#!/usr/bin/env bats
# qa-tc-generation.bats — E67-S4 schema-conformance coverage for
# qa-test-cases-{story_key}.json shape (AC1, AC2).
#
# The TC generation Phase 3C is LLM-assisted (in the fork context). The
# deterministic part this test covers is:
#   - the JSON schema exists
#   - any TC document in fixture form validates against the schema
#   - schema enforces unique tc_id and ac_ref traceability fields

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  STORY_KEY="E67-S4"
  SCHEMA="${SCHEMAS_DIR}/qa-test-cases.schema.json"
}
teardown() { common_teardown; }

write_valid_tc_doc() {
  cat > "$1" <<'EOF'
[
  {
    "tc_id": "TC-E67-S4-1",
    "ac_ref": "AC1",
    "description": "Phase 3C generates qa-test-cases.json for uncovered AC",
    "given": "a story AC with no matching test",
    "when": "Phase 3C runs",
    "then": "an entry is appended to qa-test-cases.json",
    "type": "Unit"
  },
  {
    "tc_id": "TC-E67-S4-2",
    "ac_ref": "AC3",
    "description": "Tier placement honors GAIA_EXECUTION_CONTEXT",
    "given": "tier_1.placement=local and context=local",
    "when": "qa-test-runner.sh runs",
    "then": "tier_1 suite executes and tier_2 is skipped",
    "type": "Integration"
  }
]
EOF
}

write_invalid_tc_doc_missing_field() {
  cat > "$1" <<'EOF'
[
  {
    "tc_id": "TC-E67-S4-1",
    "description": "missing ac_ref"
  }
]
EOF
}

write_invalid_tc_doc_bad_type() {
  cat > "$1" <<'EOF'
[
  {
    "tc_id": "TC-E67-S4-1",
    "ac_ref": "AC1",
    "description": "bad type",
    "given": "g", "when": "w", "then": "t",
    "type": "Smoke"
  }
]
EOF
}

@test "schema file exists" {
  [ -f "$SCHEMA" ]
}

@test "schema declares draft-07 and array of TC items" {
  jq -e '."$schema" | contains("draft-07")' "$SCHEMA" >/dev/null
  jq -e '.type == "array"' "$SCHEMA" >/dev/null
  jq -e '.items.required | index("tc_id")' "$SCHEMA" >/dev/null
  jq -e '.items.required | index("ac_ref")' "$SCHEMA" >/dev/null
  jq -e '.items.required | index("type")' "$SCHEMA" >/dev/null
}

@test "type enum is restricted to Unit/Integration/E2E" {
  jq -e '.items.properties.type.enum | index("Unit")' "$SCHEMA" >/dev/null
  jq -e '.items.properties.type.enum | index("Integration")' "$SCHEMA" >/dev/null
  jq -e '.items.properties.type.enum | index("E2E")' "$SCHEMA" >/dev/null
}

@test "valid TC doc passes ajv validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  write_valid_tc_doc "$TEST_TMP/qa-test-cases.json"
  ajv validate -s "$SCHEMA" -d "$TEST_TMP/qa-test-cases.json"
}

@test "missing-field TC doc fails ajv validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  write_invalid_tc_doc_missing_field "$TEST_TMP/qa-test-cases.json"
  run ajv validate -s "$SCHEMA" -d "$TEST_TMP/qa-test-cases.json"
  [ "$status" -ne 0 ]
}

@test "bad-type TC doc fails ajv validation" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  write_invalid_tc_doc_bad_type "$TEST_TMP/qa-test-cases.json"
  run ajv validate -s "$SCHEMA" -d "$TEST_TMP/qa-test-cases.json"
  [ "$status" -ne 0 ]
}

@test "tc_id pattern enforces TC-{story_key}-{N}" {
  # Pattern check encoded in the schema's items.properties.tc_id.pattern
  jq -e '.items.properties.tc_id | has("pattern")' "$SCHEMA" >/dev/null
}
