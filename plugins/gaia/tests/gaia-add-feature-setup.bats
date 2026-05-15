#!/usr/bin/env bats
# gaia-add-feature-setup.bats — E89-S1 prereq-gate extension tests.
#
# Note: setup.sh has hard dependencies on resolve-config.sh (which reads
# ~/.claude/settings.json and config/project-config.yaml + computes
# 11 required fields). Setting all of those up correctly in a bats temp
# dir is non-trivial. These bats therefore test setup.sh's NEW CLI-surface
# behaviour at the FLAG-PARSING + HALT layer, which can be exercised
# without a fully-staged project root because flag-parsing happens BEFORE
# resolve-config (per E89-S1 AC7).
#
# Covers TC-AFE-5 (invalid classification), TC-AFE-6 (unknown flag),
# TC-AFE-7 (SKILL.md no legacy advisory-mode prose). The full TC-AFE-1..4
# integration tests live in skills/gaia-add-feature/tests/ (separate
# project-root fixtures pattern) and are filed as a Finding for follow-up.

load 'test_helper.bash'

setup() {
  common_setup
  SETUP_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts" && pwd)/setup.sh"
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature" && pwd)/SKILL.md"
  export SETUP_SH SKILL_MD
}

teardown() {
  common_teardown
}

# ---------------- TC-AFE-5: invalid classification rejected ----------------
@test "TC-AFE-5: invalid --classification value is rejected before resolve-config" {
  run "$SETUP_SH" --classification frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid classification"* ]]
  [[ "$output" == *"frobnicate"* ]]
}

@test "TC-AFE-5b: classification inline form (--classification=X) is parsed" {
  run "$SETUP_SH" --classification=frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid classification"* ]]
}

# ---------------- TC-AFE-6: unknown flag -> exit 1 ----------------
@test "TC-AFE-6: unknown flag is rejected before resolve-config" {
  run "$SETUP_SH" --frobnicate quux
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

# ---------------- TC-AFE-7: SKILL.md no legacy advisory-mode prose ----------------
@test "TC-AFE-7: SKILL.md Steps 6 and 8b contain no legacy advisory-mode strings" {
  [ -f "$SKILL_MD" ]
  ! grep -qi "advisory mode" "$SKILL_MD"
  ! grep -qi "log a warning and skip" "$SKILL_MD"
  ! grep -qi "silently proceed" "$SKILL_MD"
}

# ---------------- TC-AFE-8: classification flag accepts all 3 valid values ----------------
@test "TC-AFE-8a: classification=patch is accepted (passes flag-parsing)" {
  # The setup.sh will exit at resolve-config (no fully-staged root) but
  # the flag parser MUST accept 'patch' as a valid value (no
  # 'invalid classification' error).
  run "$SETUP_SH" --classification patch
  # status is non-zero (resolve-config will fail), but the failure mode
  # must NOT be 'invalid classification'.
  [[ "$output" != *"invalid classification"* ]]
}

@test "TC-AFE-8b: classification=enhancement is accepted" {
  run "$SETUP_SH" --classification enhancement
  [[ "$output" != *"invalid classification"* ]]
}

@test "TC-AFE-8c: classification=feature is accepted" {
  run "$SETUP_SH" --classification feature
  [[ "$output" != *"invalid classification"* ]]
}

# ---------------- TC-AFE-9: HALT message canonical-substring contract ----------------
@test "TC-AFE-9: setup.sh source contains canonical test-plan HALT message verbatim" {
  # The canonical substring is the contract bats consumers grep for.
  grep -F "test-plan.md is missing — run /gaia-test-design first, then re-invoke /gaia-add-feature" "$SETUP_SH"
}

@test "TC-AFE-9b: setup.sh source contains canonical traceability HALT message verbatim" {
  grep -F "traceability-matrix.md is missing — run /gaia-trace first, then re-invoke /gaia-add-feature" "$SETUP_SH"
}

@test "TC-AFE-9c: setup.sh contains classification-conditional gate" {
  grep -F 'CLASSIFICATION" = "enhancement"' "$SETUP_SH"
  grep -F 'CLASSIFICATION" = "feature"' "$SETUP_SH"
}
