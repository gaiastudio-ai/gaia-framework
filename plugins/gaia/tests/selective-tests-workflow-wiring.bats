#!/usr/bin/env bats
# selective-tests-workflow-wiring.bats — regression guard for the reference
# selective-tests CI workflow.
#
# The shipped reference workflow .github/workflows/selective-tests.yml is the
# only place the promotion-push wildcard safety rail is WIRED. The pipeline
# scripts (detect-affected.sh, selective-test-driver.sh) support
# `--event promotion-push`, but a documented-yet-inert rail in the workflow
# means the last gate before production silently runs a NARROWED suite.
#
# These tests assert on the workflow file content so the wiring cannot
# regress to "scripts support it, workflow never calls it" again:
#   - the workflow determines the PR/push base branch;
#   - it derives the full-suite tier from ci_cd.promotion_chain (not hard-coded);
#   - it passes --event promotion-push to the driver on a final-tier promotion.

load 'test_helper.bash'

setup() {
  common_setup
  # SCRIPTS_DIR == <repo>/gaia-public/plugins/gaia/scripts;
  # the reference workflow lives at <repo>/gaia-public/.github/workflows/.
  WORKFLOW="$(cd "$SCRIPTS_DIR/../../.." && pwd)/.github/workflows/selective-tests.yml"
}
teardown() { common_teardown; }

@test "reference selective-tests.yml workflow file exists" {
  [ -f "$WORKFLOW" ]
}

@test "workflow determines the PR/push base branch" {
  # The base of a PR is its target branch; for a push it is the pushed ref.
  grep -qE 'github\.event\.pull_request\.base\.ref' "$WORKFLOW"
}

@test "workflow derives the full-suite tier from ci_cd.promotion_chain (not hard-coded)" {
  # Reads the LAST tier's branch from the promotion chain.
  grep -qE 'ci_cd\.promotion_chain\[-1\]\.branch' "$WORKFLOW"
}

@test "workflow passes --event promotion-push to the driver on a final-tier promotion" {
  grep -qE 'event promotion-push' "$WORKFLOW"
}

@test "promotion flag is gated on base == final tier, not applied unconditionally" {
  # The driver_extra array must only gain --event promotion-push when the
  # promotion step reports is_promotion=true; a bare unconditional append
  # would re-break the feature->staging narrowing.
  grep -qE 'is_promotion.*==.*true|is_promotion.*true' "$WORKFLOW"
}

@test "workflow YAML parses (valid syntax)" {
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c "import yaml,sys; yaml.safe_load(open('$WORKFLOW'))"
    [ "$status" -eq 0 ]
  else
    skip "python3 not available to lint YAML"
  fi
}
