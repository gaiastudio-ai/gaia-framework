#!/usr/bin/env bats
# review-runner.bats — unit tests for plugins/gaia/scripts/review-runner.sh
# Covers: sequential ordering, per-reviewer gate-write, failure propagation,
# crash handling, parallel rejection, missing-arg handling (AC1-AC5, AC-EC1-EC5).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-runner.sh"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts/stories"
  mkdir -p "$ART"

  # Create a mock review-gate.sh that logs invocations
  MOCK_DIR="$TEST_TMP/mock-bin"
  mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/review-gate.sh" <<'MOCK'
#!/usr/bin/env bash
echo "review-gate: $*" >> "${GATE_LOG:-/tmp/gate-log.txt}"
exit 0
MOCK
  chmod +x "$MOCK_DIR/review-gate.sh"
  export GATE_LOG="$TEST_TMP/gate-log.txt"
  export REVIEW_GATE_SCRIPT="$MOCK_DIR/review-gate.sh"
}

teardown() { common_teardown; }

seed_story() {
  local key="$1" verdict="${2:-UNVERIFIED}"
  cat > "$ART/${key}-fake.md" <<EOF
---
key: "$key"
status: review
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $verdict | --- |
| QA Tests | $verdict | --- |
| Security Review | $verdict | --- |
| Test Automation | $verdict | --- |
| Test Review | $verdict | --- |
| Performance Review | $verdict | --- |
EOF
}

# Create mock reviewer scripts that return a verdict
seed_mock_reviewers() {
  local verdict="${1:-PASSED}"
  local mock_dir="$TEST_TMP/mock-reviewers"
  mkdir -p "$mock_dir"
  for reviewer in code-review security-review qa-generate-tests test-automation test-review performance-review; do
    cat > "$mock_dir/$reviewer" <<MOCK
#!/usr/bin/env bash
echo "$verdict"
exit 0
MOCK
    chmod +x "$mock_dir/$reviewer"
  done
  export REVIEWER_MOCK_DIR="$mock_dir"
}

# ---------- AC-EC3: Missing story_key ----------

@test "missing story_key exits non-zero with usage" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]] || [[ "$output" == *"story"* ]] || [[ "$output" == *"required"* ]]
}

# ---------- AC-EC2: Parallel-mode rejection ----------

@test "parallel flag is rejected" {
  seed_story "E99-S1"
  run "$SCRIPT" --parallel "E99-S1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"parallel"* ]]
}

@test "--parallel flag anywhere is rejected" {
  seed_story "E99-S1"
  run "$SCRIPT" "E99-S1" --parallel
  [ "$status" -ne 0 ]
}

# ---------- AC2: Sequential ordering ----------

@test "reviewers are invoked in canonical order" {
  seed_story "E99-S1"
  seed_mock_reviewers "PASSED"
  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]

  # Verify gate log shows the exact canonical order
  [ -f "$GATE_LOG" ]
  local -a expected_order=(
    "Code Review"
    "Security Review"
    "QA Tests"
    "Test Automation"
    "Test Review"
    "Performance Review"
  )
  local idx=0
  while IFS= read -r line; do
    [[ "$line" == *"${expected_order[$idx]}"* ]]
    idx=$((idx + 1))
  done < "$GATE_LOG"
  [ "$idx" -eq 6 ]
}

# ---------- AC3: Per-reviewer gate-write ----------

@test "review-gate.sh called exactly once per reviewer" {
  seed_story "E99-S1"
  seed_mock_reviewers "PASSED"
  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  [ -f "$GATE_LOG" ]
  local count
  count=$(wc -l < "$GATE_LOG")
  [ "$count" -eq 6 ]
}

@test "gate-write includes correct story_key and verdict" {
  seed_story "E99-S1"
  seed_mock_reviewers "PASSED"
  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  grep -q "E99-S1" "$GATE_LOG"
  grep -q "PASSED" "$GATE_LOG"
}

# ---------- AC4: Failure propagation — remaining reviewers still run ----------

@test "on reviewer FAILED, subsequent reviewers still run" {
  seed_story "E99-S1"
  local mock_dir="$TEST_TMP/mock-reviewers"
  mkdir -p "$mock_dir"
  # First reviewer returns FAILED, rest return PASSED
  cat > "$mock_dir/code-review" <<'MOCK'
#!/usr/bin/env bash
echo "FAILED"
exit 0
MOCK
  chmod +x "$mock_dir/code-review"
  for reviewer in security-review qa-generate-tests test-automation test-review performance-review; do
    cat > "$mock_dir/$reviewer" <<'MOCK'
#!/usr/bin/env bash
echo "PASSED"
exit 0
MOCK
    chmod +x "$mock_dir/$reviewer"
  done
  export REVIEWER_MOCK_DIR="$mock_dir"

  run "$SCRIPT" "E99-S1"
  # Should exit non-zero because at least one FAILED
  [ "$status" -ne 0 ]
  # But all 6 gate writes should have happened
  [ -f "$GATE_LOG" ]
  local count
  count=$(wc -l < "$GATE_LOG")
  [ "$count" -eq 6 ]
}

# ---------- AC-EC1: Reviewer crash treated as FAILED ----------

@test "reviewer crash (non-zero exit) recorded as FAILED, sequence continues" {
  seed_story "E99-S1"
  local mock_dir="$TEST_TMP/mock-reviewers"
  mkdir -p "$mock_dir"
  # Second reviewer crashes
  cat > "$mock_dir/code-review" <<'MOCK'
#!/usr/bin/env bash
echo "PASSED"
exit 0
MOCK
  chmod +x "$mock_dir/code-review"
  cat > "$mock_dir/security-review" <<'MOCK'
#!/usr/bin/env bash
exit 42
MOCK
  chmod +x "$mock_dir/security-review"
  for reviewer in qa-generate-tests test-automation test-review performance-review; do
    cat > "$mock_dir/$reviewer" <<'MOCK'
#!/usr/bin/env bash
echo "PASSED"
exit 0
MOCK
    chmod +x "$mock_dir/$reviewer"
  done
  export REVIEWER_MOCK_DIR="$mock_dir"

  run "$SCRIPT" "E99-S1"
  # Non-zero exit because of the crash-as-FAILED
  [ "$status" -ne 0 ]
  # All 6 gate writes should still have happened
  [ -f "$GATE_LOG" ]
  local count
  count=$(wc -l < "$GATE_LOG")
  [ "$count" -eq 6 ]
  # The crashed reviewer should be recorded as FAILED
  grep -q "Security Review.*FAILED" "$GATE_LOG"
}

# ---------- AC-EC4: Gate-write failure does not halt orchestrator ----------

@test "gate-write failure does not halt orchestrator" {
  seed_story "E99-S1"
  seed_mock_reviewers "PASSED"
  # Replace mock review-gate.sh with one that fails on first call
  cat > "$MOCK_DIR/review-gate.sh" <<'MOCK'
#!/usr/bin/env bash
echo "review-gate: $*" >> "${GATE_LOG}"
if [ ! -f "${GATE_LOG}.fail_done" ]; then
  touch "${GATE_LOG}.fail_done"
  exit 1
fi
exit 0
MOCK
  chmod +x "$MOCK_DIR/review-gate.sh"

  run "$SCRIPT" "E99-S1"
  # Should still continue — gate-write failure is non-fatal
  [ -f "$GATE_LOG" ]
  local count
  count=$(wc -l < "$GATE_LOG")
  [ "$count" -eq 6 ]
}

# ---------- AC-EC5: All PASSED does NOT auto-transition to done ----------

@test "all PASSED does not change story state" {
  seed_story "E99-S1"
  seed_mock_reviewers "PASSED"
  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  # Story file should still say review, not done
  grep -q "status: review" "$ART/E99-S1-fake.md"
}

# ---------- E58-S5: new helper coverage (NFR-052 public-fn coverage gate) ----------
#
# Each new helper added by E58-S5 is exercised by an end-to-end script
# invocation that reaches the helper's code path. The bats suite is the
# single source of truth for the behavior; these tests name each helper
# explicitly so the public-fn coverage gate (run-with-coverage.sh) recognizes
# them as covered.

# mock_verdict_for_index — exercised by every MOCK_VERDICTS run.
@test "mock_verdict_for_index: PASS token returns PASSED verdict" {
  seed_story "E99-S1"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"
  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  # 6 PASSED rows in the gate log
  local count
  count=$(grep -c "PASSED" "$GATE_LOG")
  [ "$count" -eq 6 ]
}

# assert_mock_verdicts_when_mock_mode — guard fires before any iteration.
@test "assert_mock_verdicts_when_mock_mode: missing MOCK_VERDICTS exits non-zero" {
  seed_story "E99-S1"
  unset MOCK_VERDICTS
  export MOCK_MODE=true
  run "$SCRIPT" "E99-S1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MOCK_VERDICTS"* ]]
}

# run_skip_check + is_skipped — when REVIEW_SKIP_CHECK_SCRIPT skips a reviewer,
# the loop skips it and emits no gate row for that reviewer in the log.
@test "run_skip_check + is_skipped: skipped reviewers are omitted from the loop" {
  seed_story "E99-S1"
  local stub_dir="$TEST_TMP/orch-stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/skip-check" <<MOCK
#!/usr/bin/env bash
echo '{"skip":["code-review"],"run":["security-review","qa-tests","test-automate","test-review","review-perf"]}'
exit 0
MOCK
  chmod +x "$stub_dir/skip-check"
  export REVIEW_SKIP_CHECK_SCRIPT="$stub_dir/skip-check"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"

  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  # Code Review row was skipped — only 5 gate writes.
  local count
  count=$(wc -l < "$GATE_LOG")
  [ "$count" -eq 5 ]
  ! grep -q "Code Review" "$GATE_LOG"
}

# run_summary_gen — soft-dep call site. Stub returns 0 so no warning fires.
@test "run_summary_gen: stub is invoked after the per-reviewer loop" {
  seed_story "E99-S1"
  local stub_dir="$TEST_TMP/orch-stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/summary-gen" <<MOCK
#!/usr/bin/env bash
echo "summary-gen called" > "$TEST_TMP/summary-gen-trace.txt"
exit 0
MOCK
  chmod +x "$stub_dir/summary-gen"
  export REVIEW_SUMMARY_GEN_SCRIPT="$stub_dir/summary-gen"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"

  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/summary-gen-trace.txt" ]
}

# run_nudge — soft-dep call site. Stub returns 0 so no warning fires.
@test "run_nudge: stub is invoked after summary-gen" {
  seed_story "E99-S1"
  local stub_dir="$TEST_TMP/orch-stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/nudge" <<MOCK
#!/usr/bin/env bash
echo "nudge called" > "$TEST_TMP/nudge-trace.txt"
exit 0
MOCK
  chmod +x "$stub_dir/nudge"
  export REVIEW_NUDGE_SCRIPT="$stub_dir/nudge"
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"

  run "$SCRIPT" "E99-S1"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/nudge-trace.txt" ]
}

# resolve_soft_dep_script — exercised twice above (run_summary_gen + run_nudge);
# this test names the helper explicitly to satisfy the coverage gate.
@test "resolve_soft_dep_script: returns empty for unconfigured soft-dep" {
  seed_story "E99-S1"
  unset REVIEW_SUMMARY_GEN_SCRIPT REVIEW_NUDGE_SCRIPT REVIEW_RUNNER_USE_SUMMARY_GEN REVIEW_RUNNER_USE_NUDGE
  export MOCK_MODE=true
  export MOCK_VERDICTS="PASS,PASS,PASS,PASS,PASS,PASS"
  run "$SCRIPT" "E99-S1"
  # Without override AND without opt-in, soft-dep calls are silent no-ops.
  [ "$status" -eq 0 ]
  ! grep -q "WARNING" <<< "$output"
}
