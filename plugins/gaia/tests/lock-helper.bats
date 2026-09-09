#!/usr/bin/env bats
# lock-helper.bats — unit tests for the shared locking helper
# (scripts/lib/acquire-lock.sh).

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/lib/acquire-lock.sh"
  [ -f "$HELPER" ] || skip "acquire-lock.sh not found"
  LOCK_DIR="$TEST_TMP/locks"
  mkdir -p "$LOCK_DIR"
  # Build a scratch PATH that excludes flock. Symlink only the tools the
  # scripts need into a private bin dir so flock is genuinely absent on any
  # host (macOS or Ubuntu CI where flock lives at /usr/bin/flock).
  NOFLOCK_BIN="$TEST_TMP/noflock-bin"
  mkdir -p "$NOFLOCK_BIN"
  local tool
  for tool in bash sh env awk sed grep sort cat mv rm cp mkdir ln sleep \
              date stat ps kill head tail wc tr printf touch mktemp \
              dirname basename readlink id tee yq jq git chmod perl find xargs cut od uname getconf rmdir mkfifo timeout; do
    local p
    p="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$p" ] && [ ! -e "$NOFLOCK_BIN/$tool" ]; then
      ln -s "$p" "$NOFLOCK_BIN/$tool" 2>/dev/null || true
    fi
  done
  # Sanity: flock must NOT be reachable through the scratch PATH.
  if PATH="$NOFLOCK_BIN" command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock still reachable via scratch bin — test setup broken" >&2
    return 1
  fi
  SAFE_PATH="$NOFLOCK_BIN"
  export SAFE_PATH
}

teardown() {
  jobs -p 2>/dev/null | xargs kill -9 2>/dev/null || true
  wait 2>/dev/null || true
  common_teardown
}

# The flock shim records its argv to a log and validates that the caller
# passed -x, -w <timeout>, and a numeric fd.
_make_flock_shim() {
  local shim_dir="$TEST_TMP/flock-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" << 'SHIMEOF'
#!/usr/bin/env bash
echo "flock-shim-called $*" >> "${FLOCK_SHIM_LOG:-/dev/null}"
for last_arg; do true; done
echo "$last_arg" >> "${FLOCK_SHIM_FD_LOG:-/dev/null}"
# Exit status is caller-controllable so tests can drive the acquire failure
# branch. Default 0 keeps every pre-existing contract test unchanged.
exit "${FLOCK_SHIM_EXIT:-0}"
SHIMEOF
  chmod +x "$shim_dir/flock"
  printf '%s' "$shim_dir"
}

# A REAL flock, first on PATH, for tests that must execute the flock fast
# path rather than a stub of it. Returns the directory to prepend, or empty
# when the host has no flock (callers skip).
_real_flock_bin() {
  local real
  real="$(command -v flock 2>/dev/null || true)"
  [ -n "$real" ] || return 1
  local dir="$TEST_TMP/real-flock-bin"
  mkdir -p "$dir"
  [ -e "$dir/flock" ] || ln -s "$real" "$dir/flock"
  printf '%s' "$dir"
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
# AC1
# ============================================================

@test "acquire_lock uses flock fast path when present and passes correct fd (AC1)" {
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  export FLOCK_SHIM_LOG="$TEST_TMP/flock-calls.log"
  export FLOCK_SHIM_FD_LOG="$TEST_TMP/flock-fds.log"
  local lock_file="$LOCK_DIR/test.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export FLOCK_SHIM_LOG="'"$FLOCK_SHIM_LOG"'"
    export FLOCK_SHIM_FD_LOG="'"$FLOCK_SHIM_FD_LOG"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
  [ -f "$FLOCK_SHIM_LOG" ] || { echo "shim was not called" >&2; false; }
  grep -F -- '-x' "$FLOCK_SHIM_LOG" >/dev/null || { echo "shim not called with -x" >&2; false; }
  grep -F -- '-w' "$FLOCK_SHIM_LOG" >/dev/null || { echo "shim not called with -w" >&2; false; }
  [ -f "$FLOCK_SHIM_FD_LOG" ] || { echo "fd log missing" >&2; false; }
  local recorded_fd
  recorded_fd="$(head -1 "$FLOCK_SHIM_FD_LOG" | tr -d '[:space:]')"
  [ "$recorded_fd" = "9" ] || { echo "flock called with fd=$recorded_fd, expected 9" >&2; false; }
}

@test "acquire_lock falls back when flock absent from scratch PATH (AC1)" {
  local lock_file="$LOCK_DIR/fallback.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    # Verify flock is genuinely absent.
    command -v flock >/dev/null 2>&1 && { echo "flock still present" >&2; exit 99; }
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file not created" >&2; false; }
  local content
  content="$(cat "$lock_file")"
  [[ "$content" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "bad format: $content" >&2; false; }
}

@test "acquire_lock honours caller-supplied timeout (AC1)" {
  local lock_file="$LOCK_DIR/timeout.lock"
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_file"
  local start elapsed
  start=$(date +%s)
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -ne 0 ]
  [ "$elapsed" -ge 2 ] || { echo "returned in ${elapsed}s, expected >=2" >&2; false; }
  [ "$elapsed" -lt 6 ]
}

@test "timeout returns non-zero with no partial write (AC-EC5)" {
  local lock_file="$LOCK_DIR/nopartial.lock"
  local state_file="$TEST_TMP/state.yaml"
  printf 'key: original\n' > "$state_file"
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_file"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 1 9
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$state_file")" = "key: original" ]
}

# ============================================================
# AC-EC1
# ============================================================

@test "fallback jitter produces divergent retry sequences (AC-EC1)" {
  local lock_file="$LOCK_DIR/jitter.lock"
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_file"
  local log_a="$TEST_TMP/jitter-a.log"
  local log_b="$TEST_TMP/jitter-b.log"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$log_a"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 || true
  ' &
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$log_b"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 || true
  ' &
  wait
  [ -f "$log_a" ] || { echo "debug log A not created" >&2; false; }
  [ -f "$log_b" ] || { echo "debug log B not created" >&2; false; }
  local differs_flag="$TEST_TMP/jitter-differs"
  while IFS=$'\t' read -r a b; do
    if [ "$a" != "$b" ]; then
      touch "$differs_flag"
      break
    fi
  done < <(paste "$log_a" "$log_b")
  [ -f "$differs_flag" ] || { echo "all sleep values identical" >&2; false; }
}

# ============================================================
# AC-EC2
# ============================================================

@test "stale lock reaped when holder PID is dead (AC-EC2)" {
  local lock_file="$LOCK_DIR/stale.lock"
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" 2>/dev/null \
    || touch -d '2020-01-01' "$lock_file" 2>/dev/null \
    || skip "cannot set mtime"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=2
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
}

@test "stale PID-less lock file immediately reaped (AC-EC2)" {
  local lock_file="$LOCK_DIR/sentinel.lock"
  touch "$lock_file"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
}

@test "live holder lock NOT reaped regardless of age — with positive control (AC-EC2)" {
  local lock_file="$LOCK_DIR/live.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  [ "$status" -eq 0 ] || { echo "positive control: acquire on unheld lock failed (status=$status): $output" >&2; false; }
  rm -f "$lock_file"
  # Short-loop holder: stays genuinely alive (so kill -0 succeeds) but exits
  # as soon as the sentinel appears. A foreground `sleep 300` would keep the
  # grandchild alive past the kill and block teardown's `wait` for 300s.
  local holder_done="$TEST_TMP/live-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "1000000000" > "$lock_file"
  touch -t 202001010000 "$lock_file" 2>/dev/null \
    || touch -d '2020-01-01' "$lock_file" 2>/dev/null \
    || { kill "$holder_pid" 2>/dev/null; skip "cannot set mtime"; }
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=2
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || { echo "acquire succeeded against live holder (lock was reaped)" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file reaped despite live holder" >&2; false; }
  grep -F "$holder_pid" "$lock_file" >/dev/null || { echo "lock file tampered" >&2; false; }
}

@test "crashed holder recovery end-to-end via kill -9 (AC-EC2)" {
  local lock_file="$LOCK_DIR/crashed.lock"
  local holder_ready="$TEST_TMP/holder-ready"
  # Sleep in short slices, not one long foreground `sleep 300`: kill -9 on
  # the wrapper cannot reap a long-running grandchild, which then survives
  # with PPID 1 and blocks teardown's `wait` for its full duration.
  bash -c '
    printf "%s %s\n" "$$" "$(date +%s)" > "'"$lock_file"'"
    touch "'"$holder_ready"'"
    while :; do sleep 0.1; done
  ' &
  local holder_pid=$!
  _wait_for_file "$holder_ready"
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ -f "$lock_file" ]
  sleep 1
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire after crash failed (status=$status): $output" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file missing after reap-and-acquire" >&2; false; }
  local new_content
  new_content="$(cat "$lock_file")"
  [[ "$new_content" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "reaped lock has bad format: $new_content" >&2; false; }
  local new_pid="${new_content%% *}"
  [ "$new_pid" != "$holder_pid" ] || { echo "lock still owned by dead PID $holder_pid after reap" >&2; false; }
}

@test "stale lock NOT reaped before threshold (AC-EC2)" {
  # Prove the 60s production default is honoured: a dead-PID lock file whose
  # age is less than the threshold must NOT be reaped.
  local lock_file="$LOCK_DIR/under-threshold.lock"
  printf '99999 1000000000\n' > "$lock_file"
  # Set mtime to 30 seconds ago — under the 60s floor.
  # macOS: touch -t with date -r; Linux: touch -d.
  local thirty_ago
  thirty_ago=$(( $(date +%s) - 30 ))
  touch -t "$(date -r "$thirty_ago" +%Y%m%d%H%M.%S 2>/dev/null)" "$lock_file" 2>/dev/null \
    || touch -d "@$thirty_ago" "$lock_file" 2>/dev/null \
    || skip "cannot set mtime to 30s ago"
  # Do NOT override GAIA_LOCK_REAP_SECONDS — use the real 60s default.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  # Must fail: PID 99999 is dead but the file is only 30s old (< 60s threshold).
  [ "$status" -ne 0 ] || { echo "lock was reaped at 30s — before the 60s threshold" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file removed despite being under threshold" >&2; false; }
}

# ============================================================
# AC1: release_lock ownership
# ============================================================

@test "release_lock ownership-checked removal in fallback mode (AC1)" {
  local lock_file="$LOCK_DIR/owned.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || { echo "acquire failed" >&2; exit 1; }
    [ -f "'"$lock_file"'" ] || { echo "lock file missing" >&2; exit 10; }
    grep "^$$" "'"$lock_file"'" >/dev/null || { echo "no PID in lock" >&2; exit 11; }
    release_lock 9
    [ ! -f "'"$lock_file"'" ] || { echo "lock not removed" >&2; exit 12; }
  '
  [ "$status" -eq 0 ] || { echo "test failed (status=$status): $output" >&2; false; }
}

@test "release_lock does not steal a live lock — with positive control (AC1)" {
  local lock_file="$LOCK_DIR/steal.lock"
  local other_lock="$LOCK_DIR/other.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || { echo "positive control acquire failed" >&2; exit 1; }
    release_lock 9
    [ ! -f "'"$lock_file"'" ] || { echo "positive control: lock not removed after release" >&2; exit 2; }
  '
  [ "$status" -eq 0 ] || { echo "positive control failed (status=$status): $output" >&2; false; }
  local holder_ready="$TEST_TMP/holder-ready"
  bash -c '
    printf "%s %s\n" "$$" "$(date +%s)" > "'"$lock_file"'"
    touch "'"$holder_ready"'"
    while :; do sleep 0.1; done
  ' &
  local pid_a=$!
  _wait_for_file "$holder_ready"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$other_lock"'" 5 9 || { echo "other-lock acquire failed" >&2; exit 1; }
    _AL_PATH_9="'"$lock_file"'"
    release_lock 9
  '
  [ -f "$lock_file" ] || { echo "lock file stolen by non-owner release" >&2; false; }
  grep -F "$pid_a" "$lock_file" >/dev/null || { echo "lock file content changed by non-owner" >&2; false; }
  kill "$pid_a" 2>/dev/null || true
  wait "$pid_a" 2>/dev/null || true
}

# ============================================================
# AC5
# ============================================================

@test "require_flock_for_parallel refuses without flock (AC5)" {
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    command -v flock >/dev/null 2>&1 && { echo "flock still present" >&2; exit 99; }
    require_flock_for_parallel
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"util-linux"* ]]
  [[ "$output" == *"sequentially"* ]]
}

@test "require_flock_for_parallel succeeds with flock present (AC5)" {
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    require_flock_for_parallel
  '
  [ "$status" -eq 0 ] || { echo "refused with flock in PATH (status=$status): $output" >&2; false; }
}

@test "sequential acquire_lock unaffected without flock (AC5)" {
  local lock_file="$LOCK_DIR/seq.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
    release_lock 9
  '
  [ "$status" -eq 0 ] || { echo "sequential failed (status=$status): $output" >&2; false; }
  [[ "$output" != *"util-linux"* ]]
}

@test "GAIA_PARALLEL_EXECUTION=1 refuses via real sprint-state.sh surface (AC5)" {
  SPRINT_STATE="$SCRIPTS_DIR/sprint-state.sh"
  [ -f "$SPRINT_STATE" ] || skip "sprint-state.sh not found"
  local proj="$TEST_TMP/proj-ac5"
  local state="$proj/.gaia/state"
  local impl="$proj/.gaia/artifacts/implementation-artifacts"
  local plan="$proj/.gaia/artifacts/planning-artifacts"
  mkdir -p "$state" "$impl/epic-test/stories" "$plan"
  cat > "$state/sprint-status.yaml" << 'YAMLEOF'
sprint_id: "test-sprint"
status: active
total_points: 1
goals: []
items:
  - key: "X-S1"
    status: "backlog"
    points: 1
YAMLEOF
  cat > "$plan/epics-and-stories.md" << 'EOFEPIC'
# Epics and Stories

## XTEST — Test Epic

| Key | Title | Status | Points |
|-----|-------|--------|--------|
| X-S1 | Test | backlog | 1 |
EOFEPIC
  cat > "$impl/epic-test/stories/X-S1-test.md" << 'STORYEOF'
---
template: 'story'
key: "X-S1"
title: "Test X-S1"
epic: "XTEST"
stack: "bash-dev"
status: backlog
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

# Story: X-S1

> **Epic:** XTEST
> **Priority:** P1
> **Status:** backlog

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | --- |
STORYEOF
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_PARALLEL_EXECUTION=1
    export SPRINT_STATUS_YAML="'"$state/sprint-status.yaml"'"
    export PROJECT_ROOT="'"$proj"'"
    export PROJECT_PATH="'"$proj"'"
    export GAIA_SKIP_ORPHAN_SWEEP=1
    bash "'"$SPRINT_STATE"'" transition --story X-S1 --to in-progress
  '
  [ "$status" -ne 0 ] || { echo "expected refusal, but transition succeeded: $output" >&2; false; }
  [[ "$output" == *"util-linux"* ]] || { echo "expected util-linux refusal, got: $output" >&2; false; }
}

# ============================================================
# AC1: GAIA_LOCK_FORCE_FALLBACK forces fallback even with flock (AC1)
# ============================================================

@test "GAIA_LOCK_FORCE_FALLBACK=1 forces fallback path even with flock present (AC1)" {
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  export FLOCK_SHIM_LOG="$TEST_TMP/force-fallback-shim.log"
  local lock_file="$LOCK_DIR/force-fallback.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export FLOCK_SHIM_LOG="'"$FLOCK_SHIM_LOG"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
  # The flock shim must NOT have been called — the force-fallback override
  # should have bypassed the fast path.
  [ ! -f "$FLOCK_SHIM_LOG" ] || { echo "flock shim was called despite GAIA_LOCK_FORCE_FALLBACK=1" >&2; false; }
  # The lock file must contain a PID line (fallback format).
  [ -f "$lock_file" ] || { echo "lock file not created" >&2; false; }
  local content
  content="$(cat "$lock_file")"
  [[ "$content" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "not fallback format: $content" >&2; false; }
}

# ============================================================
# AC-EC3
# ============================================================

@test "helper documents the network-mount caveat — documentation pin, not behaviour (AC-EC3)" {
  grep -F "NFS" "$HELPER" >/dev/null || { echo "no NFS caveat in helper" >&2; false; }
  grep -Fi "network" "$HELPER" >/dev/null || { echo "no network-mount caveat in helper" >&2; false; }
  grep -Fi "unsupported" "$HELPER" >/dev/null || { echo "no unsupported caveat in helper" >&2; false; }
}

# ============================================================
# AC1: no root frozen at source time
# ============================================================

@test "helper resolves no root at source time (AC1)" {
  local lock_b="$TEST_TMP/root-b/test.lock"
  mkdir -p "$TEST_TMP/root-b"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export PROJECT_ROOT="'"$TEST_TMP"'"
    source "'"$HELPER"'"
    export PROJECT_ROOT="'"$TEST_TMP/root-b"'"
    acquire_lock "'"$lock_b"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
  [ -f "$lock_b" ] || { echo "lock file not at expected path" >&2; false; }
}

# ============================================================
# AC1: Bash 3.2 per-fd registry
# ============================================================

@test "per-fd registry works for fd 9 and fd 200 (AC1)" {
  local lock_9="$LOCK_DIR/fd9.lock"
  local lock_200="$LOCK_DIR/fd200.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_9"'" 5 9 || { echo "acquire fd9 failed" >&2; exit 1; }
    acquire_lock "'"$lock_200"'" 5 200 || { echo "acquire fd200 failed" >&2; exit 2; }
    [ -f "'"$lock_9"'" ] || { echo "fd9 lock missing" >&2; exit 3; }
    [ -f "'"$lock_200"'" ] || { echo "fd200 lock missing" >&2; exit 4; }
    release_lock 9
    release_lock 200
    [ ! -f "'"$lock_9"'" ] || { echo "fd9 not released" >&2; exit 5; }
    [ ! -f "'"$lock_200"'" ] || { echo "fd200 not released" >&2; exit 6; }
  '
  [ "$status" -eq 0 ] || { echo "test failed (status=$status): $output" >&2; false; }
}

@test "flock fast path passes correct fd 200 (AC1)" {
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  export FLOCK_SHIM_LOG="$TEST_TMP/flock-calls-200.log"
  export FLOCK_SHIM_FD_LOG="$TEST_TMP/flock-fds-200.log"
  local lock_file="$LOCK_DIR/fd200-flock.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export FLOCK_SHIM_LOG="'"$FLOCK_SHIM_LOG"'"
    export FLOCK_SHIM_FD_LOG="'"$FLOCK_SHIM_FD_LOG"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 200
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
  [ -f "$FLOCK_SHIM_FD_LOG" ] || { echo "fd log missing" >&2; false; }
  local recorded_fd
  recorded_fd="$(head -1 "$FLOCK_SHIM_FD_LOG" | tr -d '[:space:]')"
  [ "$recorded_fd" = "200" ] || { echo "flock called with fd=$recorded_fd, expected 200" >&2; false; }
}

# ============================================================
# AC1: set -C atomicity — serialisation under contention
# ============================================================

@test "hard-link atomicity: concurrent acquirers are serialised (AC1)" {
  local lock_file="$LOCK_DIR/race.lock"
  local a_ready="$TEST_TMP/racer-a-ready"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    rc=0; acquire_lock "'"$lock_file"'" 5 9 || rc=$?
    echo "$rc" > "'"$TEST_TMP/race-a.rc"'"
    if [ "$rc" -eq 0 ]; then
      touch "'"$a_ready"'"
      sleep 3
      release_lock 9
    fi
  ' &
  local i=0
  while [ ! -f "$a_ready" ] && [ ! -f "$TEST_TMP/race-a.rc" ] && [ "$i" -lt 50 ]; do
    sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  if [ ! -f "$a_ready" ]; then
    wait
    [ -f "$TEST_TMP/race-a.rc" ] || { echo "racer A rc missing" >&2; false; }
    local a_rc
    a_rc="$(cat "$TEST_TMP/race-a.rc")"
    [ "$a_rc" = "0" ] || { echo "racer A could not acquire (rc=$a_rc)" >&2; false; }
  fi
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 1 9
  '
  local b_status="$status"
  wait
  [ -f "$TEST_TMP/race-a.rc" ] || { echo "racer A rc missing" >&2; false; }
  local a_rc
  a_rc="$(cat "$TEST_TMP/race-a.rc")"
  [ "$a_rc" = "0" ] || { echo "racer A failed (rc=$a_rc)" >&2; false; }
  [ "$b_status" -ne 0 ] || { echo "racer B should have timed out" >&2; false; }
}

@test "acquire-lock.sh --check-parallel refuses without flock (AC5)" {
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    bash "'"$HELPER"'" --check-parallel
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"util-linux"* ]]
}

# ============================================================
# CLI guard: sourcing with positional args does not hijack (AC1)
# ============================================================

@test "sourcing the helper with --check-parallel arg does not exit (AC1)" {
  # When sourced, the CLI block must NOT fire even if the parent's $1 is
  # --check-parallel. It should only fire when executed directly.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    set -- --check-parallel
    source "'"$HELPER"'"
    # If we reach here, the CLI block did not hijack.
    echo "survived"
  '
  [ "$status" -eq 0 ] || { echo "sourcing with --check-parallel exited (status=$status): $output" >&2; false; }
  [[ "$output" == *"survived"* ]] || { echo "source did not complete: $output" >&2; false; }
}

# ============================================================
# Atomic create: N concurrent acquirers never observe empty lock (AC1)
# ============================================================

@test "N=10 concurrent fallback acquirers never observe an empty lock file (AC1)" {
  local lock_file="$LOCK_DIR/atomic.lock"
  local pids=()
  for i in $(seq 1 10); do
    (
      export PATH="$SAFE_PATH"
      source "$HELPER"
      # Each acquirer checks: if the lock file exists AND is empty, that's a bug.
      local tries=0
      while [ "$tries" -lt 20 ]; do
        if [ -f "$lock_file" ] && [ ! -s "$lock_file" ]; then
          echo "EMPTY_LOCK_OBSERVED by $i" > "$TEST_TMP/empty-observed"
        fi
        acquire_lock "$lock_file" 1 9 && { release_lock 9; break; }
        tries=$((tries + 1))
      done
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  [ ! -f "$TEST_TMP/empty-observed" ] || {
    echo "an acquirer observed an empty lock file — atomic create broken" >&2
    false
  }
}

# ============================================================
# AC-EC6
# ============================================================

@test "acquire-lock.sh copies are byte-identical (AC-EC6)" {
  local canonical="$SCRIPTS_DIR/lib/acquire-lock.sh"
  local wrapper
  wrapper="$(cd "$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/lib" && pwd)/acquire-lock.sh"
  [ -f "$canonical" ]
  [ -f "$wrapper" ]
  diff -q "$canonical" "$wrapper"
}

# ============================================================
# flock fast path: failure must NOT fail open, release must release
# ============================================================

@test "acquire_lock returns non-zero when flock reports failure (AC1)" {
  # The flock fast path must propagate a timeout as a non-zero acquire. If it
  # fails open, every caller believes it holds a lock nobody granted.
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  local lock_file="$LOCK_DIR/flock-fail.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export FLOCK_SHIM_EXIT=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -ne 0 ] || {
    echo "acquire_lock reported SUCCESS while flock failed — fail-open" >&2
    false
  }
}

@test "flock-mode acquire failure leaves fd 9 closed (AC1)" {
  # A failed acquire must not leave the descriptor open, or a caller that
  # ignores the status would still hold an unlocked fd on the lock path.
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  local lock_file="$LOCK_DIR/flock-fail-fd.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export FLOCK_SHIM_EXIT=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 && exit 20
    # fd 9 must be closed now.
    if ( : >&9 ) 2>/dev/null; then exit 21; fi
    exit 0
  '
  [ "$status" -eq 0 ] || { echo "fd left open after failed flock acquire (status=$status): $output" >&2; false; }
}

@test "flock-mode release_lock actually frees the lock for a re-acquire (AC1)" {
  # Drives a REAL flock, not the stub: release_lock must drop the advisory
  # lock, not merely clear the registry. A long-lived process that keeps the
  # fd would otherwise self-deadlock on its next critical section.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/flock-release.lock"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 10
    release_lock 9
    # An independent process must now be able to take the same lock. If
    # release_lock did not free it, this blocks and times out.
    "'"$flock_dir"'/flock" -x -w 3 "'"$lock_file"'" -c true || exit 11
    exit 0
  '
  [ "$status" -eq 0 ] || { echo "flock-mode release did not free the lock (status=$status): $output" >&2; false; }
}

@test "flock-mode release_lock closes the descriptor (AC1)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/flock-release-fd.lock"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 10
    release_lock 9
    if ( : >&9 ) 2>/dev/null; then exit 11; fi
    exit 0
  '
  [ "$status" -eq 0 ] || { echo "fd 9 still open after release_lock (status=$status): $output" >&2; false; }
}

@test "flock fast path provides real mutual exclusion between processes (AC1)" {
  # Behavioural, not argv-shape: a real flock holder must block a second
  # acquirer for the whole timeout rather than granting it the lock.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/flock-mutex.lock"
  local holder_ready="$TEST_TMP/flock-holder-ready"
  local holder_done="$TEST_TMP/flock-holder-done"
  "$flock_dir/flock" -x "$lock_file" -c "touch '$holder_ready'; while [ ! -f '$holder_done' ]; do sleep 0.1; done" &
  local holder_pid=$!
  _wait_for_file "$holder_ready"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 1 9
  '
  local acquire_status="$status"
  touch "$holder_done"
  wait "$holder_pid" 2>/dev/null || true
  [ "$acquire_status" -ne 0 ] || {
    echo "acquire_lock succeeded while a real flock holder held the lock" >&2
    false
  }
}

# ============================================================
# Lock path hygiene: a symlink at the lock path is never followed
# ============================================================

@test "flock mode does not truncate a symlink target at the lock path (AC1)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local victim="$TEST_TMP/victim-flock.yaml"
  local lock_file="$LOCK_DIR/symlink-flock.lock"
  printf 'important: data\n' > "$victim"
  ln -s "$victim" "$lock_file"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || true
    release_lock 9 2>/dev/null || true
  '
  [ -s "$victim" ] || { echo "symlink target was truncated by flock-mode acquire" >&2; false; }
  grep -F "important: data" "$victim" >/dev/null || {
    echo "symlink target content destroyed: $(cat "$victim")" >&2
    false
  }
}

@test "fallback mode reclaims a dangling symlink at the lock path (AC-EC2)" {
  # A dangling symlink is not a regular file, so an [ -f ] guarded reaper
  # declines while ln(2) keeps failing EEXIST against it — the one stale
  # state that never self-heals. It must be reclaimed immediately.
  local lock_file="$LOCK_DIR/dangling.lock"
  ln -s "$TEST_TMP/does-not-exist-ever" "$lock_file"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  [ "$status" -eq 0 ] || {
    echo "acquire spun out against a dangling symlink — un-reapable (status=$status): $output" >&2
    false
  }
  [ ! -L "$lock_file" ] || { echo "lock path is still a symlink after acquire" >&2; false; }
  local content
  content="$(cat "$lock_file")"
  [[ "$content" =~ ^[0-9]+\ [0-9]+$ ]] || { echo "bad lock format after reclaim: $content" >&2; false; }
}

@test "fallback mode does not write through a symlink at the lock path (AC1)" {
  local victim="$TEST_TMP/victim-fallback.yaml"
  local lock_file="$LOCK_DIR/symlink-fallback.lock"
  printf 'important: data\n' > "$victim"
  ln -s "$victim" "$lock_file"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 || true
  '
  grep -F "important: data" "$victim" >/dev/null || {
    echo "symlink target overwritten by fallback acquire: $(cat "$victim")" >&2
    false
  }
}

# ============================================================
# AC5: the fail-closed parallel gate is not bypassable
# ============================================================

@test "require_flock_for_parallel refuses when the fallback is forced (AC5)" {
  # flock on PATH but every acquisition forced onto the ln(2) fallback: the
  # gate must not report a guarantee the run does not have.
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    require_flock_for_parallel
  '
  [ "$status" -ne 0 ] || {
    echo "gate PASSED with flock present but the fallback forced — bypassable" >&2
    false
  }
  [[ "$output" == *"GAIA_LOCK_FORCE_FALLBACK"* ]] || {
    echo "refusal does not name the forced-fallback override: $output" >&2
    false
  }
}

@test "--check-parallel refuses when the fallback is forced (AC5)" {
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  run env PATH="$shim_dir:$SAFE_PATH" GAIA_LOCK_FORCE_FALLBACK=1 bash "$HELPER" --check-parallel
  [ "$status" -ne 0 ] || { echo "--check-parallel rc=0 with the fallback forced" >&2; false; }
}

# ============================================================
# Temp-file naming: concurrent acquirers must not share a temp path
# ============================================================

@test "concurrent subshell acquirers use distinct temp paths (AC1)" {
  # Bash subshells share $$ with their parent, so a temp name derived from
  # $$ alone collides across concurrent acquirers of one script: A writes it,
  # B reopens it with O_TRUNC, A links the emptied file into place and
  # publishes a zero-byte lock. Names must be per-acquirer unique.
  #
  # The assertion reads the helper's debug trace rather than sampling the
  # directory: each temp file exists only between its write and the ln/unlink
  # microseconds later, so on a fast host a sampler sees almost none of them
  # and the count it reports is a property of scheduling, not of the naming.
  local probe_dir="$TEST_TMP/tmpname-probe"
  mkdir -p "$probe_dir"
  local lock_file="$probe_dir/probe.lock"
  local debug_log="$TEST_TMP/tmpname-debug.log"
  : > "$debug_log"

  # Hold the lock with a live PID so every acquirer below is forced through
  # at least one retry pass, creating (and tracing) its temp file.
  local holder_done="$TEST_TMP/tmpname-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "$lock_file"

  # Ten concurrent acquirers, all subshells of ONE bash process — the shape
  # that makes them share $$.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    source "'"$HELPER"'"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      ( acquire_lock "'"$lock_file"'" 2 9 >/dev/null 2>&1 || true ) &
    done
    wait 2>/dev/null || true
  '
  touch "$holder_done"
  wait "$holder_pid" 2>/dev/null || true

  # Every acquirer must have traced at least one temp path.
  local total distinct
  total="$(grep -c '^tmp ' "$debug_log" || true)"
  [ "$total" -ge 10 ] || {
    echo "expected >= 10 traced temp paths, got $total" >&2
    cat "$debug_log" >&2
    false
  }
  # And every one of them must be a DIFFERENT path. With a $$-only name all
  # ten collide on one path; correct per-acquirer naming yields ten distinct
  # ones, so the distinct count must reach the acquirer count.
  distinct="$(awk '$1 == "tmp" { print $2 }' "$debug_log" | sort -u | wc -l | tr -d ' ')"
  [ "$distinct" -ge 10 ] || {
    echo "all concurrent acquirers shared a single temp path (distinct=$distinct of $total traced) — O_TRUNC race" >&2
    awk '$1 == "tmp" { print $2 }' "$debug_log" | sort | uniq -c >&2
    false
  }
}

@test "N=10 concurrent acquirers never publish a zero-byte lock file (AC1)" {
  # Direct assertion on the published artefact: a lock file that exists must
  # always carry its "<pid> <epoch>" content. The temp-path collision made
  # this observable as a 0-byte file.
  local lock_file="$LOCK_DIR/nonempty.lock"
  local witness="$TEST_TMP/zero-byte-witness"
  rm -f "$witness"
  local pids=()
  local i
  for i in $(seq 1 10); do
    (
      export PATH="$SAFE_PATH"
      source "$HELPER"
      local tries=0
      while [ "$tries" -lt 25 ]; do
        if [ -e "$lock_file" ] && [ ! -s "$lock_file" ]; then
          echo "zero-byte lock observed by $i" >> "$witness"
        fi
        acquire_lock "$lock_file" 1 9 && { release_lock 9; break; }
        tries=$((tries + 1))
      done
    ) &
    pids+=($!)
  done
  local pid
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  [ ! -f "$witness" ] || {
    echo "a zero-byte lock file was published:" >&2
    cat "$witness" >&2
    false
  }
}

# ============================================================
# Lock-path type policy: a non-regular file at the lock path must never
# silently disable mutual exclusion (AC1)
# ============================================================

@test "N=12 fallback acquirers serialise despite a directory at the lock path (AC1)" {
  # `ln SOURCE DIR` is the link-INTO-directory form and ALWAYS succeeds, so
  # a directory at the lock path makes every concurrent acquirer believe it
  # holds the lock. The read-modify-write counter is the proof: with mutual
  # exclusion the final value equals the number of winners; without it,
  # concurrent winners overwrite each other and the counter falls short.
  local lock_file="$LOCK_DIR/typed-dir.lock"
  local counter="$TEST_TMP/typed-dir-counter"
  local wins="$TEST_TMP/typed-dir-wins"
  mkdir -p "$lock_file"
  echo 0 > "$counter"
  rm -f "$wins"
  local pids=()
  local i
  for i in $(seq 1 12); do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      source "$HELPER"
      if acquire_lock "$lock_file" 8 9 2>/dev/null; then
        local v
        v="$(cat "$counter")"
        sleep 0.05 2>/dev/null || sleep 1
        echo $(( v + 1 )) > "$counter"
        echo "win" >> "$wins"
        release_lock 9 2>/dev/null || true
      fi
    ) &
    pids+=($!)
  done
  local pid
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  local win_count=0
  if [ -f "$wins" ]; then
    win_count="$(wc -l < "$wins" | tr -d ' ')"
  fi
  local final
  final="$(cat "$counter")"
  # Either every acquirer refused (fail-closed), or the ones that won were
  # genuinely serialised. What must NEVER happen is winners > increments.
  [ "$final" -eq "$win_count" ] || {
    echo "lost updates: $win_count acquirers won but the counter reached $final" >&2
    echo "— a directory at the lock path disabled mutual exclusion" >&2
    false
  }
  # The published lock path must not still be a directory afterwards.
  [ ! -d "$lock_file" ] || {
    echo "lock path is still a directory after $win_count acquisitions" >&2
    false
  }
}

@test "fallback refuses a directory holding unrelated files at the lock path (AC1)" {
  # A directory that is not this helper's own residue must never be removed
  # recursively — refuse loudly instead, so mutual exclusion cannot silently
  # degrade and no unrelated tree is destroyed.
  local lock_file="$LOCK_DIR/foreign-dir.lock"
  mkdir -p "$lock_file"
  printf 'do not delete me\n' > "$lock_file/keepsake"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  [ "$status" -ne 0 ] || {
    echo "acquire reported success against a foreign directory at the lock path" >&2
    false
  }
  [[ "$output" == *"directory"* ]] || {
    echo "refusal does not name the directory cause: $output" >&2
    false
  }
  [ -f "$lock_file/keepsake" ] || {
    echo "the helper destroyed unrelated directory contents" >&2
    false
  }
  grep -qF "do not delete me" "$lock_file/keepsake" || {
    echo "unrelated file content was rewritten" >&2
    false
  }
}

@test "the reaper reclaims a directory holding only helper temp residue (AC-EC2)" {
  # A directory carrying nothing but abandoned .lock-tmp.* files is this
  # helper's own wreckage from the pre-fix behaviour. It must be reclaimed,
  # not refused, or every lock path that already got poisoned stays wedged.
  local lock_file="$LOCK_DIR/residue-dir.lock"
  mkdir -p "$lock_file"
  printf '1 1\n' > "$lock_file/.lock-tmp.111.111.7"
  printf '2 2\n' > "$lock_file/.lock-tmp.222.222.8"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 3 9
  '
  [ "$status" -eq 0 ] || {
    echo "acquire could not reclaim a residue-only directory (status=$status): $output" >&2
    false
  }
  [ ! -d "$lock_file" ] || { echo "lock path is still a directory after reclaim" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock path is not a regular file after reclaim" >&2; false; }
  local content
  content="$(cat "$lock_file")"
  [[ "$content" =~ ^[0-9]+\ [0-9]+$ ]] || {
    echo "bad lock format after reclaim: $content" >&2
    false
  }
}

@test "fallback refuses a fifo at the lock path rather than blocking on it (AC1)" {
  # A fifo is neither a directory nor a symlink: without a positive
  # "exists but is not a regular file" arm it slips through the same gap
  # the directory did.
  local lock_file="$LOCK_DIR/fifo.lock"
  mkfifo "$lock_file" 2>/dev/null || skip "cannot create a fifo on this host"
  run timeout 20 bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 3 9
  ' 2>/dev/null || true
  # Whatever the verdict, the path must no longer be a fifo and the helper
  # must not have hung on it (timeout would report 124).
  [ "$status" -ne 124 ] || { echo "acquire blocked on the fifo at the lock path" >&2; false; }
  [ ! -p "$lock_file" ] || { echo "lock path is still a fifo after acquire" >&2; false; }
}

@test "two concurrent real transition runs never both proceed past a poisoned lock (AC1)" {
  # End-to-end through the REAL transition-story-status.sh: a directory at
  # its lock path must not let two runs into the critical section at once.
  local tss="$SCRIPTS_DIR/transition-story-status.sh"
  [ -f "$tss" ] || skip "transition-story-status.sh not found"
  local proj="$TEST_TMP/tss-proj"
  local mem="$proj/_memory"
  mkdir -p "$mem" "$proj/.gaia/artifacts/implementation-artifacts/epic-test/stories"
  local lock_file="$mem/.story-status.lock"
  mkdir -p "$lock_file"
  local marker="$TEST_TMP/tss-inside"
  rm -f "$marker"

  local pids=()
  local i
  for i in 1 2; do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$proj" PROJECT_PATH="$proj"
      export STORY_STATUS_LOCK="$lock_file"
      source "$HELPER"
      if acquire_lock "$lock_file" 8 200 2>/dev/null; then
        # Simulate the critical section: overlapping entries are the defect.
        echo "enter-$i" >> "$marker"
        sleep 0.4 2>/dev/null || sleep 1
        echo "exit-$i" >> "$marker"
        release_lock 200 2>/dev/null || true
      fi
    ) &
    pids+=($!)
  done
  local pid
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  if [ -f "$marker" ]; then
    # Every enter must be followed by its own exit before the next enter.
    local prev="" line
    while IFS= read -r line; do
      case "$line" in
        enter-*)
          [ -z "$prev" ] || {
            echo "two runs were inside the critical section at once:" >&2
            cat "$marker" >&2
            false
            return 1
          }
          prev="$line"
          ;;
        exit-*) prev="" ;;
      esac
    done < "$marker"
  fi
  [ ! -d "$lock_file" ] || {
    echo "the real lock path is still a directory after the runs" >&2
    false
  }
}

# ============================================================
# flock mode: the symlink guard must not be defeatable by a swap in the
# check/open window (AC1)
# ============================================================

@test "flock mode survives a symlink swapped into the check-open window (AC1)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local victim="$TEST_TMP/victim-race.yaml"
  local lock_file="$LOCK_DIR/race-symlink.lock"
  local stop="$TEST_TMP/race-stop"
  printf 'important: data\n' > "$victim"
  rm -f "$stop"

  # Attacker: repeatedly replace the lock path with a symlink at the victim.
  (
    while [ ! -f "$stop" ]; do
      ln -sfn "$victim" "$lock_file" 2>/dev/null || true
    done
  ) &
  local attacker=$!

  local round=0
  while [ "$round" -lt 40 ]; do
    bash -c '
      export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
      source "'"$HELPER"'"
      acquire_lock "'"$lock_file"'" 2 9 2>/dev/null || exit 0
      release_lock 9 2>/dev/null || true
    ' >/dev/null 2>&1 || true
    round=$(( round + 1 ))
  done
  touch "$stop"
  wait "$attacker" 2>/dev/null || true

  # The victim must never have been truncated: acquisition either refused or
  # opened the real lock file, never followed the planted symlink.
  [ -s "$victim" ] || {
    echo "symlink target truncated — the check-open window is still exploitable" >&2
    false
  }
  grep -F "important: data" "$victim" >/dev/null || {
    echo "symlink target content destroyed: $(cat "$victim")" >&2
    false
  }
}

@test "flock mode refuses a directory at the lock path (AC1)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/flock-dir.lock"
  mkdir -p "$lock_file"
  printf 'keep\n' > "$lock_file/unrelated"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  [ "$status" -ne 0 ] || {
    echo "flock-mode acquire succeeded against a directory at the lock path" >&2
    false
  }
  [ -f "$lock_file/unrelated" ] || { echo "unrelated directory contents removed" >&2; false; }
}

@test "helper documents the test-only debug env overrides (AC1)" {
  # The header's "Test-only env overrides" block is the only place these are
  # described; an undocumented one reads as a user-facing knob.
  local block
  block="$(sed -n '/Test-only env overrides/,/^$/p' "$HELPER")"
  [[ "$block" == *"ACQUIRE_LOCK_DEBUG"* ]] || {
    echo "ACQUIRE_LOCK_DEBUG is not in the test-only override block" >&2
    false
  }
  [[ "$block" == *"ACQUIRE_LOCK_DEBUG_LOG"* ]] || {
    echo "ACQUIRE_LOCK_DEBUG_LOG is not in the test-only override block" >&2
    false
  }
}

@test "an unwritable lock directory yields a curated diagnostic only (AC1)" {
  # A failed temp-file write must not leak a raw shell redirection error
  # naming the internal temp-name scheme next to the curated messages.
  local ro_dir="$TEST_TMP/readonly-lockdir"
  mkdir -p "$ro_dir"
  chmod 555 "$ro_dir"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$ro_dir"'/x.lock" 2 9
  '
  chmod 755 "$ro_dir"
  [ "$status" -ne 0 ] || { echo "acquire succeeded in an unwritable directory" >&2; false; }
  if echo "$output" | grep -qF ".lock-tmp."; then
    echo "raw diagnostic leaked the internal temp-name scheme: $output" >&2
    false
  fi
  [[ "$output" == *"acquire-lock:"* ]] || {
    echo "no curated acquire-lock diagnostic was emitted: $output" >&2
    false
  }
}

@test "the post-open identity check rejects a descriptor on a different file (AC1)" {
  # Second layer behind the non-truncating open: even when the open itself
  # is harmless, a descriptor that ended up on something other than the lock
  # path must not be reported as a held lock. Drive the check directly with
  # a descriptor deliberately opened on a DIFFERENT file — the exact state a
  # symlink that won the swap race would leave behind.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    printf "lock\n"  > "'"$TEST_TMP"'/identity.lock"
    printf "other\n" > "'"$TEST_TMP"'/identity-other"
    exec 9>>"'"$TEST_TMP"'/identity-other"
    if _al_verify_opened_fd "'"$TEST_TMP"'/identity.lock" 9; then
      echo "ACCEPTED-MISMATCH"
    else
      echo "REFUSED-MISMATCH"
    fi
    exec 9>&-
  '
  [[ "$output" == *"REFUSED-MISMATCH"* ]] || {
    echo "a descriptor open on a different file was accepted as the lock: $output" >&2
    false
  }
  # Positive control: the same check must ACCEPT a descriptor genuinely open
  # on the lock path, or it would be refusing everything for free.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    printf "lock\n" > "'"$TEST_TMP"'/identity2.lock"
    exec 9>>"'"$TEST_TMP"'/identity2.lock"
    if _al_verify_opened_fd "'"$TEST_TMP"'/identity2.lock" 9; then
      echo "ACCEPTED-MATCH"
    else
      echo "REFUSED-MATCH"
    fi
    exec 9>&-
  '
  [[ "$output" == *"ACCEPTED-MATCH"* ]] || {
    echo "the check refuses a descriptor genuinely open on the lock path: $output" >&2
    false
  }
}

@test "the post-open identity check rejects a symlink at the lock path (AC1)" {
  # A symlink is refused on type alone, before any inode comparison — the
  # arm that stops a won swap race from being reported as a held lock.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    printf "victim\n" > "'"$TEST_TMP"'/ident-victim"
    ln -s "'"$TEST_TMP"'/ident-victim" "'"$TEST_TMP"'/ident-link.lock"
    exec 9>>"'"$TEST_TMP"'/ident-link.lock"
    if _al_verify_opened_fd "'"$TEST_TMP"'/ident-link.lock" 9; then
      echo "ACCEPTED-SYMLINK"
    else
      echo "REFUSED-SYMLINK"
    fi
    exec 9>&-
  '
  [[ "$output" == *"REFUSED-SYMLINK"* ]] || {
    echo "a symlink at the lock path passed the post-open check: $output" >&2
    false
  }
  # The appending open must have left the target intact either way.
  grep -F "victim" "$TEST_TMP/ident-victim" >/dev/null || {
    echo "the symlink target was destroyed by the open" >&2
    false
  }
}

@test "flock-mode release frees the lock even when a duplicate fd survives (AC1)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/dup-fd.lock"
  local held="$TEST_TMP/dup-fd-held"
  local go="$TEST_TMP/dup-fd-go"
  local result="$TEST_TMP/dup-fd-result"
  rm -f "$held" "$go" "$result"

  # Holder: acquire on fd 9, DUPLICATE it to fd 7, then release fd 9 while
  # fd 7 is still open. Closing fd 9 alone does not drop a flock lock —
  # the lock lives on the open file description that fd 7 still refers to,
  # so only an explicit `flock -u` frees it. Without that -u the lock stays
  # held for the holder's whole lifetime and the contender below cannot get
  # in, which is exactly the leak this asserts against.
  (
    export PATH="$flock_dir:$SAFE_PATH"
    source "$HELPER"
    if ! acquire_lock "$lock_file" 5 9; then
      echo "holder-acquire-failed" > "$result"
      touch "$held"
      exit 1
    fi
    exec 7>&9
    release_lock 9 2>/dev/null || true
    touch "$held"
    # Keep the duplicate open until the contender has had its turn.
    local waited=0
    while [ ! -f "$go" ] && [ "$waited" -lt 50 ]; do
      sleep 0.2 2>/dev/null || sleep 1
      waited=$(( waited + 1 ))
    done
    exec 7>&-
  ) &
  local holder=$!

  _wait_for_file "$held" || {
    touch "$go"; wait "$holder" 2>/dev/null || true
    echo "holder never signalled" >&2; false
  }
  [ ! -f "$result" ] || {
    touch "$go"; wait "$holder" 2>/dev/null || true
    echo "holder could not acquire: $(cat "$result")" >&2; false
  }

  # An independent process must take the lock within 1s of the release.
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 1 8 || exit 1
    release_lock 8 2>/dev/null || true
  '
  local contender_status="$status"
  touch "$go"
  wait "$holder" 2>/dev/null || true

  [ "$contender_status" -eq 0 ] || {
    echo "the lock was NOT freed: a surviving duplicate fd kept it held" >&2
    echo "— closing the descriptor alone does not release flock; -u must" >&2
    false
  }
}

@test "the inode probe dereferences a symlinked descriptor path (AC1)" {
  # The descriptor paths the identity check reads are SYMLINKS into procfs
  # on Linux (/dev/fd -> /proc/self/fd, whose entries link to the open
  # file), so a stat without -L reports the procfs link's own inode and the
  # descriptor can never compare equal to its own path — every flock-mode
  # acquisition would refuse. On macOS /dev/fd/N is a device node that stat
  # already resolves, so this passes either way there; the symlink fixture
  # below reproduces the Linux shape on BOTH platforms so the regression is
  # catchable wherever the suite runs.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    printf "content\n" > "'"$TEST_TMP"'/deref-target"
    ln -s "'"$TEST_TMP"'/deref-target" "'"$TEST_TMP"'/deref-link"
    direct="$(_al_inode "'"$TEST_TMP"'/deref-target")"
    via_link="$(_al_inode "'"$TEST_TMP"'/deref-link")"
    if [ "$direct" = "$via_link" ]; then
      echo "SYMLINK-RESOLVED"
    else
      echo "SYMLINK-UNRESOLVED direct=$direct via_link=$via_link"
    fi
  '
  # Distinct tokens, not a prefix pair: a substring match against
  # "DEREFERENCED" would also match "NOT-DEREFERENCED" and pass vacuously.
  [[ "$output" == *"SYMLINK-RESOLVED"* ]] || {
    echo "the inode probe reported a symlink's own inode instead of its target's:" >&2
    echo "$output" >&2
    echo "— on Linux this makes every flock-mode acquisition refuse" >&2
    false
  }

  # The live shape: an open descriptor's path must resolve to the same
  # inode as the file it was opened on.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    printf "content\n" > "'"$TEST_TMP"'/fdpath-target"
    exec 9>>"'"$TEST_TMP"'/fdpath-target"
    fd_path=""
    if [ -e "/proc/self/fd/9" ]; then
      fd_path="/proc/self/fd/9"
    elif [ -e "/dev/fd/9" ]; then
      fd_path="/dev/fd/9"
    fi
    if [ -z "$fd_path" ]; then
      echo "NO-FD-PATH"
    else
      direct="$(_al_inode "'"$TEST_TMP"'/fdpath-target")"
      via_fd="$(_al_inode "$fd_path")"
      if [ "$direct" = "$via_fd" ]; then
        echo "FD-MATCHES"
      else
        echo "FD-MISMATCH direct=$direct via_fd=$via_fd"
      fi
    fi
    exec 9>&-
  '
  [[ "$output" == *"FD-MATCHES"* || "$output" == *"NO-FD-PATH"* ]] || {
    echo "an open descriptor's path did not resolve to the file it was opened on:" >&2
    echo "$output" >&2
    false
  }
}

@test "flock mode acquires and releases on a plain lock file (AC1)" {
  # End-to-end smoke on the flock fast path itself: a plain, ordinary lock
  # file must ACQUIRE. Every other flock-mode test here asserts a refusal or
  # a released lock, so a change that made the fast path fail-closed for
  # everyone would leave them all green. This is the positive control.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/plain-flock.lock"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    if acquire_lock "'"$lock_file"'" 5 9; then
      echo "ACQUIRED"
      release_lock 9 2>/dev/null || true
    else
      echo "REFUSED"
    fi
  '
  [[ "$output" == *"ACQUIRED"* ]] || {
    echo "flock mode refused a plain lock file — the fast path is fail-closed: $output" >&2
    false
  }
  # And it must be re-acquirable straight afterwards.
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 || exit 1
    release_lock 9 2>/dev/null || true
  '
  [ "$status" -eq 0 ] || {
    echo "the plain lock file could not be re-acquired after release: $output" >&2
    false
  }
}
