#!/usr/bin/env bats
# af-2026-05-21-14-ux-canonical.bats
#
# Regression coverage for AF-2026-05-21-14: the UX cluster pair (gaia-create-ux
# + gaia-edit-ux) hardcoded legacy docs/planning-artifacts/ paths in SKILL.md
# prose. Hybrid pattern: gaia-create-ux/scripts/finalize.sh already implements
# E96-S7 canonical-first two-tier (no edit needed; assert intact);
# gaia-edit-ux/scripts/setup.sh had bare legacy default (three-tier idiom
# applied per AF-21-10/-11/-12 pattern).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CREATE_UX_SKILL="$PLUGIN_ROOT/skills/gaia-create-ux/SKILL.md"
  EDIT_UX_SKILL="$PLUGIN_ROOT/skills/gaia-edit-ux/SKILL.md"
  CREATE_UX_FINALIZE="$PLUGIN_ROOT/skills/gaia-create-ux/scripts/finalize.sh"
  EDIT_UX_SETUP="$PLUGIN_ROOT/skills/gaia-edit-ux/scripts/setup.sh"
  cd "$TEST_TMP"
}

teardown() { common_teardown; }

# Helper: replicate the three-tier UX_DESIGN_PATH resolution from edit-ux/setup.sh:66-80.
resolve_ux_design_path() {
  local project_root="$1"
  if [ -n "${UX_DESIGN_PATH:-}" ]; then
    printf '%s' "$UX_DESIGN_PATH"
    return
  fi
  if [ -f "$project_root/docs/planning-artifacts/ux-design.md" ] && [ ! -d "$project_root/.gaia/artifacts/planning-artifacts" ]; then
    printf '%s' "$project_root/docs/planning-artifacts/ux-design.md"
  else
    printf '%s' "$project_root/.gaia/artifacts/planning-artifacts/ux-design.md"
  fi
}

# --- SKILL.md prose canonical assertions ---

@test "AF-21-14: gaia-create-ux/SKILL.md write-path prose uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/planning-artifacts/ux-design.md' "$CREATE_UX_SKILL"
}

@test "AF-21-14: gaia-create-ux/SKILL.md has no remaining legacy docs/ write-path literals" {
  ! grep -qE 'docs/(planning-artifacts|test-artifacts)' "$CREATE_UX_SKILL"
}

@test "AF-21-14: gaia-edit-ux/SKILL.md write-path prose uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/planning-artifacts/ux-design.md' "$EDIT_UX_SKILL"
}

@test "AF-21-14: gaia-edit-ux/SKILL.md Mission paragraph documents the three-tier idiom" {
  grep -qF 'three-tier idiom' "$EDIT_UX_SKILL"
  grep -qF 'UX_DESIGN_PATH' "$EDIT_UX_SKILL"
}

# --- Regression guard: gaia-create-ux/scripts/finalize.sh canonical-first intact ---

@test "AF-21-14: gaia-create-ux/scripts/finalize.sh retains canonical-first resolution (E96-S7 from AF-21-13 pattern)" {
  grep -qE 'if \[ -f "\.gaia/artifacts/planning-artifacts/ux-design\.md" \]' "$CREATE_UX_FINALIZE"
  grep -qE 'elif \[ -f "docs/planning-artifacts/ux-design\.md" \]' "$CREATE_UX_FINALIZE"
}

# --- New three-tier idiom assertions for gaia-edit-ux/scripts/setup.sh ---

@test "AF-21-14: gaia-edit-ux/scripts/setup.sh implements three-tier idiom verbatim" {
  grep -qF '.gaia/artifacts/planning-artifacts/ux-design.md' "$EDIT_UX_SETUP"
  grep -qF '[ ! -d "$PROJECT_ROOT/.gaia/artifacts/planning-artifacts" ]' "$EDIT_UX_SETUP"
  grep -qE 'if \[ -z "\$\{UX_DESIGN_PATH:-\}" \]' "$EDIT_UX_SETUP"
}

@test "AF-21-14: edit-ux setup.sh — greenfield (no UX anywhere) → resolves to canonical default" {
  unset UX_DESIGN_PATH
  result=$(resolve_ux_design_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/ux-design.md" ]
}

@test "AF-21-14: edit-ux setup.sh — post-ADR-111 (only .gaia/ exists) → resolves to canonical" {
  unset UX_DESIGN_PATH
  mkdir -p ".gaia/artifacts/planning-artifacts"
  echo "# UX" > ".gaia/artifacts/planning-artifacts/ux-design.md"
  result=$(resolve_ux_design_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/ux-design.md" ]
  [ ! -d "docs" ]
}

@test "AF-21-14: edit-ux setup.sh — pre-ADR-111 (only docs/, no .gaia/) → legacy back-compat preserved" {
  unset UX_DESIGN_PATH
  mkdir -p "docs/planning-artifacts"
  echo "# Legacy UX" > "docs/planning-artifacts/ux-design.md"
  result=$(resolve_ux_design_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/docs/planning-artifacts/ux-design.md" ]
  [ ! -d ".gaia" ]
}

@test "AF-21-14: edit-ux setup.sh — both present (mid-migration) → canonical wins" {
  unset UX_DESIGN_PATH
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/ux-design.md"
  echo "# Legacy (should NOT be used)" > "docs/planning-artifacts/ux-design.md"
  result=$(resolve_ux_design_path "$TEST_TMP")
  [ "$result" = "$TEST_TMP/.gaia/artifacts/planning-artifacts/ux-design.md" ]
}

@test "AF-21-14: edit-ux setup.sh — UX_DESIGN_PATH env-var override (Tier 1) wins" {
  mkdir -p ".gaia/artifacts/planning-artifacts" "docs/planning-artifacts" "custom-location"
  echo "# Canonical" > ".gaia/artifacts/planning-artifacts/ux-design.md"
  echo "# Legacy" > "docs/planning-artifacts/ux-design.md"
  echo "# Custom" > "custom-location/my-ux.md"
  export UX_DESIGN_PATH="$TEST_TMP/custom-location/my-ux.md"
  result=$(resolve_ux_design_path "$TEST_TMP")
  unset UX_DESIGN_PATH
  [ "$result" = "$TEST_TMP/custom-location/my-ux.md" ]
}
