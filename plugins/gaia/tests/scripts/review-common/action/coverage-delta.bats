#!/usr/bin/env bats
# coverage-delta.bats — E67-S3 bats coverage for coverage-delta.sh
# (FR-RSV2-2, TC-RSV2-TESTAUTOMATE-3, AC1, AC5, AC7).
#
# Exercises:
#   - positive / zero / negative delta -> exit 0 with correct JSON
#   - missing baseline / current file -> exit 1 with stderr diagnostic
#   - lcov text format auto-detection
#   - coverage.py JSON format auto-detection
#   - --help and unknown-flag handling
#
# These tests are the Red phase for E67-S3. They will FAIL until
# scripts/review-common/action/coverage-delta.sh ships.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="${ACTION_DIR}/coverage-delta.sh"
}
teardown() { common_teardown; }

# --- helpers -----------------------------------------------------------

write_lcov_summary() {
  # write_lcov_summary <path> <pct>
  # Emits a minimal lcov-style text summary. The script parses
  # `Lines executed:<pct>%` (lcov genhtml --summary format).
  local path="$1" pct="$2"
  cat > "$path" <<EOF
Reading tracefile coverage.info
Summary coverage rate:
  lines......: ${pct}% (123 of 200 lines)
  functions..: 60.0% (12 of 20 functions)
  branches...: no data found
Lines executed:${pct}% of 200
EOF
}

write_coveragepy_json() {
  # write_coveragepy_json <path> <pct>
  # Emits a minimal coverage.py 6.x report shape. The script parses
  # .totals.percent_covered.
  local path="$1" pct="$2"
  cat > "$path" <<EOF
{
  "meta": {"version": "6.0"},
  "totals": {
    "covered_lines": 800,
    "num_statements": 1000,
    "percent_covered": ${pct},
    "missing_lines": 200
  }
}
EOF
}

# --- AC1: script exists and is executable -----------------------------

@test "AC1: coverage-delta.sh exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "AC1: --help prints usage and exits 0" {
  run --separate-stderr "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--baseline"* ]]
  [[ "$output" == *"--current"* ]]
}

# --- AC5/AC7 #1: positive delta (lcov) --------------------------------

@test "AC7-1: positive delta lcov -- exit 0, JSON coverage_delta=5.00" {
  write_lcov_summary "$TEST_TMP/baseline.info" "80.0"
  write_lcov_summary "$TEST_TMP/current.info"  "85.0"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.info" --current "$TEST_TMP/current.info"
  [ "$status" -eq 0 ]
  # JSON output on stdout
  echo "$output" | jq -e '.coverage_delta == 5' >/dev/null \
    || echo "$output" | jq -e '.coverage_delta == 5.0' >/dev/null
  echo "$output" | jq -e '.baseline == 80 or .baseline == 80.0' >/dev/null
  echo "$output" | jq -e '.current == 85 or .current == 85.0' >/dev/null
}

# --- AC5/AC7 #2: zero delta (lcov) ------------------------------------

@test "AC7-2: zero delta lcov -- exit 0, JSON coverage_delta=0" {
  write_lcov_summary "$TEST_TMP/baseline.info" "80.0"
  write_lcov_summary "$TEST_TMP/current.info"  "80.0"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.info" --current "$TEST_TMP/current.info"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage_delta == 0 or .coverage_delta == 0.0' >/dev/null
}

# --- AC5/AC7 #3: negative delta (lcov) --------------------------------

@test "AC7-3: negative delta lcov -- exit 0, JSON coverage_delta=-2.5" {
  write_lcov_summary "$TEST_TMP/baseline.info" "80.0"
  write_lcov_summary "$TEST_TMP/current.info"  "77.5"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.info" --current "$TEST_TMP/current.info"
  [ "$status" -eq 0 ]
  # delta is negative; allow -2.5 or -2.50 representation
  delta="$(echo "$output" | jq -r '.coverage_delta')"
  # Use awk to normalize numeric comparison
  awk -v d="$delta" 'BEGIN{exit !(d+0 == -2.5)}'
}

# --- AC5/AC7 #4: missing baseline file --------------------------------

@test "AC7-4: missing baseline file -- exit 1, stderr names file" {
  write_lcov_summary "$TEST_TMP/current.info" "85.0"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/does-not-exist.info" --current "$TEST_TMP/current.info"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"baseline"* ]]
  [[ "$stderr" == *"does-not-exist.info"* ]]
}

# --- AC5/AC7 #5: missing current file ---------------------------------

@test "AC7-5: missing current file -- exit 1, stderr names file" {
  write_lcov_summary "$TEST_TMP/baseline.info" "80.0"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.info" --current "$TEST_TMP/missing.info"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"current"* ]]
  [[ "$stderr" == *"missing.info"* ]]
}

# --- coverage.py JSON format detection --------------------------------

@test "format auto-detect: coverage.py JSON positive delta" {
  write_coveragepy_json "$TEST_TMP/baseline.json" "80.0"
  write_coveragepy_json "$TEST_TMP/current.json"  "92.5"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.json" --current "$TEST_TMP/current.json"
  [ "$status" -eq 0 ]
  delta="$(echo "$output" | jq -r '.coverage_delta')"
  awk -v d="$delta" 'BEGIN{exit !(d+0 == 12.5)}'
}

# --- explicit --format flag --------------------------------------------

@test "explicit --format lcov works on lcov input" {
  write_lcov_summary "$TEST_TMP/baseline.info" "70.0"
  write_lcov_summary "$TEST_TMP/current.info"  "75.0"
  run --separate-stderr "$SCRIPT" --format lcov --baseline "$TEST_TMP/baseline.info" --current "$TEST_TMP/current.info"
  [ "$status" -eq 0 ]
  delta="$(echo "$output" | jq -r '.coverage_delta')"
  awk -v d="$delta" 'BEGIN{exit !(d+0 == 5)}'
}

# --- argument validation ----------------------------------------------

@test "missing --baseline -- exit 1" {
  write_lcov_summary "$TEST_TMP/current.info" "80.0"
  run --separate-stderr "$SCRIPT" --current "$TEST_TMP/current.info"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--baseline"* ]]
}

@test "missing --current -- exit 1" {
  write_lcov_summary "$TEST_TMP/baseline.info" "80.0"
  run --separate-stderr "$SCRIPT" --baseline "$TEST_TMP/baseline.info"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--current"* ]]
}

@test "unknown flag -- exit 1" {
  run --separate-stderr "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
}
