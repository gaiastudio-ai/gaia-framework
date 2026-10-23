#!/usr/bin/env bats
# review-gate-hardening.bats — regression tests for proof-of-execution
# optional-suite handling, report column pass-through, pass-suffixed report
# discovery, per-suite exit-code aggregation, data-integrity guards, and
# fail-closed behaviour on malformed evidence.

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
_write_evidence() {
  printf '%s\n' "$2" > "$1"
}

# Write a minimal report file.
_write_report() {
  printf '# Review report\n' > "$1"
}

# Extract the link target from the Code Review **Report:** line in a
# summary file. Returns the path inside the markdown link parentheses.
_extract_code_review_link() {
  sed -n '/^## Code Review$/,/^## /{
    s/^\*\*Report:\*\* \[[^]]*\](\(.*\))$/\1/p
  }' "$1"
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
  [[ "$cr_line" != *".md"* ]]
}

@test "backslash in report path is preserved byte-for-byte (not expanded by awk)" {
  # A path containing a literal backslash-t sequence must survive the awk
  # writer without the backslash being expanded into a tab character.
  local bsdir
  bsdir="$TEST_TMP/a\\tb"
  mkdir -p "$bsdir"
  local report="$bsdir/rep.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report "$report"
  [ "$status" -eq 0 ]

  # The literal path string (with the backslash) must appear in the file,
  # not a tab-expanded version.
  /usr/bin/grep -qF "| $report |" "$STORY_FILE"
  # Confirm no tab character crept in
  run /usr/bin/grep -cP '\t' <<< "$(/usr/bin/grep '| Code Review |' "$STORY_FILE")" 2>/dev/null ||:
  # The line must not contain an actual tab (beyond the original | delimiters)
  local cr_line
  cr_line="$(/usr/bin/grep '| Code Review |' "$STORY_FILE")"
  [[ "$cr_line" != *$'\t'* ]]
}

@test "report path containing pipe character is refused" {
  local report="$TEST_TMP/rep|pipe.md"
  printf '# r\n' > "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report "$report"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipe character"* ]]
}

@test "report path containing newline is refused" {
  local report
  report="$(printf '%s/rep\nforged.md' "$TEST_TMP")"
  printf '# r\n' > "$TEST_TMP/rep"  # in case it creates a partial file

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report "$report"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]]
}

# ---------------------------------------------------------------------------
# AC3: pass-suffixed reports discovered by review-summary-gen.sh
# ---------------------------------------------------------------------------

@test "review-summary-gen finds pass-suffixed report and links the actual file" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create only a pass-suffixed report (not the canonical name)
  local pass_report="$ART/code-review-${STORY_KEY}-pass2.md"
  _write_report "$pass_report"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  [ -f "$summary_file" ]

  # The rendered link must point at the pass-suffixed file, not the
  # canonical (non-existent) name
  local link
  link="$(_extract_code_review_link "$summary_file")"
  [ -n "$link" ]
  [[ "$link" == *"pass2.md" ]]
  [ -f "$link" ]
}

@test "review-summary-gen picks the highest pass number" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create pass2 and pass10 — pass10 must win
  _write_report "$ART/code-review-${STORY_KEY}-pass2.md"
  _write_report "$ART/code-review-${STORY_KEY}-pass10.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  [[ "$link" == *"pass10.md" ]]
}

@test "review-summary-gen does not match pass-suffixed drafts" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Only a draft exists — should be treated as MISSING
  _write_report "$ART/code-review-${STORY_KEY}-pass1-draft.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local content
  content="$(cat "$summary_file")"
  # Must flag Code Review as MISSING because the draft is not a valid pass report
  [[ "$content" == *"MISSING"*"code-review"* ]]
}

@test "review-summary-gen finds pass-suffixed report in reviews/ subdir and links it" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  local pass_report="$reviews_dir/code-review-${STORY_KEY}-pass2.md"
  _write_report "$pass_report"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  [ -n "$link" ]
  [[ "$link" == *"pass2.md" ]]
  [ -f "$link" ]
}

# ---------------------------------------------------------------------------
# AC4: reviews/ subdirectory reports found (regression test)
# ---------------------------------------------------------------------------

@test "review-summary-gen finds report in reviews/ subdir and links it" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  _write_report "$reviews_dir/code-review-${STORY_KEY}.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  [ -n "$link" ]
  [[ "$link" == *"/reviews/code-review-${STORY_KEY}.md" ]]
  [ -f "$link" ]
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
  local ev_file="$TEST_TMP/evidence.json"
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

@test "mixed required suites: one green one red exit_code blocks PASSED" {
  # Catches max->min mutant: min([0,1])=0 would pass; max([0,1])=1 blocks
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"e2e","required":true,"fail_count":0,"exit_code":1}]}'
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

# ---------------------------------------------------------------------------
# Fail-closed: malformed evidence
# ---------------------------------------------------------------------------

@test "malformed JSON evidence blocks PASSED with diagnostic" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" 'NOT JSON AT ALL'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "JSON array evidence blocks PASSED with diagnostic" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '[{"suites":[]}]'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON or is not an object"* ]]
}

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

# ---------------------------------------------------------------------------
# AC9: tests use temp directories, never the real plugin tree
# ---------------------------------------------------------------------------

@test "all test fixtures live in temp directories" {
  [[ "$STORY_FILE" == "${BATS_TEST_TMPDIR}"* ]] || [[ "$STORY_FILE" == /tmp/* ]] || [[ "$STORY_FILE" == /private/tmp/* ]]
}
