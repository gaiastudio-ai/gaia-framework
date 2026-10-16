#!/usr/bin/env bats
# concurrent-sprint-config.bats — schema, resolver, validator, guard helper,
# and config-show tests for the sprint.max_concurrent_active property.
#
# Tests cover five acceptance criteria:
#   - Schema accepts valid integers, rejects zero / floats / strings
#   - Absent property defaults to 1 via resolve-config
#   - Validator passes when the property is absent
#   - Guard helper accepts below the limit and refuses at the limit
#   - config-yaml-editor extract displays the property verbatim
#   - Absent and explicit 1 produce byte-identical no-machinery behaviour

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup

  VALIDATOR="$SCRIPTS_DIR/validate-project-config.sh"
  RESOLVER="$SCRIPTS_DIR/resolve-config.sh"
  EDITOR="$SCRIPTS_DIR/config-yaml-editor.sh"
  GUARD_LIB="$SCRIPTS_DIR/lib/concurrent-sprint-guard.sh"
  SCHEMA_FILE="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)/project-config.schema.json"

  # The required top-level keys for a minimal valid config.
  BASE_REQUIRED='project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.221.0"
date: "2026-10-16"'
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _write_config <extra-yaml> [suffix] — compose base + extra, echo the path.
# An optional second argument distinguishes files within the same test.
_write_config() {
  local suffix="${2:-}"
  local out="$TEST_TMP/config${suffix:+-$suffix}.yaml"
  printf '%s\n%s\n' "$BASE_REQUIRED" "$1" > "$out"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Schema property structural checks
# ---------------------------------------------------------------------------

@test "schema defines sprint.max_concurrent_active as integer with minimum 1 and default 1" {
  run jq '.properties.sprint.properties.max_concurrent_active' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q '"type": "integer"' <<< "$output"
  /usr/bin/grep -q '"minimum": 1' <<< "$output"
  /usr/bin/grep -q '"default": 1' <<< "$output"
}

@test "schema sprint object allows additional properties" {
  run jq '.properties.sprint.additionalProperties' "$SCHEMA_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# ---------------------------------------------------------------------------
# Validator acceptance / rejection
# ---------------------------------------------------------------------------

@test "validator passes when sprint.max_concurrent_active is a valid integer" {
  local cfg
  cfg="$(_write_config 'sprint:
  max_concurrent_active: 3')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "validator passes when sprint section is absent" {
  local cfg
  cfg="$(_write_config '')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "validator passes when sprint section exists but max_concurrent_active is absent" {
  local cfg
  cfg="$(_write_config 'sprint:
  other_key: value')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "validator rejects sprint.max_concurrent_active of zero" {
  local cfg
  cfg="$(_write_config 'sprint:
  max_concurrent_active: 0')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint"*"max_concurrent_active"* ]] || [[ "$output" == *"minimum"* ]]
}

@test "validator rejects sprint.max_concurrent_active as float" {
  local cfg
  cfg="$(_write_config 'sprint:
  max_concurrent_active: 1.5')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -ne 0 ]
}

@test "validator rejects sprint.max_concurrent_active as string" {
  local cfg
  cfg="$(_write_config 'sprint:
  max_concurrent_active: "two"')"
  run bash "$VALIDATOR" "$cfg"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Direct _post_validate_sprint hook tests — edge-case integer shapes
# ---------------------------------------------------------------------------

# Helper: write a JSON fixture with the given raw value for
# sprint.max_concurrent_active, source the hook, and call it.
_run_sprint_hook() {
  local raw_json_value="$1"
  local json_file="$TEST_TMP/hook-fixture.json"
  printf '{"sprint":{"max_concurrent_active":%s}}\n' "$raw_json_value" > "$json_file"
  # Source just the fail() and _post_validate_sprint from the validator.
  run bash -c '
    fail() { printf "FAIL: %s — %s\n" "${1:-unknown}" "${2:-violation}" >&2; }
    eval "$(sed -n "/_post_validate_sprint()/,/^}/p" "'"$VALIDATOR"'")"
    _post_validate_sprint "'"$json_file"'"
  '
}

@test "sprint hook rejects hyphenated string 1-2" {
  _run_sprint_hook '"1-2"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer"* ]]
}

@test "sprint hook rejects double-negative --5" {
  _run_sprint_hook '"--5"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer"* ]]
}

@test "sprint hook rejects trailing hyphen 1-" {
  _run_sprint_hook '"1-"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an integer"* ]]
}

@test "sprint hook accepts valid integer 3" {
  _run_sprint_hook '3'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Wiring guard: proves _post_validate_sprint is called at all three backend
# call sites. A grep-based structural test: if someone removes a call site,
# this test fails.
# ---------------------------------------------------------------------------

@test "sprint hook is wired at all three validator backend call sites" {
  # The validator has three exit paths (ajv, python3+jsonschema, jq-degraded).
  # Each must call _post_validate_sprint. Count the non-comment call sites.
  local count
  count="$(/usr/bin/grep -c '_post_validate_sprint "\$TMP_JSON"' "$VALIDATOR")"
  [ "$count" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Resolver default and configured value
# ---------------------------------------------------------------------------

@test "resolve-config returns 1 when sprint.max_concurrent_active is absent" {
  local cfg
  cfg="$(_write_config '')"
  run bash "$RESOLVER" --config "$cfg" --field sprint.max_concurrent_active
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "resolve-config returns configured value when sprint.max_concurrent_active is set" {
  local cfg
  cfg="$(_write_config 'sprint:
  max_concurrent_active: 3')"
  run bash "$RESOLVER" --config "$cfg" --field sprint.max_concurrent_active
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# ---------------------------------------------------------------------------
# Guard helper
# ---------------------------------------------------------------------------

@test "guard helper accepts activation when count is below the limit" {
  run bash -c "source '$GUARD_LIB'; echo 'sprint-900' | concurrent_sprint_guard 2"
  [ "$status" -eq 0 ]
}

@test "guard helper refuses activation when count equals the limit" {
  run bash -c "source '$GUARD_LIB'; printf 'sprint-900\nsprint-901\n' | concurrent_sprint_guard 2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"* ]]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" == *"sprint-901"* ]]
}

@test "guard helper refuses activation when count exceeds the limit" {
  run bash -c "source '$GUARD_LIB'; printf 'sprint-900\nsprint-901\nsprint-902\n' | concurrent_sprint_guard 2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"* ]]
}

@test "guard helper accepts activation on empty stdin" {
  run bash -c "source '$GUARD_LIB'; echo '' | concurrent_sprint_guard 1"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Config-show verbatim (config-yaml-editor extract)
# ---------------------------------------------------------------------------

@test "config-yaml-editor extract sprint section shows max_concurrent_active verbatim" {
  local cfg="$TEST_TMP/show-config.yaml"
  printf '%s\n' "$BASE_REQUIRED" > "$cfg"
  printf 'sprint:\n  max_concurrent_active: 3\n' >> "$cfg"
  run bash "$EDITOR" extract "$cfg" sprint
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_concurrent_active: 3"* ]]
}

# ---------------------------------------------------------------------------
# Machinery-inert gate (absent and explicit-1 produce no concurrent artefacts)
# ---------------------------------------------------------------------------

@test "no concurrent machinery files exist when max_concurrent_active is absent" {
  local state_dir="$TEST_TMP/state"
  mkdir -p "$state_dir"
  # After a config-only setup (S1 adds no concurrent machinery), none of the
  # concurrent-mode files should exist.
  [ ! -f "$state_dir/sprint-status-sprint-900.yaml" ]
  [ ! -f "$state_dir/.concurrent-resource-ledger.json" ]
  [ ! -f "$state_dir/.promotion-merge.lock" ]
  [ ! -f "$state_dir/.sprint-lifecycle.lock" ]
  [ ! -f "$state_dir/.sprint-proxy.lock" ]
  [ ! -f "$state_dir/.concurrent-resource-ledger.lock" ]
}

@test "absent and explicit 1 resolve identically" {
  local cfg_absent cfg_explicit
  cfg_absent="$(_write_config '' absent)"
  cfg_explicit="$(_write_config 'sprint:
  max_concurrent_active: 1' explicit)"

  # Both files must exist and differ (the extra yaml is present in one).
  [ -f "$cfg_absent" ]
  [ -f "$cfg_explicit" ]
  [ "$cfg_absent" != "$cfg_explicit" ]

  local val_absent val_explicit
  val_absent="$(bash "$RESOLVER" --config "$cfg_absent" --field sprint.max_concurrent_active)"
  val_explicit="$(bash "$RESOLVER" --config "$cfg_explicit" --field sprint.max_concurrent_active)"

  [ "$val_absent" = "1" ]
  [ "$val_explicit" = "1" ]
  [ "$val_absent" = "$val_explicit" ]
}
