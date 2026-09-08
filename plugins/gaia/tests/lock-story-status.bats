#!/usr/bin/env bats
# lock-story-status.bats — tests for transition-story-status.sh and
# set-story-sprint.sh locking under the shared helper (fallback path).
#
# AC3 tests are CONTENTION-OBSERVABLE: they hold the shared
# .story-status.lock from a background holder and assert the real
# scripts BLOCK (contention exit / timeout) while held. Today's
# scripts ignore the lock file when flock is absent, so these tests
# fail at the positive "was blocked" assertion — the correct red reason.

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
  # RED: today's transition-story-status.sh does `exec 200>"$STORY_STATUS_LOCK"`
  # which OVERWRITES the lock file content and does NOT honour the fallback lock.
  # When flock is absent, it acquires no lock, so it succeeds despite contention.
  # After migration: the helper's fallback path sees the held lock and times out.
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
  # RED: today's set-story-sprint.sh does `exec 200>"$STORY_STATUS_LOCK"` which
  # overwrites the file and takes no fallback lock. It succeeds despite contention.
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
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$PROJ"'" PROJECT_PATH="'"$PROJ"'"
    export MEMORY_PATH="'"$MEMORY"'" STORY_STATUS_LOCK="'"$MEMORY/.story-status.lock"'"
    export SPRINT_STATUS_YAML="'"$SPRINT_STATUS_YAML"'" GAIA_SKIP_ORPHAN_SWEEP=1
    export ACQUIRE_LOCK_DEBUG=1 ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    bash "'"$TSS"'" ETEST-S5 --to in-progress
  '
  local tss_rc=$?
  [ "$tss_rc" -eq 0 ] || { echo "transition failed (status=$tss_rc)" >&2; false; }
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
    sleep 300
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
