#!/usr/bin/env bats
# test-policy-schema.bats — schema-level validation tests for test_policy config section
#
# Covers: per-trigger scope rules schema validation, absent-section backward
# compatibility, referential integrity of stack names, and structural conventions.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Minimal valid base config (satisfies required keys)
  BASE_REQUIRED='
project_root: /tmp/test-project
project_path: /tmp/test-project/src
memory_path: /tmp/test-project/.gaia/memory
checkpoint_path: /tmp/test-project/.gaia/checkpoints
installed_path: /tmp/test-project/.gaia/installed
framework_version: "1.197.0"
date: "2026-06-17"
'

  STACKS_SECTION='
stacks:
  - name: stack-a
    language: bash
    paths: ["src/a"]
  - name: stack-b
    language: python
    paths: ["src/b"]
'
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _write_config — write a complete config YAML from base + stacks + extra
_write_config() {
  local extra="$1"
  local out="$TEST_TMP/config.yaml"
  printf '%s\n%s\n%s\n' "$BASE_REQUIRED" "$STACKS_SECTION" "$extra" > "$out"
  printf '%s' "$out"
}

# _write_config_no_stacks — write config without stacks section
_write_config_no_stacks() {
  local extra="$1"
  local out="$TEST_TMP/config.yaml"
  printf '%s\n%s\n' "$BASE_REQUIRED" "$extra" > "$out"
  printf '%s' "$out"
}

# _run_validate — run validate-project-config.sh and capture output+stderr
_run_validate() {
  local cfg="$1"
  run "$SCRIPTS_DIR/validate-project-config.sh" "$cfg"
}

# ---------------------------------------------------------------------------
# Test 1: valid triggers with include_stacks passes schema validation
# ---------------------------------------------------------------------------

@test "valid test_policy with triggers.pr.include_stacks passes schema validation" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    pr:
      include_stacks:
        - stack-a
')"
  _run_validate "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: valid triggers with exclude_tags passes schema validation
# ---------------------------------------------------------------------------

@test "valid test_policy with triggers.schedule.exclude_tags passes schema validation" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    schedule:
      exclude_tags:
        - slow
        - nightly
')"
  _run_validate "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: mutual exclusion rejects both include and exclude stacks on same trigger
# ---------------------------------------------------------------------------

@test "test_policy rejects both include_stacks and exclude_stacks on same trigger" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    pr:
      include_stacks:
        - stack-a
      exclude_stacks:
        - stack-b
')"
  _run_validate "$cfg"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4: unknown trigger key rejected by schema
# ---------------------------------------------------------------------------

@test "test_policy rejects unknown trigger key" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    bogus_trigger:
      include_stacks:
        - stack-a
')"
  _run_validate "$cfg"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 5: absent test_policy section passes schema validation
# ---------------------------------------------------------------------------

@test "config without test_policy section passes schema validation" {
  local cfg
  cfg="$(_write_config '')"
  _run_validate "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Test 6: absent test_policy produces no test_policy errors
# ---------------------------------------------------------------------------

@test "absent test_policy produces no test_policy related errors" {
  local cfg
  cfg="$(_write_config '')"
  _run_validate "$cfg"
  [ "$status" -eq 0 ]
  # Negative: stderr+stdout must NOT mention test_policy in any error
  [[ "$output" != *"test_policy"* ]]
}

# ---------------------------------------------------------------------------
# Test 7: valid stack name in include_stacks passes referential check
# ---------------------------------------------------------------------------

@test "include_stacks referencing declared stack passes referential check" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    pr:
      include_stacks:
        - stack-a
        - stack-b
')"
  _run_validate "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Test 8: non-existent stack in include_stacks fails with JSONPath location
# ---------------------------------------------------------------------------

@test "include_stacks with non-existent stack fails with JSONPath location" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    pr:
      include_stacks:
        - stack-a
        - nonexistent-svc
')"
  _run_validate "$cfg"
  [ "$status" -eq 1 ]
  # Must contain FAIL with JSONPath pointing to the offending entry
  [[ "$output" == *"FAIL"* ]] || [[ "${lines[*]}" == *"FAIL"* ]]
  # Check stderr for the JSONPath and stack name
  run bash -c "'$SCRIPTS_DIR/validate-project-config.sh' '$cfg' 2>&1"
  [[ "$output" == *'$.test_policy.triggers.pr.include_stacks'* ]]
  [[ "$output" == *"nonexistent-svc"* ]]
}

# ---------------------------------------------------------------------------
# Test 9: non-existent stack in exclude_stacks fails with JSONPath location
# ---------------------------------------------------------------------------

@test "exclude_stacks with non-existent stack fails with JSONPath location" {
  local cfg
  cfg="$(_write_config '
test_policy:
  triggers:
    push:
      exclude_stacks:
        - ghost
')"
  _run_validate "$cfg"
  [ "$status" -eq 1 ]
  run bash -c "'$SCRIPTS_DIR/validate-project-config.sh' '$cfg' 2>&1"
  [[ "$output" == *'$.test_policy.triggers.push.exclude_stacks'* ]]
  [[ "$output" == *"ghost"* ]]
}

# ---------------------------------------------------------------------------
# Test 10: extra unknown key in test_policy rejected
# ---------------------------------------------------------------------------

@test "test_policy rejects unknown top-level key" {
  local cfg
  cfg="$(_write_config '
test_policy:
  unknown_field: true
')"
  _run_validate "$cfg"
  [ "$status" -eq 1 ]
}
