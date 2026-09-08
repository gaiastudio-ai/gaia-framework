#!/usr/bin/env bats
# lock-story-status.bats — tests for transition-story-status.sh and
# set-story-sprint.sh locking under the shared helper (fallback path).
#
# AC3 tests are CONTENTION-OBSERVABLE: they hold the shared
# .story-status.lock from a background holder and assert the real
# scripts BLOCK (contention exit / timeout) while held. Deleting a
# script's acquire_lock call makes the run proceed instead of blocking,
# which is what these tests are built to detect.

load 'test_helper.bash'

setup() {
  common_setup
  TSS="$SCRIPTS_DIR/transition-story-status.sh"
  SSS="$SCRIPTS_DIR/set-story-sprint.sh"
  HELPER="$SCRIPTS_DIR/lib/acquire-lock.sh"
  [ -f "$TSS" ] || skip "transition-story-status.sh not found"
  [ -f "$SSS" ] || skip "set-story-sprint.sh not found"
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
  PROJ="$TEST_TMP/project"
  STATE="$PROJ/.gaia/state"
  MEMORY="$PROJ/.gaia/memory"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  PLAN="$PROJ/.gaia/artifacts/planning-artifacts"
  mkdir -p "$STATE" "$MEMORY" "$IMPL" "$PLAN"
  cat > "$STATE/sprint-status.yaml" << 'YAMLEOF'
sprint_id: "test-sprint"
status: active
total_points: 0
goals: []
items: []
YAMLEOF
  # Heading uses the em-dash form that resolve-epic-slug.sh accepts.
  cat > "$PLAN/epics-and-stories.md" << 'EOFEPIC'
# Epics and Stories

## ETEST — Test Epic

| Key | Title | Status | Points |
|-----|-------|--------|--------|
EOFEPIC
  export SPRINT_STATUS_YAML="$STATE/sprint-status.yaml"
  export PROJECT_ROOT="$PROJ"
  export PROJECT_PATH="$PROJ"
  export MEMORY_PATH="$MEMORY"
  export STORY_STATUS_LOCK="$MEMORY/.story-status.lock"
  export GAIA_SKIP_ORPHAN_SWEEP=1
}

teardown() {
  jobs -p 2>/dev/null | xargs kill -9 2>/dev/null || true
  wait 2>/dev/null || true
  # Restore write permission before the tree is removed: tests that chmod a
  # fixture directory read-only restore it inline, but an assertion aborting
  # in between would leave common_teardown's rm -rf unable to unlink through
  # it, and the litter accumulates across failing runs.
  chmod -R u+w "$IMPL" 2>/dev/null || true
  common_teardown
}

# Helper: create a story. Includes the body > **Status:** line.
_mk_story() {
  local key="$1" status="${2:-backlog}" sprint="${3:-\"test-sprint\"}"
  local story_dir="$IMPL/epic-test/stories"
  mkdir -p "$story_dir"
  local story_file="$story_dir/${key}-test.md"
  cat > "$story_file" << STORYEOF
---
template: 'story'
key: "${key}"
title: "Test ${key}"
epic: "ETEST"
stack: "bash-dev"
status: ${status}
priority: "P1"
size: "S"
points: 1
risk: "low"
sprint_id: ${sprint}
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

> **Epic:** ETEST
> **Priority:** P1
> **Status:** ${status}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | --- |
| QA Tests | UNVERIFIED | --- |
| Security Review | UNVERIFIED | --- |
| Test Automation | UNVERIFIED | --- |
| Test Review | UNVERIFIED | --- |
| Performance Review | UNVERIFIED | --- |
STORYEOF
  printf '%s' "$story_file"
}

_wait_for_file() {
  local path="$1" tries=0
  while [ ! -f "$path" ] && [ "$tries" -lt 50 ]; do
    sleep 0.2 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  [ -f "$path" ]
}

# ============================================================
# AC3: transition-story-status.sh blocks when lock is held (contention-observable)
# ============================================================

@test "transition-story-status blocks when .story-status.lock is held (AC3)" {
  local sf
  sf="$(_mk_story "ETEST-S1" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S1", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S1 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  # Pre-create the lock file with OUR PID (live holder) so it cannot be reaped.
  printf '%s %s\n' "$$" "$(date +%s)" > "$MEMORY/.story-status.lock"
  # Run transition with a short timeout — it must fail because the lock is held.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S1 --to in-progress
  '
  # Contention-observable: with the lock held by a live PID, the transition
  # must time out rather than proceed. A bare `exec 200>` on the lock path
  # would overwrite the file and take no lock, and this would succeed.
  [ "$status" -ne 0 ] || {
    echo "transition succeeded despite held lock — no contention observed (flock-absent branch is unlocked)" >&2
    echo "script output: $output" >&2
    false
  }
}

# ============================================================
# AC3: set-story-sprint.sh blocks when lock is held (contention-observable)
# ============================================================

@test "set-story-sprint blocks when .story-status.lock is held (AC3)" {
  local sf
  sf="$(_mk_story "ETEST-S2" "backlog" "null")"
  # Pre-create the lock file with OUR PID (live holder).
  printf '%s %s\n' "$$" "$(date +%s)" > "$MEMORY/.story-status.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SSS"'" ETEST-S2 --sprint test-sprint
  '
  # Contention-observable: with the lock held, set-story-sprint must block
  # and fail rather than proceed into its rewrite.
  [ "$status" -ne 0 ] || {
    echo "set-story-sprint succeeded despite held lock — no contention observed" >&2
    echo "script output: $output" >&2
    false
  }
}

# ============================================================
# AC3: two concurrent transitions on the SAME lock serialize
# ============================================================

@test "two concurrent transitions on same lock both succeed with consistent state (AC3)" {
  _mk_story "ETEST-S3" "backlog" "\"test-sprint\"" > /dev/null
  _mk_story "ETEST-S4" "backlog" "\"test-sprint\"" > /dev/null
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S3", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  yq eval '.items += [{"key": "ETEST-S4", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S3 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  printf '| ETEST-S4 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  local sf3="$IMPL/epic-test/stories/ETEST-S3-test.md"
  local sf4="$IMPL/epic-test/stories/ETEST-S4-test.md"
  local rc3="$TEST_TMP/rc3" rc4="$TEST_TMP/rc4"
  local out3="$TEST_TMP/out3" out4="$TEST_TMP/out4"
  local trace="$TEST_TMP/lock-trace.log"
  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
    export MEMORY_PATH="$MEMORY" STORY_STATUS_LOCK="$MEMORY/.story-status.lock"
    export SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" GAIA_SKIP_ORPHAN_SWEEP=1
    export ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="$trace"
    bash "$TSS" ETEST-S3 --to in-progress > "$out3" 2>&1
    echo $? > "$rc3"
  ) &
  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="$PROJ" PROJECT_PATH="$PROJ"
    export MEMORY_PATH="$MEMORY" STORY_STATUS_LOCK="$MEMORY/.story-status.lock"
    export SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" GAIA_SKIP_ORPHAN_SWEEP=1
    export ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="$trace"
    bash "$TSS" ETEST-S4 --to in-progress > "$out4" 2>&1
    echo $? > "$rc4"
  ) &
  wait
  # Both must succeed.
  [ -f "$rc3" ] && [ "$(cat "$rc3")" = "0" ] || { echo "transition S3 failed: $(cat "$out3" 2>/dev/null)" >&2; false; }
  [ -f "$rc4" ] && [ "$(cat "$rc4")" = "0" ] || { echo "transition S4 failed: $(cat "$out4" 2>/dev/null)" >&2; false; }
  grep -F "status: in-progress" "$sf3" >/dev/null || { echo "S3 status not updated" >&2; false; }
  grep -F "status: in-progress" "$sf4" >/dev/null || { echo "S4 status not updated" >&2; false; }
  # The lock trace must show the helper was invoked.
  [ -f "$trace" ] || { echo "no lock trace — helper was not invoked during transitions" >&2; false; }
  # The trace must show non-overlapping critical sections: no double-acquire
  # on the same lock without an intervening release. A no-op acquire_lock
  # that emits a trace but provides no exclusion would let both writers
  # hold the lock simultaneously — the awk check catches that.
  local doubles
  doubles=$(awk '/^acquire / { if (seen[$2]++) print $2 }
                 /^release / { delete seen[$2] }' "$trace" | wc -l | tr -d ' ')
  [ "$doubles" -eq 0 ] || {
    echo "overlapping critical sections detected in trace (double-acquire without release):" >&2
    cat "$trace" >&2
    false
  }
}

# ============================================================
# AC3: lock released on normal exit (fallback mode)
# ============================================================

@test "lock released on normal exit — lock file owned during run (AC3)" {
  local sf
  sf="$(_mk_story "ETEST-S5" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S5", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S5 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  local lock_during="$TEST_TMP/lock-during-run"
  # Run TSS in a subshell with debug tracing enabled. The helper must write
  # a debug log proving it acquired the lock during the run.
  local debug_log="$TEST_TMP/lock-release-debug.log"
  # `run`, not a bare command: under the set -e bats relies on, a bare
  # non-zero command aborts the test at that line, so the rc capture and its
  # diagnostic below would never execute.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    export ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    bash "'"$TSS"'" ETEST-S5 --to in-progress
  '
  [ "$status" -eq 0 ] || { echo "transition failed (status=$status): $output" >&2; false; }
  # The debug log MUST exist, proving the helper was invoked. Today's code
  # never calls acquire_lock, so no debug log is emitted.
  [ -f "$debug_log" ] || { echo "no lock debug log — helper was not invoked during transition" >&2; false; }
  # After the run, next acquire must succeed immediately (lock released).
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$MEMORY/.story-status.lock"'" 2 200
  '
  [ "$status" -eq 0 ] || { echo "next acquire blocked (lock not released): $output" >&2; false; }
}

# ============================================================
# AC3: lock released on signal exit (SIGTERM)
# ============================================================

@test "lock released on SIGTERM — signal delivered to live holder (AC3)" {
  # A background holder acquires the lock via the helper and then blocks
  # (sleep). A readiness marker is written AFTER acquisition so the test
  # knows the lock is held. The test sends SIGTERM while the holder is
  # alive and asserts the lock is released by the EXIT trap.
  local lock_file="$MEMORY/.story-status.lock"
  local holder_ready="$TEST_TMP/holder-acquired"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 200 || exit 1
    touch "'"$holder_ready"'"
    # Block until signalled — the trap on EXIT releases the lock.
    trap "release_lock 200" EXIT
    # The holder must (a) stay genuinely alive until signalled, (b) run the
    # EXIT trap promptly on SIGTERM, and (c) leave no long-lived orphan for
    # the suite teardown'"'"'s `wait` to block on.
    #
    # A foreground `sleep 300` fails (b): bash defers a trapped signal until
    # the running foreground command returns. A backgrounded `sleep 300 &`
    # plus `wait` fixes (b) but fails (c): the sleep outlives the holder as
    # an orphan. A `while :; do sleep 0.1; done` loop fails (b) as well —
    # each deferred signal only lands between slices, and the loop restarts.
    #
    # Backgrounding SHORT slices and waiting on each satisfies all three:
    # `wait` is interruptible so the trap runs at once, and the longest any
    # orphan can survive is one slice.
    trap "release_lock 200; exit 0" TERM
    while :; do
      sleep 0.1 &
      wait $! 2>/dev/null || break
    done
  ' &
  local holder_pid=$!
  _wait_for_file "$holder_ready"
  # Verify the holder is ALIVE at signal time.
  kill -0 "$holder_pid" 2>/dev/null || { echo "holder already dead before signal" >&2; false; }
  # The lock file must exist and carry the holder's PID.
  [ -f "$lock_file" ] || { echo "lock file missing while holder is alive" >&2; false; }
  # Send SIGTERM to the live holder.
  kill -TERM "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  # After signal, the lock file must be gone (release_lock removed it).
  # Use a high reap threshold so a leaked lock would NOT be auto-reaped.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 200
  '
  [ "$status" -eq 0 ] || { echo "next acquire blocked after SIGTERM (lock leaked): $output" >&2; false; }
}

# ============================================================
# AC3 / AC-EC2: crashed holder recovered by next run
# ============================================================

@test "crashed holder recovered by next run — helper reaped stale lock (AC3)" {
  printf '99999 1000000000\n' > "$MEMORY/.story-status.lock"
  touch -t 202001010000 "$MEMORY/.story-status.lock" 2>/dev/null \
    || touch -d '2020-01-01' "$MEMORY/.story-status.lock" 2>/dev/null \
    || skip "cannot set mtime"
  local sf
  sf="$(_mk_story "ETEST-S7" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S7", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S7 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  local debug_log="$TEST_TMP/lock-reap-debug.log"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    export GAIA_LOCK_REAP_SECONDS=1
    export ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    bash "'"$TSS"'" ETEST-S7 --to in-progress
  '
  [ "$status" -eq 0 ] || { echo "transition after crash failed (status=$status): $output" >&2; false; }
  grep -F "status: in-progress" "$sf" >/dev/null || { echo "status not updated" >&2; false; }
  # The debug log MUST exist, proving the helper was invoked and performed
  # the reap. Today's code does exec 200>"$file" which truncates the file
  # without calling the helper — no debug log emitted.
  [ -f "$debug_log" ] || { echo "no lock debug log — helper was not invoked (dead-PID reap not exercised)" >&2; false; }
  # The trace must show the lock path was acquired (not just emitted).
  grep -F "acquire" "$debug_log" >/dev/null || { echo "no acquire entry in debug log" >&2; false; }
  grep -F "release" "$debug_log" >/dev/null || { echo "no release entry in debug log" >&2; false; }
}

# ============================================================
# W1: two successive runs emit no spurious "reaped" stderr noise
# ============================================================

@test "two successive transitions produce no reaped-ownerless stderr noise (AC3)" {
  _mk_story "ETEST-S8" "backlog" "\"test-sprint\"" > /dev/null
  _mk_story "ETEST-S9" "backlog" "\"test-sprint\"" > /dev/null
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S8", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  yq eval '.items += [{"key": "ETEST-S9", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S8 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  printf '| ETEST-S9 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  # Run 1: transition S8 (leaves a post-release sentinel).
  local stderr1="$TEST_TMP/stderr1"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S8 --to in-progress
  ' > /dev/null 2> "$stderr1"
  # Run 2: transition S9 — stderr must NOT contain "reaped".
  local stderr2="$TEST_TMP/stderr2"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S9 --to in-progress
  ' > /dev/null 2> "$stderr2"
  if grep -F "reaped" "$stderr2" >/dev/null 2>&1; then
    echo "run 2 emitted spurious reaped noise:" >&2
    cat "$stderr2" >&2
    false
  fi
}

# ============================================================
# AC3: no exit path between acquire and the releasing trap may leak the lock
# ============================================================

# Shared shape for the early-exit leak tests: run transition-story-status.sh
# so it exits on one of the paths that sit between lock acquisition and the
# rollback trap, then assert the lock file it leaves behind is not a
# PID-bearing lock that would block the next run.
_assert_no_leaked_lock() {
  local what="$1"
  local lock_file="$MEMORY/.story-status.lock"
  # A leaked fallback lock is "<pid> <epoch>" with a live PID. A zero-byte
  # sentinel (what the release path re-touches) is fine.
  if [ -s "$lock_file" ]; then
    local holder
    read -r holder _ < "$lock_file" 2>/dev/null || true
    if [ -n "$holder" ] && [ "$holder" -gt 0 ] 2>/dev/null; then
      echo "$what left a PID-bearing lock file behind: $(cat "$lock_file")" >&2
      return 1
    fi
  fi
  # The decisive check: the very next acquirer must get the lock at once.
  # A leaked lock has a fresh mtime, so the reaper refuses it for the full
  # 60s floor and this blocks for the whole timeout.
  local start_s
  start_s=$(date +%s)
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 3 200
  '
  local elapsed=$(( $(date +%s) - start_s ))
  [ "$status" -eq 0 ] || {
    echo "$what leaked the lock — the next acquirer blocked ${elapsed}s and failed" >&2
    return 1
  }
  return 0
}

@test "idempotent no-op transition does not leak the lock (AC3)" {
  # The most frequently taken path in the script: the story is already at the
  # requested status, so it exits 0 early. If the releasing trap is installed
  # only further down, this routine no-op poisons its own lock.
  local sf
  sf="$(_mk_story "ETEST-S20" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S20", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S20 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S20 --to backlog
  '
  [ "$status" -eq 0 ] || { echo "no-op transition failed (status=$status): $output" >&2; false; }
  [[ "$output" == *"no-op"* ]] || { echo "did not take the no-op path: $output" >&2; false; }
  _assert_no_leaked_lock "the idempotent no-op path"
}

@test "a second transition still runs right after a no-op (AC3)" {
  # End-to-end consequence of the leak: the run immediately following a
  # no-op must not hit lock contention.
  local sf
  sf="$(_mk_story "ETEST-S21" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S21", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S21 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  local env_prelude='
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
  '
  # First: the no-op.
  run bash -c "$env_prelude"' bash "'"$TSS"'" ETEST-S21 --to backlog'
  [ "$status" -eq 0 ] || { echo "no-op run failed: $output" >&2; false; }
  # Then: a real transition, which must not block on a leaked lock.
  run bash -c "$env_prelude"' bash "'"$TSS"'" ETEST-S21 --to in-progress'
  [ "$status" -eq 0 ] || {
    echo "transition after a no-op failed (status=$status) — leaked lock: $output" >&2
    false
  }
  [[ "$output" != *"lock contention"* ]] || {
    echo "transition after a no-op hit lock contention — the no-op leaked its lock" >&2
    false
  }
}

@test "invalid-transition exit does not leak the lock (AC3)" {
  # The state-machine rejection (exit 7) also sits inside the window.
  local sf
  sf="$(_mk_story "ETEST-S22" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S22", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S22 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S22 --to done
  '
  [ "$status" -ne 0 ] || { echo "backlog -> done was accepted: $output" >&2; false; }
  _assert_no_leaked_lock "the invalid-transition path"
}

@test "--from mismatch exit does not leak the lock (AC3)" {
  # The --from guard (exit 1) is the earliest exit inside the window.
  local sf
  sf="$(_mk_story "ETEST-S23" "backlog" "\"test-sprint\"")"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq eval '.items += [{"key": "ETEST-S23", "status": "backlog", "points": 1}]' -i "$SPRINT_STATUS_YAML"
  printf '| ETEST-S23 | Test | backlog | 1 |\n' >> "$PLAN/epics-and-stories.md"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$TSS"'" ETEST-S23 --from review --to done
  '
  [ "$status" -ne 0 ] || { echo "--from mismatch was accepted: $output" >&2; false; }
  _assert_no_leaked_lock "the --from mismatch path"
}

@test "set-story-sprint does not leak the lock when the rewrite aborts early (AC3)" {
  # set-story-sprint has the same shape: acquire, then mktemp, then the
  # releasing trap. If mktemp fails, set -e exits with the lock held and no
  # trap installed. Make the story directory unwritable but keep the LOCK
  # directory writable, so acquisition succeeds and only mktemp fails.
  local sf
  sf="$(_mk_story "ETEST-S24" "backlog" "null")"
  local story_dir
  story_dir="$(dirname "$sf")"
  chmod 555 "$story_dir"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SSS"'" ETEST-S24 --sprint new-sprint
  '
  chmod 755 "$story_dir"
  [ "$status" -ne 0 ] || { echo "expected failure on an unwritable story dir: $output" >&2; false; }
  _assert_no_leaked_lock "the set-story-sprint early-abort path"
}
