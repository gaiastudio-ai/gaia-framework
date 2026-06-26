#!/usr/bin/env bats
# Tests that skill-proposal.sh helpers are documented via a usage() function
# and that SKILL.md Step 5e cross-references the documented helpers.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../skills/gaia-retro/scripts/skill-proposal.sh"
  SKILLMD="${BATS_TEST_DIRNAME}/../skills/gaia-retro/SKILL.md"
}

@test "skill-proposal.sh contains a usage function (AC1)" {
  grep -q '^usage()' "$SCRIPT"
}

@test "usage documents extract_tech_debt_reflection (AC2)" {
  # Run the script directly to capture usage output
  local out
  out="$(bash "$SCRIPT")"
  printf '%s' "$out" | grep -q 'extract_tech_debt_reflection'
}

@test "usage documents build_proposal (AC3)" {
  local out
  out="$(bash "$SCRIPT")"
  printf '%s' "$out" | grep -q 'build_proposal'
}

@test "usage documents validate_proposal (AC4)" {
  local out
  out="$(bash "$SCRIPT")"
  printf '%s' "$out" | grep -q 'validate_proposal'
}

@test "usage documents write_approved_proposal (AC5)" {
  local out
  out="$(bash "$SCRIPT")"
  printf '%s' "$out" | grep -q 'write_approved_proposal'
}

@test "SKILL.md Step 5e references usage docs (AC6)" {
  # The cross-reference should mention the usage function or --help
  grep -q 'usage()' "$SKILLMD" || grep -q -- '--help' "$SKILLMD"
}

@test "direct execution prints usage and exits 0 (AC7)" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"extract_tech_debt_reflection"* ]]
  [[ "$output" == *"build_proposal"* ]]
  [[ "$output" == *"validate_proposal"* ]]
  [[ "$output" == *"write_approved_proposal"* ]]
}

@test "header and usage agree on 100 KB size limit, not 8KB (AC-size-limit)" {
  # Header comment should mention 100 KB, NOT 8KB
  run grep -n '8KB' "$SCRIPT"
  [ "$status" -ne 0 ]   # no occurrence of "8KB"

  # Both header and usage should say "100 KB"
  run grep -c '100 KB' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]   # at least header + usage
}
