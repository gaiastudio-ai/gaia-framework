#!/usr/bin/env bats
# adapters/plugin-manifest-validator/test/contract.bats — ADR-078 + FR-410 contract.
#
# Standard four probe states via _contract-helper.bash, plus FR-410-specific
# scenarios that exercise the real run.sh:
#   - happy path (AC4): valid manifest with all required fields, name == basename,
#                       no drift -> zero high-severity findings, exit 0.
#   - missing required fields (AC5): one finding per missing field with severity
#                                     "high" (NOT "critical") per Round 1+2 calibration.
#   - manifest drift — declared tool missing (AC5): high-severity finding.
#   - name/basename mismatch (AC5): high-severity finding naming both values.
#
# Plus a normalize.sh test (AC6): raw run.sh output transforms to the canonical
# normalized findings JSON array (rule_id, severity, message, file, line).

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

# Stage a manifest.yaml fixture under WORK_TMP/<basename>/manifest.yaml with the given body.
# Args: <dir-basename> <heredoc-body>
_stage_manifest() {
  local dir_base="$1"
  local body="$2"
  local plugin_dir="$WORK_TMP/$dir_base"
  mkdir -p "$plugin_dir"
  printf '%s' "$body" > "$plugin_dir/manifest.yaml"
  printf '%s\n' "$plugin_dir/manifest.yaml"
}

# ---------------------------------------------------------------------------
# AC1 / AC2: layout + adapter.json well-formedness
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator: directory contains exactly five required artifacts" {
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

@test "plugin-manifest-validator: adapter.json declares name and required schema fields" {
  local dir; dir="$(_real_adapter_dir)"
  jq -e . "$dir/adapter.json" >/dev/null
  # Schema requires provider, category, runtime-profile, default-timeout-seconds,
  # file-extensions, version-range, description.
  for field in provider category runtime-profile default-timeout-seconds file-extensions version-range description; do
    jq -e --arg f "$field" 'has($f)' "$dir/adapter.json" >/dev/null
  done
  # Name field declares the adapter as plugin-manifest-validator (FR-410 / AC2).
  [ "$(jq -r '.name // ""' "$dir/adapter.json")" = "plugin-manifest-validator" ]
  # Category must be a valid enum entry; "linter" is the validator-class entry
  # accepted by the schema (sibling plugin-frontmatter-validator uses "linter").
  [ "$(jq -r '.category' "$dir/adapter.json")" = "linter" ]
  # Runtime-profile MUST be subprocess (shell-native validator).
  [ "$(jq -r '.["runtime-profile"]' "$dir/adapter.json")" = "subprocess" ]
  # Version field must be a valid semver-like string.
  [ -n "$(jq -r '.version // ""' "$dir/adapter.json")" ]
}

# ---------------------------------------------------------------------------
# Standard four-state probe contract (via _contract-helper.bash).
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator contract: state=available when tool on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "plugin-manifest-validator contract: state=expected_and_missing when tool absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "plugin-manifest-validator contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "manifest parse failure" 0
  assert_fragment_shape
}

@test "plugin-manifest-validator contract: state=not_applicable when file-list has no .yaml files" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

# ---------------------------------------------------------------------------
# AC3: probe.sh tri-state JSON
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator probe.sh: returns tri-state JSON with available/version/failure_kind keys" {
  local dir; dir="$(_real_adapter_dir)"
  run "$dir/probe.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("available") and has("version") and has("failure_kind")' >/dev/null
  # Provider is shell-native (awk + jq) -> available is true on supported POSIX systems.
  [ "$(echo "$output" | jq -r '.available')" = "true" ]
  [ "$(echo "$output" | jq -r '.failure_kind')" = "null" ]
}

# ---------------------------------------------------------------------------
# AC4: happy path — valid manifest with all required fields, no drift
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator run.sh: AC4 happy path emits zero high-severity findings and exits 0" {
  local dir; dir="$(_real_adapter_dir)"
  local manifest_path
  manifest_path="$(_stage_manifest "happy-path-plugin" 'name: happy-path-plugin
description: A test plugin manifest with all required fields
version: 1.0.0
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$manifest_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "passed"' >/dev/null
  # Zero high-severity findings.
  echo "$output" | jq -e '[.findings[] | select(.severity == "high")] | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: missing required fields — high-severity findings (NOT critical)
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator run.sh: AC5 missing required fields emits high-severity findings, NOT critical" {
  local dir; dir="$(_real_adapter_dir)"
  local manifest_path
  # All three required fields missing.
  manifest_path="$(_stage_manifest "missing-fields-plugin" 'unrelated_field: something
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$manifest_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  # Three required fields missing -> three findings, one per missing field.
  echo "$output" | jq -e '[.findings[] | select(.rule == "missing-required-field")] | length == 3' >/dev/null
  # Round 1+2 calibration: drift severity is "high" (NOT "critical").
  echo "$output" | jq -e '[.findings[] | select(.severity == "critical")] | length == 0' >/dev/null
  echo "$output" | jq -e '[.findings[] | select(.severity == "high")] | length >= 3' >/dev/null
  # Each finding names the missing field.
  for field in name description version; do
    echo "$output" | jq -e --arg f "$field" '.findings | map(.message | contains($f)) | any' >/dev/null
  done
}

@test "plugin-manifest-validator run.sh: AC5 single missing field reports exactly one high-severity finding" {
  local dir; dir="$(_real_adapter_dir)"
  local manifest_path
  manifest_path="$(_stage_manifest "single-missing-plugin" 'name: single-missing-plugin
version: 1.0.0
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$manifest_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '[.findings[] | select(.rule == "missing-required-field")] | length == 1' >/dev/null
  echo "$output" | jq -e '.findings[0].severity == "high"' >/dev/null
  echo "$output" | jq -e '.findings[0].message | contains("description")' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: name-basename mismatch — high severity, both names in message
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator run.sh: AC5 name-basename mismatch flags high severity, names both values" {
  local dir; dir="$(_real_adapter_dir)"
  local manifest_path
  # Directory basename is `actual-plugin-name`, manifest declares `name: foo-bar`.
  manifest_path="$(_stage_manifest "actual-plugin-name" 'name: foo-bar
description: A plugin whose name does not match its directory basename
version: 1.0.0
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$manifest_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  # Exactly one finding for the mismatch (no missing fields here).
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")] | length == 1' >/dev/null
  # Severity is "high" (NOT "critical") per Round 1+2 calibration.
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].severity == "high"' >/dev/null
  # Message must include BOTH the declared name and the directory basename.
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].message | contains("foo-bar")' >/dev/null
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].message | contains("actual-plugin-name")' >/dev/null
}

@test "plugin-manifest-validator run.sh: AC5 case-sensitive byte-exact comparison" {
  local dir; dir="$(_real_adapter_dir)"
  local manifest_path
  # Same letters, different case (LC_ALL=C byte-exact rule from the stack file).
  manifest_path="$(_stage_manifest "My-Plugin" 'name: my-plugin
description: Case mismatch should fail validation
version: 1.0.0
')"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$manifest_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")] | length == 1' >/dev/null
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].severity == "high"' >/dev/null
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].message | contains("my-plugin")' >/dev/null
  echo "$output" | jq -e '[.findings[] | select(.rule == "name-equals-basename")][0].message | contains("My-Plugin")' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: manifest not found — high-severity finding
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator run.sh: AC5 missing manifest file emits high-severity finding" {
  local dir; dir="$(_real_adapter_dir)"
  local missing_path="$WORK_TMP/no-such-plugin/manifest.yaml"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$missing_path" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  # An unreadable manifest input is a finding (not an adapter error).
  echo "$output" | jq -e '.findings | length >= 1' >/dev/null
  # Severity must be high — never critical.
  echo "$output" | jq -e '[.findings[] | select(.severity == "critical")] | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC6: normalize.sh — transforms raw run.sh output to canonical JSON array
# ---------------------------------------------------------------------------

@test "plugin-manifest-validator normalize.sh: transforms raw output to ADR-078 normalized JSON array" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{
    "name": "plugin-manifest-validator",
    "status": "failed",
    "findings": [
      {
        "rule": "missing-required-field",
        "severity": "high",
        "file": "/tmp/foo/manifest.yaml",
        "line": 1,
        "message": "Missing required manifest field: description",
        "blocking": true
      },
      {
        "rule": "name-equals-basename",
        "severity": "high",
        "file": "/tmp/foo/manifest.yaml",
        "line": 2,
        "message": "Manifest name \"foo-bar\" does not match directory basename \"actual\"",
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
  # Severity passes through verbatim.
  echo "$output" | jq -e '.[0].severity == "high"' >/dev/null
}

@test "plugin-manifest-validator normalize.sh: passing-status raw output yields empty array" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{"name":"plugin-manifest-validator","status":"passed","findings":[]}'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}
