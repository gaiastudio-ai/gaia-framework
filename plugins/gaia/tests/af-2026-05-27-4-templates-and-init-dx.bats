#!/usr/bin/env bats
# af-2026-05-27-4-templates-and-init-dx.bats
#
# AF-2026-05-27-4 / Test05 F-002, F-005, F-006, F-007, F-008, F-013, F-014, F-055.
# PRD/UX template completeness + /gaia-init developer-experience fixes.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PRD_TPL="$PLUGIN_ROOT/skills/gaia-create-prd/prd-template.md"
  PRD_EX="$PLUGIN_ROOT/skills/gaia-create-prd/prd-example.md"
  PRD_SKILL="$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
  STRIP="$PLUGIN_ROOT/skills/gaia-create-prd/scripts/strip-brownfield-block.sh"
  UX_TPL="$PLUGIN_ROOT/skills/gaia-create-ux/ux-design-template.md"
  UX_SKILL="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  INIT_SKILL="$PLUGIN_ROOT/skills/gaia-init/SKILL.md"
  GEN_CONFIG="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}
teardown() { common_teardown; }

# ---------- F-005 / F-006: PRD template ----------

@test "F-005: PRD template documents the MoSCoW <-> P0-P3 mapping" {
  grep -qiE 'MoSCoW|Must-Have.*P0|P0.*Must-Have' "$PRD_TPL"
  grep -qF 'Must-Have' "$PRD_TPL"
  grep -qF 'P0' "$PRD_TPL"
}

@test "F-006: PRD template User Journeys has a Path column with happy + error rows" {
  grep -qE '\| Journey \| Path \| Trigger \| Steps \| Outcome \|' "$PRD_TPL"
  grep -qE '\| .* \| happy \|' "$PRD_TPL"
  grep -qE '\| .* \| error \|' "$PRD_TPL"
}

# ---------- F-007: brownfield-block strip helper ----------

@test "F-007: strip-brownfield-block.sh exists and is executable" {
  [ -x "$STRIP" ]
  bash -n "$STRIP"
}

@test "F-007: strip removes the BROWNFIELD-ONLY block and is idempotent" {
  cp "$PRD_TPL" "$TEST_TMP/prd.md"
  [ "$(grep -cF '<!-- BROWNFIELD-ONLY-START -->' "$TEST_TMP/prd.md")" -eq 1 ]
  run bash "$STRIP" "$TEST_TMP/prd.md"
  [ "$status" -eq 0 ]
  [ "$(grep -cF '<!-- BROWNFIELD-ONLY-START -->' "$TEST_TMP/prd.md")" -eq 0 ]
  [ "$(grep -cF '<!-- BROWNFIELD-ONLY-END -->' "$TEST_TMP/prd.md")" -eq 0 ]
  # idempotent no-op on the second run
  run bash "$STRIP" "$TEST_TMP/prd.md"
  [ "$status" -eq 0 ]
}

@test "F-007: strip refuses a malformed block (START without END)" {
  printf -- '# X\n<!-- BROWNFIELD-ONLY-START -->\nstuff\n' > "$TEST_TMP/bad.md"
  run bash "$STRIP" "$TEST_TMP/bad.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed"* ]]
  # file left untouched
  grep -qF '<!-- BROWNFIELD-ONLY-START -->' "$TEST_TMP/bad.md"
}

@test "F-007: gaia-create-prd SKILL.md documents the greenfield strip step" {
  grep -qF 'strip-brownfield-block.sh' "$PRD_SKILL"
}

# ---------- F-008: example PRD ----------

@test "F-008: an example PRD ships in the skill directory and is referenced" {
  [ -f "$PRD_EX" ]
  grep -qiF 'calibration reference' "$PRD_EX"
  grep -qF 'prd-example.md' "$PRD_SKILL"
}

# ---------- F-013 / F-014: UX templates ----------

@test "F-013: a greenfield ux-design-template.md ships in the UX skill dir" {
  [ -f "$UX_TPL" ]
  grep -qF "template: 'ux-design'" "$UX_TPL"
  # structural sections present
  grep -qE '^## 2\. Personas' "$UX_TPL"
  grep -qE '^## 7\. Accessibility' "$UX_TPL"
}

@test "F-013: gaia-create-ux SKILL.md resolves the greenfield template by mode" {
  grep -qF 'ux-design-template.md' "$UX_SKILL"
  grep -qiE 'greenfield' "$UX_SKILL"
}

@test "F-014: UX template + SKILL.md provide a no-Figma fallback placeholder" {
  grep -qiF 'No Figma source' "$UX_TPL"
  grep -qiF 'No Figma source' "$UX_SKILL"
}

# ---------- F-002: init questionnaire env-by-phase ----------

@test "F-002: gaia-init SKILL.md scopes the env requirement to config_phase=full" {
  grep -qF 'F-002' "$INIT_SKILL"
  grep -qiE 'full.*requires.*environments|at least one environment' "$INIT_SKILL"
  # The bare "none is OK" should now be phase-qualified, not unconditional.
  grep -qiF 'only say "none is OK" when NOT in full mode' "$INIT_SKILL"
}

# ---------- F-055: init seeds a .gitignore ----------

@test "F-055: generate-config.sh seeds a .gitignore with .DS_Store + .gaia runtime excludes" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj"
  run bash -c "printf '{}' | bash '$GEN_CONFIG' --path '$proj' --name demo --phase minimal"
  [ "$status" -eq 0 ]
  [ -f "$proj/.gitignore" ]
  grep -qF '.DS_Store' "$proj/.gitignore"
  grep -qF '.gaia/memory/' "$proj/.gitignore"
  grep -qF '# --- GAIA (added by /gaia-init) ---' "$proj/.gitignore"
}

@test "F-055: generate-config.sh appends the GAIA block to an existing .gitignore once" {
  local proj="$TEST_TMP/proj2"
  mkdir -p "$proj"
  printf 'node_modules/\n' > "$proj/.gitignore"
  run bash -c "printf '{}' | bash '$GEN_CONFIG' --path '$proj' --name demo --phase minimal"
  [ "$status" -eq 0 ]
  grep -qF 'node_modules/' "$proj/.gitignore"        # preserved
  grep -qF '.DS_Store' "$proj/.gitignore"            # appended
  [ "$(grep -cF '# --- GAIA (added by /gaia-init) ---' "$proj/.gitignore")" -eq 1 ]
}
