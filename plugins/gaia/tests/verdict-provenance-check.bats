#!/usr/bin/env bats
# verdict-provenance-check.bats — unit tests for the verdict-provenance
# guard script.  Verifies accept, reject, and argument-error contracts.

load 'test_helper.bash'

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

PROVENANCE_SCRIPT=""

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROVENANCE_SCRIPT="$PLUGIN_ROOT/skills/gaia-design-review/scripts/verdict-provenance-check.sh"
}

teardown() { common_teardown; }


# =========================================================================
# Existence guard
# =========================================================================

@test "verdict-provenance-check.sh exists and is executable" {
  [ -f "$PROVENANCE_SCRIPT" ] || \
    fail "verdict-provenance-check.sh does not exist: $PROVENANCE_SCRIPT"
  [ -x "$PROVENANCE_SCRIPT" ] || \
    fail "verdict-provenance-check.sh is not executable: $PROVENANCE_SCRIPT"
}


# =========================================================================
# Accept contract — verdict with no boundary overlap passes
# =========================================================================

@test "accepts verdict with no verbatim overlap with boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  local candidate_notes="Overall the design quality is strong with good contrast ratios"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -eq 0 ] || \
    fail "should accept notes with no verbatim overlap — exit $status: $output"
}

@test "accepts short common substrings below the length threshold" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The project uses a modern responsive layout with clear typography.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Short common words like "the" and "with" appear in both but are below
  # any reasonable length threshold
  local candidate_notes="The layout is well structured with good spacing"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -eq 0 ] || \
    fail "should accept short common substrings below threshold — exit $status: $output"
}


# =========================================================================
# Reject contract — verbatim boundary content in verdict
# =========================================================================

@test "rejects verdict containing verbatim boundary-marker content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The distinctive sentinel MARKER_SENTINEL_e9f2a7 appears in this project content.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  local candidate_notes="I found that MARKER_SENTINEL_e9f2a7 is a quality issue"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict containing verbatim boundary content"
}

@test "rejects verdict echoing a long phrase from boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The sidebar component has a navigation drawer with expandable menu items and breadcrumb trail.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Echoing a substantial phrase verbatim
  local candidate_notes="The sidebar component has a navigation drawer with expandable menu items"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict echoing a long phrase from boundary content"
}

@test "reject emits diagnostic on stderr" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local boundary_content
  boundary_content="$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
MARKER_SENTINEL_e9f2a7 is present in the read-back.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  local candidate_notes="The MARKER_SENTINEL_e9f2a7 indicates a problem"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || fail "should reject"

  # Diagnostic should be present (stderr is captured in $output by bats run)
  [[ "$output" == *"verbatim"* ]] || [[ "$output" == *"provenance"* ]] || [[ "$output" == *"match"* ]] || \
    fail "should emit a diagnostic naming the match reason: $output"
}


# =========================================================================
# Argument-error contract
# =========================================================================

@test "fails with no arguments" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  run "$PROVENANCE_SCRIPT"
  [ "$status" -ne 0 ] || fail "should fail with no arguments"
}

@test "fails with only one argument" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  run "$PROVENANCE_SCRIPT" "some notes text"
  [ "$status" -ne 0 ] || fail "should fail with only one argument"
}

@test "fails with empty candidate notes" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  run "$PROVENANCE_SCRIPT" "" "<<<BOUNDARY>>>content<<<END_BOUNDARY>>>"
  [ "$status" -ne 0 ] || fail "should fail with empty candidate notes"
}
