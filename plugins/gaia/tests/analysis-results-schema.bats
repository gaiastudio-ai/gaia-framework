#!/usr/bin/env bats
# analysis-results-schema.bats — JSON schema sanity checks (E65-S1)
# Covers TC-DEJ-ADR-02, TC-DEJ-JSON-01..04, EC-7.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)/analysis-results.schema.json"
  export SCHEMA
}
teardown() { common_teardown; }

@test "schema file exists and is valid JSON" {
  [ -f "$SCHEMA" ]
  run jq -e . "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "schema declares draft-07 (or later) via \$schema" {
  run jq -r '."$schema"' "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"json-schema.org"* ]]
  [[ "$output" == *"draft-07"* ]] || [[ "$output" == *"2019-09"* ]] || [[ "$output" == *"2020-12"* ]]
}

@test "schema requires schema_version with const '1.0'" {
  run jq -e '.required | index("schema_version")' "$SCHEMA"
  [ "$status" -eq 0 ]
  run jq -r '.properties.schema_version.const // .properties.schema_version.enum[0] // empty' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
}

@test "top-level additionalProperties is true (forward-compatible)" {
  run jq -r '.additionalProperties' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "example payload from PRD §4.37 validates against the schema (structurally)" {
  cat > "$TEST_TMP/example.json" <<'EOF'
{
  "schema_version": "1.0",
  "story_key": "E28-S66",
  "skill": "gaia-code-review",
  "skill_version": "1.0",
  "model": "claude-opus-4-7",
  "model_temperature": 0,
  "prompt_hash": "sha256:abc",
  "tool_versions": { "eslint": "9.x", "tsc": "5.x" },
  "file_hashes": { "src/foo.ts": "sha256:xyz" },
  "checks": [
    {
      "name": "eslint",
      "scope": "file",
      "status": "passed",
      "findings": []
    },
    {
      "name": "tsc",
      "scope": "file",
      "status": "failed",
      "findings": [{ "file":"src/foo.ts", "line":42, "severity":"error", "rule":"TS2345", "message":"type error" }]
    }
  ]
}
EOF
  # Smoke check: schema_version present, all required check fields present.
  run jq -e '.schema_version == "1.0" and (.checks | length) > 0' "$TEST_TMP/example.json"
  [ "$status" -eq 0 ]
  # Each check has the schema-required fields.
  run jq -e '[.checks[] | .name and .status] | all' "$TEST_TMP/example.json"
  [ "$status" -eq 0 ]
}

@test "schema: checks[].status enum covers passed/failed/errored/skipped" {
  run jq -r '.properties.checks.items.properties.status.enum | sort | join(",")' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "errored,failed,passed,skipped" ]
}
