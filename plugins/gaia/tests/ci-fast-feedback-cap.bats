#!/usr/bin/env bats
# ci-fast-feedback-cap.bats — structural tests for the fast-feedback skip and
# file-count cap in plugin-ci.yml.  Ensures a future refactor cannot silently
# remove the guard that prevents timeout-cancellation on large diffs.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  REPO_ROOT="$( cd "$PLUGIN_DIR/../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/plugin-ci.yml"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Structural: the bats-fast-feedback job skips promotion PRs and caps the
# file count for large feature-branch diffs.
# ---------------------------------------------------------------------------

@test "plugin-ci.yml bats-fast-feedback skips when base branch is the release target" {
  [ -f "$WORKFLOW" ]
  # The skip must test PR_BASE_REF against the release branch name and
  # exit 0 with a summary message.  Assert the conditional and the summary.
  grep -q 'PR_BASE_REF.*main\|main.*PR_BASE_REF' "$WORKFLOW"
  grep -q 'Skipped.*promotion' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback declares FAST_FEEDBACK_MAX_FILES env var" {
  [ -f "$WORKFLOW" ]
  grep -q 'FAST_FEEDBACK_MAX_FILES' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback contains file-count cap logic with head truncation" {
  [ -f "$WORKFLOW" ]
  # The cap logic compares the selected count against the maximum and
  # truncates with head.  Assert both the comparison and the truncation.
  grep -q 'count.*-gt.*max\|count.*-ge.*max' "$WORKFLOW"
  grep -q 'head -n' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback emits a ::warning:: line when the cap triggers" {
  [ -f "$WORKFLOW" ]
  # When the cap triggers, the step must emit a GitHub Actions warning
  # annotation with the cap details.  A bare 'dropped' variable assignment
  # alone is insufficient — assert the warning line itself.
  grep -q '::warning::.*capped' "$WORKFLOW"
}

@test "plugin-ci.yml FAST_FEEDBACK_MAX_FILES is at most 50" {
  [ -f "$WORKFLOW" ]
  # 50 files x ~2.25 s/file = ~113 s, fitting the 5-minute timeout.
  # Values above 50 risk timeout on the single-threaded fast-feedback runner.
  local val
  val=$(grep 'FAST_FEEDBACK_MAX_FILES' "$WORKFLOW" \
    | head -1 | sed -E "s/.*FAST_FEEDBACK_MAX_FILES:[[:space:]]*['\"]?([0-9]+)['\"]?.*/\1/")
  [ -n "$val" ]
  [ "$val" -gt 0 ]
  [ "$val" -le 50 ]
}
