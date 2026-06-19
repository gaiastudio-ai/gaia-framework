#!/usr/bin/env bats
# Doc-structure tests for the automated versioning and deploy tutorial.
#
# Asserts: the tutorial page exists, covers all three release strategies,
# documents the three affected-set channels, and is linked from the
# deployment category page.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../documentation" && pwd)"
  TUTORIAL="$DOC_ROOT/tutorials/automated-versioning-and-deploy.html"
}

teardown() { common_teardown; }

# ===========================================================================
# Tutorial existence and well-formedness
# ===========================================================================

@test "versioning tutorial exists" {
  [ -f "$TUTORIAL" ]
}

@test "versioning tutorial is well-formed HTML with doctype and closing tags" {
  head -1 "$TUTORIAL" | grep -qi '<!doctype html>'
  grep -q '</html>' "$TUTORIAL"
  grep -q '</body>' "$TUTORIAL"
}

# ===========================================================================
# Release strategy coverage (three strategies)
# ===========================================================================

@test "versioning tutorial covers conventional-commits strategy" {
  grep -q 'conventional-commits' "$TUTORIAL"
  grep -q 'Conventional Commits' "$TUTORIAL"
}

@test "versioning tutorial covers manual strategy" {
  grep -q 'strategy: manual' "$TUTORIAL"
  grep -q 'Manual versioning' "$TUTORIAL"
}

@test "versioning tutorial covers calendar strategy" {
  grep -q 'strategy: calendar' "$TUTORIAL"
  grep -q 'Calendar versioning' "$TUTORIAL"
}

# ===========================================================================
# Per-component deploy coverage
# ===========================================================================

@test "versioning tutorial documents deploy_order" {
  grep -q 'deploy_order' "$TUTORIAL"
}

@test "versioning tutorial documents health_check config" {
  grep -q 'health_check' "$TUTORIAL"
}

@test "versioning tutorial documents post_deploy_smoke config" {
  grep -q 'post_deploy_smoke' "$TUTORIAL"
}

@test "versioning tutorial documents partial-deploy recovery" {
  grep -q 'PARTIAL-DEPLOY' "$TUTORIAL"
  grep -q 'best-effort' "$TUTORIAL"
}

# ===========================================================================
# Affected-set data contract (three channels)
# ===========================================================================

@test "versioning tutorial documents CI artifact channel" {
  grep -q 'affected-set.json' "$TUTORIAL"
  grep -q 'ci-artifact' "$TUTORIAL"
}

@test "versioning tutorial documents commit trailer channel" {
  grep -q 'Affected-Set:' "$TUTORIAL"
  grep -q 'commit-trailer' "$TUTORIAL"
}

@test "versioning tutorial documents full-deploy fallback" {
  grep -q 'full-deploy' "$TUTORIAL"
  # The safety-net guarantee
  grep -q 'never silently deploys nothing' "$TUTORIAL"
}

# ===========================================================================
# Configuration reference (self-contained for new users)
# ===========================================================================

@test "versioning tutorial includes release.version_files config example" {
  grep -q 'release.version_files' "$TUTORIAL" || \
    grep -q 'version_files' "$TUTORIAL"
}

@test "versioning tutorial includes release.strategy config example" {
  grep -q 'release.strategy' "$TUTORIAL" || \
    grep -q 'release:' "$TUTORIAL"
}

# ===========================================================================
# Nav integration
# ===========================================================================

@test "deployment category page links to versioning tutorial" {
  grep -q 'automated-versioning-and-deploy.html' \
    "$DOC_ROOT/categories/deployment.html"
}

@test "index page sidebar links to versioning tutorial" {
  grep -q 'automated-versioning-and-deploy.html' \
    "$DOC_ROOT/index.html"
}

@test "lifecycle diagram links to versioning tutorial" {
  grep -q 'automated-versioning-and-deploy.html' \
    "$DOC_ROOT/lifecycle-diagram.html"
}
