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

@test "flat-only layout resolves PASS ( regression-guard)" {
  printf 'matrix\n' > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "sharded-index-only layout resolves PASS ( regression-guard)" {
  mkdir -p "$TEST_ARTIFACTS/traceability-matrix"
  printf 'matrix\n' > "$TEST_ARTIFACTS/traceability-matrix/index.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "strategy/ placement resolves PASS ( — new behavior)" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'matrix\n' > "$TEST_ARTIFACTS/strategy/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 0 ]
}

@test "flat wins when flat AND strategy/ both present" {
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

@test "no layout present fails with all-paths error" {
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: traceability_exists failed"* ]]
  # AF-2026-05-28-1 / Test07 D-6: the error message used to name ONLY the legacy
  # flat path (the "FLAT-path log-parser contract"). That misled users into
  # thinking the producer wrote elsewhere when the actual issue was a missing
  # file at ANY accepted location. The contract is now "expected one of: ..."
  # listing the canonical planning-artifacts home first plus the 3 legacy
  # fallbacks (flat, strategy/, sharded index.md).
  [[ "$output" == *"expected one of:"* ]]
  [[ "$output" == *"planning-artifacts/traceability-matrix.md"* ]]
  [[ "$output" == *"(canonical)"* ]]
  [[ "$output" == *"traceability-matrix.md"* ]]
  [[ "$output" == *"strategy/traceability-matrix.md"* ]]
}

# ---------------------------------------------------------------------------
# Empty-file failures — error names the RESOLVED path (AC6)
# ---------------------------------------------------------------------------

@test "flat exists but empty fails with empty-file error naming flat path" {
  : > "$TEST_ARTIFACTS/traceability-matrix.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/traceability-matrix.md"* ]]
  [[ "$output" != *"/strategy/"* ]]
  [[ "$output" != *"/index.md"* ]]
}

@test "sharded-index exists but empty fails with empty-file error naming index.md" {
  mkdir -p "$TEST_ARTIFACTS/traceability-matrix"
  : > "$TEST_ARTIFACTS/traceability-matrix/index.md"
  run "$SCRIPT" traceability_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/traceability-matrix/index.md"* ]]
}

@test "strategy/ exists but empty fails with empty-file error naming strategy path" {
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

@test "list output mentions strategy/ placement for traceability_exists" {
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

@test "ci_setup_exists unaffected by — strategy/ci-setup.md does NOT pass" {
  # AI-2026-05-16-9 extended the strategy/ alias to test_plan_exists, mirroring
  # E53-S248's treatment of traceability_exists. ci_setup_exists is NOT in
  # scope — keep this regression guard so future drift is caught.
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'ci\n' > "$TEST_ARTIFACTS/strategy/ci-setup.md"
  run "$SCRIPT" ci_setup_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: ci_setup_exists failed"* ]]
}

# ---------------------------------------------------------------------------
# AI-2026-05-16-9 — test_plan_exists strategy/ alias (mirrors TC-DRO-21 above)
# ---------------------------------------------------------------------------

@test "test_plan_exists flat-only layout resolves PASS (regression-guard)" {
  printf 'plan\n' > "$TEST_ARTIFACTS/test-plan.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "test_plan_exists sharded-index-only layout resolves PASS (regression-guard)" {
  mkdir -p "$TEST_ARTIFACTS/test-plan"
  printf 'plan\n' > "$TEST_ARTIFACTS/test-plan/index.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "test_plan_exists strategy/ placement resolves PASS (new behavior)" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'plan\n' > "$TEST_ARTIFACTS/strategy/test-plan.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 0 ]
}

@test "test_plan_exists no-layout fails with all 4 acceptable paths listed" {
  # AF-2026-05-22-5: the error message used to surface only the flat path.
  # It now lists all 4 acceptable forms (flat / strategy/test-plan.md /
  # strategy/test-strategy.md / test-plan/index.md) so users following the
  # documented /gaia-test-strategy → /gaia-create-epics path see why their
  # test-strategy.md is acceptable. Verify the new "expected one of:" form
  # contains the flat path AND the strategy/test-strategy.md alternate.
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: test_plan_exists failed"* ]]
  [[ "$output" == *"expected:"* ]] || [[ "$output" == *"expected one of:"* ]]
  [[ "$output" == *"test-plan.md"* ]]
  [[ "$output" == *"strategy/test-strategy.md"* ]]
}

@test "test_plan_exists strategy/ empty file fails naming strategy path" {
  mkdir -p "$TEST_ARTIFACTS/strategy"
  : > "$TEST_ARTIFACTS/strategy/test-plan.md"
  run "$SCRIPT" test_plan_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"file is empty (0 bytes)"* ]]
  [[ "$output" == *"/strategy/test-plan.md"* ]]
}

@test "list output mentions strategy/ placement for test_plan_exists" {
  run "$SCRIPT" --list
  [ "$status" -eq 0 ]
  plan_row=$(printf '%s\n' "$output" | awk '$1 == "test_plan_exists" { print; exit }')
  [ -n "$plan_row" ]
  [[ "$plan_row" == *"strategy/test-plan.md"* ]]
}

@test "ci_setup_exists unaffected — strategy/ci-setup.md does NOT pass" {
  # AI-2026-05-16-9 extended the strategy/ alias to test_plan_exists, mirroring
  # E53-S248's treatment of traceability_exists. ci_setup_exists is NOT in
  # scope — keep this regression guard so future drift is caught.
  mkdir -p "$TEST_ARTIFACTS/strategy"
  printf 'ci\n' > "$TEST_ARTIFACTS/strategy/ci-setup.md"
  run "$SCRIPT" ci_setup_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"validate-gate: ci_setup_exists failed"* ]]
}
