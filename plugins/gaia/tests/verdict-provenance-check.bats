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

# _write_files NOTES BOUNDARY — write notes and boundary content to temp
# files under TEST_TMP and set NOTES_FILE / BOUNDARY_FILE.
_write_files() {
  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"
  printf '%s' "$1" > "$NOTES_FILE"
  printf '%s' "$2" > "$BOUNDARY_FILE"
}


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

  _write_files \
    "Overall the design quality is strong with good contrast ratios" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept notes with no verbatim overlap — exit $status: $output"
}

@test "accepts short common substrings below the length threshold" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "The layout is well structured with good spacing" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The project uses a modern responsive layout with clear typography.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept short common substrings below threshold — exit $status: $output"
}


# =========================================================================
# Reject contract — verbatim boundary content in verdict
# =========================================================================

@test "rejects verdict containing verbatim boundary-marker content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "I found that distinctive sentinel MARKER_SENTINEL_e9f2a7 appears prominently in the design" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The distinctive sentinel MARKER_SENTINEL_e9f2a7 appears prominently in this project content section.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict containing verbatim boundary content"
}

@test "rejects verdict echoing a long phrase from boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "The sidebar component has a navigation drawer with expandable menu items" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
The sidebar component has a navigation drawer with expandable menu items and breadcrumb trail.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict echoing a long phrase from boundary content"
}

@test "reject emits diagnostic on stderr" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "The MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_PROJECT_BOUNDARY>>>
MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back content section.
<<<END_DESIGN_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
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
  [ "$status" -eq 2 ] || fail "should exit 2 with no arguments — got $status"
}

@test "fails with only --notes-file" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  printf 'some notes' > "$TEST_TMP/notes.txt"
  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt"
  [ "$status" -eq 2 ] || fail "should exit 2 with only --notes-file — got $status"
}

@test "fails with only --boundary-file" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  printf 'some boundary' > "$TEST_TMP/boundary.txt"
  run "$PROVENANCE_SCRIPT" --boundary-file "$TEST_TMP/boundary.txt"
  [ "$status" -eq 2 ] || fail "should exit 2 with only --boundary-file — got $status"
}

@test "fails when notes file does not exist" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  printf 'boundary' > "$TEST_TMP/boundary.txt"
  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/nonexistent.txt" --boundary-file "$TEST_TMP/boundary.txt"
  [ "$status" -eq 2 ] || fail "should exit 2 for missing notes file — got $status"
  [[ "$output" == *"not found"* ]] || fail "should report missing file: $output"
}

@test "fails when boundary file does not exist" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  printf 'notes' > "$TEST_TMP/notes.txt"
  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt" --boundary-file "$TEST_TMP/nonexistent.txt"
  [ "$status" -eq 2 ] || fail "should exit 2 for missing boundary file — got $status"
  [[ "$output" == *"not found"* ]] || fail "should report missing file: $output"
}

@test "fails when notes file is empty" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  : > "$TEST_TMP/notes.txt"
  printf 'boundary content' > "$TEST_TMP/boundary.txt"
  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt" --boundary-file "$TEST_TMP/boundary.txt"
  [ "$status" -eq 2 ] || fail "should exit 2 for empty notes file — got $status"
  [[ "$output" == *"empty"* ]] || fail "should report empty file: $output"
}

@test "fails when boundary file is unreadable" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  printf 'notes' > "$TEST_TMP/notes.txt"
  printf 'boundary' > "$TEST_TMP/boundary.txt"
  chmod 000 "$TEST_TMP/boundary.txt"
  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt" --boundary-file "$TEST_TMP/boundary.txt"
  chmod 644 "$TEST_TMP/boundary.txt"  # restore for cleanup
  [ "$status" -eq 2 ] || fail "should exit 2 for unreadable boundary file — got $status"
  [[ "$output" == *"not readable"* ]] || fail "should report unreadable file: $output"
}


# =========================================================================
# Performance — linear-time algorithm
# =========================================================================

@test "10 KB notes against 200 KB boundary content completes in under 3 s" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # Generate test data via python3 and write directly to files
  python3 -c '
lines = ["<<<DESIGN_PROJECT_BOUNDARY>>>"]
i, total = 0, 0
while total < 204800:
    line = f"boundary line {i} with unique filler text alpha-bravo-charlie-delta-echo-foxtrot-golf-hotel-india-juliet"
    lines.append(line)
    total += len(line) + 1
    i += 1
lines.append("<<<END_DESIGN_PROJECT_BOUNDARY>>>")
with open("'"$TEST_TMP"'/boundary.txt", "w") as f:
    f.write("\n".join(lines))
'

  python3 -c '
lines = []
i, total = 0, 0
while total < 10240:
    line = f"review observation {i} colour contrast spacing typography hierarchy layout grid responsive mobile desktop"
    lines.append(line)
    total += len(line) + 1
    i += 1
with open("'"$TEST_TMP"'/notes.txt", "w") as f:
    f.write("\n".join(lines))
'

  local start_ms end_ms elapsed_ms
  start_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"

  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt" --boundary-file "$TEST_TMP/boundary.txt"

  end_ms="$(python3 -c 'import time; print(int(time.monotonic() * 1000))')"
  elapsed_ms=$((end_ms - start_ms))

  [ "$status" -eq 0 ] || fail "script failed on large input — exit $status"
  [ "$elapsed_ms" -lt 3000 ] || \
    fail "performance: ${elapsed_ms} ms exceeds 3000 ms budget for 10 KB vs 200 KB"
}


# =========================================================================
# Linux MAX_ARG_STRLEN — 300 KB content via file interface
# =========================================================================

@test "300 KB boundary content works via file interface (above Linux 128 KB arg limit)" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # Generate 300 KB of boundary content directly to file
  python3 -c '
lines = ["<<<DESIGN_PROJECT_BOUNDARY>>>"]
i, total = 0, 0
while total < 307200:
    line = f"boundary line {i} with unique filler alpha-bravo-charlie-delta-echo-foxtrot-golf-hotel-india-juliet-kilo-lima"
    lines.append(line)
    total += len(line) + 1
    i += 1
lines.append("<<<END_DESIGN_PROJECT_BOUNDARY>>>")
with open("'"$TEST_TMP"'/boundary.txt", "w") as f:
    f.write("\n".join(lines))
'

  python3 -c '
with open("'"$TEST_TMP"'/notes.txt", "w") as f:
    f.write("The overall design quality is excellent with strong visual hierarchy and good spacing throughout.")
'

  # Assert the boundary file is actually above 128 KB
  local boundary_size
  boundary_size="$(wc -c < "$TEST_TMP/boundary.txt" | tr -d ' ')"
  [ "$boundary_size" -gt 131072 ] || \
    fail "boundary file is only ${boundary_size} bytes — must exceed 131072 (128 KB) to prove the fix"

  run "$PROVENANCE_SCRIPT" --notes-file "$TEST_TMP/notes.txt" --boundary-file "$TEST_TMP/boundary.txt"
  [ "$status" -eq 0 ] || \
    fail "should accept 300 KB boundary content via file interface — exit $status: $output"
}


# =========================================================================
# False-positive denial of service — min match length raised to 40
# =========================================================================

@test "accepts a short reviewer phrase (under 40 chars) that also appears in boundary" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local shared_phrase="the layout is well structured"  # 29 chars

  _write_files \
    "I observed that ${shared_phrase} overall." \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s with some extra filler text for the boundary.\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$shared_phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept a short (<40 char) shared phrase — exit $status: $output"
}

@test "rejects a verbatim copied passage of 40 or more characters" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local verbatim_passage="the sidebar component navigation drawer panel"  # 47 chars

  _write_files \
    "The review found that ${verbatim_passage} needs improvement." \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\nSome prefix text. %s and more suffix text.\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$verbatim_passage")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject a verbatim passage of 40+ characters"
}


# =========================================================================
# Case and whitespace evasion — normalised comparison
# =========================================================================

@test "rejects an upper-cased copy of boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local phrase="the sidebar component has navigation drawer items and breadcrumbs"
  local upper_phrase
  upper_phrase="$(printf '%s' "$phrase" | tr '[:lower:]' '[:upper:]')"

  _write_files \
    "Finding: ${upper_phrase} needs work" \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject an upper-cased copy of boundary content"
}

@test "boundary markers are stripped — verdict echoing marker-adjacent text is accepted" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local inner="zephyr widget renders unique navigation items within the special layout grid design and more filler"

  _write_files \
    "review data: ject_boundary>>> zephyr widget renders u found in the log." \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$inner")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept verdict echoing marker-adjacent text — exit $status: $output"
}

@test "boundary markers are stripped — inner content still matches" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local inner_phrase="the project has a sidebar with navigation links and footer sections and header elements"

  _write_files \
    "Found that ${inner_phrase} needs improvement" \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$inner_phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject verdict echoing inner boundary content"
}

@test "rejects a whitespace-padded copy of boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local phrase="the sidebar component has navigation drawer items and breadcrumbs"
  local padded_phrase
  padded_phrase="$(printf '%s' "$phrase" | sed 's/ /  /g; s/drawer/drawer\n/')"

  _write_files \
    "Finding: ${padded_phrase} needs work" \
    "$(printf '<<<DESIGN_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_PROJECT_BOUNDARY>>>' "$phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -ne 0 ] || \
    fail "should reject a whitespace-padded copy of boundary content"
}
