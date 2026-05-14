#!/usr/bin/env bats
# add-feature-step8.bats — E89-S2 Step 8 deferred-seed-brief mode tests.
#
# Covers TC-AFE-5..8 (foundation-level, not full integration):
#   TC-AFE-5: SKILL.md Step 8 documents both modes
#   TC-AFE-6: SKILL.md documents the Before/After default flip
#   TC-AFE-7: --step-8-mode CLI flag accepts both valid values
#   TC-AFE-8: --step-8-mode rejects invalid values with canonical stderr

load 'test_helper.bash'

setup() {
  common_setup
  SETUP_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts" && pwd)/setup.sh"
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature" && pwd)/SKILL.md"
  export SETUP_SH SKILL_MD
}

teardown() {
  common_teardown
}

# ---------------- TC-AFE-5: Step 8 documents both modes ----------------
@test "TC-AFE-5: SKILL.md Step 8 documents inline-dispatch and deferred-seed-brief modes" {
  [ -f "$SKILL_MD" ]
  grep -qF "inline-dispatch" "$SKILL_MD"
  grep -qF "deferred-seed-brief" "$SKILL_MD"
}

# ---------------- TC-AFE-6: Before/After default flip documented ----------------
@test "TC-AFE-6: SKILL.md documents the Before/After default flip" {
  [ -f "$SKILL_MD" ]
  grep -qE 'BEFORE \(pre-E89-S2\)' "$SKILL_MD"
  grep -qE 'AFTER \(post-E89-S2\)' "$SKILL_MD"
}

# ---------------- TC-AFE-7: --step-8-mode accepts valid values ----------------
@test "TC-AFE-7a: --step-8-mode=inline-dispatch is accepted (passes flag-parsing)" {
  run "$SETUP_SH" --step-8-mode=inline-dispatch
  [[ "$output" != *"invalid --step-8-mode value"* ]]
}

@test "TC-AFE-7b: --step-8-mode=deferred-seed-brief is accepted" {
  run "$SETUP_SH" --step-8-mode=deferred-seed-brief
  [[ "$output" != *"invalid --step-8-mode value"* ]]
}

@test "TC-AFE-7c: --step-8-mode <value> next-arg form is accepted" {
  run "$SETUP_SH" --step-8-mode inline-dispatch
  [[ "$output" != *"invalid --step-8-mode value"* ]]
}

# ---------------- TC-AFE-8: --step-8-mode rejects invalid values ----------------
@test "TC-AFE-8: --step-8-mode=invalid-value is rejected with canonical stderr" {
  run "$SETUP_SH" --step-8-mode=frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"gaia-add-feature: invalid --step-8-mode value"* ]]
  [[ "$output" == *"frobnicate"* ]]
}

# ---------------- TC-AFE-9: SKILL.md Step 8 documents YOLO-keyed default ----------------
@test "TC-AFE-9: SKILL.md documents YOLO-keyed default selection (AC2)" {
  [ -f "$SKILL_MD" ]
  # Both branches must be documented.
  grep -qE 'YOLO active.*inline-dispatch|YOLO active.*default mode is .inline-dispatch.' "$SKILL_MD"
  grep -qE 'YOLO inactive.*deferred-seed-brief|YOLO inactive.*default mode is .deferred-seed-brief.' "$SKILL_MD"
}

# ---------------- TC-AFE-10: SKILL.md documents the seed-brief shape (AC4) ----------------
@test "TC-AFE-10: SKILL.md Step 8 documents the seed-brief content shape" {
  [ -f "$SKILL_MD" ]
  grep -qF "Story seed brief for <story_key>" "$SKILL_MD"
  grep -qF "next-story-id.sh" "$SKILL_MD"
}
