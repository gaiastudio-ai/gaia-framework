#!/usr/bin/env bats
# test-plan-schema-detection.bats — AF-2026-05-17-1 regression guard
#
# Asserts that the /gaia-test-gap-analysis SKILL.md Pinned Schemas section
# acknowledges the test-plan heterogeneous-table reality discovered on
# 2026-05-17:
#   - On the GAIA-Framework reference project the test-plan contains 64
#     distinct table-header shapes across 435 tables; the canonical pinned
#     schema matches 0 tables.
#   - The skill must surface a clear DEGRADED-MODE banner when no canonical
#     schema is detected, NOT silently tolerant-match into 100% unmapped.
#
# This is a documentation-only patch (AF-2026-05-17-1). No new matching
# logic is asserted here; the matching-logic redesign is deferred to a
# follow-on AF/epic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_MD="$REPO_ROOT/plugins/gaia/skills/gaia-test-gap-analysis/SKILL.md"
  export LC_ALL=C
}

@test "SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "Pinned Schemas section acknowledges section-scoped heterogeneous tables" {
  run grep -E '(section-scoped|heterogeneous)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "SKILL.md documents the three coverage signals (STRONG / MEDIUM / WEAK)" {
  run grep -E 'STRONG.*MEDIUM.*WEAK|STRONG|WEAK.*DEGRADED-MODE' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # All three signal labels must appear
  grep -q 'STRONG' "$SKILL_MD"
  grep -q 'MEDIUM' "$SKILL_MD"
  grep -q 'WEAK' "$SKILL_MD"
}

@test "SKILL.md mandates a DEGRADED-MODE banner contract" {
  run grep -E 'DEGRADED-MODE' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # Banner contract must mention the Executive Summary as the surface
  grep -q 'Executive Summary' "$SKILL_MD"
}

