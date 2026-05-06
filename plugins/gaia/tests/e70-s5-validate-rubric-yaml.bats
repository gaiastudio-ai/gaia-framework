#!/usr/bin/env bats
# e70-s5-validate-rubric-yaml.bats — E70-S5 AC6, AC7
#
# Verifies that validate-rubric.sh, used by /gaia-validate-rubric:
#   - Accepts JSON rubric files and emits PASS / FAIL (existing E68-S2 behavior).
#   - Accepts YAML rubric files (.yaml / .yml extension) and validates them
#     identically to their JSON equivalents (AC7).
#   - Emits a clear file-not-found error when the rubric path does not exist.
#
# AC7 requires either yq OR python3+PyYAML to convert YAML to JSON. Tests
# that depend on YAML are skipped when neither is available, with a clear
# skip message.
#
# Story: E70-S5  (TC-RSV2-RUBRIC-VAL-01, TC-RSV2-RUBRIC-VAL-02)

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"

setup() { common_setup; }
teardown() { common_teardown; }

_yaml_supported() {
  command -v yq >/dev/null 2>&1 && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import yaml' >/dev/null 2>&1 && return 0
  fi
  return 1
}

_write_valid_json_rubric() {
  cat >"$1" <<'JSON'
{
  "schema_version": "1.0",
  "skill": "code",
  "severity_rules": [
    {
      "id": "code-fixture-001",
      "category": "fixture",
      "pattern": "fixture-pattern",
      "severity": "Medium",
      "description": "Fixture rule for E70-S5 tests."
    }
  ]
}
JSON
}

_write_valid_yaml_rubric() {
  cat >"$1" <<'YAML'
schema_version: "1.0"
skill: code
severity_rules:
  - id: code-fixture-001
    category: fixture
    pattern: fixture-pattern
    severity: Medium
    description: Fixture rule for E70-S5 tests.
YAML
}

_write_invalid_yaml_rubric() {
  # Missing required top-level field 'severity_rules'.
  cat >"$1" <<'YAML'
schema_version: "1.0"
skill: code
YAML
}

@test "TS-5 / AC6, AC7: validate-rubric.sh PASSes a conforming JSON rubric" {
  local f="$TEST_TMP/rubric.json"
  _write_valid_json_rubric "$f"
  run "$VALIDATOR" "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

@test "TS-6 / AC7: validate-rubric.sh PASSes a conforming YAML rubric" {
  _yaml_supported || skip "no yaml->json converter (yq or python3+PyYAML) available"
  local f="$TEST_TMP/rubric.yaml"
  _write_valid_yaml_rubric "$f"
  run "$VALIDATOR" "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

@test "TS-7 / AC6: validate-rubric.sh FAILs a YAML rubric missing required fields" {
  _yaml_supported || skip "no yaml->json converter (yq or python3+PyYAML) available"
  local f="$TEST_TMP/rubric-bad.yaml"
  _write_invalid_yaml_rubric "$f"
  run "$VALIDATOR" "$f"
  [ "$status" -ne 0 ]
  # The script emits "FAIL: <path> ..." on stderr.
  echo "$output" | grep -qi "fail"
  # The missing-field violation should mention severity_rules.
  echo "$output" | grep -qi "severity_rules"
}

@test "AC6: validate-rubric.sh emits file-not-found for a non-existent path" {
  run "$VALIDATOR" "$TEST_TMP/does-not-exist.yaml"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not found"
}

@test "AC7: .yml extension is accepted as YAML" {
  _yaml_supported || skip "no yaml->json converter (yq or python3+PyYAML) available"
  local f="$TEST_TMP/rubric.yml"
  _write_valid_yaml_rubric "$f"
  run "$VALIDATOR" "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}
