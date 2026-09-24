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
The distinctive sentinel MARKER_SENTINEL_e9f2a7 appears prominently in this project content section.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # Echoes a 40+ char substring from the boundary content
  local candidate_notes="I found that distinctive sentinel MARKER_SENTINEL_e9f2a7 appears prominently in the design"

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
MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back content section.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  # A 40+ char overlap with the boundary content
  local candidate_notes="The MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back"

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


# =========================================================================
# Performance — linear-time algorithm
# =========================================================================

@test "10 KB notes against 200 KB boundary content completes in under 3 s" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # Generate test data via python3 for speed (bash loops are too slow
  # for 200 KB string assembly).
  local boundary_content
  boundary_content="$(python3 -c '
lines = []
lines.append("<<<DESIGN_PROJECT_BOUNDARY>>>")
i = 0
total = 0
while total < 204800:
    line = f"boundary line {i} with unique filler text alpha-bravo-charlie-delta-echo-foxtrot-golf-hotel-india-juliet"
    lines.append(line)
    total += len(line) + 1
    i += 1
lines.append("<<<END_DESIGN_PROJECT_BOUNDARY>>>")
print("\n".join(lines))
')"

  local candidate_notes
  candidate_notes="$(python3 -c '
lines = []
i = 0
total = 0
while total < 10240:
    line = f"review observation {i} colour contrast spacing typography hierarchy layout grid responsive mobile desktop"
    lines.append(line)
    total += len(line) + 1
    i += 1
print("\n".join(lines))
')"

  # Measure wall-clock time portably via python3 (macOS date lacks %s%N)
  local start_ms end_ms elapsed_ms
  start_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"

  end_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
  elapsed_ms=$((end_ms - start_ms))

  [ "$status" -eq 0 ] || fail "script failed on large input — exit $status"
  [ "$elapsed_ms" -lt 3000 ] || \
    fail "performance: ${elapsed_ms} ms exceeds 3000 ms budget for 10 KB vs 200 KB"
}


# =========================================================================
# False-positive denial of service — min match length raised to 40
# =========================================================================

@test "accepts a short reviewer phrase (under 40 chars) that also appears in boundary" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # A 30-character phrase that could naturally appear in both reviewer
  # notes and project content.  Must NOT trigger a match.
  local shared_phrase="the layout is well structured"  # 29 chars

  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s with some extra filler text for the boundary.\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$shared_phrase")"

  local candidate_notes="I observed that ${shared_phrase} overall."

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -eq 0 ] || \
    fail "should accept a short (<40 char) shared phrase — exit $status: $output"
}

@test "rejects a verbatim copied passage of 40 or more characters" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # A 45-character verbatim passage.
  local verbatim_passage="the sidebar component navigation drawer panel"  # 47 chars

  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\nSome prefix text. %s and more suffix text.\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$verbatim_passage")"

  local candidate_notes="The review found that ${verbatim_passage} needs improvement."

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject a verbatim passage of 40+ characters"
}


# =========================================================================
# Case and whitespace evasion — normalised comparison
# =========================================================================

@test "rejects an upper-cased copy of boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local phrase="the sidebar component has navigation drawer items and breadcrumbs"

  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$phrase")"

  # Upper-case version of the same phrase
  local upper_phrase
  upper_phrase="$(printf '%s' "$phrase" | tr '[:lower:]' '[:upper:]')"
  local candidate_notes="Finding: ${upper_phrase} needs work"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject an upper-cased copy of boundary content"
}

@test "boundary markers are stripped — verdict echoing marker-adjacent text is accepted" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # The boundary wraps inner text with a newline after the opening
  # marker.  After normalisation, the unstripped boundary is:
  #   "<<<design_project_boundary>>> zephyr widget renders ..."
  # The candidate echoes a 40-char window spanning the marker/inner
  # seam.  With stripping, the marker text is gone and only the inner
  # content is searched — the candidate's cross-seam window has no
  # match, so the check passes.
  local inner="zephyr widget renders unique navigation items within the special layout grid design and more filler"
  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$inner")"

  # After normalisation, the unstripped boundary is:
  #   "<<<design_project_boundary>>> zephyr widget renders ..."
  # 40-char cross-seam window:
  #   "ject_boundary>>> zephyr widget renders u" (40 chars)
  # That window is absent from the stripped inner (starts "zephyr ...")
  local candidate_notes="review data: ject_boundary>>> zephyr widget renders u found in the log."

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -eq 0 ] || \
    fail "should accept verdict echoing marker-adjacent text — exit $status: $output"
}

@test "boundary markers are stripped — inner content still matches" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # A longer inner phrase that exceeds the 40-char threshold
  local inner_phrase="the project has a sidebar with navigation links and footer sections and header elements"

  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$inner_phrase")"

  # Candidate echoes a 40+ char substring of the INNER content — must reject
  local candidate_notes="Found that ${inner_phrase} needs improvement"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict echoing inner boundary content"
}

@test "rejects a whitespace-padded copy of boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local phrase="the sidebar component has navigation drawer items and breadcrumbs"

  local boundary_content
  boundary_content="$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$phrase")"

  # Insert extra spaces and a newline in the middle
  local padded_phrase
  padded_phrase="$(printf '%s' "$phrase" | sed 's/ /  /g; s/drawer/drawer\n/')"
  local candidate_notes="Finding: ${padded_phrase} needs work"

  run "$PROVENANCE_SCRIPT" "$candidate_notes" "$boundary_content"
  [ "$status" -ne 0 ] || \
    fail "should reject a whitespace-padded copy of boundary content"
}
