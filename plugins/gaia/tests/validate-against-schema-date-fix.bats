#!/usr/bin/env bats
# validate-against-schema-date-fix.bats — AF-2026-05-21-3
#
# Asserts the fix for: validate-against-schema.sh crashes on an
# unquoted top-level `date: YYYY-MM-DD` line emitted by generate-config.sh.
# Root cause: yaml.safe_load parses the date into a Python datetime.date
# object; json.dumps(...) raises TypeError because date is not JSON-
# serializable. Fix: json.dumps(..., default=str) coerces date to ISO-8601.
#
# Also asserts the SKILL.md error-text polish (--full removed from the
# re-init refusal message per AC11).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/../skills/gaia-init/scripts/validate-against-schema.sh"
  SKILL_MD="$SCRIPTS_DIR/../skills/gaia-init/SKILL.md"
}

teardown() {
  common_teardown
}

@test "#1: validate-against-schema.sh yaml_to_json passes default=str" {
  # The fix is the addition of `default=str` to the json.dumps() call.
  # Assert the literal token is present in the script body.
  run grep -F 'default=str' "$SCRIPT"
  [ "$status" -eq 0 ]
  # And specifically inside the json.dumps call (not elsewhere)
  run grep -E 'json\.dumps\(yaml\.safe_load\(sys\.stdin\),[[:space:]]*default=str\)' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "#1: python3 round-trip of a config with date: line does NOT crash" {
  # Reproduces the exact failure mode generate-config.sh produces.
  # Skip when PyYAML is absent (matches the script's `import yaml` guard).
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not installed"

  local fixture="$TEST_TMP/cfg.yaml"
  cat > "$fixture" << 'EOF'
project_name: "test"
date: 2026-05-21
schema_version: "2.0.0"
config_phase: full
EOF
  # Run the actual yaml_to_json transform that the script uses.
  run python3 -c '
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
' < "$fixture"
  [ "$status" -eq 0 ]
  # JSON output contains the date as an ISO-8601 string.
  [[ "$output" == *'"date": "2026-05-21"'* ]]
}

@test "#1: regression — without default=str the same fixture crashes" {
  # Document the pre-fix failure mode so this test would have caught it.
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not installed"
  local fixture="$TEST_TMP/cfg.yaml"
  printf 'date: 2026-05-21\n' > "$fixture"
  run python3 -c '
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin)))
' < "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not JSON serializable"* ]]
}

@test "#2: SKILL.md refusal message no longer steers user toward --full" {
  # The misleading `--full to reinitialize` guidance MUST NOT appear in
  # the canonical refusal error since AC11 says --full does not override
  # the re-init guard.
  run grep -F 'use --full to reinitialize' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "#2: SKILL.md refusal message points at /gaia-config-* and /gaia-brownfield" {
  run grep -F 'use /gaia-config-* to edit' "$SKILL_MD"
  [ "$status" -eq 0 ]
  run grep -F '/gaia-brownfield' "$SKILL_MD"
  [ "$status" -eq 0 ]
}
