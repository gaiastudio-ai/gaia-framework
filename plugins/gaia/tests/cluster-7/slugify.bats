#!/usr/bin/env bats
# slugify.bats — E63-S1 / Work Item 6.3
#
# Verifies the byte-deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/slugify.sh.
# This script is the dependency root for E63-S3 (generate-frontmatter.sh),
# E63-S4 (validate-canonical-filename.sh), and E63-S9 (scaffold-story.sh) —
# any change here must be coordinated with their fixtures.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1 Happy path                 (AC1)
#   #2 Multi-space collapse       (AC2)
#   #3 Unicode strip              (AC3)
#   #4 All non-alphanumeric       (AC6)
#   #5 Stdin invocation           (AC4)
#   #6 Empty --title input        (AC4)
#   #7 Numeric-only title         (extra coverage)
#   #8 Mixed case                 (extra coverage)
#   AC5 — script header invariants (shebang, set -euo pipefail, LC_ALL=C, mode 0755)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/slugify.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — happy path
# ---------------------------------------------------------------------------

@test "AC1: --title 'Add User Auth!' -> add-user-auth (Scenario 1)" {
  run "$SCRIPT" --title "Add User Auth!"
  [ "$status" -eq 0 ]
  [ "$output" = "add-user-auth" ]
}

# ---------------------------------------------------------------------------
# AC2 — multi-space collapse
# ---------------------------------------------------------------------------

@test "AC2: --title '  Multiple   Spaces  ' -> multiple-spaces (Scenario 2)" {
  run "$SCRIPT" --title "  Multiple   Spaces  "
  [ "$status" -eq 0 ]
  [ "$output" = "multiple-spaces" ]
}

# ---------------------------------------------------------------------------
# AC3 — unicode strip (deterministic policy: non-ASCII bytes are dropped)
# ---------------------------------------------------------------------------

@test "AC3: unicode title strips non-ASCII -> caf-r-sum (Scenario 3)" {
  # Build the input from a Bash $'...' escape to avoid UTF-8 bytes in the
  # bats test name (bats 1.13 mangles the test description when the name
  # contains multibyte sequences). The input still contains the literal
  # UTF-8 bytes for the e-acute in 'cafe' and 'resume'.
  local input
  input=$'caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9'
  run "$SCRIPT" --title "$input"
  [ "$status" -eq 0 ]
  [ "$output" = "caf-r-sum" ]
}

# ---------------------------------------------------------------------------
# AC6 — all non-alphanumeric input trims to empty (no leading/trailing -)
# ---------------------------------------------------------------------------

@test "AC6: --title '!!! ???' -> empty string, exit 0 (Scenario 4)" {
  run "$SCRIPT" --title "!!! ???"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# AC4 — stdin invocation
# ---------------------------------------------------------------------------

@test "AC4: stdin pipe 'Add User Auth!' -> add-user-auth (Scenario 5)" {
  run bash -c "echo 'Add User Auth!' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "add-user-auth" ]
}

# ---------------------------------------------------------------------------
# AC4 — empty --title
# ---------------------------------------------------------------------------

@test "AC4: --title '' -> empty string, exit 0 (Scenario 6)" {
  run "$SCRIPT" --title ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Extra coverage — numeric-only and mixed case (Scenarios 7, 8)
# ---------------------------------------------------------------------------

@test "Scenario 7: --title '123 456' -> 123-456" {
  run "$SCRIPT" --title "123 456"
  [ "$status" -eq 0 ]
  [ "$output" = "123-456" ]
}

@test "Scenario 8: --title 'MixedCase' -> mixedcase" {
  run "$SCRIPT" --title "MixedCase"
  [ "$status" -eq 0 ]
  [ "$output" = "mixedcase" ]
}

# ---------------------------------------------------------------------------
# AC5 — script header invariants
# ---------------------------------------------------------------------------

@test "AC5: script exists at the canonical path" {
  [ -f "$SCRIPT" ]
}

@test "AC5: script is executable (mode 0755)" {
  [ -x "$SCRIPT" ]
  # Portable mode read: stat on macOS uses -f, on GNU coreutils uses -c.
  local mode
  if mode="$(stat -f '%Lp' "$SCRIPT" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' "$SCRIPT")"
  fi
  [ "$mode" = "755" ]
}

@test "AC5: script begins with #!/usr/bin/env bash" {
  run head -n1 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]
}

@test "AC5: script sets 'set -euo pipefail'" {
  run grep -E '^set -euo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "AC5: script sets 'LC_ALL=C'" {
  run grep -E '^LC_ALL=C|^export LC_ALL' "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# E63-S12 — canonical Usage block for --help / -h (replaces header-dump)
# ---------------------------------------------------------------------------

@test "E63-S12 AC1: --help stdout contains literal 'Usage:'" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^Usage:'
}

@test "E63-S12 AC1: --help stdout enumerates --title and --help flags" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  # Test scenario #3: at least 2 matches across --title and --help
  local match_count
  match_count=$(echo "$output" | grep -E -c -- '(--title|--help)')
  [ "$match_count" -ge 2 ]
}

@test "E63-S12 AC2: -h emits same block as --help (byte-for-byte)" {
  local short_out long_out
  short_out="$("$SCRIPT" -h)"
  long_out="$("$SCRIPT" --help)"
  [ "$short_out" = "$long_out" ]
}

@test "E63-S12 AC3: --help enumerates exit code 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  # Help must mention exit code 0 (success).
  echo "$output" | grep -E -q 'exit.*0|0.*success|Exit.*0'
}

@test "E63-S12 AC4: --help merged stderr contains literal 'Usage' (defect-surface guard)" {
  # Mirrors gaia-public/plugins/gaia/tests/cluster-7/create-story-e2e.bats AC2
  # defect-surface check: \`script --help 2>&1 | grep -i 'usage'\`. Once this
  # passes, slugify.sh is no longer enumerated in that test's stderr defect list.
  run bash -c "'$SCRIPT' --help 2>&1 | grep -i 'usage'"
  [ "$status" -eq 0 ]
}
