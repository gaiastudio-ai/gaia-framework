#!/usr/bin/env bats
# action-items-write-lock.bats
#
# Tests for the action-items writer's locking behaviour: live-holder timeout,
# stale-lock recovery, forced fallback, flock-path timeout, fail-closed under
# parallel execution, stat mode restoration, and id/dedup atomicity.
#
# Covers: aiw_append_entry, aiw_resolve, aiw_write locking paths in
# action-items-write.sh, plus the GAIA_AIW_LOCK_TIMEOUT,
# GAIA_LOCK_FORCE_FALLBACK, GAIA_AIW_TEST_HOLD_SECONDS, and
# GAIA_LOCK_REAP_SECONDS env overrides.

load 'test_helper.bash'

AIW_SH="$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
LOCK_LIB="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  # Ensure parallel execution is OFF unless a test explicitly sets it.
  unset GAIA_PARALLEL_EXECUTION
  unset GAIA_WORKTREE_MODE
}

teardown() {
  # Kill only jobs this test started.
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  common_teardown
}

# ---------- Fixture helpers ----------

_seed_file() {
  local target="$1" count="${2:-4}"
  mkdir -p "$(dirname "$target")"
  {
    printf 'last_updated: "2026-01-01"\nitems:\n'
    if [ "$count" -gt 0 ] 2>/dev/null; then
      local i
      for i in $(seq 1 "$count"); do
        printf '  - id: "AI-%d"\n    sprint_id: "sprint-99"\n    text: "Item %d"\n    classification: "implementation"\n    status: "open"\n    escalation_count: 0\n    created_at: "2026-01-01T00:00:00Z"\n    theme_hash: "sha256:abc"\n    story_key: "STORY-%d"\n' "$i" "$i" "$i"
      done
    fi
  } > "$target"
}

# ================================================================
# AC1: live-holder timeout — waiter must not delete the lock, must
#       not write unlocked, must exit 1 with the correct two-line
#       stdout, and must leave no temp file behind.
# ================================================================

@test "fallback lock: waiter times out without removing a live holder's lock (resolve)" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac1-resolve.yaml"
  _seed_file "$target" 2

  # Hold the lock via the fallback path (same mechanism the writer will use).
  source "$LOCK_LIB"
  local lock_file="${target}.lock"
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lock_file" 120 6

  # Run aiw_resolve with a short timeout and forced fallback.
  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_resolve --target "$target" --item "AI-1" --status done \
      --resolution "test" 2>/dev/null
  )" && rc=0 || rc=$?

  # Must fail.
  [ "$rc" -ne 0 ]

  # Stdout must be exactly two lines: status=error then reason=...
  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ]
  [[ "$line2" == reason=*"lock timeout"* ]]

  # The lock must still exist — the waiter must NOT have removed it.
  [ -e "$lock_file" ]

  # No leftover temp files.
  local temps
  temps="$(find "$(dirname "$target")" -name "$(basename "$target").??????" 2>/dev/null)" || temps=""
  [ -z "$temps" ]

  release_lock 6
}

@test "fallback lock: waiter times out without removing a live holder's lock (write/append)" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac1-write.yaml"
  _seed_file "$target" 1

  # Hold the lock via the fallback path (same mechanism the writer will use).
  source "$LOCK_LIB"
  local lock_file="${target}.lock"
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lock_file" 120 6

  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "should timeout" \
      --ref-key story_key --ref-value "STORY-99" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]

  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ]
  [[ "$line2" == reason=*"lock timeout"* ]]

  # Lock still present.
  [ -e "$lock_file" ]

  release_lock 6
}

# ================================================================
# AC2: stale-lock recovery — a lock left by a dead process and older
#       than the reap threshold is cleaned up and the write proceeds.
#       A lock whose holder PID is alive is never removed.
# ================================================================

@test "stale lock left by dead process is reaped after threshold" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac2-stale.yaml"
  _seed_file "$target" 2

  # Create a lock file with a known-dead PID and back-date it.
  local lock_file="${target}.lock"
  printf '99999999 1000000000\n' > "$lock_file"
  # Verify the PID is actually dead.
  if kill -0 99999999 2>/dev/null; then skip "PID 99999999 is somehow alive"; fi

  # Back-date the lock so it exceeds the reap threshold.
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    touch -d '2020-01-01' "$lock_file"
  else
    touch -t 202001010000 "$lock_file"
  fi

  # Use a low reap threshold and forced fallback.
  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=5 GAIA_LOCK_REAP_SECONDS=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_resolve --target "$target" --item "AI-1" --status done \
      --resolution "reaped" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -eq 0 ]
  [[ "$out" == *"status=ok"* ]]

  # Verify the resolve actually landed.
  local done_count
  done_count="$(yq -r '[.items[] | select(.status == "done")] | length' "$target")"
  [ "$done_count" -eq 1 ]
}

@test "lock held by a live PID is never removed regardless of age" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac2-live.yaml"
  _seed_file "$target" 2

  # Create a lock file with OUR PID (guaranteed alive) and back-date it.
  local lock_file="${target}.lock"
  printf '%s 1000000000\n' "$$" > "$lock_file"
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    touch -d '2020-01-01' "$lock_file"
  else
    touch -t 202001010000 "$lock_file"
  fi

  # With a very short timeout, the writer should time out rather than
  # reapting a lock whose holder is alive.
  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=1 GAIA_LOCK_REAP_SECONDS=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_resolve --target "$target" --item "AI-1" --status done \
      --resolution "should-fail" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]
  # Lock file must still exist.
  [ -e "$lock_file" ]
  # File must not have been modified.
  local done_count
  done_count="$(yq -r '[.items[] | select(.status == "done")] | length' "$target")"
  [ "$done_count" -eq 0 ]
}

# ================================================================
# AC3: GAIA_LOCK_FORCE_FALLBACK forces the fallback path, flock-path
#       timeout, and fail-closed under parallel execution.
# ================================================================

@test "GAIA_LOCK_FORCE_FALLBACK=1 forces the fallback path (not flock)" {
  # This test verifies the writer respects the forced-fallback override.
  # With a live holder and forced fallback at a short timeout, it must
  # time out (proving flock was NOT used, since flock would still work).
  source "$AIW_SH"
  source "$LOCK_LIB"

  local target="$TEST_TMP/ac3-force-fb.yaml"
  _seed_file "$target" 1

  # Hold the lock via the shared helper's fallback path.
  local lock_file="${target}.lock"
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lock_file" 120 6

  # Writer with forced fallback and short timeout should fail.
  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "fb test" \
      --ref-key story_key --ref-value "STORY-99" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]
  [[ "$out" == *"lock timeout"* ]]

  release_lock 6
}

@test "flock-path times out after GAIA_AIW_LOCK_TIMEOUT seconds instead of blocking forever" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  source "$AIW_SH"

  local target="$TEST_TMP/ac3-flock-timeout.yaml"
  _seed_file "$target" 1

  # Hold the lock via flock on a different fd.
  local lock_file="${target}.lock"
  ( umask 077; set -C; : > "$lock_file" ) 2>/dev/null || true
  eval "exec 5>>\"$lock_file\""
  flock -x 5

  # Writer with a very short timeout must fail (not block forever).
  local out
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=1 \
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "flock timeout" \
      --ref-key story_key --ref-value "STORY-99" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]
  [[ "$out" == *"lock timeout"* ]]

  flock -u 5
  eval "exec 5>&-"
}

@test "fail-closed: parallel execution with no flock rejects with lock unavailable" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac3-fail-closed-noflock.yaml"
  _seed_file "$target" 1

  # Simulate no flock by hiding it from PATH.
  local noflock_dir="$TEST_TMP/noflock-bin-fc"
  mkdir -p "$noflock_dir"
  local _pd _f _bn OLDIFS="$IFS"; IFS=':'
  for _pd in $PATH; do
    [ -d "$_pd" ] || continue
    for _f in "$_pd"/*; do
      [ -x "$_f" ] || continue
      _bn="${_f##*/}"
      [ "$_bn" = "flock" ] && continue
      [ -e "$noflock_dir/$_bn" ] || ln -sf "$_f" "$noflock_dir/$_bn" 2>/dev/null || true
    done
  done
  IFS="$OLDIFS"

  local out
  out="$(
    export PATH="$noflock_dir"
    export GAIA_PARALLEL_EXECUTION=1
    source "$AIW_SH"
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "should reject" \
      --ref-key story_key --ref-value "STORY-99" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]
  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ]
  [[ "$line2" == *"lock unavailable"*"parallel execution requires flock"* ]]
}

@test "fail-closed: parallel execution with forced fallback rejects with lock unavailable" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac3-fail-closed-forced.yaml"
  _seed_file "$target" 1

  local out
  out="$(
    GAIA_PARALLEL_EXECUTION=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_resolve --target "$target" --item "AI-1" --status done \
      --resolution "should-reject" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ]
  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ]
  [[ "$line2" == *"lock unavailable"*"parallel execution requires flock"* ]]
}

# ================================================================
# AC5: stat mode restoration works under both GNU and BSD stat.
# ================================================================

@test "aiw_resolve restores original file mode under BSD stat (macOS)" {
  if [ "$_TEST_STAT_FMT" != "bsd" ]; then skip "BSD stat not available"; fi
  source "$AIW_SH"

  local target="$TEST_TMP/ac5-mode.yaml"
  _seed_file "$target" 1
  chmod 644 "$target"

  aiw_resolve --target "$target" --item "AI-1" --status done \
    --resolution "mode test" > /dev/null 2>&1

  local mode
  mode="$(stat -f '%Lp' "$target")"
  [ "$mode" = "644" ]
}

@test "aiw_resolve restores original file mode under GNU stat" {
  if [ "$_TEST_STAT_FMT" != "gnu" ]; then skip "GNU stat not available"; fi
  source "$AIW_SH"

  local target="$TEST_TMP/ac5-mode-gnu.yaml"
  _seed_file "$target" 1
  chmod 644 "$target"

  aiw_resolve --target "$target" --item "AI-1" --status done \
    --resolution "mode test" > /dev/null 2>&1

  local mode
  mode="$(stat -c '%a' "$target")"
  [ "$mode" = "644" ]
}

@test "aiw_resolve mode restoration works under /bin/bash 3.2" {
  if [ ! -x /bin/bash ]; then skip "/bin/bash not available"; fi
  local bash_ver
  bash_ver="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  if [ "$bash_ver" != "3.2" ]; then skip "/bin/bash is $bash_ver, not 3.2"; fi

  local target="$TEST_TMP/ac5-mode-bash32.yaml"
  _seed_file "$target" 1
  chmod 644 "$target"

  /bin/bash -c '
    source "'"$AIW_SH"'"
    aiw_resolve --target "'"$target"'" --item "AI-1" --status done \
      --resolution "bash32 mode" > /dev/null 2>&1
  '

  local mode
  if [ "$_TEST_STAT_FMT" = "bsd" ]; then
    mode="$(stat -f '%Lp' "$target")"
  else
    mode="$(stat -c '%a' "$target")"
  fi
  [ "$mode" = "644" ]
}

# ================================================================
# AC6: id and dedup computed inside the lock — no duplicate ids.
# (The deterministic forced-run test is in the race test below; here
#  we verify the structural property: two concurrent appends to the
#  same file must each get a unique id.)
# ================================================================

@test "concurrent appends never produce duplicate ids" {
  source "$AIW_SH"

  local target="$TEST_TMP/ac6-dedup.yaml"
  _seed_file "$target" 0

  local pids=() i
  for i in $(seq 1 8); do
    (
      source "$AIW_SH"
      aiw_write --target "$target" --sprint-id sprint-99 \
        --classification implementation --text "Concurrent item $i" \
        --ref-key story_key --ref-value "STORY-$i" > /dev/null 2>&1
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # All 8 items present.
  local total
  total="$(yq -r '.items | length' "$target")"
  [ "$total" -eq 8 ]

  # No duplicate ids.
  local unique_ids
  unique_ids="$(yq -r '[.items[].id] | unique | length' "$target")"
  [ "$unique_ids" -eq 8 ]
}

# ================================================================
# Mutual exclusion: no two holders overlap inside the critical section.
# Each holder creates a marker directory on entry (mkdir is atomic — fails
# if already present) and removes it on exit.  An overlap means the mkdir
# succeeded while another holder's marker was still present.
#
# The writer tests go through _aiw_lock / _aiw_unlock (the writer's
# lock/unlock cycle) so they exercise the release mechanism.  The flock
# test uses the raw helper.
#
# Fails on fafa06f5 because the truncation release in _aiw_unlock lets
# the reaper delete a live holder's lock, allowing a second holder in.
# ================================================================

@test "mutual exclusion: no two writer lock/unlock holders overlap (fallback)" {
  local lock_file="$TEST_TMP/mx-writer-fb.lock"
  local marker="$TEST_TMP/mx-writer-fb-cs"
  local log="$TEST_TMP/mx-writer-fb.log"
  : > "$log"

  # 6 processes x 4 iterations: enough contention to verify exclusion
  # without exceeding a reasonable test budget.
  local N=6 ITERS=4
  local pids=() i
  for i in $(seq 1 "$N"); do
    bash -c '
      unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
      export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_LOCK_TIMEOUT=30
      source "'"$AIW_SH"'"
      for k in $(seq 1 '"$ITERS"'); do
        if ! _aiw_lock "'"$lock_file"'" "mx-test" 2>/dev/null; then
          echo "FAIL" >> "'"$log"'"
          continue
        fi
        if mkdir "'"$marker"'" 2>/dev/null; then
          sleep 0.02
          rmdir "'"$marker"'" 2>/dev/null || echo "CS_STOLEN" >> "'"$log"'"
          echo "OK" >> "'"$log"'"
        else
          echo "OVERLAP" >> "'"$log"'"
        fi
        _aiw_unlock 2>/dev/null
      done
    ' &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  local overlaps
  overlaps="$(grep -c '^OVERLAP$' "$log" 2>/dev/null)" || overlaps=0
  [ "$overlaps" -eq 0 ]
}

@test "mutual exclusion: no two holders overlap (flock, separate processes)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi

  local lock_file="$TEST_TMP/mx-flock.lock"
  local marker="$TEST_TMP/mx-flock-cs"
  local log="$TEST_TMP/mx-flock.log"
  : > "$log"

  local N=8 ITERS=6
  local pids=() i
  for i in $(seq 1 "$N"); do
    bash -c '
      unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
      source "'"$LOCK_LIB"'"
      for k in $(seq 1 '"$ITERS"'); do
        acquire_lock "'"$lock_file"'" 30 6 2>/dev/null || { echo "FAIL" >> "'"$log"'"; continue; }
        if mkdir "'"$marker"'" 2>/dev/null; then
          sleep 0.01
          rmdir "'"$marker"'" 2>/dev/null || echo "CS_STOLEN" >> "'"$log"'"
          echo "OK" >> "'"$log"'"
        else
          echo "OVERLAP" >> "'"$log"'"
        fi
        release_lock 6 2>/dev/null
      done
    ' &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  local overlaps
  overlaps="$(grep -c '^OVERLAP$' "$log" 2>/dev/null)" || overlaps=0
  [ "$overlaps" -eq 0 ]
}

# ================================================================
# Deterministic reap-interleaving test: uses _al_pre_reap_delete_hook to
# swap the lock file between the reaper's read and its rename, then verifies
# the new holder's file survives.
#
# Fails on staging's helper (which does rm -f without inode verification):
# the hook is never called (old code doesn't check for it), so the empty
# file is unconditionally deleted and the test's existence assertion fails.
# ================================================================

@test "reaper does not delete a lock swapped by a new holder (ownerless case)" {
  source "$LOCK_LIB"

  local lock_file="$TEST_TMP/reap-own.lock"

  # Create an empty (ownerless) lock file.
  : > "$lock_file"

  # Hook: swap the lock with a new holder's file between read and rename.
  _al_pre_reap_delete_hook() {
    rm -f "$1" 2>/dev/null || true
    printf '%s %s\n' "$$" "$(date +%s)" > "${1}.hook-tmp"
    ln "${1}.hook-tmp" "$1" 2>/dev/null || true
    rm -f "${1}.hook-tmp" 2>/dev/null || true
  }

  # The reaper (inside _al_try_reap) reads the empty file, decides to reap,
  # then the hook swaps it.  The inode-safe reap must detect the swap.
  _al_try_reap "$lock_file" 5 2>/dev/null || true

  # The new holder's file must survive.
  [ -f "$lock_file" ]
  local pid_line=""
  read -r pid_line _ < "$lock_file" 2>/dev/null || pid_line=""
  [ "$pid_line" = "$$" ]

  unset -f _al_pre_reap_delete_hook
}

@test "reaper does not delete a lock swapped by a new holder (dead-PID case)" {
  source "$LOCK_LIB"

  local lock_file="$TEST_TMP/reap-dead.lock"

  # Create a lock with a dead PID, back-dated past the reap threshold.
  printf '99999999 1000000000\n' > "$lock_file"
  if kill -0 99999999 2>/dev/null; then skip "PID 99999999 is somehow alive"; fi
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    touch -d '2020-01-01' "$lock_file"
  else
    touch -t 202001010000 "$lock_file"
  fi

  # Hook: swap with a new holder's file.
  _al_pre_reap_delete_hook() {
    rm -f "$1" 2>/dev/null || true
    printf '%s %s\n' "$$" "$(date +%s)" > "${1}.hook-tmp"
    ln "${1}.hook-tmp" "$1" 2>/dev/null || true
    rm -f "${1}.hook-tmp" 2>/dev/null || true
  }

  GAIA_LOCK_REAP_SECONDS=1 _al_try_reap "$lock_file" 5 2>/dev/null || true

  # The new holder's file must survive.
  [ -f "$lock_file" ]
  local pid_line=""
  read -r pid_line _ < "$lock_file" 2>/dev/null || pid_line=""
  [ "$pid_line" = "$$" ]

  unset -f _al_pre_reap_delete_hook
}
