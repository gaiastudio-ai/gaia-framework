#!/usr/bin/env bats
# phase-persistence.bats — coverage for the optional per-story `phase` field
# persisted through sprint-state.sh.
#
# The phase is a sprint-level scheduling attribute: a 1-based partition index
# over ONE sprint's candidate set, supplied by the planner rather than read
# from story frontmatter. It is optional, and a sprint planned without phases
# must produce byte-identical yaml to the pre-phase output — so the field is
# OMITTED when unset, never emitted as a null.
#
# Surfaces exercised, all against the real script (no mocks anywhere):
#   * inject --phase <n>            — the emitter path
#   * set-phase --story K --phase N — the net-new writer verb (set / clear)
#   * transition / reconcile        — must preserve the field by construction
#   * set-story-sprint              — must not touch the yaml at all
#   * rollover                      — must CLEAR the phase on both branches
#
# Public functions covered (public-function coverage gate):
#   cmd_set_phase, do_set_phase_locked, read_yaml_story_phase,
#   append_story_to_yaml, cmd_inject.
#
# cmd_set_phase is the dispatch target for the `set-phase` subcommand and is
# driven end-to-end by every set-phase test below. do_set_phase_locked is its
# locked critical section — the idempotency no-op and the not-found refusal
# are asserted through it. read_yaml_story_phase is the entry-scoped reader
# that supplies the current value the idempotency check compares against.
#
# Two-copy byte-identity is pinned by the standing wrapper gates elsewhere in
# this suite; no duplicate gate is added here. The no-op writer paths are
# additionally double-driven against the wrapper copy, because that is the
# copy the story-development workflow actually invokes.

load 'test_helper.bash'

setup() {
  common_setup
  CANONICAL="$SCRIPTS_DIR/sprint-state.sh"
  WRAPPER="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"
  # The wrapper's sibling foundation scripts (lifecycle-event.sh) live in the
  # canonical scripts dir; point the resolver there so the real event emitter
  # runs rather than dying on a missing sibling.
  export SPRINT_STATE_SCRIPT_DIR="$SCRIPTS_DIR"
  export CANONICAL WRAPPER
  export MEMORY_PATH="$TEST_TMP/_memory"
  export PROJECT_PATH="$TEST_TMP"
  # Hermetic: never inherit an ambient project from the developer's shell.
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_CONFIG
  ART="$TEST_TMP/docs/implementation-artifacts"
  YAML="$TEST_TMP/.gaia/state/sprint-status.yaml"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/phase-persistence"
  export ART YAML FIXTURES
  mkdir -p "$ART" "$MEMORY_PATH" "$TEST_TMP/.gaia/state"
}
teardown() { common_teardown; }

# Seed a story file whose frontmatter carries the fields inject validates.
seed_story() {
  local key="$1" sprint_id="${2:-sprint-99}" status="${3:-ready-for-dev}"
  cat > "$ART/${key}-x.md" <<EOF
---
template: 'story'
key: "$key"
title: "Fake $key"
status: $status
sprint_id: $sprint_id
points: 3
risk: "medium"
---

# Story: Fake $key

> **Status:** $status
EOF
}

# Seed a sprint yaml with the given story rows already present. Each argument
# is "KEY" or "KEY:PHASE" — the latter emits a phase line on that row.
seed_yaml_with_rows() {
  local sprint_id="$1"; shift
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: active\n'
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items: []\n'
    printf 'stories:\n'
    local spec key phase
    for spec in "$@"; do
      key="${spec%%:*}"
      phase=""
      case "$spec" in *:*) phase="${spec#*:}" ;; esac
      printf '  - key: "%s"\n' "$key"
      printf "    title: 'Fake %s'\n" "$key"
      printf '    status: "ready-for-dev"\n'
      printf '    points: 3\n'
      printf '    risk_level: "medium"\n'
      printf '    assignee: null\n'
      printf '    blocked_by: null\n'
      printf '    updated: "2026-01-01"\n'
      [ -z "$phase" ] || printf '    phase: %s\n' "$phase"
    done
  } > "$YAML"
}

# Print the yaml block belonging to one story key: the `- key:` header line
# through the line before the next entry header or the next top-level key.
# Entry-scoped, so a "exactly one phase line" assertion cannot pass spuriously
# by matching a sibling row.
entry_block() {
  local key="$1"
  awk -v target="$key" '
    BEGIN { in_entry = 0 }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1; print; next }
      in_entry = 0
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry { print }
  ' "$YAML"
}

# Count phase lines within one story entry (never file-wide).
entry_phase_count() {
  entry_block "$1" | grep -c 'phase:' || true
}

# Snapshot the yaml so a later cmp proves the run wrote nothing.
snapshot_yaml() { cp "$YAML" "$YAML.pre"; }

# Assert the combined output is the validator's OWN rejection of $value, not
# some other refusal that happens to exit non-zero. Without this the whole
# negative-input block would pass vacuously against a script that simply does
# not know the flag: `unknown flag: --phase` is also a non-zero exit with
# "--phase" in the message, so a laxer assertion proves nothing about the
# validator ever having been written.
assert_phase_rejected() {
  local text="$1" value="$2"
  case "$text" in
    *"unknown flag"*|*"unknown subcommand"*)
      printf 'assert_phase_rejected: flag/subcommand not implemented, got: %s\n' "$text" >&2
      return 1 ;;
  esac
  case "$text" in
    *"--phase must "*"got: '${value}'"*) return 0 ;;
  esac
  printf 'assert_phase_rejected: missing validator diagnostic for %s, got: %s\n' "$value" "$text" >&2
  return 1
}

# Assert the surface exists at all — used by the positive-path tests so a
# failure line names the missing behaviour rather than a bare status compare.
assert_surface_implemented() {
  local text="$1"
  case "$text" in
    *"unknown flag"*|*"unknown subcommand"*)
      printf 'assert_surface_implemented: phase surface missing, got: %s\n' "$text" >&2
      return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# AC1 — the emitter: inject --phase
# ---------------------------------------------------------------------------

@test "inject --phase writes an unquoted integer phase into the story row (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]

  run bash "$CANONICAL" inject --story AAA-S1 --phase 2
  [ "$status" -eq 0 ]

  run entry_block AAA-S1
  [ "$status" -eq 0 ]
  # Unquoted integer, matching the `points:` precedent — not "2" and not '2'.
  printf '%s\n' "$output" | grep -q '^    phase: 2$'
  run grep -c 'phase: "2"' "$YAML"
  [ "$output" = "0" ]

  # Serialisation guard: yq must read the field back as a NUMBER, not a string.
  if command -v yq >/dev/null 2>&1; then
    run yq eval '.stories[0].phase | type' "$YAML"
    [ "$status" -eq 0 ]
    [ "$output" = "!!int" ] || [ "$output" = "int" ]
  fi
}

@test "inject --phase emits phase as the last field, after updated (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  run bash "$CANONICAL" inject --story AAA-S1 --phase 3
  [ "$status" -eq 0 ]

  # Exact nine-line block, field order and indentation pinned. `updated:` is
  # clock-dependent so it is normalised on both sides — no literal date is
  # ever asserted anywhere in this suite.
  local got expected
  got="$(entry_block AAA-S1 | sed -E 's/^([[:space:]]*updated: ).*/\1"<DATE>"/')"
  expected="$(cat <<'EOF'
  - key: "AAA-S1"
    title: 'Fake AAA-S1'
    status: "ready-for-dev"
    points: 3
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "<DATE>"
    phase: 3
EOF
)"
  [ "$got" = "$expected" ]
}

@test "inject without --phase omits the phase key entirely — never phase: null (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  run bash "$CANONICAL" inject --story AAA-S1
  [ "$status" -eq 0 ]

  # File-wide: not one occurrence of the token anywhere, in any form.
  run grep -c 'phase' "$YAML"
  [ "$output" = "0" ]

  # Positive control: the omission above is only meaningful if the emitter is
  # actually CAPABLE of writing the field. Without this the test would pass
  # against a script that has no phase support at all.
  seed_story AAA-S2
  run bash "$CANONICAL" inject --story AAA-S2 --phase 1
  assert_surface_implemented "$output"
  [ "$status" -eq 0 ]
  run entry_block AAA-S2
  printf '%s\n' "$output" | grep -q '^    phase: 1$'
}

@test "inject --phase 0 is rejected and the yaml is unchanged (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  run bash "$CANONICAL" inject --story AAA-S1 --phase 0
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "0"
  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase -1 is rejected and the yaml is unchanged (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  run bash "$CANONICAL" inject --story AAA-S1 --phase -1
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "-1"
  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase abc is rejected and the yaml is unchanged (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  run bash "$CANONICAL" inject --story AAA-S1 --phase abc
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "abc"
  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase 2.5 is rejected and the yaml is unchanged (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  # A guard that inspects only the first character would accept this.
  run bash "$CANONICAL" inject --story AAA-S1 --phase 2.5
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "2.5"
  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase 07 is rejected as a leading-zero form (AC-EC3)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  # A leading-zero literal round-trips through yq as the STRING "07", which
  # would break the unquoted-integer serialisation guarantee.
  local v
  for v in 07 007; do
    run bash "$CANONICAL" inject --story AAA-S1 --phase "$v"
    [ "$status" -ne 0 ]
    assert_phase_rejected "$output" "$v"
    cmp "$YAML.pre" "$YAML"
  done
}

@test "inject --phase 1000 is rejected as out of range while 999 is accepted (AC1)" {
  seed_story AAA-S1
  seed_story AAA-S2
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  run bash "$CANONICAL" inject --story AAA-S1 --phase 1000
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "1000"
  cmp "$YAML.pre" "$YAML"

  # The bound is inclusive — the boundary value itself must still work, so a
  # regression that rejects everything cannot pass this test.
  run bash "$CANONICAL" inject --story AAA-S2 --phase 999
  [ "$status" -eq 0 ]
  run entry_block AAA-S2
  printf '%s\n' "$output" | grep -q '^    phase: 999$'
}

@test "inject --phase with a 26-digit value is rejected without shell noise on stderr (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  # An arithmetic comparison cannot parse a literal wider than a machine
  # integer: the shell prints its own diagnostic and evaluates the test as
  # FALSE, which inside an `if` neither dies nor trips set -e — so the value
  # falls through to ACCEPTED. A digit-count check must run first.
  local stderr_file="$TEST_TMP/wide.stderr"
  run bash -c 'bash "$1" inject --story AAA-S1 --phase 99999999999999999999999999 2>"$2" >/dev/null' \
    _ "$CANONICAL" "$stderr_file"
  [ "$status" -ne 0 ]

  # Positive whole-stderr match. Asserting what stderr IS — rather than
  # blocklisting known shell wordings — keeps this shell-agnostic: bash 3.2
  # says "integer expression expected" where bash 5 says "integer expected",
  # so any exclusion list would be version-specific.
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  [ "$stderr_content" = "sprint-state.sh: error: inject: --phase must be between 1 and 999, got: '99999999999999999999999999'" ]

  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase with an empty value is rejected and writes nothing (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  # An explicitly-given empty value must NOT be silently reinterpreted as
  # "flag omitted" — that would hide a caller passing an unset variable.
  run bash "$CANONICAL" inject --story AAA-S1 --phase ""
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" ""
  cmp "$YAML.pre" "$YAML"
}

@test "inject --phase requires a value when it is the final argument (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  snapshot_yaml

  run bash "$CANONICAL" inject --story AAA-S1 --phase
  [ "$status" -ne 0 ]
  assert_surface_implemented "$output"
  printf '%s\n' "$output" | grep -q -- '--phase requires a value'
  cmp "$YAML.pre" "$YAML"
}

@test "inject rejects an invalid phase before appending — no row and no totals change (AC1)" {
  seed_story AAA-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]

  local before_total
  before_total="$(grep '^total_points:' "$YAML")"

  run bash "$CANONICAL" inject --story AAA-S1 --phase abc
  [ "$status" -ne 0 ]
  assert_phase_rejected "$output" "abc"

  # The row must be entirely absent — a validator that ran only after the
  # append would leave a row behind with the totals already bumped.
  run grep -c 'AAA-S1' "$YAML"
  [ "$output" = "0" ]
  local after_total
  after_total="$(grep '^total_points:' "$YAML")"
  [ "$before_total" = "$after_total" ]
}

# ---------------------------------------------------------------------------
# AC2 — the net-new writer verb
# ---------------------------------------------------------------------------

@test "set-phase sets a phase on an existing phase-less row (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1

  run bash "$CANONICAL" set-phase --story CCC-S1 --phase 3
  [ "$status" -eq 0 ]

  run entry_block CCC-S1
  printf '%s\n' "$output" | grep -q '^    phase: 3$'
  [ "$(entry_phase_count CCC-S1)" = "1" ]
}

@test "set-phase changes an existing phase value in place (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1:1

  run bash "$CANONICAL" set-phase --story CCC-S1 --phase 4
  [ "$status" -eq 0 ]

  run entry_block CCC-S1
  printf '%s\n' "$output" | grep -q '^    phase: 4$'
  # Entry-scoped count: a rewriter that appended instead of replacing would
  # leave two phase lines on this one row.
  [ "$(entry_phase_count CCC-S1)" = "1" ]
  run grep -c 'phase: 1' "$YAML"
  [ "$output" = "0" ]
}

@test "set-phase --phase \"\" clears the phase and omitting --phase is a usage error (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1:2

  run bash "$CANONICAL" set-phase --story CCC-S1 --phase ""
  [ "$status" -eq 0 ]
  [ "$(entry_phase_count CCC-S1)" = "0" ]

  # Clearing must be deliberate, never the residue of a forgotten flag — and
  # the omission must surface as a usage DIAGNOSTIC, not an unbound-variable
  # crash, so a non-zero exit alone is not sufficient evidence here.
  seed_yaml_with_rows sprint-99 CCC-S1:2
  run bash "$CANONICAL" set-phase --story CCC-S1
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- '--phase'
  # A `grep && return 1` line would itself fail under set -e when the pattern
  # is absent (the passing case), so assert the absence positively instead.
  case "$output" in
    *"unbound variable"*)
      printf 'set-phase crashed on an unset flag-seen variable instead of emitting a usage diagnostic: %s\n' "$output" >&2
      return 1 ;;
  esac
  [ "$(entry_phase_count CCC-S1)" = "1" ]
}

@test "set-phase is a no-op when setting the value already present (AC-EC2)" {
  local script
  for script in "$CANONICAL" "$WRAPPER"; do
    seed_yaml_with_rows sprint-99 CCC-S1:2
    snapshot_yaml

    run bash "$script" set-phase --story CCC-S1 --phase 2
    [ "$status" -eq 0 ]
    # A rewriter that re-emitted an identical row would be invisible to cmp,
    # so the stdout no-op marker is the real mutation detector here.
    printf '%s\n' "$output" | grep -q 'no-op'
    cmp "$YAML.pre" "$YAML"
  done
}

@test "set-phase is a no-op when clearing a row that has no phase (AC-EC2)" {
  local script
  for script in "$CANONICAL" "$WRAPPER"; do
    seed_yaml_with_rows sprint-99 CCC-S1
    snapshot_yaml

    # Must not be a "field not found" error — clearing an absent field is a
    # legitimate idempotent call.
    run bash "$script" set-phase --story CCC-S1 --phase ""
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'no-op'
    cmp "$YAML.pre" "$YAML"
  done
}

@test "set-phase writes when a SIBLING row already carries the requested value (AC-EC2)" {
  # The idempotency decision is driven by reading the TARGET row's current
  # phase. A reader that returns the first phase found in the FILE makes this
  # a false match: the requested value equals the sibling's, so a legitimate
  # write is routed into the no-op branch and silently discarded at exit 0 —
  # a lost write reported as success.
  #
  # Every other phase-carrying fixture in this suite is single-row, where
  # "first phase in the file" and "this row's phase" are the same string and
  # the two behaviours are indistinguishable. This fixture separates them.
  seed_yaml_with_rows sprint-99 CCC-S1:2 CCC-S2
  [ "$(entry_phase_count CCC-S1)" = "1" ]
  [ "$(entry_phase_count CCC-S2)" = "0" ]

  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 2
  [ "$status" -eq 0 ]
  assert_surface_implemented "$output"

  # The write must actually land on the target row.
  [ "$(entry_phase_count CCC-S2)" = "1" ]
  run entry_block CCC-S2
  printf '%s\n' "$output" | grep -q '^    phase: 2$'
  # And the sibling must be untouched.
  [ "$(entry_phase_count CCC-S1)" = "1" ]
}

@test "set-phase reports no-op from the TARGET row's value, not a sibling's (AC-EC2)" {
  # The mirror direction. Here the target already holds the requested value
  # and the sibling holds a different one, so a reader scoped to the wrong
  # row would miss the real match and perform a pointless rewrite while
  # reporting a write that changed nothing.
  seed_yaml_with_rows sprint-99 CCC-S1:5 CCC-S2:2
  snapshot_yaml

  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 2
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no-op'
  cmp "$YAML.pre" "$YAML"

  # Clearing a phase-less target must also read the target, not the sibling.
  seed_yaml_with_rows sprint-99 CCC-S1:5 CCC-S2
  snapshot_yaml
  run bash "$CANONICAL" set-phase --story CCC-S2 --phase ""
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no-op'
  cmp "$YAML.pre" "$YAML"
}

@test "the phase reader is scoped to the target row on a three-row yaml (AC2)" {
  # read_yaml_story_phase is not reachable by sourcing the script (loading it
  # runs main), so its scoping is pinned through the observable behaviour it
  # drives: the idempotency decision in do_set_phase_locked. On a three-row
  # yaml each row holds a DIFFERENT value, so a reader that returns the first
  # phase in the file cannot agree with a reader scoped to the target for
  # more than one of the three cases.
  seed_yaml_with_rows sprint-99 CCC-S1:7 CCC-S2:3 CCC-S3:5

  # Middle row: no-op only if its own 3 was read (a file-first reader sees 7).
  snapshot_yaml
  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 3
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no-op'
  cmp "$YAML.pre" "$YAML"

  # Last row: same probe, different value, so no single wrong read satisfies
  # both this assertion and the one above.
  snapshot_yaml
  run bash "$CANONICAL" set-phase --story CCC-S3 --phase 5
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no-op'
  cmp "$YAML.pre" "$YAML"

  # And the first row's value must NOT be reported for a row that lacks one.
  seed_yaml_with_rows sprint-99 CCC-S1:7 CCC-S3
  run bash "$CANONICAL" set-phase --story CCC-S3 --phase 7
  [ "$status" -eq 0 ]
  assert_surface_implemented "$output"
  [ "$(entry_phase_count CCC-S3)" = "1" ]
  [ "$(entry_phase_count CCC-S1)" = "1" ]
}

@test "set-phase on a story key absent from the yaml fails closed with a diagnostic (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1
  snapshot_yaml

  run bash "$CANONICAL" set-phase --story NOPE-S9 --phase 1
  [ "$status" -ne 0 ]
  assert_surface_implemented "$output"
  printf '%s\n' "$output" | grep -q 'NOPE-S9'
  cmp "$YAML.pre" "$YAML"
}

@test "set-phase touches only the target row — sibling rows are byte-unchanged (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1 CCC-S2 CCC-S3

  local before_s1 before_s3
  before_s1="$(entry_block CCC-S1)"
  before_s3="$(entry_block CCC-S3)"

  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 7
  [ "$status" -eq 0 ]

  # Lost in_entry scoping would patch the first row, or every row.
  [ "$(entry_block CCC-S1)" = "$before_s1" ]
  [ "$(entry_block CCC-S3)" = "$before_s3" ]
  [ "$(entry_phase_count CCC-S1)" = "0" ]
  [ "$(entry_phase_count CCC-S3)" = "0" ]
  [ "$(entry_phase_count CCC-S2)" = "1" ]
}

@test "set-phase appends to a target row that is the last entry running to EOF (AC2)" {
  # A sprint yaml conventionally ends with its stories list, so the target
  # entry reaching neither a following entry header nor a following top-level
  # key is the COMMON case — the append must be flushed at end of input.
  seed_yaml_with_rows sprint-99 CCC-S1 CCC-S2
  [ "$(tail -n 1 "$YAML")" = '    updated: "2026-01-01"' ]

  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 5
  [ "$status" -eq 0 ]

  [ "$(tail -n 1 "$YAML")" = "    phase: 5" ]
  # And attached to the RIGHT key.
  [ "$(entry_phase_count CCC-S2)" = "1" ]
  [ "$(entry_phase_count CCC-S1)" = "0" ]
}

@test "set-phase on a middle row emits phase before the next entry header (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1 CCC-S2 CCC-S3

  run bash "$CANONICAL" set-phase --story CCC-S2 --phase 6
  [ "$status" -eq 0 ]

  # Flushing after the next header's `print raw` would attach the phase to
  # CCC-S3 instead. Compare line numbers rather than trusting entry scoping
  # alone, so a broken flush order is caught positionally.
  local phase_line next_key_line
  phase_line="$(grep -n '^    phase: 6$' "$YAML" | head -1 | cut -d: -f1)"
  next_key_line="$(grep -n '^  - key: "CCC-S3"$' "$YAML" | head -1 | cut -d: -f1)"
  [ -n "$phase_line" ]
  [ -n "$next_key_line" ]
  [ "$phase_line" -lt "$next_key_line" ]
  [ "$(entry_phase_count CCC-S2)" = "1" ]
  [ "$(entry_phase_count CCC-S3)" = "0" ]
}

@test "set-phase writes only the phase line — status, points and updated are byte-unchanged (AC2)" {
  seed_yaml_with_rows sprint-99 CCC-S1

  local before
  before="$(entry_block CCC-S1)"

  run bash "$CANONICAL" set-phase --story CCC-S1 --phase 8
  [ "$status" -eq 0 ]

  # Everything except the added phase line must be byte-for-byte the original,
  # so a rewriter that re-emits the entry from scratch fails.
  local after_without_phase
  after_without_phase="$(entry_block CCC-S1 | grep -v '^    phase: ')"
  [ "$after_without_phase" = "$before" ]
}

# ---------------------------------------------------------------------------
# AC3 — preservation across the row-rewriting paths
# ---------------------------------------------------------------------------

@test "phase survives inject then transition then reconcile, asserted after each step (AC3)" {
  seed_story DDD-S1
  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]

  run bash "$CANONICAL" inject --story DDD-S1 --phase 2
  [ "$status" -eq 0 ]
  run entry_block DDD-S1
  printf '%s\n' "$output" | grep -q '^    phase: 2$'

  # Single-field patchers must pass unknown lines through verbatim.
  run bash "$CANONICAL" transition --story DDD-S1 --to in-progress
  [ "$status" -eq 0 ]
  run entry_block DDD-S1
  printf '%s\n' "$output" | grep -q '^    phase: 2$'
  printf '%s\n' "$output" | grep -q 'status: "in-progress"'

  run bash "$CANONICAL" reconcile
  [ "$status" -eq 0 ]
  run entry_block DDD-S1
  printf '%s\n' "$output" | grep -q '^    phase: 2$'
  [ "$(entry_phase_count DDD-S1)" = "1" ]
}

@test "set-story-sprint binds an unbound story and writes nothing to the yaml (AC3)" {
  # set-story-sprint hard-refuses a story already bound to a sprint, and an
  # injected story necessarily has one — so an unbound story before any inject
  # is the ONLY state in which this verb is reachable.
  seed_story DDD-S2 null
  seed_yaml_with_rows sprint-99 CCC-S1:2
  snapshot_yaml

  run bash "$CANONICAL" set-story-sprint --story DDD-S2 --sprint sprint-99
  [ "$status" -eq 0 ]

  # Its only write target is the story file's own sprint_id line.
  run grep -q 'sprint_id: "sprint-99"' "$ART/DDD-S2-x.md"
  [ "$status" -eq 0 ]
  # The seeded row still carries its phase, untouched.
  [ "$(entry_phase_count CCC-S1)" = "1" ]
  cmp "$YAML.pre" "$YAML"

  # Positive control: this preservation claim only has content once the phase
  # surface exists, so drive the real writer in the same test.
  run bash "$CANONICAL" set-phase --story CCC-S1 --phase 4
  assert_surface_implemented "$output"
  [ "$status" -eq 0 ]
}

@test "rollover clears phase when the row is already present in the active yaml (AC-EC1)" {
  # The reproduced shape: one yaml, the row already present CARRYING a phase.
  # Inject's idempotency short-circuit means the append is never reached, so a
  # reset that relies on the append path being taken silently CARRIES the
  # stale phase — the opposite of the decided rule.
  seed_story EEE-S1 '"sprint-41"'
  seed_yaml_with_rows sprint-42 EEE-S1:2
  [ "$(entry_phase_count EEE-S1)" = "1" ]

  run bash "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys EEE-S1
  [ "$status" -eq 0 ]

  [ "$(entry_phase_count EEE-S1)" = "0" ]
  run grep -q 'sprint_id: "sprint-42"' "$ART/EEE-S1-x.md"
  [ "$status" -eq 0 ]
}

@test "rollover clears phase when the row is absent from the target yaml (AC-EC1)" {
  seed_story EEE-S2 '"sprint-41"'
  # The empty-stories shape: the append branch runs and must omit the field.
  cat > "$YAML" <<'EOF'
sprint_id: "sprint-42"
status: active
total_points: 0
goals: []
items: []
stories: []
EOF

  run bash "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys EEE-S2
  [ "$status" -eq 0 ]

  run grep -c 'EEE-S2' "$YAML"
  [ "$output" != "0" ]
  [ "$(entry_phase_count EEE-S2)" = "0" ]

  # Positive control: prove the row COULD have carried a phase, so the
  # assertion above is about rollover's reset rather than about the field
  # being unimplementable.
  run bash "$CANONICAL" set-phase --story EEE-S2 --phase 3
  assert_surface_implemented "$output"
  [ "$status" -eq 0 ]
  [ "$(entry_phase_count EEE-S2)" = "1" ]
}

# ---------------------------------------------------------------------------
# AC4 — backward compatibility for phase-less sprints
# ---------------------------------------------------------------------------

@test "a phase-less sprint yaml is byte-identical to the pre-phase baseline (AC4)" {
  # The golden was generated from the PRE-CHANGE script, so it cannot be
  # tautological. `updated:` is clock-dependent and is normalised identically
  # on both sides — no literal date is pinned.
  local k
  for k in AAA-S1 AAA-S2 AAA-S3; do
    cat > "$ART/${k}-x.md" <<EOF
---
template: 'story'
key: "$k"
title: "Baseline story $k"
status: ready-for-dev
sprint_id: "sprint-99"
points: 3
risk: "medium"
---

# Story: Baseline story $k
EOF
  done

  run bash "$CANONICAL" init --sprint-id sprint-99
  [ "$status" -eq 0 ]
  for k in AAA-S1 AAA-S2 AAA-S3; do
    run bash "$CANONICAL" inject --story "$k"
    [ "$status" -eq 0 ]
  done

  sed -E 's/^([[:space:]]*updated: ).*/\1"<DATE>"/' "$YAML" > "$TEST_TMP/live-normalised.yaml"
  diff -u "$FIXTURES/phase-less-baseline.yaml" "$TEST_TMP/live-normalised.yaml"

  # Positive control: byte-identity for a phase-less sprint is only a
  # meaningful backward-compatibility claim once phases are supported at all.
  run bash "$CANONICAL" set-phase --story AAA-S1 --phase 2
  assert_surface_implemented "$output"
  [ "$status" -eq 0 ]
}
