#!/usr/bin/env bats
# AF-21-23: bulk sweep of 59 simple SKILL.md files (no dual-layout caveats).
# 13 caveat-containing files deferred to AF-21-24.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# Simple files asserted zero legacy hits.
# (gaia-run-all-reviews intentionally retains 3 docs/ refs in ADR-111 dual-layout
#  caveats from AF-21-22 — already capped via af-2026-05-21-22 bats fixture.)
SIMPLE_FILES=(
  gaia-a11y-testing gaia-action-items gaia-advanced-elicitation gaia-brainstorming
  gaia-bridge-enable gaia-bridge-toggle gaia-changelog gaia-check-dod
  gaia-check-review-gate gaia-ci-edit gaia-ci-setup gaia-code-review
  gaia-create-epics gaia-create-story gaia-create-ux gaia-creative-sprint
  gaia-deploy-checklist gaia-deploy-post gaia-design-thinking gaia-dev-story gaia-document-project
  gaia-documentation-standards gaia-epic-status gaia-fix-story gaia-ground-truth-management
  gaia-index-docs gaia-init gaia-innovation gaia-memory-management
  gaia-migrate gaia-mobile-testing gaia-party gaia-perf-testing
  gaia-performance-review gaia-pitch-deck gaia-post-deploy gaia-project-context
  gaia-quick-dev gaia-refresh-ground-truth gaia-release gaia-release-plan
  gaia-resume gaia-review-a11y gaia-review-api gaia-review-mobile
  gaia-review-security gaia-rollback-plan gaia-shard-doc gaia-slide-deck
  gaia-sprint-review gaia-sprint-status gaia-statusline gaia-storytelling
  gaia-test-gap-analysis gaia-threat-model gaia-validate-design-a11y gaia-validate-framework
  gaia-validate-prd gaia-validate-story
)

@test "all 59 simple SKILL.md files have zero legacy docs/ literals" {
  local failed=()
  for skill in "${SIMPLE_FILES[@]}"; do
    if grep -qE 'docs/(planning-artifacts|test-artifacts|creative-artifacts|implementation-artifacts|research-artifacts)' "$PLUGIN_ROOT/skills/$skill/SKILL.md"; then
      failed+=("$skill")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "Files still containing legacy docs/ refs: ${failed[*]}" >&2
    return 1
  fi
}
