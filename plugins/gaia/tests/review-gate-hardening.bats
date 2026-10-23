#!/usr/bin/env bats
# review-gate-hardening.bats — regression tests for proof-of-execution
# optional-suite handling, report column pass-through, pass-suffixed report
# discovery, and per-suite exit-code aggregation.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  SUMMARY="$SCRIPTS_DIR/review-summary-gen.sh"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  TST="$TEST_TMP/docs/test-artifacts"
  mkdir -p "$ART" "$TST"

  STORY_KEY="E900-S1"
  STORY_FILE="$ART/${STORY_KEY}-fixture.md"
  _write_story_file "$STORY_FILE" "$STORY_KEY"
}

teardown() {
  common_teardown
}

_write_story_file() {
  local file="$1" key="$2"
  cat > "$file" <<EOF
---
template: 'story'
key: "${key}"
status: review
---

# Story: ${key}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | -- |
| QA Tests | UNVERIFIED | -- |
| Security Review | UNVERIFIED | -- |
| Test Automation | UNVERIFIED | -- |
| Test Review | UNVERIFIED | -- |
| Performance Review | UNVERIFIED | -- |
EOF
}

# Write a minimal execution-evidence JSON to a file.
# Usage: _write_evidence <path> <json>
_write_evidence() {
  printf '%s\n' "$2" > "$1"
}

# Write a minimal report file.
_write_report() {
  printf '# Review report\n' > "$1"
}

# ---------------------------------------------------------------------------
# AC1: optional suites excluded from proof-of-execution blocking total
# ---------------------------------------------------------------------------

@test "optional suite with failures does not block PASSED verdict" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"visual","required":false,"fail_count":3,"exit_code":1}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

@test "required suite with failures blocks PASSED verdict" {
  local ev_file="$TEST_TMP/evidence.json"
  # exit_code 0 so only fail_count triggers the block
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":2,"exit_code":0}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail_count"* ]]
}

@test "suite without required field defaults to required (blocks on failure)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","fail_count":1,"exit_code":0}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail_count"* ]]
}

@test "all-optional suites with failures allows PASSED" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"opt1","required":false,"fail_count":5},{"name":"opt2","required":false,"fail_count":2}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

@test "mixed required/optional suites: required green, optional red allows PASSED" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"lint","required":false,"fail_count":7,"exit_code":1},{"name":"integration","required":true,"fail_count":0,"exit_code":0}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2: --report value written to the Report column
# ---------------------------------------------------------------------------

@test "update with --report writes the path into the Report column" {
  local report="$TEST_TMP/code-review-report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report "$report"
  [ "$status" -eq 0 ]

  # Read the story file and check the Report column for Code Review
  local cr_line
  cr_line="$(/usr/bin/grep '| Code Review |' "$STORY_FILE")"
  [[ "$cr_line" == *"$report"* ]]
}

@test "update without --report writes em-dash in the Report column" {
  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict UNVERIFIED
  [ "$status" -eq 0 ]

  local cr_line
  cr_line="$(/usr/bin/grep '| Code Review |' "$STORY_FILE")"
  # The report column should contain an em-dash or double-dash placeholder
  [[ "$cr_line" != *".md"* ]]
}

# ---------------------------------------------------------------------------
# AC3: pass-suffixed reports discovered by review-summary-gen.sh
# ---------------------------------------------------------------------------

@test "review-summary-gen finds pass-suffixed report in flat layout" {
  # Set up the story with Code Review = PASSED
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create a pass-suffixed report (not the base name)
  local pass_report="$ART/code-review-${STORY_KEY}-pass2.md"
  _write_report "$pass_report"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  # The output's last line is the summary file path
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  [ -f "$summary_file" ]
  # The summary should not flag Code Review as MISSING
  local content
  content="$(cat "$summary_file")"
  ! echo "$content" | /usr/bin/grep -q 'Code Review.*MISSING'
  ! echo "$content" | /usr/bin/grep -q 'MISSING.*code-review'
}

@test "review-summary-gen finds pass-suffixed report in reviews/ subdir" {
  # Set the story to have Code Review = PASSED
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create reviews/ subdir with pass-suffixed report
  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  local pass_report="$reviews_dir/code-review-${STORY_KEY}-pass2.md"
  _write_report "$pass_report"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  [ -f "$summary_file" ]
  local content
  content="$(cat "$summary_file")"
  ! echo "$content" | /usr/bin/grep -q 'Code Review.*MISSING'
  ! echo "$content" | /usr/bin/grep -q 'MISSING.*code-review'
}

# ---------------------------------------------------------------------------
# AC4: reviews/ subdirectory reports found (regression test)
# ---------------------------------------------------------------------------

@test "review-summary-gen finds report in reviews/ subdir (regression)" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create per-story reviews/ dir with canonical basename
  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  _write_report "$reviews_dir/code-review-${STORY_KEY}.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  [ -f "$summary_file" ]
  local content
  content="$(cat "$summary_file")"
  ! echo "$content" | /usr/bin/grep -q 'Code Review.*MISSING'
}

# ---------------------------------------------------------------------------
# AC5: per-suite exit_code aggregation (not top-level)
# ---------------------------------------------------------------------------

@test "per-suite exit_code blocks PASSED when any required suite has nonzero exit" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":1}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Test Automation" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exit_code"* ]]
}

@test "per-suite exit_code: optional suite with nonzero exit does not block" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"visual","required":false,"fail_count":0,"exit_code":1}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Test Review" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

@test "evidence with no top-level exit_code but per-suite nonzero exit blocks PASSED" {
  # This tests that the code reads .suites[].exit_code, not .exit_code
  local ev_file="$TEST_TMP/evidence.json"
  # No top-level .exit_code, but suites have it
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":2}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exit_code"* ]]
}

@test "evidence with all per-suite exit_code zero allows PASSED" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"integration","required":true,"fail_count":0,"exit_code":0}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Test Automation" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC9: tests use temp directories, never the real plugin tree
# ---------------------------------------------------------------------------

@test "all test fixtures live in BATS_TEST_TMPDIR" {
  # Verify our story file is in the temp dir
  [[ "$STORY_FILE" == "${BATS_TEST_TMPDIR}"* ]] || [[ "$STORY_FILE" == /tmp/* ]] || [[ "$STORY_FILE" == /private/tmp/* ]]
}

# ---------------------------------------------------------------------------
# Edge cases: malformed evidence
# ---------------------------------------------------------------------------

@test "empty suites array allows PASSED (no suites to fail)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

@test "evidence with missing suites key allows PASSED (no suites)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"version":"1.0"}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}

@test "FAILED verdict is allowed even with optional-suite failures" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"opt","required":false,"fail_count":5}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict FAILED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -eq 0 ]
}
