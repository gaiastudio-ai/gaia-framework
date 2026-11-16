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
# Before the writer switched to the shared helper, the hand-rolled
# mkdir-based lock had no holder-PID check: a waiter that timed out would
# remove the holder's lock, letting a second holder in concurrently.
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

  local overlaps fails
  overlaps="$(grep -c '^OVERLAP$' "$log" 2>/dev/null)" || overlaps=0
  fails="$(grep -c '^FAIL$' "$log" 2>/dev/null)" || fails=0
  [ "$overlaps" -eq 0 ]
  [ "$fails" -eq 0 ]

  # Structural invariant: after release, the lock path must not exist as
  # an empty (ownerless) file. An empty lock file triggers the reaper's
  # unconditional rm -f, which can race with a new holder's ln and delete
  # the new holder's lock — this is the mechanism that allows concurrent
  # holders. The safe release either removes the file outright (fallback
  # release_lock) or closes the fd (flock release_lock), leaving no
  # ownerless intermediate state the reaper can act on.
  source "$AIW_SH"
  local check_lock="$TEST_TMP/mx-release-check.lock"
  GAIA_LOCK_FORCE_FALLBACK=1 _aiw_lock "$check_lock" "mx-check" 2>/dev/null
  _aiw_unlock 2>/dev/null
  if [ -f "$check_lock" ]; then
    local check_content=""
    check_content="$(cat "$check_lock" 2>/dev/null)" || check_content=""
    [ -n "$check_content" ] || {
      echo "Lock file exists and is empty after release — ownerless intermediate state allows mutex violation" >&2
      false
    }
  fi
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
# Deterministic interleaving: the release-to-acquire window.
#
# After a holder releases via the fallback path, the reaper in a
# concurrent acquirer may remove the next holder's lock file.  Two
# processes (R, B) race through _aiw_lock / _aiw_unlock; a shell-
# function hook on rm pauses R's reaper (or a lock-steal mutation's
# rm) at the critical instant so B acquires first.  When R resumes,
# its rm deletes B's live lock and R re-acquires — overlap.
#
# Synchronisation is by marker files (polled), not by sleep timing.
# The test catches both the empty-file reaper race (a release that
# truncates instead of removing) and the lock-steal mutation (an rm
# injected after acquire).
# ================================================================

@test "mutual exclusion: interleaved release-reaper detects no overlap (fallback)" {
  local lock_file="$TEST_TMP/ir-fb.lock"
  local log="$TEST_TMP/ir-fb.log"
  local marker_B="$TEST_TMP/ir-fb-B"
  local marker_R_saw="$TEST_TMP/ir-fb-Rsaw"
  local marker_R_go="$TEST_TMP/ir-fb-Rgo"
  : > "$log"

  source "$AIW_SH"

  # Phase 1: A acquires and releases.  A safe release removes the file
  # outright; a buggy release (truncation) leaves an empty ownerless
  # file that triggers the reaper race below.
  GAIA_LOCK_FORCE_FALLBACK=1 _aiw_lock "$lock_file" "ir-setup" 2>/dev/null
  _aiw_unlock 2>/dev/null

  # Phase 2: R tries to acquire with a paused rm hook.  Any rm of the
  # lock path during acquisition is paused until marker_R_go appears.
  local _ir_lock_path="$lock_file"
  bash -c '
    _IR_LOCK='"'$_ir_lock_path'"'
    _IR_SAW='"'$marker_R_saw'"'
    _IR_GO='"'$marker_R_go'"'
    _IR_B='"'$marker_B'"'
    _IR_LOG='"'$log'"'
    source "'"$AIW_SH"'"
    export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_LOCK_TIMEOUT=8
    _ir_acq=0
    rm() {
      if [ "$_ir_acq" = "0" ]; then
        local _a
        for _a in "$@"; do
          if [ "$_a" = "$_IR_LOCK" ]; then
            touch "$_IR_SAW"
            while [ ! -e "$_IR_GO" ]; do
              sleep 0.02 2>/dev/null || sleep 1
            done
            break
          fi
        done
      fi
      command rm "$@"
    }
    _aiw_lock "$_IR_LOCK" "R" 2>/dev/null || { echo "R_TIMEOUT" >> "$_IR_LOG"; exit 0; }
    _ir_acq=1
    # Poll for B inside (marker-ordered, not timed).
    _rw=0
    while [ ! -e "$_IR_B" ] && [ "$_rw" -lt 20 ]; do
      sleep 0.05 2>/dev/null || sleep 1; _rw=$((_rw + 1))
    done
    [ -e "$_IR_B" ] && echo "OVERLAP" >> "$_IR_LOG"
    _aiw_unlock 2>/dev/null
  ' &
  local rp=$!

  # Wait for R to pause (its hook fired) or for R to finish (head path:
  # file was already gone, no hook).
  local _w=0
  while [ ! -e "$marker_R_saw" ] && kill -0 "$rp" 2>/dev/null; do
    sleep 0.05 2>/dev/null || sleep 1
    _w=$(( _w + 1 ))
    [ "$_w" -ge 60 ] && break   # ~3 s ceiling
  done

  if [ -e "$marker_R_saw" ]; then
    # R paused — start B so it acquires before R resumes.
    bash -c '
      _IR_LOCK='"'$_ir_lock_path'"'
      _IR_B='"'$marker_B'"'
      _IR_LOG='"'$log'"'
      source "'"$AIW_SH"'"
      export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_LOCK_TIMEOUT=8
      _aiw_lock "$_IR_LOCK" "B" 2>/dev/null || { echo "B_TIMEOUT" >> "$_IR_LOG"; exit 0; }
      touch "$_IR_B"
      echo "B_IN" >> "$_IR_LOG"
      # Hold for 2 s — long enough for R to enter and check the marker.
      sleep 2 2>/dev/null || sleep 2
      command rm -f "$_IR_B"
      _aiw_unlock 2>/dev/null
    ' &
    local bp=$!
    # Wait for B to enter, then resume R.
    local _bwait=0
    while [ ! -e "$marker_B" ] && kill -0 "$bp" 2>/dev/null; do
      sleep 0.05 2>/dev/null || sleep 1
      _bwait=$(( _bwait + 1 ))
      [ "$_bwait" -ge 60 ] && break
    done
    touch "$marker_R_go"
    wait "$rp" 2>/dev/null || true
    wait "$bp" 2>/dev/null || true
  else
    # R never paused — head path (no empty file, no lock-steal).
    touch "$marker_R_go"
    wait "$rp" 2>/dev/null || true
  fi

  local overlaps
  overlaps="$(grep -c '^OVERLAP$' "$log" 2>/dev/null)" || overlaps=0
  [ "$overlaps" -eq 0 ]
}

# ================================================================
# LC_ALL containment: sourcing the writer must not leak LC_ALL=C
# ================================================================

@test "sourcing the writer with LC_ALL unset preserves unset state" {
  # The writer sources acquire-lock.sh which exports LC_ALL=C. After
  # sourcing, the caller's LC_ALL must be restored to its prior value
  # (unset, in this case). acquire_lock / release_lock must still work.
  local out
  out="$(
    unset LC_ALL
    source "$AIW_SH"
    if [ -n "${LC_ALL+set}" ]; then
      printf 'LEAKED=%s\n' "${LC_ALL}"
    else
      printf 'UNSET\n'
    fi
    # Verify the helper functions are still callable.
    local _lf="$TEST_TMP/lc-test.lock"
    GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$_lf" 5 9 2>/dev/null || true
    release_lock 9 2>/dev/null || true
    printf 'CALLABLE\n'
  )"
  [[ "$out" == *"UNSET"* ]] || {
    echo "LC_ALL was not restored after sourcing the writer: $out" >&2
    false
  }
  [[ "$out" == *"CALLABLE"* ]] || {
    echo "acquire_lock / release_lock not callable after LC_ALL restore: $out" >&2
    false
  }
}

# ================================================================
# Permanent lock failure: fails at once, not after the full timeout
# ================================================================

@test "permanent lock failure fails at once without spinning" {
  # An unwritable lock directory causes acquire_lock to return rc=1
  # immediately. The writer wrapper must not spin for the full timeout;
  # it must fail at once with a descriptive reason.
  source "$AIW_SH"

  local target="$TEST_TMP/perm-fail.yaml"
  _seed_file "$target" 1

  # Create the lock directory and make it unwritable.
  local lock_dir="$TEST_TMP/unwritable-lock"
  mkdir -p "$lock_dir"
  chmod 000 "$lock_dir"

  local lock_file="$lock_dir/perm-fail.lock"
  local start_epoch out rc
  start_epoch="$(date +%s)"
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=5 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "perm-test" 2>/dev/null
  )" && rc=0 || rc=$?
  local elapsed=$(( $(date +%s) - start_epoch ))

  # Restore permissions for cleanup.
  chmod 755 "$lock_dir"

  # Must fail.
  [ "$rc" -ne 0 ] || {
    echo "expected failure but got rc=0" >&2
    false
  }

  # Must finish well before the 5 s timeout (< 3 s).
  [ "$elapsed" -lt 3 ] || {
    echo "spent $elapsed seconds — spun for the full timeout instead of failing at once" >&2
    false
  }

  # Reason must NOT be "lock timeout" or "parallel execution requires flock".
  [[ "$out" != *"lock timeout"* ]] || {
    echo "reported 'lock timeout' for a permanent failure: $out" >&2
    false
  }
  [[ "$out" != *"parallel execution requires flock"* ]] || {
    echo "reported 'parallel execution requires flock' for a permanent failure: $out" >&2
    false
  }
}

# ================================================================
# Publication refusal retry: total wait never exceeds one timeout
# ================================================================

@test "publication refusal retries within remaining deadline only" {
  # A late publication refusal must not restart the full timeout.
  # The test holds a live lock so every acquire_lock attempt waits for
  # the full timeout. The wrapper acquire_lock is shimmed so the FIRST
  # call burns most of the budget as a publication refusal (rc=1).
  # Under the current code, _aiw_lock retries with the FULL timeout
  # again (3 s), so total elapsed approaches 2 * 3 = 6 s. After the fix
  # (remaining-deadline), the second call gets only the leftover budget
  # and the total stays near 3 s.
  source "$AIW_SH"
  source "$LOCK_LIB"

  local lock_file="$TEST_TMP/pub-retry.lock"

  # Hold the lock so every real acquire_lock attempt blocks until timeout.
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lock_file" 120 7

  local n_calls_file="$TEST_TMP/pub-retry-calls"
  printf '0' > "$n_calls_file"
  eval "_real_$(declare -f acquire_lock)"
  acquire_lock() {
    local _nc
    _nc="$(cat "$n_calls_file")"
    _nc=$((_nc + 1))
    printf '%s' "$_nc" > "$n_calls_file"
    if [ "$_nc" -eq 1 ]; then
      # Simulate a late publication refusal: burn 2 s of the 3 s budget.
      sleep 2 2>/dev/null || sleep 2
      printf 'acquire-lock: refusing a lock that did not publish at %s\n' "$1" >&2
      return "$ACQUIRE_LOCK_EXIT_PUBLISH"
    fi
    # Subsequent calls go to the real acquire_lock (which will time out
    # because the lock is held).
    _real_acquire_lock "$@"
  }

  local start_epoch out rc
  start_epoch="$(date +%s)"
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=3 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "pub-retry-test" 2>/dev/null
  )" && rc=0 || rc=$?
  local elapsed=$(( $(date +%s) - start_epoch ))
  local total_calls
  total_calls="$(cat "$n_calls_file")"

  release_lock 7

  # At least one retry must have happened (total_calls >= 2).
  [ "$total_calls" -ge 2 ] || {
    echo "expected at least one retry but acquire_lock was called only $total_calls times" >&2
    false
  }

  # With the doubled-wait bug, total elapsed approaches 2 + 3 = 5 s.
  # After the fix, it should be about 2 + 1 = 3 s (original budget).
  # Measured 10 runs: all 3 s. Threshold < 4 s catches the bug with margin.
  [ "$elapsed" -lt 4 ] || {
    echo "elapsed $elapsed s — the retry restarted with the full timeout (doubled-wait bug)" >&2
    false
  }
}

# ================================================================
# Parallel execution: permission denied must not say "requires flock"
# ================================================================

@test "flock present but permission denied does not say requires flock" {
  # When GAIA_PARALLEL_EXECUTION=1 and flock IS present, a non-flock
  # failure (permission denied) must report the real reason, not
  # "parallel execution requires flock".
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi

  source "$AIW_SH"

  # Wrap acquire_lock to simulate a permission-denied failure (rc=1).
  eval "_real_$(declare -f acquire_lock)"
  acquire_lock() {
    printf 'acquire-lock: permission denied opening lock file: %s\n' "$1" >&2
    return 1
  }

  local out
  out="$(
    GAIA_PARALLEL_EXECUTION=1 GAIA_AIW_LOCK_TIMEOUT=1 \
    _aiw_lock "$TEST_TMP/pe-test.lock" "pe-test" 2>/dev/null
  )" && rc=0 || rc=$?

  [ "$rc" -ne 0 ] || {
    echo "expected failure but got rc=0" >&2
    false
  }

  # The reason must NOT say "parallel execution requires flock" since
  # flock IS present — the failure was permission denied.
  [[ "$out" != *"parallel execution requires flock"* ]] || {
    echo "incorrectly reported 'parallel execution requires flock': $out" >&2
    false
  }
}

# ================================================================
# Legacy .lockdir cleanup timing
# ================================================================

@test "legacy lockdir left untouched by the writer (never auto-removed)" {
  # Approved behaviour: the writer never removes a legacy .lockdir.
  # Leftover directories are cleared only by documented manual recovery
  # after stopping all processes.
  source "$AIW_SH"
  source "$LOCK_LIB"

  local target="$TEST_TMP/lockdir-timing.yaml"
  _seed_file "$target" 1
  local lock_file="${target}.lock"
  local lockdir="${target}.lockdir"

  # Create a legacy .lockdir.
  mkdir -p "$lockdir"

  # Hold the lock so _aiw_lock times out.
  GAIA_LOCK_FORCE_FALLBACK=1 acquire_lock "$lock_file" 120 7

  local rc=0
  GAIA_AIW_LOCK_TIMEOUT=1 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "lockdir-test" >/dev/null 2>/dev/null \
    && rc=0 || rc=$?

  # After a failed acquire, the .lockdir must still exist.
  [ -d "$lockdir" ] || {
    echo ".lockdir was removed during a failed acquire" >&2
    release_lock 7
    false
  }

  release_lock 7

  # Acquire successfully — call _aiw_lock in the main shell (not a
  # subshell) so _aiw_unlock can release the same fd.
  rc=0
  GAIA_AIW_LOCK_TIMEOUT=5 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "lockdir-test" >/dev/null 2>/dev/null \
    && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || {
    echo "acquire failed unexpectedly (rc=$rc)" >&2; false; }

  # The .lockdir is left untouched after a successful acquire.
  [ -d "$lockdir" ] || {
    echo ".lockdir was removed after successful acquire — writer must never auto-remove it" >&2
    _aiw_unlock; false
  }

  _aiw_unlock

  # The writer acquires normally even with a legacy .lockdir present.
  rc=0
  GAIA_AIW_LOCK_TIMEOUT=5 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "lockdir-test-2" >/dev/null 2>/dev/null \
    && rc=0 || rc=$?

  [ "$rc" -eq 0 ] || {
    echo "second acquire failed with .lockdir present (rc=$rc)" >&2; false; }
  [ -d "$lockdir" ] || {
    echo ".lockdir was removed on second acquire" >&2; _aiw_unlock; false; }
  _aiw_unlock
}

# ================================================================
# Comment hygiene guard: no bare commit hashes or branch refs
# ================================================================

@test "no bare commit hashes or branch refs in lock test comments" {
  # Scan comment lines (first non-blank char is #) of the two lock test
  # files this story touches for leaked identifiers.
  local files=(
    "$BATS_TEST_DIRNAME/action-items-write-lock.bats"
    "$BATS_TEST_DIRNAME/lock-helper.bats"
  )
  local violations="" f
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Extract comment lines (first non-blank character is #).
    local comments
    comments="$(grep '^[[:space:]]*#' "$f")" || continue

    # Check for 7+ character standalone lowercase hex tokens containing
    # at least one letter a-f (bare commit hashes). Word boundaries (\b)
    # exclude hex-like substrings of English words (e.g. "succeeded").
    # Strip sha256:<hex> tokens BEFORE extracting, so the filter actually
    # removes them (grep -v after grep -oE would not match the prefix).
    local hex_hits
    hex_hits="$(echo "$comments" | sed 's/sha256:[0-9a-f]*/SHA_REDACTED/g' | grep -noE '\b[0-9a-f]{7,}\b' | grep '[a-f]')" || hex_hits=""
    if [ -n "$hex_hits" ]; then
      violations="${violations}$(basename "$f"): bare hex tokens:\n${hex_hits}\n"
    fi

    # Check for git branch references: origin/<word> or quoted branch names.
    local branch_hits
    branch_hits="$(echo "$comments" | grep -noE 'origin/[[:alnum:]_-]+' )" || branch_hits=""
    if [ -n "$branch_hits" ]; then
      violations="${violations}$(basename "$f"): origin/ references:\n${branch_hits}\n"
    fi
    local quoted_branch_hits
    quoted_branch_hits="$(echo "$comments" | grep -noE '['\''"\x60](staging|main|master)['\''"\x60]')" || quoted_branch_hits=""
    if [ -n "$quoted_branch_hits" ]; then
      violations="${violations}$(basename "$f"): quoted branch names:\n${quoted_branch_hits}\n"
    fi
  done

  if [ -n "$violations" ]; then
    printf 'Comment hygiene violations found:\n%b' "$violations" >&2
    false
  fi
}

# ================================================================
# Permanent path-type failure: a non-regular, uncleanable entry at
# the lock path must fail fast with the reason, not "lock timeout".
# ================================================================

@test "non-regular uncleanable entry at lock path fails fast with reason" {
  # A non-empty directory at the lock path is a permanent failure:
  # the helper cannot clear it and must not spin until timeout.
  source "$AIW_SH"

  local target="$TEST_TMP/pathtype-perm.yaml"
  _seed_file "$target" 1
  local lock_file="${target}.lock"

  # Create a non-empty directory at the lock path.
  mkdir -p "$lock_file"
  printf 'planted\n' > "$lock_file/occupant.txt"

  local start_epoch out rc
  start_epoch="$(date +%s)"
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=4 GAIA_LOCK_FORCE_FALLBACK=1 \
    _aiw_lock "$lock_file" "pathtype-test" 2>/dev/null
  )" && rc=0 || rc=$?
  local elapsed=$(( $(date +%s) - start_epoch ))

  # Clean up the planted directory.
  rm -rf "$lock_file"

  # Must fail.
  [ "$rc" -ne 0 ] || {
    echo "expected failure but got rc=0" >&2
    false
  }

  # Must finish well before the 4 s timeout (< 2 s).
  [ "$elapsed" -lt 2 ] || {
    echo "spent $elapsed s — spun for the full timeout instead of failing at once" >&2
    false
  }

  # Reason must NOT be "lock timeout".
  [[ "$out" != *"lock timeout"* ]] || {
    echo "reported 'lock timeout' for a permanent path-type failure: $out" >&2
    false
  }

  # Reason should mention the actual problem.
  [[ "$out" == *"status=error"* ]] || {
    echo "no status=error in output: $out" >&2
    false
  }
}

# ================================================================
# Writer-level reap-mutex diagnostic: stderr must forward the
# helper's diagnostic naming the .reap-mtx file and the remedy.
# ================================================================

@test "writer timeout forwards the reap-mutex diagnostic to stderr" {
  source "$AIW_SH"

  local lock_file="$TEST_TMP/mtx-diag-writer.yaml.lock"
  local mutex="${lock_file}.reap-mtx"
  local lock_dir
  lock_dir="$(dirname "$lock_file")"
  mkdir -p "$lock_dir"

  # Plant a stale lock (dead PID, backdated).
  printf '99999 1000000000\n' > "$lock_file"
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    touch -d '2020-01-01' "$lock_file"
  else
    touch -t 202001010000 "$lock_file"
  fi

  # Plant a dead-owner reap mutex.
  printf '99999 dead-nonce\n' > "$mutex"

  # Call _aiw_lock capturing stdout and stderr separately.
  local out="" err="" rc=0
  out="$(
    GAIA_AIW_LOCK_TIMEOUT=2 GAIA_LOCK_FORCE_FALLBACK=1 GAIA_LOCK_REAP_SECONDS=1 \
    _aiw_lock "$lock_file" "diag-test" 2>"$TEST_TMP/diag-stderr"
  )" && rc=0 || rc=$?
  err="$(cat "$TEST_TMP/diag-stderr" 2>/dev/null)"

  # Exit status must be 1 (the writer's protocol for failure).
  [ "$rc" -eq 1 ] || {
    echo "expected rc=1, got rc=$rc" >&2; false; }

  # Stdout: exactly the two-line status=error / reason=...lock timeout protocol.
  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ] || {
    echo "stdout line 1: expected 'status=error', got '$line1'" >&2; false; }
  [[ "$line2" == reason=*"lock timeout"* ]] || {
    echo "stdout line 2: expected lock timeout reason, got '$line2'" >&2; false; }

  # Stderr: must contain the exact .reap-mtx path.
  [[ "$err" == *"$mutex"* ]] || {
    echo "stderr does not name the reap-mutex path: $err" >&2; false; }

  # Stderr: must contain the stop/quiesce-first remedy.
  [[ "$err" == *"stop or quiesce"* ]] || {
    echo "stderr does not give the quiesce-first remedy: $err" >&2; false; }

  rm -f "$mutex" "$lock_file"
}

# ================================================================
# Increment-vs-writer contention
# ================================================================

INCREMENT_SH="$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts/action-items-increment.sh"

_seed_increment_file() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  # The awk in the increment script sets in_target=1 on the theme_hash
  # line, so escalation_count must appear AFTER theme_hash for the
  # match to work. This matches the canonical writer's output order.
  {
    printf 'items:\n'
    printf '  - id: "AI-1"\n'
    printf '    sprint_id: "sprint-99"\n'
    printf '    text: "Test item"\n'
    printf '    classification: "implementation"\n'
    printf '    status: "open"\n'
    printf '    theme_hash: "sha256:abc123"\n'
    printf '    escalation_count: 0\n'
    printf '    story_key: "STORY-1"\n'
  } > "$target"
}

@test "increment and writer contention preserves all updates (fallback)" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }
  source "$AIW_SH"

  # Place the file at the allowlisted path so the increment's boundary
  # check passes.
  local proj_root="$TEST_TMP/incr-proj"
  mkdir -p "$proj_root/.gaia/state"
  local target="$proj_root/.gaia/state/action-items.yaml"
  _seed_increment_file "$target"

  local pids=()
  (
    unset GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_FORCE_FALLBACK=1 PROJECT_ROOT="$proj_root"
    bash "$INCREMENT_SH" --file "$target" --theme-hash "abc123" --sprint-id "sprint-100" 2>/dev/null
  ) &
  pids+=($!)
  (
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "$AIW_SH"
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "Contention item" \
      --ref-key story_key --ref-value "STORY-2" > /dev/null 2>&1
  ) &
  pids+=($!)
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  local esc_count
  esc_count="$(grep 'escalation_count:' "$target" | head -1 | tr -dc '0-9')"
  [ "$esc_count" = "1" ] || {
    echo "escalation_count not bumped: got $esc_count" >&2; false; }
  grep -q 'Contention item' "$target" || {
    echo "writer append lost during contention" >&2; false; }
}

@test "after normal completion no lock file blocks the next no-flock acquirer" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }
  source "$AIW_SH"

  local proj_root="$TEST_TMP/incr-noleak-proj"
  mkdir -p "$proj_root/.gaia/state"
  local target="$proj_root/.gaia/state/action-items.yaml"
  _seed_increment_file "$target"
  local ledger="${target}.escalation-ledger"
  : > "$ledger"
  local lock_file="${target}.lock"

  PROJECT_ROOT="$proj_root" GAIA_LOCK_FORCE_FALLBACK=1 bash "$INCREMENT_SH" \
    --file "$target" --theme-hash "abc123" --sprint-id "sprint-100" 2>/dev/null

  [ ! -f "$lock_file" ] || {
    echo "lock file left behind after increment: $(cat "$lock_file")" >&2; false; }

  local out
  out="$(
    GAIA_LOCK_FORCE_FALLBACK=1 \
    aiw_write --target "$target" --sprint-id sprint-99 \
      --classification implementation --text "Post-increment" \
      --ref-key story_key --ref-value "STORY-3" 2>/dev/null
  )"
  [[ "$out" == *"status=ok"* ]] || {
    echo "post-increment writer failed: $out" >&2; false; }
}

@test "writer timeout diagnostic works when mktemp fails" {
  # When mktemp fails, the writer must let helper stderr pass through
  # so the reap-mutex diagnostic reaches the caller.
  source "$AIW_SH"

  local lock_file="$TEST_TMP/mtx-diag-nomktemp.yaml.lock"
  local mutex="${lock_file}.reap-mtx"
  local lock_dir
  lock_dir="$(dirname "$lock_file")"
  mkdir -p "$lock_dir"

  # Plant a stale lock (dead PID, backdated).
  printf '99999 1000000000\n' > "$lock_file"
  if [ "$_TEST_STAT_FMT" = "gnu" ]; then
    touch -d '2020-01-01' "$lock_file"
  else
    touch -t 202001010000 "$lock_file"
  fi
  # Plant a dead-owner reap mutex.
  printf '99999 dead-nonce\n' > "$mutex"

  # Create a mktemp shim that fails only the bare (no-template) call the
  # writer uses for its stderr capture. The helper calls mktemp with a
  # template argument, so those calls pass through to the real mktemp.
  local shim_dir="$TEST_TMP/mktemp-shim"
  mkdir -p "$shim_dir"
  local real_mktemp
  real_mktemp="$(command -v mktemp)"
  cat > "$shim_dir/mktemp" <<SHIMEOF
#!/bin/sh
if [ \$# -eq 0 ]; then exit 1; fi
exec "$real_mktemp" "\$@"
SHIMEOF
  chmod +x "$shim_dir/mktemp"

  # Call _aiw_lock with the shim first on PATH, capturing stdout and stderr.
  local out="" err="" rc=0
  out="$(
    PATH="$shim_dir:$PATH" \
    GAIA_AIW_LOCK_TIMEOUT=2 GAIA_LOCK_FORCE_FALLBACK=1 GAIA_LOCK_REAP_SECONDS=1 \
    _aiw_lock "$lock_file" "nomktemp-test" 2>"$TEST_TMP/diag-stderr-nomk"
  )" && rc=0 || rc=$?
  err="$(cat "$TEST_TMP/diag-stderr-nomk" 2>/dev/null)"

  # Exit status must be 1.
  [ "$rc" -eq 1 ] || {
    echo "expected rc=1, got rc=$rc" >&2; false; }

  # Stdout: the unchanged status=error / reason=lock timeout protocol.
  local line1 line2
  line1="$(printf '%s\n' "$out" | sed -n '1p')"
  line2="$(printf '%s\n' "$out" | sed -n '2p')"
  [ "$line1" = "status=error" ] || {
    echo "stdout line 1: expected 'status=error', got '$line1'" >&2; false; }
  [[ "$line2" == reason=*"lock timeout"* ]] || {
    echo "stdout line 2: expected lock timeout reason, got '$line2'" >&2; false; }

  # Stderr: must contain the exact .reap-mtx path (passed through directly).
  [[ "$err" == *"$mutex"* ]] || {
    echo "stderr does not name the reap-mutex path: $err" >&2; false; }

  # Stderr: must contain the stop/quiesce-first remedy.
  [[ "$err" == *"stop or quiesce"* ]] || {
    echo "stderr does not give the quiesce-first remedy: $err" >&2; false; }

  rm -f "$mutex" "$lock_file"
}

# ================================================================
# Deterministic increment-vs-writer contention (cross-tool locking)
#
# Three test groups prove the increment (which sources the shared
# writer for locking) and the writer itself correctly exclude each
# other via the same lock file:
#
#   (a) Writer holds the lock (test-only hold hook); the increment
#       must NOT mutate during the hold (checksum proof); both
#       updates land afterwards.
#   (b) Short timeout while the writer holds; the increment exits
#       non-zero and the file is byte-identical afterwards.
#   (c) Reverse: the increment holds; the writer must NOT mutate
#       during the hold; both updates land afterwards.
#
# Each runs in: flock, fallback (forced + no flock on PATH), and
# mixed (one side flock, the other forced fallback).
# ================================================================

# Build a directory with symlinks to every executable on PATH except
# flock, so flock is genuinely absent at both source time and run time.
_dcont_build_noflock_path() {
  local dir="$1"
  mkdir -p "$dir"
  local _pd _f _bn OLDIFS="$IFS"; IFS=':'
  # shellcheck disable=SC2086
  for _pd in $PATH; do
    [ -d "$_pd" ] || continue
    for _f in "$_pd"/*; do
      [ -x "$_f" ] || continue
      _bn="${_f##*/}"
      [ "$_bn" = "flock" ] && continue
      [ -e "$dir/$_bn" ] || ln -sf "$_f" "$dir/$_bn" 2>/dev/null || true
    done
  done
  IFS="$OLDIFS"
}

_dcont_cksum() {
  cksum "$1" | awk '{print $1, $2}'
}

_dcont_wait_lock() {
  local lf="$1" n=0
  while [ ! -e "$lf" ] && [ "$n" -lt 60 ]; do
    sleep 0.05 2>/dev/null || sleep 1; n=$((n + 1))
  done
  sleep 0.2 2>/dev/null || sleep 1
  [ -e "$lf" ]
}

# --- (a) writer holds, increment waits ---------------------------------

@test "deterministic contention: writer holds, increment waits, both land (flock)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/da-fl"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Writer: holds lock 3 s via test hook, then appends an item.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_AIW_TEST_HOLD_SECONDS=3; source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  # Increment: blocks on the held lock.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr"
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  # During the hold window: file must be unchanged.
  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$wp" 2>/dev/null || true
  wait "$ip" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

@test "deterministic contention: writer holds, increment waits, both land (fallback no-flock)" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/da-fb"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0 nfd="$TEST_TMP/nfb-da-fb"
  cs0="$(_dcont_cksum "$t")"
  _dcont_build_noflock_path "$nfd"

  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_TEST_HOLD_SECONDS=3
    source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_LOCK_FORCE_FALLBACK=1
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$wp" 2>/dev/null || true
  wait "$ip" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

@test "deterministic contention: writer holds, increment waits, both land (mixed)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/da-mx"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Writer: flock mode.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_AIW_TEST_HOLD_SECONDS=3; source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  # Increment: forced fallback mode.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_LOCK_FORCE_FALLBACK=1
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$wp" 2>/dev/null || true
  wait "$ip" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

# --- (b) increment timeout -----------------------------------------------

@test "deterministic contention: increment timeout leaves file unchanged (flock)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/db-fl"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Writer: holds for 10 s (long enough for the increment to time out).
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_AIW_TEST_HOLD_SECONDS=10; source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Blocker" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  # Increment with 1 s timeout: must fail.
  local rc=0
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_AIW_LOCK_TIMEOUT=1
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) || rc=$?

  kill "$wp" 2>/dev/null || true; wait "$wp" 2>/dev/null || true

  [ "$rc" -ne 0 ] || { echo "increment should have failed (rc=$rc)" >&2; false; }

  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file changed after timeout: $cs0 -> $cs1" >&2; false; }
}

@test "deterministic contention: increment timeout leaves file unchanged (fallback no-flock)" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/db-fb"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0 nfd="$TEST_TMP/nfb-db-fb"
  cs0="$(_dcont_cksum "$t")"
  _dcont_build_noflock_path "$nfd"

  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_TEST_HOLD_SECONDS=10
    source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Blocker" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  local rc=0
  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_LOCK_TIMEOUT=1
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) || rc=$?

  kill "$wp" 2>/dev/null || true; wait "$wp" 2>/dev/null || true

  [ "$rc" -ne 0 ] || { echo "increment should have failed (rc=$rc)" >&2; false; }

  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file changed after timeout: $cs0 -> $cs1" >&2; false; }
}

@test "deterministic contention: increment timeout leaves file unchanged (mixed)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/db-mx"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Writer: flock, long hold.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_AIW_TEST_HOLD_SECONDS=10; source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Blocker" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  _dcont_wait_lock "$lf"

  # Increment: forced fallback, short timeout.
  local rc=0
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_LOCK_TIMEOUT=1
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) || rc=$?

  kill "$wp" 2>/dev/null || true; wait "$wp" 2>/dev/null || true

  [ "$rc" -ne 0 ] || { echo "increment should have failed (rc=$rc)" >&2; false; }

  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file changed after timeout: $cs0 -> $cs1" >&2; false; }
}

# --- (c) reverse: increment holds, writer waits --------------------------

@test "deterministic contention: increment holds, writer waits, both land (flock)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/dc-fl"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Increment: holds lock 3 s via test hook, then bumps escalation_count.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_AIW_TEST_HOLD_SECONDS=3
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  _dcont_wait_lock "$lf"

  # Writer: blocks on the held lock.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  # During the hold window: file must be unchanged.
  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$ip" 2>/dev/null || true
  wait "$wp" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

@test "deterministic contention: increment holds, writer waits, both land (fallback no-flock)" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/dc-fb"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0 nfd="$TEST_TMP/nfb-dc-fb"
  cs0="$(_dcont_cksum "$t")"
  _dcont_build_noflock_path "$nfd"

  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_TEST_HOLD_SECONDS=3
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  _dcont_wait_lock "$lf"

  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1
    source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$ip" 2>/dev/null || true
  wait "$wp" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

@test "deterministic contention: increment holds, writer waits, both land (mixed)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/dc-mx"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Increment: flock mode, holds lock 3 s.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export PROJECT_ROOT="$pr" GAIA_AIW_TEST_HOLD_SECONDS=3
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null
  ) &
  local ip=$!

  _dcont_wait_lock "$lf"

  # Writer: forced fallback mode.
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1; source "$AIW_SH"
    aiw_write --target "$t" --sprint-id sprint-99 \
      --classification implementation --text "Writer item" \
      --ref-key story_key --ref-value "STORY-2" >/dev/null 2>&1
  ) &
  local wp=$!

  sleep 1
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "mutated during hold: $cs0 -> $cs1" >&2
    kill "$wp" "$ip" 2>/dev/null || true; wait 2>/dev/null || true; false; }

  wait "$ip" 2>/dev/null || true
  wait "$wp" 2>/dev/null || true

  local ec; ec="$(grep 'escalation_count:' "$t" | head -1 | tr -dc '0-9')"
  [ "$ec" = "1" ] || { echo "esc=$ec want 1" >&2; false; }
  grep -q 'Writer item' "$t" || { echo "writer append lost" >&2; false; }
}

# ================================================================
# Signal-safe lock cleanup in the increment script
#
# When the increment is killed mid-hold (TERM or INT), the trap must:
#   (a) terminate the process with non-zero status,
#   (b) leave action-items.yaml unmodified (or atomically reverted),
#   (c) release the lock so the next acquirer proceeds at once.
# ================================================================

@test "signal cleanup: TERM during increment hold exits non-zero and releases lock (fallback)" {
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/sig-fb"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0 nfd="$TEST_TMP/nfb-sig-fb"
  cs0="$(_dcont_cksum "$t")"
  _dcont_build_noflock_path "$nfd"

  # Increment: fallback, holds lock 10 s so we can TERM it mid-hold.
  PATH="$nfd" GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_TEST_HOLD_SECONDS=10 \
    PROJECT_ROOT="$pr" \
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null &
  local ip=$!

  _dcont_wait_lock "$lf"

  # Send TERM while the increment holds the lock inside the test-hold sleep.
  kill -TERM "$ip" 2>/dev/null || true
  local wrc=0
  wait "$ip" 2>/dev/null || wrc=$?

  # (a) Process terminated with exit 143 (128 + SIGTERM).
  [ "$wrc" -ne 0 ] || {
    echo "increment should have exited non-zero after TERM (rc=$wrc)" >&2; false; }
  [ "$wrc" -eq 143 ] || {
    echo "expected exit 143, got $wrc" >&2; false; }

  # (b) File unchanged (no partial write after lock release).
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file mutated after TERM: $cs0 -> $cs1" >&2; false; }

  # (c) Next acquirer succeeds promptly (< 3 s), not after a 60 s reap.
  local start_s
  start_s="$(date +%s)"
  local acq_rc=0
  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_LOCK_REAP_SECONDS=300
    source "$LOCK_LIB"
    acquire_lock "$lf" 5 200
    release_lock 200
  ) || acq_rc=$?
  local elapsed=$(( $(date +%s) - start_s ))

  [ "$acq_rc" -eq 0 ] || {
    echo "next acquirer failed (rc=$acq_rc) after ${elapsed}s" >&2; false; }
  [ "$elapsed" -lt 3 ] || {
    echo "next acquirer took ${elapsed}s — lock was not released by signal handler" >&2; false; }

  # (d) No leftover .bak.
  [ ! -f "${t}.bak" ] || {
    echo ".bak file left behind after signal" >&2; false; }
}

@test "signal cleanup: TERM during increment hold exits non-zero and releases lock (flock)" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available"; fi
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/sig-fl"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0
  cs0="$(_dcont_cksum "$t")"

  # Increment: flock mode, holds lock 10 s.
  GAIA_AIW_TEST_HOLD_SECONDS=10 PROJECT_ROOT="$pr" \
    bash "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
      --sprint-id sprint-200 2>/dev/null &
  local ip=$!

  _dcont_wait_lock "$lf"

  kill -TERM "$ip" 2>/dev/null || true
  local wrc=0
  wait "$ip" 2>/dev/null || wrc=$?

  [ "$wrc" -ne 0 ] || {
    echo "increment should have exited non-zero after TERM (rc=$wrc)" >&2; false; }
  [ "$wrc" -eq 143 ] || {
    echo "expected exit 143, got $wrc" >&2; false; }

  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file mutated after TERM: $cs0 -> $cs1" >&2; false; }

  # In flock mode, the fd close on process exit releases the kernel lock.
  # Verify the next acquirer succeeds promptly.
  local start_s acq_rc=0
  start_s="$(date +%s)"
  (
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    source "$LOCK_LIB"
    acquire_lock "$lf" 5 200
    release_lock 200
  ) || acq_rc=$?
  local elapsed=$(( $(date +%s) - start_s ))

  [ "$acq_rc" -eq 0 ] || {
    echo "next acquirer failed (rc=$acq_rc) after ${elapsed}s" >&2; false; }
  [ "$elapsed" -lt 3 ] || {
    echo "next acquirer took ${elapsed}s — lock was not released" >&2; false; }
}

@test "signal cleanup: INT during increment hold exits 130 and releases lock (fallback)" {
  # Backgrounding with & sets SIGINT to SIG_IGN (POSIX). Bash cannot
  # re-trap a signal that was SIG_IGN at entry. Perl can reset the
  # disposition: $SIG{INT}="DEFAULT" calls sigaction(SIGINT, SIG_DFL)
  # directly, then exec replaces perl with bash (same PID).
  command -v perl >/dev/null 2>&1 || skip "perl not available"  # lint-pack:allow-skip
  [ -f "$INCREMENT_SH" ] || { echo "increment script not found: $INCREMENT_SH" >&2; false; }

  local pr="$TEST_TMP/sig-int-fb"; mkdir -p "$pr/.gaia/state"
  local t="$pr/.gaia/state/action-items.yaml"
  _seed_increment_file "$t"
  local lf="${t}.lock" cs0 nfd="$TEST_TMP/nfb-sig-int"
  cs0="$(_dcont_cksum "$t")"
  _dcont_build_noflock_path "$nfd"

  # Perl exec launcher: resets SIGINT to SIG_DFL, then replaces itself
  # with the increment (same PID). $! gives the PID to signal and wait on.
  PATH="$nfd" \
  GAIA_LOCK_FORCE_FALLBACK=1 GAIA_AIW_TEST_HOLD_SECONDS=10 \
  PROJECT_ROOT="$pr" \
  perl -e '$SIG{INT}="DEFAULT"; exec("bash", @ARGV)' \
    -- "$INCREMENT_SH" --file "$t" --theme-hash abc123 \
       --sprint-id sprint-200 2>/dev/null &
  local ip=$!

  _dcont_wait_lock "$lf"

  kill -INT "$ip" 2>/dev/null || true
  local wrc=0
  wait "$ip" 2>/dev/null || wrc=$?

  # (a) Process terminated with exit 130 (128 + SIGINT).
  [ "$wrc" -ne 0 ] || {
    echo "increment should have exited non-zero after INT (rc=$wrc)" >&2; false; }
  [ "$wrc" -eq 130 ] || {
    echo "expected exit 130, got $wrc" >&2; false; }

  # (b) File unchanged.
  local cs1; cs1="$(_dcont_cksum "$t")"
  [ "$cs1" = "$cs0" ] || {
    echo "file mutated after INT: $cs0 -> $cs1" >&2; false; }

  # (c) Next acquirer succeeds promptly (< 3 s).
  local start_s acq_rc=0
  start_s="$(date +%s)"
  (
    export PATH="$nfd"
    unset GAIA_PARALLEL_EXECUTION GAIA_WORKTREE_MODE
    export GAIA_LOCK_FORCE_FALLBACK=1 GAIA_LOCK_REAP_SECONDS=300
    source "$LOCK_LIB"
    acquire_lock "$lf" 5 200
    release_lock 200
  ) || acq_rc=$?
  local elapsed=$(( $(date +%s) - start_s ))

  [ "$acq_rc" -eq 0 ] || {
    echo "next acquirer failed (rc=$acq_rc) after ${elapsed}s" >&2; false; }
  [ "$elapsed" -lt 3 ] || {
    echo "next acquirer took ${elapsed}s — lock was not released by INT handler" >&2; false; }

  # (d) No leftover .bak.
  [ ! -f "${t}.bak" ] || {
    echo ".bak file left behind after INT" >&2; false; }
}
