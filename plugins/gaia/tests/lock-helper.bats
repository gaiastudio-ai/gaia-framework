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
              dirname basename readlink id tee yq jq git chmod perl find xargs cut od uname getconf; do
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
exit 0
SHIMEOF
  chmod +x "$shim_dir/flock"
  printf '%s' "$shim_dir"
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
  sleep 300 &
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
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || { echo "acquire succeeded against live holder (lock was reaped)" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file reaped despite live holder" >&2; false; }
  grep -F "$holder_pid" "$lock_file" >/dev/null || { echo "lock file tampered" >&2; false; }
}

@test "crashed holder recovery end-to-end via kill -9 (AC-EC2)" {
  local lock_file="$LOCK_DIR/crashed.lock"
  local holder_ready="$TEST_TMP/holder-ready"
  bash -c '
    printf "%s %s\n" "$$" "$(date +%s)" > "'"$lock_file"'"
    touch "'"$holder_ready"'"
    sleep 300
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
    sleep 300
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

@test "NFS caveat documented in helper source (AC-EC3)" {
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
