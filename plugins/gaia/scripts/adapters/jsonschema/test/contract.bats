#!/usr/bin/env bats
# adapters/jsonschema/test/contract.bats — ADR-078 + FR-415 contract.
#
# Standard four-state probe contract via _contract-helper.bash, plus FR-415
# scenarios that exercise the real run.sh and normalize.sh:
#   - AC1 (story): directory layout (five files present, executable bits)
#   - AC1: adapter.json declares required keys, provider=check-jsonschema
#   - AC4 (story): probe.sh tri-state JSON shape
#   - AC5 (story): run.sh exits non-zero with raw output on schema violation
#   - AC6 (story): normalize.sh transforms raw output to canonical JSON array
#   - AC7 (story): contract.bats covers all the above (this file)

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

# Resolve absolute path to the real adapter directory.
_real_adapter_dir() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd
}

# ---------------------------------------------------------------------------
# AC1: directory layout — five files present, scripts executable
# ---------------------------------------------------------------------------

@test "jsonschema adapter: directory contains exactly five files (AC1)" {
  local dir; dir="$(_real_adapter_dir)"
  [ -f "$dir/adapter.json" ]
  [ -f "$dir/probe.sh" ]
  [ -f "$dir/run.sh" ]
  [ -f "$dir/normalize.sh" ]
  [ -f "$dir/test/contract.bats" ]
  [ -x "$dir/probe.sh" ]
  [ -x "$dir/run.sh" ]
  [ -x "$dir/normalize.sh" ]
}

@test "jsonschema adapter: adapter.json declares required keys, provider=check-jsonschema (AC1)" {
  local dir; dir="$(_real_adapter_dir)"
  jq -e . "$dir/adapter.json" >/dev/null
  for field in provider category runtime-profile default-timeout-seconds file-extensions version-range description; do
    jq -e --arg f "$field" 'has($f)' "$dir/adapter.json" >/dev/null
  done
  [ "$(jq -r '.provider' "$dir/adapter.json")" = "check-jsonschema" ]
  [ "$(jq -r '.category' "$dir/adapter.json")" = "linter" ]
  [ "$(jq -r '.["runtime-profile"]' "$dir/adapter.json")" = "subprocess" ]
  jq -e '."file-extensions" | index(".json") != null' "$dir/adapter.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Standard four-state probe contract (via _contract-helper.bash).
# ---------------------------------------------------------------------------

@test "jsonschema contract: state=available when binary on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "jsonschema contract: state=expected_and_missing when binary absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "jsonschema contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "schema validation failure" 0
  assert_fragment_shape
}

@test "jsonschema contract: state=not_applicable when file-list has no .json files" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

# ---------------------------------------------------------------------------
# AC4: probe.sh tri-state JSON
# ---------------------------------------------------------------------------

@test "jsonschema probe.sh: returns tri-state JSON with available/version/failure_kind keys (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  run "$dir/probe.sh"
  echo "$output" | jq -e 'has("available") and has("version") and has("failure_kind")' >/dev/null
}

@test "jsonschema probe.sh: when binary absent on minimal PATH, available=false and failure_kind=not_installed (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  PATH=/usr/bin:/bin run "$dir/probe.sh"
  if command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema present on /usr/bin:/bin — cannot exercise the absent branch here"
  fi
  echo "$output" | jq -e '.available == false' >/dev/null
  echo "$output" | jq -e '.failure_kind == "not_installed"' >/dev/null
}

@test "jsonschema probe.sh: when binary present, available=true and version is a non-empty string (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed in this environment"
  fi
  run "$dir/probe.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.available == true' >/dev/null
  echo "$output" | jq -e '.version | type == "string" and length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: run.sh exits non-zero on schema violation, exits 0 when clean
# ---------------------------------------------------------------------------

@test "jsonschema run.sh: exits non-zero on schema violation, with raw output (AC5)" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi
  local dir; dir="$(_real_adapter_dir)"
  local target="$WORK_TMP/bad-target"
  mkdir -p "$target"
  cat > "$target/schema.json" <<'EOF'
{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
EOF
  cat > "$target/instance.json" <<'EOF'
{"unrelated":"field"}
EOF
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$target/instance.json" > "$file_list"

  run "$dir/run.sh" --input "$file_list" --config "$target/schema.json"
  # Findings present -> exit 2.
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.name == "jsonschema"' >/dev/null
  echo "$output" | jq -e '.status == "failed"' >/dev/null
  echo "$output" | jq -e '.findings | length >= 1' >/dev/null
}

@test "jsonschema run.sh: exits 0 when schema validation succeeds (AC5)" {
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "check-jsonschema not installed"
  fi
  local dir; dir="$(_real_adapter_dir)"
  local target="$WORK_TMP/good-target"
  mkdir -p "$target"
  cat > "$target/schema.json" <<'EOF'
{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
EOF
  cat > "$target/instance.json" <<'EOF'
{"name":"valid"}
EOF
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$target/instance.json" > "$file_list"

  run "$dir/run.sh" --input "$file_list" --config "$target/schema.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "passed"' >/dev/null
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

@test "jsonschema run.sh: empty file-list yields advisory + exit 0" {
  local dir; dir="$(_real_adapter_dir)"
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run --separate-stderr "$dir/run.sh" --input "$file_list"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC6: normalize.sh transforms raw output to canonical JSON array
# ---------------------------------------------------------------------------

@test "jsonschema normalize.sh: transforms raw run.sh fragment into canonical findings array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{
    "name": "jsonschema",
    "status": "failed",
    "findings": [
      {
        "rule": "schema-violation",
        "severity": "error",
        "file": "config.json",
        "line": 1,
        "message": "missing required property: name",
        "blocking": true
      }
    ]
  }'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"' >/dev/null
  echo "$output" | jq -e 'length == 1' >/dev/null
  for key in rule severity file line message; do
    echo "$output" | jq -e --arg k "$key" '.[0] | has($k)' >/dev/null
  done
}

@test "jsonschema normalize.sh: empty stdin yields empty array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  run bash -c "printf '' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}

@test "jsonschema normalize.sh: passing-status raw output yields empty array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{"name":"jsonschema","status":"passed","findings":[]}'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}
