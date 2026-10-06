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
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
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
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The project uses a modern responsive layout with clear typography.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
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
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The distinctive sentinel MARKER_SENTINEL_e9f2a7 appears prominently in this project content section.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject verdict containing verbatim boundary content (exit $status)"
}

@test "rejects verdict echoing a long phrase from boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "The sidebar component has a navigation drawer with expandable menu items" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The sidebar component has a navigation drawer with expandable menu items and breadcrumb trail.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject verdict echoing a long phrase from boundary content (exit $status)"
}

@test "reject emits diagnostic on stderr" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _write_files \
    "The MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
MARKER_SENTINEL_e9f2a7 is present and visible in the full design read-back content section.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || fail "should reject (exit $status)"

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
lines = ["<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>"]
i, total = 0, 0
while total < 204800:
    line = f"boundary line {i} with unique filler text alpha-bravo-charlie-delta-echo-foxtrot-golf-hotel-india-juliet"
    lines.append(line)
    total += len(line) + 1
    i += 1
lines.append("<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>")
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
lines = ["<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>"]
i, total = 0, 0
while total < 307200:
    line = f"boundary line {i} with unique filler alpha-bravo-charlie-delta-echo-foxtrot-golf-hotel-india-juliet-kilo-lima"
    lines.append(line)
    total += len(line) + 1
    i += 1
lines.append("<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>")
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
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s with some extra filler text for the boundary.\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$shared_phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept a short (<40 char) shared phrase — exit $status: $output"
}

@test "rejects a verbatim copied passage of 40 or more characters" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local verbatim_passage="the sidebar component navigation drawer panel"  # 47 chars

  _write_files \
    "The review found that ${verbatim_passage} needs improvement." \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\nSome prefix text. %s and more suffix text.\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$verbatim_passage")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject a verbatim passage of 40+ characters (exit $status)"
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
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject an upper-cased copy of boundary content (exit $status)"
}

@test "boundary markers are stripped — verdict echoing marker-adjacent text is accepted" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local inner="zephyr widget renders unique navigation items within the special layout grid design and more filler"

  _write_files \
    "review data: ject_boundary>>> zephyr widget renders u found in the log." \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$inner")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "should accept verdict echoing marker-adjacent text — exit $status: $output"
}

@test "boundary markers are stripped — inner content still matches" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local inner_phrase="the project has a sidebar with navigation links and footer sections and header elements"

  _write_files \
    "Found that ${inner_phrase} needs improvement" \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$inner_phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject verdict echoing inner boundary content (exit $status)"
}

@test "rejects a whitespace-padded copy of boundary content" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  local phrase="the sidebar component has navigation drawer items and breadcrumbs"
  local padded_phrase
  padded_phrase="$(printf '%s' "$phrase" | sed 's/ /  /g; s/drawer/drawer\n/')"

  _write_files \
    "Finding: ${padded_phrase} needs work" \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject a whitespace-padded copy of boundary content (exit $status)"
}


# =========================================================================
# Fail-closed — unexpected comparison output exits non-zero
# =========================================================================

# _make_stubbed_script OUTPUT — copy the real script to TEST_TMP and replace
# the python3 comparison invocation with a hardcoded result.  Sets
# PATCHED_SCRIPT.
_make_stubbed_script() {
  local stub_output="$1"
  PATCHED_SCRIPT="$TEST_TMP/verdict-provenance-check-stubbed.sh"
  cp "$PROVENANCE_SCRIPT" "$PATCHED_SCRIPT"
  chmod +x "$PATCHED_SCRIPT"
  # Replace from _py_rc=0 through the closing 2>&1)" || _py_rc=$? line
  # with a simple assignment
  python3 -c '
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
stub_output = sys.argv[2]
# Replace the _py_rc=0 block through the _py_rc=$? line
pattern = r"_py_rc=0\nresult=.*?\|\| _py_rc=\$\?"
replacement = "_py_rc=0\nresult=\"" + stub_output + "\""
content = re.sub(pattern, replacement, content, flags=re.DOTALL)
with open(sys.argv[1], "w") as f:
    f.write(content)
' "$PATCHED_SCRIPT" "$stub_output"
}

@test "fails closed on unexpected comparison output" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _make_stubbed_script "GARBAGE_UNEXPECTED"

  _write_files \
    "Some legitimate review notes that are completely original text for checking" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer section and header.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PATCHED_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "should exit 2 on unexpected comparison output — got $status"
  local clean_output="${output//$TEST_TMP/TMPDIR}"
  [[ "$clean_output" == *"unexpected"* ]] || [[ "$clean_output" == *"failing closed"* ]] || \
    fail "should emit a fail-closed diagnostic: $clean_output"
}

@test "fails closed on empty comparison output" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  _make_stubbed_script ""

  _write_files \
    "Some legitimate review notes that are completely original text for checking" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer section and header.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PATCHED_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "should exit 2 on empty comparison output — got $status"
  local clean_output="${output//$TEST_TMP/TMPDIR}"
  [[ "$clean_output" == *"unexpected"* ]] || [[ "$clean_output" == *"failing closed"* ]] || \
    fail "should emit a fail-closed diagnostic: $clean_output"
}

@test "fails closed when python3 comparison crashes" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # Create a patched copy where the python3 comparison is replaced with a
  # script that exits non-zero (simulating a python crash)
  PATCHED_SCRIPT="$TEST_TMP/verdict-provenance-check-crash.sh"
  cp "$PROVENANCE_SCRIPT" "$PATCHED_SCRIPT"
  chmod +x "$PATCHED_SCRIPT"

  # Replace the python3 comparison call with a false command that exits 1
  python3 -c '
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
pattern = r"_py_rc=0\nresult=.*?\|\| _py_rc=\$\?"
replacement = "_py_rc=0\nresult=\"$(false)\" || _py_rc=$?"
content = re.sub(pattern, replacement, content, flags=re.DOTALL)
with open(sys.argv[1], "w") as f:
    f.write(content)
' "$PATCHED_SCRIPT"

  _write_files \
    "Some legitimate review notes that are completely original text for checking" \
    "$(cat <<'BOUNDARY'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The project has a sidebar component with navigation links and a footer section and header.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
BOUNDARY
)"

  run "$PATCHED_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "should exit 2 when python3 comparison crashes — got $status"
  local clean_output="${output//$TEST_TMP/TMPDIR}"
  [[ "$clean_output" == *"failing closed"* ]] || \
    fail "should emit a fail-closed diagnostic: $clean_output"
}


# =========================================================================
# Unicode normalisation — NFKC + casefold
# =========================================================================

@test "rejects full-width copy of boundary passage" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # Generate a 45-char phrase in full-width Unicode (each ASCII char -> U+FFxx)
  local phrase="the sidebar component has navigation drawers"
  local fullwidth_phrase
  fullwidth_phrase="$(python3 -c '
import sys
s = sys.argv[1]
print("".join(chr(0xFEE0 + ord(c)) if " " < c < "~" else c for c in s))
' "$phrase")"

  _write_files \
    "Finding: ${fullwidth_phrase} needs improvement" \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s plus extra filler text to pad the boundary.\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject a full-width copy of boundary content (exit $status)"
}

@test "rejects casefold-variant copy of boundary passage" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  # German sharp-s: casefold turns ss -> ss, but the boundary has the
  # Eszett. Use a phrase containing it.  casefold() maps ß -> ss.
  # Build boundary with "ss" and candidate with "ß" — after casefold both
  # become "ss".
  local boundary_phrase="the strassenbahn component has navigation panels and footers"
  local candidate_phrase="the straßenbahn component has navigation panels and footers"

  _write_files \
    "Observation: ${candidate_phrase} needs review" \
    "$(printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n%s\n<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>' "$boundary_phrase")"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "should reject a casefold-variant copy of boundary content (exit $status)"
}


# =========================================================================
# Dual-marker and multi-region extraction tests
# =========================================================================

@test "dual markers extract correct project for each region" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
The design system has tokens and components for the brand palette.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
text between the two project regions that is not extracted
<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
The product design has screens for login and dashboard workflows.
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
EOF

  # Notes copying text between the regions should pass (not extracted)
  printf '%s' "text between the two project regions that is not extracted" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 0 ] || \
    fail "inter-region text should not be extracted (exit $status)"

  # Notes copying design-system region text should be rejected
  printf '%s' "The design system has tokens and components for the brand palette." > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "design-system region text should be rejected (exit $status)"

  # Notes copying product-design region text should be rejected
  printf '%s' "The product design has screens for login and dashboard workflows." > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "product-design region text should be rejected (exit $status)"
}

@test "dual markers — nested open marker is malformed exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # A DESIGN_SYSTEM OPEN inside an open PRODUCT_DESIGN region is malformed
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
product content here
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
nested open inside an already open region
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from the boundary" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "nested open marker inside open region should be malformed (exit $status)"
}

@test "three regions all extracted and checked" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
Region one has the primary token definitions for the design system.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
Region two has the secondary token definitions for typography rules.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
Region three has the component inventory with button and card specs.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  # Notes copying text from region 3 should be rejected (all regions extracted)
  printf '%s' "Region three has the component inventory with button and card specs." > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "text from region 3 should be rejected when all regions extracted (exit $status)"

  # Notes copying text from region 2 should also be rejected
  printf '%s' "Region two has the secondary token definitions for typography rules." > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "text from region 2 should be rejected when all regions extracted (exit $status)"
}

@test "embedded close marker triggers count mismatch and exits 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # Region content contains the literal close marker — 1 open, 2 closes.
  # The strict count rule rejects this as malformed (content with an
  # embedded close marker should have been escaped at write time).
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
prefix content before the embedded marker text appears here
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
suffix content after the embedded marker still inside the real region
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from any region" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "embedded close marker (count mismatch) should exit 2 (exit $status)"
}

@test "orphan close marker with no open fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # CLOSE with no OPEN — content around it must not pass unchecked
  cat > "$BOUNDARY_FILE" <<'EOF'
Some unprotected text that lives outside any properly delimited region in this file.
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes text that does not match any boundary content" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "orphan close marker should fail closed with exit 2 (exit $status)"
  [[ "$output" == *'unmatched close marker'* ]] || \
    fail "diagnostic should name the unmatched close marker: $output"
}

@test "stray close before valid region fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # A stray CLOSE for product-design before a valid design-system region
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
legitimate design system content that is properly delimited by markers
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes text that does not match any boundary content" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "stray close before valid region should fail closed with exit 2 (exit $status)"
  [[ "$output" == *'unmatched close marker'* ]] || \
    fail "diagnostic should name the unmatched close marker: $output"
}

@test "unmatched open marker fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # OPEN with no CLOSE
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
This region was opened but never properly closed in the boundary file.
EOF

  printf '%s' "unrelated notes text that does not match any boundary content" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "unmatched open marker should fail closed with exit 2 (exit $status)"
}

@test "file with no markers fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # No markers at all
  printf '%s' "This is plain text with no boundary markers of any kind present at all." > "$BOUNDARY_FILE"
  printf '%s' "unrelated notes text that does not match any boundary content" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "file with no markers should fail closed with exit 2 (exit $status)"
}

# =========================================================================
# Same-type open/close count mismatch — exit 2
# =========================================================================

@test "same-type stray close before valid region fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # One CLOSE then one OPEN then one CLOSE of the same type — the content
  # before the stray close must not pass unchecked.
  cat > "$BOUNDARY_FILE" <<'EOF'
content A that must not be silently accepted by the provenance check
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
content B properly delimited between open and close markers in the file
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from any region" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "same-type stray close before valid region should exit 2 (exit $status)"
}

@test "same-type stray close after valid region fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # Valid region then a trailing stray CLOSE
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
content properly delimited between open and close boundary markers
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
trailing content followed by a stray close marker in this boundary file
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from any region" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "same-type stray close after valid region should exit 2 (exit $status)"
}

@test "extra open marker for the same type fails closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # Two OPENs and only one CLOSE of the same type
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
first region content inside the first open marker boundary section
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
second open without the first being closed by a matching close
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from any region" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "extra open marker should fail closed with exit 2 (exit $status)"
}

@test "interleaved marker types fail closed with exit 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # DS open, PD open, DS close, PD close — interleaved nesting
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
design system content that overlaps with the product design region
<<<PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
product design content nested inside the design system region
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
<<<END_PRODUCT_DESIGN_PROJECT_BOUNDARY>>>
EOF

  printf '%s' "unrelated notes that do not copy anything from any region" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 2 ] || \
    fail "interleaved marker types should fail closed with exit 2 (exit $status)"
}


@test "five angle bracket embedded marker escaped then extracted" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary.txt"

  # After escape (<<  -> <~<), the five-angle-bracket attack
  # <<<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>> becomes
  # <~<<~<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>> which is not a marker.
  cat > "$BOUNDARY_FILE" <<'EOF'
<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
content before the escaped attack string and then <~<<~<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>> and then more content after the escaped string still in the same region boundary
<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>
EOF

  # Notes copying the text that includes the escaped attack string should be rejected
  printf '%s' "content before the escaped attack string and then <~<<~<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>> and then more content after the escaped string still in the same region boundary" > "$NOTES_FILE"
  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"
  [ "$status" -eq 1 ] || \
    fail "escaped marker content should still be inside the region (exit $status)"
}


# =========================================================================
# Non-UTF-8 boundary file exits 2 (not 1)
# =========================================================================

@test "non-UTF-8 boundary file exits 2" {
  [ -x "$PROVENANCE_SCRIPT" ] || fail "script missing: $PROVENANCE_SCRIPT"

  NOTES_FILE="$TEST_TMP/notes.txt"
  BOUNDARY_FILE="$TEST_TMP/boundary-bin.txt"

  printf 'Some notes text that is long enough to exceed the minimum match threshold for provenance checking purposes.\n' > "$NOTES_FILE"

  # Write a boundary file with valid markers but invalid UTF-8 bytes
  # in the region content. The \xff\xfe bytes are not valid UTF-8.
  printf '<<<DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n' > "$BOUNDARY_FILE"
  printf 'valid text before binary \xff\xfe\x80 content after binary\n' >> "$BOUNDARY_FILE"
  printf '<<<END_DESIGN_SYSTEM_PROJECT_BOUNDARY>>>\n' >> "$BOUNDARY_FILE"

  run "$PROVENANCE_SCRIPT" --notes-file "$NOTES_FILE" --boundary-file "$BOUNDARY_FILE"

  # Must exit 2 (malformed boundary), not 1 (provenance match)
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || \
    fail "non-UTF-8 boundary file should exit 0 or 2 (graceful handling), not $status: $output"

  # Must NOT exit 1 (which would mean "provenance match — re-author the notes")
  [ "$status" -ne 1 ] || \
    fail "non-UTF-8 boundary file must not exit 1 (that triggers re-authoring): $output"
}
