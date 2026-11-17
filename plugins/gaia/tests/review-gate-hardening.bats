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

  STORY_KEY="E900-S1" # lint-pack:allow leaked-identifiers — synthetic fixture story key for gate tests
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

@test "all-optional suites refuses PASSED (no required suite evaluated)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"opt1","required":false,"fail_count":5},{"name":"opt2","required":false,"fail_count":2}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no required suite evaluated"* ]]

  # Row must be unchanged (still UNVERIFIED).
  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
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
  cr_line="$(grep '| Code Review |' "$STORY_FILE")"
  # Positive assertion: em-dash character must be present
  [[ "$cr_line" == *"—"* ]]
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
  # The line must not contain an actual tab (beyond the original | delimiters)
  local cr_line
  cr_line="$(grep '| Code Review |' "$STORY_FILE")"
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

@test "report path containing newline is refused and table unchanged" {
  # Snapshot the table before the attempt
  local before
  before="$(cat "$STORY_FILE")"

  # Use UNVERIFIED so proof-of-execution is not involved — the guard is the
  # only thing that can refuse.
  local report
  report="$(printf '%s/rep\nforged.md' "$TEST_TMP")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict UNVERIFIED \
    --report "$report"
  [ "$status" -ne 0 ]
  [[ "$output" == *"would forge a Review Gate row"* ]]

  # Table must be byte-unchanged
  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

@test "report path containing carriage-return is refused and table unchanged" {
  local before
  before="$(cat "$STORY_FILE")"

  local report
  report="$(printf '%s/rep\rforged.md' "$TEST_TMP")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict UNVERIFIED \
    --report "$report"
  [ "$status" -ne 0 ]
  [[ "$output" == *"would forge a Review Gate row"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
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

@test "non-array suites value blocks PASSED with shape diagnostic" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":"x"}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an array"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

@test "suites entry that is a string blocks PASSED with non-object diagnostic" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":["not-an-object"]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-object entry"* ]]
}

@test "mixed junk and valid green suite is refused (non-object entry)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":["junk",{"name":"unit","required":true,"exit_code":0,"fail_count":0}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  # Snapshot the table before the attempt.
  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-object entry"* ]]

  # Row must be unchanged (still UNVERIFIED).
  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

@test "empty suites array refuses PASSED (no required suite evaluated)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no required suite evaluated"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

@test "evidence with missing suites key refuses PASSED (no required suite evaluated)" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"version":"1.0"}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no required suite evaluated"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
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

@test "review-gate.sh does not write outside the test temp directory" {
  # Snapshot the plugin tree before a representative invocation.
  local plugin_tree="$BATS_TEST_DIRNAME/.."
  local before_count
  before_count="$(find "$plugin_tree" -newer "$STORY_FILE" -type f 2>/dev/null | wc -l | tr -d ' ')"

  # Run an update (UNVERIFIED needs no proof).
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict UNVERIFIED

  # No new files should appear in the plugin tree.
  local after_count
  after_count="$(find "$plugin_tree" -newer "$STORY_FILE" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$before_count" = "$after_count" ]
}

# ---------------------------------------------------------------------------
# Template-path report wins over pass-suffixed fallback
# ---------------------------------------------------------------------------

@test "template path report wins when both template and passN exist" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create BOTH the canonical template-path report AND a passN report.
  local template_report="$ART/code-review-${STORY_KEY}.md"
  _write_report "$template_report"
  _write_report "$ART/code-review-${STORY_KEY}-pass2.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  # Template path must win — basename has no -pass suffix.
  [ "$(basename "$link")" = "code-review-${STORY_KEY}.md" ]
  [ -f "$link" ]

  # Remove the template path — passN should now be linked.
  rm "$template_report"
  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  summary_file="$(echo "$output" | tail -1)"
  link="$(_extract_code_review_link "$summary_file")"
  [ "$(basename "$link")" = "code-review-${STORY_KEY}-pass2.md" ]
}

@test "reviews/ subdir report wins over flat passN" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  # Create a reviews/ canonical copy AND a flat passN — reviews/ must win.
  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  _write_report "$reviews_dir/code-review-${STORY_KEY}.md"
  _write_report "$ART/code-review-${STORY_KEY}-pass3.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  # reviews/ canonical copy must win over flat passN — basename has no -pass suffix.
  [ "$(basename "$link")" = "code-review-${STORY_KEY}.md" ]
  [[ "$link" == */reviews/* ]]
}

@test "pass2 vs pass10 ordering in reviews/ subdir picks pass10" {
  bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Code Review" \
    --verdict PASSED \
    --report-missing-reason "seeding gate"

  local reviews_dir="$ART/epic-E900/${STORY_KEY}-fixture/reviews"
  mkdir -p "$reviews_dir"
  _write_report "$reviews_dir/code-review-${STORY_KEY}-pass2.md"
  _write_report "$reviews_dir/code-review-${STORY_KEY}-pass10.md"

  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  local summary_file
  summary_file="$(echo "$output" | tail -1)"
  local link
  link="$(_extract_code_review_link "$summary_file")"
  [ "$(basename "$link")" = "code-review-${STORY_KEY}-pass10.md" ]
}

# ---------------------------------------------------------------------------
# review-summary-gen.sh uses grep from PATH (no hardcoded /usr/bin/grep)
# ---------------------------------------------------------------------------

@test "review-summary-gen.sh has no hardcoded /usr/bin/grep" {
  local count
  count="$(grep -c '/usr/bin/grep' "$SUMMARY" || true)"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative exit code detected as non-zero in proof-of-execution
# ---------------------------------------------------------------------------

@test "negative exit code in required suite refuses PASSED" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unit","required":true,"fail_count":0,"exit_code":0},{"name":"signal","required":true,"fail_count":0,"exit_code":-1}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exit_code"* ]] || [[ "$output" == *"non-zero"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Required suite missing exit_code key refuses PASSED
# ---------------------------------------------------------------------------

@test "required suite without exit_code key refuses PASSED" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"unitA","required":true}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing exit_code"* ]] || [[ "$output" == *"unitA"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

@test "mixed suites: one with exit_code one without refuses PASSED and names the suite" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"ok-suite","required":true,"exit_code":0},{"name":"no-exit-suite","required":true}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "Test Automation" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-exit-suite"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Placeholder suite with skip_reason does not count as an evaluated required suite
# ---------------------------------------------------------------------------

@test "placeholder suite with skip_reason does not count as evaluated" {
  local ev_file="$TEST_TMP/evidence.json"
  _write_evidence "$ev_file" '{"suites":[{"name":"ph","required":true,"skip_reason":"no command declared"}]}'
  local report="$TEST_TMP/report.md"
  _write_report "$report"

  local before
  before="$(cat "$STORY_FILE")"

  run bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" \
    --verdict PASSED \
    --report "$report" \
    --execution-evidence "$ev_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no required suite evaluated"* ]]

  local after
  after="$(cat "$STORY_FILE")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Legacy path blocks tell parent to write llm-findings.json before resolver
# ---------------------------------------------------------------------------

# Helper: check a SKILL.md file for a write construct (cat > ...llm-findings.json)
# in the Legacy path block, appearing before the verdict-resolver.sh call.
# Returns 0 on pass, 1 on fail with diagnostic on stderr.
_check_legacy_path_write_step() {
  local skill_md="$1" label="$2"
  [ -f "$skill_md" ] || { echo "$label: file not found: $skill_md" >&2; return 1; }
  # Extract the Legacy path block: from "Legacy path" to the next "## " heading.
  local block
  block="$(awk '/Legacy path/,/^## /' "$skill_md")"
  # Match only a shell write construct that targets llm-findings.json
  # (cat > / cat >> / > " patterns), not a bare mention in prose or --llm-findings arg.
  local write_line resolver_line
  write_line="$(echo "$block" | grep -nE '(cat|>)[[:space:]]+.*llm-findings\.json' | head -1 | cut -d: -f1)"
  resolver_line="$(echo "$block" | grep -n 'verdict-resolver\.sh' | head -1 | cut -d: -f1)"
  [ -n "$write_line" ] || { echo "$label: no write construct for llm-findings.json found" >&2; return 1; }
  [ -n "$resolver_line" ] || { echo "$label: no verdict-resolver.sh call found" >&2; return 1; }
  [ "$write_line" -lt "$resolver_line" ] || {
    echo "$label: write construct (line $write_line) must precede resolver call (line $resolver_line)" >&2; return 1
  }
  return 0
}

@test "five review skill Legacy path blocks instruct writing llm-findings.json" {
  local skills_dir="$BATS_TEST_DIRNAME/../skills"
  local skill
  for skill in gaia-code-review gaia-qa-tests gaia-test-review gaia-test-automate gaia-performance-review; do
    _check_legacy_path_write_step "$skills_dir/$skill/SKILL.md" "$skill" || false
  done
}

@test "Legacy path write-step check fails when the write construct is stripped" {
  # Negative test: copy a SKILL.md to a temp file, strip the write construct,
  # and confirm the helper rejects it.
  local skills_dir="$BATS_TEST_DIRNAME/../skills"
  local orig="$skills_dir/gaia-code-review/SKILL.md"
  local stripped="$TEST_TMP/stripped-SKILL.md"
  # Remove lines containing the cat-to-llm-findings write construct.
  sed '/cat.*llm-findings\.json/d' "$orig" > "$stripped"
  run _check_legacy_path_write_step "$stripped" "stripped-fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no write construct"* ]]
}
