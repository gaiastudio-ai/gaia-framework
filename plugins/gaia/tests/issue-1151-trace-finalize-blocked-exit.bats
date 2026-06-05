#!/usr/bin/env bash
# issue-1151-trace-finalize-blocked-exit.bats
#
# /gaia-trace finalize detected a traceability matrix whose OWN verdict was
# BLOCKED/FAIL but still exited 0 — the downstream path-based gate
# (validate-gate.sh traceability_exists) only checks file existence, so a
# BLOCKED matrix silently passed. The WARNING it logged was buried in stderr.
#
# Fix: finalize exits non-zero when the generated matrix declares its own
# verdict BLOCKED/FAIL, so the BLOCKED verdict actually gates. An opt-out env
# (GAIA_TRACE_ALLOW_BLOCKED=1) preserves the advisory-only behaviour for
# callers that deliberately want to proceed.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FINALIZE="$PLUGIN_ROOT/skills/gaia-trace/scripts/finalize.sh"
}

teardown() { common_teardown; }

_mk_matrix() {
  local tmp="$1"; local verdict_line="$2"
  mkdir -p "$tmp/.gaia/artifacts/planning-artifacts" "$tmp/.gaia/memory/checkpoints"
  # Set CHECKPOINT_PATH so the upstream checkpoint write succeeds — this
  # isolates the matrix-verdict gate as the sole determinant of the exit code.
  export CHECKPOINT_PATH="$tmp/.gaia/memory/checkpoints"
  {
    printf '# Traceability Matrix\n\n'
    [ -n "$verdict_line" ] && printf '%s\n\n' "$verdict_line"
    printf '| Req | Story | Test |\n|-----|-------|------|\n| FR-1 | S-1 | T-1 |\n'
  } > "$tmp/.gaia/artifacts/planning-artifacts/traceability-matrix.md"
}

@test "issue-1151: a BLOCKED matrix makes finalize exit non-zero" {
  local tmp="$BATS_TEST_TMPDIR/blocked"
  _mk_matrix "$tmp" '**Gate verdict:** BLOCKED'
  cd "$tmp"
  run bash "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "issue-1151: a FAIL matrix makes finalize exit non-zero" {
  local tmp="$BATS_TEST_TMPDIR/fail"
  _mk_matrix "$tmp" 'Verdict: FAILED'
  cd "$tmp"
  run bash "$FINALIZE"
  [ "$status" -ne 0 ]
}

@test "issue-1151: a clean (no BLOCKED) matrix exits zero" {
  local tmp="$BATS_TEST_TMPDIR/clean"
  _mk_matrix "$tmp" 'Verdict: PASSED'
  cd "$tmp"
  run bash "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "issue-1151: no matrix present exits zero (idempotent no-op)" {
  local tmp="$BATS_TEST_TMPDIR/none"
  mkdir -p "$tmp/.gaia/memory/checkpoints"
  export CHECKPOINT_PATH="$tmp/.gaia/memory/checkpoints"
  cd "$tmp"
  run bash "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "issue-1151: GAIA_TRACE_ALLOW_BLOCKED=1 downgrades BLOCKED back to a warning (exit 0)" {
  local tmp="$BATS_TEST_TMPDIR/optout"
  _mk_matrix "$tmp" 'Verdict: BLOCKED'
  cd "$tmp"
  run env GAIA_TRACE_ALLOW_BLOCKED=1 bash "$FINALIZE"
  [ "$status" -eq 0 ]
}

@test "issue-1151: BLOCKED exit still emits the WARNING line" {
  local tmp="$BATS_TEST_TMPDIR/blocked-warn"
  _mk_matrix "$tmp" 'Verdict: BLOCKED'
  cd "$tmp"
  run bash "$FINALIZE"
  printf '%s\n' "$output" | grep -qiE 'BLOCKED/FAIL'
}
