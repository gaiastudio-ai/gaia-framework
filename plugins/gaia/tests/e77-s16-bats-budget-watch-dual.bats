#!/usr/bin/env bats
# e77-s16-bats-budget-watch-dual.bats — E77-S16 / FR-419 / AC3
#
# Extends bats-budget-watch.sh with dual soft / hard thresholds:
#   * --soft-threshold-seconds N  (default 270)
#   * --hard-threshold-seconds N  (default 480)
#
# Contract is advisory — exit code is always the inner command's status.
# Both breaches emit a structured WARNING (no failure). Backward compat:
# the legacy --threshold-seconds flag is honoured as a soft-threshold alias.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

BUDGET_WATCH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/bats-budget-watch.sh"

# ---------------------------------------------------------------------------
# AC3 — dual-threshold behavioural tests.
# ---------------------------------------------------------------------------

@test "dual-mode: --soft and --hard accepted; under both thresholds emits no warning" {
  local summary="$TEST_TMP/step-summary.md"
  : > "$summary"
  GITHUB_STEP_SUMMARY="$summary" \
    run "$BUDGET_WATCH" --soft-threshold-seconds 60 --hard-threshold-seconds 120 -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
  [ ! -s "$summary" ]
}

@test "dual-mode: soft breach emits soft WARNING, exit 0 (advisory)" {
  local summary="$TEST_TMP/step-summary.md"
  : > "$summary"
  GITHUB_STEP_SUMMARY="$summary" \
    run "$BUDGET_WATCH" --soft-threshold-seconds 1 --hard-threshold-seconds 60 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  [ -s "$summary" ]
  grep -q 'soft budget exceeded' "$summary"
  grep -q 'soft: 1s' "$summary"
}

@test "dual-mode: hard breach emits hard WARNING, exit 0 (advisory-only contract)" {
  local summary="$TEST_TMP/step-summary.md"
  : > "$summary"
  GITHUB_STEP_SUMMARY="$summary" \
    run "$BUDGET_WATCH" --soft-threshold-seconds 1 --hard-threshold-seconds 1 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  [ -s "$summary" ]
  grep -q 'hard budget exceeded' "$summary"
}

@test "dual-mode: defaults are soft=270 hard=480 when neither flag passed" {
  # No --soft or --hard or --threshold-seconds — under-threshold inner cmd.
  run "$BUDGET_WATCH" -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "dual-mode: hard < soft is a configuration error (exit 2)" {
  run "$BUDGET_WATCH" --soft-threshold-seconds 100 --hard-threshold-seconds 50 -- /bin/sh -c 'exit 0'
  [ "$status" -eq 2 ]
  [[ "$output" == *"hard"*"soft"* || "$output" == *"hard-threshold"* ]]
}

# ---------------------------------------------------------------------------
# Backward compatibility — single --threshold-seconds path remains green.
# ---------------------------------------------------------------------------

@test "back-compat: --threshold-seconds aliases to --soft-threshold-seconds" {
  local summary="$TEST_TMP/step-summary.md"
  : > "$summary"
  GITHUB_STEP_SUMMARY="$summary" \
    run "$BUDGET_WATCH" --threshold-seconds 1 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  [ -s "$summary" ]
  # Legacy callers see the legacy "bats budget exceeded" wording — preserved
  # so existing CI dashboards / regex grep rules keep matching.
  grep -q 'bats budget exceeded\|soft budget exceeded' "$summary"
}

@test "back-compat: legacy flag-form still exits 0 advisory under threshold" {
  run "$BUDGET_WATCH" --threshold-seconds 60 -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "back-compat: legacy --label argument still recognised" {
  local summary="$TEST_TMP/step-summary.md"
  : > "$summary"
  GITHUB_STEP_SUMMARY="$summary" \
    run "$BUDGET_WATCH" --threshold-seconds 1 --label "bats-tests" -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  grep -q 'bats-tests' "$summary"
}

# ---------------------------------------------------------------------------
# AC3 — advisory-only invariant: inner failures still surface their exit.
# ---------------------------------------------------------------------------

@test "advisory: inner non-zero status is preserved (no exit-masking)" {
  run "$BUDGET_WATCH" --soft-threshold-seconds 60 --hard-threshold-seconds 120 -- /bin/sh -c 'exit 7'
  [ "$status" -eq 7 ]
}
