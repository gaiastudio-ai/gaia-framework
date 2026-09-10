#!/usr/bin/env bats
# worktree-lifecycle.bats — per-story linked git worktree lifecycle.
#
# Covers creation (including the branch-existence dispatch that makes re-entry
# work), teardown on every exit path, the trap contract, orphan pruning with
# its fail-closed vetoes, and the post-merge working-directory restore.
#
# Every test builds a REAL throwaway git repository and REAL worktrees under
# the bats temp dir and drives the REAL library. `git` is never mocked: the
# behaviours under test (a branch ref outliving a worktree, a dirty worktree
# refusing removal, a locked record being unprunable) are git's own semantics,
# so a mock would assert nothing.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  LIB="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  DEVSTORY_SCRIPTS="$PLUGIN_ROOT/skills/gaia-dev-story/scripts"
  SHARED_SCRIPTS="$PLUGIN_ROOT/scripts"
  # Worktree mode is opt-in and enforced by the library, so tests that exercise
  # creation must switch it on explicitly. The gate tests below unset it again.
  export GAIA_WORKTREE_MODE=1
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _mk_primary_repo <dir> [initial_branch] — real repo with one commit.
# Echoes the absolute toplevel.
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

# _mk_bare_remote <dir> — a real bare repo usable as `origin`.
_mk_bare_remote() {
  local dir="$1"
  git init -q --bare "$dir"
  ( cd "$dir" && pwd )
}

# _mk_pushed_primary_repo <dir> — a primary repo whose base branch is already
# published to a real bare remote. Tests that assert a REAP must use this: with
# no remote, `--not --remotes` has an empty exclusion set, so every commit reads
# as unpushed and the unpushed-work veto would block the very reap under test.
# Using it keeps each prune test about ONE condition.
_mk_pushed_primary_repo() {
  local dir="$1"
  local primary; primary="$(_mk_primary_repo "$dir")"
  local remote; remote="$(_mk_bare_remote "${dir}-remote.git")"
  git -C "$primary" remote add origin "$remote"
  git -C "$primary" push -q -u origin HEAD
  printf '%s' "$primary"
}

# _source_lib — source the library under test, skipping cleanly if absent so a
# missing file reports as a real failure rather than a harness explosion.
_source_lib() {
  [ -f "$LIB" ] || return 1
  # shellcheck disable=SC1090
  . "$LIB"
}

# _wt_count <repo> <needle> — number of porcelain records naming the needle.
_wt_count() {
  local out
  out="$(git -C "$1" worktree list --porcelain 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -c "$2" || true
}

# ---------------------------------------------------------------------------
# Creation, export, and the branch dispatch
# ---------------------------------------------------------------------------

@test "worktree_create makes a linked worktree whose HEAD is the story feature branch (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K1-S1" "sample-slug")"
  [ -d "$wt" ]
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "feat/K1-S1-sample-slug" ]
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
}

@test "worktree path is the story key under the sibling worktree parent of the git toplevel (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local parent; parent="$(worktree_parent_dir "$primary")"
  local wt; wt="$(worktree_create "$primary" "K1-S2" "slug")"
  [ "$wt" = "$parent/K1-S2" ]
  # The worktree must be OUTSIDE the primary tree, never nested within it.
  case "$wt" in
    "$primary"/*) echo "worktree nested inside the primary tree: $wt"; return 1 ;;
  esac
}

@test "git-branch.sh run inside the created worktree takes its resume path and exits 0 (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K1-S3" "slug")"
  PROJECT_PATH="$wt" run "$DEVSTORY_SCRIPTS/git-branch.sh" "K1-S3" "slug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "worktree_create leaves PROJECT_ROOT untouched while PROJECT_PATH moves (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local state="$TEST_TMP/state-root"
  mkdir -p "$state"
  export PROJECT_ROOT="$state"
  local wt; wt="$(worktree_create "$primary" "K1-S4" "slug")"
  [ "$PROJECT_ROOT" = "$state" ]
  [ "$wt" != "$PROJECT_ROOT" ]
  [ "$wt" != "$primary" ]
}

@test "re-creating a story worktree after a clean teardown attaches the surviving branch (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K2-S1" "slug")"
  worktree_teardown "$primary" "$wt"
  # The branch ref outlives the worktree, so an unconditional -b would die here.
  run worktree_create "$primary" "K2-S1" "slug"
  [ "$status" -eq 0 ]
  [ "$(git -C "$output" rev-parse --abbrev-ref HEAD)" = "feat/K2-S1-slug" ]
}

@test "re-creating a story worktree after its orphan is pruned attaches the surviving branch (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base: the prune under test must actually reap, so the unpushed-work
  # veto must not be what decides this fixture.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K2-S2" "slug")"
  rm -rf "$wt"
  worktree_prune_stale "$primary"
  run worktree_create "$primary" "K2-S2" "slug"
  [ "$status" -eq 0 ]
  [ "$(git -C "$output" rev-parse --abbrev-ref HEAD)" = "feat/K2-S2-slug" ]
}

@test "worktree creation fails closed when the branch is checked out in another worktree (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K2-S3" "slug")"
  # Ask for the same branch at a different path.
  local other="$TEST_TMP/other-holder"
  run git -C "$primary" worktree add "$other" "feat/K2-S3-slug"
  [ "$status" -ne 0 ]
  # The library must refuse with a message naming the holding worktree.
  run worktree_branch_state "$primary" "feat/K2-S3-slug"
  [ "$status" -eq 0 ]
  [[ "$output" == checked-out:* ]]
  [[ "$output" == *"$wt"* ]]
}

@test "worktree_branch_state reports absent free and checked-out correctly (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  run worktree_branch_state "$primary" "feat/never-made"
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
  local wt; wt="$(worktree_create "$primary" "K2-S4" "slug")"
  run worktree_branch_state "$primary" "feat/K2-S4-slug"
  [ "$output" = "checked-out:$wt" ]
  worktree_teardown "$primary" "$wt"
  run worktree_branch_state "$primary" "feat/K2-S4-slug"
  [ "$output" = "free" ]
}

@test "a resumed run re-enters the recorded worktree instead of creating a second one (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K3-S1" "slug")"

  # Record the path the way the workflow does, then read it back the way the
  # owning workflow must on re-entry.
  export CHECKPOINT_ROOT="$TEST_TMP/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
  run "$SHARED_SCRIPTS/write-checkpoint.sh" gaia-dev-story 3 "worktree_path=$wt"
  [ "$status" -eq 0 ]

  run "$SHARED_SCRIPTS/resume-checkpoint.sh" read --skill gaia-dev-story --latest
  [ "$status" -eq 0 ]
  local recorded
  recorded="$(printf '%s' "$output" | jq -r '.key_variables.worktree_path')"
  [ "$recorded" = "$wt" ]

  # Re-entry must reuse it: exactly one story worktree, not two.
  run worktree_create "$primary" "K3-S1" "slug"
  [ "$status" -eq 0 ]
  [ "$output" = "$wt" ]
  [ "$(_wt_count "$primary" "^worktree ")" -eq 2 ]
}

@test "every public function in the worktree library is exercised by name in a test (AC1)" {
  [ -f "$LIB" ] || { echo "library not implemented: $LIB"; return 1; }
  local fn missing=""
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    if ! grep -rlF "$fn" "$BATS_TEST_DIRNAME" >/dev/null 2>&1; then
      missing="$missing $fn"
    fi
  done <<EOF
$(sed -n 's/^\([a-z][a-z0-9_]*\)() *{.*$/\1/p' "$LIB")
EOF
  [ -z "$missing" ] || { echo "public functions with no test reference:$missing"; return 1; }
}

# ---------------------------------------------------------------------------
# Teardown, traps, and the post-merge restore
# ---------------------------------------------------------------------------

@test "worktree_teardown removes the worktree and leaves the list clean (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K4-S1" "slug")"
  run worktree_teardown "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "teardown on a mid-flight failure leaves zero orphans (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cat > "$TEST_TMP/child.sh" <<CHILD
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
PRIMARY_CODE_TREE="$primary"
STORY_WORKTREE_PATH="\$(worktree_create "\$PRIMARY_CODE_TREE" "K4-S2" "slug")"
printf '%s\n' "\$STORY_WORKTREE_PATH" > "$TEST_TMP/wt-path"
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
exit 1
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  [ "$status" -eq 1 ]
  local wt; wt="$(cat "$TEST_TMP/wt-path")"
  [ ! -d "$wt" ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "teardown fires on INT and leaves zero orphans (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cat > "$TEST_TMP/child.sh" <<CHILD
#!/usr/bin/env bash
set -uo pipefail
. "$LIB"
PRIMARY_CODE_TREE="$primary"
STORY_WORKTREE_PATH="\$(worktree_create "\$PRIMARY_CODE_TREE" "K4-S3" "slug")"
printf '%s\n' "\$STORY_WORKTREE_PATH" > "$TEST_TMP/wt-path"
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
kill -INT \$\$
sleep 5
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  local wt; wt="$(cat "$TEST_TMP/wt-path")"
  [ ! -d "$wt" ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "teardown fires on TERM and leaves zero orphans (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cat > "$TEST_TMP/child.sh" <<CHILD
#!/usr/bin/env bash
set -uo pipefail
. "$LIB"
PRIMARY_CODE_TREE="$primary"
STORY_WORKTREE_PATH="\$(worktree_create "\$PRIMARY_CODE_TREE" "K4-S4" "slug")"
printf '%s\n' "\$STORY_WORKTREE_PATH" > "$TEST_TMP/wt-path"
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
kill -TERM \$\$
sleep 5
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  local wt; wt="$(cat "$TEST_TMP/wt-path")"
  [ ! -d "$wt" ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "teardown refuses to destroy uncommitted work and warns loudly (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K5-S1" "slug")"
  printf 'unsaved\n' > "$wt/untracked.txt"
  run --separate-stderr worktree_teardown "$primary" "$wt"
  [ "$status" -ne 0 ]
  [ -d "$wt" ]
  [ -f "$wt/untracked.txt" ]
  [[ "$stderr" == *"$wt"* ]]
}

@test "an interrupted dirty run warns exactly once across the double trap firing (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cat > "$TEST_TMP/child.sh" <<CHILD
#!/usr/bin/env bash
set -uo pipefail
. "$LIB"
PRIMARY_CODE_TREE="$primary"
STORY_WORKTREE_PATH="\$(worktree_create "\$PRIMARY_CODE_TREE" "K5-S2" "slug")"
printf 'unsaved\n' > "\$STORY_WORKTREE_PATH/untracked.txt"
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
kill -TERM \$\$
sleep 5
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run --separate-stderr "$TEST_TMP/child.sh"
  # TERM then EXIT both fire the handler; the warning must appear exactly once.
  local warnings
  warnings="$(printf '%s\n' "$stderr" | grep -c "modified or untracked" || true)"
  [ "$warnings" -eq 1 ]
}

@test "the post-merge gate runs against a valid tree after teardown (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary" staging)"
  local wt; wt="$(worktree_create "$primary" "K6-S1" "slug")"
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "K6-S1: implement the thing"
  git -C "$primary" merge --no-ff -q -m "Merge pull request: K6-S1 slug" "feat/K6-S1-slug"

  local PRIMARY_CODE_TREE="$primary"
  worktree_teardown "$PRIMARY_CODE_TREE" "$wt"
  # The restore: only after a successful removal.
  export PROJECT_PATH="$PRIMARY_CODE_TREE"

  run --separate-stderr "$DEVSTORY_SCRIPTS/verify-pr-merged.sh" "K6-S1" staging
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"cannot cd"* ]]
}

@test "the post-merge retry path stays reachable after teardown (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary" staging)"
  local wt; wt="$(worktree_create "$primary" "K6-S2" "slug")"
  worktree_teardown "$primary" "$wt"
  export PROJECT_PATH="$primary"
  # No merge commit for this key: must be the documented gate-fail code, not
  # the usage-error code a dangling working directory would produce.
  run "$DEVSTORY_SCRIPTS/verify-pr-merged.sh" "K6-S2" staging
  [ "$status" -eq 2 ]
}

@test "the teardown trap targets the captured worktree path after the restore (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local PRIMARY_CODE_TREE="$primary"
  local STORY_WORKTREE_PATH
  STORY_WORKTREE_PATH="$(worktree_create "$PRIMARY_CODE_TREE" "K6-S3" "slug")"

  # A dirty worktree makes the first removal refuse, so PROJECT_PATH stays put.
  printf 'unsaved\n' > "$STORY_WORKTREE_PATH/untracked.txt"
  run worktree_teardown "$PRIMARY_CODE_TREE" "$STORY_WORKTREE_PATH"
  [ "$status" -ne 0 ]

  # Now simulate the post-merge restore having happened anyway.
  export PROJECT_PATH="$PRIMARY_CODE_TREE"
  rm -f "$STORY_WORKTREE_PATH/untracked.txt"

  # The trap must act on the CAPTURED path, not on the live PROJECT_PATH.
  run worktree_teardown_trap "$PRIMARY_CODE_TREE" "$STORY_WORKTREE_PATH"
  [ ! -d "$STORY_WORKTREE_PATH" ]
  [ "$(_wt_count "$PRIMARY_CODE_TREE" "$STORY_WORKTREE_PATH")" -eq 0 ]
  # The primary must be untouched and still a registered work tree.
  [ -d "$PRIMARY_CODE_TREE" ]
  [ "$(_wt_count "$PRIMARY_CODE_TREE" "^worktree ")" -eq 1 ]
}

@test "teardown before the branch-deleting merge lets the local branch delete succeed (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary" staging)"
  local wt; wt="$(worktree_create "$primary" "K6-S4" "slug")"
  git -C "$primary" merge --no-ff -q -m "Merge: K6-S4" "feat/K6-S4-slug" || true
  # While the worktree is live git refuses the branch delete.
  run git -C "$primary" branch -D "feat/K6-S4-slug"
  [ "$status" -ne 0 ]
  worktree_teardown "$primary" "$wt"
  run git -C "$primary" branch -D "feat/K6-S4-slug"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pruning and its fail-closed vetoes
# ---------------------------------------------------------------------------

@test "worktree_prune_stale reaps a worktree whose directory was removed (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base: isolates the vanished-directory condition from the
  # unpushed-work veto, which would otherwise block the reap under test.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K7-S1" "slug")"
  rm -rf "$wt"
  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "worktree_prune_stale never reaps a locked live worktree (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base, so the one worktree that SHOULD be reaped is not spared by the
  # unpushed-work veto — the live/locked one must survive on its own merits.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local keep; keep="$(worktree_create "$primary" "K7-S2" "slug")"
  local gone; gone="$(worktree_create "$primary" "K7-S3" "slug")"
  rm -rf "$gone"
  worktree_prune_stale "$primary"
  [ -d "$keep" ]
  [ "$(_wt_count "$primary" "$keep")" -ge 1 ]
  [ "$(_wt_count "$primary" "$gone")" -eq 0 ]
}

@test "a story start prunes an orphan left by a killed prior run (AC-EC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base, so the orphan's branch carries NO unpushed commits: only the
  # dead-owner and vanished-directory conditions decide the reap.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # The real crash shape: created AND locked, then the directory disappears
  # with no trap having fired. Such a record is locked but NOT prunable, so a
  # plain `git worktree prune` cannot reap it.
  local wt; wt="$(worktree_create "$primary" "K7-S4" "slug")"
  local dead_pid
  dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story K7-S4 pid $dead_pid"
  rm -rf "$wt"
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]

  run worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ]
}

@test "prune never reaps a worktree whose owning process is still alive (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base, so the unpushed-work veto cannot fire and mask this one: only
  # the owner-liveness condition decides whether the record survives.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K8-S1" "slug")"
  # A process this test started, and will stop itself.
  sleep 30 &
  local live_pid=$!
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story K8-S1 pid $live_pid"
  rm -rf "$wt"
  run worktree_prune_stale "$primary"
  local still; still="$(_wt_count "$primary" "$wt")"
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  [ "$still" -ge 1 ]
}

@test "prune never reaps a worktree whose branch has unpushed commits (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local remote; remote="$(_mk_bare_remote "$TEST_TMP/remote.git")"
  git -C "$primary" remote add origin "$remote"
  git -C "$primary" push -q -u origin HEAD
  local wt; wt="$(worktree_create "$primary" "K8-S2" "slug")"
  printf 'local only\n' > "$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" commit -qm "local-only work"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story K8-S2 pid $dead_pid"
  rm -rf "$wt"
  run worktree_prune_stale "$primary"
  # Unpushed work must veto the reap even though the owner is gone.
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
}

@test "prune never touches a worktree whose lock reason it does not own (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base, so the unpushed-work veto cannot fire and mask this one: only
  # the lock-ownership condition decides whether the record survives.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "K8-S3" "slug")"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "held by an unrelated tool"
  rm -rf "$wt"
  run worktree_prune_stale "$primary"
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
}

@test "two concurrent worktree creations both succeed (AC-EC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cat > "$TEST_TMP/one.sh" <<CHILD
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
worktree_create "$primary" "\$1" "slug" > "$TEST_TMP/out-\$1"
CHILD
  chmod +x "$TEST_TMP/one.sh"
  "$TEST_TMP/one.sh" "K9-S1" &
  local p1=$!
  "$TEST_TMP/one.sh" "K9-S2" &
  local p2=$!
  wait "$p1"
  wait "$p2"
  local a b
  a="$(cat "$TEST_TMP/out-K9-S1")"
  b="$(cat "$TEST_TMP/out-K9-S2")"
  [ -d "$a" ]
  [ -d "$b" ]
  [ "$(git -C "$a" rev-parse --abbrev-ref HEAD)" = "feat/K9-S1-slug" ]
  [ "$(git -C "$b" rev-parse --abbrev-ref HEAD)" = "feat/K9-S2-slug" ]
}

# ---------------------------------------------------------------------------
# Edge cases: boundaries, slug length, dirty primary, mode gating
# ---------------------------------------------------------------------------

@test "worktree creation is refused before any git call when the parent cannot ascend (AC-EC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  # A parent that resolves to itself is the filesystem-root shape.
  run --separate-stderr worktree_validate_parent "/" "/"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
  # Nothing may have been registered as a side effect.
  [ "$(_wt_count "$primary" "^worktree ")" -eq 1 ]
}

@test "the device probe yields one numeric token shared by a directory and its child (AC-EC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local parent="$TEST_TMP/dev-probe"
  mkdir -p "$parent/child"

  local a b
  a="$(_sw_device_of "$parent")"
  b="$(_sw_device_of "$parent/child")"

  # Exactly one line. The two stat dialects disagree about what -f means: under
  # GNU it is file-SYSTEM status, so probing that dialect first prints a
  # multi-line block on the failing branch and the fallback appends the real id
  # after it. A multi-line or non-numeric value is that bug, whichever platform
  # this runs on.
  [ "$(printf '%s\n' "$a" | grep -c .)" -eq 1 ] \
    || { echo "device probe returned multiple lines: [$a]"; return 1; }
  case "$a" in
    ''|*[!0-9]*) echo "device probe returned a non-numeric token: [$a]"; return 1 ;;
  esac

  # A directory and its child are on the same filesystem, so the ids must match.
  # Under the wrong flag order they differ (the block carries free-space
  # counters that change between calls), which is what made every creation
  # refuse with a spurious cross-filesystem error.
  [ "$a" = "$b" ] \
    || { echo "same-filesystem paths reported different devices: [$a] vs [$b]"; return 1; }
}

@test "worktree creation is refused when the parent is on a different filesystem or unwritable (AC-EC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  if [ "$(id -u)" = "0" ]; then
    skip "running as root: write permission bits are advisory"
  fi
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local ro="$TEST_TMP/read-only-parent"
  mkdir -p "$ro"
  chmod 500 "$ro"
  run --separate-stderr worktree_validate_parent "$ro" "$primary"
  local rc="$status"
  chmod 700 "$ro"
  [ "$rc" -ne 0 ]
}

@test "an over-long slug is capped so the branch is still created and unique per story key (AC-EC2)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local long
  long="$(printf 'x%.0s' $(seq 1 300))"
  local a b
  a="$(worktree_create "$primary" "KA-S1" "$long")"
  b="$(worktree_create "$primary" "KA-S2" "$long")"
  local br_a br_b
  br_a="$(git -C "$a" rev-parse --abbrev-ref HEAD)"
  br_b="$(git -C "$b" rev-parse --abbrev-ref HEAD)"
  [ "${#br_a}" -lt 200 ]
  [ "$br_a" != "$br_b" ]
}

@test "a dirty primary tree warns and starts the worktree from HEAD (AC-EC3)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  printf 'modified\n' >> "$primary/seed.txt"
  printf 'extra\n' > "$primary/untracked-in-primary.txt"
  run --separate-stderr worktree_create "$primary" "KB-S1" "slug"
  [ "$status" -eq 0 ]
  [ -n "$stderr" ]
  local wt="$output"
  # The primary keeps its changes; the worktree starts clean from HEAD.
  grep -q "modified" "$primary/seed.txt"
  [ -f "$primary/untracked-in-primary.txt" ]
  [ ! -f "$wt/untracked-in-primary.txt" ]
  run grep -c "modified" "$wt/seed.txt"
  [ "$status" -ne 0 ]
}

@test "worktree creation degrades to skip-with-warning outside any git work tree (AC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local nongit="$TEST_TMP/non-git-root"
  mkdir -p "$nongit"
  ( cd "$nongit" && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
    || skip "fixture unexpectedly inside a git work tree"
  cat > "$TEST_TMP/child.sh" <<CHILD
#!/usr/bin/env bash
set -uo pipefail
. "$PLUGIN_ROOT/scripts/lib/non-git-cwd-guard.sh"
cd "$nongit"
PROJECT_PATH="$nongit"
non_git_cwd_skip "worktree-create" || { printf '%s\n' "\$PROJECT_PATH"; exit 0; }
printf 'SHOULD-NOT-REACH\n'
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run --separate-stderr "$TEST_TMP/child.sh"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped (non-git CWD)"* ]]
  [ "$output" = "$nongit" ]
}

@test "with worktree mode disabled the story path is unchanged (AC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local before_head; before_head="$(git -C "$primary" rev-parse --abbrev-ref HEAD)"

  # The predicate itself.
  ( unset GAIA_WORKTREE_MODE; ! worktree_mode_enabled )
  ( GAIA_WORKTREE_MODE=0 ; ! worktree_mode_enabled )
  ( GAIA_WORKTREE_MODE=1 ; worktree_mode_enabled )

  # The observable consequence: with the mode off, the REAL create path must
  # refuse and leave no trace -- no worktree registered, no branch ref, the
  # primary tree still on its own branch.
  unset GAIA_WORKTREE_MODE
  run --separate-stderr worktree_create "$primary" "KM-S1" "slug"
  [ "$status" -ne 0 ] || { echo "create succeeded while worktree mode was off"; return 1; }
  [ -n "$stderr" ]

  [ "$(_wt_count "$primary" "^worktree ")" -eq 1 ] \
    || { echo "a worktree was registered while the mode was off"; return 1; }
  if git -C "$primary" show-ref --verify --quiet "refs/heads/feat/KM-S1-slug"; then
    echo "a branch was created while the mode was off"
    return 1
  fi
  [ ! -d "$(dirname "$primary")/.gaia-worktrees/KM-S1" ]
  [ "$(git -C "$primary" rev-parse --abbrev-ref HEAD)" = "$before_head" ]
}

@test "no argument can bypass the mode gate (AC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  unset GAIA_WORKTREE_MODE

  # There is deliberately no "I already checked" argument. Any extra token an
  # earlier design might have honoured must be inert: the call is still refused
  # and nothing is created.
  local extra
  for extra in "--mode-checked" "--force" "1" ""; do
    run worktree_create "$primary" "KM-S2" "slug" $extra
    [ "$status" -ne 0 ] \
      || { echo "create succeeded with the mode off and extra arg: '$extra'"; return 1; }
  done
  [ "$(_wt_count "$primary" "^worktree ")" -eq 1 ]
  if git -C "$primary" show-ref --verify --quiet "refs/heads/feat/KM-S2-slug"; then
    echo "a branch was created while the mode was off"
    return 1
  fi
}

@test "a create that fails partway leaves no branch behind (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  # Occupy the target path with a plain directory so `worktree add` fails after
  # git has already created the ref.
  local parent; parent="$(worktree_parent_dir "$primary")"
  mkdir -p "$parent/KN-S1"
  printf 'in the way\n' > "$parent/KN-S1/blocker.txt"

  run worktree_create "$primary" "KN-S1" "slug"
  [ "$status" -ne 0 ]
  if git -C "$primary" show-ref --verify --quiet "refs/heads/feat/KN-S1-slug"; then
    echo "a partially-failed create left its branch ref behind"
    return 1
  fi
}

@test "a failing create never deletes a branch another worktree holds (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local branch="feat/KO-S1-slug"

  # A second worktree legitimately holds the branch this story key maps to.
  local holder="$TEST_TMP/holder"
  git -C "$primary" worktree add "$holder" -b "$branch" >/dev/null 2>&1
  git -C "$primary" show-ref --verify --quiet "refs/heads/$branch"

  # Now drive a create for the same key that cannot succeed.
  local parent; parent="$(worktree_parent_dir "$primary")"
  mkdir -p "$parent/KO-S1"
  printf 'in the way\n' > "$parent/KO-S1/blocker.txt"
  run worktree_create "$primary" "KO-S1" "slug"
  [ "$status" -ne 0 ]

  # The held branch must survive: cleanup applies only to a ref this call made
  # and that no worktree holds.
  git -C "$primary" show-ref --verify --quiet "refs/heads/$branch" \
    || { echo "a branch held by another worktree was deleted"; return 1; }
  [ -d "$holder" ]

  # Behaviourally, git refuses to delete a branch a worktree holds, so the
  # assertion above passes with or without the library's own guard. Pin the
  # guard structurally too, so removing it is visible: cleanup must be
  # conditional on the ref being free rather than an unconditional delete.
  local cleanup
  cleanup="$(awk '/cannot create worktree at .* on new branch/{found=1} found' "$LIB" | head -1)"
  grep -q 'worktree_branch_state "\$repo" "\$branch"' "$LIB" \
    || { echo "the branch cleanup lost its free-ref condition"; return 1; }
  grep -qE 'if \[ "\$\(worktree_branch_state "\$repo" "\$branch"\)" = "free" \]; then' "$LIB" \
    || { echo "branch cleanup is no longer guarded by a free-ref check"; return 1; }
}

@test "the library refuses to be executed instead of sourced (AC1)" {
  [ -f "$LIB" ] || { echo "library not implemented: $LIB"; return 1; }
  run --separate-stderr bash "$LIB"
  [ "$status" -ne 0 ] || { echo "executing the library should refuse, got exit 0"; return 1; }
  [[ "$stderr" == *"must be sourced"* ]]
}

@test "worktree_slug_cap truncates to a safe length and leaves short slugs intact (AC-EC2)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local long capped
  long="$(printf 'y%.0s' $(seq 1 300))"
  capped="$(worktree_slug_cap "$long")"
  [ "${#capped}" -le 60 ]
  [ "$(worktree_slug_cap "short-slug")" = "short-slug" ]
}
