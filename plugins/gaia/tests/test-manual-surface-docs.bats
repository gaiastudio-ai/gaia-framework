#!/usr/bin/env bats
# test-manual-surface-docs.bats — AC4: documentation completeness
#
# Validates that SKILL.md includes a "Relationship to Existing Testing
# Skills" section naming all 6 sibling skills, and does NOT reference
# PLUGIN_DIR (the non-substrate variable).
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  SKILL_MD="$PLUGIN_DIR/skills/gaia-test-manual/SKILL.md"
}

teardown() {
  :
}

# ---------- AC4: Relationship section exists ----------

@test "AC4: SKILL.md contains Relationship to Existing Testing Skills section" {
  grep -q "Relationship to Existing Testing Skills" "$SKILL_MD"
}

# ---------- AC4: All 6 sibling skills named ----------

@test "AC4: Relationship section names gaia-test-e2e" {
  grep -q "gaia-test-e2e" "$SKILL_MD"
}

@test "AC4: Relationship section names gaia-test-mobile-e2e" {
  grep -q "gaia-test-mobile-e2e" "$SKILL_MD"
}

@test "AC4: Relationship section names gaia-test-a11y" {
  grep -q "gaia-test-a11y" "$SKILL_MD"
}

@test "AC4: Relationship section names gaia-review-mobile" {
  grep -q "gaia-review-mobile" "$SKILL_MD"
}

@test "AC4: Relationship section names gaia-test-device-matrix" {
  grep -q "gaia-test-device-matrix" "$SKILL_MD"
}

@test "AC4: Relationship section names gaia-config-device-target" {
  grep -q "gaia-config-device-target" "$SKILL_MD"
}

# ---------- AC4: No PLUGIN_DIR reference ----------

@test "AC4: SKILL.md does not reference PLUGIN_DIR variable" {
  ! grep -q 'PLUGIN_DIR' "$SKILL_MD"
}

# ---------- AC4: Supported Surfaces section exists ----------

@test "AC4: SKILL.md contains Supported Surfaces section" {
  grep -q "Supported Surfaces" "$SKILL_MD"
}

# ---------- AC4: Step 1b surface resolution documented ----------

@test "AC4: SKILL.md documents surface profile resolution step" {
  grep -qi "surface" "$SKILL_MD"
}
