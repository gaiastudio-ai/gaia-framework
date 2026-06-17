#!/usr/bin/env bats
# placeholder-test-detector.bats — E67-S2 deterministic placeholder gate
#
# Bats coverage for plugins/gaia/scripts/review-common/placeholder-test-detector.sh.
# Each placeholder pattern documented in AC1 / Subtask 1.1 has at least one
# focused fixture; mixed-content fixtures cover the line-number contract and
# the "clean file" path; SKILL.md cross-references cover AC8.
#
# Refs: AC1, AC2, AC3, AC4, AC7, AC8, FR-RSV2-1, FR-RSV2-2, FR-RSV2-4.

setup() {
  DETECTOR="${BATS_TEST_DIRNAME}/../scripts/review-common/placeholder-test-detector.sh"
  TMPDIR_LOCAL="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR_LOCAL}"
}

# ---------------------------------------------------------------------------
# AC1 — single-pattern detection per documented placeholder
# ---------------------------------------------------------------------------

@test "detects expect(true) placeholder" {
  cat > "${TMPDIR_LOCAL}/a.test.ts" <<'EOF'
test('a', () => { expect(true).toBe(true); });
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/a.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
  [[ "$output" == *"a.test.ts:1"* ]]
}

@test "detects expect(false) placeholder" {
  cat > "${TMPDIR_LOCAL}/b.test.ts" <<'EOF'
test('b', () => { expect(false).toBe(true); });
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/b.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
}

@test "detects assert True (Python)" {
  cat > "${TMPDIR_LOCAL}/c_test.py" <<'EOF'
def test_c():
    assert True
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/c_test.py"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
}

@test "detects assert False (Python)" {
  cat > "${TMPDIR_LOCAL}/d_test.py" <<'EOF'
def test_d():
    assert False
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/d_test.py"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
}

@test "detects assert_true / assert_false" {
  cat > "${TMPDIR_LOCAL}/e.test.ts" <<'EOF'
test('e', () => { assert_true(1); });
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/e.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
  cat > "${TMPDIR_LOCAL}/e2.test.ts" <<'EOF'
test('e2', () => { assert_false(0); });
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/e2.test.ts"
  [ "$status" -ne 0 ]
}

@test "detects test.todo" {
  cat > "${TMPDIR_LOCAL}/f.test.ts" <<'EOF'
test.todo('not yet implemented');
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/f.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
}

@test "detects test.skip / it.skip / xit / xdescribe / xcontext / describe.skip" {
  for pattern in 'test.skip(' 'it.skip(' 'xit(' 'xdescribe(' 'xcontext(' 'describe.skip('; do
    cat > "${TMPDIR_LOCAL}/p.test.ts" <<EOF
${pattern}'x', () => {});
EOF
    run "$DETECTOR" --file "${TMPDIR_LOCAL}/p.test.ts"
    [ "$status" -ne 0 ] || { echo "pattern $pattern not detected"; return 1; }
  done
}

@test "detects empty it block (no assertion)" {
  cat > "${TMPDIR_LOCAL}/g.test.ts" <<'EOF'
it('does nothing', () => {});
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/g.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"low_quality_test_generated"* ]]
  [[ "$output" == *"empty_block"* || "$output" == *"empty"* ]]
}

# ---------------------------------------------------------------------------
# Clean files — exit 0
# ---------------------------------------------------------------------------

@test "clean file with real assertions exits 0 with no output" {
  cat > "${TMPDIR_LOCAL}/clean.test.ts" <<'EOF'
import { calculateTotal } from '../src/billing';
test('calculateTotal sums line items', () => {
  expect(calculateTotal([{ amount: 10 }, { amount: 32 }])).toBe(42);
});
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/clean.test.ts"
  [ "$status" -eq 0 ]
}

@test "Python clean file with real assertion exits 0" {
  cat > "${TMPDIR_LOCAL}/clean_test.py" <<'EOF'
from billing import calculate_total
def test_calculate_total():
    assert calculate_total([10, 32]) == 42
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/clean_test.py"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Mixed file — line numbers + structured findings
# ---------------------------------------------------------------------------

@test "mixed file with placeholder on line 30 reports correct line" {
  {
    for i in $(seq 1 29); do
      printf "test('real%d', () => { expect(%d).toBe(%d); });\n" "$i" "$i" "$i"
    done
    printf "xit('skipped real test', () => { expect(false).toBe(false); });\n"
  } > "${TMPDIR_LOCAL}/mixed.test.ts"
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/mixed.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mixed.test.ts:30"* ]]
}

@test "structured finding format: low_quality_test_generated|<file>:<line>|<pattern>" {
  cat > "${TMPDIR_LOCAL}/struct.test.ts" <<'EOF'
test.todo('placeholder');
EOF
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/struct.test.ts"
  [ "$status" -ne 0 ]
  # Structured: pipe-delimited finding name | path:line | pattern
  [[ "$output" =~ low_quality_test_generated\|.*struct\.test\.ts:1\|.* ]]
}

# ---------------------------------------------------------------------------
# Modes — --file vs --dir
# ---------------------------------------------------------------------------

@test "--dir mode recurses and reports per-file findings" {
  mkdir -p "${TMPDIR_LOCAL}/sub"
  cat > "${TMPDIR_LOCAL}/sub/x.test.ts" <<'EOF'
test.skip('x', () => {});
EOF
  cat > "${TMPDIR_LOCAL}/sub/y.test.ts" <<'EOF'
test('y', () => { expect(2 + 2).toBe(4); });
EOF
  run "$DETECTOR" --dir "${TMPDIR_LOCAL}/sub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"x.test.ts"* ]]
  # y.test.ts is clean, must not appear with a finding
  ! [[ "$output" =~ low_quality_test_generated\|.*y\.test\.ts ]]
}

@test "--dir mode with all clean files exits 0" {
  mkdir -p "${TMPDIR_LOCAL}/clean"
  cat > "${TMPDIR_LOCAL}/clean/a.test.ts" <<'EOF'
test('a', () => { expect(1).toBe(1); });
EOF
  cat > "${TMPDIR_LOCAL}/clean/b.test.ts" <<'EOF'
test('b', () => { expect('s').toEqual('s'); });
EOF
  run "$DETECTOR" --dir "${TMPDIR_LOCAL}/clean"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run "$DETECTOR" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"placeholder-test-detector.sh"* ]]
}

@test "no args: usage error and non-zero exit" {
  run "$DETECTOR"
  [ "$status" -ne 0 ]
}

@test "missing file path: error and non-zero exit" {
  run "$DETECTOR" --file "${TMPDIR_LOCAL}/nonexistent.test.ts"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC8 — single-instance shared script (no duplication under skill scripts/)
# ---------------------------------------------------------------------------

@test "detector ships under review-common/ (single instance)" {
  REVIEW_COMMON="${BATS_TEST_DIRNAME}/../scripts/review-common/placeholder-test-detector.sh"
  [ -x "$REVIEW_COMMON" ]
}

@test "no duplicate copy under gaia-test-automate/scripts/" {
  DUP="${BATS_TEST_DIRNAME}/../skills/gaia-test-automate/scripts/placeholder-test-detector.sh"
  [ ! -e "$DUP" ]
}

@test "no duplicate copy under gaia-test-review/scripts/" {
  DUP="${BATS_TEST_DIRNAME}/../skills/gaia-test-review/scripts/placeholder-test-detector.sh"
  [ ! -e "$DUP" ]
}

@test "gaia-test-automate SKILL.md references the shared detector" {
  SKILL_FILE="${BATS_TEST_DIRNAME}/../skills/gaia-test-automate/SKILL.md"
  grep -q "review-common/placeholder-test-detector.sh" "$SKILL_FILE"
}

@test "gaia-test-review SKILL.md references the shared detector" {
  SKILL_FILE="${BATS_TEST_DIRNAME}/../skills/gaia-test-review/SKILL.md"
  grep -q "review-common/placeholder-test-detector.sh" "$SKILL_FILE"
}

# ---------------------------------------------------------------------------
# AC6 — /gaia-run-all-reviews excludes /gaia-test-automate by default
# ---------------------------------------------------------------------------

@test "gaia-run-all-reviews SKILL.md documents test-automate exclusion" {
  SKILL_FILE="${BATS_TEST_DIRNAME}/../skills/gaia-run-all-reviews/SKILL.md"
  # Either an explicit exclusion note OR test-automate is documented as
  # action-skill triggered only on demand / by qa or test-review gaps.
  grep -E "test-automate.*(excluded|action.?skill|triggered)" "$SKILL_FILE" \
    || grep -E "(excluded|on.?demand|action.?skill).*test-automate" "$SKILL_FILE"
}

# ---------------------------------------------------------------------------
# AC2 — Phase 2 detector wiring (presence of mandatory gate call)
# ---------------------------------------------------------------------------

@test "phase2-execute.sh invokes placeholder-test-detector.sh by default" {
  PHASE2="${BATS_TEST_DIRNAME}/../skills/gaia-test-automate/scripts/phase2-execute.sh"
  grep -q "placeholder-test-detector.sh" "$PHASE2"
}

# ---------------------------------------------------------------------------
# AC3 — --scaffold flag skips detector
# ---------------------------------------------------------------------------

@test "phase2-execute.sh recognizes --scaffold and skips detector when set" {
  PHASE2="${BATS_TEST_DIRNAME}/../skills/gaia-test-automate/scripts/phase2-execute.sh"
  grep -q -- "--scaffold" "$PHASE2"
  # The skip path mentions "scaffold" near the detector invocation
  grep -B5 -A5 "placeholder-test-detector.sh" "$PHASE2" | grep -q -i "scaffold"
}

# ---------------------------------------------------------------------------
# AC7 — verdict-resolver action-skill semantics
# ---------------------------------------------------------------------------

@test "verdict-resolver supports --action-mode for test-automate" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  grep -E -- "(--action-mode|action_mode|action-skill)" "$RESOLVER"
}

@test "action-mode APPROVE — plan present, execution success, no placeholders" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  cat > "${TMPDIR_LOCAL}/approve.json" <<'EOF'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":false}
EOF
  run "$RESOLVER" --action-mode --analysis-results "${TMPDIR_LOCAL}/approve.json"
  [ "$status" -eq 0 ]
  [[ "$output" == "APPROVE" ]]
}

@test "action-mode REQUEST_CHANGES — placeholders detected" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  cat > "${TMPDIR_LOCAL}/req-ph.json" <<'EOF'
{"plan":"present","execution":"success","placeholders":true,"mocks_sut":false,"breaks_suite":false}
EOF
  run "$RESOLVER" --action-mode --analysis-results "${TMPDIR_LOCAL}/req-ph.json"
  [ "$status" -eq 0 ]
  [[ "$output" == "REQUEST_CHANGES" ]]
}

@test "action-mode REQUEST_CHANGES — tests mock the SUT" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  cat > "${TMPDIR_LOCAL}/req-mock.json" <<'EOF'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":true,"breaks_suite":false}
EOF
  run "$RESOLVER" --action-mode --analysis-results "${TMPDIR_LOCAL}/req-mock.json"
  [[ "$output" == "REQUEST_CHANGES" ]]
}

@test "action-mode REQUEST_CHANGES — generated tests break the suite" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  cat > "${TMPDIR_LOCAL}/req-break.json" <<'EOF'
{"plan":"present","execution":"success","placeholders":false,"mocks_sut":false,"breaks_suite":true}
EOF
  run "$RESOLVER" --action-mode --analysis-results "${TMPDIR_LOCAL}/req-break.json"
  [[ "$output" == "REQUEST_CHANGES" ]]
}

@test "action-mode BLOCKED — plan_tamper / target_outside / runner_unavailable / drift / malformed" {
  RESOLVER="${BATS_TEST_DIRNAME}/../scripts/verdict-resolver.sh"
  for failure_mode in plan_tamper target_outside_allowlist runner_unavailable plan_drift malformed_output; do
    cat > "${TMPDIR_LOCAL}/blocked.json" <<EOF
{"blocking_failure":"${failure_mode}"}
EOF
    run "$RESOLVER" --action-mode --analysis-results "${TMPDIR_LOCAL}/blocked.json"
    [[ "$output" == "BLOCKED" ]] || { echo "failure_mode=$failure_mode not BLOCKED, got $output"; return 1; }
  done
}
