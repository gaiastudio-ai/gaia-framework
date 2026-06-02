#!/usr/bin/env bats
# next-story-id.bats — E63-S2 / Work Item 6.2
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/next-story-id.sh.
# This script is the auto-allocation source for E63-S3
# (generate-frontmatter.sh) — any change here must be coordinated with that
# downstream consumer.
#
# Test scenarios trace back to the story Test Scenarios table:
#   #1 Empty epic returns S1                   (AC1)
#   #2 Contiguous stories return max+1         (AC2)
#   #3 Non-contiguous (gaps) return max+1      (AC3)
#   #4 Missing epics-file errors clearly       (AC4)
#   #5 Prefix overlap is anchored              (AC5)
#   AC6 — script header invariants (shebang, set -euo pipefail, LC_ALL=C, mode 0755)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/next-story-id.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — empty epic returns S1
# ---------------------------------------------------------------------------

@test "AC1: empty epic returns S1 (Scenario 1)" {
  run "$SCRIPT" --epic E1 --epics-file "$FIXTURES/epics-empty.md"
  [ "$status" -eq 0 ]
  [ "$output" = "E1-S1" ]
}

# ---------------------------------------------------------------------------
# AC2 — contiguous stories return max+1
# ---------------------------------------------------------------------------

@test "AC2: contiguous E1-S1..S3 returns E1-S4 (Scenario 2)" {
  run "$SCRIPT" --epic E1 --epics-file "$FIXTURES/epics-contiguous.md"
  [ "$status" -eq 0 ]
  [ "$output" = "E1-S4" ]
}

# ---------------------------------------------------------------------------
# AC3 — non-contiguous numbering returns max+1 (no backfill)
# ---------------------------------------------------------------------------

@test "AC3: gaps E1-S1,S3,S7 returns E1-S8 — no backfill (Scenario 3)" {
  run "$SCRIPT" --epic E1 --epics-file "$FIXTURES/epics-gaps.md"
  [ "$status" -eq 0 ]
  [ "$output" = "E1-S8" ]
}

# ---------------------------------------------------------------------------
# AC4 — missing epics-file errors clearly
# ---------------------------------------------------------------------------

@test "AC4: missing epics-file exits non-zero with stderr naming the path (Scenario 4)" {
  run "$SCRIPT" --epic E1 --epics-file /nonexistent/path/to/epics.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"/nonexistent/path/to/epics.md"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — prefix overlap is anchored
# ---------------------------------------------------------------------------

@test "AC5: query E1 ignores E10-Sx, returns E1-S6 (Scenario 5)" {
  run "$SCRIPT" --epic E1 --epics-file "$FIXTURES/epics-overlap-prefix.md"
  [ "$status" -eq 0 ]
  [ "$output" = "E1-S6" ]
}

# ---------------------------------------------------------------------------
# AC5 reverse — query E10 ignores E1-Sx
# ---------------------------------------------------------------------------

@test "AC5 reverse: query E10 returns E10-S4 (max E10 is S3)" {
  run "$SCRIPT" --epic E10 --epics-file "$FIXTURES/epics-overlap-prefix.md"
  [ "$status" -eq 0 ]
  [ "$output" = "E10-S4" ]
}

# ---------------------------------------------------------------------------
# AC4 — missing required flag
# ---------------------------------------------------------------------------

@test "AC4: missing --epic flag exits non-zero with usage on stderr" {
  run "$SCRIPT" --epics-file "$FIXTURES/epics-empty.md"
  [ "$status" -ne 0 ]
}

@test "AC4: missing --epics-file flag exits non-zero with usage on stderr" {
  run "$SCRIPT" --epic E1
  [ "$status" -ne 0 ]
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
