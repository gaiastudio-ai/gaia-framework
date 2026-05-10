#!/usr/bin/env bats
# E28-S227-td74-gaia-config-csv-cleanup.bats — TD-74 final cleanup regression guard
#
# Story: E28-S227 (TD-74 cleanup — strip last _gaia/_config/*.csv reference from
#                  gaia-party/SKILL.md)
# Epic: E28 (GAIA Native Conversion Program)
# ADR: ADR-049 (V1 Engine Retirement)
# Sprint: sprint-41
#
# Validates:
#   AC1 — `grep -rl '_gaia/_config/.*\.csv' gaia-public/plugins/gaia/skills/`
#         returns 0 lines (exit 1). Prior to this story it returned the
#         gaia-party/SKILL.md path.
#
#   Bonus — `gaia-party/SKILL.md` specifically contains zero matches of the
#           AC1 regex (the surgical site).
#
# Usage:
#   bats tests/skills/E28-S227-td74-gaia-config-csv-cleanup.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  PARTY_SKILL="$SKILLS_DIR/gaia-party/SKILL.md"
}

@test "AC1: no _gaia/_config/*.csv references remain anywhere under plugins/gaia/skills/" {
  # grep -r returns exit 1 with no stdout when no matches are found.
  run grep -rl '_gaia/_config/.*\.csv' "$SKILLS_DIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "Surgical: gaia-party/SKILL.md contains zero _gaia/_config/*.csv references" {
  [ -f "$PARTY_SKILL" ]
  run grep -c '_gaia/_config/.*\.csv' "$PARTY_SKILL"
  # grep -c emits "0" and exits 1 when there are no matches.
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}
