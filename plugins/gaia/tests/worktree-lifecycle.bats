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

# _mk_ignoring_repo <dir> — a pushed primary repo whose .gitignore excludes the
# places local state actually lives. Committing the .gitignore matters: the
# worktrees created from it inherit the rules, so a file placed there is
# invisible to a plain `status --porcelain` while still being destroyed by a
# worktree removal.
_mk_ignoring_repo() {
  local dir="$1"
  local primary; primary="$(_mk_primary_repo "$dir")"
  printf '.gaia/\nlocal.env\n' > "$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -qm "ignore local state"
  local remote; remote="$(_mk_bare_remote "${dir}-remote.git")"
  git -C "$primary" remote add origin "$remote"
  git -C "$primary" push -q -u origin HEAD
  printf '%s' "$primary"
}

# _mk_build_ignoring_repo <dir> — like _mk_ignoring_repo but also ignores the
# build-output path the discard tests use, so `coverage/` is ignored rather than
# untracked (untracked is a different refusal and would mask the case).
_mk_build_ignoring_repo() {
  local dir="$1"
  local primary; primary="$(_mk_primary_repo "$dir")"
  # `coverage/` alone matches only a real directory; a SYMLINK named coverage
  # would read as untracked instead of ignored, which is a different refusal.
  printf '.gaia/\nlocal.env\ncoverage/\ncoverage\n' > "$primary/.gitignore"
  git -C "$primary" add .gitignore
  git -C "$primary" commit -qm "ignore local and build state"
  local remote; remote="$(_mk_bare_remote "${dir}-remote.git")"
  git -C "$primary" remote add origin "$remote"
  git -C "$primary" push -q -u origin HEAD
  printf '%s' "$primary"
}

# _seed_ignored_state <worktree> — write only gitignored local state.
_seed_ignored_state() {
  mkdir -p "$1/.gaia/memory"
  printf 'resume state\n' > "$1/.gaia/memory/x"
  printf 'SECRET=1\n' > "$1/local.env"
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
  # Positive precondition: the worktree really existed and was registered, so
  # the absence assertions below prove a transition rather than a no-op.
  [ -d "$wt" ]
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
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
[ -d "\$STORY_WORKTREE_PATH" ] || exit 9
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
exit 1
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  # 1 is the child's own deliberate failure; 9 would mean its worktree was never
  # created, which would make the absence assertions below vacuous.
  [ "$status" -eq 1 ] \
    || { echo "expected the child's own failure (1), got $status"; return 1; }
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
[ -d "\$STORY_WORKTREE_PATH" ] || exit 9
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
kill -INT \$\$
sleep 5
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  # The child exits 9 if its worktree was never created, so the absence
  # assertions below cannot be satisfied by a create that did nothing.
  [ "$status" -ne 9 ] \
    || { echo "the worktree never existed, so teardown proved nothing"; return 1; }
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
[ -d "\$STORY_WORKTREE_PATH" ] || exit 9
trap 'worktree_teardown_trap "\$PRIMARY_CODE_TREE" "\$STORY_WORKTREE_PATH"' EXIT INT TERM
kill -TERM \$\$
sleep 5
CHILD
  chmod +x "$TEST_TMP/child.sh"
  run "$TEST_TMP/child.sh"
  # The child exits 9 if its worktree was never created, so the absence
  # assertions below cannot be satisfied by a create that did nothing.
  [ "$status" -ne 9 ] \
    || { echo "the worktree never existed, so teardown proved nothing"; return 1; }
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
  warnings="$(printf '%s\n' "$stderr" | grep -c "worktree kept:" || true)"
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

@test "worktree_prune_stale reaps an orphan left by a killed prior run (AC-EC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # Pushed base, so the orphan's branch carries NO unpushed commits: only the
  # dead-owner condition decides the reap.
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

@test "starting a story prunes a prior run's orphan before creating its worktree (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # A killed run's leftover: our lock, a dead owner, directory gone.
  local orphan; orphan="$(worktree_create "$primary" "KX-S1" "slug")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$orphan" 2>/dev/null || true
  git -C "$primary" worktree lock "$orphan" --reason "gaia story KX-S1 pid $dead_pid"
  rm -rf "$orphan"
  [ "$(_wt_count "$primary" "$orphan")" -ge 1 ]

  # Start a DIFFERENT story. Nothing calls the prune helper directly: the create
  # path must do it, and must do it before its own worktree appears.
  local fresh; fresh="$(worktree_create "$primary" "KX-S2" "slug")"
  [ -d "$fresh" ]
  [ "$(_wt_count "$primary" "$orphan")" -eq 0 ] \
    || { echo "starting a story did not prune the prior run's orphan"; return 1; }
}

@test "a killed run whose directory survives is reaped on the next story start (AC-EC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # The real kill shape: the process dies, so no trap runs and the checkout is
  # left fully intact on disk -- only the owner is gone.
  local wt; wt="$(worktree_create "$primary" "KY-S1" "slug")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story KY-S1 pid $dead_pid"
  [ -d "$wt" ]

  worktree_prune_stale "$primary"
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ] \
    || { echo "a killed run's intact worktree was never reaped"; return 1; }
}

@test "a killed run holding uncommitted work is kept and announced (AC-EC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KY-S2" "slug")"
  printf 'unsaved\n' > "$wt/untracked.txt"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story KY-S2 pid $dead_pid"

  run --separate-stderr worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  # Never destroyed, and never silent about it.
  [ -d "$wt" ]
  [ -f "$wt/untracked.txt" ]
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
  [[ "$stderr" == *"$wt"* ]] \
    || { echo "a kept dirty worktree was not announced"; return 1; }
}

@test "prune keeps the lock on a present worktree whose owner is gone but is dirty (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KY-S3" "slug")"
  printf 'unsaved\n' > "$wt/untracked.txt"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story KY-S3 pid $dead_pid"

  worktree_prune_stale "$primary"
  # The lock is the ownership marker the next run depends on: it must survive.
  local rec; rec="$(git -C "$primary" worktree list --porcelain | grep -A3 -F "$wt" || true)"
  printf '%s\n' "$rec" | grep -q '^locked' \
    || { echo "the lock was stripped from a kept worktree"; return 1; }
}

@test "a live process owned by another user counts as alive (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # pid 1 is alive and owned by root, so kill -0 fails with EPERM rather than
  # ESRCH. Reading only the exit status would call it dead.
  _sw_pid_alive 1 || { echo "pid 1 (alive, foreign uid) was reported dead"; return 1; }

  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KZ-S1" "slug")"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story KZ-S1 pid 1"
  rm -rf "$wt"
  worktree_prune_stale "$primary"
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "a record owned by a live foreign-uid process was reaped"; return 1; }
}

@test "the parent is refused when the device probe reports a different filesystem (AC-EC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  local parent; parent="$(worktree_parent_dir "$primary")"
  mkdir -p "$parent"

  # Same filesystem in reality, so only the comparison is under test: override
  # the probe to report two different device ids.
  _sw_device_of() { case "$1" in *"/primary") printf '111' ;; *) printf '222' ;; esac; }
  run --separate-stderr worktree_validate_parent "$parent" "$primary"
  [ "$status" -ne 0 ] \
    || { echo "a cross-filesystem parent was accepted"; return 1; }
  [[ "$stderr" == *"different filesystem"* ]]
}

@test "a killed run holding only gitignored local state is preserved and announced (AC-EC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-S1" "slug")"

  # Only ignored files. `status --porcelain` reports NOTHING here, yet
  # `git worktree remove` would delete them -- and this is where the runtime
  # tree, memory and checkpoints live, so the loss is unrecoverable.
  _seed_ignored_state "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || { echo "fixture is visibly dirty; it must be ignored-only to test this"; return 1; }

  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "gaia story KG-S1 pid $dead_pid"

  run --separate-stderr worktree_prune_stale "$primary"
  [ "$status" -eq 0 ]
  [ -d "$wt" ] || { echo "a worktree holding ignored local state was reaped"; return 1; }
  [ -f "$wt/local.env" ]
  [ -f "$wt/.gaia/memory/x" ]
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ]
  [[ "$stderr" == *"$wt"* ]] \
    || { echo "the operator was never told the worktree was kept"; return 1; }
}

@test "teardown refuses a worktree holding only gitignored local state (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-S2" "slug")"
  _seed_ignored_state "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ]

  run --separate-stderr worktree_teardown "$primary" "$wt"
  [ "$status" -ne 0 ] \
    || { echo "teardown removed a worktree holding ignored local state"; return 1; }
  [ -d "$wt" ]
  [ -f "$wt/local.env" ]
  [ -f "$wt/.gaia/memory/x" ]
  [[ "$stderr" == *"$wt"* ]]
}

@test "a forged lock reason cannot aim a reap at the primary checkout (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"

  # Independently of anything git would refuse, the primary checkout is not a
  # story worktree and must never be treated as a reap candidate.
  run _sw_reapable "$primary" "$primary" "gaia story FORGED pid $dead_pid" "refs/heads/staging"
  [ "$status" -ne 0 ] \
    || { echo "the primary checkout was accepted as a reap candidate"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$primary"
  [ "$status" -ne 0 ] \
    || { echo "teardown accepted the primary checkout"; return 1; }
  [ -d "$primary" ]
  [ -f "$primary/seed.txt" ]
}

@test "teardown refuses a path outside the story worktree parent (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local stranger="$TEST_TMP/not-ours"
  mkdir -p "$stranger"
  printf 'keep me\n' > "$stranger/file.txt"

  run --separate-stderr worktree_teardown "$primary" "$stranger"
  [ "$status" -ne 0 ]
  [ -f "$stranger/file.txt" ]
  [[ "$stderr" == *"not a story worktree"* ]]
}

@test "a foreign lock mentioning a pid is never claimed as ours (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }

  # Only the library's own reason shape yields a pid. A reason from some other
  # tool that merely contains " pid <n> " must not be claimed, or a prune would
  # unlock, delete and unregister a worktree that was never ours.
  [ -z "$(_sw_pid_from_reason 'held by other-tool pid 123 session')" ] \
    || { echo "a foreign lock reason was parsed as ours"; return 1; }
  [ -z "$(_sw_pid_from_reason 'pid 9')" ]
  [ -z "$(_sw_pid_from_reason 'gaia story K1 pid 7 extra')" ]
  [ "$(_sw_pid_from_reason 'gaia story K1-S1 pid 456')" = "456" ] \
    || { echo "our own lock reason no longer parses"; return 1; }

  # End to end: a present, clean, fully pushed worktree locked by another tool
  # survives a prune untouched.
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KF-S1" "slug")"
  git -C "$wt" push -q -u origin HEAD
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "held by other-tool pid 123 session"

  worktree_prune_stale "$primary"
  [ -d "$wt" ] \
    || { echo "another tool's worktree was deleted from disk"; return 1; }
  [ "$(_wt_count "$primary" "$wt")" -ge 1 ] \
    || { echo "another tool's worktree was unregistered"; return 1; }
  local rec; rec="$(git -C "$primary" worktree list --porcelain | grep -A3 -F "$wt" || true)"
  printf '%s\n' "$rec" | grep -q '^locked' \
    || { echo "another tool's lock was stripped"; return 1; }
}

@test "our own lock shape is still reaped after the prefix tightening (AC7)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KF-S2" "slug")"
  local dead_pid; dead_pid="$( bash -c 'echo $$' )"
  git -C "$primary" worktree unlock "$wt" 2>/dev/null || true
  git -C "$primary" worktree lock "$wt" --reason "$(_sw_lock_reason "KF-S2" "$dead_pid")"
  rm -rf "$wt"

  worktree_prune_stale "$primary"
  [ "$(_wt_count "$primary" "$wt")" -eq 0 ] \
    || { echo "our own orphan is no longer reaped"; return 1; }
}

@test "a cleanliness probe that cannot run keeps the worktree (AC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KH-S1" "slug")"

  # A probe that cannot report must never be read as "nothing to lose".
  git() { if [ "${3:-}" = "status" ] || [ "${1:-}" = "status" ]; then return 1; fi
          command git "$@"; }
  run _sw_worktree_is_clean "$primary" "$wt"
  unset -f git
  [ "$status" -ne 0 ] \
    || { echo "an unusable cleanliness probe reported the worktree clean"; return 1; }
  [ -d "$wt" ]
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

@test "a project path containing shell-special characters is handled literally (AC1)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  # A literal `|` in the path. Bookkeeping that fed the path to a text-processing
  # tool as a pattern used to abort here AFTER the worktree had been created and
  # locked, so the return code disagreed with what was on disk.
  local odd="$TEST_TMP/p|ipe"
  mkdir -p "$odd"
  local primary; primary="$(_mk_primary_repo "$odd/primary")"

  run worktree_create "$primary" "KS-S1" "slug"
  [ "$status" -eq 0 ] \
    || { echo "create failed on a path containing a pipe: $output"; return 1; }
  local wt="$output"
  [ -d "$wt" ] \
    || { echo "create reported success but no worktree exists: $wt"; return 1; }
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "feat/KS-S1-slug" ]

  # Teardown must handle the same path without complaint.
  run worktree_teardown "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
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
  if [ "$(id -u)" = "0" ]; then
    skip "running as root: write permission bits are advisory"
  fi
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"

  # A WRITABLE self-ascending fixture. Using "/" would let this pass even with
  # the ascend guard deleted, because the call would then fall through to the
  # unrelated writability refusal -- the guard under test has to be the only
  # thing that can refuse here.
  local selfdir="$TEST_TMP/self-ascend"
  mkdir -p "$selfdir"
  [ -w "$selfdir" ]

  run --separate-stderr worktree_validate_parent "$selfdir" "$selfdir"
  [ "$status" -ne 0 ] \
    || { echo "a self-ascending parent was accepted"; return 1; }
  # Assert the SPECIFIC refusal, so another guard's message cannot stand in.
  [[ "$stderr" == *"cannot ascend"* ]] \
    || { echo "expected the ascend refusal, got: $stderr"; return 1; }

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

@test "a non-git working directory degrades with its own exit code (AC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local nongit="$TEST_TMP/non-git-root"
  mkdir -p "$nongit"
  ( cd "$nongit" && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
    || skip "fixture unexpectedly inside a git work tree"

  run --separate-stderr worktree_create "$nongit" "NG-S1" "slug"
  # 3 is reserved for "nothing to isolate here", so the caller can degrade
  # instead of halting. A plain 1 would be indistinguishable from a real error.
  [ "$status" -eq 3 ] \
    || { echo "expected the non-git degradation code 3, got $status"; return 1; }
  [[ "$stderr" == *"skipped (non-git CWD)"* ]]
  [ ! -d "$nongit/.gaia-worktrees" ]
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
  # `producer | head -1` is a SIGPIPE trap inside a command substitution: head
  # closes the pipe while awk is still writing, awk dies of SIGPIPE (141), and
  # under `set -o pipefail` the substitution fails. It is timing-dependent, so
  # it surfaces on Linux/GNU and not on macOS. Let awk stop itself instead.
  local cleanup
  cleanup="$(awk '/cannot create worktree at .* on new branch/{print; exit}' "$LIB")"
  grep -q 'worktree_branch_state "\$repo" "\$branch"' "$LIB" \
    || { echo "the branch cleanup lost its free-ref condition"; return 1; }
  grep -qE 'if \[ "\$\(worktree_branch_state "\$repo" "\$branch"\)" = "free" \]; then' "$LIB" \
    || { echo "branch cleanup is no longer guarded by a free-ref check"; return 1; }
}

@test "usage errors report usage rather than an unbound variable under set -u (AC1)" {
  [ -f "$LIB" ] || { echo "library not implemented: $LIB"; return 1; }
  # The header tells callers to run with `set -euo pipefail`, and every workflow
  # fence does. Assigning positionals into locals before the arity check would
  # abort on the expansion, so the usage message would never be reached.
  local fn
  for fn in worktree_teardown worktree_branch_state worktree_prune_stale; do
    run bash -c "set -euo pipefail; . '$LIB'; $fn" 2>&1
    [[ "$output" != *"unbound variable"* ]] \
      || { echo "$fn died on an unbound positional instead of reporting usage"; return 1; }
    [[ "$output" == *"usage:"* ]] \
      || { echo "$fn did not report usage; got: $output"; return 1; }
  done
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

# ---------------------------------------------------------------------------
# Opt-in discard of ignored-only state (third teardown argument)
#
# Teardown refuses any worktree holding local state, which is the right default
# but leaves a locked directory behind on a NORMAL successful run whenever the
# story's tooling wrote an ignored file (coverage output, dependency trees).
# The opt-in third argument narrows that: ignored-only state may be discarded,
# but only after the work is provably merged, and never when the ignored set
# touches memory or checkpoint state a resumed run depends on.
#
# The classifier reads `git status --porcelain --ignored -uall -z`. Each flag is
# load-bearing and each has a test: without -uall git reports whole directories
# and a protected path is never seen; without -z git C-quotes any path holding
# a space or a non-ASCII byte, so the quoted form misses the protected match and
# falls to the discard arm. Both failures destroy data while looking correct.
# ---------------------------------------------------------------------------

# _seed_ignored_build_state <worktree> — ignored state that is safe to discard:
# build output only, no memory or checkpoint paths.
_seed_ignored_build_state() {
  mkdir -p "$1/coverage"
  printf 'lcov\n' > "$1/coverage/report.txt"
}

@test "ignored-only state is discarded when the caller opts in (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D1" "slug")"
  _seed_ignored_build_state "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || { echo "fixture is visibly dirty; it must be ignored-only"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -eq 0 ] \
    || { echo "opting in did not discard ignored-only state: $stderr"; return 1; }
  [ ! -d "$wt" ] \
    || { echo "the worktree survived an opted-in discard"; return 1; }
}

@test "ignored-only state is kept when the caller does NOT opt in (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D2" "slug")"
  _seed_ignored_build_state "$wt"

  # The default must be unchanged: discarding is something a caller asks for.
  run --separate-stderr worktree_teardown "$primary" "$wt"
  [ "$status" -ne 0 ] \
    || { echo "ignored state was discarded without the caller opting in"; return 1; }
  [ -f "$wt/coverage/report.txt" ] \
    || { echo "ignored state was destroyed on the default path"; return 1; }
}

@test "opting in never discards tracked modifications (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D3" "slug")"
  printf 'edited\n' > "$wt/seed.txt"

  # Classification must say "no" (real work present), not merely refuse:
  # today teardown refuses everything, so a refusal alone proves nothing.
  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "no" ] \
    || { echo "a worktree holding tracked work classified as '$output', not 'no'"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "opting in discarded a worktree holding tracked edits"; return 1; }
  [ -d "$wt" ]
  [ "$(cat "$wt/seed.txt")" = "edited" ] \
    || { echo "an uncommitted tracked edit was destroyed"; return 1; }
}

@test "opting in never discards untracked files (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D4" "slug")"
  printf 'new work\n' > "$wt/untracked.txt"

  # Classification must say "no" (real work present), not merely refuse:
  # today teardown refuses everything, so a refusal alone proves nothing.
  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "no" ] \
    || { echo "a worktree holding untracked work classified as '$output', not 'no'"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "opting in discarded a worktree holding untracked work"; return 1; }
  [ -f "$wt/untracked.txt" ] \
    || { echo "untracked work was destroyed"; return 1; }
}

@test "ignored memory state is protected from an opted-in discard (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D5" "slug")"
  mkdir -p "$wt/.gaia/memory"
  printf 'sidecar\n' > "$wt/.gaia/memory/sidecar.md"

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "memory state was discarded"; return 1; }
  [ -f "$wt/.gaia/memory/sidecar.md" ] \
    || { echo "sidecar memory was destroyed by an opted-in discard"; return 1; }

  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ] \
    || { echo "expected classification 'protected', got '$output'"; return 1; }
}

@test "a nested checkpoint directory is protected from an opted-in discard (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D6" "slug")"
  # Nested one level down: a glob anchored at a fixed depth would miss this.
  mkdir -p "$wt/.gaia/sub/checkpoints"
  printf '{}\n' > "$wt/.gaia/sub/checkpoints/ck.json"

  # Pin the CLASSIFICATION, not just survival: with no discard path implemented
  # at all, teardown refuses everything and a survival-only assertion passes
  # without proving the protected set is understood.
  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ] \
    || { echo "a nested checkpoint path classified as '$output', not 'protected'"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "a nested checkpoint directory was discarded"; return 1; }
  [ -f "$wt/.gaia/sub/checkpoints/ck.json" ] \
    || { echo "checkpoint state was destroyed"; return 1; }
}

@test "a protected path holding a space and a non-ASCII byte is recognised as protected (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D7" "slug")"
  mkdir -p "$wt/.gaia/memory"
  # Porcelain C-quotes both of these unless -z is passed, and a quoted path
  # parses as an ordinary relative name -- so it misses the protected match and
  # reaches the discard arm looking perfectly normal. Asserting only that the
  # directory survived would also pass if it were preserved for some unrelated
  # reason, so the CLASSIFICATION is what this pins.
  printf 'sidecar\n' > "$wt/.gaia/memory/side car.md"
  printf 'sidecar\n' > "$wt/.gaia/memory/café.md"

  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ] \
    || { echo "a C-quoted protected path classified as '$output', not 'protected'"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "a C-quoted protected path was discarded"; return 1; }
  [ -f "$wt/.gaia/memory/side car.md" ] \
    || { echo "a protected path containing a space was destroyed"; return 1; }
  [ -f "$wt/.gaia/memory/café.md" ] \
    || { echo "a protected path containing a non-ASCII byte was destroyed"; return 1; }
}

@test "an ignored symlink to a directory is preserved, not discarded (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_build_ignoring_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KG-D8" "slug")"
  # Reported as a bare entry with no trailing slash, so the unexpanded-directory
  # rule does not see it. Git unlinks the symlink rather than following it, but
  # the classifier is not entitled to rely on that.
  mkdir -p "$TEST_TMP/outside"
  printf 'data\n' > "$TEST_TMP/outside/keep.txt"
  ln -s "$TEST_TMP/outside" "$wt/coverage"

  run worktree_ignored_only "$primary" "$wt"
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ] \
    || { echo "an ignored symlink classified as '$output', not 'protected'"; return 1; }

  run --separate-stderr worktree_teardown "$primary" "$wt" --discard-ignored
  [ "$status" -ne 0 ] \
    || { echo "an ignored symlink was discarded"; return 1; }
  [ -f "$TEST_TMP/outside/keep.txt" ] \
    || { echo "the symlink target's contents were destroyed"; return 1; }
}

@test "a concurrent prune does not reap a sibling worktree being created (AC-EC4)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_pushed_primary_repo "$TEST_TMP/primary")"

  # Under slot-based execution one story's start prunes orphans while a sibling
  # is mid-create. The live sibling holds this shell's pid in its lock reason
  # and has no unpushed commits, so only the liveness veto stands between it and
  # a reap -- exactly the veto a prune must honour.
  local live; live="$(worktree_create "$primary" "KG-LIVE" "slug")"
  [ -d "$live" ] || { echo "fixture worktree was not created"; return 1; }

  # A genuine orphan from a killed run, so the prune has real work to do and a
  # no-op prune cannot pass this test by doing nothing.
  local orphan; orphan="$(worktree_create "$primary" "KG-ORPHAN" "slug2")"
  rm -rf "$orphan"

  worktree_prune_stale "$primary" &
  local pruner=$!
  local racer; racer="$(worktree_create "$primary" "KG-RACER" "slug3")" || true
  wait "$pruner" 2>/dev/null || true

  [ -d "$live" ] \
    || { echo "a live sibling worktree was reaped by a concurrent prune"; return 1; }
  [ -n "$racer" ] && [ -d "$racer" ] \
    || { echo "the worktree created during the prune did not survive"; return 1; }
  git -C "$primary" worktree list --porcelain | grep -q "$live" \
    || { echo "the live sibling lost its worktree record"; return 1; }
  git -C "$primary" worktree list --porcelain | grep -q 'KG-ORPHAN' \
    && { echo "the killed run's orphan survived the prune, so it was a no-op"; return 1; }
  return 0
}
