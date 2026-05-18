#!/usr/bin/env bats
# release-commit-range.bats — coverage for resolve-release-anchor.sh
#
# Story: E40-S2 — Anchor release.yml commit-classification range on most-recent v* tag
# Traces: AC1, AC2, AC3, AC4(a-d)
# Origin: docs/creative-artifacts/meeting-2026-05-15-ci-review-section-deploy-versioning-redesign.md
#
# The helper at plugins/gaia/scripts/lib/resolve-release-anchor.sh emits the
# commit-range BEFORE anchor for release.yml. Algorithm:
#
#   BEFORE = git describe --tags --abbrev=0 --match 'v*' 2>/dev/null
#            || git rev-list --max-parents=0 HEAD
#
# This file exercises four scenarios that must produce deterministic output
# regardless of merge strategy (squash / rebase / force-push) or first-release
# state (no v* tag yet).

load 'test_helper.bash'

setup() {
  common_setup
  ANCHOR_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/resolve-release-anchor.sh"
  cd "$TEST_TMP"
  # Each scenario stands up its own git repo (per architect's bats pattern note —
  # no shared git-fixture helpers in test_helper.bash).
}

teardown() { common_teardown; }

# Stand up a fresh git repo with a configured identity (required for commits).
_init_repo() {
  git init -q
  git config user.email "test@gaia.local"
  git config user.name  "Test User"
  git config commit.gpgsign false
}

# Make a commit with a specified Conventional Commit subject.
_commit() {
  local subject="$1"
  echo "$RANDOM" > "file-${RANDOM}.txt"
  git add -A
  git commit -q -m "$subject"
}

# AC4(a) — Standard squash merge with a feat: commit since the last v* tag.
# Expected: resolve-release-anchor.sh emits the v* tag name (which git log
# accepts as a revision identifier just like a SHA).
@test "AC4a: standard squash — emits v* tag name when tag exists and feat commit follows" {
  _init_repo
  _commit "chore: initial commit"
  _commit "chore(release): v1.0.0"
  git tag v1.0.0
  _commit "feat: add a feature"

  run bash "$ANCHOR_SCRIPT"
  [ "$status" -eq 0 ]
  # Output should be "v1.0.0" — `git describe --abbrev=0` returns the tag NAME.
  [ "$output" = "v1.0.0" ]
  # And that name resolves correctly via git rev-parse for the range expression.
  expected_sha="$(git rev-parse "$output")"
  tag_sha="$(git rev-parse v1.0.0)"
  [ "$expected_sha" = "$tag_sha" ]
}

# AC4(b) — Force-push retry: same commit range, second invocation yields
# identical anchor. The tag SHA does not change across re-invocations.
@test "AC4b: force-push retry — same anchor SHA across multiple invocations" {
  _init_repo
  _commit "chore: initial commit"
  _commit "chore(release): v1.0.0"
  git tag v1.0.0
  _commit "feat: add a feature"

  first="$(bash "$ANCHOR_SCRIPT")"
  second="$(bash "$ANCHOR_SCRIPT")"
  third="$(bash "$ANCHOR_SCRIPT")"

  [ -n "$first" ]
  [ "$first" = "$second" ]
  [ "$second" = "$third" ]
}

# AC4(c) — First-release fallback: no v* tag exists yet. The helper falls
# through to git rev-list --max-parents=0 HEAD (the root commit).
@test "AC4c: first-release fallback — emits root commit SHA when no v* tag exists" {
  _init_repo
  _commit "chore: initial commit"
  _commit "feat: first feature, no tag yet"
  _commit "fix: a fix, still no tag"

  run bash "$ANCHOR_SCRIPT"
  [ "$status" -eq 0 ]
  # Output should be the root commit SHA.
  root_sha="$(git rev-list --max-parents=0 HEAD)"
  [ "$output" = "$root_sha" ]
}

# AC4(d) — Mixed bump sizes: the helper's job is the ANCHOR, not the
# classification. So this test verifies the anchor is correct when the
# range covers a mix of feat: and fix: commits. (The actual precedence
# resolution lives in classify-commits.js — verified separately at
# classify-commits.js L79-95.)
@test "AC4d: mixed bump sizes — anchor is the v* tag name, range contains feat+fix+chore" {
  _init_repo
  _commit "chore: initial commit"
  _commit "chore(release): v1.0.0"
  git tag v1.0.0
  _commit "feat: a feature"
  _commit "fix: a fix"
  _commit "chore: docs"

  run bash "$ANCHOR_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.0.0" ]

  # Verify the range between the anchor and HEAD contains all three commits.
  # `git log` accepts the tag name as a revision identifier identically to a SHA.
  range_count="$(git log --format='%H' "$output..HEAD" | wc -l | tr -d '[:space:]')"
  [ "$range_count" = "3" ]
}
