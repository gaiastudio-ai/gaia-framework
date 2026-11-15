#!/usr/bin/env bats
# review-gate-proof-of-execution.bats — proof-of-execution gate contract.
#
# Asserts the proof-of-execution contract added to review-gate.sh update and
# review-summary-gen.sh:
#
#   (1) review-gate.sh update --verdict PASSED|FAILED refuses the write when:
#       - neither --report nor --report-missing-reason is supplied; OR
#       - --report points at a non-existent file; OR
#       - the gate is a test-execution gate (QA Tests / Test Automation /
#         Test Review) and --execution-evidence is absent / missing.
#
#   (2) UNVERIFIED verdicts do NOT require proof.
#
#   (3) --report-missing-reason is the documented escape hatch.
#
#   (4) review-summary-gen.sh marks MISSING in the rendered body when a
#       report file referenced by the gate is absent; under
#       REVIEW_SUMMARY_REQUIRE_REPORTS=on, it exits 3.
#
#   (5) The legacy bypass — `update --verdict PASSED` with no proof — is now
#       refused (regression-prevention against the sprint-49 defect class).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  SUMMARY="$SCRIPTS_DIR/review-summary-gen.sh"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  TST="$TEST_TMP/docs/test-artifacts"
  mkdir -p "$ART" "$TST"

  STORY_KEY="POE-S1"
  STORY_FILE="$ART/${STORY_KEY}-fake.md"
  cat > "$STORY_FILE" <<EOF
---
template: 'story'
key: "${STORY_KEY}"
status: review
---

# Story: ${STORY_KEY}

## Review Gate

| Review | Status | Report |
|---|---|---|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
EOF
  # IMPORTANT: do NOT disable proof-of-execution in this suite. The whole
  # point is to exercise the gate.
  unset REVIEW_GATE_PROOF_OF_EXECUTION
}
teardown() { common_teardown; }

# ---------- (1) Verdict write refused without proof ----------

@test "POE: update --verdict PASSED refuses without --report or --report-missing-reason" {
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" --verdict PASSED
  [ "$status" -ne 0 ]
  [[ "$output" == *"proof-of-execution"* ]]
  [[ "$output" == *"requires --report"* ]]
}

@test "POE: update --verdict FAILED refuses without --report or --report-missing-reason" {
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" --verdict FAILED
  [ "$status" -ne 0 ]
  [[ "$output" == *"proof-of-execution"* ]]
}

@test "POE: update --verdict PASSED refuses when --report points at non-existent file" {
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" \
    --verdict PASSED --report "$ART/${STORY_KEY}-code-review.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist on disk"* ]]
}

@test "POE: update --verdict PASSED accepts an existing report file" {
  REPORT="$ART/${STORY_KEY}-code-review.md"
  echo "report body" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" \
    --verdict PASSED --report "$REPORT"
  [ "$status" -eq 0 ]
}

# ---------- (2) UNVERIFIED does NOT require proof ----------

@test "POE: UNVERIFIED verdict needs no proof" {
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" --verdict UNVERIFIED
  [ "$status" -eq 0 ]
}

# ---------- (3) --report-missing-reason escape hatch ----------

@test "POE: --report-missing-reason accepts PASSED without --report" {
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" \
    --verdict PASSED --report-missing-reason "dispatch-failed: skill not installed"
  [ "$status" -eq 0 ]
}

# ---------- Test-execution gates require --execution-evidence ----------

@test "POE: QA Tests gate refuses PASSED without --execution-evidence even with --report" {
  REPORT="$TST/${STORY_KEY}-qa-tests.md"
  echo "report" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "QA Tests" \
    --verdict PASSED --report "$REPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-execution gate"* ]]
  [[ "$output" == *"--execution-evidence"* ]]
}

@test "POE: Test Automation gate refuses PASSED without --execution-evidence" {
  REPORT="$TST/${STORY_KEY}-test-automation.md"
  echo "report" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Test Automation" \
    --verdict PASSED --report "$REPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-execution gate"* ]]
}

@test "POE: Test Review gate refuses PASSED without --execution-evidence" {
  REPORT="$TST/${STORY_KEY}-test-review.md"
  echo "report" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "Test Review" \
    --verdict PASSED --report "$REPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-execution gate"* ]]
}

@test "POE: QA Tests gate accepts PASSED with both --report and --execution-evidence" {
  REPORT="$TST/${STORY_KEY}-qa-tests.md"
  EVIDENCE="$TST/${STORY_KEY}-execution-evidence.json"
  echo "report" > "$REPORT"
  echo '{"suites": [{"name":"unit","required":true,"fail_count":0,"exit_code":0}]}' > "$EVIDENCE"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "QA Tests" \
    --verdict PASSED --report "$REPORT" --execution-evidence "$EVIDENCE"
  [ "$status" -eq 0 ]
}

@test "POE: QA Tests gate refuses --execution-evidence pointing at non-existent file" {
  REPORT="$TST/${STORY_KEY}-qa-tests.md"
  echo "report" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" --gate "QA Tests" \
    --verdict PASSED --report "$REPORT" \
    --execution-evidence "$TST/missing-evidence.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist on disk"* ]]
}

# ---------- review-summary-gen.sh proof-of-execution surfacing ----------

# Helper: seed the gate to PASSED across all 6 rows WITHOUT writing the report
# files (reproduces the verdicts-without-evidence defect class). We bypass POE
# during the seed so the summary-gen scenario can run.
_seed_all_passed_no_reports() {
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "Code Review" --verdict PASSED
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "QA Tests" --verdict PASSED
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "Security Review" --verdict PASSED
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "Test Automation" --verdict PASSED
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "Test Review" --verdict PASSED
  REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update --story "$STORY_KEY" --gate "Performance Review" --verdict PASSED
}

@test "POE: review-summary-gen marks MISSING when report files don't exist" {
  _seed_all_passed_no_reports
  run bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  # Open the generated summary and check for MISSING markers
  SUMMARY_FILE="$ART/${STORY_KEY}-review-summary.md"
  [ -f "$SUMMARY_FILE" ]
  grep -q "MISSING" "$SUMMARY_FILE"
  grep -q "Proof-of-Execution Findings" "$SUMMARY_FILE"
}

@test "POE: review-summary-gen Findings section enumerates each missing gate (printf -- bug regression)" {
  # Regression for the printf-flag bug discovered during user manual test:
  # the Findings section enumeration uses `printf '- **%s** ...'` whose
  # format string starts with `-` and was being parsed as a flag by bash's
  # builtin printf. The fix is `printf --` to terminate flag parsing.
  _seed_all_passed_no_reports
  bash "$SUMMARY" --story "$STORY_KEY" >/dev/null
  SUMMARY_FILE="$ART/${STORY_KEY}-review-summary.md"
  # The Findings section must list ALL six gates as bullet items.
  grep -E '^- \*\*Code Review\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  grep -E '^- \*\*QA Tests\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  grep -E '^- \*\*Security Review\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  grep -E '^- \*\*Test Automation\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  grep -E '^- \*\*Test Review\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  grep -E '^- \*\*Performance Review\*\* \(PASSED\) — MISSING:' "$SUMMARY_FILE"
  # Exactly six bullet items in the Findings section.
  bullet_count=$(awk '/^## Proof-of-Execution Findings/,/^## Aggregate/' "$SUMMARY_FILE" | grep -cE '^- \*\*')
  [ "$bullet_count" = "6" ]
}

@test "POE: review-summary-gen exits 3 under REVIEW_SUMMARY_REQUIRE_REPORTS=on when reports missing" {
  _seed_all_passed_no_reports
  run env REVIEW_SUMMARY_REQUIRE_REPORTS=on bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 3 ]
  [[ "$output" == *"proof-of-execution"* ]] || [[ "$stderr" == *"proof-of-execution"* ]] || true
}

@test "POE: review-summary-gen exits 0 under REVIEW_SUMMARY_REQUIRE_REPORTS=on when reports present" {
  # Create all six report files then seed verdicts via POE-respecting path.
  # Canonical report paths use the type-first naming convention, all under
  # implementation-artifacts/; the test-automate review report token is
  # `test-automate-review`. Seed those exact paths so summary-gen's
  # proof-of-execution check finds them.
  for r in code-review qa-tests security-review test-automate-review test-review performance-review; do
    echo "report body" > "$ART/${r}-${STORY_KEY}.md"
  done
  # Seed all PASSED bypassing POE — the goal here is to verify summary-gen
  # is happy when the reports exist.
  _seed_all_passed_no_reports
  run env REVIEW_SUMMARY_REQUIRE_REPORTS=on bash "$SUMMARY" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
}

# ---------- Regression-prevention against sprint-49 defect class ----------

@test "POE: regression — orchestrator cannot self-seed all 6 PASSED without any report files" {
  # This is the exact failure mode from sprint-49: orchestrator loops over
  # the 6 gates calling `update --verdict PASSED` with no proof. Each call
  # must now refuse.
  for GATE in "Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review"; do
    run bash "$SCRIPT" update --story "$STORY_KEY" --gate "$GATE" --verdict PASSED
    [ "$status" -ne 0 ]
  done
}

# ---------- plan-id refused on test-execution canonical gates ----------

@test "POE: plan-id on QA Tests gate is refused" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED --plan-id "some-plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --plan-id"* ]]
  [[ "$output" == *"QA Tests"* ]]
}

@test "POE: plan-id on Test Automation gate is refused" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "Test Automation" --verdict PASSED --plan-id "some-plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --plan-id"* ]]
}

@test "POE: plan-id on Test Review gate is refused" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "Test Review" --verdict PASSED --plan-id "some-plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --plan-id"* ]]
}

# Regression guard: plan-only gates still accept --plan-id PASSED.
@test "POE: story-validation gate accepts plan-id PASSED (regression guard)" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "story-validation" --verdict PASSED --plan-id "val-run-1"
  [ "$status" -eq 0 ]
}

# Regression guard: test-automate-plan gate still accepts --plan-id PASSED.
@test "POE: test-automate-plan gate accepts plan-id PASSED (regression guard)" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "test-automate-plan" --verdict PASSED --plan-id "ta-plan-1"
  [ "$status" -eq 0 ]
}

@test "POE: sprint-scoped auto plan-id on QA Tests is refused" {
  local ledger="$TEST_TMP/ledger"
  run bash "$SCRIPT" update \
    --sprint sprint-x --gate "QA Tests" --verdict PASSED --ledger "$ledger"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --plan-id"* ]]
}

@test "POE: report-missing-reason with PASSED on test gate coerces to UNVERIFIED" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "Test Review" --verdict PASSED \
    --report-missing-reason "all good"
  [ "$status" -eq 0 ]
  # stderr must name the coercion.
  [[ "$output" == *"recorded as UNVERIFIED"* ]]
  # The Review Gate table must show UNVERIFIED (not PASSED) for Test Review.
  local tr_line
  tr_line="$(grep '| Test Review |' "$STORY_FILE")"
  [[ "$tr_line" == *"UNVERIFIED"* ]]
  [[ "$tr_line" != *"PASSED"* ]]
  # The reason text must appear in the Report column.
  [[ "$tr_line" == *"all good"* ]]
}

@test "POE: report-missing-reason with pipe character on test gate is refused" {
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED \
    --report-missing-reason "has|pipe"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipe character"* ]]
}

@test "POE: coercion fires even with proof-of-execution off" {
  run env REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED \
    --report-missing-reason "reason text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded as UNVERIFIED"* ]]
  local qa_line
  qa_line="$(grep '| QA Tests |' "$STORY_FILE")"
  [[ "$qa_line" == *"UNVERIFIED"* ]]
  [[ "$qa_line" == *"reason text"* ]]
}

@test "POE: plan-id on test gate is refused even with proof-of-execution off" {
  run env REVIEW_GATE_PROOF_OF_EXECUTION=off bash "$SCRIPT" update \
    --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED --plan-id p1
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not accept --plan-id"* ]]
}

@test "POE: both report and report-missing-reason keeps report path in column" {
  REPORT="$TST/${STORY_KEY}-test-review.md"
  echo "report body" > "$REPORT"
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "Test Review" --verdict PASSED \
    --report "$REPORT" --report-missing-reason "r"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded as UNVERIFIED"* ]]
  local tr_line
  tr_line="$(grep '| Test Review |' "$STORY_FILE")"
  [[ "$tr_line" == *"UNVERIFIED"* ]]
  # The report path must appear in the Report column, not the reason text.
  [[ "$tr_line" == *"$REPORT"* ]]
}

@test "POE: report-missing-reason with newline on test gate is refused" {
  local reason
  reason="$(printf 'line1\nline2')"
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED \
    --report-missing-reason "$reason"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]] || [[ "$output" == *"carriage-return"* ]]
}

@test "POE: report-missing-reason with carriage-return on test gate is refused" {
  local reason
  reason="$(printf 'line1\rline2')"
  run bash "$SCRIPT" update --story "$STORY_KEY" \
    --gate "QA Tests" --verdict PASSED \
    --report-missing-reason "$reason"
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline"* ]] || [[ "$output" == *"carriage-return"* ]]
}
