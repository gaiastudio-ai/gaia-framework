#!/usr/bin/env bats
# adapters/plugin-frontmatter-validator/test/contract.bats — ADR-078 + FR-409 contract.
#
# Standard four probe states via _contract-helper.bash, plus three FR-409-specific
# scenarios that exercise the real run.sh:
#   - happy path (AC4): all required fields present, name == basename
#   - missing required fields (AC5): one finding per missing field, exit non-zero
#   - name-basename mismatch (AC6): high-severity finding naming both values
#
# Plus a normalize.sh test (AC7): raw run.sh output transforms to the canonical
# normalized findings JSON array.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Resolve absolute path to the real adapter directory (not the staged one).
_real_adapter_dir() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd
}

# Stage a SKILL.md fixture under WORK_TMP/<basename>/SKILL.md with the given body.
# Args: <dir-basename> <heredoc-body>
_stage_skill() {
  local dir_base="$1"
  local body="$2"
  local skill_dir="$WORK_TMP/$dir_base"
  mkdir -p "$skill_dir"
  printf '%s' "$body" > "$skill_dir/SKILL.md"
  printf '%s\n' "$skill_dir/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC1 / AC2: layout + adapter.json well-formedness
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator: directory contains exactly five files" {
  local dir; dir="$(_real_adapter_dir)"
  [ -f "$dir/adapter.json" ]
  [ -f "$dir/probe.sh" ]
  [ -f "$dir/run.sh" ]
  [ -f "$dir/normalize.sh" ]
  [ -f "$dir/test/contract.bats" ]
  # Probe / run / normalize must be executable.
  [ -x "$dir/probe.sh" ]
  [ -x "$dir/run.sh" ]
  [ -x "$dir/normalize.sh" ]
}

@test "plugin-frontmatter-validator: adapter.json declares name and required fields" {
  local dir; dir="$(_real_adapter_dir)"
  jq -e . "$dir/adapter.json" >/dev/null
  # Schema requires provider, category, runtime-profile, default-timeout-seconds,
  # file-extensions, version-range, description.
  for field in provider category runtime-profile default-timeout-seconds file-extensions version-range description; do
    jq -e --arg f "$field" 'has($f)' "$dir/adapter.json" >/dev/null
  done
  # Name field declares the adapter as plugin-frontmatter-validator. The base
  # adapter.schema.json does NOT require a `name` key, but FR-409 / AC2 does.
  [ "$(jq -r '.name // ""' "$dir/adapter.json")" = "plugin-frontmatter-validator" ]
}

# ---------------------------------------------------------------------------
# Standard four-state probe contract (via _contract-helper.bash).
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "plugin-frontmatter-validator contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "plugin-frontmatter-validator contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "frontmatter parse failure" 0
  assert_fragment_shape
}

@test "plugin-frontmatter-validator contract: state=not_applicable when file-list has no .md files" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

# ---------------------------------------------------------------------------
# AC3: probe.sh tri-state JSON
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator probe.sh: returns tri-state JSON with available/version/failure_kind keys" {
  local dir; dir="$(_real_adapter_dir)"
  run "$dir/probe.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("available") and has("version") and has("failure_kind")' >/dev/null
  # Provider is shell-native -> available is true on supported POSIX systems.
  [ "$(echo "$output" | jq -r '.available')" = "true" ]
  [ "$(echo "$output" | jq -r '.failure_kind')" = "null" ]
}

# ---------------------------------------------------------------------------
# AC4: happy path — valid frontmatter, name matches basename
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator run.sh: AC4 happy path emits empty findings and exits 0" {
  local dir; dir="$(_real_adapter_dir)"
  local skill_path
  skill_path="$(_stage_skill "happy-path-skill" '---
name: happy-path-skill
description: A test skill with all required fields
version: 1.0.0
---

# Happy Path Skill

Body content.
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$skill_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "passed"' >/dev/null
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: missing required fields — one finding per missing field
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator run.sh: AC5 missing required fields emits one finding per field, exits non-zero" {
  local dir; dir="$(_real_adapter_dir)"
  local skill_path
  # All three required fields missing.
  skill_path="$(_stage_skill "missing-fields-skill" '---
unrelated_field: something
---

# Missing Fields Skill

Body content.
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$skill_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  # Three required fields missing -> three findings, one per missing field.
  echo "$output" | jq -e '.findings | length == 3' >/dev/null
  # Each finding names the missing field.
  for field in name description version; do
    echo "$output" | jq -e --arg f "$field" '.findings | map(.message | contains($f)) | any' >/dev/null
  done
}

@test "plugin-frontmatter-validator run.sh: AC5 single missing field reports exactly one finding" {
  local dir; dir="$(_real_adapter_dir)"
  local skill_path
  # Only the `description` field missing.
  skill_path="$(_stage_skill "single-missing-skill" '---
name: single-missing-skill
version: 1.0.0
---

Body.
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$skill_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.findings | length == 1' >/dev/null
  echo "$output" | jq -e '.findings[0].message | contains("description")' >/dev/null
}

# ---------------------------------------------------------------------------
# AC6: name-basename mismatch — high severity, both names in message
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator run.sh: AC6 name-basename mismatch flags high severity, names both" {
  local dir; dir="$(_real_adapter_dir)"
  local skill_path
  # Directory basename is `actual-dir-name`, frontmatter declares `name: foo-bar`.
  skill_path="$(_stage_skill "actual-dir-name" '---
name: foo-bar
description: A skill whose name does not match its directory basename
version: 1.0.0
---

Body.
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$skill_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  # Exactly one finding for the mismatch (no missing fields here).
  echo "$output" | jq -e '.findings | length == 1' >/dev/null
  echo "$output" | jq -e '.findings[0].severity == "error"' >/dev/null
  # Message must include BOTH the declared name and the directory basename.
  echo "$output" | jq -e '.findings[0].message | contains("foo-bar")' >/dev/null
  echo "$output" | jq -e '.findings[0].message | contains("actual-dir-name")' >/dev/null
  # Rule id identifies the name-basename rule.
  echo "$output" | jq -e '.findings[0].rule | contains("name-equals-basename") or contains("name_equals_basename")' >/dev/null
}

@test "plugin-frontmatter-validator run.sh: AC6 case-sensitive byte-exact comparison" {
  local dir; dir="$(_real_adapter_dir)"
  local skill_path
  # Same letters, different case.
  skill_path="$(_stage_skill "My-Skill" '---
name: my-skill
description: Case mismatch should fail validation
version: 1.0.0
---

Body.
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$skill_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.findings | length == 1' >/dev/null
  echo "$output" | jq -e '.findings[0].message | contains("my-skill")' >/dev/null
  echo "$output" | jq -e '.findings[0].message | contains("My-Skill")' >/dev/null
}

# ---------------------------------------------------------------------------
# AC7: normalize.sh — transforms raw run.sh output to canonical JSON array
# ---------------------------------------------------------------------------

@test "plugin-frontmatter-validator normalize.sh: transforms raw output to ADR-078 normalized JSON array" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{
    "name": "plugin-frontmatter-validator",
    "status": "failed",
    "findings": [
      {
        "rule": "missing-required-field",
        "severity": "error",
        "file": "/tmp/foo/SKILL.md",
        "line": 1,
        "message": "Missing required frontmatter field: description",
        "blocking": true
      },
      {
        "rule": "name-equals-basename",
        "severity": "error",
        "file": "/tmp/foo/SKILL.md",
        "line": 2,
        "message": "Frontmatter name \"foo-bar\" does not match directory basename \"actual\"",
        "blocking": true
      }
    ]
  }'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  # Output is a JSON array (top-level type array).
  echo "$output" | jq -e 'type == "array"' >/dev/null
  echo "$output" | jq -e 'length == 2' >/dev/null
  # Each element has the canonical five keys: rule, severity, file, line, message.
  for key in rule severity file line message; do
    echo "$output" | jq -e --arg k "$key" '.[0] | has($k)' >/dev/null
    echo "$output" | jq -e --arg k "$key" '.[1] | has($k)' >/dev/null
  done
}

@test "plugin-frontmatter-validator normalize.sh: passing-status raw output yields empty array" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{"name":"plugin-frontmatter-validator","status":"passed","findings":[]}'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}
