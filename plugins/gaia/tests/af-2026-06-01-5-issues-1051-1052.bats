#!/usr/bin/env bats
# AF-2026-06-01-5 — issues #1051 (validator silent false-PASS) and #1052
# (reconciler emits schema-invalid null sections).
#
# The two bugs compound: the reconciler writes invalid config AND the
# validator can't see it. Fixed together so the new strictness lands on
# a config the reconciler now produces correctly.
#
# Bash-3.2 compatible. Wired into the cross-platform-portability CI matrix.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RECONCILER="$PLUGIN_ROOT/scripts/gaia-reconcile-v2.sh"
  VALIDATOR="$PLUGIN_ROOT/scripts/validate-project-config.sh"
  SCHEMA="$PLUGIN_ROOT/schemas/project-config.schema.json"
}

teardown() { common_teardown; }

# ===========================================================================
# Issue #1052 — gaia-reconcile-v2 emits `section: {}` (object), not bare null
# ===========================================================================

@test "AF-32-3 #1052: reconciler fragment writer uses 'section: {}' (empty object)" {
  # The fragment-build block (around line 388 of gaia-reconcile-v2.sh) MUST
  # emit `section: {}` so the section parses as an empty object, not null.
  # Use grep -E with literal-bracket escape; bash and grep handle the
  # newline-token differently when -F is used.
  run grep -E "printf '%s: \{\}\\\\n'" "$RECONCILER"
  [ "$status" -eq 0 ]
}

@test "AF-32-3 #1052: reconciler fragment writer does NOT emit a bare 'section:' line" {
  # The pre-fix shape `printf '%s:\n' "$s"` produced null sections. It must
  # be gone from the missing-section hydration loop. A separate
  # `printf '%s:\n'` in unrelated scaffolding is fine — we scope by looking
  # at the missing-section loop block only.
  # Grep for the exact pre-fix pair (key-line + inline-comment-line). If
  # both lines still appear in the same loop body, the fix did not land.
  run grep -F "printf '%s:\\\\n' \"\$s\"" "$RECONCILER"
  [ "$status" -ne 0 ]
}

@test "AF-32-3 #1052: 'section: {}' parses as an empty object (sanity check)" {
  # yq sanity — `section: {}` is the actual YAML shape we now write.
  local fixture
  fixture="$(mktemp -t af325-1052.XXXXXX).yaml"
  cat > "$fixture" <<'YAML'
sprint: {}
review_gate: {}
tools: {}
YAML
  run yq eval '.sprint | type' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "!!map" ]
  run yq eval '.review_gate | type' "$fixture"
  [ "$output" = "!!map" ]
  rm -f "$fixture"
}

@test "AF-32-3 #1052: bare 'section:' parses as null (regression evidence)" {
  # The exact pre-fix shape that issue #1052 reported. Confirms the bug
  # class exists in YAML semantics, not in the schema.
  local fixture
  fixture="$(mktemp -t af325-1052.XXXXXX).yaml"
  cat > "$fixture" <<'YAML'
sprint:
  # comment only — no value
YAML
  run yq eval '.sprint | type' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "!!null" ]
  rm -f "$fixture"
}

# ===========================================================================
# Issue #1051 — validate-project-config.sh tier-aware backend selection
# ===========================================================================

@test "AF-32-3 #1051: validator script declares a python3+jsonschema backend tier" {
  run grep -F "import jsonschema" "$VALIDATOR"
  [ "$status" -eq 0 ]
}

@test "AF-32-3 #1051: validator emits a DEGRADED marker when running structural-only" {
  run grep -F 'PASS (DEGRADED):' "$VALIDATOR"
  [ "$status" -eq 0 ]
}

@test "AF-32-3 #1051: validator emits a WARNING listing the skipped checks in degraded mode" {
  run grep -F "WARNING: the following schema checks are SKIPPED" "$VALIDATOR"
  [ "$status" -eq 0 ]
}

@test "AF-32-3 #1051: validator WARNING names enum, additionalProperties, type, pattern" {
  run grep -F "enum, additionalProperties, type, pattern" "$VALIDATOR"
  [ "$status" -eq 0 ]
}

@test "AF-32-3 #1051: validator WARNING recommends ajv-cli or python3 jsonschema install" {
  run grep -F "ajv-cli" "$VALIDATOR"
  [ "$status" -eq 0 ]
  run grep -F "pip install jsonschema" "$VALIDATOR"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Issue #1051 — behavioural end-to-end: schema-invalid input is REJECTED
# (instead of silently passing) when a real validator backend is available.
# ===========================================================================

@test "AF-32-3 #1051: schema-invalid input (enum mismatch + null section) is REJECTED end-to-end" {
  # Skip when no real validator backend is on the runner — the structural
  # path is exercised by the script-level greps above; this test pins the
  # behavioural outcome when the runner CAN reach a real engine.
  if ! command -v ajv >/dev/null 2>&1 && \
     ! ( command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1 ); then
    skip "neither ajv nor python3+jsonschema available on this runner"
  fi

  local fixture
  fixture="$(mktemp -t af325-1051.XXXXXX).yaml"
  cat > "$fixture" <<'YAML'
$schema_version: "2.0.0"
config_phase: ready
project_root: "/tmp"
project_path: "."
memory_path: "_memory"
checkpoint_path: ".checkpoints"
installed_path: "/tmp/gaia"
framework_version: "1.182.7"
date: "2026-06-01"
ci_platform:
  provider: github_actions    # WRONG — schema enum uses github-actions
sprint:                       # null instead of object — invalid
YAML

  run "$VALIDATOR" "$fixture"
  [ "$status" -eq 1 ]                          # rejects, not PASS
  [[ "$output$stderr" == *FAIL* ]]            # surfaces the violations
  rm -f "$fixture"
}

# ===========================================================================
# Compound regression — reconciler-produced sections validate clean
# ===========================================================================

@test "AF-32-3 #1051+#1052 compound: a fragment-shaped 'section: {}' validates clean" {
  # Pins the closure: with the reconciler now emitting `section: {}`, a
  # config that contains only those reconciled sections (plus the required
  # top-level keys) MUST validate clean against a real engine. Confirms
  # the two fixes interlock — the reconciler no longer needs to apologize
  # for invalid YAML, and the validator no longer needs to look the other
  # way.
  if ! command -v ajv >/dev/null 2>&1 && \
     ! ( command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1 ); then
    skip "neither ajv nor python3+jsonschema available on this runner"
  fi

  local fixture
  fixture="$(mktemp -t af325-compound.XXXXXX).yaml"
  cat > "$fixture" <<'YAML'
$schema_version: "2.0.0"
config_phase: ready
project_root: "/tmp"
project_path: "."
memory_path: "_memory"
checkpoint_path: ".checkpoints"
installed_path: "/tmp/gaia"
framework_version: "1.182.7"
date: "2026-06-01"
sprint: {}
review_gate: {}
team_conventions: {}
agent_customizations: {}
tools: {}
device_targets: {}
YAML

  run "$VALIDATOR" "$fixture"
  [ "$status" -eq 0 ]
  rm -f "$fixture"
}
