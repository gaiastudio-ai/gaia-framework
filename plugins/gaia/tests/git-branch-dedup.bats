#!/usr/bin/env bats
# git-branch-dedup.bats — git-branch.sh respects worktree_create truncation.
#
# Regression tests: when a worktree already has a truncated-slug branch,
# git-branch.sh must detect and reuse it instead of creating a second branch
# with the full slug. When no existing branch is found, the new branch must
# use the same slug cap as worktree_create.
#
# All fixtures live in BATS_TEST_TMPDIR — no writes to the real plugin tree.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup

  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  GIT_BRANCH_SH="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/git-branch.sh"
  [ -f "$GIT_BRANCH_SH" ] || fail "git-branch.sh not found at $GIT_BRANCH_SH"

  # Source the real worktree library to get the authoritative slug cap.
  STORY_WORKTREE_SH="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  [ -f "$STORY_WORKTREE_SH" ] || fail "story-worktree.sh not found at $STORY_WORKTREE_SH"
  # shellcheck source=../scripts/lib/story-worktree.sh
  . "$STORY_WORKTREE_SH"

  # Build a throwaway bare repo (serves as "origin") and a primary clone.
  BARE="$TEST_TMP/bare.git"
  git init -q --bare "$BARE"

  PRIMARY="$TEST_TMP/primary"
  git clone -q "$BARE" "$PRIMARY"
  git -C "$PRIMARY" config user.email "test@example.invalid"
  git -C "$PRIMARY" config user.name "Test User"
  printf 'seed\n' > "$PRIMARY/seed.txt"
  git -C "$PRIMARY" add seed.txt
  git -C "$PRIMARY" commit -qm "initial commit"
  git -C "$PRIMARY" push -q origin HEAD 2>/dev/null
}

teardown() {
  # Clean up any worktrees we created during the test.
  if [ -d "${PRIMARY:-}" ]; then
    git -C "$PRIMARY" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' \
      | while IFS= read -r wt; do
          [ "$wt" != "$PRIMARY" ] && git -C "$PRIMARY" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  common_teardown
}

# Helper: create a linked worktree on a specific branch.
_mk_worktree() {
  local repo="$1" branch="$2" path="$3"
  git -C "$repo" branch "$branch" HEAD 2>/dev/null || true
  git -C "$repo" worktree add "$path" "$branch" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Worktree dedup: reuse an existing worktree branch with a truncated slug
# ---------------------------------------------------------------------------

@test "reuses existing truncated-slug branch via show-ref path" {
  local long_slug capped_slug wt_branch wt_path story_key="E900-S1"

  # A slug longer than the cap, so worktree_create would truncate it.
  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  capped_slug="$(worktree_slug_cap "$long_slug")"
  wt_branch="feat/${story_key}-${capped_slug}"

  # Create a worktree on the capped branch (simulating worktree_create).
  wt_path="$TEST_TMP/wt-${story_key}"
  _mk_worktree "$PRIMARY" "$wt_branch" "$wt_path"

  # Run git-branch.sh with the FULL (untruncated) slug.
  run env PROJECT_PATH="$wt_path" bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]

  # The capped branch name equals the computed BRANCH_NAME, so this takes the
  # show-ref path. Assert the exact output line.
  [[ "$output" == *"already exists: $wt_branch"* ]]

  # There must NOT be a branch with the full slug.
  local full_branch="feat/${story_key}-${long_slug}"
  run git -C "$wt_path" show-ref --verify "refs/heads/$full_branch"
  [ "$status" -ne 0 ]
}

@test "reuses worktree branch even when its slug differs from the cap" {
  local custom_slug wt_branch wt_path story_key="E900-S6"

  # Simulate a worktree created by an older version with a different cap:
  # the branch slug is shorter than the current cap but still a valid
  # feat/<key>-<slug> pattern.
  custom_slug="older-version-truncated-slug"
  wt_branch="feat/${story_key}-${custom_slug}"

  wt_path="$TEST_TMP/wt-${story_key}"
  _mk_worktree "$PRIMARY" "$wt_branch" "$wt_path"

  # Call git-branch.sh with a DIFFERENT slug — the dedup must detect the
  # worktree's current branch and reuse it rather than creating a new one.
  local caller_slug="a-completely-different-slug-that-the-caller-passes"
  run env PROJECT_PATH="$wt_path" bash "$GIT_BRANCH_SH" "$story_key" "$caller_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists: $wt_branch"* ]]

  # The caller-slug branch must NOT have been created.
  local caller_branch="feat/${story_key}-${caller_slug}"
  run git -C "$wt_path" show-ref --verify "refs/heads/$caller_branch"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Key-boundary: dedup must not match a prefix of another story key
# ---------------------------------------------------------------------------

@test "does not reuse branch of a different story whose key is a prefix" {
  local wt_path story_key="E900-S1"

  # Create a worktree on feat/E900-S10-other (note: key E900-S10, not E900-S1).
  local other_branch="feat/E900-S10-other-story-slug"
  wt_path="$TEST_TMP/wt-boundary"
  _mk_worktree "$PRIMARY" "$other_branch" "$wt_path"

  # Run git-branch.sh with key E900-S1. It must NOT reuse the E900-S10 branch.
  local slug="my-real-slug"
  local expected_branch="feat/${story_key}-${slug}"
  run env PROJECT_PATH="$wt_path" bash "$GIT_BRANCH_SH" "$story_key" "$slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  # Last line must be exactly the created line — not an "already exists" reuse.
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]
}

@test "does not reuse branch when key is prefix but missing the dash separator" {
  local wt_path story_key="E900-S1"

  # E900-S1x-y looks like E900-S1 if the dash is missing from the case pattern.
  local other_branch="feat/E900-S1x-another-slug"
  wt_path="$TEST_TMP/wt-prefix"
  _mk_worktree "$PRIMARY" "$other_branch" "$wt_path"

  local slug="correct-slug"
  local expected_branch="feat/${story_key}-${slug}"
  run env PROJECT_PATH="$wt_path" bash "$GIT_BRANCH_SH" "$story_key" "$slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]
}

# ---------------------------------------------------------------------------
# Slug cap: new branch uses slug cap consistent with worktree_create
# ---------------------------------------------------------------------------

@test "new branch applies slug cap matching worktree_slug_cap" {
  local long_slug capped_slug story_key="E900-S2"

  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  capped_slug="$(worktree_slug_cap "$long_slug")"
  local expected_branch="feat/${story_key}-${capped_slug}"

  run env PROJECT_PATH="$PRIMARY" bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  # Exact last-line match — substring would let a larger cap pass.
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]

  # Verify the exact ref exists.
  run git -C "$PRIMARY" show-ref --verify "refs/heads/$expected_branch"
  [ "$status" -eq 0 ]

  # The full-slug branch must NOT exist.
  local full_branch="feat/${story_key}-${long_slug}"
  run git -C "$PRIMARY" show-ref --verify "refs/heads/$full_branch"
  [ "$status" -ne 0 ]
}

@test "new branch keeps short slug unchanged when under the limit" {
  local short_slug="fix-login-bug" story_key="E900-S3"
  local expected_branch="feat/${story_key}-${short_slug}"

  run env PROJECT_PATH="$PRIMARY" bash "$GIT_BRANCH_SH" "$story_key" "$short_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]
}

@test "slug cap agrees with worktree_slug_cap for a multibyte slug" {
  local mb_slug capped_slug story_key="E900-S8"

  # Build a slug with multibyte characters that exceeds the cap.
  mb_slug="$(printf 'caf%s-' 'é' | head -c 200 | tr -d '\n')"
  # Pad to ensure it exceeds the cap.
  mb_slug="${mb_slug}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  capped_slug="$(worktree_slug_cap "$mb_slug")"
  local expected_branch="feat/${story_key}-${capped_slug}"

  run env PROJECT_PATH="$PRIMARY" bash "$GIT_BRANCH_SH" "$story_key" "$mb_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]
}

# ---------------------------------------------------------------------------
# Exact match: existing branch with exact slug match is still detected
# ---------------------------------------------------------------------------

@test "detects existing branch with exact slug match" {
  local slug="my-feature" story_key="E900-S4"
  local branch="feat/${story_key}-${slug}"

  # Pre-create the branch
  git -C "$PRIMARY" checkout -b "$branch" 2>/dev/null
  git -C "$PRIMARY" checkout - 2>/dev/null

  run env PROJECT_PATH="$PRIMARY" bash "$GIT_BRANCH_SH" "$story_key" "$slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists: $branch"* ]]
}

# ---------------------------------------------------------------------------
# Bash 3.2 compatibility
# ---------------------------------------------------------------------------

@test "slug cap works under bash 3.2 when available" {
  # Only run if /bin/bash is 3.x (macOS default)
  local bash_ver
  bash_ver="$(/bin/bash --version 2>/dev/null | head -1 || true)"
  if [[ "$bash_ver" != *'version 3.'* ]]; then
    skip "no bash 3.2 at /bin/bash"
  fi

  local long_slug capped_slug story_key="E900-S5"
  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  capped_slug="$(worktree_slug_cap "$long_slug")"
  local expected_branch="feat/${story_key}-${capped_slug}"

  run env PROJECT_PATH="$PRIMARY" /bin/bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  local last_line="${lines[${#lines[@]}-1]}"
  [[ "$last_line" == "created: $expected_branch" ]]
}
