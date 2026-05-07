#!/usr/bin/env bats
# adapters/markdownlint/test/contract.bats — ADR-078 + FR-415 contract.
#
# Standard four-state probe contract via _contract-helper.bash, plus FR-415
# scenarios that exercise the real run.sh and normalize.sh:
#   - AC2 (story): directory layout (five files present, executable bits)
#   - AC2: adapter.json declares required keys, provider=markdownlint-cli2
#   - AC4 (story): probe.sh tri-state JSON shape
#   - AC5 (story): run.sh exits non-zero with raw output on lint violations
#   - AC6 (story): normalize.sh transforms raw output to canonical JSON array
#   - AC7 (story): contract.bats covers all the above (this file)

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

_real_adapter_dir() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd
}

# ---------------------------------------------------------------------------
# AC2: directory layout
# ---------------------------------------------------------------------------

@test "markdownlint adapter: directory contains exactly five files (AC2)" {
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

@test "markdownlint adapter: adapter.json declares required keys, provider=markdownlint-cli2 (AC2)" {
  local dir; dir="$(_real_adapter_dir)"
  jq -e . "$dir/adapter.json" >/dev/null
  for field in provider category runtime-profile default-timeout-seconds file-extensions version-range description; do
    jq -e --arg f "$field" 'has($f)' "$dir/adapter.json" >/dev/null
  done
  [ "$(jq -r '.provider' "$dir/adapter.json")" = "markdownlint-cli2" ]
  [ "$(jq -r '.category' "$dir/adapter.json")" = "linter" ]
  [ "$(jq -r '.["runtime-profile"]' "$dir/adapter.json")" = "subprocess" ]
  jq -e '."file-extensions" | index(".md") != null' "$dir/adapter.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Standard four-state probe contract
# ---------------------------------------------------------------------------

@test "markdownlint contract: state=available when binary on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "markdownlint contract: state=expected_and_missing when binary absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "markdownlint contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "lint failure" 0
  assert_fragment_shape
}

@test "markdownlint contract: state=not_applicable when file-list has no .md files" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

# ---------------------------------------------------------------------------
# AC4: probe.sh tri-state JSON
# ---------------------------------------------------------------------------

@test "markdownlint probe.sh: returns tri-state JSON with available/version/failure_kind keys (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  run "$dir/probe.sh"
  echo "$output" | jq -e 'has("available") and has("version") and has("failure_kind")' >/dev/null
}

@test "markdownlint probe.sh: when binary absent on minimal PATH, available=false and failure_kind=not_installed (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  PATH=/usr/bin:/bin run "$dir/probe.sh"
  if command -v markdownlint-cli2 >/dev/null 2>&1 || command -v markdownlint >/dev/null 2>&1; then
    skip "markdownlint present on /usr/bin:/bin — cannot exercise the absent branch here"
  fi
  echo "$output" | jq -e '.available == false' >/dev/null
  echo "$output" | jq -e '.failure_kind == "not_installed"' >/dev/null
}

@test "markdownlint probe.sh: when binary present, available=true and version is a non-empty string (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  if ! command -v markdownlint-cli2 >/dev/null 2>&1 && ! command -v markdownlint >/dev/null 2>&1; then
    skip "markdownlint not installed in this environment"
  fi
  run "$dir/probe.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.available == true' >/dev/null
  echo "$output" | jq -e '.version | type == "string" and length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: run.sh exits non-zero on lint violations, exits 0 when clean
# ---------------------------------------------------------------------------

@test "markdownlint run.sh: exits non-zero on lint violations (AC5)" {
  if ! command -v markdownlint-cli2 >/dev/null 2>&1 && ! command -v markdownlint >/dev/null 2>&1; then
    skip "markdownlint not installed"
  fi
  local dir; dir="$(_real_adapter_dir)"
  local target="$WORK_TMP/bad-md"
  mkdir -p "$target"
  # Two violations: leading whitespace before heading (MD023) and missing blank
  # line around heading (MD022). Most installations flag at least one of these.
  printf '%s\n' '## Heading' '   #wrong' 'paragraph' > "$target/bad.md"
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$target/bad.md" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  # Findings present -> exit 2.
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.name == "markdownlint"' >/dev/null
  echo "$output" | jq -e '.status == "failed"' >/dev/null
  echo "$output" | jq -e '.findings | length >= 1' >/dev/null
}

@test "markdownlint run.sh: exits 0 on clean Markdown (AC5)" {
  if ! command -v markdownlint-cli2 >/dev/null 2>&1 && ! command -v markdownlint >/dev/null 2>&1; then
    skip "markdownlint not installed"
  fi
  local dir; dir="$(_real_adapter_dir)"
  local target="$WORK_TMP/good-md"
  mkdir -p "$target"
  cat > "$target/good.md" <<'EOF'
# Clean Document

This is a paragraph.

## Section

Another paragraph.
EOF
  local file_list="$WORK_TMP/files.txt"
  printf '%s\n' "$target/good.md" > "$file_list"

  run "$dir/run.sh" --input "$file_list"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "passed"' >/dev/null
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

@test "markdownlint run.sh: empty file-list yields advisory + exit 0" {
  local dir; dir="$(_real_adapter_dir)"
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run --separate-stderr "$dir/run.sh" --input "$file_list"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC6: normalize.sh
# ---------------------------------------------------------------------------

@test "markdownlint normalize.sh: transforms raw run.sh fragment into canonical findings array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{
    "name": "markdownlint",
    "status": "failed",
    "findings": [
      {
        "rule": "MD022",
        "severity": "error",
        "file": "README.md",
        "line": 3,
        "message": "Headings should be surrounded by blank lines",
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

@test "markdownlint normalize.sh: empty stdin yields empty array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  run bash -c "printf '' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}

@test "markdownlint normalize.sh: passing-status raw output yields empty array (AC6)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{"name":"markdownlint","status":"passed","findings":[]}'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}
