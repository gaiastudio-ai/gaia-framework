#!/usr/bin/env bats
# Tests for the env-var reference knowledge document.
# Verifies the doc exists, covers key variables, and includes a default column.

setup() {
  KNOWLEDGE_DIR="${BATS_TEST_DIRNAME}/../knowledge"
  DOC="${KNOWLEDGE_DIR}/env-var-reference.md"
}

@test "env-var reference document exists and is non-empty (AC1)" {
  [ -f "$DOC" ]
  [ -s "$DOC" ]
}

@test "documents GAIA_STRICT_LIFECYCLE variable (AC2)" {
  grep -q 'GAIA_STRICT_LIFECYCLE' "$DOC"
}

@test "documents PLANNING_ARTIFACTS variable (AC3)" {
  grep -q 'PLANNING_ARTIFACTS' "$DOC"
}

@test "documents CLAUDE_PROJECT_ROOT variable (AC4)" {
  grep -q 'CLAUDE_PROJECT_ROOT' "$DOC"
}

@test "documents CLAUDE_PLUGIN_ROOT variable (AC5)" {
  grep -q 'CLAUDE_PLUGIN_ROOT' "$DOC"
}

@test "documents IMPLEMENTATION_ARTIFACTS variable (AC6)" {
  grep -q 'IMPLEMENTATION_ARTIFACTS' "$DOC"
}

@test "documents SPRINT_STATUS_YAML variable (AC7)" {
  grep -q 'SPRINT_STATUS_YAML' "$DOC"
}

@test "documents PROJECT_CONFIG variable (AC8)" {
  grep -q 'PROJECT_CONFIG' "$DOC"
}

@test "documents GAIA_ARTIFACTS_DIR variable (AC9)" {
  grep -q 'GAIA_ARTIFACTS_DIR' "$DOC"
}

@test "table rows include a Default column (AC10)" {
  # The header row should contain "Default" as a table column
  grep -qE '\|\s*Default\s*\|' "$DOC"
}

@test "document is organized by category sections (AC11)" {
  # At least three H2 section headings
  local count
  count="$(grep -c '^## ' "$DOC")"
  [ "$count" -ge 3 ]
}

@test "GAIA_TOOLS_TIMEOUT default is 600, not 300 (AC-timeout)" {
  run grep 'GAIA_TOOLS_TIMEOUT' "$DOC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`600`'* ]]
}

@test "GAIA_PREWARM_MAX_AGE_DAYS default is 5, not 7 (AC-prewarm)" {
  run grep 'GAIA_PREWARM_MAX_AGE_DAYS' "$DOC"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`5`'* ]]
}

@test "DefectDojo API token row carries a secret-handling note (AC-secret)" {
  run grep 'GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN' "$DOC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Secret"* ]] || [[ "$output" == *"secret"* ]]
}
