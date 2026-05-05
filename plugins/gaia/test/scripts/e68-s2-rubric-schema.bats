#!/usr/bin/env bats
# e68-s2-rubric-schema.bats — Tests for rubric.schema.json + validation helper.
#
# Story: E68-S2 — covers AC5 (schema presence), AC6 (validate-rubric PASS/FAIL).

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"

setup() {
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# ---------- AC5 ----------

@test "AC5 / TC-RSV2-RUBRIC-02: rubric.schema.json exists at canonical path" {
  [ -f "$SCHEMA" ]
}

@test "AC5: rubric.schema.json is valid JSON" {
  run jq -e . "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "AC5: rubric.schema.json declares draft-07 (or later) \$schema" {
  run jq -r '."$schema"' "$SCHEMA"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "draft-0[7-9]|draft/20"
}

@test "AC5: rubric.schema.json declares required top-level fields" {
  run jq -e '.required | index("schema_version") and index("skill") and index("severity_rules")' "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "AC5: rubric.schema.json severity enum lists Critical|High|Medium|Low|Info" {
  run jq -r '.. | objects | select(.enum != null) | .enum[]?' "$SCHEMA"
  [ "$status" -eq 0 ]
  for sev in Critical High Medium Low Info; do
    echo "$output" | grep -qx "$sev"
  done
}

# ---------- AC6 ----------

@test "AC6 / TC-RSV2-RUBRIC-03: validate-rubric.sh exists and is executable" {
  [ -x "$VALIDATOR" ]
}

@test "AC6: valid rubric passes validation (exit 0, PASS message)" {
  cat >"$TMP_DIR/r.json" <<'EOF'
{
  "schema_version": "1.0",
  "skill": "code",
  "severity_rules": [
    {"id": "r1", "category": "c", "pattern": "p", "severity": "Medium", "description": "d"}
  ]
}
EOF
  run "$VALIDATOR" "$TMP_DIR/r.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"
}

@test "AC6 / TC-RSV2-RUBRIC-04: invalid rubric (missing schema_version) fails with violations" {
  cat >"$TMP_DIR/r.json" <<'EOF'
{"skill": "code", "severity_rules": []}
EOF
  run "$VALIDATOR" "$TMP_DIR/r.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "schema_version"
}

@test "AC6: invalid severity enum value fails with violations" {
  cat >"$TMP_DIR/r.json" <<'EOF'
{
  "schema_version": "1.0",
  "skill": "code",
  "severity_rules": [
    {"id": "r1", "category": "c", "pattern": "p", "severity": "Unknown", "description": "d"}
  ]
}
EOF
  run "$VALIDATOR" "$TMP_DIR/r.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "severity"
}

@test "AC6: missing required rule field (id) fails with violations" {
  cat >"$TMP_DIR/r.json" <<'EOF'
{
  "schema_version": "1.0",
  "skill": "code",
  "severity_rules": [
    {"category": "c", "pattern": "p", "severity": "Low", "description": "d"}
  ]
}
EOF
  run "$VALIDATOR" "$TMP_DIR/r.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "id"
}

@test "AC6: validator fails when file is missing" {
  run "$VALIDATOR" "$TMP_DIR/missing.json"
  [ "$status" -ne 0 ]
}

@test "AC6: validator fails when file is not valid JSON" {
  printf '%s\n' "{not valid" >"$TMP_DIR/bad.json"
  run "$VALIDATOR" "$TMP_DIR/bad.json"
  [ "$status" -ne 0 ]
}
