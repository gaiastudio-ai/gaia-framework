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

# The slug cap that worktree_create uses (must match the value in
# story-worktree.sh).
_SLUG_MAX=60

setup() {
  common_setup

  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  GIT_BRANCH_SH="$PLUGIN_ROOT/skills/gaia-dev-story/scripts/git-branch.sh"
  [ -f "$GIT_BRANCH_SH" ] || fail "git-branch.sh not found at $GIT_BRANCH_SH"

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

@test "reuses existing truncated-slug branch from the worktree" {
  local long_slug short_slug wt_branch wt_path story_key="E900-S1"

  # A slug longer than the cap, so worktree_create would truncate it.
  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  short_slug="${long_slug:0:$_SLUG_MAX}"
  wt_branch="feat/${story_key}-${short_slug}"

  # Simulate what worktree_create does: create a worktree on the truncated branch.
  wt_path="$TEST_TMP/wt-${story_key}"
  _mk_worktree "$PRIMARY" "$wt_branch" "$wt_path"

  # Run git-branch.sh with the FULL (untruncated) slug.
  run env PROJECT_PATH="$wt_path" bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]

  # It must report the EXISTING (truncated) branch, not create a new one.
  [[ "$output" == *"already exists: $wt_branch"* ]] || \
  [[ "$output" == *"reusing worktree branch: $wt_branch"* ]]

  # There must NOT be a branch with the full slug.
  local full_branch="feat/${story_key}-${long_slug}"
  run git -C "$wt_path" show-ref --verify "refs/heads/$full_branch"
  [ "$status" -ne 0 ]
}

@test "reuses worktree branch even when its slug differs from the cap" {
  local custom_slug wt_branch wt_path story_key="E900-S6"

  # Simulate a worktree created by an older version with a different cap:
  # the branch slug is shorter than the current 60-char cap but still a
  # valid feat/<key>-<slug> pattern.
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
# Slug cap: new branch uses slug cap consistent with worktree_create
# ---------------------------------------------------------------------------

@test "new branch applies slug cap when slug exceeds the limit" {
  local long_slug expected_slug story_key="E900-S2"

  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  expected_slug="${long_slug:0:$_SLUG_MAX}"
  local expected_branch="feat/${story_key}-${expected_slug}"

  run env PROJECT_PATH="$PRIMARY" bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$expected_branch"* ]]

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
  [[ "$output" == *"created: $expected_branch"* ]]
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
  if ! printf '%s' "$bash_ver" | grep -qF 'version 3.'; then
    skip "no bash 3.2 at /bin/bash"
  fi

  local long_slug story_key="E900-S5"
  long_slug="this-is-a-very-long-slug-that-exceeds-the-sixty-character-slug-cap-limit"
  local expected_slug="${long_slug:0:$_SLUG_MAX}"
  local expected_branch="feat/${story_key}-${expected_slug}"

  run env PROJECT_PATH="$PRIMARY" /bin/bash "$GIT_BRANCH_SH" "$story_key" "$long_slug"
  echo "status=$status"
  echo "output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$expected_branch"* ]]
}

# ---------------------------------------------------------------------------
# Fixture isolation: no writes to the real plugin tree (structural check)
# ---------------------------------------------------------------------------

@test "test fixtures use only temp directories" {
  # This test is a structural assertion: every path variable used as a git
  # repo target must be rooted under BATS_TEST_TMPDIR or TEST_TMP.
  # The litter guard in test_helper.bash also catches stray writes.
  local pattern
  pattern="$(grep -cE '^\s*(PRIMARY|BARE|wt_path)=' "$BATS_TEST_FILENAME" || true)"
  [ "$pattern" -gt 0 ]

  # None of the assignments point outside TEST_TMP
  run grep -E '^\s*(PRIMARY|BARE|wt_path)=' "$BATS_TEST_FILENAME"
  echo "$output"
  # Every assignment must reference TEST_TMP (the per-test temp dir)
  while IFS= read -r line; do
    [[ "$line" == *'TEST_TMP'* ]] || [[ "$line" == *'BATS_TEST_TMPDIR'* ]] || \
      fail "fixture path not rooted in temp dir: $line"
  done <<< "$output"
}
