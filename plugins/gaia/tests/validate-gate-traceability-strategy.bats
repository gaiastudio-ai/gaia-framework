#!/usr/bin/env bats
# validate-gate-traceability-strategy.bats — TC-DRO-21 coverage
#
# Story: E53-S248 (Teach validate-gate.sh traceability_exists to accept the
#                  E53 strategy/ placement).
# Test plan row: TC-DRO-21 (covers AC1, AC3, AC4, AC5, AC6, AC9 of E53-S248).
# Origin: AF-2026-05-08-5 (option B — additive resolver extension).
#
# Resolution order under test (canonical, "first match (existing AND
# non-empty) wins"):
#   1. flat:           ${TEST_ARTIFACTS}/traceability-matrix.md
#   2. sharded-index:  ${TEST_ARTIFACTS}/traceability-matrix/index.md   (E53-S233)
#   3. strategy/:      ${TEST_ARTIFACTS}/strategy/traceability-matrix.md (this story)
#
# Failure-mode contract:
#   - No layout present  -> exit 1, stderr names the FLAT path
#                           (preserves the log-parser contract from
#                           check_file_nonempty).
#   - Resolved file empty -> exit 1, stderr names the RESOLVED path
#                            (so operator can `ls -la` it directly).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/validate-gate.sh"
  export TEST_ARTIFACTS="$TEST_TMP/test-artifacts"
  mkdir -p "$TEST_ARTIFACTS"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Positive cases — first-match-wins resolution
# ---------------------------------------------------------------------------

@test "TC-DRO-21: flat-only layout resolves PASS (AC3 regression-guard)" {
  printf 'matrix\n' > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "TC-DRO-21: sharded-index-only layout resolves PASS (AC4 regression-guard)" {
  mkdir -p "$TEST_ARTIFACTS/traceability-matrix"
  printf 'matrix\n' > "$TEST_ARTIFACTS/traceability-matrix/index.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "TC-DRO-21: strategy/ placement resolves PASS (AC1 — new behavior)" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'matrix\n' > "$TEST_ARTIFACTS/strategy/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "TC-DRO-21: flat wins when flat AND strategy/ both present" {
  # First-match semantic: flat is checked first, so the flat path wins
  # even when strategy/ is also healthy. (No assertion on which path
  # produces the error; we only assert PASS — the script never names
  # a path on success.)
  printf 'matrix\n' > "$TEST_ARTIFACTS/traceability-matrix.md"
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'matrix\n' > "$TEST_ARTIFACTS/strategy/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative case — none-present
# ---------------------------------------------------------------------------

@test "TC-DRO-21: no layout present fails with FLAT-path error (AC5)" {
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: traceability_exists failed"* ]]
  [[ "$output" == *"expected:"* ]]
  # Error names the flat path (log-parser contract).
  [[ "$output" == *"traceability-matrix.md"* ]]
  # Error MUST NOT name the strategy/ path (that path is reachable via the
  # alias arm, not the documented canonical location).
  [[ "$output" != *"strategy/traceability-matrix.md"* ]]
}

# ---------------------------------------------------------------------------
# Empty-file failures — error names the RESOLVED path (AC6)
# ---------------------------------------------------------------------------

@test "TC-DRO-21: flat exists but empty fails with empty-file error naming flat path (AC6)" {
  : > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/traceability-matrix.md"* ]]
  [[ "$output" != *"/strategy/"* ]]
  [[ "$output" != *"/index.md"* ]]
}

@test "TC-DRO-21: sharded-index exists but empty fails with empty-file error naming index.md (AC6)" {
  mkdir -p "$TEST_ARTIFACTS/traceability-matrix"
  : > "$TEST_ARTIFACTS/traceability-matrix/index.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/traceability-matrix/index.md"* ]]
}

@test "TC-DRO-21: strategy/ exists but empty fails with empty-file error naming strategy path (AC6)" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  : > "$TEST_ARTIFACTS/strategy/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/strategy/traceability-matrix.md"* ]]
}

# ---------------------------------------------------------------------------
# --list documentation (AC7)
# ---------------------------------------------------------------------------

@test "TC-DRO-21: --list output mentions strategy/ placement for traceability_exists (AC7)" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  # Find the traceability_exists row and assert it mentions strategy/.
  trace_row=$(printf '%s\n' "$output" | awk '$1 == "traceability_exists" { print; exit }')
  [ -n "$trace_row" ]
  [[ "$trace_row" == *"strategy/traceability-matrix.md"* ]]
}

# ---------------------------------------------------------------------------
# AC8 no-regression spot-checks — other gates byte-identical post-fix
# ---------------------------------------------------------------------------

@test "TC-DRO-21: test_plan_exists unaffected — strategy/test-plan.md does NOT pass" {
  # The strategy alias arm is gate-specific to traceability_exists.
  # An equivalent strategy/ placement for test_plan MUST NOT silently pass.
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'plan\n' > "$TEST_ARTIFACTS/strategy/test-plan.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: test_plan_exists failed"* ]]
}

@test "TC-DRO-21: ci_setup_exists unaffected — strategy/ci-setup.md does NOT pass" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'ci\n' > "$TEST_ARTIFACTS/strategy/ci-setup.md"
  run "$SCRIPT" ci_setup_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: ci_setup_exists failed"* ]]
}
