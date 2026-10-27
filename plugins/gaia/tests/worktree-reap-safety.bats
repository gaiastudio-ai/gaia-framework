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
# Scenario 1: worktree with unpushed commits is never reaped
# (aged so the age check does NOT short-circuit — exercises commits-ahead)
# ---------------------------------------------------------------------------

@test "a sibling with unpushed commits ahead of base is not reaped even with a dead owner" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1-S1")"

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
# Scenario 1d: a DETACHED worktree with commits is never reaped
# ---------------------------------------------------------------------------

@test "a detached worktree with commits ahead of base is not reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1D-S1")"

  # Commit, then detach HEAD so the porcelain listing has no branch line.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "story work"
  git -C "$wt" checkout --detach HEAD 2>/dev/null

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "detached worktree with commits was reaped"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "detached worktree was unregistered"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 1e: a worktree paused mid-rebase is never reaped
# ---------------------------------------------------------------------------

@test "a worktree paused mid-rebase is not reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1E-S1")"

  # Create two commits so we can pause a rebase between them.
  printf 'A\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -qm "commit A"
  printf 'B\n' > "$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -qm "commit B"

  # Start an interactive rebase that pauses on edit at the first commit.
  # Use GIT_SEQUENCE_EDITOR to rewrite the todo list.
  GIT_SEQUENCE_EDITOR="sed -i.bak 's/^pick/edit/' " \
    git -C "$wt" rebase -i HEAD~2 2>/dev/null || true

  # The worktree should be in a rebase state.  In a linked worktree .git is
  # always a file (not a directory), so checking for .git/rebase-merge would
  # always fail; the rebase state lives in the resolved git dir instead.
  local gitdir
  gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)" \
    || { echo "cannot resolve git dir for $wt"; return 1; }
  [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] \
    || { echo "rebase did not start; test fixture is broken"; return 1; }

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "mid-rebase worktree was reaped"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario 1f: missing merge-base keeps the worktree (fail closed)
# ---------------------------------------------------------------------------

@test "a worktree whose merge-base cannot be determined is kept" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R1F-S1")"

  # Create a commit on an orphan branch (no common ancestor with staging).
  git -C "$wt" checkout --orphan orphan-branch 2>/dev/null
  printf 'orphan\n' > "$wt/orphan.txt"
  git -C "$wt" add orphan.txt
  git -C "$wt" commit -qm "orphan commit"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "worktree with no merge-base was reaped"; return 1; }
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

  local wt; wt="$(_mk_aged_dead_sibling "$primary" "R4-S1")"

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
# Scenario 7: _sw_reapable rejects a worktree with commits (aged, direct)
# (aged so the age check does NOT short-circuit — exercises commits-ahead)
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects an aged worktree with commits ahead" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "R7-S1" "slug")"

  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "local work"

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local branch="refs/heads/feat/R7-S1-slug"
  local old_ts=1000000000
  local reason; reason="$(_sw_lock_reason "R7-S1" "$dead_pid")"
  reason="${reason% ts *} ts $old_ts"

  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted an aged worktree with commits"; return 1; }
}

# ---------------------------------------------------------------------------
# Timestamp extraction from lock reason
# ---------------------------------------------------------------------------

@test "_sw_ts_from_reason extracts the creation epoch from a writer-built reason" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local reason; reason="$(_sw_lock_reason "K1-S1" "12345")"
  local ts; ts="$(_sw_ts_from_reason "$reason")"
  [ -n "$ts" ] || { echo "no timestamp extracted from: $reason"; return 1; }
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
  local wt; wt="$(worktree_create "$primary" "R8-S1" "slug")"

  local rec; rec="$(git -C "$primary" worktree list --porcelain | grep -A4 -F "$wt" || true)"
  local reason; reason="$(printf '%s\n' "$rec" | grep '^locked ' || true)"
  reason="${reason#locked }"
  [[ "$reason" == *" ts "* ]] \
    || { echo "lock reason does not contain a timestamp: $reason"; return 1; }

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
  local wt; wt="$(worktree_create "$primary" "R9-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story R9-S1 pid $dead_pid"

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
  local wt; wt="$(worktree_create "$primary" "R10-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  # Re-lock with a timestamp a few seconds in the past.
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local reason; reason="$(_sw_lock_reason "R10-S1" "$dead_pid")"
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
  local wt; wt="$(_mk_dead_sibling "$primary" "R11-S1")"

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
  local wt; wt="$(worktree_create "$primary" "R12-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local reason; reason="$(_sw_lock_reason "R12-S1" "$dead_pid")"
  reason="${reason% ts *} ts 0999999999"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$reason"

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ] \
    || { echo "leading-zero timestamp caused a prune failure (exit $status)"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario: vanished directory re-create (AC1)
# ---------------------------------------------------------------------------

@test "worktree_create re-creates a worktree whose directory vanished but lock survived" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "V1-S1" "slug")"

  # Commit so the branch has history.
  printf 'data\n' > "$wt/data.txt"
  git -C "$wt" add data.txt
  git -C "$wt" commit -qm "some work"

  # Simulate directory vanishing (manual rm -rf) while the lock survives.
  rm -rf "$wt"
  [ ! -d "$wt" ] || { echo "directory was not removed"; return 1; }

  # The lock record still exists: the branch is still checked-out per porcelain.
  local state; state="$(worktree_branch_state "$primary" "feat/V1-S1-slug")"
  case "$state" in
    checked-out:*) ;;
    *) echo "expected checked-out state, got: $state"; return 1 ;;
  esac

  # worktree_create should detect the missing directory and re-create.
  run worktree_create "$primary" "V1-S1" "slug"
  [ "$status" -eq 0 ] \
    || { echo "worktree_create failed on vanished directory (exit $status): ${lines[*]}"; return 1; }
  [ -d "$wt" ] \
    || { echo "worktree was not re-created at $wt"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario: detached vanished record preserved when commits ahead (AC2)
# ---------------------------------------------------------------------------

@test "a detached vanished sibling with commits ahead is not reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "D1-S1")"

  # Commit, then detach so the porcelain listing has no branch line.
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "detached work"
  git -C "$wt" checkout --detach HEAD 2>/dev/null

  # Remove the directory; the git record and lock survive.
  rm -rf "$wt"
  [ ! -d "$wt" ] || { echo "directory was not removed"; return 1; }

  # The record should be kept because the porcelain HEAD carries commits
  # that are ahead of the base branch.
  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]

  # The record must still be registered (not pruned away).
  local count; count="$(_wt_count "$primary" "$wt")"
  [ "$count" -ge 1 ] \
    || { echo "detached vanished sibling with commits was unregistered (reaped)"; return 1; }
}

@test "a detached vanished sibling with no commits ahead IS reaped" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(_mk_aged_dead_sibling "$primary" "D2-S1")"

  # Detach without adding commits; HEAD is at the same point as base.
  git -C "$wt" checkout --detach HEAD 2>/dev/null

  # Remove the directory.
  rm -rf "$wt"
  [ ! -d "$wt" ] || { echo "directory was not removed"; return 1; }

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]

  # The record should be gone: no commits ahead, aged, dead owner, dir gone.
  local count; count="$(_wt_count "$primary" "$wt")"
  [ "$count" -eq 0 ] \
    || { echo "detached vanished sibling with no commits ahead was NOT reaped"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario: aged worktree with commits ahead survives (AC5 — ahead-check)
# The young-worktree test (scenario 6) passes on the age check alone; this
# aged variant proves the commits-ahead guard is independently exercised.
# ---------------------------------------------------------------------------

@test "_sw_reapable rejects an aged clean worktree whose branch is ahead" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "A1-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD

  # Add a commit so the branch is 1 ahead (not merged).
  printf 'ahead\n' > "$wt/ahead.txt"
  git -C "$wt" add ahead.txt
  git -C "$wt" commit -qm "unpushed ahead"

  # Re-lock with an old timestamp so the age check passes (does not protect).
  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local old_ts=1000000000
  local reason; reason="$(_sw_lock_reason "A1-S1" "$dead_pid")"
  reason="${reason% ts *} ts $old_ts"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$reason"

  local branch="refs/heads/feat/A1-S1-slug"
  run _sw_reapable "$primary" "$wt" "$reason" "$branch"
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted an aged worktree with commits ahead"; return 1; }
}

# ---------------------------------------------------------------------------
# Scenario: unreadable HEAD fails closed (AC5)
# ---------------------------------------------------------------------------

@test "_sw_reapable fails closed when the worktree HEAD cannot be read" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "UH-S1" "slug")"

  # Detach and corrupt the HEAD so git -C cannot read it.
  git -C "$wt" checkout --detach HEAD 2>/dev/null
  # Remove the .git file so rev-parse HEAD fails inside the worktree.
  rm -f "$wt/.git"
  mkdir -p "$wt/.git"

  local dead_pid; dead_pid="$( /bin/bash -c 'echo $$' )"
  local old_ts=1000000000
  local reason; reason="$(_sw_lock_reason "UH-S1" "$dead_pid")"
  reason="${reason% ts *} ts $old_ts"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$reason"

  # Call _sw_reapable with no branch (detached) — the path exists but HEAD
  # is unreadable, so the function must fail closed (return 1, keep it).
  run _sw_reapable "$primary" "$wt" "$reason" ""
  [ "$status" -ne 0 ] \
    || { echo "_sw_reapable accepted a worktree with unreadable HEAD"; return 1; }
}
