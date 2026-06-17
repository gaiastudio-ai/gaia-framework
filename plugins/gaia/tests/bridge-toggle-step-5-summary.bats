#!/usr/bin/env bats
# bridge-toggle-step-5-summary.bats — E17-S36
#
# Covers the bridge-toggle Step 5 ("Post-Toggle Summary") prose additions:
# canonical path + generated runners + "edit to fine-tune" prompt.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  SKILL_MD="${PLUGIN_ROOT}/gaia/skills/gaia-bridge-toggle/SKILL.md"
}

# AC1 — Step 5 just_generated path includes canonical path + edit-prompt
@test "Step 5 just-generated path emits canonical-path + edit-to-fine-tune prompt" {
  STEP5=$(awk '/^## Step 5/{found=1} /^## Edge Cases/{found=0} found' "${SKILL_MD}")
  # Must mention canonical config path (AF-2026-05-21-8: post-ADR-111 .gaia/config/)
  echo "${STEP5}" | grep -qF ".gaia/config/test-environment.yaml"
  # Must include the edit-prompt (architecture §10.20.12.5.C canonical wording)
  echo "${STEP5}" | grep -qF "edit .gaia/config/test-environment.yaml to fine-tune for your project"
}

# AC2 — Step 5 already-present (not just generated) path emits path + runners but NOT the edit prompt
@test "Step 5 SKILL.md describes the already-present vs just-generated branch" {
  STEP5=$(awk '/^## Step 5/{found=1} /^## Edge Cases/{found=0} found' "${SKILL_MD}")
  # Must mention "just generated" or "just_generated" branch
  echo "${STEP5}" | grep -qiE "just[- ]generated|just[- ]auto[- ]generated"
}

# AC4 — YOLO mode replacement prompt
@test "Step 5 YOLO mode emits 'auto-generated for detected stack — review' nudge" {
  STEP5=$(awk '/^## Step 5/{found=1} /^## Edge Cases/{found=0} found' "${SKILL_MD}")
  echo "${STEP5}" | grep -qF "auto-generated for detected stack — review .gaia/config/test-environment.yaml if needed."
}

# Defense-in-depth: the just-generated signal mechanism is documented somewhere
@test "Step 4 → Step 5 just-generated signal is documented" {
  # Either an env var like GAIA_BRIDGE_JUST_GENERATED or a post_flip_result field
  STEP_4_AND_5=$(awk '/^## Step 4/,/^## (Step 6|disable|YOLO)/' "${SKILL_MD}")
  # Should mention some signal carrying "just generated" state forward
  echo "${STEP_4_AND_5}" | grep -qiE "just[- ]generated|GAIA_BRIDGE_JUST_GENERATED"
}
