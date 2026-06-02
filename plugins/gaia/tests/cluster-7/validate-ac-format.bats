#!/usr/bin/env bats
# validate-ac-format.bats — E63-S6 / Work Item 6.6
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/validate-ac-format.sh.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1  All-good ACs exit 0 silent                      (AC4)
#   #2  Malformed primary AC emits finding              (AC1)
#   #3  AC-EC entries follow the same rule              (AC2)
#   #4  Empty AC section is CRITICAL                    (AC3)
#   #5  Missing file errors clearly                     (AC5)
#   #6  Case-insensitive Given/When/Then matching       (cross-cut AC4)
#   #7  Live-tree smoke: known-good real story          (cross-cut AC4)
#   AC6 — script header invariants (shebang, set -euo pipefail, LC_ALL=C, mode 0755)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/validate-ac-format.sh"
  FIX_DIR="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC4 — all-good ACs exit 0 silent
# ---------------------------------------------------------------------------

@test "AC4: all-good ACs -> exit 0, empty stdout (Scenario 1)" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-good.md"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC1 — malformed primary AC emits finding
# ---------------------------------------------------------------------------

@test "AC1: malformed AC -> exit non-zero, stdout names offending line (Scenario 2)" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-malformed.md"
  [ "$status" -ne 0 ]
  # The finding row should reference the offending content.
  [[ "$output" == *"foo bar"* ]]
}

@test "AC1: malformed AC -> stdout includes line number" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-malformed.md"
  [ "$status" -ne 0 ]
  # The malformed line is at line 12 in the fixture (line numbers are 1-based).
  [[ "$output" == *"line 12"* ]] || [[ "$output" == *"12"* ]]
}

# ---------------------------------------------------------------------------
# AC2 — AC-EC entries follow the same rule
# ---------------------------------------------------------------------------

@test "AC2: malformed AC-EC -> exit non-zero, AC-EC line called out (Scenario 3)" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-mixed-ec.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AC-EC1"* ]] || [[ "$output" == *"empty input gracefully"* ]]
}

@test "AC2: malformed AC-EC -> primary ACs do not produce findings" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-mixed-ec.md"
  [ "$status" -ne 0 ]
  # The well-formed primary ACs should NOT appear in the findings.
  [[ "$output" != *"valid input"* ]]
  [[ "$output" != *"authenticated user"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — empty AC section is CRITICAL
# ---------------------------------------------------------------------------

@test "AC3: empty AC section -> exit non-zero, CRITICAL on stdout (Scenario 4)" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-empty.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"acceptance-criteria"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — missing file errors clearly
# ---------------------------------------------------------------------------

@test "AC5: missing --file path -> exit non-zero, stderr names path (Scenario 5)" {
  run "$SCRIPT" --file "/nonexistent/path/story.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/nonexistent/path/story.md"* ]]
}

# ---------------------------------------------------------------------------
# Case-insensitive matching (Scenario 6)
# ---------------------------------------------------------------------------

@test "Scenario 6: mixed-case Given/When/Then -> exit 0 (case-insensitive)" {
  run "$SCRIPT" --file "$FIX_DIR/story-ac-mixed-case.md"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Usage error coverage
# ---------------------------------------------------------------------------

@test "usage: missing --file flag -> exit non-zero" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "usage: --file with no value -> exit non-zero" {
  run "$SCRIPT" --file
  [ "$status" -ne 0 ]
}

@test "usage: unknown flag -> exit non-zero" {
  run "$SCRIPT" --bogus
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Live-tree smoke (Scenario 7)
# ---------------------------------------------------------------------------

@test "Scenario 7: known-good real story -> exit 0 silent" {
  # SKILLS_DIR = gaia-public/plugins/gaia/skills. The docs/ tree lives at the
  # project root (the parent of gaia-public/). Walk up four levels.
  local project_root
  project_root="$(cd "$SKILLS_DIR/../../../.." && pwd)"
  local story="$project_root/docs/implementation-artifacts/E63-S2-next-story-id-sh-bats-work-item-6-2.md"
  if [ ! -r "$story" ]; then
    skip "live-tree story file not present: $story"
  fi
  run "$SCRIPT" --file "$story"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC6 — script header invariants
# ---------------------------------------------------------------------------

@test "AC6: script exists at the canonical path" {
  [ -f "$SCRIPT" ]
}

@test "AC6: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "AC6: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "AC6: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AC6: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}
