#!/usr/bin/env bats
# manual-test-docs.bats — doc-presence guards for /gaia-test-manual
# documentation. Validates that the doc-site page exists with key sections,
# that the testing category page links to it, that the sprint-review page
# references it, and that the help and manifest CSVs contain the registration.

load 'test_helper.bash'

setup() {
  common_setup
  PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC_DIR="$PUBLIC_ROOT/documentation"
  MANUAL_PAGE="$DOC_DIR/commands/gaia-test-manual.html"
  TESTING_CAT="$DOC_DIR/categories/testing.html"
  SPRINT_REVIEW="$DOC_DIR/commands/gaia-sprint-review.html"
  HELP_CSV="$PUBLIC_ROOT/plugins/gaia/knowledge/gaia-help.csv"
  MANIFEST_CSV="$PUBLIC_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Doc page exists
# ---------------------------------------------------------------------------

@test "gaia-test-manual.html exists" {
  [ -f "$MANUAL_PAGE" ]
}

# ---------------------------------------------------------------------------
# Key sections present in the doc page
# ---------------------------------------------------------------------------

@test "doc page has verification surfaces section" {
  assert_file_contains "$MANUAL_PAGE" "Verification surfaces"
}

@test "doc page lists browser surface" {
  assert_file_contains "$MANUAL_PAGE" "browser"
}

@test "doc page lists api surface" {
  assert_file_contains "$MANUAL_PAGE" "api"
}

@test "doc page lists mobile surface" {
  assert_file_contains "$MANUAL_PAGE" "mobile"
}

@test "doc page lists desktop surface" {
  assert_file_contains "$MANUAL_PAGE" "desktop"
}

@test "doc page has baseline lifecycle section" {
  assert_file_contains "$MANUAL_PAGE" "baseline lifecycle"
}

@test "doc page has proof-of-execution gate" {
  assert_file_contains "$MANUAL_PAGE" "proof-of-execution"
}

@test "doc page has advisory review gate section" {
  assert_file_contains "$MANUAL_PAGE" "Advisory review gate"
}

@test "doc page disambiguates from gaia-test-run" {
  assert_file_contains "$MANUAL_PAGE" "gaia-test-run"
}

# ---------------------------------------------------------------------------
# Testing category page links to gaia-test-manual
# ---------------------------------------------------------------------------

@test "testing category links gaia-test-manual.html" {
  assert_file_contains "$TESTING_CAT" "gaia-test-manual.html"
}

# ---------------------------------------------------------------------------
# Sprint-review page references gaia-test-manual
# ---------------------------------------------------------------------------

@test "sprint-review page references gaia-test-manual" {
  assert_file_contains "$SPRINT_REVIEW" "gaia-test-manual"
}

# ---------------------------------------------------------------------------
# Help CSV and workflow manifest registration (verify AC3)
# ---------------------------------------------------------------------------

@test "help CSV has test-manual row" {
  grep -F '"test-manual"' "$HELP_CSV" | grep -F '"testing"'
}

@test "workflow manifest has test-manual row" {
  grep -F '"test-manual"' "$MANIFEST_CSV" | grep -F 'gaia-test-manual'
}
