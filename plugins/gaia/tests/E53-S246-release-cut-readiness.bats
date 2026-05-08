#!/usr/bin/env bats
#
# E53-S246: Cut plugin release v1.135 bundling E53-S234 non-git-cwd-guard
#
# This story is a release-cut readiness verification. The actual release is
# automated by .github/workflows/release.yml (per ADR-056 / E40-S1) when the
# staging→main release PR merges. This test verifies the preconditions:
#
#   1. The story file has been populated (no {CONTENT_PLACEHOLDER} markers).
#   2. version-bump.js minor dry-run produces v1.137.0 (current is 1.136.0).
#   3. The release.yml workflow exists and is wired to push: main.
#   4. The non-git-cwd-guard library exists in the plugin tree (the bundle).
#
# Test framework: bats (matches existing plugins/gaia/tests/*.bats convention).
# Repo root assumption: tests run from gaia-public/ (matches plugin-ci.yml).
#
# Environment portability:
#   - The story file lives in the parent project tree (docs/) which is OUTSIDE
#     gaia-public/. CI checks out only gaia-public/, so story-file-dependent
#     tests `skip` when the file is unreachable.
#   - The staging-branch comparison requires both `origin/main` and `staging`
#     refs. CI usually has only the PR head + base, so the comparison test
#     `skip`s when either ref is missing.
#   - Tests that touch only files inside gaia-public/ run unconditionally.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  STORY_FILE="${REPO_ROOT}/../docs/implementation-artifacts/epic-E53-docs-reorganization-auto-sharding-and-naming-convention-mass/stories/E53-S246-cut-plugin-release-v1-135-bundling-e53-s234-non-git-cwd-guard.md"
}

# ---------------------------------------------------------------------------
# Story-file checks (skip when story file is unreachable, e.g., CI runners
# that only check out gaia-public/).
# ---------------------------------------------------------------------------

@test "story file exists (or skip when outside gaia-public/ checkout)" {
  if [ ! -f "$STORY_FILE" ]; then
    skip "story file not present in this checkout (expected outside gaia-public/)"
  fi
  [ -f "$STORY_FILE" ]
}

@test "story file has no standalone CONTENT_PLACEHOLDER markers" {
  if [ ! -f "$STORY_FILE" ]; then
    skip "story file not present in this checkout"
  fi
  # A standalone marker is a line whose only non-whitespace token is
  # {CONTENT_PLACEHOLDER} (the create-story template default). References
  # inside backticks or prose (e.g., "no `{CONTENT_PLACEHOLDER}` markers") are
  # legitimate documentation and pass.
  ! grep -qE '^[[:space:]]*\{CONTENT_PLACEHOLDER\}[[:space:]]*$' "$STORY_FILE"
}

@test "story User Story section is populated" {
  if [ ! -f "$STORY_FILE" ]; then
    skip "story file not present in this checkout"
  fi
  run grep -A 2 '^## User Story$' "$STORY_FILE"
  [ "$status" -eq 0 ]
  # The line after the heading must contain "As a" (canonical user-story stem)
  echo "$output" | grep -qE '^As a '
}

@test "story has at least three Acceptance Criteria (AC1, AC2, AC3)" {
  if [ ! -f "$STORY_FILE" ]; then
    skip "story file not present in this checkout"
  fi
  run grep -cE '^\- \[[ x]\] \*\*AC[0-9]+\*\*' "$STORY_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Plugin-tree checks (always run; everything is inside gaia-public/).
# ---------------------------------------------------------------------------

@test "version-bump.js minor dry-run reports 1.137.0" {
  cd "$REPO_ROOT"
  run node scripts/version-bump.js minor --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '1.136.0 -> 1.137.0'
}

@test "release.yml workflow exists and triggers on push to main" {
  WF="${REPO_ROOT}/.github/workflows/release.yml"
  [ -f "$WF" ]
  # Triggers on push to main with plugins/gaia/** path filter
  grep -q 'branches: \[main\]' "$WF"
  grep -q "plugins/gaia/\*\*" "$WF"
}

@test "non-git-cwd-guard library bundled in plugin tree" {
  GUARD="${REPO_ROOT}/plugins/gaia/scripts/lib/non-git-cwd-guard.sh"
  [ -f "$GUARD" ]
}

@test "plugin.json current version is 1.136.0" {
  PLUGIN="${REPO_ROOT}/plugins/gaia/.claude-plugin/plugin.json"
  [ -f "$PLUGIN" ]
  grep -q '"version": "1.136.0"' "$PLUGIN"
}

# ---------------------------------------------------------------------------
# Staging-branch check (skip when origin/main or staging refs are missing,
# e.g., shallow CI checkouts).
# ---------------------------------------------------------------------------

@test "staging branch contains qualifying conventional commits ahead of origin/main" {
  cd "$REPO_ROOT"
  if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
    skip "origin/main ref not available in this checkout"
  fi
  if ! git rev-parse --verify staging >/dev/null 2>&1 \
    && ! git rev-parse --verify origin/staging >/dev/null 2>&1; then
    skip "staging ref not available in this checkout"
  fi
  # Prefer local staging; fall back to origin/staging.
  if git rev-parse --verify staging >/dev/null 2>&1; then
    STAGING_REF=staging
  else
    STAGING_REF=origin/staging
  fi
  # Need at least one commit not yet on origin/main with a conventional prefix
  # touching plugins/gaia/** or .github/workflows/release.yml.
  count=$(git log "origin/main..$STAGING_REF" --oneline -- 'plugins/gaia/' '.github/workflows/release.yml' 2>/dev/null \
    | grep -cE '^[a-f0-9]+ (feat|fix|chore|docs|refactor|test|build|ci|perf|style)' || true)
  [ "$count" -ge 1 ]
}
