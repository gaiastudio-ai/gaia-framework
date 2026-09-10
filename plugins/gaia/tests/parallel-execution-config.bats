#!/usr/bin/env bats
# parallel-execution-config.bats — the parallel_execution config section:
# schema surface, the cross-field headroom constraint, reader-bypass shapes,
# probe encoding, and the runtime ceiling read.
#
# The cross-field rule (ceiling >= slots + headroom) cannot be expressed in
# JSON Schema draft-07, so it lives in validate-project-config.sh and is
# exercised here through the REAL validator on whichever engine the host has.
#
# Bypass-shape tests (flow mapping, commented parent, signed int, ...) are
# deliberately NOT skip-guarded: a skipped bypass test is indistinguishable
# from the fail-open it exists to catch.
#
# On block/flow parametrisation — what it is and is NOT worth:
#   For the VALIDATOR tests it is defence against a future refactor, not extra
#   coverage today: yq normalises both spellings to identical JSON before the
#   validator reads a byte, so the two shapes exercise the same code path and
#   the loop does not double what is proven. It is kept because the invariant
#   "shape must not change the verdict" is cheap to pin and would otherwise be
#   silently lost if the reader ever moved back to the raw YAML.
#   For the RUNTIME tests it IS load-bearing: _dt_config_int parses the config
#   itself, and a line-oriented reader sees the two shapes differently — that
#   difference was a real over-provisioning defect.
#
# On the reader-trust guards — defence in depth, not three unique kills:
#   The validator refuses an untrustworthy reader at three points (commit only
#   on a recognised verdict, normalise the verdict, then require exactly two
#   recognised probe lines). Reverting any ONE of them is caught by another, so
#   no single-guard mutant reaches a PASS and the outermost guard kills no test
#   on its own. That is deliberate layering, not redundancy to trim: the
#   complete fail-open IS pinned (revert all three and the 8/11 config returns
#   PASS (DEGRADED), which a test catches). The outermost guard's own unique
#   contribution is AVAILABILITY — it keeps a valid config passing when jq is
#   present but broken — and that is covered by its own test.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup

  VALIDATOR="$SCRIPTS_DIR/validate-project-config.sh"
  export VALIDATOR

  LIB="$SCRIPTS_DIR/lib/dispatch-teammate.sh"
  export LIB

  # The seven required top-level keys. Without these the validator fails for
  # the wrong reason and every assertion below becomes meaningless.
  BASE_REQUIRED='project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.216.2"
date: "2026-09-10"'
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _write_config <extra-yaml> — compose base + extra, echo the path.
_write_config() {
  local extra="$1"
  local out="$TEST_TMP/config.yaml"
  printf '%s\n%s\n' "$BASE_REQUIRED" "$extra" > "$out"
  printf '%s' "$out"
}

# _write_pe_config <shape> <slots> <ceiling> — the SAME budget in block or
# flow form. Every schema/validator assertion runs through both shapes so no
# claim is proven only in the shape a line-oriented reader could see.
_write_pe_config() {
  local shape="$1" slots="$2" ceiling="$3" body=""
  case "$shape" in
    block)
      body="parallel_execution:
  max_parallel_dev_slots: ${slots}
  teammate_dispatch_ceiling: ${ceiling}"
      ;;
    flow)
      body="parallel_execution: {max_parallel_dev_slots: ${slots}, teammate_dispatch_ceiling: ${ceiling}}"
      ;;
    *) printf 'unknown shape: %s\n' "$shape" >&2; return 1 ;;
  esac
  _write_config "$body"
}

# _write_pe_body <shape> <body-line...> — render an arbitrary set of
# parallel_execution sub-keys in block or flow form, so a test that is not a
# plain slots/ceiling pair can still be proven in BOTH shapes.
_write_pe_body() {
  local shape="$1"; shift
  local kv joined="" body=""
  case "$shape" in
    block)
      body="parallel_execution:"
      for kv in "$@"; do body="${body}
  ${kv}"; done
      ;;
    flow)
      for kv in "$@"; do
        if [ -z "$joined" ]; then joined="$kv"; else joined="${joined}, ${kv}"; fi
      done
      body="parallel_execution: {${joined}}"
      ;;
    *) printf 'unknown shape: %s\n' "$shape" >&2; return 1 ;;
  esac
  _write_config "$body"
}

# _has_full_schema_engine — true when ajv or python3+jsonschema is present.
# Only schema-level (type/enum/additionalProperties) assertions need this;
# the cross-field check runs on all three engine paths by design.
_has_full_schema_engine() {
  command -v ajv >/dev/null 2>&1 && return 0
  command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1
}

# _resolve_ceiling <config-path> — source the library with the given config
# and echo the ceiling it resolves. Drives the REAL library, never a mock.
_resolve_ceiling() {
  local cfg="$1"
  GAIA_SHARED_CONFIG="$cfg" \
  GAIA_SESSION_DIR="$TEST_TMP/session" \
  bash -c '
    set -u
    export GAIA_MODE_B_SUBSTRATE=unavailable
    mkdir -p "$GAIA_SESSION_DIR"
    # shellcheck disable=SC1090
    . "$0"
    _dt_resolve_ceiling
    printf "%s\n" "$_DT_MAX_TEAMMATES"
  ' "$LIB"
}

# ---------------------------------------------------------------------------
# Schema surface + the headroom constraint (AC1)
# ---------------------------------------------------------------------------

@test "parallel_execution section is accepted with both keys at defaults (AC1)" {
  local shape
  for shape in block flow; do
    local cfg
    cfg="$(_write_pe_config "$shape" 8 12)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
  done
}

@test "config with the parallel_execution section absent validates (AC1)" {
  local cfg
  cfg="$(_write_config 'project_name: demo')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "empty parallel_execution section validates (AC1)" {
  # Both spellings of "present but empty" must behave identically to absent.
  local cfg body
  for body in 'parallel_execution: {}' 'parallel_execution:'; do
    cfg="$(_write_config "$body")"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
  done
}

@test "unknown key inside parallel_execution is rejected (AC1)" {
  _has_full_schema_engine || skip "no full-schema engine"
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_body "$shape" 'max_parallel_dev_slots: 8' \
      'teammate_dispatch_ceiling: 12' 'bogus_knob: 3')"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "non-integer max_parallel_dev_slots is rejected, not defaulted (AC1)" {
  local shape
  for shape in block flow; do
    local cfg
    cfg="$(_write_pe_config "$shape" '"abc"' 12)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "zero max_parallel_dev_slots is rejected (AC1)" {
  _has_full_schema_engine || skip "no full-schema engine"
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" 0 12)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "slots 8 with ceiling 12 is accepted — the exact headroom boundary (AC1)" {
  local shape
  for shape in block flow; do
    local cfg
    cfg="$(_write_pe_config "$shape" 8 12)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 0 ]
  done
}

@test "slots 8 with ceiling 11 is rejected — one below the headroom boundary (AC1)" {
  local shape
  for shape in block flow; do
    local cfg
    cfg="$(_write_pe_config "$shape" 8 11)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]] || [[ "${lines[*]}" == *"FAIL"* ]]
  done
}

@test "ceiling equal to the slot budget is rejected (AC1)" {
  local shape
  for shape in block flow; do
    local cfg
    cfg="$(_write_pe_config "$shape" 8 8)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "ceiling below the slot budget is rejected (AC1)" {
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" 8 6)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "ceiling far above the slot budget is accepted (AC1)" {
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" 4 32)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 0 ]
  done
}

@test "headroom is checked against the default slot budget when only the ceiling is set (AC1)" {
  # Ceiling 9 with the default slot budget 8 violates 8+4; the validator must
  # apply the same per-key default the runtime does, not skip the check.
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_body "$shape" 'teammate_dispatch_ceiling: 9')"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "the cross-field failure names the offending key and both values (AC1)" {
  local shape cfg all
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" 8 11)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
    all="${output}${stderr:-}"
    [[ "$all" == *"teammate_dispatch_ceiling"* ]]
    [[ "$all" == *"max_parallel_dev_slots"* ]]
  done
}

# ---------------------------------------------------------------------------
# Default convergence + the runtime ceiling read (AC1, AC2)
# ---------------------------------------------------------------------------

@test "absent section, empty section, and explicit defaults resolve to the same ceiling (AC1, AC2)" {
  local absent empty explicit a b c
  absent="$(_write_config 'project_name: demo')"
  a="$(_resolve_ceiling "$absent")"
  empty="$(_write_config 'parallel_execution: {}')"
  b="$(_resolve_ceiling "$empty")"
  [ "$a" = "12" ]
  [ "$b" = "12" ]
  # Explicit defaults must converge in BOTH shapes.
  local shape
  for shape in block flow; do
    explicit="$(_write_pe_config "$shape" 8 12)"
    c="$(_resolve_ceiling "$explicit")"
    [ "$c" = "12" ]
  done
}

@test "the resolved ceiling comes from config, not a hardcoded value (AC2)" {
  local shape cfg got
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" 1 5)"
    got="$(_resolve_ceiling "$cfg")"
    [ "$got" = "5" ]
  done
}

@test "a non-integer configured ceiling falls back to the default rather than propagating (AC2)" {
  local shape cfg got
  for shape in block flow; do
    cfg="$(_write_pe_body "$shape" 'teammate_dispatch_ceiling: abc')"
    got="$(_resolve_ceiling "$cfg")"
    [ "$got" = "12" ]
  done
}

@test "a configured ceiling of zero falls back to the default (AC2)" {
  local shape cfg got
  for shape in block flow; do
    cfg="$(_write_pe_body "$shape" 'teammate_dispatch_ceiling: 0')"
    got="$(_resolve_ceiling "$cfg")"
    [ "$got" = "12" ]
  done
}

# ---------------------------------------------------------------------------
# Reader-bypass shapes — NO skip-guards (AC1)
# ---------------------------------------------------------------------------

@test "an under-provisioned budget written as a flow mapping is rejected (AC1)" {
  local cfg
  cfg="$(_write_config 'parallel_execution: {max_parallel_dev_slots: 40, teammate_dispatch_ceiling: 5}')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  [[ "${output}${stderr:-}" == *"teammate_dispatch_ceiling"* ]]
}

@test "an under-provisioned budget whose parent line carries a trailing comment is rejected (AC1)" {
  local cfg
  cfg="$(_write_config 'parallel_execution: # small CI box
  max_parallel_dev_slots: 40
  teammate_dispatch_ceiling: 5')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "a signed-integer slot budget is honoured, not silently defaulted (AC1)" {
  # +40 normalises to 40; against ceiling 5 that must be REJECTED, not read
  # as an absent/zero budget that would pass.
  local cfg
  cfg="$(_write_config 'parallel_execution:
  max_parallel_dev_slots: +40
  teammate_dispatch_ceiling: 5')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "a parallel_execution section that is a string, not an object, is rejected (AC1)" {
  local cfg
  cfg="$(_write_config 'parallel_execution: "hello"')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "a negative slot budget is rejected (AC1)" {
  local shape cfg
  for shape in block flow; do
    cfg="$(_write_pe_config "$shape" -4 12)"
    run "$VALIDATOR" "$cfg"
    [ "$status" -eq 1 ]
  done
}

@test "the same keys nested under the wrong parent do not satisfy the check (AC1)" {
  # A sibling section carrying the same key names must not be mistaken for
  # parallel_execution; with no real section present this must PASS.
  local cfg
  cfg="$(_write_config 'unrelated_section:
  max_parallel_dev_slots: 40
  teammate_dispatch_ceiling: 5')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Probe-encoding hardening (AC1)
# ---------------------------------------------------------------------------

@test "a space-containing string slot value is rejected on the DEGRADED path (AC1)" {
  # Force Path B (jq degraded) by masking the jsonschema import: yq still
  # performs the YAML->JSON conversion, so the path is genuinely reached.
  # A positional probe would read slots=40 ceiling=99 and PASS a config whose
  # real ceiling is 5.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local cfg fakelib
  cfg="$(_write_config 'parallel_execution:
  max_parallel_dev_slots: "40 99"
  teammate_dispatch_ceiling: 5')"
  fakelib="$TEST_TMP/nojsonschema"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "an explicit null sub-key is rejected, not treated as absent (AC1)" {
  local cfg
  cfg="$(_write_config 'parallel_execution:
  max_parallel_dev_slots: null
  teammate_dispatch_ceiling: 12')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "the jq and python3 readers agree on every fixture (AC1)" {
  # The reader chain prefers jq, so comparing engine paths alone never runs the
  # python3 reader. Mask jq from PATH to force the python3 branch, and compare
  # its verdict against the jq branch on the same fixtures. A divergence (e.g.
  # one branch treating an explicit null as "absent") shows up here.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  # Shadow jq for the parallel_execution queries ONLY, delegating everything
  # else to the real jq. A blanket-failing stub also breaks the DEGRADED path's
  # own required-property check, which uses jq too — on a host without the
  # python jsonschema module (precisely what degraded mode serves) a valid
  # fixture then fails for an unrelated reason and the two sides diverge. That
  # would have been green here and red in an environment without jsonschema.
  local shadow="$TEST_TMP/shadow"
  _make_selective_jq_stub "$shadow" garbage

  local body cfg rc_jq rc_py
  for body in \
    'parallel_execution: {max_parallel_dev_slots: 40, teammate_dispatch_ceiling: 5}' \
    'parallel_execution:
  max_parallel_dev_slots: null
  teammate_dispatch_ceiling: 12' \
    'parallel_execution:
  max_parallel_dev_slots: 8
  teammate_dispatch_ceiling: 12' \
    'parallel_execution:
  max_parallel_dev_slots: "40 99"
  teammate_dispatch_ceiling: 5'
  do
    cfg="$(_write_config "$body")"
    "$VALIDATOR" "$cfg" >/dev/null 2>&1 && rc_jq=0 || rc_jq=1
    PATH="$shadow:$PATH" "$VALIDATOR" "$cfg" >/dev/null 2>&1 && rc_py=0 || rc_py=1
    [ "$rc_jq" = "$rc_py" ]
  done

  # Repeat with the jsonschema module masked: that is the environment the
  # degraded path exists for, and it is where a blanket jq stub diverged.
  local fakelib="$TEST_TMP/nojs-agree"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  for body in \
    'parallel_execution:
  max_parallel_dev_slots: 8
  teammate_dispatch_ceiling: 12' \
    'parallel_execution: {max_parallel_dev_slots: 40, teammate_dispatch_ceiling: 5}'
  do
    cfg="$(_write_config "$body")"
    PYTHONPATH="$fakelib" "$VALIDATOR" "$cfg" >/dev/null 2>&1 && rc_jq=0 || rc_jq=1
    PATH="$shadow:$PATH" PYTHONPATH="$fakelib" "$VALIDATOR" "$cfg" >/dev/null 2>&1 && rc_py=0 || rc_py=1
    [ "$rc_jq" = "$rc_py" ]
  done
}

@test "a quoted numeric ceiling is rejected by the validator (AC1)" {
  # The runtime silently ignores a quoted numeric and falls back to the
  # default, so the validator is the only layer that can tell the operator
  # their value is not taking effect.
  local cfg
  cfg="$(_write_config 'parallel_execution:
  max_parallel_dev_slots: 1
  teammate_dispatch_ceiling: "5"')"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Engine-path coverage: the hook must be wired on ALL THREE success paths
# ---------------------------------------------------------------------------

# _make_ajv_stub <dir> — write a delegating `ajv` that performs a real
# jsonschema validation via python3 and mirrors ajv's CLI contract
# (`ajv validate -s SCHEMA -d DATA`, exit 0 valid / 1 invalid). Without this the
# ajv branch is never taken on a host that has no ajv, and deleting the hook
# from that branch would kill no test.
_make_ajv_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/ajv" <<'AJVEOF'
#!/usr/bin/env bash
schema=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) schema="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
python3 - "$schema" "$data" <<'PYEOF'
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
cls = jsonschema.validators.validator_for(schema)
validator = cls(schema)
errors = list(validator.iter_errors(data))
if errors:
    for e in errors:
        sys.stderr.write("invalid: " + str(e.message) + chr(10))
    sys.exit(1)
sys.exit(0)
PYEOF
AJVEOF
  chmod +x "$dir/ajv"
}

@test "the headroom rule is enforced on the ajv engine path too (AC1)" {
  # Binds the third call site. Mutant: removing the hook from the ajv branch
  # must turn this red — on a host without ajv nothing else would notice.
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  python3 -c 'import jsonschema' >/dev/null 2>&1 || skip "jsonschema unavailable"
  local stub cfg
  stub="$TEST_TMP/ajvbin"
  _make_ajv_stub "$stub"
  cfg="$(_write_pe_config block 8 11)"
  PATH="$stub:$PATH" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  [[ "${output}${stderr:-}" == *"teammate_dispatch_ceiling"* ]]
}

@test "a valid budget still passes on the ajv engine path (AC1)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  python3 -c 'import jsonschema' >/dev/null 2>&1 || skip "jsonschema unavailable"
  local stub cfg
  stub="$TEST_TMP/ajvbin"
  _make_ajv_stub "$stub"
  cfg="$(_write_pe_config block 8 12)"
  PATH="$stub:$PATH" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
}

@test "an explicit null ceiling is rejected on the DEGRADED path (AC1)" {
  # On the degraded path there is no schema to reject null first, so the jq
  # probe's has() is the only thing standing between an explicit null and a
  # silent default. Mutant: has() -> `!= null` must turn this red.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local cfg fakelib
  cfg="$(_write_config 'parallel_execution:
  max_parallel_dev_slots: 1
  teammate_dispatch_ceiling: null')"
  fakelib="$TEST_TMP/nojsonschema"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  [[ "${output}${stderr:-}" == *"teammate_dispatch_ceiling"* ]]
}

@test "the teammate-dispatch docs state the ceiling-saturated exit contract (AC2)" {
  # A caller that does not know exit 8 is a capacity condition will mark queued
  # work failed, and an unguarded assignment dies under errexit.
  local readme
  readme="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)/README.md"
  [ -f "$readme" ]
  # Assert content unique to the exit-8 paragraph. The `rc=$?` idiom is shared
  # with the exit-7 block, so pinning it alone would stay green if the exit-8
  # documentation were deleted outright.
  grep -q 'exit code 8' "$readme"
  grep -qi 'capacity condition' "$readme"
  # The queue-and-retry instruction is the exit-8 contract specifically.
  grep -qi 'queue' "$readme"
  # And the worked guard must actually branch on 8, not merely mention rc=$?.
  grep -qE '^ *8\)' "$readme"
}

# ---------------------------------------------------------------------------
# Untrustworthy-reader guards: a reader that exits 0 while emitting nonsense
# must never be believed. Emptiness is not the test — shape is.
# ---------------------------------------------------------------------------

# _make_selective_jq_stub <dir> <mode> — a `jq` that corrupts ONLY the
# parallel_execution queries and delegates everything else to the real jq, so
# the rest of the degraded path behaves normally and the assertion isolates the
# guard under test.
#   mode=garbage   exit 0 with a non-verdict token
#   mode=extraline exit 0 with the two expected probe lines PLUS a bogus third
_make_selective_jq_stub() {
  local dir="$1" mode="$2" real
  real="$(command -v jq)"
  mkdir -p "$dir"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do\n'
    if [ "$mode" = extraline ]; then
      printf '  case "$a" in\n'
      printf '    *has\\(*) printf %s; exit 0 ;;\n' "'slots\tnumber\t8\nceiling\tnumber\t99\nbogus\tnumber\t1\n'"
      printf '  esac\n'
    else
      printf '  case "$a" in\n'
      printf '    *parallel_execution*) echo garbage-not-json; exit 0 ;;\n'
      printf '  esac\n'
    fi
    printf 'done\n'
    printf 'exec %s "$@"\n' "$real"
  } > "$dir/jq"
  chmod +x "$dir/jq"
}

@test "a jq that exits 0 with garbage is not trusted on the degraded path (AC1)" {
  # Guard: commit to jq only on a RECOGNISED verdict. If emptiness alone were
  # the test, the garbage would fall past ABSENT/NOTOBJ, the probe would yield
  # unparseable lines, and the defaults would satisfy the headroom rule — an
  # under-provisioned 8/11 budget would PASS (DEGRADED).
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local stub cfg fakelib all
  stub="$TEST_TMP/jqgarbage"
  _make_selective_jq_stub "$stub" garbage
  cfg="$(_write_pe_config block 8 11)"
  fakelib="$TEST_TMP/nojsonschema"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PATH="$stub:$PATH" PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  all="${output}${stderr:-}"
  [[ "$all" != *"PASS (DEGRADED)"* ]]
  # Shipped falls through to python3 and names the real violation; a reverted
  # guard hard-fails with the reader message instead. Either way it must NOT
  # pass, and it must mention the section.
  [[ "$all" == *"parallel_execution"* ]]
}

@test "a VALID budget still validates when jq is broken (AC1)" {
  # The recognised-verdict guard's unique behaviour is AVAILABILITY, not safety:
  # its safety role is covered downstream. Without it, a present-but-broken jq
  # makes the reader commit to jq on non-empty garbage and hard-fail with
  # "cannot verify", so a perfectly valid 8/12 config is REJECTED. With it, the
  # chain falls through to python3 and the config passes.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  local stub cfg
  stub="$TEST_TMP/jqavail"
  _make_selective_jq_stub "$stub" garbage
  cfg="$(_write_pe_config block 8 12)"
  PATH="$stub:$PATH" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "a jq emitting an extra probe line is not trusted (AC1)" {
  # Guard: exactly two recognised label lines, no unrecognised ones. The stub
  # reports a ceiling of 99 (which would satisfy 8+4) alongside a bogus third
  # line; believing it would accept a budget the real config never declared.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local stub cfg fakelib all
  stub="$TEST_TMP/jqextra"
  _make_selective_jq_stub "$stub" extraline
  cfg="$(_write_pe_config block 8 11)"
  fakelib="$TEST_TMP/nojsonschema2"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PATH="$stub:$PATH" PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
  all="${output}${stderr:-}"
  [[ "$all" != *"PASS (DEGRADED)"* ]]
}

@test "a yq that exits 0 with garbage resolves the conservative ceiling (AC2)" {
  # Runtime counterpart. A reader that cannot be trusted is an UNKNOWN, so the
  # ceiling must fall to the conservative bound with a warning — never to the
  # 12 default, which would silently ignore the operator configuring 5.
  local stub cfg got
  stub="$TEST_TMP/yqgarbage"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho garbage\nexit 0\n' > "$stub/yq"
  chmod +x "$stub/yq"
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 5')"
  got="$(PATH="$stub:$PATH" GAIA_SHARED_CONFIG="$cfg" GAIA_SESSION_DIR="$TEST_TMP/gsess" \
    /bin/bash -c '
      set -u
      export GAIA_MODE_B_SUBSTRATE=unavailable
      mkdir -p "$GAIA_SESSION_DIR"
      # shellcheck disable=SC1090
      . "$0"
      _dt_resolve_ceiling 2>/dev/null
      printf "%s\n" "$_DT_MAX_TEAMMATES"
    ' "$LIB")"
  [ "$got" = "8" ]
}

@test "an untrustworthy runtime reader logs why it fell back (AC2)" {
  local stub cfg err
  stub="$TEST_TMP/yqgarbage2"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho garbage\nexit 0\n' > "$stub/yq"
  chmod +x "$stub/yq"
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 5')"
  err="$(PATH="$stub:$PATH" GAIA_SHARED_CONFIG="$cfg" GAIA_SESSION_DIR="$TEST_TMP/gsess2" \
    /bin/bash -c '
      set -u
      export GAIA_MODE_B_SUBSTRATE=unavailable
      mkdir -p "$GAIA_SESSION_DIR"
      # shellcheck disable=SC1090
      . "$0"
      _dt_resolve_ceiling 2>&1 >/dev/null
    ' "$LIB")"
  [[ "$err" == *"conservative ceiling"* ]]
}

# ---------------------------------------------------------------------------
# Bridge errexit safety: a saturated ceiling must not kill the skill
# ---------------------------------------------------------------------------

# _bridge_ceiling_probe <bridge-file> <spawn-fn> <session> — fill the ceiling,
# then call the bridge under `set -euo pipefail` and report the bridge's own
# stderr. A bridge whose assignment is unguarded aborts mid-body BEFORE its
# capacity branch runs, so only the raw library message appears; a guarded one
# reaches its own branch and names the capacity condition.
_bridge_ceiling_probe() {
  local bridge="$1" fn="$2" sess="$3" cfg="$4"
  GAIA_SHARED_CONFIG="$cfg" GAIA_SESSION_DIR="$sess" _DT_CEILING_RETRY_BASE_DELAY=0 \
  bash -c '
    set -euo pipefail
    export GAIA_MODE_B_SUBSTRATE=unavailable
    mkdir -p "$GAIA_SESSION_DIR"
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    spawn_teammate "gaia:a1" >/dev/null
    spawn_teammate "gaia:a2" >/dev/null
    # Deliberately NOT guarded with an or-assignment: such a guard suspends
    # errexit for the whole call and would mask an abort inside the bridge,
    # which is exactly the defect under test. The subshell keeps an abort from
    # killing this probe; the bridge own stderr is then the discriminator, as
    # an unguarded bridge dies at its assignment and never reaches its
    # capacity branch.
    # UNGUARDED call site, in a child shell under errexit — the real skill
    # shape. An or-guard here would suspend errexit for the whole compound and
    # neither form would abort, which is what made an earlier version of this
    # probe blind. A bridge whose own assignment is unguarded dies AT that
    # assignment and never reaches its capacity branch, so its message never
    # appears; a guarded bridge prints it and then returns the code.
    "$3" "gaia:architect" "sess" >/dev/null 2>"$GAIA_SESSION_DIR/err.txt"
    printf "unreachable\n"
  ' _ "$LIB" "$bridge" "$fn" 2>/dev/null
  printf 'stderr=%s\n' "$(tail -1 "$sess/err.txt" 2>/dev/null)"
}

@test "a saturated ceiling does not kill the planning bridge under errexit (AC2)" {
  local cfg out
  cfg="$(_write_pe_config block 1 2)"
  out="$(_bridge_ceiling_probe \
    "$(dirname "$LIB")/planning-mode-b-bridge.sh" planning_spawn_subagent \
    "$TEST_TMP/pb" "$cfg")"
  # The bridge reached its own capacity branch rather than aborting at the
  # assignment — an unguarded bridge dies first and never prints this.
  [[ "$out" == *"ceiling saturated"* ]]
}

@test "a saturated ceiling does not kill the research bridge under errexit (AC2)" {
  local cfg out
  cfg="$(_write_pe_config block 1 2)"
  out="$(_bridge_ceiling_probe \
    "$(dirname "$LIB")/research-mode-b-bridge.sh" research_spawn_subagent \
    "$TEST_TMP/rb" "$cfg")"
  [[ "$out" == *"ceiling saturated"* ]]
}

@test "a saturated ceiling does not kill the conversational bridge under errexit (AC2)" {
  local cfg out
  cfg="$(_write_pe_config block 1 2)"
  out="$(_bridge_ceiling_probe \
    "$(dirname "$LIB")/conversational-mode-b-bridge.sh" conversational_spawn_participant \
    "$TEST_TMP/cb" "$cfg")"
  [[ "$out" == *"ceiling saturated"* ]]
}

# ---------------------------------------------------------------------------
# Out-of-range ceilings must never reach shell arithmetic (security F-1/F-2)
# ---------------------------------------------------------------------------

@test "an out-of-range ceiling is rejected on the degraded path (AC1)" {
  # A value beyond the shell's integer range makes `[` abort and evaluate
  # false, so the headroom test silently passes and the degraded path prints
  # PASS for a config that bricks dispatch at runtime.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local cfg fakelib
  cfg="$(_write_pe_config block 8 99999999999999999999)"
  fakelib="$TEST_TMP/nojs-range"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "an out-of-range ceiling is rejected on the full-schema path (AC1)" {
  _has_full_schema_engine || skip "no full-schema engine"
  local cfg
  cfg="$(_write_pe_config block 8 99999999999999999999)"
  run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "a ceiling above the schema maximum is rejected by the validator (AC1)" {
  local cfg fakelib
  cfg="$(_write_pe_config block 8 65)"
  fakelib="$TEST_TMP/nojs-65"
  mkdir -p "$fakelib"
  printf 'raise ImportError("masked")\n' > "$fakelib/jsonschema.py"
  PYTHONPATH="$fakelib" run "$VALIDATOR" "$cfg"
  [ "$status" -eq 1 ]
}

@test "an out-of-range ceiling resolves conservatively and leaves dispatch working (AC2)" {
  # The bug this pins: the oversized value poisoned the enforcement comparison
  # too, so EVERY spawn was refused against an empty registry.
  local cfg got
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 99999999999999999999')"
  got="$(_resolve_ceiling "$cfg")"
  [ "$got" = "8" ]

  local rc=0
  GAIA_SHARED_CONFIG="$cfg" GAIA_SESSION_DIR="$TEST_TMP/oor" \
  bash -c '
    set -u
    export GAIA_MODE_B_SUBSTRATE=unavailable
    mkdir -p "$GAIA_SESSION_DIR"
    # shellcheck disable=SC1090
    . "$0"
    spawn_teammate "gaia:analyst" >/dev/null 2>&1
  ' "$LIB" || rc=$?
  [ "$rc" -eq 0 ]
}

@test "the runtime clamp holds in both directions at the schema maximum (AC2)" {
  local cfg got
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 65')"
  got="$(_resolve_ceiling "$cfg")"
  [ "$got" = "64" ]
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 64')"
  got="$(_resolve_ceiling "$cfg")"
  [ "$got" = "64" ]
}

@test "twelve bridge spawns read the config once, not twelve times (AC2)" {
  # Each spawn runs inside a command substitution, so an in-shell memo dies with
  # the subshell and every spawn re-forks the reader. The bridge warms the cache
  # in the PARENT and exports it, so the read happens once per session.
  command -v yq >/dev/null 2>&1 || skip "yq unavailable"
  local cfg bin log real
  cfg="$(_write_pe_body block 'teammate_dispatch_ceiling: 20')"
  bin="$TEST_TMP/forkcount"
  log="$TEST_TMP/forks.log"
  mkdir -p "$bin"
  : > "$log"
  real="$(command -v yq)"
  printf '#!/bin/sh\necho x >> "%s"\nexec %s "$@"\n' "$log" "$real" > "$bin/yq"
  chmod +x "$bin/yq"

  PATH="$bin:$PATH" GAIA_SHARED_CONFIG="$cfg" GAIA_SESSION_DIR="$TEST_TMP/fc" \
  bash -c '
    set -u
    export GAIA_MODE_B_SUBSTRATE=unavailable
    mkdir -p "$GAIA_SESSION_DIR"
    # shellcheck disable=SC1090
    . "$0"
    i=1
    while [ "$i" -le 12 ]; do
      planning_spawn_subagent "gaia:agent-$i" "s" >/dev/null 2>&1
      i=$((i + 1))
    done
  ' "$(dirname "$LIB")/planning-mode-b-bridge.sh" 2>/dev/null || true

  local forks
  forks="$( { wc -l < "$log" || true; } | tr -d ' ')"
  [ "$forks" -eq 1 ]
}

@test "the config section is registered as operator-managed, not auto-hydrated (AC1)" {
  # Two registrations, with different jobs:
  #   - the schema marker DOCUMENTS the intent (and satisfies the hydration
  #     reverse invariant, which is an OR over three buckets);
  #   - the managed-elsewhere entry is what the RECONCILER actually consults.
  # Only the second is load-bearing at runtime; the marker is pinned here so it
  # cannot be dropped silently, leaving the intent undocumented.
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  local schema hydration marked
  schema="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)/project-config.schema.json"
  hydration="$(dirname "$LIB")/config-hydration.sh"
  [ -f "$schema" ]
  [ -f "$hydration" ]

  marked="$(jq -r '.properties.parallel_execution["x-no-auto-hydration"] // "absent"' "$schema")"
  [ "$marked" = "true" ]

  # The section must NOT be auto-hydrated: a stub would mean exactly what the
  # section absence already means, while adding a key to every project config.
  run bash -c "source '$hydration' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_MANAGED_ELSEWHERE[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"parallel_execution"* ]]

  run bash -c "source '$hydration' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_ALLOWLIST[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"parallel_execution"* ]]
}

# ---------------------------------------------------------------------------
# Sweep-regression guard (AC3)
# ---------------------------------------------------------------------------

@test "a malformed config resolves to the conservative bound, not the default (AC2)" {
  # yq exits non-zero with EMPTY output on a parse error — byte-identical to
  # "key absent" if the exit status is discarded. An unknown must land on the
  # conservative 8, never the 12 default.
  local cfg got
  cfg="$TEST_TMP/malformed.yaml"
  printf '%s\nparallel_execution:\n  teammate_dispatch_ceiling: 5\n  bad: [unclosed\n' \
    "$BASE_REQUIRED" > "$cfg"
  got="$(_resolve_ceiling "$cfg")"
  [ "$got" = "8" ]
}

@test "an unreadable config file resolves to the conservative bound (AC2)" {
  local cfg got
  cfg="$(_write_pe_config block 1 5)"
  chmod 000 "$cfg"
  got="$(_resolve_ceiling "$cfg")"
  chmod 644 "$cfg"
  [ "$got" = "8" ]
}

@test "a quoted numeric ceiling resolves to the default at runtime, not to its digits (AC2)" {
  # yq preserves the quotes through -o=json, so the integer filter rejects it
  # and the value falls back to 12 — it does NOT become 5.
  local cfg got
  cfg="$(_write_config 'parallel_execution:
  teammate_dispatch_ceiling: "5"')"
  got="$(_resolve_ceiling "$cfg")"
  [ "$got" = "12" ]
}

@test "no published file states a hard eight-teammate ceiling (AC3)" {
  local root hits
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # Scope covers every change site the story names, INCLUDING the plugin
  # CHANGELOG and tests/ — a guard that skipped them would let the literal come
  # back in exactly the two places the sweep also had to touch.
  #
  # Two allowlisted exceptions, both deliberate:
  #   - the released [1.203.0] CHANGELOG entry, where the hard 8 was factually
  #     correct at the time; rewriting shipped history would make it lie;
  #   - this guard's own regex literal, which must contain what it searches for.
  # `|| true` is load-bearing: grep exits 1 on no-match, and under the helper's
  # `set -e` the substitution would abort the test at this line, so a fully
  # swept tree would fail here instead of reaching the assertion.
  # Every stage needs `|| true`: grep exits 1 both on no-match AND when the
  # allowlist filters remove every line, and either would abort the test here.
  hits="$( { { { grep -rnE '(^|[^%d])(8|[Ee]ight)[ -]?teammate|ceiling of (8|eight)|_DT_MAX_TEAMMATES=8' \
    "$root/documentation" "$root/plugins/gaia/skills" "$root/plugins/gaia/scripts" \
    "$root/plugins/gaia/CHANGELOG.md" "$root/plugins/gaia/tests" 2>/dev/null || true; } \
    | { grep -v 'CHANGELOG.md:.*Agent Teams (Mode B) foundation' || true; }; } \
    | { grep -v 'parallel-execution-config.bats:' || true; }; } \
    | wc -l | tr -d ' ')"
  [ "$hits" -eq 0 ]
}


