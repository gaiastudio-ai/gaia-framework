#!/usr/bin/env bats
# e37-s2-wire-composite-check.bats
#
# Integration coverage for E37-S2 — Wire composite review-gate-check into
# the 6 review commands (gaia-code-review, gaia-qa-tests, gaia-test-review,
# gaia-security-review, gaia-test-automate, gaia-review-perf).
#
# The 6 consumer SKILL.md files each gain a final composite-check step that
# invokes `review-gate.sh review-gate-check --story "{story_key}"` AFTER
# their individual gate update completes.
#
# Covers:
#   AC1 — each of the 6 SKILL.md files contains the composite check
#          invocation with the correct review-gate-check shape
#   AC2 — the composite check step appears AFTER the individual gate
#          update step (positional ordering in the markdown)
#   AC3 — gaia-test-automate does NOT invoke the composite check on
#          the Abort path (Val INFO #2: the Abort path returns without
#          a verdict, so composite check is implicitly skipped)
#   AC4 — the composite check is documented as informational-only
#          (non-zero exit codes do not halt the command)
#
# E37-S2 introduces NO new public shell functions — pure wire-up into
# existing SKILL.md files. No additional unit tests required (NFR-052).

load 'test_helper.bash'

setup() {
  common_setup
}

teardown() { common_teardown; }

SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

# ---------------------------------------------------------------------------
# AC1 — each of the 6 SKILL.md files invokes review-gate-check
# ---------------------------------------------------------------------------

@test "gaia-code-review SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-code-review/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

@test "gaia-qa-tests SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-qa-tests/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

@test "gaia-test-review SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-test-review/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

@test "gaia-security-review SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-security-review/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

@test "gaia-test-automate SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-test-automate/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

@test "gaia-review-perf SKILL.md invokes review-gate-check" {
  local skill="$SKILLS_DIR/gaia-review-perf/SKILL.md"
  [ -f "$skill" ]
  grep -q 'review-gate-check' "$skill"
  grep -q 'review-gate.sh' "$skill"
  grep -q -- '--story' "$skill"
}

# ---------------------------------------------------------------------------
# AC1 — invocation shape matches the shipped CLI contract
# (review-gate.sh review-gate-check --story "{story_key}")
# ---------------------------------------------------------------------------

@test "gaia-code-review uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-code-review/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

@test "gaia-qa-tests uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-qa-tests/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

@test "gaia-test-review uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-test-review/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

@test "gaia-security-review uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-security-review/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

@test "gaia-test-automate uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-test-automate/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

@test "gaia-review-perf uses correct invocation shape" {
  local skill="$SKILLS_DIR/gaia-review-perf/SKILL.md"
  grep -Eq 'review-gate\.sh\s+review-gate-check\s+--story' "$skill"
}

# ---------------------------------------------------------------------------
# AC2 — composite check appears AFTER the individual gate update step
# The individual gate update uses "review-gate.sh update --story" and the
# composite check uses "review-gate-check". The composite MUST appear at
# a higher line number than the individual update.
# ---------------------------------------------------------------------------

_assert_composite_after_individual() {
  local skill="$1"
  local update_line composite_line
  update_line=$(grep -n 'review-gate\.sh update' "$skill" | tail -1 | cut -d: -f1)
  composite_line=$(grep -n 'review-gate-check' "$skill" | tail -1 | cut -d: -f1)
  [ -n "$update_line" ]
  [ -n "$composite_line" ]
  [ "$composite_line" -gt "$update_line" ]
}

@test "gaia-code-review composite step appears after individual update" {
  _assert_composite_after_individual "$SKILLS_DIR/gaia-code-review/SKILL.md"
}

@test "gaia-qa-tests composite step appears after individual update" {
  _assert_composite_after_individual "$SKILLS_DIR/gaia-qa-tests/SKILL.md"
}

@test "gaia-test-review composite step appears after individual update" {
  _assert_composite_after_individual "$SKILLS_DIR/gaia-test-review/SKILL.md"
}

@test "gaia-security-review composite step appears after individual update" {
  _assert_composite_after_individual "$SKILLS_DIR/gaia-security-review/SKILL.md"
}

@test "gaia-test-automate composite step appears after approval gate" {
  local skill="$SKILLS_DIR/gaia-test-automate/SKILL.md"
  # test-automate uses a two-phase architecture. The composite check must
  # appear after the approval gate (Step 7) PASSED branch, not after a
  # "review-gate.sh update" individual gate update (which happens in Phase 2).
  # The composite check must appear in the PASSED branch of Step 7.
  local passed_line composite_line
  passed_line=$(grep -n 'PASSED' "$skill" | grep -i 'verdict\|approve' | tail -1 | cut -d: -f1)
  composite_line=$(grep -n 'review-gate-check' "$skill" | tail -1 | cut -d: -f1)
  [ -n "$passed_line" ]
  [ -n "$composite_line" ]
  [ "$composite_line" -gt "$passed_line" ]
}

@test "gaia-review-perf composite step appears after individual update" {
  _assert_composite_after_individual "$SKILLS_DIR/gaia-review-perf/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC3 — gaia-test-automate Abort path does NOT invoke composite check
# (Val INFO #2: Abort path returns without a verdict, so composite check
# must not be wired into the Abort path)
# ---------------------------------------------------------------------------

@test "gaia-test-automate Abort path does not invoke composite check" {
  local skill="$SKILLS_DIR/gaia-test-automate/SKILL.md"
  # Extract the Abort section text. The Abort action starts with "On **Abort**"
  # or "- On **Abort**" and ends at the next major section (Step, ##, or **7.6**).
  # If review-gate-check appears in that region, the test FAILS.
  local abort_start abort_end
  abort_start=$(grep -n 'On \*\*Abort\*\*' "$skill" | head -1 | cut -d: -f1)
  # Find the next section boundary after the Abort line
  abort_end=$(awk -v start="$abort_start" '
    NR > start && /^(### |## |\*\*7\.[0-9])/ { print NR; exit }
  ' "$skill")
  [ -n "$abort_start" ]
  [ -n "$abort_end" ]
  # Extract the Abort region and assert review-gate-check is NOT present
  run sed -n "${abort_start},${abort_end}p" "$skill"
  [[ "$output" != *"review-gate-check"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — composite check is documented as informational-only (non-halt)
# Each SKILL.md must document that non-zero exit codes from the composite
# check do not halt the command.
# ---------------------------------------------------------------------------

@test "gaia-code-review documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-code-review/SKILL.md"
  # Must mention informational/non-halt semantics near the composite check
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

@test "gaia-qa-tests documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-qa-tests/SKILL.md"
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

@test "gaia-test-review documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-test-review/SKILL.md"
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

@test "gaia-security-review documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-security-review/SKILL.md"
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

@test "gaia-test-automate documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-test-automate/SKILL.md"
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

@test "gaia-review-perf documents composite check as informational" {
  local skill="$SKILLS_DIR/gaia-review-perf/SKILL.md"
  grep -iq 'informational\|non-halt\|do not halt\|does not halt\|no halt' "$skill"
}

# ---------------------------------------------------------------------------
# Regression guard — all 6 SKILL.md files still contain their original
# individual gate update (the composite check is additive, not a replacement)
# ---------------------------------------------------------------------------

@test "Regression: gaia-code-review retains individual gate update" {
  grep -q 'review-gate.sh.*update.*--gate "Code Review"' "$SKILLS_DIR/gaia-code-review/SKILL.md"
}

@test "Regression: gaia-qa-tests retains individual gate update" {
  grep -q 'review-gate.sh.*update.*--gate "QA Tests"' "$SKILLS_DIR/gaia-qa-tests/SKILL.md"
}

@test "Regression: gaia-test-review retains individual gate update" {
  grep -q 'review-gate.sh.*update.*--gate "Test Review"' "$SKILLS_DIR/gaia-test-review/SKILL.md"
}

@test "Regression: gaia-security-review retains individual gate update" {
  grep -q 'review-gate.sh.*update.*--gate "Security Review"' "$SKILLS_DIR/gaia-security-review/SKILL.md"
}

@test "Regression: gaia-review-perf retains individual gate update" {
  grep -q 'review-gate.sh.*update.*--gate "Performance Review"' "$SKILLS_DIR/gaia-review-perf/SKILL.md"
}
