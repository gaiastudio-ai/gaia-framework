#!/usr/bin/env bats
# worktree-reap-safety.bats — regression tests for the worktree reap
# heuristic safety threshold.
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

# _mk_dead_sibling <repo> <key> [slug] — create a worktree in a one-shot
# subshell (simulating Claude Code's execution model) so the owner PID is
# dead by the time it returns.  Echoes the worktree path.
_mk_dead_sibling() {
  local repo="$1" key="$2" slug="${3:-slug}"
  /bin/bash -c '
    set -euo pipefail
    . "'"$LIB"'"
    export GAIA_WORKTREE_MODE=1
    worktree_create "'"$repo"'" "'"$key"'" "'"$slug"'"
  ' 2>/dev/null
}

# _mk_aged_dead_sibling <repo> <key> [slug] — like _mk_dead_sibling but
# re-locks with a past timestamp so the worktree appears old enough to reap.
# Uses the REAL _sw_lock_reason writer to build the reason, then overwrites
# only the ts field.
_mk_aged_dead_sibling() {
  local repo="$1" key="$2" slug="${3:-slug}"
  local wt; wt="$(_mk_dead_sibling "$repo" "$key" "$slug")"
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local old_ts=1000000000  # 2001-09-09, well past any threshold
  # Build the reason with the real writer, then replace just the ts value.
  local reason; reason="$(_sw_lock_reason "$key" "$dead_pid")"
  reason="${reason% ts *} ts $old_ts"
  git -C "$repo" worktree unlock "$wt" 2>/dev/null || true
  git -C "$repo" worktree lock "$wt" --reason "$reason"
  printf '%s' "$wt"
}

# ---------------------------------------------------------------------------
# Scenario 1: live worktree with unpushed commits is never reaped
# ---------------------------------------------------------------------------

@test "a sibling with unpushed commits ahead of base is not reaped even with a dead owner" {
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
# Scenario 1b: a PUSHED branch with commits ahead of base is never reaped
# ---------------------------------------------------------------------------

@test "a sibling whose pushed branch is ahead of base is not reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1B-S1")"

  # Commit AND push, so --not --remotes would see 0 unpushed, but the branch
  # is still ahead of the base.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "story work"
  git -C "$wt" push -q -u origin HEAD

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "pushed-but-ahead sibling was reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "pushed-but-ahead sibling was unregistered"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 1c: a fully merged branch (0 commits ahead) MAY be reaped
# ---------------------------------------------------------------------------

@test "a fully merged branch with aged dead owner is reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1C-S1")"

  # Commit, push, then merge into the base so the branch is at 0 ahead.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "story work"
  git -C "$wt" push -q -u origin HEAD
  git -C "$primary" merge --no-edit "feat/R1C-S1-slug" -q

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] || { echo "fully merged worktree was not reaped"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 2: aged empty worktree with dead owner IS reaped
# ---------------------------------------------------------------------------

@test "an aged empty clean worktree with dead owner is reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R2-S1")"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] || { echo "aged empty worktree was not reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ] \
    || { echo "aged empty worktree record was not cleared"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 3: fresh empty worktree with dead owner is NOT reaped
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
# Scenario 4: GAIA_WORKTREE_PRUNE_ON_CREATE=0 disables all reaping
# ---------------------------------------------------------------------------

@test "GAIA_WORKTREE_PRUNE_ON_CREATE=0 prevents any sibling from being reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # Create an aged empty orphan that WOULD normally be reaped.
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R4-S1")"

  # With the override, creating a new story must NOT prune the orphan.
  GAIA_WORKTREE_PRUNE_ON_CREATE=0 \
    run worktree_create "$primary" "R4-S2" "slug"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "orphan was reaped despite PRUNE_ON_CREATE=0"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "orphan was unregistered despite PRUNE_ON_CREATE=0"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 5: _sw_reapable rejects a worktree with commits
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects a worktree with unpushed commits" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R5-S1" "slug")"

  # Add a commit.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "local work"

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local branch="refs/heads/feat/R5-S1-slug"
  local reason; reason="$(_sw_lock_reason "R5-S1" "$dead_pid")"

  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted a worktree with unpushed commits"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 6: _sw_reapable rejects a young worktree
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects a young worktree even when empty and clean" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R6-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local branch="refs/heads/feat/R6-S1-slug"
  local reason; reason="$(_sw_lock_reason "R6-S1" "$dead_pid")"

  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted a young empty worktree"; return 1; }
}

# ---------------------------------------------------------------------------
# Timestamp extraction from lock reason
# ---------------------------------------------------------------------------

@test "_sw_ts_from_reason extracts the creation epoch from a writer-built reason" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local reason; reason="$(_sw_lock_reason "K1-S1" "12345")"
  local ts; ts="$(_sw_ts_from_reason "$reason")"
  [ -n "$ts" ] || { echo "no timestamp extracted from: $reason"; return 1; }
  # Must be a recent epoch (within 60 seconds of now).
  local now; now="$(date +%s)"
  local diff=$(( now - ts ))
  [ "$diff" -ge 0 ] && [ "$diff" -lt 60 ] \
    || { echo "timestamp $ts not recent (diff=${diff}s)"; return 1; }
}

@test "_sw_ts_from_reason returns empty for a legacy lock reason without ts" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local ts
  ts="$(_sw_ts_from_reason "gaia story K1-S1 pid 12345")"
  [ -z "$ts" ] \
    || { echo "expected empty, got '$ts'"; return 1; }
}

@test "_sw_pid_from_reason still works with a writer-built reason" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local reason; reason="$(_sw_lock_reason "K1-S1" "12345")"
  local pid; pid="$(_sw_pid_from_reason "$reason")"
  [ "$pid" = "12345" ] \
    || { echo "expected 12345, got '$pid' from reason: $reason"; return 1; }
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
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
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

  # Re-lock with a timestamp 3 seconds in the past (via the real writer shape).
  sleep 2
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local reason; reason="$(_sw_lock_reason "R9-S1" "$dead_pid")"
  local old_ts=$(( $(date +%s) - 3 ))
  reason="${reason% ts *} ts $old_ts"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$reason"

  GAIA_WORKTREE_REAP_AGE_SECONDS=1 run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ] \
    || { echo "worktree was not reaped with short age threshold"; return 1; }
}

# ---------------------------------------------------------------------------
# Non-integer GAIA_WORKTREE_REAP_AGE_SECONDS falls back to default (fail closed)
# ---------------------------------------------------------------------------

@test "a non-integer reap age threshold falls back to the default and keeps a fresh worktree" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_dead_sibling "$primary" "R10-S1")"

  # "30m" is not an integer -- the age check must not be skipped.
  GAIA_WORKTREE_REAP_AGE_SECONDS=30m run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] \
    || { echo "fresh worktree was reaped with non-integer threshold '30m'"; return 1; }
}

# ---------------------------------------------------------------------------
# Leading-zero timestamps do not cause an octal arithmetic error
# ---------------------------------------------------------------------------

@test "a leading-zero timestamp does not abort worktree_create" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R11-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  # Re-lock with a ts that has a leading zero (octal-hostile).
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local reason; reason="$(_sw_lock_reason "R11-S1" "$dead_pid")"
  reason="${reason% ts *} ts 0999999999"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$reason"

  # Must not abort (the old epoch makes it reapable, but the point is no crash).
  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ] \
    || { echo "leading-zero timestamp caused a prune failure (exit $status)"; return 1; }
}
