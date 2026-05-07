#!/usr/bin/env bats
# e45-s6-bats-budget-watch.bats
#
# E45-S6 — CI bats-tests budget-watch invariant (AC3).
#
# bats-budget-watch.sh wraps the bats suite invocation, captures wall-clock
# duration, and emits a structured warning when duration exceeds a configurable
# threshold. The warning lands in $GITHUB_STEP_SUMMARY so it surfaces on the
# PR. Exit code is always 0 — this is an advisory gate, never a hard fail
# (per ADR-062 §Recommendation: warn before we fail).
#
# Functions under test:
#   bats_budget_watch_check  — main entry, parses args, runs the inner cmd,
#                              measures elapsed seconds, writes warning if
#                              elapsed > threshold.
#
# Internal helpers (leading-underscore prefix per NFR-052 allowlist):
#   _bats_format_warning      — formats the structured warning markdown block.
#   _bats_elapsed_seconds     — diff between two epoch seconds.
#   _bats_emit_warning        — appends warning to $GITHUB_STEP_SUMMARY (or
#                               stdout when the env var is unset).
#
# Test pattern: black-box invocations through the CLI plus targeted unit
# coverage of _bats_* internals via sourced function extraction.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

BUDGET_WATCH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/bats-budget-watch.sh"

# ---------------------------------------------------------------------------
# Helper: source the script's library functions without triggering main().
# ---------------------------------------------------------------------------
_source_budget_watch_lib() {
  # shellcheck disable=SC1090
  BATS_BUDGET_WATCH_LIB_ONLY=1 source "$BUDGET_WATCH"
}

# ---------------------------------------------------------------------------
# AC3 behavioural tests — black-box via CLI.
# ---------------------------------------------------------------------------

@test "bats_budget_watch_check exits 0 when inner command succeeds under threshold" {
  run "$BUDGET_WATCH" --threshold-seconds 60 -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "bats_budget_watch_check exits 0 when inner command exceeds threshold (advisory only)" {
  # 2-second sleep, 1-second threshold — must exceed but still exit 0.
  run "$BUDGET_WATCH" --threshold-seconds 1 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
}

@test "bats_budget_watch_check emits structured warning when threshold exceeded" {
  local summary_file="$TEST_TMP/step-summary.md"
  : > "$summary_file"
  GITHUB_STEP_SUMMARY="$summary_file" \
    run "$BUDGET_WATCH" --threshold-seconds 1 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  [ -s "$summary_file" ]
  grep -q 'bats budget exceeded' "$summary_file"
  grep -q 'threshold: 1s' "$summary_file"
  grep -q 'elapsed:' "$summary_file"
}

@test "bats_budget_watch_check does not emit warning when under threshold" {
  local summary_file="$TEST_TMP/step-summary.md"
  : > "$summary_file"
  GITHUB_STEP_SUMMARY="$summary_file" \
    run "$BUDGET_WATCH" --threshold-seconds 60 -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
  # File stays empty when no warning is needed.
  [ ! -s "$summary_file" ]
}

@test "bats_budget_watch_check propagates inner command failure" {
  # Inner failure should make us exit non-zero — the wrapper preserves
  # the inner exit code so a real bats failure still fails the CI step.
  run "$BUDGET_WATCH" --threshold-seconds 60 -- /bin/sh -c 'exit 1'
  [ "$status" -ne 0 ]
}

@test "bats_budget_watch_check accepts no --threshold-seconds (FR-419 defaults)" {
  # E77-S16 / FR-419 amends the original "missing --threshold-seconds is an
  # error" contract: when no threshold flag is passed, the wrapper now
  # applies the canonical FR-419 defaults (soft=270, hard=480) and runs the
  # inner command in advisory dual-threshold mode. This preserves single-
  # threshold callers (they still pass --threshold-seconds explicitly) while
  # making the no-flag path useful for ad-hoc local invocations.
  run "$BUDGET_WATCH" -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "bats_budget_watch_check rejects missing -- separator" {
  run "$BUDGET_WATCH" --threshold-seconds 60 /bin/sh -c 'exit 0'
  [ "$status" -ne 0 ]
  [[ "$output" == *"--"* ]]
}

@test "bats_budget_watch_check warning falls back to stdout when GITHUB_STEP_SUMMARY unset" {
  unset GITHUB_STEP_SUMMARY
  run "$BUDGET_WATCH" --threshold-seconds 1 -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats budget exceeded"* ]]
}

@test "bats_budget_watch_check honours --label argument in warning text" {
  local summary_file="$TEST_TMP/step-summary.md"
  : > "$summary_file"
  GITHUB_STEP_SUMMARY="$summary_file" \
    run "$BUDGET_WATCH" --threshold-seconds 1 --label "bats-tests" -- /bin/sh -c 'sleep 2'
  [ "$status" -eq 0 ]
  grep -q 'bats-tests' "$summary_file"
}

# ---------------------------------------------------------------------------
# Internal-helper unit tests — leading-underscore prefix, exempt from NFR-052
# textual coverage gate but exercised here for behaviour.
# ---------------------------------------------------------------------------

@test "_bats_elapsed_seconds returns difference between two epoch seconds" {
  _source_budget_watch_lib
  result="$(_bats_elapsed_seconds 100 137)"
  [ "$result" -eq 37 ]
}

@test "_bats_elapsed_seconds returns 0 when end == start" {
  _source_budget_watch_lib
  result="$(_bats_elapsed_seconds 500 500)"
  [ "$result" -eq 0 ]
}

@test "_bats_elapsed_seconds returns 0 when end < start (clock skew guard)" {
  _source_budget_watch_lib
  result="$(_bats_elapsed_seconds 100 50)"
  [ "$result" -eq 0 ]
}

@test "_bats_format_warning produces the canonical markdown block" {
  _source_budget_watch_lib
  out="$(_bats_format_warning "bats-tests" 240 180)"
  [[ "$out" == *"bats budget exceeded"* ]]
  [[ "$out" == *"bats-tests"* ]]
  [[ "$out" == *"threshold: 180s"* ]]
  [[ "$out" == *"elapsed: 240s"* ]]
  [[ "$out" == *"E45-S6"* ]]
}

@test "_bats_emit_warning appends to GITHUB_STEP_SUMMARY when set" {
  _source_budget_watch_lib
  local summary_file="$TEST_TMP/step-summary.md"
  : > "$summary_file"
  GITHUB_STEP_SUMMARY="$summary_file" _bats_emit_warning "hello world"
  grep -q "hello world" "$summary_file"
}

@test "_bats_emit_warning falls back to stdout when GITHUB_STEP_SUMMARY unset" {
  _source_budget_watch_lib
  unset GITHUB_STEP_SUMMARY
  out="$(_bats_emit_warning "stdout fallback")"
  [[ "$out" == *"stdout fallback"* ]]
}
