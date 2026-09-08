#!/usr/bin/env bats
# lock-review-gate-ledger.bats — concurrent ledger stress tests for
# review-gate.sh locking.
#
# Drives the REAL review-gate.sh update path. The ledger_write path is
# taken when --plan-id is present (review-gate.sh:1232-1233). The cmd_update
# path is taken when --plan-id is absent (review-gate.sh:1235), with
# REVIEW_GATE_PROOF_OF_EXECUTION=off to bypass the proof gate (line 1167).

load 'test_helper.bash'

setup() {
  common_setup
  REVIEW_GATE="$SCRIPTS_DIR/review-gate.sh"
  HELPER="$SCRIPTS_DIR/lib/acquire-lock.sh"
  [ -f "$REVIEW_GATE" ] || skip "review-gate.sh not found"
  [ -f "$HELPER" ] || skip "acquire-lock.sh not found"
  # Build a scratch PATH excluding flock (works on both macOS and Ubuntu CI).
  NOFLOCK_BIN="$TEST_TMP/noflock-bin"
  mkdir -p "$NOFLOCK_BIN"
  local tool
  for tool in bash sh env awk sed grep sort cat mv rm cp mkdir ln sleep \
              date stat ps kill head tail wc tr printf touch mktemp \
              dirname basename readlink id tee yq jq git chmod perl find xargs cut od uname getconf; do
    local p
    p="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$p" ] && [ ! -e "$NOFLOCK_BIN/$tool" ]; then
      ln -s "$p" "$NOFLOCK_BIN/$tool" 2>/dev/null || true
    fi
  done
  SAFE_PATH="$NOFLOCK_BIN"
  # Sanity: flock must NOT be reachable through the scratch PATH.
  if PATH="$NOFLOCK_BIN" command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock still reachable via scratch bin — test setup broken" >&2
    return 1
  fi
  # Build a scratch project with a story file.
  PROJ="$TEST_TMP/project"
  STATE="$PROJ/.gaia/state"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$STATE" "$IMPL/epic-test/stories"
  export PROJECT_ROOT="$PROJ"
  export PROJECT_PATH="$PROJ"
}

teardown() {
  jobs -p 2>/dev/null | xargs kill -9 2>/dev/null || true
  wait 2>/dev/null || true
  common_teardown
}

# Helper: create a story file for review-gate tests.
_mk_rg_story() {
  local key="$1"
  local story_dir="$IMPL/epic-test/stories"
  local sf="$story_dir/${key}-test.md"
  cat > "$sf" << STORYEOF
---
template: 'story'
key: "${key}"
title: "Test ${key}"
epic: "ETEST"
stack: "bash-dev"
status: in-progress
priority: "P1"
size: "S"
points: 1
risk: "low"
sprint_id: "test-sprint"
priority_flag: null
delivered: false
deferred_implementation: false
manual_verification: false
origin: "manual"
origin_ref: "test"
depends_on: []
blocks: []
traces_to: []
date: "2026-01-01"
author: "test"
---

# Story: ${key}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORYEOF
  printf '%s' "$sf"
}

# ============================================================
# AC4: N=5 concurrent ledger writers produce exactly 5 entries
# ============================================================

@test "N=5 concurrent ledger writers produce exactly 5 entries (AC4)" {
  local sf
  sf="$(_mk_rg_story "ETEST-RG1")"
  # Set ledger path to scratch state dir.
  export REVIEW_GATE_LEDGER="$STATE/.review-gate-ledger"
  local pids=()
  local rc_files=()
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    rc_files+=("$rcf")
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
      export REVIEW_GATE_LEDGER="$STATE/.review-gate-ledger"
      bash "$REVIEW_GATE" update \
        --story ETEST-RG1 \
        --gate "Code Review" \
        --verdict PASSED \
        --plan-id "plan-$i"
      echo $? > "$rcf"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  # RED: ledger_write is unlocked AND/OR acquire_lock stub returns 1.
  # All 5 must exit 0.
  for i in 1 2 3 4 5; do
    local rcf="$TEST_TMP/rc-$i"
    [ -f "$rcf" ] || { echo "rc file missing for writer $i" >&2; false; }
    local rc
    rc="$(cat "$rcf")"
    [ "$rc" = "0" ] || { echo "writer $i exited $rc" >&2; false; }
  done
  # Ledger file must exist and contain exactly 5 rows.
  [ -f "$STATE/.review-gate-ledger" ]
  local count
  count=$(wc -l < "$STATE/.review-gate-ledger" | tr -d ' ')
  [ "$count" -eq 5 ] || { echo "expected 5 ledger rows, got $count" >&2; false; }
  # Each plan-id must be present.
  for i in 1 2 3 4 5; do
    grep -qF "plan-$i" "$STATE/.review-gate-ledger" || {
      echo "plan-$i MISSING from ledger (lost update)" >&2; false
    }
  done
}

# ============================================================
# AC4: cmd_update branch produces correct final state
# ============================================================

@test "concurrent cmd_update writers produce correct final state (AC4)" {
  local sf
  sf="$(_mk_rg_story "ETEST-RG2")"
  # Drive 3 updates on 3 different gates without --plan-id (cmd_update path,
  # review-gate.sh:1235). REVIEW_GATE_PROOF_OF_EXECUTION=off bypasses the
  # proof gate at line 1167.
  local gates=("Code Review" "QA Tests" "Security Review")
  local pids=()
  local rc_files=()
  for i in 0 1 2; do
    local rcf="$TEST_TMP/rcu-$i"
    rc_files+=("$rcf")
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
      export REVIEW_GATE_PROOF_OF_EXECUTION=off
      bash "$REVIEW_GATE" update \
        --story ETEST-RG2 \
        --gate "${gates[$i]}" \
        --verdict PASSED
      echo $? > "$rcf"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  # RED: cmd_update's inline flock/fallback is not yet migrated to the helper.
  # All 3 must exit 0.
  for i in 0 1 2; do
    local rcf="$TEST_TMP/rcu-$i"
    [ -f "$rcf" ] || { echo "rc file missing for writer $i" >&2; false; }
    local rc
    rc="$(cat "$rcf")"
    [ "$rc" = "0" ] || { echo "writer $i exited $rc" >&2; false; }
  done
  # The story file must show PASSED for all 3 gates.
  for g in "Code Review" "QA Tests" "Security Review"; do
    grep -q "| $g | PASSED |" "$sf" || {
      echo "gate '$g' not PASSED in story file" >&2
      cat "$sf" >&2
      false
    }
  done
}

# ============================================================
# Lock released on die() inside ledger_write subshell
# ============================================================

@test "the subshell EXIT-trap release pattern used by ledger_write frees the fallback lock on die (AC4)" {
  # review-gate.sh is not driven here because ledger_write's ! mv handler
  # has an explicit release_lock that covers every reachable fault path.
  # The trap is defense-in-depth; this test proves the pattern itself works.
  #
  # Exercises the exact lock/die/release pattern from review-gate.sh's
  # ledger_write: acquire fd 8 fallback lock, EXIT trap as sole cleanup,
  # then die (exit 1) inside the subshell. The die fires AFTER acquire
  # succeeds — proved by the debug log showing "acquire" with no
  # preceding "lock timeout" in the error output.
  local ledger_dir="$TEST_TMP/ledger-dir"
  mkdir -p "$ledger_dir"
  local lock_file="$ledger_dir/.review-gate-ledger.lock"
  local debug_log="$TEST_TMP/lock-debug.log"
  run bash -c '
    set -euo pipefail
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    source "'"$HELPER"'"
    # Mirror ledger_write subshell pattern (fd 8, EXIT trap, die).
    (
      if ! acquire_lock "'"$lock_file"'" 5 8; then
        echo "lock timeout" >&2
        exit 1
      fi
      trap "release_lock 8 2>/dev/null || true" EXIT
      # Simulate a die inside the critical section.
      echo "die-after-acquire: simulated fault" >&2
      exit 1
    )
  '
  # The command must have failed (die path).
  [ "$status" -ne 0 ] || { echo "expected die, but succeeded: $output" >&2; false; }
  # Verify the lock was genuinely acquired (debug log records "acquire").
  [ -f "$debug_log" ] || { echo "debug log missing — lock may not have been attempted" >&2; false; }
  grep -q "^acquire " "$debug_log" \
    || { echo "debug log has no acquire entry — lock was never held: $(cat "$debug_log")" >&2; false; }
  # The failure must NOT be a lock-acquisition timeout.
  echo "$output" | grep -v "lock timeout" >/dev/null 2>&1 \
    || { echo "failure was lock-timeout, not post-acquire fault: $output" >&2; false; }
  # The error output must show the post-acquire die message.
  echo "$output" | grep -q "die-after-acquire" \
    || { echo "die message not found in output — fault did not fire after acquire: $output" >&2; false; }
  # The lock file must NOT carry a held PID (trap released it).
  if [ -f "$lock_file" ]; then
    local content
    content="$(cat "$lock_file")"
    if echo "$content" | grep -E '^[0-9]+ [0-9]+$' >/dev/null 2>&1; then
      echo "lock file still carries PID after die (trap did not fire): $content" >&2
      false
    fi
  fi
  # Follow-up acquire with high reap threshold must succeed quickly
  # (proving the lock was released, not just reaped from a stale file).
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 8
  '
  [ "$status" -eq 0 ] || { echo "follow-up acquire blocked (lock leaked): $output" >&2; false; }
}
