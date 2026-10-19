#!/usr/bin/env bats
# ci-fast-feedback-cap.bats — structural tests for the fast-feedback file-count
# cap in plugin-ci.yml.  Ensures a future refactor cannot silently remove the
# guard that prevents timeout-cancellation on large diffs (promotion PRs).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  REPO_ROOT="$( cd "$PLUGIN_DIR/../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/plugin-ci.yml"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Structural: the bats-fast-feedback job carries a file-count cap or a
# skip condition for promotion PRs (base branch = release target).
# ---------------------------------------------------------------------------

@test "plugin-ci.yml bats-fast-feedback step declares FAST_FEEDBACK_MAX_FILES env var" {
  [ -f "$WORKFLOW" ]
  grep -q 'FAST_FEEDBACK_MAX_FILES' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback step contains file-count cap logic" {
  [ -f "$WORKFLOW" ]
  # The cap logic compares the selected count against the maximum and
  # truncates with head.  Assert both the comparison and the truncation.
  grep -q 'count.*-gt.*max\|count.*-ge.*max' "$WORKFLOW"
  grep -q 'head -n' "$WORKFLOW"
}

@test "plugin-ci.yml bats-fast-feedback step logs dropped file count on cap" {
  [ -f "$WORKFLOW" ]
  # When the cap triggers, the step must log how many files were dropped
  # so the operator knows the fast-feedback result is partial.
  grep -q 'dropped' "$WORKFLOW"
}

@test "plugin-ci.yml FAST_FEEDBACK_MAX_FILES is a positive integer" {
  [ -f "$WORKFLOW" ]
  # Extract the value and verify it is a bare positive integer (no quotes
  # around the number itself are required, but the YAML scalar might be
  # quoted as a string).
  local val
  val=$(grep 'FAST_FEEDBACK_MAX_FILES' "$WORKFLOW" \
    | head -1 | sed -E "s/.*FAST_FEEDBACK_MAX_FILES:[[:space:]]*['\"]?([0-9]+)['\"]?.*/\1/")
  [ -n "$val" ]
  [ "$val" -gt 0 ]
}
