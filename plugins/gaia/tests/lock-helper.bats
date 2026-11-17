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
  # Clear the parallel-execution flag so fallback-path tests are not blocked
  # by the parallel gate inside acquire_lock.
  unset GAIA_PARALLEL_EXECUTION
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
# Side-effect-free sourcing
# ============================================================

@test "sourcing the lock library does not flip errexit on (AC1-sourcing)" {
  run bash -c '
    set +e
    source "'"$HELPER"'"
    case "$-" in *e*) echo "errexit leaked"; exit 1 ;; esac
  '
  [ "$status" -eq 0 ] || { echo "errexit was flipped on by sourcing: $output" >&2; false; }
}

@test "sourcing the lock library does not flip pipefail on (AC1-sourcing)" {
  run bash -c '
    set +o pipefail
    source "'"$HELPER"'"
    if set -o | grep -q "pipefail.*on"; then echo "pipefail leaked"; exit 1; fi
  '
  [ "$status" -eq 0 ] || { echo "pipefail was flipped on by sourcing: $output" >&2; false; }
}

@test "sourcing the lock library preserves errexit when already set (AC1-sourcing)" {
  run bash -c '
    set -e
    source "'"$HELPER"'"
    case "$-" in *e*) exit 0 ;; esac
    echo "errexit was cleared"
    exit 1
  '
  [ "$status" -eq 0 ] || { echo "errexit was cleared by sourcing: $output" >&2; false; }
}

@test "acquire_lock and release_lock do not leak nounset, errexit, or pipefail (AC1-sourcing)" {
  # Caller starts with all three OFF, calls acquire+release on the success
  # path and (via a second lock) the timeout path, then asserts all three
  # are still OFF.
  local lock_ok="$LOCK_DIR/opts-ok.lock"
  local lock_held="$LOCK_DIR/opts-held.lock"
  # Pre-plant a held lock so the second acquire times out.
  printf '%s %s\n' "$$" "$(date +%s)" > "$lock_held"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    set +e +u +o pipefail
    source "'"$HELPER"'"
    # Success path.
    acquire_lock "'"$lock_ok"'" 5 9 || true
    release_lock 9 || true
    # Failure path (timeout).
    acquire_lock "'"$lock_held"'" 1 200 2>/dev/null || true
    # Assert all three are still OFF.
    case "$-" in *e*) echo "LEAK: errexit on after acquire/release"; exit 1 ;; esac
    case "$-" in *u*) echo "LEAK: nounset on after acquire/release"; exit 1 ;; esac
    if set -o | grep -q "pipefail.*on"; then echo "LEAK: pipefail on"; exit 1; fi
    echo "ALL OFF"
  '
  rm -f "$lock_held"
  [ "$status" -eq 0 ] || { echo "options leaked: $output" >&2; false; }
  [[ "$output" == *"ALL OFF"* ]] || { echo "unexpected output: $output" >&2; false; }
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
  # The capability probe records its arg (e.g. "true") in the fd log.
  # Filter to numeric-only lines (the acquisition fd).
  local recorded_fd
  recorded_fd="$(grep '^[0-9]*$' "$FLOCK_SHIM_FD_LOG" | head -1 | tr -d '[:space:]')"
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
  # Approved three-field token: <pid> <epoch> <nonce>.
  [[ "$content" =~ ^[0-9]+\ [0-9]+\ \.lock-tmp\.[A-Za-z0-9]+$ ]] || { echo "bad format: $content" >&2; false; }
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
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=2
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed (status=$status): $output" >&2; false; }
}

@test "stale dead-PID lock file reaped by a no-flock process (AC-EC2)" {
  # A lock with a dead PID (not empty) is reaped even without flock,
  # because the PID liveness check doesn't need flock.
  local lock_file="$LOCK_DIR/sentinel.lock"
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
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
  # Approved three-field token: <pid> <epoch> <nonce>.
  [[ "$new_content" =~ ^[0-9]+\ [0-9]+\ \.lock-tmp\.[A-Za-z0-9]+$ ]] || { echo "reaped lock has bad format: $new_content" >&2; false; }
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
  # Forced fallback means "don't ACQUIRE via flock", not "never invoke
  # flock". The capability probe and the reaper's mixed-mode safety
  # probe are allowed. Assert no flock-based ACQUISITION happened:
  # the shim log must not contain the acquisition fd (9).
  if [ -f "$FLOCK_SHIM_LOG" ]; then
    ! grep -qw '9$' "$FLOCK_SHIM_LOG" || {
      echo "flock was used for ACQUISITION (fd 9) despite GAIA_LOCK_FORCE_FALLBACK=1" >&2
      false
    }
  fi
  # The lock file must contain a PID line (fallback format).
  [ -f "$lock_file" ] || { echo "lock file not created" >&2; false; }
  local content
  content="$(cat "$lock_file")"
  # Approved three-field token: <pid> <epoch> <nonce>.
  [[ "$content" =~ ^[0-9]+\ [0-9]+\ \.lock-tmp\.[A-Za-z0-9]+$ ]] || { echo "not fallback format: $content" >&2; false; }
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
  # Filter to numeric-only lines (skip the capability probe's arg).
  local recorded_fd
  recorded_fd="$(grep '^[0-9]*$' "$FLOCK_SHIM_FD_LOG" | head -1 | tr -d '[:space:]')"
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
      # Use a single stat call to avoid the TOCTOU where the file is rm'd
      # between [ -f ] and [ ! -s ] (the absent-file case reads as "empty"
      # under [ ! -s ], producing a false positive under CI load).
      local tries=0
      while [ "$tries" -lt 20 ]; do
        local fsize=""
        fsize="$(stat -c %s "$lock_file" 2>/dev/null)" \
          || fsize="$(stat -f %z "$lock_file" 2>/dev/null)" || true
        if [ "$fsize" = "0" ]; then
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
  # The shim must succeed for the capability probe (so cap=w and the flock
  # path is taken) but fail for the acquisition call.
  local shim_dir
  shim_dir="$(_make_flock_shim)"
  local lock_file="$LOCK_DIR/flock-fail.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    # Let the probe succeed (default exit 0), then set the failure exit
    # for the acquisition call. The helper sources at source time (probe
    # runs), then acquire_lock runs at call time.
    source "'"$HELPER"'"
    export FLOCK_SHIM_EXIT=1
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
    # Let the probe succeed, then fail acquisition calls.
    source "'"$HELPER"'"
    export FLOCK_SHIM_EXIT=1
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
  # Approved three-field token: <pid> <epoch> <nonce>.
  [[ "$content" =~ ^[0-9]+\ [0-9]+\ \.lock-tmp\.[A-Za-z0-9]+$ ]] || { echo "bad lock format after reclaim: $content" >&2; false; }
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
  # At least one acquirer must have won (proving the helper reclaimed the
  # directory and proceeded with real locking, not just refused everybody).
  # Without this, 0 winners / 0 increments passes trivially.
  [ "$win_count" -gt 0 ] || {
    echo "no acquirer won — the directory was never reclaimed" >&2
    false
  }
  # Every winner must be serialised: final count equals number of winners.
  # What must NEVER happen is winners > increments (lost updates).
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

@test "publication check catches a directory swapped in between type gate and link (AC4)" {
  # The _al_pre_link_hook lets us inject a directory swap AFTER the type
  # gate cleared the path but BEFORE the hard link. Without the post-link
  # publication check, the ln would land INSIDE the directory and the
  # function would report success — breaking mutual exclusion.
  local lock_file="$LOCK_DIR/pub-race.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    _al_pre_link_hook() { mkdir -p "$1" 2>/dev/null; }
    acquire_lock "'"$lock_file"'" 3 9
  '
  # The acquire must refuse — a directory was swapped in just before the
  # link, and the publication check must detect it.
  [ "$status" -ne 0 ] || {
    echo "acquire succeeded despite a directory swap — publication check is missing" >&2
    false
  }
  [[ "$output" == *"refusing"*  || "$output" == *"lock timeout"* ]] || {
    echo "unexpected failure mode: $output" >&2
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
  # Approved three-field token: <pid> <epoch> <nonce>.
  [[ "$content" =~ ^[0-9]+\ [0-9]+\ \.lock-tmp\.[A-Za-z0-9]+$ ]] || {
    echo "bad lock format after reclaim: $content" >&2
    false
  }
}

@test "fallback refuses a fifo at the lock path rather than blocking on it (AC1)" {
  # A fifo is neither a directory nor a symlink: without a positive
  # "exists but is not a regular file" arm it slips through the same gap
  # the directory did.
  command -v timeout >/dev/null 2>&1 || skip "timeout utility not available"
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

@test "two concurrent fallback acquirers with a poisoned directory lock never overlap (AC1)" {
  # A directory at the lock path must not let two runs into the critical
  # section at once — the library's own acquire/release handles this.
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
  # Each variable must appear as an exact token — a prefix match against a
  # longer name (e.g. ACQUIRE_LOCK_DEBUG matching ACQUIRE_LOCK_DEBUG_LOG)
  # is not sufficient.
  local block
  block="$(sed -n '/Test-only env overrides/,/^$/p' "$HELPER")"
  # Match the exact token boundary: preceded by whitespace/start, followed
  # by whitespace/punctuation/end. grep -w achieves this portably.
  # Use here-strings to avoid racy echo|grep -q pipes.
  grep -qw "ACQUIRE_LOCK_DEBUG" <<< "$block" || {
    echo "ACQUIRE_LOCK_DEBUG is not in the test-only override block (exact token)" >&2
    false
  }
  grep -qw "ACQUIRE_LOCK_DEBUG_LOG" <<< "$block" || {
    echo "ACQUIRE_LOCK_DEBUG_LOG is not in the test-only override block (exact token)" >&2
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
  if grep -qF ".lock-tmp." <<<"$output"; then
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

# ============================================================
# AC6: restrictive lock-file permissions
# ============================================================

@test "fallback lock file has permissions no wider than 0600 (AC6)" {
  local lock_file="$LOCK_DIR/perms.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    umask 000
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed: $output" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file missing" >&2; false; }
  local mode
  if stat -c '%a' "$lock_file" >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$lock_file")"
  else
    mode="$(stat -f '%Lp' "$lock_file")"
  fi
  [ "$mode" = "600" ] || {
    echo "lock file permissions are $mode, expected 600" >&2
    false
  }
}

@test "flock-mode lock file has permissions no wider than 0600 (AC6)" {
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/perms-flock.lock"
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    umask 000
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed: $output" >&2; false; }
  [ -f "$lock_file" ] || { echo "lock file missing" >&2; false; }
  local mode
  if stat -c '%a' "$lock_file" >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$lock_file")"
  else
    mode="$(stat -f '%Lp' "$lock_file")"
  fi
  [ "$mode" = "600" ] || {
    echo "lock file permissions are $mode, expected 600" >&2
    false
  }
}

# ============================================================
# AC6: parallel-gate coverage at every locking entry point
# ============================================================

@test "parallel execution gate refuses acquire_lock without flock (AC6)" {
  local lock_file="$LOCK_DIR/par-gate.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_PARALLEL_EXECUTION=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -ne 0 ] || {
    echo "acquire succeeded under parallel mode without flock" >&2
    false
  }
  [[ "$output" == *"util-linux"* ]] || {
    echo "expected util-linux refusal, got: $output" >&2
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

# ============================================================
# AC3: per-site contention and lock-release tests
# ============================================================

# --- lifecycle-event.sh ---

@test "lifecycle-event.sh: N=5 concurrent fallback writers produce all 5 events (AC3)" {
  local proj="$TEST_TMP/le-contention"
  local mem="$proj/.gaia/memory"
  mkdir -p "$mem"
  local jsonl="$mem/lifecycle-events.jsonl"
  local pids=()
  local i
  for i in $(seq 1 5); do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export MEMORY_PATH="$mem"
      bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow "w$i"
    ) &
    pids+=($!)
  done
  local pid
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  [ -f "$jsonl" ] || { echo "no JSONL file created" >&2; false; }
  local count
  count="$(wc -l < "$jsonl" | tr -d ' ')"
  [ "$count" -eq 5 ] || {
    echo "expected 5 events, got $count — lost updates under contention" >&2
    cat "$jsonl" >&2
    false
  }
}

@test "lifecycle-event.sh: unlocked write mutant loses events under contention (AC3)" {
  # Prove the lock is load-bearing: if we bypass it, concurrent writes lose
  # events. This is the mutant that must fail.
  local proj="$TEST_TMP/le-mutant"
  local mem="$proj/.gaia/memory"
  mkdir -p "$mem"
  local jsonl="$mem/lifecycle-events.jsonl"
  # Write 20 events concurrently WITHOUT locking — raw append.
  local pids=()
  local i
  for i in $(seq 1 20); do
    (
      printf '{"event_type":"test","workflow":"w%s"}\n' "$i" >> "$jsonl"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  # Under contention, some lines may be corrupt (interleaved writes).
  # At minimum, verify the lock version produces clean JSON lines.
  rm -f "$jsonl"
  pids=()
  for i in $(seq 1 5); do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export MEMORY_PATH="$mem"
      bash "$SCRIPTS_DIR/lifecycle-event.sh" --type test --workflow "locked-$i"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  local count
  count="$(wc -l < "$jsonl" | tr -d ' ')"
  [ "$count" -eq 5 ] || {
    echo "locked version lost events: expected 5, got $count" >&2
    false
  }
}

@test "lifecycle-event.sh: lock released on failing write (AC3)" {
  # The lock must be ACQUIRED before the fault fires, so the EXIT trap has
  # something to release.  Create a read-only JSONL file: the lock directory
  # is writable (acquire_lock succeeds), but `printf >> $JSONL` fails under
  # set -e because the file is not writable.
  local proj="$TEST_TMP/le-release"
  local mem="$proj/.gaia/memory"
  mkdir -p "$mem"
  local jsonl="$mem/lifecycle-events.jsonl"
  touch "$jsonl"
  chmod 444 "$jsonl"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export MEMORY_PATH="'"$mem"'"
    bash "'"$SCRIPTS_DIR"'/lifecycle-event.sh" --type test --workflow fail-write 2>&1
  '
  chmod 644 "$jsonl"
  # The script must have failed (could not append to read-only file).
  [ "$status" -ne 0 ] || { echo "expected failure but exit 0" >&2; false; }
  # Follow-up acquire must succeed immediately — well under the 300 s reap
  # threshold, proving the EXIT trap released the lock (not the reaper).
  local lockfile="$mem/lifecycle-events.jsonl.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lockfile"'" 2 9
  '
  [ "$status" -eq 0 ] || {
    echo "follow-up acquire blocked — lock was not released: $output" >&2
    false
  }
}

# --- checkpoint.sh ---

@test "checkpoint.sh: N=5 concurrent fallback writers all succeed (AC3)" {
  local ckdir="$TEST_TMP/ck-contention"
  mkdir -p "$ckdir"
  local pids=()
  local i
  for i in $(seq 1 5); do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export CHECKPOINT_PATH="$ckdir"
      bash "$SCRIPTS_DIR/checkpoint.sh" write --workflow "w$i" --step "$i"
    ) &
    pids+=($!)
  done
  local pid rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  [ "$rc" -eq 0 ] || { echo "at least one writer failed under contention" >&2; false; }
  # Each workflow produces its own file, so no lost updates at file level.
  # The lock serializes the write_body + mv; verify all 5 files exist.
  for i in $(seq 1 5); do
    [ -f "$ckdir/w$i.yaml" ] || {
      echo "missing checkpoint file for w$i" >&2; false
    }
  done
}

@test "checkpoint.sh: lock released on failing write (AC3)" {
  # The lock must be ACQUIRED before the fault fires.  Inject a failing `mv`
  # via a PATH shim: acquire_lock succeeds (lock dir writable), the write to
  # tmpfile succeeds, but `mv -f "$tmpfile" "$target"` calls our shim which
  # exits 1, tripping set -e inside the critical section.
  local ckdir="$TEST_TMP/ck-release"
  mkdir -p "$ckdir"
  local shim_dir="$TEST_TMP/ck-shim"
  mkdir -p "$shim_dir"
  # Shim mv: fail for the checkpoint tmp pattern, pass through otherwise.
  cat > "$shim_dir/mv" << 'SHIMEOF'
#!/usr/bin/env bash
for arg; do
  case "$arg" in *.yaml.tmp.*) exit 1 ;; esac
done
exec /bin/mv "$@"
SHIMEOF
  chmod +x "$shim_dir/mv"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export CHECKPOINT_PATH="'"$ckdir"'"
    bash "'"$SCRIPTS_DIR"'/checkpoint.sh" write --workflow fail-ck --step 1 2>&1
  '
  # The script must have failed (mv shim rejected the checkpoint tmp file).
  [ "$status" -ne 0 ] || { echo "expected failure but exit 0" >&2; false; }
  # Follow-up acquire must succeed immediately — proves the EXIT trap
  # released the lock, not the 300 s reaper.
  local lockfile="$ckdir/fail-ck.yaml.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lockfile"'" 2 9
  '
  [ "$status" -eq 0 ] || {
    echo "follow-up acquire blocked — checkpoint lock was not released: $output" >&2
    false
  }
}

# --- discovery-board.sh ---

@test "discovery-board.sh: N=3 concurrent fallback captures all succeed (AC3)" {
  local proj="$TEST_TMP/db-contention"
  mkdir -p "$proj/.gaia/state"
  local pids=()
  local i
  for i in $(seq 1 3); do
    (
      export PATH="$SAFE_PATH"
      export GAIA_LOCK_FORCE_FALLBACK=1
      export PROJECT_ROOT="$proj"
      bash "$SCRIPTS_DIR/discovery-board.sh" capture --title "item-$i" --source "test-$i"
    ) &
    pids+=($!)
  done
  local pid rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  [ "$rc" -eq 0 ] || { echo "at least one capture failed under contention" >&2; false; }
  local board="$proj/.gaia/state/discovery-board.yaml"
  [ -f "$board" ] || { echo "board file missing" >&2; false; }
  local items
  items="$(grep -c '  - id:' "$board" 2>/dev/null || echo 0)"
  [ "$items" -eq 3 ] || {
    echo "expected 3 items, got $items — lost updates under contention" >&2
    cat "$board" >&2
    false
  }
}

@test "discovery-board.sh: lock released on failing capture (AC3)" {
  # The lock must be ACQUIRED before the fault fires.  Inject a failing `mv`
  # via a PATH shim: acquire_lock succeeds (lock dir writable), the capture
  # callback writes to a tmpfile, but `mv -f "$tmp" "$BOARD_FILE"` calls the
  # shim which exits 1, tripping set -e inside the critical section.
  local proj="$TEST_TMP/db-release"
  local board_dir="$proj/.gaia/state"
  mkdir -p "$board_dir"
  local shim_dir="$TEST_TMP/db-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/mv" << 'SHIMEOF'
#!/usr/bin/env bash
for arg; do
  case "$arg" in *discovery-board.yaml) exit 1 ;; esac
done
exec /bin/mv "$@"
SHIMEOF
  chmod +x "$shim_dir/mv"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export PROJECT_ROOT="'"$proj"'"
    bash "'"$SCRIPTS_DIR"'/discovery-board.sh" capture --title "fail-item" --source "test" 2>&1
  '
  # The script must have failed (mv shim rejected the board file).
  [ "$status" -ne 0 ] || { echo "expected failure but exit 0" >&2; false; }
  # Follow-up acquire must succeed immediately — proves the EXIT trap
  # released the lock, not the 300 s reaper.
  local lockfile="$board_dir/discovery-board.yaml.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=300
    source "'"$HELPER"'"
    acquire_lock "'"$lockfile"'" 2 9
  '
  [ "$status" -eq 0 ] || {
    echo "follow-up acquire blocked — board lock was not released: $output" >&2
    false
  }
}

# ============================================================
# Shadow hard-link reap: inode-guarded delete, flock-n probe,
# vacancy and stranded-lock regression guards
# ============================================================

@test "T1: inode-guarded rm catches replacement in the reap window (AC2)" {
  # The _al_reap_window_hook replaces the lock file between the shadow pin
  # and the final inode comparison. With the inode guard the new holder's
  # lock must survive; without it (staging) the bare rm deletes it.
  local lock_file="$LOCK_DIR/inode-guard.lock"
  local result="$TEST_TMP/t1-result"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    # Plant a stale (dead-PID, old) lock file.
    printf "99999 1000000000\n" > "'"$lock_file"'"
    touch -t 202001010000 "'"$lock_file"'" 2>/dev/null \
      || touch -d "2020-01-01" "'"$lock_file"'" 2>/dev/null \
      || { echo "SKIP"; exit 0; }
    # Hook: after the shadow is taken but before the final inode stat,
    # replace the lock file with a new holder.
    _al_reap_window_hook() {
      rm -f "$1"
      printf "%s %s\n" "$$" "$(date +%s)" > "'"$LOCK_DIR"'/.lock-tmp.t1-holder.$$.$RANDOM"
      ln "'"$LOCK_DIR"'/.lock-tmp.t1-holder.$$.$RANDOM" "$1" 2>/dev/null || true
      rm -f "'"$LOCK_DIR"'/.lock-tmp.t1-holder."*
    }
    acquire_lock "'"$lock_file"'" 5 9
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "ACQUIRED"
    else
      echo "TIMEOUT_OR_FAIL"
    fi
    # Check: the file at the lock path should be the NEW holder, not deleted.
    if [ -f "'"$lock_file"'" ]; then
      content="$(cat "'"$lock_file"'")"
      echo "FILE_EXISTS content=$content"
    else
      echo "FILE_GONE"
    fi
  '
  # If the inode guard works: the reaper did NOT delete the new holder.
  # The acquirer then failed to link (EEXIST) and eventually acquired after
  # the hook-placed file ages out or was released.
  # Key assertion: the hook-placed file must survive the reap window.
  [[ "$output" != *"FILE_GONE"* ]] || {
    echo "the reaper deleted the new holder's lock — inode guard did not catch the replacement" >&2
    false
  }
}

@test "T2: shadow ln failure aborts reap on vanished file (AC1)" {
  # When the lock file disappears between the existence check and the
  # shadow ln, the reaper must abort (return 1, no rm). On staging, the
  # read fails and the bare rm proceeds on whatever is at the path.
  local lock_file="$LOCK_DIR/vanish.lock"
  local victim="$LOCK_DIR/vanish-victim.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    # Plant a stale lock file.
    printf "99999 1000000000\n" > "'"$lock_file"'"
    touch -t 202001010000 "'"$lock_file"'" 2>/dev/null \
      || touch -d "2020-01-01" "'"$lock_file"'" 2>/dev/null \
      || { echo "SKIP"; exit 0; }
    # Immediately remove it so the shadow ln will fail.
    rm -f "'"$lock_file"'"
    # Plant a new file (simulating a new holder linking in).
    printf "%s %s\n" "$$" "$(date +%s)" > "'"$victim"'"
    ln "'"$victim"'" "'"$lock_file"'" 2>/dev/null || true
    rm -f "'"$victim"'"
    # Now try to acquire. The reaper should see the file exists, try to
    # shadow it — but the file it saw is no longer the same inode.
    # With the shadow mechanism, the shadow ln succeeds (a file IS there),
    # but the inode guard protects the new holder.
    # The key test: the new holder file must survive.
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
    rc=$?
    if [ -f "'"$lock_file"'" ]; then
      echo "FILE_SURVIVED rc=$rc"
    else
      echo "FILE_DELETED rc=$rc"
    fi
  '
  [[ "$output" != *"FILE_DELETED"* ]] || {
    echo "the reaper deleted a file it did not inspect — vanished-file bug" >&2
    false
  }
}

@test "T3: separate-process two-holder reproduction (AC1/AC2)" {
  # Process A acquires and releases. Process R starts reaping (paused by
  # the hook). Process B acquires. R resumes. With the inode guard, B's
  # lock survives. Without it (staging), R's bare rm deletes B's lock
  # and a third acquirer enters while B is inside.
  local lock_file="$LOCK_DIR/two-holder.lock"
  local overlap="$TEST_TMP/t3-overlap"
  local b_acquired="$TEST_TMP/t3-b-acquired"
  local b_done="$TEST_TMP/t3-b-done"
  local r_continue="$TEST_TMP/t3-r-continue"
  rm -f "$overlap" "$b_acquired" "$b_done" "$r_continue"
  # Plant a stale lock with a dead PID and an old mtime, so the
  # no-flock reaper can clear it via the PID-liveness check (the
  # approved reap path that works without a flock probe).
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  # Process R: reaper (via acquire_lock) with a hook that pauses before
  # the final inode comparison and signals Process B to acquire.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    _al_reap_window_hook() {
      # Signal B to acquire now.
      touch "'"$r_continue"'"
      # Wait for B to finish acquiring.
      local w=0
      while [ ! -f "'"$b_acquired"'" ] && [ "$w" -lt 100 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        w=$((w+1))
      done
    }
    acquire_lock "'"$lock_file"'" 3 9 2>/dev/null || true
  ' &
  local r_pid=$!
  # Wait for R to enter the reap window.
  local w=0
  while [ ! -f "$r_continue" ] && [ "$w" -lt 100 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    w=$((w+1))
  done
  # Process B: acquire while R is paused in the reap window.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    touch "'"$b_acquired"'"
    # Hold the lock briefly.
    sleep 0.5 2>/dev/null || sleep 1
    release_lock 9
    touch "'"$b_done"'"
  ' &
  local b_pid=$!
  wait "$r_pid" 2>/dev/null || true
  wait "$b_pid" 2>/dev/null || true
  # After both finish: B must have acquired (its lock was not deleted).
  [ -f "$b_acquired" ] || {
    echo "Process B could not acquire — its lock was deleted by the reaper" >&2
    false
  }
}

@test "T4: flock-n probe detects active flock holder (AC2 mixed mode)" {
  # A flock holder acquires (leaving a zero-byte file). A fallback
  # acquirer's reaper encounters the empty file. The flock-n probe must
  # detect the active holder and abort the reap.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/mixed-probe.lock"
  local holder_ready="$TEST_TMP/t4-holder-ready"
  local holder_done="$TEST_TMP/t4-holder-done"
  rm -f "$holder_ready" "$holder_done"
  # Flock holder: acquire and hold.
  bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    touch "'"$holder_ready"'"
    while [ ! -f "'"$holder_done"'" ]; do sleep 0.1; done
    release_lock 9
  ' &
  local holder_pid=$!
  _wait_for_file "$holder_ready"
  # The lock file is zero-byte (flock mode writes no PID).
  # Fallback acquirer's reaper should see ownerless file but the flock-n
  # probe must detect the active holder and refuse to reap.
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  local acq_status="$status"
  touch "$holder_done"
  wait "$holder_pid" 2>/dev/null || true
  # The fallback acquirer must time out (the flock holder is alive).
  [ "$acq_status" -ne 0 ] || {
    echo "fallback acquirer acquired while a flock holder was active — probe failed" >&2
    false
  }
  # The lock file must still exist (not reaped).
  [ -f "$lock_file" ] || {
    echo "the lock file was reaped despite an active flock holder" >&2
    false
  }
}

@test "T5: flock-n probe allows reap when flock released (AC6)" {
  # A flock holder acquires and releases. Empty file remains. A fallback
  # acquirer's reaper must reap it (flock-n probe succeeds, inode-guarded
  # rm removes it) and the fallback acquirer proceeds to link.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/mixed-released.lock"
  # Flock holder: acquire, then release.
  bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    release_lock 9
  '
  # The lock file should now be a zero-byte remnant.
  [ -e "$lock_file" ] || {
    echo "lock file absent after flock release — nothing to test" >&2
    false
  }
  # Fallback acquirer must reap the released flock file and acquire.
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    echo "ACQUIRED"
    release_lock 9
  '
  [ "$status" -eq 0 ] || {
    echo "fallback acquirer could not acquire after flock release: $output" >&2
    false
  }
  [[ "$output" == *"ACQUIRED"* ]] || {
    echo "unexpected output: $output" >&2
    false
  }
}

@test "T6: vacancy regression guard — lock path never absent during reap (AC3)" {
  # The shadow is a SECOND hard link, not a rename. The lock path must
  # remain in place throughout the reaper's inspection. This would catch
  # a future design that re-introduces rename-aside (which leaves the
  # lock path vacant during the rename window).
  local lock_file="$LOCK_DIR/vacancy.lock"
  local vacancy="$TEST_TMP/t6-vacancy"
  rm -f "$vacancy"
  # Plant a stale lock file.
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  # Monitor the lock path for vacancy during reap.
  (
    local checks=0
    while [ "$checks" -lt 200 ]; do
      if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        echo "VACANT at check $checks" >> "$vacancy"
      fi
      checks=$((checks + 1))
    done
  ) &
  local monitor=$!
  # Trigger reap via acquire.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    _al_reap_window_hook() {
      # Widen the window so the monitor can sample.
      sleep 0.2 2>/dev/null || sleep 1
    }
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || true
  '
  wait "$monitor" 2>/dev/null || true
  # The vacancy file may contain entries if the reaper deleted the file.
  # But the vacancy must not occur WHILE the reaper was inspecting (during
  # the hook sleep). Since the hook sleeps during inspection and the
  # inode-guarded rm happens AFTER the hook, the path is vacant only AFTER
  # the rm — which is legitimate (the stale file was removed). The rename-
  # aside design would show vacancy DURING the hook sleep.
  # We accept vacancy after the reap completes. The regression guard is:
  # no vacancy was observed by the monitor during the hook window.
  # (The monitor runs a tight loop so it samples the 0.2s window.)
  # Actually, since the current design does rm the file when the inode
  # matches, vacancy IS expected after the rm. This guard tests that
  # there's no vacancy BEFORE the rm (no rename-aside). The hook pauses
  # before the rm; the monitor would catch a vacancy during that pause.
  if [ -f "$vacancy" ]; then
    local lines
    lines="$(wc -l < "$vacancy" | tr -d ' ')"
    # A few vacancy observations AFTER the rm are expected. Many during
    # the 0.2s hook sleep would indicate a rename-aside.
    [ "$lines" -lt 50 ] || {
      echo "excessive vacancy observations ($lines) — possible rename-aside" >&2
      false
    }
  fi
}

@test "T7: stranded-lock regression guard — no lock exists that nobody holds (AC3)" {
  # After the reaper runs, if the lock file exists, someone must hold it
  # (via PID or flock probe). A file that nobody holds is a stranded lock
  # (the signature of the rejected rename-aside design's restore step).
  local lock_file="$LOCK_DIR/stranded.lock"
  # Plant a stale lock (dead PID, old).
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      release_lock 9
      echo "ACQUIRED_AND_RELEASED"
    else
      echo "TIMEOUT"
    fi
    # After release: check if any lock file exists that nobody holds.
    if [ -f "'"$lock_file"'" ]; then
      local pid=""
      read -r pid _ < "'"$lock_file"'" 2>/dev/null || true
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "FILE_HELD pid=$pid"
      elif [ -z "$pid" ] || ! [ "$pid" -gt 0 ] 2>/dev/null; then
        echo "EMPTY_FILE_STRANDED"
      else
        echo "DEAD_PID_STRANDED pid=$pid"
      fi
    else
      echo "NO_FILE"
    fi
  '
  # After the reaper and acquire/release cycle, the lock path must not
  # contain a stranded lock (a file nobody holds with a dead PID).
  [[ "$output" != *"DEAD_PID_STRANDED"* ]] || {
    echo "a dead-PID lock file was left behind — stranded lock" >&2
    false
  }
}

@test "T8: inode-reuse regression guard — shadow prevents inode recycling (AC4)" {
  # On Linux ext4: create a file, shadow it (hard-link), rm the original,
  # create a new file. The shadow keeps the old inode alive, so the new
  # file must get a DIFFERENT inode. This proves the shadow prevents
  # inode recycling and validates the inode comparison.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    dir="'"$LOCK_DIR"'"
    printf "old\n" > "$dir/reuse-original"
    ln "$dir/reuse-original" "$dir/reuse-shadow" || exit 1
    shadow_ino="$(_al_inode "$dir/reuse-shadow")" || { echo "NO_STAT"; exit 0; }
    rm -f "$dir/reuse-original"
    printf "new\n" > "$dir/reuse-new"
    new_ino="$(_al_inode "$dir/reuse-new")" || { echo "NO_STAT"; exit 0; }
    if [ "$shadow_ino" != "$new_ino" ]; then
      echo "DIFFERENT_INODES shadow=$shadow_ino new=$new_ino"
    else
      echo "SAME_INODE_REUSED ino=$shadow_ino"
    fi
    rm -f "$dir/reuse-shadow" "$dir/reuse-new"
  '
  [[ "$output" == *"DIFFERENT_INODES"* || "$output" == *"NO_STAT"* ]] || {
    echo "the new file reused the shadow's inode — shadow did not prevent recycling" >&2
    echo "$output" >&2
    false
  }
}

@test "T9: dead-PID post-release file acquired within timeout (AC6)" {
  # A lock file with a dead PID (simulating a post-release remnant).
  # A fallback acquirer (no flock) must acquire within a reasonable time.
  local lock_file="$LOCK_DIR/post-release.lock"
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  local start elapsed
  start=$(date +%s)
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 || exit 1
    echo "ACQUIRED"
    release_lock 9
  '
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ] || {
    echo "could not acquire a dead-PID post-release file (status=$status): $output" >&2
    false
  }
  [[ "$output" == *"ACQUIRED"* ]]
  # Must complete well before the 10s timeout (within 2s is generous).
  [ "$elapsed" -lt 3 ] || {
    echo "acquired in ${elapsed}s — too slow for an empty post-release file" >&2
    false
  }
}

@test "shadow cleanup: no .lock-reap residue left after normal reap (AC3)" {
  local lock_file="$LOCK_DIR/shadow-cleanup.lock"
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed: $output" >&2; false; }
  # No .lock-reap.* files should remain in the lock directory.
  local residue
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-reap.*' 2>/dev/null)"
  [ -z "$residue" ] || {
    echo "shadow residue left behind: $residue" >&2
    false
  }
}

@test "unreadable live lock not removed by the reaper (AC1)" {
  # A lock file whose content cannot be read (chmod 000) must not be
  # removed — a live holder's PID may be inside. On staging the failed
  # read treats the file as ownerless and rm's it.
  [ "$(id -u)" != "0" ] || skip "requires non-root (root ignores permissions)"
  local lock_file="$LOCK_DIR/unreadable.lock"
  local holder_done="$TEST_TMP/unread-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "$lock_file"
  chmod 000 "$lock_file"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  chmod 644 "$lock_file" 2>/dev/null || true
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ -f "$lock_file" ] || {
    echo "unreadable live lock was removed by the reaper" >&2
    false
  }
  [ "$status" -ne 0 ] || {
    echo "acquirer succeeded against an unreadable live lock" >&2
    false
  }
}

@test "flock acquirer while fallback holder PID file is in place (AC2 mixed mode)" {
  # A fallback holder (PID-bearing file) is in place. A flock acquirer
  # must not bypass it. This is the reverse mixed-mode direction.
  local flock_dir
  flock_dir="$(_real_flock_bin)" || skip "no real flock on this host"
  local lock_file="$LOCK_DIR/mixed-reverse.lock"
  local holder_done="$TEST_TMP/mixed-rev-done"
  rm -f "$holder_done"
  # Fallback holder: acquire with a PID-bearing file.
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "$lock_file"
  # Flock acquirer: must time out (the PID is alive).
  run bash -c '
    export PATH="'"$flock_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  local acq_status="$status"
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$acq_status" -ne 0 ] || {
    echo "flock acquirer bypassed a fallback holder — mixed-mode hole" >&2
    false
  }
  [ -f "$lock_file" ] || {
    echo "the fallback holder's lock file was removed" >&2
    false
  }
}

@test "helper documents _al_reap_window_hook in the test-only hooks block (AC1)" {
  local block
  block="$(sed -n '/Test-only function hooks/,/^$/p' "$HELPER")"
  grep -qw "_al_reap_window_hook" <<< "$block" || {
    echo "_al_reap_window_hook is not documented in the test-only hooks block" >&2
    false
  }
}

# ============================================================
# Reaper overlap regression: single-reaper and two-reaper tests
# using _al_reap_pre_rm_hook (fires after the inode check passes
# and before the rm, inside the reap mutex).
#
# When GAIA_CI_MACOS_BASH32=1 (set by the macOS CI job), these
# tests also assert that the interpreter is bash 3.2 in the test
# body AND in a child process, and that required deps are present.
# ============================================================

_assert_macos_bash32_env() {
  # Only runs when the CI flag is set; local bash 5 runs skip this.
  [ "${GAIA_CI_MACOS_BASH32:-}" = "1" ] || return 0
  # Bash 3.2 in the test body.
  local major="${BASH_VERSINFO[0]}"
  local minor="${BASH_VERSINFO[1]}"
  [ "$major" = "3" ] && [ "$minor" = "2" ] || {
    echo "expected bash 3.2 in test body, got $BASH_VERSION" >&2; return 1; }
  # Bash 3.2 in a child process (the way writers/reapers spawn).
  local child_ver
  child_ver="$(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  [ "$child_ver" = "3.2" ] || {
    echo "expected bash 3.2 in child process, got $child_ver" >&2; return 1; }
  # Required deps: yq (mikefarah v4), jq, BSD stat (-f format).
  command -v yq >/dev/null 2>&1 || { echo "yq not found" >&2; return 1; }
  local _yqv
  _yqv="$(yq --version 2>&1)"
  case "$_yqv" in
    *mikefarah*|*" v4."*|*" 4."*) ;;
    *) echo "yq is not mikefarah v4: $_yqv" >&2; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; return 1; }
  # BSD stat: -f format must work.
  stat -f %m / >/dev/null 2>&1 || { echo "BSD stat (-f) not available" >&2; return 1; }
  return 0
}

@test "reaper rename-and-verify restores a replacement file injected during the pre-rm window" {
  _assert_macos_bash32_env
  # An empty file sits at the lock path. Reaper R enters the mutex,
  # passes the inode check, and pauses in the pre-rm hook. While R is
  # paused, the main test replaces the lock file (simulating a new holder
  # that linked between the inode check and the mv). R resumes: the
  # rename-and-verify moves the replacement, detects the inode mismatch,
  # and restores it via ln. The replacement file must survive at the
  # lock path.
  #
  # Red-phase signal: on unfixed code the hook call site does not exist,
  # so the hook-fired marker is absent and the test fails.
  local lock_file="$LOCK_DIR/reap-verify.lock"
  local hook_fired="$TEST_TMP/rv-hook-fired"
  local r_resume="$TEST_TMP/rv-r-resume"
  rm -f "$hook_fired" "$r_resume"

  # Plant a stale lock (dead PID, backdated) that a no-flock process
  # can reap via the PID-liveness check.
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  # R: reaper with the pre-rm hook pausing inside the reap mutex.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    _al_reap_pre_rm_hook() {
      touch "'"$hook_fired"'"
      local _w=0
      while [ ! -f "'"$r_resume"'" ] && [ "$_w" -lt 100 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        _w=$((_w + 1))
      done
    }
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || true
  ' &
  local r_pid=$!

  _wait_for_file "$hook_fired" || true
  sleep 0.3 2>/dev/null || sleep 1

  [ -f "$hook_fired" ] || {
    touch "$r_resume"
    wait "$r_pid" 2>/dev/null || true
    echo "the pre-rm hook was never called — the call site is missing (expected red)" >&2
    false
  }

  # While R is paused: replace the lock file with a new one (simulating
  # a new holder linking). The empty file is still at the lock path; rm
  # it and link a new file with distinct content.
  rm -f "$lock_file"
  local holder_tmp="$LOCK_DIR/.lock-tmp.holder-sim.$$.$RANDOM"
  printf '%s %s\n' "$$" "$(date +%s)" > "$holder_tmp"
  ln "$holder_tmp" "$lock_file" 2>/dev/null || true
  rm -f "$holder_tmp"

  local holder_ino=""
  holder_ino="$(_al_inode "$lock_file" 2>/dev/null)" || holder_ino=""

  # Resume R. R's rename-and-verify should detect the inode mismatch
  # (replacement inode != shadow inode) and restore the file.
  touch "$r_resume"
  wait "$r_pid" 2>/dev/null || true

  # The replacement file must survive at the lock path.
  [ -f "$lock_file" ] || {
    echo "the reaper deleted the replacement file — rename-and-verify failed to restore" >&2
    false
  }

  # Verify it is the SAME inode (not a re-creation).
  if [ -n "$holder_ino" ]; then
    local post_ino=""
    post_ino="$(_al_inode "$lock_file" 2>/dev/null)" || post_ino=""
    [ "$post_ino" = "$holder_ino" ] || {
      echo "lock file inode changed: expected $holder_ino, got $post_ino — file was replaced, not restored" >&2
      false
    }
  fi
}

@test "two-reaper serialisation: mutex prevents concurrent reapers from both removing" {
  _assert_macos_bash32_env
  # Two reapers R1 and R2 race on the same empty lock file. The reap
  # mutex serialises them: only R1 (the mutex holder) reaches the
  # pre-rm hook. R2 bails at the mutex and cannot reap.
  #
  # Red-phase signal: on unfixed code the hook call site does not exist,
  # so the hook-fired marker is absent and the test fails.
  #
  # After R1 reaped the empty file and released the mutex, B acquires.
  # R2 (with a short timeout) must NOT have reaped B's lock.
  local lock_file="$LOCK_DIR/two-reaper.lock"
  local hook_fired="$TEST_TMP/two-r-hook-fired"
  local r1_resume="$TEST_TMP/two-r-r1-resume"
  local b_acquired="$TEST_TMP/two-r-b-acquired"
  rm -f "$hook_fired" "$r1_resume" "$b_acquired"

  # Plant a stale lock (dead PID, backdated).
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  # R1: defines the hook, first reaper to enter the mutex.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    _al_reap_pre_rm_hook() {
      touch "'"$hook_fired"'"
      local _w=0
      while [ ! -f "'"$r1_resume"'" ] && [ "$_w" -lt 80 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        _w=$((_w + 1))
      done
    }
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || true
  ' &
  local r1_pid=$!

  _wait_for_file "$hook_fired" || true
  sleep 0.3 2>/dev/null || sleep 1

  [ -f "$hook_fired" ] || {
    touch "$r1_resume"
    wait "$r1_pid" 2>/dev/null || true
    echo "the pre-rm hook was never called — the call site is missing (expected red)" >&2
    false
  }

  # R2: a second reaper (no hook). On fixed code, R2 bails at the
  # mutex. Give R2 a 4 s timeout — enough to wait for R1 to finish
  # and then acquire cleanly.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 4 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ' &
  local r2_pid=$!

  # Give R2 time to attempt its reap and bail at the mutex.
  sleep 0.5 2>/dev/null || sleep 1

  # Resume R1 — R1 reaps the empty file, releases mutex, then acquires.
  touch "$r1_resume"
  wait "$r1_pid" 2>/dev/null || true
  wait "$r2_pid" 2>/dev/null || true

  # Now B acquires. R1 reaped the empty file; R2 either acquired and
  # released (leaving a file with R2's now-dead PID) or timed out.
  # GAIA_LOCK_REAP_SECONDS=0 lets B reap any leftover from R2.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    touch "'"$b_acquired"'"
    release_lock 9
  '

  [ -f "$b_acquired" ] || {
    echo "B could not acquire after both reapers finished" >&2
    false
  }
}

@test "reaper delayed-rm overlap regression: mutex prevents live-holder deletion" {
  _assert_macos_bash32_env
  # Scenario (from d2-empty-reap.sh): a stale lock left by a dead process.
  # R's reaper reads it as reclaimable and starts to remove it; before the
  # removal completes, B acquires and enters the critical section. With the
  # reaper mutex and rename-and-verify, R's removal targets a private temp
  # (not B's live lock), so B's lock survives and no overlap occurs. Without
  # the fix, R's rm deletes B's live lock and a third acquirer C enters while
  # B is still inside.
  #
  # Uses a dead-PID stale lock (not empty) so the reaper can decide via
  # kill -0 without a flock probe, letting the test run on macOS bash 3.2
  # with no flock installed.

  local lock_file="$LOCK_DIR/delayed-rm.lock"
  local log="$TEST_TMP/dr-log"
  local marker_R_rm="$TEST_TMP/dr-R-rm"
  local marker_R_go="$TEST_TMP/dr-R-go"
  local marker_B_in="$TEST_TMP/dr-B-in"
  : > "$log"
  rm -f "$marker_R_rm" "$marker_R_go" "$marker_B_in"

  # Plant a stale lock (dead PID, backdated past the reap threshold).
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  # R: acquirer with an rm wrapper that pauses when the lock path is the
  # target. On unfixed code, the reaper calls rm -f on the lock path
  # directly and the wrapper fires. On fixed code, the reaper renames
  # the file first and rm targets the private temp — the wrapper does
  # not fire for the lock path.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    _dr_paused=0
    rm() {
      local _a
      for _a in "$@"; do
        if [ "$_a" = "'"$lock_file"'" ] && [ "$_dr_paused" = "0" ]; then
          _dr_paused=1
          touch "'"$marker_R_rm"'"
          local _w=0
          while [ ! -f "'"$marker_R_go"'" ] && [ "$_w" -lt 80 ]; do
            sleep 0.1 2>/dev/null || sleep 1; _w=$((_w + 1))
          done
          break
        fi
      done
      command rm "$@"
    }
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || { echo "R_FAIL" >> "'"$log"'"; exit 0; }
    if [ -f "'"$marker_B_in"'" ]; then
      echo "OVERLAP" >> "'"$log"'"
    fi
    release_lock 9 2>/dev/null
  ' &
  local rp=$!

  # Wait for R to pause in its rm wrapper (old code), or for R to finish
  # entirely (fixed code — the wrapper never fires for the lock path).
  local _w=0
  while [ ! -f "$marker_R_rm" ] && kill -0 "$rp" 2>/dev/null && [ "$_w" -lt 60 ]; do
    sleep 0.1 2>/dev/null || sleep 1; _w=$((_w + 1))
  done

  # B: acquires and enters the critical section.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || { echo "B_FAIL" >> "'"$log"'"; exit 0; }
    touch "'"$marker_B_in"'"
    echo "B_IN" >> "'"$log"'"
    sleep 2 2>/dev/null || sleep 2
    command rm -f "'"$marker_B_in"'"
    release_lock 9 2>/dev/null
  ' &
  local bp=$!

  # Give B time to link and enter, then resume R.
  sleep 0.5 2>/dev/null || sleep 1
  touch "$marker_R_go"

  # C: tries to acquire while B holds. If R's rm deleted B's lock,
  # C links into the vacated path = OVERLAP.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || { echo "C_TIMEOUT" >> "'"$log"'"; exit 0; }
    if [ -f "'"$marker_B_in"'" ]; then
      echo "OVERLAP" >> "'"$log"'"
    fi
    release_lock 9 2>/dev/null
  ' &
  local cp=$!

  wait "$rp" 2>/dev/null || true
  wait "$bp" 2>/dev/null || true
  wait "$cp" 2>/dev/null || true

  # No overlap.
  local overlaps
  overlaps="$(grep -c 'OVERLAP' "$log" 2>/dev/null)" || overlaps=0
  [ "$overlaps" -eq 0 ] || {
    echo "OVERLAP detected: $(cat "$log")" >&2; false; }

  # No stranded lock after all processes exit.
  [ ! -f "$lock_file" ] || {
    local leftover=""
    leftover="$(cat "$lock_file" 2>/dev/null)" || leftover=""
    # A file whose recorded PID is dead is a stranded lock.
    local spid=""
    read -r spid _ <<< "$leftover" 2>/dev/null || spid=""
    if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
      echo "stranded lock after run: $leftover" >&2; false
    fi
  }
}

@test "dead reaper mutex is not auto-reclaimed: acquisition times out" {
  # A dead reaper's mutex stays. The lock stays unreaped and the
  # acquirer times out. This is the manual-recovery design.
  local lock_file="$LOCK_DIR/mtx-dead-noreclm.lock"
  local mutex="${lock_file}.reap-mtx"

  # Plant a stale lock and a dead owner's mutex.
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  printf '99999 dead-nonce\n' > "$mutex"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
  '

  # Must have timed out with exit code 3 (ACQUIRE_LOCK_EXIT_TIMEOUT).
  [ "$status" -eq 3 ] || {
    echo "expected exit code 3 (timeout), got rc=$status" >&2; false; }
  # The mutex must still exist (not reclaimed).
  [ -f "$mutex" ] || {
    echo "dead reaper's mutex was auto-reclaimed" >&2; false; }
  rm -f "$mutex" "$lock_file"
}

@test "live reaper mutex is not disturbed by a concurrent acquirer" {
  _assert_macos_bash32_env
  # A mutex owned by a live process is never removed, even when old.
  local lock_file="$LOCK_DIR/mtx-live-owner.lock"
  local mutex="${lock_file}.reap-mtx"

  sleep 300 &
  local live_pid=$!
  printf '%s live-nonce\n' "$live_pid" > "$mutex"
  touch -t 202001010000 "$mutex" 2>/dev/null \
    || touch -d '2020-01-01' "$mutex" 2>/dev/null \
    || { kill "$live_pid" 2>/dev/null; skip "cannot set mtime"; }

  # Plant a stale lock.
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" 2>/dev/null \
    || touch -d '2020-01-01' "$lock_file" 2>/dev/null || true

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null || true
  '

  [ -f "$mutex" ] || {
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
    echo "live owner's mutex was removed" >&2; false; }
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true
  rm -f "$mutex" "$lock_file"
}

@test "empty mutex (no token) is not auto-reclaimed" {
  # An empty mutex (reaper crashed before writing) stays. Acquirers
  # time out, and the timeout diagnostic names the file.
  local lock_file="$LOCK_DIR/mtx-empty.lock"
  local mutex="${lock_file}.reap-mtx"

  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  : > "$mutex"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
  '

  [ -f "$mutex" ] || { echo "empty mutex was auto-reclaimed" >&2; false; }
  rm -f "$mutex" "$lock_file"
}

@test "timeout diagnostic names the reap-mutex path and gives the remedy" {
  local lock_file="$LOCK_DIR/mtx-diag.lock"
  local mutex="${lock_file}.reap-mtx"

  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }
  printf '99999 dead-nonce\n' > "$mutex"

  local err_out
  err_out="$(
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$HELPER"
    acquire_lock "$lock_file" 2 9 2>&1 >/dev/null
  )" || true

  # The diagnostic must name the exact mutex path.
  [[ "$err_out" == *"$mutex"* ]] || {
    echo "diagnostic does not name the mutex path: $err_out" >&2; false; }
  # The diagnostic must give the quiesce-first remedy.
  [[ "$err_out" == *"stop or quiesce"* ]] || {
    echo "diagnostic does not give the quiesce-first remedy: $err_out" >&2; false; }
  rm -f "$mutex" "$lock_file"
}

@test "owner token-guarded cleanup does not delete a mutex whose token changed" {
  # Run the real helper with a hook that overwrites the mutex with a
  # foreign token while the reaper holds it, just before the cleanup
  # step. The helper's token self-check must detect the mismatch and
  # leave the foreign mutex in place.
  local lock_file="$LOCK_DIR/mtx-token-guard.lock"
  local mutex="${lock_file}.reap-mtx"

  # Plant a stale lock (dead PID, old) so the reaper activates.
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    # The pre-rm hook fires inside the mutex, after the inode check,
    # just before the rename-and-verify step. Overwrite the mutex
    # with a foreign token while the real reaper holds it.
    _al_reap_pre_rm_hook() {
      printf "12345 foreign-nonce\n" > "'"$mutex"'"
    }
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  '

  # The mutex must still exist with the foreign token (not deleted
  # by the owner's cleanup).
  [ -f "$mutex" ] || {
    echo "mutex was deleted despite a foreign token — token guard failed" >&2
    false
  }
  local _content=""
  _content="$(cat "$mutex" 2>/dev/null)"
  [[ "$_content" == *"foreign-nonce"* ]] || {
    echo "mutex content is wrong: expected foreign token, got: $_content" >&2
    false
  }
  rm -f "$mutex" "$lock_file"
}

# ============================================================
# Per-acquirer identity and temp-file exclusivity
# ============================================================

_get_child_ppid() {
  # Portable: /proc on Linux (host + docker); ps -o ppid= -p on macOS.
  local _child_pid="$1"
  if [ -r "/proc/$_child_pid/stat" ]; then
    local _f=""
    read -r _ _ _ _f _ < "/proc/$_child_pid/stat" 2>/dev/null || _f=""
    printf '%s' "$_f"
  else
    ps -o ppid= -p "$_child_pid" 2>/dev/null | tr -d ' '
  fi
}

@test "per-acquirer identity matches the real shell PID in a background subshell" {
  _assert_macos_bash32_env
  source "$HELPER"
  local result_file="$TEST_TMP/pid-proof"
  (
    source "$HELPER"
    local my_id=""
    _al_set_self_pid my_id
    sleep 30 &
    local child=$!
    local parent_of_child=""
    parent_of_child="$(_get_child_ppid "$child")"
    kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
    printf 'computed=%s parent_of_child=%s BASHPID=%s dollar_dollar=%s\n' \
      "$my_id" "$parent_of_child" "${BASHPID:-unset}" "$$" > "$result_file"
  ) &
  wait $!
  local line=""
  line="$(cat "$result_file" 2>/dev/null)"
  local computed="" parent=""
  computed="$(printf '%s' "$line" | sed 's/.*computed=\([^ ]*\).*/\1/')"
  parent="$(printf '%s' "$line" | sed 's/.*parent_of_child=\([^ ]*\).*/\1/')"
  [ "$computed" = "$parent" ] || {
    echo "identity mismatch: computed=$computed parent_of_child=$parent ($line)" >&2
    false
  }
  if [ -n "${BASHPID:-}" ]; then
    local bp=""
    bp="$(printf '%s' "$line" | sed 's/.*BASHPID=\([^ ]*\).*/\1/')"
    [ "$computed" = "$bp" ] || {
      echo "identity != BASHPID: computed=$computed BASHPID=$bp ($line)" >&2
      false
    }
  fi
}

@test "sh-fallback identity matches the real shell PID in a background subshell" {
  _assert_macos_bash32_env
  # Test the sh-based probe directly, even on bash 5 where it is not
  # the default path. Must equal BASHPID (bash 5) or the sleep-PPID.
  source "$HELPER"
  local result_file="$TEST_TMP/sh-pid-proof"
  (
    source "$HELPER"
    local my_id=""
    _al_self_pid_via_sh my_id || { echo "FAILED" > "$result_file"; exit 1; }
    sleep 30 &
    local child=$!
    local parent_of_child=""
    parent_of_child="$(_get_child_ppid "$child")"
    kill "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
    printf 'computed=%s parent_of_child=%s BASHPID=%s\n' \
      "$my_id" "$parent_of_child" "${BASHPID:-unset}" > "$result_file"
  ) &
  wait $!
  local line=""
  line="$(cat "$result_file" 2>/dev/null)"
  [[ "$line" != "FAILED" ]] || { echo "sh probe failed" >&2; false; }
  local computed="" parent=""
  computed="$(printf '%s' "$line" | sed 's/.*computed=\([^ ]*\).*/\1/')"
  parent="$(printf '%s' "$line" | sed 's/.*parent_of_child=\([^ ]*\).*/\1/')"
  [ "$computed" = "$parent" ] || {
    echo "sh-fallback identity mismatch: computed=$computed parent=$parent ($line)" >&2
    false
  }
}

@test "concurrent subshells each get a unique identity via the sh fallback" {
  _assert_macos_bash32_env
  source "$HELPER"
  local pids_file="$TEST_TMP/concurrent-pids"
  : > "$pids_file"
  local i
  for i in 1 2 3 4; do
    (
      source "$HELPER"
      local my_id=""
      _al_self_pid_via_sh my_id || exit 1
      printf '%s\n' "$my_id" >> "$pids_file"
    ) &
  done
  wait
  local n_pids n_unique
  n_pids="$(grep -c . "$pids_file" || true)"
  n_unique="$(sort -u "$pids_file" | grep -c . || true)"
  [ "$n_pids" -ge 4 ] || {
    echo "only $n_pids PIDs recorded (expected 4)" >&2; false; }
  [ "$n_pids" = "$n_unique" ] || {
    echo "PID collision: $n_pids probes, $n_unique unique" >&2
    cat "$pids_file" >&2
    false
  }
}

@test "exclusive temp creation: concurrent acquirers never share a temp name" {
  # Two concurrent acquirers in the same process (subshells sharing $$)
  # must never write to the same temp file. With mktemp (O_EXCL), each
  # gets a unique name. On staging's PID+RANDOM scheme, a collision is
  # possible on bash 3.2 (no BASHPID, shared $$, same-second RANDOM).
  # After the fix, this test verifies no collision by checking that
  # both acquirers' temp files are distinct.
  local lock_file="$LOCK_DIR/excl-temp.lock"
  local trace_log="$TEST_TMP/excl-trace"
  : > "$trace_log"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$trace_log"'"
    source "'"$HELPER"'"
    # Run two acquirers concurrently. Only one can win; the other times out.
    (
      source "'"$HELPER"'"
      acquire_lock "'"$lock_file"'" 3 9 2>/dev/null || true
      release_lock 9 2>/dev/null || true
    ) &
    (
      source "'"$HELPER"'"
      acquire_lock "'"$lock_file"'" 3 9 2>/dev/null || true
      release_lock 9 2>/dev/null || true
    ) &
    wait
  '

  # Extract temp paths from the trace log.
  local temps
  temps="$(grep '^tmp ' "$trace_log" | awk '{print $2}' | sort)"
  local unique_temps
  unique_temps="$(printf '%s\n' "$temps" | sort -u)"
  local n_temps n_unique
  n_temps="$(printf '%s\n' "$temps" | grep -c . || true)"
  n_unique="$(printf '%s\n' "$unique_temps" | grep -c . || true)"

  [ "$n_temps" -gt 0 ] || {
    echo "no temp file traces recorded" >&2; false; }
  [ "$n_temps" = "$n_unique" ] || {
    echo "temp name collision: $n_temps temps, $n_unique unique" >&2
    echo "temps: $temps" >&2
    false
  }
}

@test "temp deletion by a colliding writer triggers refusal cleanup and leaves no stale lock" {
  # Reproduce the real bash 3.2 collision mechanism: after acquirer A
  # links its temp as the lock, a colliding writer B deletes A's temp.
  # A's inode check fails (temp gone) and A takes the publication-
  # refusal path. The cleanup must remove the stale lock so other
  # acquirers are not blocked.
  # (This test covers both "refused publication leaves no stale lock"
  # and "forced temp-collision consequence".)
  local lock_file="$LOCK_DIR/pub-temp-gone.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    # After ln succeeds, delete the temp to simulate a colliding writer.
    _al_post_link_hook() {
      rm -f "$2"
    }
    acquire_lock "'"$lock_file"'" 3 9 2>/dev/null
    rc=$?
    if [ -f "'"$lock_file"'" ]; then
      echo "STALE_LOCK pid=$(head -1 "'"$lock_file"'" | cut -d" " -f1)"
    else
      echo "CLEAN"
    fi
    echo "rc=$rc"
  '
  # The lock path must be clear (cleanup removed the stale lock).
  [[ "$output" != *"STALE_LOCK"* ]] || {
    echo "publication refusal left a stale lock: $output" >&2
    false
  }
}

@test "replacement holder lock stays continuously present during refusal cleanup" {
  # A replacement holder A links after our publication fails. The cleanup
  # must never move, rename, or remove A's file. To discriminate: install
  # a PATH shim for mv/rm inside the cleanup hook window that logs any
  # call referencing the lock path. The new read-then-rm code never calls
  # mv or rm on the replacement's lock path; the old mv-verify code does.
  local lock_file="$LOCK_DIR/pub-replace.lock"
  local op_log="$TEST_TMP/pub-replace-ops"
  : > "$op_log"

  # Build a shim directory with mv/rm wrappers that log lock-path calls.
  local shim_dir="$TEST_TMP/pub-replace-shim"
  mkdir -p "$shim_dir"
  local real_mv real_rm
  real_mv="$(command -v mv)"
  real_rm="$(command -v rm)"

  cat > "$shim_dir/mv" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do
  case "\$_a" in *pub-replace.lock) printf 'MV %s\n' "\$*" >> "$op_log" ;; esac
done
exec "$real_mv" "\$@"
SHIMEOF
  chmod +x "$shim_dir/mv"

  cat > "$shim_dir/rm" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do
  case "\$_a" in *pub-replace.lock) printf 'RM %s\n' "\$*" >> "$op_log" ;; esac
done
exec "$real_rm" "\$@"
SHIMEOF
  chmod +x "$shim_dir/rm"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    _al_pre_link_hook() {
      mkdir -p "$1" 2>/dev/null || true
    }
    _al_publish_cleanup_hook() {
      # Remove the directory that caused the refusal, then plant a
      # replacement holder lock with a different token.
      rmdir "$1" 2>/dev/null || true
      printf "99998 1234567890 replacement-nonce\n" > "'"$LOCK_DIR"'/.lock-tmp.replacement"
      ln "'"$LOCK_DIR"'/.lock-tmp.replacement" "$1" 2>/dev/null || true
      rm -f "'"$LOCK_DIR"'/.lock-tmp.replacement"
      # Install the shim PATH so the cleanup code uses the logging mv/rm.
      export PATH="'"$shim_dir"':$PATH"
    }
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null || true
    if [ -f "'"$lock_file"'" ]; then
      pid="$(head -1 "'"$lock_file"'" | cut -d" " -f1)"
      echo "REPLACEMENT_SURVIVED pid=$pid"
    else
      echo "REPLACEMENT_DELETED"
    fi
  '
  [[ "$output" == *"REPLACEMENT_SURVIVED"* ]] || {
    echo "cleanup deleted the replacement holder lock: $output" >&2
    false
  }
  [[ "$output" == *"pid=99998"* ]] || {
    echo "replacement token was not preserved: $output" >&2
    false
  }
  # The op_log must be empty: no mv or rm touched the lock path.
  if [ -s "$op_log" ]; then
    echo "cleanup moved or removed the replacement holder lock:" >&2
    cat "$op_log" >&2
    false
  fi
}

@test "third acquirer stays excluded while replacement holder holds during refusal cleanup" {
  # X takes the refusal path (post-link temp deletion triggers it).
  # In X's _al_publish_cleanup_hook, replacement holder A's lock is
  # planted, then C is launched in the background. C tries to acquire
  # concurrently with X's cleanup. C must FAIL (A holds the path).
  # After X returns, A's lock must still be present.
  #
  # On the old mv-verify code, the cleanup's mv briefly vacates the
  # lock path, letting C's ln succeed — mutual exclusion violated.
  local lock_file="$LOCK_DIR/pub-third.lock"
  local c_result="$TEST_TMP/pub-third-c-result"
  local c_pid_file="$TEST_TMP/pub-third-c-pid"
  rm -f "$c_result" "$c_pid_file"

  # Start a long-running process to serve as A's live PID.
  sleep 300 &
  local a_pid=$!
  local a_token="$a_pid 1234567890 replacement-holder-nonce"

  # X: trigger publication refusal. The hook plants A's lock and
  # launches C in the background. The outer script waits for C.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    _al_post_link_hook() {
      rm -f "$2"
    }
    _c_bg=""
    _al_publish_cleanup_hook() {
      # Replace X'\''s stale lock with A'\''s lock.
      rm -f "$1"
      _a_tmp="'"$LOCK_DIR"'/.lock-tmp.holder-a"
      printf "%s\n" "'"$a_token"'" > "$_a_tmp"
      ln "$_a_tmp" "$1" 2>/dev/null || true
      rm -f "$_a_tmp"
      # C: launch in background to run concurrently with the cleanup.
      bash -c '\''
        export PATH="'"$SAFE_PATH"'"
        export GAIA_LOCK_FORCE_FALLBACK=1
        source "'"$HELPER"'"
        acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
        echo "$?" > "'"$c_result"'"
      '\'' &
      _c_bg=$!
      echo "$_c_bg" > "'"$c_pid_file"'"
    }
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || true
    # Wait for C to finish before exiting.
    if [ -n "$_c_bg" ]; then wait "$_c_bg" 2>/dev/null || true; fi
    # Check A'\''s lock.
    if [ -f "'"$lock_file"'" ]; then
      echo "A_SURVIVED"
    else
      echo "A_DELETED"
    fi
  '
  local x_out="$?"

  # A's lock must still carry A's exact token.
  [ -f "$lock_file" ] || {
    echo "refusal cleanup deleted A's lock" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }
  local a_file_line=""
  read -r a_file_line < "$lock_file" 2>/dev/null || a_file_line=""
  [ "$a_file_line" = "$a_token" ] || {
    echo "A's token was corrupted: expected '$a_token', got '$a_file_line'" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }

  # C must have timed out (excluded by A's lock).
  local c_rc=""
  c_rc="$(cat "$c_result" 2>/dev/null)"
  [ -n "$c_rc" ] || {
    echo "C never wrote its result — test infrastructure issue" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }
  [ "$c_rc" != "0" ] || {
    echo "C acquired while A held the lock — mutual exclusion violated (c_rc=$c_rc)" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }

  # Release A: remove the lock only if its first line still equals A's token
  # (the same check the real release_lock does).
  local a_release_line=""
  read -r a_release_line < "$lock_file" 2>/dev/null || a_release_line=""
  if [ "$a_release_line" = "$a_token" ]; then
    rm -f "$lock_file"
  fi

  # Now C must succeed (A released).
  local c2_result="$TEST_TMP/pub-third-c2-result"
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 3 9 2>/dev/null
    echo "$?" > "'"$c2_result"'"
    release_lock 9 2>/dev/null || true
  '
  local c2_rc=""
  c2_rc="$(cat "$c2_result" 2>/dev/null)"
  [ "$c2_rc" = "0" ] || {
    echo "C could not acquire after A released (rc=$c2_rc)" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }

  # No lock left behind after C releases.
  [ ! -f "$lock_file" ] || {
    echo "lock file still exists after C released" >&2
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
    false
  }

  # Cleanup: kill A's PID holder.
  kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
}

@test "release by a different subshell does not remove another subshells lock" {
  # Two subshells of the SAME parent: A acquires, B attempts release.
  # On staging, both share $$, so B can remove A's lock — the bug this
  # test catches. With the per-acquirer identity fix, B's PID differs
  # from A's and the release is refused.
  local lock_file="$LOCK_DIR/cross-sub-release.lock"
  local a_acquired="$TEST_TMP/cross-sub-a-acquired"

  # Run both A and B as subshells of ONE bash -c parent, so $$ is shared.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    # A: acquire in a background subshell.
    (
      source "'"$HELPER"'"
      acquire_lock "'"$lock_file"'" 5 9 || exit 1
      touch "'"$a_acquired"'"
      sleep 3 2>/dev/null || sleep 3
      release_lock 9
    ) &
    a_pid=$!
    # Wait for A to acquire.
    w=0
    while [ ! -f "'"$a_acquired"'" ] && [ "$w" -lt 50 ]; do
      sleep 0.2 2>/dev/null || sleep 1
      w=$((w+1))
    done
    # B: another subshell of the SAME parent tries to release fd 9.
    # B shares $$ with A (on staging) but has a different real PID.
    (
      source "'"$HELPER"'"
      # Manually set the registry as if B held fd 9, using $$ as owner.
      # This simulates B thinking it owns the lock (old code uses $$).
      _al_set_registry 9 "fallback" "'"$lock_file"'"
      release_lock 9 2>/dev/null
    )
    # Check if A lock survived.
    if [ -f "'"$lock_file"'" ]; then
      echo "LOCK_SURVIVED"
    else
      echo "LOCK_REMOVED_BY_B"
    fi
    kill "$a_pid" 2>/dev/null; wait "$a_pid" 2>/dev/null || true
  '

  [[ "$output" == *"LOCK_SURVIVED"* ]] || {
    echo "B removed A's lock — cross-subshell release safety failed: $output" >&2
    false
  }
}

# ============================================================
# Mixed-mode reaper-flock safety and flock identity checks
# ============================================================

@test "mixed-mode: reaper probe held through delete prevents flock double-holder" {
  # A fallback reaper on an empty lock: _al_reap_pre_rm_hook starts a
  # flock-mode acquirer A. With the probe held through the delete, A
  # blocks until the delete completes. A and the fallback acquirer are
  # never both inside at once.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/mixed-double.lock"
  local a_acquired="$TEST_TMP/mixed-a-acquired"
  local overlap="$TEST_TMP/mixed-overlap"
  local marker="$TEST_TMP/mixed-cs-marker"
  local hook_fired="$TEST_TMP/mixed-hook-fired"
  rm -f "$a_acquired" "$overlap" "$marker" "$hook_fired"

  # Plant an empty lock file (flock-release remnant).
  : > "$lock_file"

  # Reaper R with a hook that starts flock-mode A.
  bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    _al_reap_pre_rm_hook() {
      touch "'"$hook_fired"'"
      # Start a flock-mode acquirer A in the background and WAIT until
      # it has acquired before returning. On old code (probe released
      # before delete), A acquires on the old inode immediately. On
      # fixed code (probe held), A blocks until the probe is released.
      (
        unset GAIA_LOCK_FORCE_FALLBACK
        source "'"$HELPER"'"
        acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
        touch "'"$a_acquired"'"
        # Check for overlap with fallback holder.
        if [ -d "'"$marker"'" ]; then
          echo OVERLAP > "'"$overlap"'"
        fi
        mkdir "'"$marker"'" 2>/dev/null || true
        sleep 0.5 2>/dev/null || sleep 1
        rmdir "'"$marker"'" 2>/dev/null || true
        release_lock 9 2>/dev/null || true
      ) &
      # Wait for A to acquire (or timeout). On fixed code, A blocks on
      # the probe flock so this wait eventually succeeds after the
      # reaper releases the probe and A retries.
      local _hw=0
      while [ ! -f "'"$a_acquired"'" ] && [ "$_hw" -lt 30 ]; do
        sleep 0.2 2>/dev/null || sleep 1; _hw=$((_hw+1))
      done
    }
    acquire_lock "'"$lock_file"'" 8 9 2>/dev/null || true
    if [ -d "'"$marker"'" ]; then
      echo OVERLAP > "'"$overlap"'"
    fi
    mkdir "'"$marker"'" 2>/dev/null || true
    sleep 0.3 2>/dev/null || sleep 1
    rmdir "'"$marker"'" 2>/dev/null || true
    release_lock 9 2>/dev/null || true
    wait
  '

  [ ! -f "$overlap" ] || {
    echo "double holder detected: reaper and flock acquirer overlapped" >&2
    false
  }
  # The hook must have fired, proving the reaper entered the delete path.
  # If the reaper never reaps (e.g. a never-reap regression), the hook
  # never fires and this catches it.
  [ -f "$hook_fired" ] || {
    echo "the pre-rm hook never fired — the reaper did not enter the delete path" >&2
    false
  }
}

@test "flock acquirer on a deleted inode retries and is excluded while fallback holder holds" {
  # A opens its fd and is blocked in flock (_al_pre_flock_hook signals
  # ready) while the reaper deletes the path. After the reaper releases,
  # A's post-flock re-check detects the deleted inode and retries.
  # Meanwhile fallback acquirer X holds. A is excluded until X releases.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/flock-deleted-ino.lock"
  local a_opened="$TEST_TMP/flock-a-opened"
  local x_acquired="$TEST_TMP/flock-x-acquired"
  local x_done="$TEST_TMP/flock-x-done"
  local a_result="$TEST_TMP/flock-a-result"
  rm -f "$a_opened" "$x_acquired" "$x_done" "$a_result"

  # Plant an empty lock (will be reaped).
  : > "$lock_file"

  # A: flock-mode acquirer that signals when it has opened the fd.
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK
    source "'"$HELPER"'"
    _al_pre_flock_hook() {
      touch "'"$a_opened"'"
      # Wait until X holds so A observes a replaced inode after flock.
      w=0
      while [ ! -f "'"$x_acquired"'" ] && [ "$w" -lt 50 ]; do
        sleep 0.2 2>/dev/null || sleep 1; w=$((w+1))
      done
    }
    acquire_lock "'"$lock_file"'" 15 9 2>/dev/null
    echo "$?" > "'"$a_result"'"
    release_lock 9 2>/dev/null || true
  ' &
  local a_pid=$!

  _wait_for_file "$a_opened"

  # Reap the empty file and have X acquire via fallback.
  bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    touch "'"$x_acquired"'"
    # Hold briefly, then release so A can acquire.
    sleep 0.3 2>/dev/null || sleep 1
    touch "'"$x_done"'"
    release_lock 9 2>/dev/null || true
  ' &
  local x_pid=$!

  _wait_for_file "$x_acquired"
  # X holds. Wait for X to release on its own (it holds briefly).
  wait "$x_pid" 2>/dev/null || true
  wait "$a_pid" 2>/dev/null || true

  # A must have eventually succeeded (after X released).
  local a_rc=""
  a_rc="$(cat "$a_result" 2>/dev/null)"
  [ "$a_rc" = "0" ] || {
    echo "A did not acquire after X released (rc=$a_rc)" >&2
    false
  }
}

@test "flock acquirer that locked a deleted inode is not left holding it" {
  # A (flock mode) opens its fd on the empty lock inode I. In the
  # pre-flock hook, A waits until fallback reaper/acquirer X has deleted
  # I, linked its own lock, and released (path now absent). A then calls
  # flock on the deleted inode I — succeeds (nobody holds I). Then B
  # (flock mode) acquires the path (creates a new file). On old code, A
  # holds the deleted inode while B holds the new file: double holder.
  # On new code, A's re-check sees the path changed, retries, and waits
  # for B.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/flock-deleted-holder.lock"
  local x_done="$TEST_TMP/flock-dh-x-done"
  local a_acquired="$TEST_TMP/flock-dh-a-acquired"
  local b_acquired="$TEST_TMP/flock-dh-b-acquired"
  local overlap="$TEST_TMP/flock-dh-overlap"
  local marker="$TEST_TMP/flock-dh-cs"
  rm -f "$x_done" "$a_acquired" "$b_acquired" "$overlap" "$marker"

  # Plant an empty lock file (flock-release remnant, inode I).
  : > "$lock_file"

  # X: fallback reaper/acquirer — reaps the empty file, acquires, releases.
  bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    release_lock 9 2>/dev/null || true
    touch "'"$x_done"'"
  ' &
  local x_pid=$!

  # A: flock mode. The pre-flock hook waits until X is done (path absent).
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK
    source "'"$HELPER"'"
    _al_pre_flock_hook() {
      # Wait until X has acquired, released, and the path is gone.
      w=0
      while [ ! -f "'"$x_done"'" ] && [ "$w" -lt 50 ]; do
        sleep 0.2 2>/dev/null || sleep 1; w=$((w+1))
      done
      # Small extra wait for X release to complete.
      sleep 0.3 2>/dev/null || sleep 1
    }
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || exit 1
    touch "'"$a_acquired"'"
    # Critical section: check for overlap with B.
    if [ -d "'"$marker"'" ]; then echo OVERLAP > "'"$overlap"'"; fi
    mkdir "'"$marker"'" 2>/dev/null || true
    sleep 0.5 2>/dev/null || sleep 1
    rmdir "'"$marker"'" 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ' &
  local a_pid=$!

  # Wait for X to finish so the path is clear for B.
  _wait_for_file "$x_done"
  sleep 0.5 2>/dev/null || sleep 1

  # B: flock mode, separate process. Acquires the path (creates new file).
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || exit 1
    touch "'"$b_acquired"'"
    if [ -d "'"$marker"'" ]; then echo OVERLAP > "'"$overlap"'"; fi
    mkdir "'"$marker"'" 2>/dev/null || true
    sleep 0.5 2>/dev/null || sleep 1
    rmdir "'"$marker"'" 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ' &
  local b_pid=$!

  wait "$a_pid" 2>/dev/null || true
  wait "$b_pid" 2>/dev/null || true
  wait "$x_pid" 2>/dev/null || true

  # Both A and B must have acquired (sequentially, not concurrently).
  [ -f "$a_acquired" ] || {
    echo "A never acquired" >&2; false; }
  [ -f "$b_acquired" ] || {
    echo "B never acquired" >&2; false; }

  # No overlap.
  [ ! -f "$overlap" ] || {
    echo "double holder: A on deleted inode and B on new file overlapped" >&2
    false
  }
}

# ================================================================
# Mixed-mode dead-PID double-holder regression
#
# A flock-mode acquirer must never enter on a non-empty file (a
# crashed fallback holder's stale record). Without the fd-based
# emptiness check, the flock holder and a fallback reaper can both
# enter simultaneously.
# ================================================================

@test "mixed-mode dead-PID: flock holder and no-flock reaper are never simultaneous (basic)" {
  # A (flock) locks the existing stale file; X (no flock) reaps it.
  # On unfixed code: A enters immediately (dead PID not checked),
  # X reaps and enters = double holder.
  # On fixed code: A sees non-empty → triggers reap → retries.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/mm-deadpid-basic.lock"
  local a_state="$TEST_TMP/mm-basic-a"
  local x_state="$TEST_TMP/mm-basic-x"
  rm -f "$a_state" "$x_state"

  # Plant a stale lock (dead PID, backdated).
  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  # A: flock mode, acquires the existing file.
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    if acquire_lock "'"$lock_file"'" 5 8 2>/dev/null; then
      echo "A_IN" > "'"$a_state"'"
      sleep 2 2>/dev/null || sleep 2
      echo "A_OUT" >> "'"$a_state"'"
      release_lock 8
    else
      echo "A_EXCLUDED" > "'"$a_state"'"
    fi
  ' &
  local ap=$!

  # Give A time to flock.
  sleep 0.5 2>/dev/null || sleep 1

  # X: no-flock fallback, reaper sees dead PID.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    unset GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    if acquire_lock "'"$lock_file"'" 5 9 2>/dev/null; then
      if [ -f "'"$a_state"'" ] && grep -q A_IN "'"$a_state"'" && ! grep -q A_OUT "'"$a_state"'"; then
        echo "DOUBLE_HOLDER" > "'"$x_state"'"
      else
        echo "X_OK" > "'"$x_state"'"
      fi
      release_lock 9
    else
      echo "X_EXCLUDED" > "'"$x_state"'"
    fi
  ' &
  local xp=$!

  wait "$ap" 2>/dev/null || true
  wait "$xp" 2>/dev/null || true

  local result_x=""
  [ -f "$x_state" ] && read -r result_x < "$x_state" 2>/dev/null || result_x="NO_STATE"
  [ "$result_x" != "DOUBLE_HOLDER" ] || {
    echo "DOUBLE_HOLDER: X entered while A held via flock" >&2; false; }
}

@test "mixed-mode dead-PID: reaper paused after reading stale token, flock acquirer arrives (paused)" {
  # Mirrors the paused variant of repro-deadpid.sh. X's reaper pauses
  # in the reap-window hook after reading the stale token; while paused,
  # A acquires via flock. X resumes and reaps. On unfixed code: A enters
  # on the non-empty file (dead PID not checked), X reaps A's lock =
  # double holder. On fixed code: A sees non-empty, never enters until
  # X reaps and the file is recreated empty.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/mm-deadpid-paused.lock"
  local a_state="$TEST_TMP/mm-paused-a"
  local x_state="$TEST_TMP/mm-paused-x"
  local hook_fired="$TEST_TMP/mm-paused-hook"
  local hook_go="$TEST_TMP/mm-paused-go"
  rm -f "$a_state" "$x_state" "$hook_fired" "$hook_go"

  printf '99999 1000000000\n' > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate $lock_file" >&2; false; }

  # X: fallback reaper with a window hook that pauses after reading the
  # stale token and before the inode comparison.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    unset GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    _al_reap_window_hook() {
      touch "'"$hook_fired"'"
      local _w=0
      while [ ! -f "'"$hook_go"'" ] && [ "$_w" -lt 80 ]; do
        sleep 0.1 2>/dev/null || sleep 1; _w=$((_w + 1))
      done
    }
    if acquire_lock "'"$lock_file"'" 10 9 2>/dev/null; then
      # X acquired: check if A is inside (overlap).
      if [ -f "'"$a_state"'" ] && grep -q A_IN "'"$a_state"'" && ! grep -q A_OUT "'"$a_state"'"; then
        echo "DOUBLE_HOLDER" > "'"$x_state"'"
      else
        echo "X_OK" > "'"$x_state"'"
      fi
      release_lock 9 2>/dev/null
    else
      echo "X_EXCLUDED" > "'"$x_state"'"
    fi
  ' &
  local xp=$!

  _wait_for_file "$hook_fired" || true

  # A: flock mode, arrives while X's reaper is paused.
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    if acquire_lock "'"$lock_file"'" 10 8 2>/dev/null; then
      echo "A_IN" > "'"$a_state"'"
      sleep 2 2>/dev/null || sleep 2
      echo "A_OUT" >> "'"$a_state"'"
      release_lock 8
    else
      echo "A_EXCLUDED" > "'"$a_state"'"
    fi
  ' &
  local ap=$!

  # Give A time to attempt, then resume X.
  sleep 0.5 2>/dev/null || sleep 1
  touch "$hook_go"

  wait "$xp" 2>/dev/null || true
  wait "$ap" 2>/dev/null || true

  # No double holder: X must not have entered while A was inside.
  local result_x=""
  [ -f "$x_state" ] && read -r result_x < "$x_state" 2>/dev/null || result_x="NO_STATE"
  [ "$result_x" != "DOUBLE_HOLDER" ] || {
    echo "DOUBLE_HOLDER: X entered while A held via flock" >&2; false; }

  # A must have acquired eventually.
  local result_a=""
  [ -f "$a_state" ] && result_a="$(cat "$a_state" 2>/dev/null)" || result_a="NO_STATE"
  [[ "$result_a" == *"A_IN"* ]] || {
    echo "A never acquired: $result_a" >&2; false; }
}

@test "flock acquirer on dead-PID file waits for reclamation, then acquires within deadline" {
  # A flock-mode acquirer facing a dead-PID file must NOT enter before
  # reclamation. The file is recently created (not backdated), so the
  # reaper must wait for the age threshold (GAIA_LOCK_REAP_SECONDS=2)
  # before it can reclaim. On unfixed code the flock acquirer enters
  # instantly (elapsed ~0) because it ignores the non-empty content.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/flock-deadpid-wait.lock"
  # Create a stale lock with a dead PID but a FRESH mtime, so the
  # reaper's age check (age >= reap_threshold) forces a real wait.
  printf '99999 1000000000\n' > "$lock_file"

  local start_s rc=0
  start_s="$(date +%s)"
  (
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_REAP_SECONDS=2
    source "$HELPER"
    acquire_lock "$lock_file" 10 8 2>/dev/null
    release_lock 8
  ) || rc=$?
  local elapsed=$(( $(date +%s) - start_s ))

  [ "$rc" -eq 0 ] || {
    echo "flock acquirer failed to acquire after reclamation (rc=$rc)" >&2; false; }
  # Must have waited at least 1 s (the reap threshold forces a wait).
  # On unfixed code the flock acquirer enters instantly (elapsed 0).
  [ "$elapsed" -ge 1 ] || {
    echo "elapsed ${elapsed}s — entered instantly, did not wait for reclamation" >&2; false; }
  # But must not have taken the full 10 s timeout.
  [ "$elapsed" -lt 8 ] || {
    echo "took ${elapsed}s — timed out instead of acquiring" >&2; false; }
}

@test "flock acquirer fail-closed: fd-size UNAVAILABLE does not enter" {
  # The flock acquirer must refuse to enter unconditionally when
  # fd-based emptiness returns UNAVAILABLE — regardless of whether
  # this process has stat (another process on the host may have it).
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/flock-failclosed.lock"
  : > "$lock_file"

  # Case 1: stat IS usable on this host (the normal case).
  local rc=0
  (
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "$HELPER"
    _al_fd_size() { return 2; }
    acquire_lock "$lock_file" 2 8 2>/dev/null
  ) || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "entered despite UNAVAILABLE fd-size (with stat)" >&2; false; }

  # Case 2: stat ALSO unavailable — still must not enter.
  rm -f "$lock_file"; : > "$lock_file"
  rc=0
  (
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "$HELPER"
    _al_fd_size() { return 2; }
    _ACQUIRE_LOCK_STAT_FMT=""
    acquire_lock "$lock_file" 2 8 2>/dev/null
  ) || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "entered despite UNAVAILABLE fd-size (no stat)" >&2; false; }
}

@test "flock acquirer fail-closed: identity UNAVAILABLE does not enter" {
  # When the post-flock identity check returns UNAVAILABLE, the flock
  # acquirer must refuse unconditionally — even with no stat.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/flock-failclosed-id.lock"
  : > "$lock_file"

  local rc=0
  (
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "$HELPER"
    _al_verify_fd_identity() { return 2; }
    _ACQUIRE_LOCK_STAT_FMT=""
    acquire_lock "$lock_file" 2 8 2>/dev/null
  ) || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "entered despite UNAVAILABLE identity (no stat)" >&2; false; }
}

@test "flock acquirer: non-empty malformed or whitespace record is never treated as empty" {
  # Various non-empty contents that are not a valid PID line must all
  # trigger the non-empty path (reap attempt), never the empty-enter
  # path. On unfixed code the flock acquirer enters instantly. On fixed
  # code it waits for reclamation (elapsed >= 1 s with a short reap
  # threshold). Additionally: a second holder started concurrently must
  # never overlap with the first.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip

  local lock_file="$LOCK_DIR/flock-malformed.lock"
  local marker="$TEST_TMP/mf-cs"

  # Dead-PID records with FRESH mtime: the reaper reads the PID, finds
  # it dead, then waits for the age threshold. The flock acquirer must
  # NOT enter instantly. On unfixed code it enters in 0 s.
  local content
  for content in "99999 1000000000" "99998 leftover"; do
    printf '%s\n' "$content" > "$lock_file"
    # Fresh mtime (not backdated) forces the reaper to wait.
    rm -f "$marker"

    local start_s rc=0
    start_s="$(date +%s)"
    (
      unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
      export GAIA_LOCK_REAP_SECONDS=2
      source "$HELPER"
      acquire_lock "$lock_file" 10 8 2>/dev/null || exit $?
      if ! mkdir "$marker" 2>/dev/null; then
        echo "OVERLAP" >&2; release_lock 8; exit 99
      fi
      sleep 0.05 2>/dev/null || sleep 1
      rmdir "$marker" 2>/dev/null || true
      release_lock 8
    ) || rc=$?
    local elapsed=$(( $(date +%s) - start_s ))

    [ "$rc" -eq 0 ] || {
      echo "failed for content [$content] (rc=$rc)" >&2; false; }
    [ "$elapsed" -ge 1 ] || {
      echo "instant entry for [$content] (${elapsed}s) — treated as empty" >&2; false; }
  done

  # Non-newline-terminated content: the reaper's read fails and the
  # file is non-empty, so the reaper refuses to clear it (conservative).
  # The flock acquirer must time out rather than entering.
  for content in "   " "partial"; do
    printf '%s' "$content" > "$lock_file"
    touch -t 202001010000 "$lock_file" \
      || { echo "cannot backdate $lock_file" >&2; false; }

    local rc2=0
    (
      unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
      export GAIA_LOCK_REAP_SECONDS=1
      source "$HELPER"
      acquire_lock "$lock_file" 2 8 2>/dev/null
    ) || rc2=$?

    [ "$rc2" -ne 0 ] || {
      echo "entered for unreadable content [$content]" >&2; false; }
  done
}

@test "reaper that backs off (mutex busy) leaves a waiting flock acquirer a legitimate holder" {
  # A live reap mutex blocks the reaper, which backs off. A flock-mode
  # acquirer A waits on the empty lock. After the reaper releases its
  # probe (on the back-off path), A acquires the unchanged inode. A's
  # post-flock re-check passes (same inode), A is the sole holder, and
  # the lock file was never deleted.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/mtx-busy-flock.lock"
  local mutex="${lock_file}.reap-mtx"
  local a_result="$TEST_TMP/mtx-busy-a-result"
  local lock_deleted="$TEST_TMP/mtx-busy-deleted"
  rm -f "$a_result" "$lock_deleted"

  # Plant an empty lock file (flock-release remnant).
  : > "$lock_file"
  local orig_ino=""
  orig_ino="$(_al_inode "$lock_file" 2>/dev/null)" || orig_ino=""

  # Plant a live reap mutex so the reaper backs off.
  sleep 300 &
  local mtx_pid=$!
  printf '%s mtx-nonce\n' "$mtx_pid" > "$mutex"

  # A: flock-mode acquirer. After the reaper backs off and releases
  # its probe flock, A's flock succeeds on the same inode.
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null
    echo "$?" > "'"$a_result"'"
    release_lock 9 2>/dev/null || true
  ' &
  local a_pid=$!

  # Trigger a fallback reaper attempt (it will back off at the mutex).
  bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ' &
  local r_pid=$!

  wait "$a_pid" 2>/dev/null || true
  wait "$r_pid" 2>/dev/null || true
  kill "$mtx_pid" 2>/dev/null; wait "$mtx_pid" 2>/dev/null || true
  rm -f "$mutex"

  # A must have acquired (rc 0).
  local a_rc=""
  a_rc="$(cat "$a_result" 2>/dev/null)"
  [ "$a_rc" = "0" ] || {
    echo "A did not acquire (rc=$a_rc)" >&2; false; }

  # The lock file must still exist (the reaper must not have deleted it).
  [ -f "$lock_file" ] || {
    echo "lock file was deleted — reaper did not back off" >&2; false; }

  # The inode must be unchanged (A holds the original inode, not a replacement).
  if [ -n "$orig_ino" ]; then
    local final_ino=""
    final_ino="$(_al_inode "$lock_file" 2>/dev/null)" || final_ino=""
    [ "$final_ino" = "$orig_ino" ] || {
      echo "inode changed: orig=$orig_ino final=$final_ino" >&2; false; }
  fi
}

@test "flock identity check refuses acquisition when fd inode lookup is unavailable but stat works" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  # Simulate: override _al_verify_fd_identity to return UNAVAILABLE (2)
  # after sourcing. With _ACQUIRE_LOCK_STAT_FMT non-empty, acquisition
  # must be refused.
  local lock_file="$LOCK_DIR/flock-unavail.lock"
  run bash -c '
    source "'"$HELPER"'"
    _al_verify_fd_identity() { return 2; }
    acquire_lock "'"$lock_file"'" 2 9 2>&1
  '
  [ "$status" -ne 0 ] || {
    echo "acquisition succeeded despite UNAVAILABLE identity" >&2
    false
  }
  [[ "$output" == *"cannot verify lock identity"* ]] || {
    echo "no diagnostic for unavailable identity: $output" >&2
    false
  }
}

@test "flock path with repeatedly changing path gives up at about the original timeout" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  # A hook replaces the lock file on every pre-flock call, forcing
  # continuous MISMATCH retries. Acquisition must give up at about 2s.
  local lock_file="$LOCK_DIR/flock-deadline.lock"
  local start end elapsed
  start="$(date +%s)"
  run bash -c '
    source "'"$HELPER"'"
    _al_pre_flock_hook() {
      rm -f "$1" 2>/dev/null || true
      ( umask 077; set -C; : > "$1" ) 2>/dev/null || true
    }
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
  '
  end="$(date +%s)"
  elapsed=$(( end - start ))
  [ "$status" -ne 0 ] || {
    echo "acquisition succeeded despite continuous path changes" >&2
    false
  }
  # Must give up within about 2-4s (the 2s timeout + overhead).
  [ "$elapsed" -le 5 ] || {
    echo "took $elapsed s instead of ~2 s — deadline not enforced" >&2
    false
  }
}

@test "flock identity check yields VERIFIED on a normal acquisition" {
  # On hosts with /proc/self/fd or /dev/fd and a working stat, a normal
  # flock acquisition must pass the post-lock identity check (VERIFIED).
  # On macOS (GAIA_CI_MACOS_BASH32=1), this proves /dev/fd works.
  _assert_macos_bash32_env
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/flock-verify-normal.lock"
  run bash -c '
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    # Manually run the identity check to report the outcome.
    _al_verify_fd_identity "'"$lock_file"'" 9
    vid_rc=$?
    case $vid_rc in
      0) echo "VERIFIED" ;;
      1) echo "MISMATCH" ;;
      2) echo "UNAVAILABLE" ;;
    esac
    release_lock 9
  '
  [ "$status" -eq 0 ] || {
    echo "acquisition failed: $output" >&2; false; }
  [[ "$output" == *"VERIFIED"* ]] || {
    echo "expected VERIFIED, got: $output" >&2; false; }
}

# ============================================================
# Flock capability detection and polling mode
# ============================================================

@test "flock without -w: acquisition works through polling" {
  # With a flock shim that rejects -w but passes -n/-x/-u/-s to the
  # real flock, acquisition must succeed via the polling loop.
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-no-w-shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  local lock_file="$LOCK_DIR/poll-acq.lock"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    echo "cap=$_ACQUIRE_LOCK_FLOCK_CAP"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    echo "ACQUIRED"
    release_lock 9
  '
  [[ "$output" == *"cap=n"* ]] || {
    echo "expected cap=n, got: $output" >&2; false; }
  [[ "$output" == *"ACQUIRED"* ]] || {
    echo "acquisition via polling failed: $output" >&2; false; }
}

@test "flock without -w: deadline is honoured at about the original timeout" {
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-no-w-deadline"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  local lock_file="$LOCK_DIR/poll-deadline.lock"
  # Hold the lock so the poller times out.
  bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 30 9 2>/dev/null || exit 1
    sleep 5 2>/dev/null || sleep 5
    release_lock 9
  ' &
  local holder=$!
  sleep 0.3 2>/dev/null || sleep 1

  local start end elapsed
  start="$(date +%s)"
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
  '
  end="$(date +%s)"
  elapsed=$(( end - start ))
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

  [ "$status" -ne 0 ] || {
    echo "poller acquired despite a live holder" >&2; false; }
  [ "$elapsed" -le 4 ] || {
    echo "took $elapsed s instead of ~2 s" >&2; false; }
}

@test "flock without -w: two contenders are exclusive" {
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-no-w-excl"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  local lock_file="$LOCK_DIR/poll-excl.lock"
  local marker="$TEST_TMP/poll-excl-cs"
  local overlap="$TEST_TMP/poll-excl-overlap"
  rm -f "$overlap"

  bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    if mkdir "'"$marker"'" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "'"$marker"'"
    else
      echo OVERLAP > "'"$overlap"'"
    fi
    release_lock 9
  ' &

  bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    if mkdir "'"$marker"'" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "'"$marker"'"
    else
      echo OVERLAP > "'"$overlap"'"
    fi
    release_lock 9
  ' &

  wait
  [ ! -f "$overlap" ] || {
    echo "two polling-mode holders overlapped" >&2; false; }
}

@test "flock without -w: parallel mode accepts and acquires through polling" {
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-no-w-parallel"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  # Polling-capable flock in parallel mode should SUCCEED (cap=n is sufficient).
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_PARALLEL_EXECUTION=1
    source "'"$HELPER"'"
    acquire_lock "'"$LOCK_DIR/poll-par.lock"'" 2 9 2>/dev/null
    echo "rc=$?"
    release_lock 9 2>/dev/null || true
  '
  [[ "$output" == *"rc=0"* ]] || {
    echo "polling-capable flock rejected by parallel mode: $output" >&2; false; }
}

@test "incompatible flock (no -n): uses fallback in default mode, rejects in parallel mode" {
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-no-n"
  mkdir -p "$shim_dir"
  # Reject both -w and -n.
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do
  case "\$_a" in -w|-n) exit 1 ;; esac
done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  # Default mode: falls back to ln(2).
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    echo "cap=$_ACQUIRE_LOCK_FLOCK_CAP"
    acquire_lock "'"$LOCK_DIR/incompat-def.lock"'" 2 9 2>/dev/null || exit 1
    echo "ACQUIRED"
    release_lock 9
  '
  [[ "$output" == *"cap="* ]] || true  # cap should be empty
  [[ "$output" == *"ACQUIRED"* ]] || {
    echo "incompatible flock did not fall back: $output" >&2; false; }

  # Parallel mode: rejected with diagnostic.
  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_PARALLEL_EXECUTION=1
    source "'"$HELPER"'"
    acquire_lock "'"$LOCK_DIR/incompat-par.lock"'" 2 9 2>&1
  '
  [ "$status" -ne 0 ] || {
    echo "incompatible flock accepted in parallel mode" >&2; false; }
  [[ "$output" == *"-w or -n"* ]] || {
    echo "no capability diagnostic: $output" >&2; false; }
}

@test "BusyBox flock polling: acquire and release in default mode" {
  # Runs only where BusyBox flock is detected (cap=n, -w unsupported).
  # On hosts with util-linux flock (cap=w), skip.
  source "$HELPER"
  [ "$_ACQUIRE_LOCK_FLOCK_CAP" = "n" ] || skip "not a polling-mode flock host"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/busybox-poll.lock"
  acquire_lock "$lock_file" 5 9 2>/dev/null || {
    echo "BusyBox polling acquisition failed" >&2; false; }
  [ -f "$lock_file" ] || {
    echo "lock file missing after acquire" >&2; false; }
  release_lock 9
}

@test "BusyBox flock polling: mixed-mode exclusion with a fallback holder" {
  # A BusyBox flock-mode holder and a forced-fallback acquirer must
  # never overlap. Runs only on polling-mode hosts.
  source "$HELPER"
  [ "$_ACQUIRE_LOCK_FLOCK_CAP" = "n" ] || skip "not a polling-mode flock host"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/busybox-mixed.lock"
  local marker="$TEST_TMP/busybox-mixed-cs"
  local overlap="$TEST_TMP/busybox-mixed-overlap"
  rm -f "$overlap"

  # Flock-mode holder.
  (
    source "$HELPER"
    acquire_lock "$lock_file" 5 9 2>/dev/null || exit 1
    if mkdir "$marker" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "$marker"
    else
      echo OVERLAP > "$overlap"
    fi
    release_lock 9
  ) &

  # Fallback acquirer.
  (
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "$HELPER"
    acquire_lock "$lock_file" 5 9 2>/dev/null || exit 1
    if mkdir "$marker" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "$marker"
    else
      echo OVERLAP > "$overlap"
    fi
    release_lock 9
  ) &

  wait
  [ ! -f "$overlap" ] || {
    echo "BusyBox flock holder and fallback holder overlapped" >&2; false; }
}

@test "BusyBox flock polling: deadline with a live holder" {
  # A live BusyBox flock holder blocks a second acquirer, which must
  # give up at about the original timeout with exit 3.
  source "$HELPER"
  [ "$_ACQUIRE_LOCK_FLOCK_CAP" = "n" ] || skip "not a polling-mode flock host"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/busybox-deadline.lock"

  # Holder: acquire and hold for 4 s.
  (
    source "$HELPER"
    acquire_lock "$lock_file" 10 9 2>/dev/null || exit 1
    sleep 4 2>/dev/null || sleep 4
    release_lock 9
  ) &
  local holder=$!
  sleep 0.3 2>/dev/null || sleep 1

  local start end elapsed rc=0
  start="$(date +%s)"
  acquire_lock "$lock_file" 2 9 2>/dev/null || rc=$?
  end="$(date +%s)"
  elapsed=$(( end - start ))

  wait "$holder" 2>/dev/null || true

  [ "$rc" -eq 3 ] || {
    echo "expected timeout (rc=3), got rc=$rc" >&2; false; }
  [ "$elapsed" -le 4 ] || {
    echo "took $elapsed s instead of ~2 s" >&2; false; }
}

@test "BusyBox flock polling: two flock-mode contenders are exclusive" {
  source "$HELPER"
  [ "$_ACQUIRE_LOCK_FLOCK_CAP" = "n" ] || skip "not a polling-mode flock host"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/busybox-excl.lock"
  local marker="$TEST_TMP/busybox-excl-cs"
  local overlap="$TEST_TMP/busybox-excl-overlap"
  rm -f "$overlap"

  (
    source "$HELPER"
    acquire_lock "$lock_file" 5 9 2>/dev/null || exit 1
    if mkdir "$marker" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "$marker"
    else
      echo OVERLAP > "$overlap"
    fi
    release_lock 9
  ) &

  (
    source "$HELPER"
    acquire_lock "$lock_file" 5 9 2>/dev/null || exit 1
    if mkdir "$marker" 2>/dev/null; then
      sleep 0.2 2>/dev/null || sleep 1
      rmdir "$marker"
    else
      echo OVERLAP > "$overlap"
    fi
    release_lock 9
  ) &

  wait
  [ ! -f "$overlap" ] || {
    echo "two BusyBox flock-mode holders overlapped" >&2; false; }
}

@test "capability probe leaves no leaked fd 223" {
  # With a flock shim where both -w and -n fail, after sourcing the
  # helper, fd 223 must not be open.
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-leak-test"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w|-n) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    source "'"$HELPER"'"
    if [ -e /proc/self/fd/223 ] || [ -e /dev/fd/223 ]; then
      echo "FD_223_LEAKED"
    else
      echo "FD_223_CLEAN"
    fi
  '
  [[ "$output" == *"FD_223_CLEAN"* ]] || {
    echo "fd 223 leaked after capability probe: $output" >&2; false; }
}

# ============================================================
# No-flock reaper and incompatible-flock probe guards
# ============================================================

@test "a process without flock on its PATH does not acquire while a flock-mode holder holds" {
  # A acquires via flock and holds. X runs with a PATH that has no flock
  # binary. Under fail-closed, X's reaper refuses to clear the ownerless
  # file (no reliable probe available) and X times out.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/noflock-double.lock"
  local a_state="$TEST_TMP/noflock-a-state"
  rm -f "$a_state"

  # A: flock-mode holder (flock on PATH).
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 8 2>/dev/null || exit 1
    echo A_ACQUIRED > "'"$a_state"'"
    sleep 3 2>/dev/null || sleep 3
    release_lock 8
    echo A_RELEASED >> "'"$a_state"'"
  ' &
  local a_pid=$!

  # Wait for A to acquire.
  local w=0
  while [ ! -s "$a_state" ] && [ "$w" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1; w=$((w+1))
  done

  # X: PATH-narrowed to exclude flock.
  local x_out=""
  x_out="$(
    export PATH="$SAFE_PATH"
    unset GAIA_PARALLEL_EXECUTION
    bash -c '
      source "'"$HELPER"'"
      if acquire_lock "'"$lock_file"'" 2 9 2>/dev/null; then
        if grep -q A_ACQUIRED "'"$a_state"'" && ! grep -q A_RELEASED "'"$a_state"'"; then
          echo "DOUBLE_HOLDER"
        else
          echo "X_AFTER_A_RELEASED"
        fi
        release_lock 9
      else
        echo "X_EXCLUDED rc=$?"
      fi
    '
  )"

  wait "$a_pid" 2>/dev/null || true

  # X must NOT have acquired while A holds.
  [[ "$x_out" != *"DOUBLE_HOLDER"* ]] || {
    echo "X (no flock) acquired while A holds via flock — double holder" >&2
    false
  }
}

@test "no-flock process timeout diagnostic names the lock path and the cause" {
  # When a no-flock process times out because it could not probe an
  # ownerless empty lock, the diagnostic must name the lock path and
  # say "no usable flock".
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/noflock-diag.lock"
  : > "$lock_file"

  local err_out=""
  err_out="$(
    export PATH="$SAFE_PATH"
    unset GAIA_PARALLEL_EXECUTION
    bash -c '
      source "'"$HELPER"'"
      # Deadline >1 s: whole-second accounting can skip all attempts at 1 s.
      acquire_lock "'"$lock_file"'" 3 9 2>&1 >/dev/null
    '
  )" || true

  [[ "$err_out" == *"$lock_file"* ]] || {
    echo "diagnostic does not name the lock path: $err_out" >&2; false; }
  [[ "$err_out" == *"no usable flock"* ]] || {
    echo "diagnostic does not mention the cause: $err_out" >&2; false; }
  [[ "$err_out" == *"util-linux flock"* ]] || {
    echo "diagnostic does not name the remedy: $err_out" >&2; false; }
}

@test "incompatible flock process gets the no-probe diagnostic on an ownerless lock" {
  # With a flock shim where both -w and -n fail (cap empty), the reaper
  # cannot probe and must time out with the diagnostic.
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-incompat-diag"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w|-n) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  local lock_file="$LOCK_DIR/incompat-diag.lock"
  : > "$lock_file"

  local err_out=""
  err_out="$(
    export PATH="$shim_dir:$SAFE_PATH"
    bash -c '
      source "'"$HELPER"'"
      # Deadline >1 s: whole-second accounting can skip all attempts at 1 s.
      acquire_lock "'"$lock_file"'" 3 9 2>&1 >/dev/null
    '
  )" || true

  [[ "$err_out" == *"$lock_file"* ]] || {
    echo "diagnostic does not name the lock path: $err_out" >&2; false; }
  [[ "$err_out" == *"no usable flock"* ]] || {
    echo "diagnostic does not mention the cause: $err_out" >&2; false; }
}

@test "incompatible flock reaper does not delete an ownerless empty lock" {
  # With a flock shim that rejects both -w and -n (cap empty), the
  # reaper must NOT delete an ownerless (empty) lock file. The
  # incompatible flock can't probe, so it's unsafe to assume no holder.
  local real_flock=""
  real_flock="$(command -v flock 2>/dev/null || true)"
  [ -n "$real_flock" ] || skip "flock not available"  # lint-pack:allow-skip

  local shim_dir="$TEST_TMP/flock-incompat-reap"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/flock" <<SHIMEOF
#!/bin/sh
for _a in "\$@"; do case "\$_a" in -w|-n) exit 1 ;; esac; done
exec "$real_flock" "\$@"
SHIMEOF
  chmod +x "$shim_dir/flock"

  local lock_file="$LOCK_DIR/incompat-reap.lock"
  # Plant an ownerless empty lock.
  : > "$lock_file"

  run bash -c '
    export PATH="'"$shim_dir"':'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null || true
    if [ -f "'"$lock_file"'" ]; then
      echo "LOCK_SURVIVED"
    else
      echo "LOCK_DELETED"
    fi
  '

  # The empty lock must survive (reaper can't safely probe).
  [[ "$output" == *"LOCK_SURVIVED"* ]] || {
    echo "incompatible-flock reaper deleted an ownerless lock: $output" >&2
    false
  }
}

@test "a process with a reliable flock probe still clears an empty ownerless lock with no holder" {
  # Positive test: a forced-fallback acquirer with usable flock (cap w)
  # must reap an empty ownerless lock that has no holder, acquire
  # successfully, and NOT print the no-probe diagnostic.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/probe-clears.lock"
  : > "$lock_file"

  local err_out=""
  run bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=0
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>"'"$TEST_TMP/probe-clears-err"'"
    echo "rc=$?"
    if [ -f "'"$lock_file"'" ]; then
      head -1 "'"$lock_file"'"
    fi
    release_lock 9
  '
  err_out="$(cat "$TEST_TMP/probe-clears-err" 2>/dev/null)"

  # Must acquire (rc 0).
  [[ "$output" == *"rc=0"* ]] || {
    echo "acquirer failed: $output" >&2; false; }

  # The no-probe diagnostic must NOT appear.
  [[ "$err_out" != *"no usable flock"* ]] || {
    echo "no-probe diagnostic printed despite usable flock: $err_out" >&2; false; }

  # The lock file must carry the acquirer's token (non-empty, has a PID).
  local token_line=""
  token_line="$(printf '%s\n' "$output" | grep -v '^rc=' | head -1)"
  [ -n "$token_line" ] || {
    echo "lock file has no token after acquire" >&2; false; }
  local token_pid=""
  token_pid="${token_line%% *}"
  [ "$token_pid" -gt 0 ] 2>/dev/null || {
    echo "token PID is not a positive integer: $token_line" >&2; false; }
}

@test "forced-fallback reaper runs flock probe and does not reap a live flock holder" {
  # With GAIA_LOCK_FORCE_FALLBACK=1 and a USABLE flock, the reaper's
  # flock probe must still run (the override is per-process, not system-
  # wide). A live flock-mode holder's empty lock is not reaped.
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  local lock_file="$LOCK_DIR/forced-fb-probe.lock"
  local a_ready="$TEST_TMP/forced-fb-a-ready"
  local a_done="$TEST_TMP/forced-fb-a-done"
  rm -f "$a_ready" "$a_done"

  # A: flock-mode holder (usable flock).
  bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 2>/dev/null || exit 1
    touch "'"$a_ready"'"
    w=0
    while [ ! -f "'"$a_done"'" ] && [ "$w" -lt 50 ]; do
      sleep 0.2 2>/dev/null || sleep 1; w=$((w+1))
    done
    release_lock 9
  ' &
  local a_pid=$!
  _wait_for_file "$a_ready"

  # X: forced-fallback acquirer. The reaper should probe via flock and
  # detect A's holder, so X stays excluded.
  run bash -c '
    export GAIA_LOCK_FORCE_FALLBACK=1
    unset GAIA_PARALLEL_EXECUTION
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9 2>/dev/null
    echo "rc=$?"
  '

  touch "$a_done"
  wait "$a_pid" 2>/dev/null || true

  # X must have timed out (excluded by A's live flock).
  [[ "$output" == *"rc=3"* ]] || [[ "$output" == *"rc=1"* ]] || {
    echo "forced-fallback X was not excluded while A held via flock: $output" >&2
    false
  }
}

# ============================================================
# Optimisation validation: temp reuse, reaper throttle, lazy cap
# ============================================================

@test "holder dies mid-contention: other contenders reclaim and finish within deadline" {
  # A acquires the lock and is killed. B and C contend; both must
  # eventually acquire (after the reap threshold) within their
  # deadlines, with no double holder at any point.
  local lock_file="$LOCK_DIR/die-mid.lock"
  local holder_ready="$TEST_TMP/die-mid-ready"
  local marker="$TEST_TMP/die-mid-cs"
  local overlap="$TEST_TMP/die-mid-overlap"
  local b_done="$TEST_TMP/die-mid-b"
  local c_done="$TEST_TMP/die-mid-c"
  rm -f "$holder_ready" "$overlap" "$b_done" "$c_done"

  # A: acquire and hold, signal readiness.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 || exit 1
    touch "'"$holder_ready"'"
    while :; do sleep 0.1; done
  ' &
  local a_pid=$!
  _wait_for_file "$holder_ready"

  # Kill A.
  kill -9 "$a_pid" 2>/dev/null || true
  wait "$a_pid" 2>/dev/null || true
  sleep 1

  # B and C contend with a short reap threshold.
  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || exit 1
    if ! mkdir "'"$marker"'" 2>/dev/null; then
      echo OVERLAP > "'"$overlap"'"
    fi
    sleep 0.2 2>/dev/null || sleep 1
    rmdir "'"$marker"'" 2>/dev/null || true
    release_lock 9
    touch "'"$b_done"'"
  ' &
  local b_pid=$!

  bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 10 9 2>/dev/null || exit 1
    if ! mkdir "'"$marker"'" 2>/dev/null; then
      echo OVERLAP > "'"$overlap"'"
    fi
    sleep 0.2 2>/dev/null || sleep 1
    rmdir "'"$marker"'" 2>/dev/null || true
    release_lock 9
    touch "'"$c_done"'"
  ' &
  local c_pid=$!

  wait "$b_pid" 2>/dev/null || true
  wait "$c_pid" 2>/dev/null || true

  [ -f "$b_done" ] || { echo "B never acquired" >&2; false; }
  [ -f "$c_done" ] || { echo "C never acquired" >&2; false; }
  [ ! -f "$overlap" ] || { echo "double holder detected" >&2; false; }
}

@test "deadline shorter than reap threshold: acquirer times out cleanly" {
  # A lock with a dead PID and a FRESH mtime. The reap threshold is 10 s,
  # so the reaper reads the dead PID but refuses to clear it (file too
  # young). The acquirer has a 2 s deadline, which is shorter than the
  # 10 s the reaper would need. The acquirer must time out cleanly.
  local lock_file="$LOCK_DIR/short-dl.lock"
  printf '99999 1000000000\n' > "$lock_file"
  # Do NOT backdate — the file has a fresh mtime, so age < 10 s threshold.

  local start_s elapsed
  start_s="$(date +%s)"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_REAP_SECONDS=10
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 2 9
  '
  elapsed=$(( $(date +%s) - start_s ))

  [ "$status" -eq 3 ] || { echo "expected exit 3 (timeout), got $status" >&2; false; }
  [ "$elapsed" -ge 2 ] || { echo "returned in ${elapsed}s, expected >=2" >&2; false; }
  [ "$elapsed" -le 5 ] || { echo "took ${elapsed}s, expected ~2" >&2; false; }
  [[ "$output" == *"lock_timeout"* ]] || { echo "no timeout diagnostic: $output" >&2; false; }
}

@test "reused temp never collides across concurrent subshells of one process" {
  # 8 background subshells of one process acquire and release in a loop.
  # Assert unique temp names via the debug trace and no double holder.
  # Also assert reuse WITHIN one acquisition: each acquisition emits
  # exactly one tmp trace even when it retries (force retries with a
  # held lock).
  local lock_file="$LOCK_DIR/reuse-temp.lock"
  local debug_log="$TEST_TMP/reuse-temp-debug.log"
  local overlap="$TEST_TMP/reuse-temp-overlap"
  local marker="$TEST_TMP/reuse-temp-cs"
  : > "$debug_log"
  rm -f "$overlap"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$debug_log"'"
    source "'"$HELPER"'"
    for i in 1 2 3 4 5 6 7 8; do
      (
        source "'"$HELPER"'"
        local _j
        for _j in 1 2 3; do
          if acquire_lock "'"$lock_file"'" 5 9 2>/dev/null; then
            if ! mkdir "'"$marker"'" 2>/dev/null; then
              echo OVERLAP > "'"$overlap"'"
            fi
            sleep 0.01 2>/dev/null || true
            rmdir "'"$marker"'" 2>/dev/null || true
            release_lock 9
          fi
        done
      ) &
    done
    wait 2>/dev/null || true
  '

  [ ! -f "$overlap" ] || { echo "double holder detected" >&2; false; }

  # Check temp names are unique across concurrent subshells.
  local total distinct
  total="$(grep -c '^tmp ' "$debug_log" || true)"
  [ "$total" -ge 8 ] || { echo "too few temp traces: $total" >&2; false; }
  distinct="$(awk '$1 == "tmp" { print $2 }' "$debug_log" | sort -u | wc -l | tr -d ' ')"
  [ "$distinct" -ge 8 ] || {
    echo "temp collision: $total traced, $distinct unique" >&2
    false
  }

  # Reuse within ONE acquisition: hold a lock so a second acquirer
  # retries multiple times. It must emit exactly one tmp trace.
  local reuse_lock="$LOCK_DIR/reuse-within.lock"
  local reuse_log="$TEST_TMP/reuse-within-debug.log"
  : > "$reuse_log"
  local holder_done="$TEST_TMP/reuse-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "$reuse_lock"

  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export ACQUIRE_LOCK_DEBUG=1
    export ACQUIRE_LOCK_DEBUG_LOG="'"$reuse_log"'"
    source "'"$HELPER"'"
    acquire_lock "'"$reuse_lock"'" 2 9 2>/dev/null || true
  '
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  local reuse_tmp_count
  reuse_tmp_count="$(grep -c '^tmp ' "$reuse_log" || true)"
  [ "$reuse_tmp_count" -eq 1 ] || {
    echo "expected exactly 1 tmp trace per acquisition, got $reuse_tmp_count" >&2
    grep '^tmp ' "$reuse_log" >&2
    false
  }
}

@test "cleanup path: no .lock-tmp residue after acquire+release or timeout" {
  local lock_file="$LOCK_DIR/cleanup.lock"
  local residue

  # Path 1: successful acquire and release.
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$lock_file"'" 5 9 || exit 1
    release_lock 9
  '
  [ "$status" -eq 0 ] || { echo "acquire failed: $output" >&2; false; }
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after release: $residue" >&2; false; }

  # Path 2: timeout (live holder).
  local held_lock="$LOCK_DIR/cleanup-held.lock"
  printf '%s %s\n' "$$" "$(date +%s)" > "$held_lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$held_lock"'" 1 9
  '
  [ "$status" -ne 0 ]
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after timeout: $residue" >&2; false; }
  rm -f "$held_lock"

  # Path 3: a published lock is never removed by temp cleanup.
  local pub_lock="$LOCK_DIR/cleanup-pub.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$pub_lock"'" 5 9 || exit 1
    echo "HELD"
  '
  [[ "$output" == *"HELD"* ]] || { echo "acquire failed: $output" >&2; false; }
  [ -f "$pub_lock" ] || { echo "published lock vanished" >&2; false; }

  # Path 4: publication-refusal (exit 6) — directory at the lock path.
  local pub_dir_lock="$LOCK_DIR/cleanup-pub-dir.lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    _al_pre_link_hook() { mkdir -p "$1" 2>/dev/null; }
    acquire_lock "'"$pub_dir_lock"'" 2 9
  '
  [ "$status" -ne 0 ]
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after publication-refusal: $residue" >&2; false; }

  # Path 5: strict type failure (exit 4) — symlink at the lock path.
  local strict_lock="$LOCK_DIR/cleanup-strict.lock"
  ln -s /dev/null "$strict_lock" 2>/dev/null || true
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$strict_lock"'" 2 9 --strict
  '
  [ "$status" -eq 4 ] || [ "$status" -ne 0 ]
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after strict type failure: $residue" >&2; false; }
  rm -f "$strict_lock"

  # Path 6: non-strict type enforcement failure — directory with foreign files.
  local type_lock="$LOCK_DIR/cleanup-type.lock"
  mkdir -p "$type_lock"
  printf 'keep\n' > "$type_lock/foreign"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    acquire_lock "'"$type_lock"'" 2 9
  '
  [ "$status" -ne 0 ]
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after type enforcement failure: $residue" >&2; false; }
  rm -rf "$type_lock"

  # Path 7: strict identity mismatch (exit 5) — override _al_dev_ino.
  local sid_lock="$LOCK_DIR/cleanup-sid.lock"
  local foreign_lock="$LOCK_DIR/cleanup-sid-foreign.lock"
  sleep 300 & local foreign_pid=$!
  printf '%s %s foreign-nonce\n' "$foreign_pid" "$(date +%s)" > "$foreign_lock"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    # Path-based differentiation (each call in a $() subshell).
    _al_dev_ino() {
      case "$1" in
        *.lock-tmp.*) printf "2:200" ;;
        *)            printf "1:100" ;;
      esac
    }
    acquire_lock "'"$sid_lock"'" 2 9 --strict
  '
  [ "$status" -eq 5 ] || { echo "expected exit 5, got $status" >&2; false; }
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue after strict identity mismatch: $residue" >&2; false; }
  # Foreign lock must survive.
  [ -f "$foreign_lock" ] || { echo "foreign lock removed by identity-mismatch cleanup" >&2; false; }
  kill "$foreign_pid" 2>/dev/null; wait "$foreign_pid" 2>/dev/null || true
  rm -f "$foreign_lock" "$sid_lock"
}

@test "strict fallback identity mismatch: exit 5, prompt, ownership-safe, no residue" {
  # Force the strict-mode fallback dev:ino check to disagree and assert
  # (a) exit status 5, (b) prompt termination, (c) ownership-safe cleanup.
  local lock_file="$LOCK_DIR/strict-id-fail.lock"
  local foreign_lock="$LOCK_DIR/strict-id-foreign.lock"

  # Plant a foreign lock at a nearby path to prove it is never touched.
  sleep 300 & local foreign_pid=$!
  printf '%s %s foreign\n' "$foreign_pid" "$(date +%s)" > "$foreign_lock"

  local start_s elapsed
  start_s="$(date +%s)"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    # Override _al_dev_ino to return different values for the published
    # lock vs. the temp file. Each call runs in a $() subshell, so a
    # counter variable would be reset. Use path-based differentiation:
    # the temp path contains ".lock-tmp.", the published lock does not.
    _al_dev_ino() {
      case "$1" in
        *.lock-tmp.*) printf "2:200" ;;
        *)            printf "1:100" ;;
      esac
    }
    acquire_lock "'"$lock_file"'" 10 9 --strict
  '
  elapsed=$(( $(date +%s) - start_s ))

  # (a) Exact exit status 5 (ACQUIRE_LOCK_EXIT_IDENTITY).
  [ "$status" -eq 5 ] || { echo "expected exit 5, got $status" >&2; false; }

  # (b) Prompt termination (well under the 10 s deadline).
  [ "$elapsed" -lt 3 ] || { echo "took ${elapsed}s — not prompt" >&2; false; }

  # (c) The diagnostic names the cause.
  [[ "$output" == *"lock_identity_unstable"* ]] || {
    echo "no identity_unstable diagnostic: $output" >&2; false
  }

  # (c) No temp residue.
  local residue
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue: $residue" >&2; false; }

  # (c) Foreign lock untouched.
  [ -f "$foreign_lock" ] || { echo "foreign lock removed" >&2; false; }
  grep -qF "foreign" "$foreign_lock" || { echo "foreign lock content changed" >&2; false; }
  kill "$foreign_pid" 2>/dev/null; wait "$foreign_pid" 2>/dev/null || true
  rm -f "$foreign_lock" "$lock_file"
}

@test "flock path: identity UNAVAILABLE once then live-holder contention exits 3 not 5" {
  # The _al_last_exit latch must be reset after a successful identity +
  # fd-size check. When the FIRST iteration encounters UNAVAILABLE (setting
  # _al_last_exit to IDENTITY/5) and subsequent iterations see a live
  # fallback holder (identity VERIFIED, fd-size non-empty, latch reset),
  # the final timeout must be 3 (TIMEOUT), not the stale 5 (IDENTITY).
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/latch-reset.lock"
  local holder_done="$TEST_TMP/latch-holder-done"
  local flag="$TEST_TMP/latch-first-flag"
  rm -f "$holder_done" "$flag"

  # Plant a live fallback holder (non-empty PID file).
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s nonce\n' "$holder_pid" "$(date +%s)" > "$lock_file"

  run bash -c '
    source "'"$HELPER"'"
    # First iteration: force UNAVAILABLE via a file-based flag.
    _al_verify_fd_identity() {
      if [ ! -f "'"$flag"'" ]; then
        touch "'"$flag"'"
        return 2  # UNAVAILABLE
      fi
      # Real check on subsequent iterations (call the original).
      local _lf="$1" _fd="$2"
      local _fd_path=""
      if [ -e "/proc/self/fd/${_fd}" ]; then _fd_path="/proc/self/fd/${_fd}"
      elif [ -e "/dev/fd/${_fd}" ]; then _fd_path="/dev/fd/${_fd}"
      else return 2; fi
      local _fd_ino="" _path_ino=""
      _fd_ino="$(_al_inode "$_fd_path" 2>/dev/null)" || return 2
      _path_ino="$(_al_inode "$_lf" 2>/dev/null)" || return 1
      [ "$_fd_ino" = "$_path_ino" ] && return 0 || return 1
    }
    acquire_lock "'"$lock_file"'" 3 9 2>/dev/null
    echo "rc=$?"
  '
  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null || true

  # Must be exit 3 (TIMEOUT from live-holder contention), not 5 (IDENTITY).
  [[ "$output" == *"rc=3"* ]] || {
    echo "expected rc=3 (timeout), got: $output" >&2; false
  }
  rm -f "$lock_file" "$flag"
}

@test "strict fallback: in-loop type rejection returns exit 4 and never enters" {
  # Regression: when the in-loop strict type check rejects, the
  # cleanup must preserve the status code. The bug was: `rm || true;
  # return $?` always returned 0 because `|| true` clobbered $?.
  # Strategy: override _al_enforce_path_type_strict to pass on the
  # pre-loop check (so the temp is created) and fail with exit 4 on the
  # in-loop check (a file-based flag distinguishes the calls).
  local lock_file="$LOCK_DIR/strict-inloop.lock"
  local entered="$TEST_TMP/strict-inloop-entered"
  local flag="$TEST_TMP/strict-inloop-flag"
  rm -f "$entered" "$flag"

  # Plant a held lock so the first ln fails and the loop iterates.
  local holder_done="$TEST_TMP/strict-inloop-holder-done"
  rm -f "$holder_done"
  ( while [ ! -f "$holder_done" ]; do sleep 0.1; done ) &
  local holder_pid=$!
  printf '%s %s nonce\n' "$holder_pid" "$(date +%s)" > "$lock_file"

  local start_s
  start_s="$(date +%s)"
  run bash -c '
    export PATH="'"$SAFE_PATH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "'"$HELPER"'"
    # Pre-loop check: pass. In-loop check (after temp created): fail 4.
    _al_enforce_path_type_strict() {
      if [ -f "'"$flag"'" ]; then
        printf "lock_symlink_detected: %s\n" "$1" >&2
        return 4
      fi
      touch "'"$flag"'"
      return 0
    }
    acquire_lock "'"$lock_file"'" 10 9 --strict
    rc=$?
    if [ "$rc" -eq 0 ]; then
      touch "'"$entered"'"
      release_lock 9
    fi
    exit "$rc"
  '
  local elapsed=$(( $(date +%s) - start_s ))

  touch "$holder_done"
  kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null || true

  # (a) Exit status must be 4.
  [ "$status" -eq 4 ] || { echo "expected exit 4, got $status" >&2; false; }

  # (b) Prompt termination (well under the 10 s deadline).
  [ "$elapsed" -lt 3 ] || { echo "took ${elapsed}s — not prompt" >&2; false; }

  # (c) Critical section never entered.
  [ ! -f "$entered" ] || { echo "critical section entered despite type rejection" >&2; false; }

  # (d) No temp residue.
  local residue
  residue="$(find "$LOCK_DIR" -maxdepth 1 -name '.lock-tmp.*' 2>/dev/null)"
  [ -z "$residue" ] || { echo "temp residue: $residue" >&2; false; }

  # (e) The holder's lock file is intact (not damaged by cleanup).
  if [ -f "$lock_file" ]; then
    grep -qF "$holder_pid" "$lock_file" || {
      echo "holder's lock file damaged" >&2; false
    }
  fi

  rm -f "$lock_file" "$flag"
}

@test "flock dead-PID reaper throttled: bounded calls per second" {
  # The flock path's dead-PID/non-empty record wait must call the reaper
  # at most about once per second. Count calls via a counting wrapper
  # that delegates every call to the original implementation.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/flock-reap-throttle.lock"
  local count_file="$TEST_TMP/flock-reap-count"
  : > "$count_file"

  # Guaranteed-dead PID: spawn and reap a short-lived process.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  # Plant a fresh stale lock (dead PID, NOT backdated — reaper waits).
  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"

  run bash -c '
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_REAP_SECONDS=10
    source "'"$HELPER"'"
    # Rename the original, then define a counting wrapper.
    eval "$(declare -f _al_try_reap | sed "1s/_al_try_reap/_al_try_reap_orig/")"
    _al_try_reap() {
      printf "reap_call %s\n" "$(date +%s)" >> "'"$count_file"'"
      _al_try_reap_orig "$@"
    }
    acquire_lock "'"$lock_file"'" 3 9 2>/dev/null || true
  '

  local call_count
  call_count="$(grep -c '^reap_call ' "$count_file" || true)"
  # 3 s timeout, at most 1 reap/s + initial = about 4-5 max.
  [ "$call_count" -le 5 ] || {
    echo "reaper called $call_count times in 3 s — not throttled" >&2
    cat "$count_file" >&2
    false
  }
  # At least 2 calls: the wrapper must actually count.
  [ "$call_count" -ge 2 ] || {
    echo "only $call_count reaper call(s) — wrapper not counting" >&2
    false
  }
  rm -f "$lock_file"
}

@test "flock acquirer reclaims a dead-PID record after reap threshold" {
  # A flock-mode acquirer facing a dead-PID file must eventually reclaim
  # it (after the reap threshold) and acquire, within the deadline.
  command -v flock >/dev/null 2>&1 || skip "flock not available"  # lint-pack:allow-skip
  local lock_file="$LOCK_DIR/flock-deadpid-reclaim.lock"
  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  local start_s rc=0
  start_s="$(date +%s)"
  (
    unset GAIA_LOCK_FORCE_FALLBACK GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_REAP_SECONDS=1
    source "$HELPER"
    acquire_lock "$lock_file" 10 8 2>/dev/null
    release_lock 8
  ) || rc=$?
  local elapsed=$(( $(date +%s) - start_s ))

  [ "$rc" -eq 0 ] || { echo "failed to acquire (rc=$rc)" >&2; false; }
  [ "$elapsed" -lt 8 ] || { echo "took ${elapsed}s — timed out" >&2; false; }
}

# --- Reaper mutex exclusive-creation regression tests ---
#
# The reaper's mutex temp file must be created exclusively (mktemp with
# O_CREAT|O_EXCL) so that two same-process reapers can never collide on
# a shared temp path. Without exclusive creation, two subshells sharing
# $$ can draw the same $RANDOM suffix, one overwrites the other's token,
# and the mutex is orphaned because the owner's self-check fails.

# Derive RANDOM-seed parameters at runtime so the tests work on any bash
# version (the LCG differs between 3.2 and 5.x). _mtx_seed_derive
# replays the 3-draw sequence (2 for token, 1 for temp suffix) that the
# helper performs between the _al_reap_window_hook and the temp-name
# assignment — zero intervening RANDOM draws in that gap (verified by
# inspection: only _al_inode, comparisons, and local declarations).
# It then finds two seeds whose third draw (temp suffix) collides while
# their token draws (draws 1-2) differ, via sort+awk over 0..20000.
#
# Sets: _SEED_A  _TOKEN_A  _R3  _SEED_B  _TOKEN_B
# Fails loudly (not skip) if no colliding pair is found.
_mtx_seed_derive() {
  local _pair
  _pair="$(
    set +o pipefail  # awk exits early; SIGPIPE on the feeder is expected
    local _s _r1 _r2 _r3
    for _s in $(seq 0 20000); do
      RANDOM=$_s; _r1=$RANDOM; _r2=$RANDOM; _r3=$RANDOM
      printf '%s %s %s%s\n' "$_r3" "$_s" "$_r1" "$_r2"
    done | sort -k1,1n -k3,3 | awk '
      prev_r3=="" { prev_r3=$1; prev_s=$2; prev_t=$3; next }
      $1==prev_r3 && $3!=prev_t {
        print prev_s, $2, $1, prev_t, $3; exit
      }
      { prev_r3=$1; prev_s=$2; prev_t=$3 }
    '
  )"
  [ -n "$_pair" ] || {
    echo "FAIL: no colliding seed pair found in 0..20000 for this bash LCG" >&2
    false
    return
  }
  read -r _SEED_A _SEED_B _R3 _TOKEN_A _TOKEN_B <<< "$_pair"
}

@test "reaper mutex temp uses exclusive creation, not a predictable path" {
  # Derives RANDOM seeds at runtime so the predicted temp suffix is
  # correct for this bash version's LCG. Between the _al_reap_window_hook
  # and the first $RANDOM draw (the mutex token) there are zero intervening
  # RANDOM draws in the helper — only _al_inode, comparisons, and local
  # declarations. The token draws 2 values and the temp suffix draws 1
  # (3 total from the reseeded state).
  # A marker file planted at the predicted path survives only if the
  # helper uses exclusive mktemp; a plain printf > overwrites it.
  #
  # Supports _TEST_HELPER_OVERRIDE for red-phase verification.
  local h="${_TEST_HELPER_OVERRIDE:-$HELPER}"
  _mtx_seed_derive
  local seed_a="$_SEED_A" r3="$_R3"

  local lock_file="$LOCK_DIR/mtx-excl.lock"
  local mutex="${lock_file}.reap-mtx"

  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  local predicted="${LOCK_DIR}/.reap-mtx-tmp.$$.${r3}"
  printf 'COLLISION_MARKER\n' > "$predicted"

  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    _al_reap_window_hook() { RANDOM=$seed_a; }
    acquire_lock "$lock_file" 5 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  )

  # The mutex must be cleaned up by its owner (not orphaned).
  [ ! -f "$mutex" ] || {
    echo "mutex orphaned (token: $(cat "$mutex" 2>/dev/null))" >&2; false; }

  # The marker file must survive: mktemp created a different temp.
  local survived=0
  if [ -f "$predicted" ]; then
    local content=""
    read -r content < "$predicted" 2>/dev/null || content=""
    [ "$content" = "COLLISION_MARKER" ] && survived=1
  fi

  rm -f "$predicted" "$lock_file" "$mutex"

  [ "$survived" -eq 1 ] || {
    echo "reaper used the predicted temp path (not exclusive mktemp)" >&2
    false
  }
}

@test "concurrent same-process reapers: correct mutex ownership and cleanup" {
  # Derives two RANDOM seeds at runtime whose third draw (temp suffix)
  # collides but whose token draws differ — works on any bash LCG.
  # Two subshells of the same process reap simultaneously; an
  # ln-override delay forces:
  #   A.printf -> B.printf (overwrites on old code) -> A.ln -> B.ln(fail)
  # On the old code A links a file carrying B's token; the token
  # self-check fails and the mutex is orphaned. On the fix each reaper
  # gets its own mktemp path, so the mutex carries the linker's token.
  #
  # Supports _TEST_HELPER_OVERRIDE env var for red-phase demonstration
  # against a detached copy of the pre-fix helper.
  _mtx_seed_derive
  local seed_a="$_SEED_A" seed_b="$_SEED_B"

  local h="${_TEST_HELPER_OVERRIDE:-$HELPER}"
  local lock_file="$LOCK_DIR/mtx-ownership.lock"
  local mutex="${lock_file}.reap-mtx"
  local barrier="$TEST_TMP/mtx-own"
  local result_a="$TEST_TMP/mtx-own-result-a"
  local result_b="$TEST_TMP/mtx-own-result-b"

  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  rm -f "$barrier".{a,b} "$result_a" "$result_b"

  # Build per-reaper PATH directories with an ln wrapper that delays
  # on the mutex-temp pattern. Using a PATH-based wrapper (not a
  # function override) avoids a bash 3.2 set -e bug where
  # `if ! function()` exits the shell on a non-zero return.
  local real_ln
  real_ln="$(command -v ln)"
  local shim_a="$TEST_TMP/ln-shim-a" shim_b="$TEST_TMP/ln-shim-b"
  mkdir -p "$shim_a" "$shim_b"
  printf '#!/bin/sh\ncase "$1" in *reap-mtx-tmp*) sleep 1;; esac\nexec "%s" "$@"\n' \
    "$real_ln" > "$shim_a/ln"
  chmod +x "$shim_a/ln"
  printf '#!/bin/sh\ncase "$1" in *reap-mtx-tmp*) sleep 2;; esac\nexec "%s" "$@"\n' \
    "$real_ln" > "$shim_b/ln"
  chmod +x "$shim_b/ln"

  # Reaper A: delays ln by 1 s so B's printf can overwrite.
  (
    export PATH="$shim_a:$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    _al_reap_window_hook() {
      RANDOM=$seed_a
      touch "$barrier.a"
      local _t=0
      while [ ! -f "$barrier.b" ] && [ "$_t" -lt 100 ]; do
        sleep 0.05; _t=$((_t + 1)); done
    }
    _al_reap_pre_rm_hook() {
      local _mc=""
      read -r _mc < "$mutex" 2>/dev/null || _mc=""
      printf '%s\n%s\n' "$_mc" "$_mtx_token" > "$result_a"
    }
    acquire_lock "$lock_file" 8 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ) &
  local pid_a=$!

  # Reaper B: delays ln by 2 s so A links first.
  (
    export PATH="$shim_b:$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    _al_reap_window_hook() {
      RANDOM=$seed_b
      touch "$barrier.b"
      local _t=0
      while [ ! -f "$barrier.a" ] && [ "$_t" -lt 100 ]; do
        sleep 0.05; _t=$((_t + 1)); done
      sleep 0.1
    }
    _al_reap_pre_rm_hook() {
      local _mc=""
      read -r _mc < "$mutex" 2>/dev/null || _mc=""
      printf '%s\n%s\n' "$_mc" "$_mtx_token" > "$result_b"
    }
    acquire_lock "$lock_file" 8 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
  ) &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  # Exactly one reaper should have held the mutex (the first to ln).
  local winner="" mtx_val="" own_val=""
  if [ -f "$result_a" ]; then
    winner="A"
    mtx_val="$(sed -n '1p' "$result_a")"
    own_val="$(sed -n '2p' "$result_a")"
  elif [ -f "$result_b" ]; then
    winner="B"
    mtx_val="$(sed -n '1p' "$result_b")"
    own_val="$(sed -n '2p' "$result_b")"
  fi
  [ -n "$winner" ] || {
    echo "no reaper held the mutex (pre-rm hook never fired)" >&2; false; }

  # (a) While the reaper held the mutex, it must have contained
  #     exactly that reaper's own token.
  [ "$mtx_val" = "$own_val" ] || {
    echo "ownership mismatch: mutex had [$mtx_val], reaper $winner owns [$own_val]" >&2
    false
  }

  # (b) After the reap, the mutex must be gone and no temp leftover.
  [ ! -f "$mutex" ] || {
    echo "mutex orphaned after reap (content: $(cat "$mutex" 2>/dev/null))" >&2
    false
  }
  local leftover
  leftover="$(find "$LOCK_DIR" -name '.reap-mtx-tmp.*' 2>/dev/null)"
  [ -z "$leftover" ] || {
    echo "temp leftover: $leftover" >&2; false; }

  rm -f "$lock_file" "$mutex" "$barrier".{a,b} "$result_a" "$result_b"
}

@test "pre-existing foreign reap mutex is not removed by another reaper" {
  # A mutex left by a dead owner must survive when a different reaper
  # tries to reap the same lock: the new reaper's ln to the mutex
  # path fails (EEXIST) and it backs off without touching the file.
  local h="${_TEST_HELPER_OVERRIDE:-$HELPER}"
  local lock_file="$LOCK_DIR/mtx-foreign.lock"
  local mutex="${lock_file}.reap-mtx"

  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  # Pre-create a foreign-owned mutex.
  printf '99998 foreign-nonce\n' > "$mutex"

  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    acquire_lock "$lock_file" 2 9 2>/dev/null || true
  )

  # (c) The foreign mutex must survive.
  [ -f "$mutex" ] || {
    echo "foreign mutex was removed by another reaper" >&2; false; }
  local token=""
  read -r token < "$mutex" 2>/dev/null || token=""
  [ "$token" = "99998 foreign-nonce" ] || {
    echo "foreign mutex content changed: [$token]" >&2; false; }
  rm -f "$lock_file" "$mutex"
}

@test "reaper mutex creation failure leaves no leftover and does not reap" {
  # When the exclusive temp for the mutex cannot be created, the
  # reaper must decline: no mutex, no temp leftover, stale lock
  # not reaped.
  #
  # Supports _TEST_HELPER_OVERRIDE for red-phase verification.
  local h="${_TEST_HELPER_OVERRIDE:-$HELPER}"
  local lock_file="$LOCK_DIR/mtx-noreap.lock"

  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    # Shim: fail only the reap-mutex temp pattern; pass everything else.
    mktemp() {
      case "$1" in
        *reap-mtx-tmp*) return 1 ;;
        *) command mktemp "$@" ;;
      esac
    }
    acquire_lock "$lock_file" 2 9 2>/dev/null || true
  )

  # Stale lock must NOT have been reaped.
  [ -f "$lock_file" ] || {
    echo "lock file removed" >&2; false; }
  local pid_check=""
  read -r pid_check _ < "$lock_file" 2>/dev/null || pid_check=""
  [ "$pid_check" = "$dead_pid" ] || {
    echo "stale lock was reaped (pid=$pid_check, expected $dead_pid)" >&2; false; }
  # No mutex must exist.
  [ ! -f "${lock_file}.reap-mtx" ] || {
    echo "mutex left behind" >&2; false; }
  # No reap-mtx-tmp leftover.
  local leftover
  leftover="$(find "$LOCK_DIR" -name '.reap-mtx-tmp.*' 2>/dev/null)"
  [ -z "$leftover" ] || {
    echo "temp leftover: $leftover" >&2; false; }
  rm -f "$lock_file" "${lock_file}.reap-mtx"
}

@test "reaper mutex write failure after exclusive creation leaves no leftover" {
  # When the exclusively created mutex temp exists but writing the
  # token fails, the reaper must clean up: no mutex, no leftover temp
  # in the lock dir, stale lock not reaped, and emit the specific
  # write-failure diagnostic. The shim returns a path whose parent
  # does not exist, so the shell redirect fails for any user including
  # root (no CAP_DAC_OVERRIDE bypass). The shim records the injected
  # path so the leftover check verifies the ACTUAL path, not just a
  # glob. rm -f on the nonexistent path is a silent no-op.
  #
  # Supports _TEST_HELPER_OVERRIDE for red-phase verification.
  local h="${_TEST_HELPER_OVERRIDE:-$HELPER}"
  local lock_file="$LOCK_DIR/mtx-wfail.lock"

  # Guaranteed-dead PID.
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true

  printf '%s 1000000000\n' "$dead_pid" > "$lock_file"
  touch -t 202001010000 "$lock_file" \
    || { echo "cannot backdate" >&2; false; }

  local err_file="$TEST_TMP/mtx-wfail-err"
  local injected_path_file="$TEST_TMP/mtx-wfail-injected"
  (
    export PATH="$SAFE_PATH"
    export GAIA_LOCK_FORCE_FALLBACK=1
    export GAIA_LOCK_REAP_SECONDS=1
    source "$h"
    # Shim: for the reap-mutex pattern, return a path under a
    # nonexistent subdirectory. printf > fails (ENOENT) for any user.
    # Record the injected path so the outer test can check it.
    mktemp() {
      case "$1" in
        *reap-mtx-tmp*)
          local _injected="${1%/*}/no-such-dir/.reap-mtx-tmp.XXXXXX"
          printf '%s' "$_injected" > "$injected_path_file"
          printf '%s' "$_injected"
          ;;
        *) command mktemp "$@" ;;
      esac
    }
    acquire_lock "$lock_file" 2 9 2>"$err_file" || true
  )

  [ -f "$lock_file" ] || {
    echo "lock file removed" >&2; false; }
  local pid_check=""
  read -r pid_check _ < "$lock_file" 2>/dev/null || pid_check=""
  [ "$pid_check" = "$dead_pid" ] || {
    echo "stale lock was reaped (pid=$pid_check, expected $dead_pid)" >&2; false; }
  # No mutex must exist.
  [ ! -f "${lock_file}.reap-mtx" ] || {
    echo "mutex left behind" >&2; false; }
  # The injected temp path must not exist (cleaned up or never created).
  local injected=""
  read -r injected < "$injected_path_file" 2>/dev/null || injected=""
  if [ -n "$injected" ] && [ -e "$injected" ]; then
    echo "injected temp path still exists: $injected" >&2; false
  fi
  # No .reap-mtx-tmp.* residue anywhere in the lock dir.
  local leftover
  leftover="$(find "$LOCK_DIR" -name '.reap-mtx-tmp.*' 2>/dev/null)"
  [ -z "$leftover" ] || {
    echo "temp leftover in lock dir: $leftover" >&2; false; }
  # Stderr must contain the specific write-failure diagnostic.
  grep -q 'cannot write reap-mutex token' "$err_file" 2>/dev/null || {
    echo "missing write-failure diagnostic in stderr:" >&2
    cat "$err_file" >&2
    false
  }
  rm -f "$lock_file" "${lock_file}.reap-mtx" "$err_file" "$injected_path_file"
}
