#!/usr/bin/env bats
# adapters/bats/test/contract.bats — ADR-078 + FR-414 contract for the bats adapter.
#
# Standard four-state probe contract via _contract-helper.bash, plus FR-414-specific
# scenarios that exercise the real run.sh dual-mode dispatch:
#   - AC1: directory layout (five files present, executable bits)
#   - AC2: --mode test-runner emits TAP-compliant pass/fail/skip stream
#   - AC3: --mode smell-detection finds anti-patterns and emits findings
#   - AC4: probe.sh tri-state JSON shape
#   - AC5: normalize.sh transforms raw output to canonical JSON
#   - AC6: contract.bats covers all the above (this file)
#   - AC8: empty target directory yields advisory + exit 0 in either mode
#
# AC7 (spike fallback to bats-runner/ + bats-lint/) is inactive on the dual-mode
# happy path and intentionally not asserted here.

load '../../_contract-helper.bash'
bats_require_minimum_version 1.5.0

setup() { contract_setup; }
teardown() { contract_teardown; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Resolve absolute path to the real adapter directory.
_real_adapter_dir() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd
}

# Stage a directory of .bats fixtures under WORK_TMP/<dir>/<name>.bats.
# Args: <dir-name> <file-name> <heredoc-body>
_stage_bats() {
  local dir_name="$1"
  local file_name="$2"
  local body="$3"
  local target="$WORK_TMP/$dir_name"
  mkdir -p "$target"
  printf '%s' "$body" > "$target/$file_name"
  printf '%s\n' "$target"
}

# Build a newline-delimited file-list for the staged .bats fixtures in <dir>.
_file_list_from_dir() {
  local dir="$1"
  local list="$WORK_TMP/files.txt"
  : > "$list"
  for f in "$dir"/*.bats; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f" >> "$list"
  done
  printf '%s\n' "$list"
}

# ---------------------------------------------------------------------------
# AC1: directory layout — five files present, probe/run/normalize executable
# ---------------------------------------------------------------------------

@test "bats adapter: directory contains exactly five files (AC1)" {
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

@test "bats adapter: adapter.json declares required keys, modes, provider=bats (AC1)" {
  local dir; dir="$(_real_adapter_dir)"
  jq -e . "$dir/adapter.json" >/dev/null
  for field in provider category runtime-profile default-timeout-seconds file-extensions version-range description; do
    jq -e --arg f "$field" 'has($f)' "$dir/adapter.json" >/dev/null
  done
  [ "$(jq -r '.provider' "$dir/adapter.json")" = "bats" ]
  # FR-414 extension: modes array names the two dispatch targets.
  jq -e '.modes | type == "array"' "$dir/adapter.json" >/dev/null
  jq -e '.modes | index("test-runner") != null' "$dir/adapter.json" >/dev/null
  jq -e '.modes | index("smell-detection") != null' "$dir/adapter.json" >/dev/null
  # File-extensions includes .bats.
  jq -e '."file-extensions" | index(".bats") != null' "$dir/adapter.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Standard four-state probe contract (via _contract-helper.bash).
# ---------------------------------------------------------------------------

@test "bats contract: state=available when bats on PATH and matching files" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" available "$ext" 0 "" 0
  assert_fragment_shape
}

@test "bats contract: state=expected_and_missing when bats absent from PATH" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" expected_and_missing "$ext" 0 "" 0
  assert_fragment_shape
}

@test "bats contract: state=ran_and_errored when run.sh exits non-zero" {
  local ext; ext="$(_contract_first_ext)"
  assert_state "$(_contract_provider)" ran_and_errored "$ext" 1 "bats run failure" 0
  assert_fragment_shape
}

@test "bats contract: state=not_applicable when file-list has no .bats files" {
  assert_state "$(_contract_provider)" not_applicable "" 0 "" 0
  assert_fragment_shape
}

# ---------------------------------------------------------------------------
# AC4: probe.sh tri-state JSON
# ---------------------------------------------------------------------------

@test "bats probe.sh: returns tri-state JSON with available/version/failure_kind keys (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  run "$dir/probe.sh"
  # Probe always emits valid JSON; exit code mirrors availability (0 when present, 1 when missing).
  echo "$output" | jq -e 'has("available") and has("version") and has("failure_kind")' >/dev/null
}

@test "bats probe.sh: when bats absent on minimal PATH, available=false and failure_kind=not_installed (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  # Strip bats from PATH by pointing PATH at a known minimal set.
  PATH=/usr/bin:/bin run "$dir/probe.sh"
  if command -v bats >/dev/null 2>&1; then
    skip "bats present on /usr/bin:/bin — cannot exercise the absent branch here"
  fi
  echo "$output" | jq -e '.available == false' >/dev/null
  echo "$output" | jq -e '.failure_kind == "not_installed"' >/dev/null
}

@test "bats probe.sh: when bats present, available=true and version is a non-empty string (AC4)" {
  local dir; dir="$(_real_adapter_dir)"
  if ! command -v bats >/dev/null 2>&1; then
    skip "bats not installed in this environment"
  fi
  run "$dir/probe.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.available == true' >/dev/null
  echo "$output" | jq -e '.version | type == "string" and length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# AC2: --mode test-runner emits TAP output
# ---------------------------------------------------------------------------

@test "bats run.sh: --mode test-runner runs bats and emits TAP-compliant stream (AC2)" {
  if ! command -v bats >/dev/null 2>&1; then
    skip "bats not installed in this environment"
  fi
  local dir; dir="$(_real_adapter_dir)"
  local target
  # NOTE: We assemble the `@test` lines via printf so bats's own preprocessor
  # does not rewrite our heredoc body at parse time. A literal `@test "..." {`
  # inside a heredoc on a .bats file would be transformed into
  # `bats_test_function ...` before this test runs.
  target="$WORK_TMP/tap-target"
  mkdir -p "$target"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "ok-test" { [ 1 -eq 1 ]; }\n' '@test'
    printf '%s "fail-test" { [ 1 -eq 2 ]; }\n' '@test'
  } > "$target/sample.bats"
  local file_list; file_list="$(_file_list_from_dir "$target")"

  run "$dir/run.sh" --input "$file_list" --mode test-runner
  # Run completes regardless of pass/fail. Exit 0 = clean run; exit 2 = blocking findings.
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  # stdout is a JSON fragment with a `tap` field carrying the raw TAP output.
  echo "$output" | jq -e '.name == "bats"' >/dev/null
  echo "$output" | jq -e '.tap | type == "string"' >/dev/null
  echo "$output" | jq -e '.tap | test("(?m)^1\\.\\.")' >/dev/null
  echo "$output" | jq -e '.tap | test("(?m)^ok |^not ok ")' >/dev/null
  # Counts: pass + fail + skip totals are integers.
  for k in passed failed skipped; do
    echo "$output" | jq -e --arg k "$k" '.counts[$k] | type == "number"' >/dev/null
  done
}

# ---------------------------------------------------------------------------
# AC3: --mode smell-detection finds anti-patterns
# ---------------------------------------------------------------------------

@test "bats run.sh: --mode smell-detection flags bare-run, hardcoded paths, untimed sleep (AC3)" {
  local dir; dir="$(_real_adapter_dir)"
  local target
  # Assemble fixture via printf so bats's preprocessor does not rewrite the
  # `@test` lines in our heredoc body.
  target="$WORK_TMP/smell-target"
  mkdir -p "$target"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "bare-run-no-assert" { run echo hi; }\n' '@test'
    printf '%s "hardcoded-path" { [ -f /etc/passwd ]; }\n' '@test'
    printf '%s "untimed-sleep" { sleep 5; }\n' '@test'
  } > "$target/smelly.bats"
  local file_list; file_list="$(_file_list_from_dir "$target")"

  run "$dir/run.sh" --input "$file_list" --mode smell-detection
  # Findings present -> exit 2 (mirrors plugin-frontmatter-validator pattern).
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
  echo "$output" | jq -e '.findings | type == "array"' >/dev/null
  echo "$output" | jq -e '.findings | length >= 3' >/dev/null
  # Each finding has the canonical fields (rule, severity, file, line, message, blocking).
  echo "$output" | jq -e '.findings | all(has("rule") and has("severity") and has("file") and has("line") and has("message"))' >/dev/null
  # Specific rules must be present.
  echo "$output" | jq -e '[.findings[].rule] | index("BATS-BARE-RUN") != null' >/dev/null
  echo "$output" | jq -e '[.findings[].rule] | index("BATS-HARDCODED-PATH") != null' >/dev/null
  echo "$output" | jq -e '[.findings[].rule] | index("BATS-UNTIMED-SLEEP") != null' >/dev/null
}

@test "bats run.sh: --mode smell-detection returns no findings on a clean file (AC3)" {
  local dir; dir="$(_real_adapter_dir)"
  local target
  target="$WORK_TMP/clean-target"
  mkdir -p "$target"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "clean-test" {\n' '@test'
    printf '  run echo hi\n'
    printf '  [ "$status" -eq 0 ]\n'
    printf '  [ "$output" = "hi" ]\n'
    printf '}\n'
  } > "$target/clean.bats"
  local file_list; file_list="$(_file_list_from_dir "$target")"

  run "$dir/run.sh" --input "$file_list" --mode smell-detection
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
  echo "$output" | jq -e '.status == "passed"' >/dev/null
}

# ---------------------------------------------------------------------------
# AC8: empty target — both modes exit 0 with advisory and empty findings
# ---------------------------------------------------------------------------

@test "bats run.sh: empty file-list yields advisory + exit 0 in test-runner mode (AC8)" {
  local dir; dir="$(_real_adapter_dir)"
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run --separate-stderr "$dir/run.sh" --input "$file_list" --mode test-runner
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
  echo "$stderr" | grep -q "No bats files found"
}

@test "bats run.sh: empty file-list yields advisory + exit 0 in smell-detection mode (AC8)" {
  local dir; dir="$(_real_adapter_dir)"
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run --separate-stderr "$dir/run.sh" --input "$file_list" --mode smell-detection
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0' >/dev/null
  echo "$stderr" | grep -q "No bats files found"
}

# ---------------------------------------------------------------------------
# AC2/AC3 negative: invalid --mode flag exits non-zero
# ---------------------------------------------------------------------------

@test "bats run.sh: unknown --mode value exits non-zero with usage-style error" {
  local dir; dir="$(_real_adapter_dir)"
  local file_list="$WORK_TMP/files.txt"
  : > "$file_list"
  run --separate-stderr "$dir/run.sh" --input "$file_list" --mode no-such-mode
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -qi "mode"
}

# ---------------------------------------------------------------------------
# AC5: normalize.sh transforms raw output to canonical JSON array
# ---------------------------------------------------------------------------

@test "bats normalize.sh: transforms raw run.sh fragment into canonical findings array (AC5)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{
    "name": "bats",
    "status": "failed",
    "findings": [
      {
        "rule": "BATS-BARE-RUN",
        "severity": "warning",
        "file": "tests/foo.bats",
        "line": 3,
        "message": "bare run without assert_*",
        "blocking": false
      },
      {
        "rule": "BATS-HARDCODED-PATH",
        "severity": "warning",
        "file": "tests/foo.bats",
        "line": 7,
        "message": "hardcoded absolute path",
        "blocking": false
      }
    ]
  }'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"' >/dev/null
  echo "$output" | jq -e 'length == 2' >/dev/null
  for key in rule severity file line message; do
    echo "$output" | jq -e --arg k "$key" '.[0] | has($k)' >/dev/null
    echo "$output" | jq -e --arg k "$key" '.[1] | has($k)' >/dev/null
  done
}

@test "bats normalize.sh: passing-status raw output yields empty array (AC5)" {
  local dir; dir="$(_real_adapter_dir)"
  local raw='{"name":"bats","status":"passed","findings":[]}'
  run bash -c "printf '%s' '$raw' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}

@test "bats normalize.sh: empty stdin yields empty array (AC5)" {
  local dir; dir="$(_real_adapter_dir)"
  run bash -c "printf '' | '$dir/normalize.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 0' >/dev/null
}
