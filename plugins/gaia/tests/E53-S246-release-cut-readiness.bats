#!/usr/bin/env bats
#
# E53-S246: Cut plugin release v1.135 bundling E53-S234 non-git-cwd-guard
#
# This story is a release-cut readiness verification. The actual release is
# automated by .github/workflows/release.yml (per ADR-056 / E40-S1) when the
# staging→main release PR merges. This test verifies the preconditions:
#
#   1. The story file has been populated (no {CONTENT_PLACEHOLDER} markers).
#   2. version-bump.js minor dry-run produces v1.135.0 (current is 1.134.1).
#   3. The release.yml workflow exists and is wired to push: main.
#   4. The non-git-cwd-guard library exists in the plugin tree (the bundle).
#
# Test framework: bats (matches existing plugins/gaia/tests/*.bats convention).
# Repo root assumption: tests run from gaia-public/ (matches plugin-ci.yml).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  STORY_FILE="${REPO_ROOT}/../docs/implementation-artifacts/epic-E53-docs-reorganization-auto-sharding-and-naming-convention-mass/stories/E53-S246-cut-plugin-release-v1-135-bundling-e53-s234-non-git-cwd-guard.md"
}

@test "story file exists" {
  [ -f "$STORY_FILE" ]
}

@test "story file has no standalone CONTENT_PLACEHOLDER markers" {
  # A standalone marker is a line whose only non-whitespace token is
  # {CONTENT_PLACEHOLDER} (the create-story template default). References
  # inside backticks or prose (e.g., "no `{CONTENT_PLACEHOLDER}` markers") are
  # legitimate documentation and pass.
  ! grep -qE '^[[:space:]]*\{CONTENT_PLACEHOLDER\}[[:space:]]*$' "$STORY_FILE"
}

@test "story User Story section is populated" {
  run grep -A 2 '^## User Story$' "$STORY_FILE"
  [ "$status" -eq 0 ]
  # The line after the heading must contain "As a" (canonical user-story stem)
  echo "$output" | grep -qE '^As a '
}

@test "story has at least three Acceptance Criteria (AC1, AC2, AC3)" {
  run grep -cE '^\- \[[ x]\] \*\*AC[0-9]+\*\*' "$STORY_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "version-bump.js minor dry-run reports 1.135.0" {
  cd "$REPO_ROOT"
  run node scripts/version-bump.js minor --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '1.134.1 -> 1.135.0'
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

@test "plugin.json current version is 1.134.1" {
  PLUGIN="${REPO_ROOT}/plugins/gaia/.claude-plugin/plugin.json"
  [ -f "$PLUGIN" ]
  grep -q '"version": "1.134.1"' "$PLUGIN"
}

@test "staging branch contains qualifying conventional commits ahead of origin/main" {
  cd "$REPO_ROOT"
  # Need at least one commit not yet on origin/main with a conventional prefix
  # touching plugins/gaia/** or .github/workflows/release.yml.
  count=$(git log origin/main..staging --oneline -- 'plugins/gaia/' '.github/workflows/release.yml' 2>/dev/null \
    | grep -cE '^[a-f0-9]+ (feat|fix|chore|docs|refactor|test|build|ci|perf|style)' || true)
  [ "$count" -ge 1 ]
}
