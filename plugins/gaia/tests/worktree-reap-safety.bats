#!/usr/bin/env bats
# worktree-reap-safety.bats — regression tests for the worktree reap heuristic
# safety threshold.
#
# The reap heuristic must require stronger evidence than a dead owner PID
# before considering a sibling worktree an orphan.  Claude Code's one-shot
# Bash calls always exit immediately, so every owner PID is dead by the time
# the next worktree_create runs.  An age threshold prevents freshly-created
# worktrees from being mistaken for orphans.
#
# Every test builds real throwaway git repositories under $BATS_TEST_TMPDIR.
# Nothing touches the real plugin tree.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  LIB="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  export GAIA_WORKTREE_MODE=1
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers (same shape as worktree-lifecycle.bats)
# ---------------------------------------------------------------------------

_mk_primary_repo() {
  local dir="$1" branch="${2:-staging}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch" .
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test User"
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm "initial commit"
  ( cd "$dir" && pwd )
}

_mk_bare_remote() {
  local dir="$1"
  git init -q --bare "$dir"
  ( cd "$dir" && pwd )
}

_mk_pushed_primary_repo() {
  local dir="$1"
  local primary; primary="$(_mk_primary_repo "$dir")"
  local remote; remote="$(_mk_bare_remote "${dir}-remote.git")"
  git -C "$primary" remote add origin "$remote"
  git -C "$primary" push -q -u origin HEAD
  printf '%s' "$primary"
}

_source_lib() {
  [ -f "$LIB" ] || return 1
  # shellcheck disable=SC1090
  . "$LIB"
}

_wt_count() {
  local out
  out="$(git -C "$1" worktree list --porcelain 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -c "$2" || true
}

# _mk_dead_sibling <repo> <key> [slug] — create a worktree with a dead owner
# PID, simulating a one-shot Bash call that has already exited.
_mk_dead_sibling() {
  local repo="$1" key="$2" slug="${3:-slug}"
  local wt; wt="$(worktree_create "$repo" "$key" "$slug")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$repo" worktree unlock "$wt" 2>/dev/null || true
  git -C "$repo" worktree lock "$wt" --reason "$(_sw_lock_reason "$key" "$dead_pid")"
  printf '%s' "$wt"
}

# ---------------------------------------------------------------------------
# Scenario 1 (AC1): live worktree with commits is never reaped
# ---------------------------------------------------------------------------

@test "a sibling with commits ahead of base is not reaped even with a dead owner" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_dead_sibling "$primary" "R1-S1")"

  # Add a commit so the worktree has unpushed work.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "story work"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "sibling with commits was reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "sibling with commits was unregistered"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 2 (AC2): aged empty worktree with dead owner IS reaped
# ---------------------------------------------------------------------------

@test "an aged empty clean worktree with dead owner is reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_dead_sibling "$primary" "R2-S1")"

  # Make the creation look old: re-lock with a timestamp far in the past.
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  local old_epoch=1000000000  # 2001-09-09, well past any threshold
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" \
    --reason "$(_sw_lock_reason "R2-S1" "$dead_pid") ts $old_epoch"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] || { echo "aged empty worktree was not reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ] \
    || { echo "aged empty worktree record was not cleared"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 3 (AC2): fresh empty worktree with dead owner is NOT reaped
# ---------------------------------------------------------------------------

@test "a fresh empty clean worktree with dead owner is not reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_dead_sibling "$primary" "R3-S1")"

  # The worktree was just created (the lock reason carries a recent timestamp),
  # so it should survive even though its owner PID is dead and it has no commits.
  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "fresh empty worktree was reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "fresh empty worktree was unregistered"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 4 (AC3): GAIA_WORKTREE_PRUNE_ON_CREATE=0 disables all reaping
# ---------------------------------------------------------------------------

@test "GAIA_WORKTREE_PRUNE_ON_CREATE=0 prevents any sibling from being reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # Create an aged empty orphan that WOULD normally be reaped.
  local wt; wt="$(_mk_dead_sibling "$primary" "R4-S1")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  local old_epoch=1000000000
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" \
    --reason "$(_sw_lock_reason "R4-S1" "$dead_pid") ts $old_epoch"

  # With the override, creating a new story must NOT prune the orphan.
  GAIA_WORKTREE_PRUNE_ON_CREATE=0 \
    run worktree_create "$primary" "R4-S2" "slug"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "orphan was reaped despite PRUNE_ON_CREATE=0"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "orphan was unregistered despite PRUNE_ON_CREATE=0"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 5 (AC1): _sw_reapable returns non-zero for a sibling with commits
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects a worktree with unpushed commits" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R5-S1" "slug")"

  # Add a commit.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "local work"

  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  local branch="refs/heads/feat/R5-S1-slug"
  local reason; reason="$(_sw_lock_reason "R5-S1" "$dead_pid")"

  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted a worktree with unpushed commits"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 6 (AC2): _sw_reapable returns non-zero for a young worktree
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects a young worktree even when empty and clean" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R6-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  local branch="refs/heads/feat/R6-S1-slug"
  # Lock reason with a RECENT timestamp (just created).
  local reason; reason="$(_sw_lock_reason "R6-S1" "$dead_pid")"

  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted a young empty worktree"; return 1; }
}

# ---------------------------------------------------------------------------
# Timestamp extraction from lock reason
# ---------------------------------------------------------------------------

@test "_sw_ts_from_reason extracts the creation epoch from a lock reason" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local ts
  ts="$(_sw_ts_from_reason "gaia story K1-S1 pid 12345 ts 1700000000")"
  [ "$ts" = "1700000000" ] \
    || { echo "expected 1700000000, got '$ts'"; return 1; }
}

@test "_sw_ts_from_reason returns empty for a legacy lock reason without ts" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local ts
  ts="$(_sw_ts_from_reason "gaia story K1-S1 pid 12345")"
  [ -z "$ts" ] \
    || { echo "expected empty, got '$ts'"; return 1; }
}

@test "_sw_pid_from_reason still works with the new lock reason format" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local pid
  # New format with ts suffix — PID must still be extracted correctly.
  pid="$(_sw_pid_from_reason "gaia story K1-S1 pid 12345 ts 1700000000")"
  [ "$pid" = "12345" ] \
    || { echo "expected 12345, got '$pid'"; return 1; }
}

# ---------------------------------------------------------------------------
# Lock reason includes timestamp on creation
# ---------------------------------------------------------------------------

@test "worktree_create writes a lock reason that includes a creation timestamp" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R7-S1" "slug")"

  local rec; rec="$(git -C "$primary" worktree list --porcelain | grep -A4 -F "$wt" || true)"
  local reason; reason="$(printf '%s\n' "$rec" | grep '^locked ' || true)"
  reason="${reason#locked }"
  [[ "$reason" == *" ts "* ]] \
    || { echo "lock reason does not contain a timestamp: $reason"; return 1; }

  # Extract and validate the timestamp is a recent epoch.
  local ts; ts="$(_sw_ts_from_reason "$reason")"
  [ -n "$ts" ] || { echo "no timestamp parsed from reason: $reason"; return 1; }
  local now; now="$(date +%s)"
  local diff=$(( now - ts ))
  [ "$diff" -ge 0 ] && [ "$diff" -lt 60 ] \
    || { echo "timestamp $ts is not recent (diff=${diff}s from now=$now)"; return 1; }
}

# ---------------------------------------------------------------------------
# Legacy lock reasons (no timestamp) are treated as old enough to reap
# ---------------------------------------------------------------------------

@test "a worktree with a legacy lock reason and no commits is reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R8-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  # Replace lock with the old-style reason (no ts).
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story R8-S1 pid $dead_pid"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] \
    || { echo "worktree with legacy lock was not reaped"; return 1; }
}

# ---------------------------------------------------------------------------
# The default reap age threshold
# ---------------------------------------------------------------------------

@test "GAIA_WORKTREE_REAP_AGE_SECONDS overrides the default age threshold" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R9-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  # With a very short threshold (1 second), a just-created worktree should be
  # old enough to reap after a brief sleep.
  sleep 2
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  # Re-lock with the timestamp from creation (2 seconds ago).
  local ts; ts="$(( $(date +%s) - 3 ))"
  git -C "$primary" worktree lock "$wt" \
    --reason "$(_sw_lock_reason "R9-S1" "$dead_pid") ts $ts"

  GAIA_WORKTREE_REAP_AGE_SECONDS=1 run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] \
    || { echo "worktree was not reaped with short age threshold"; return 1; }
}
