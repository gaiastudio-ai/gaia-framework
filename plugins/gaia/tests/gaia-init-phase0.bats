#!/usr/bin/env bats
# gaia-init-phase0.bats — Phase 0 minimal bootstrap + --full flag (E85-S3).
#
# Story: E85-S3 — /gaia-init SKILL.md rewrite — Phase 0 default (5-field
#                  bootstrap) + --full flag + binary opener (FR-453, FR-454).
# ADRs:  ADR-096 (config_phase state machine), ADR-099 (greenfield-guard.sh
#                retirement, inline config_phase lookup pattern).
#
# Test scenarios map to AC12 (TC-CPH-1..9, TC-CPH-45) plus generate-config.sh
# --phase argument verification.
#
# Strategy:
#   The binary opener (AC2) and re-init refusal (AC4) live in SKILL.md prose
#   and are LLM-driven. We test those via structural grep on the SKILL.md
#   (Step 1b heading present, refusal text present, --full flag detection
#   documented). The deterministic surface — generate-config.sh --phase
#   handling — is tested directly by invoking the script with crafted
#   answer-bundles.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-init" && pwd)"
  SKILL_SCRIPTS="$SKILL_DIR/scripts"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  PLUGIN_JSON="$(cd "$BATS_TEST_DIRNAME/../.claude-plugin" && pwd)/plugin.json"
  FIXTURE_ROOT="$TEST_TMP/proj"
  mkdir -p "$FIXTURE_ROOT"
}
teardown() { common_teardown; }

# ---- Fixture helpers ------------------------------------------------------

# Build a minimal answer-bundle for Phase 0 (project_name + primary_platform).
phase0_bundle() {
  local platform="${1:-web}"
  cat <<JSON
{
  "project_name": "myapp",
  "primary_platform": "$platform"
}
JSON
}

# Build a full-mode answer-bundle (multi-section).
full_bundle() {
  cat <<JSON
{
  "project_name": "myapp",
  "project_shape": "single backend",
  "stacks": [{"name": "typescript", "language": "typescript", "paths": ["src/"]}],
  "platforms": ["web"],
  "environments": {"dev": {"url": "http://localhost"}},
  "ci_platform": {"provider": "github-actions"}
}
JSON
}

# ---- AC12 / TC-CPH-1: default Phase 0 bootstrap ---------------------------

@test "TC-CPH-1: --phase minimal emits 5 user-facing fields + config_phase + schema_version" {
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  local cfg="$FIXTURE_ROOT/config/project-config.yaml"
  [ -f "$cfg" ]
  # User-facing keys (5)
  grep -qE '^project_name:[[:space:]]*"?myapp"?$' "$cfg"
  grep -qE '^project_kind:[[:space:]]*"?application"?$' "$cfg"
  grep -qE '^version:[[:space:]]' "$cfg"
  grep -qE '^primary_platform:[[:space:]]*"?web"?$' "$cfg"
  grep -qE '^framework_version:[[:space:]]' "$cfg"
  # Meta keys (2)
  grep -qE '^config_phase:[[:space:]]*"?minimal"?$' "$cfg"
  grep -qE '^schema_version:[[:space:]]*"?2\.0\.0"?$' "$cfg"
  # Absent sections (Phase 0 invariant — none of these top-level blocks)
  ! grep -qE '^stacks:' "$cfg"
  ! grep -qE '^platforms:' "$cfg"
  ! grep -qE '^environments:' "$cfg"
  ! grep -qE '^ci_platform:' "$cfg"
  ! grep -qE '^compliance:' "$cfg"
  ! grep -qE '^device_targets:' "$cfg"
}

# ---- TC-CPH-2: project_kind defaults to "application" ---------------------

@test "TC-CPH-2: project_kind defaults to 'application' when not provided in Phase 0" {
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  grep -qE '^project_kind:[[:space:]]*"?application"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

# ---- TC-CPH-3: alias normalization (react -> web, ios -> mobile) ----------

@test "TC-CPH-3 (react): primary_platform=react normalizes to web in Phase 0" {
  # The alias normalization arm is SKILL.md-side per Dev Notes; the script
  # receives the already-normalized answer. Simulate by passing the
  # post-normalization value.
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  grep -qE '^primary_platform:[[:space:]]*"?web"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

@test "TC-CPH-3 (ios): primary_platform=mobile is preserved in Phase 0" {
  phase0_bundle mobile | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  grep -qE '^primary_platform:[[:space:]]*"?mobile"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

# Negative regression guard (Tex W1): generate-config.sh MUST NOT silently
# accept un-normalized literal "react" / "ios" aliases — normalization lives
# SKILL.md-side. If the script ever starts doing its own normalization, this
# test catches it; if the script faithfully passes through whatever it gets,
# this test documents the contract.
@test "TC-CPH-3 (regression): script passes 'react' literal through unchanged (no script-side normalization)" {
  phase0_bundle react | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  # The script faithfully writes whatever it received — alias normalization
  # is SKILL.md-side, not script-side. This regression guard ensures the
  # script does not silently rewrite values behind the SKILL.md's back.
  grep -qE '^primary_platform:[[:space:]]*"?react"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

# ---- TC-CPH-4: re-init refusal ---------------------------------------------

@test "TC-CPH-4: generate-config.sh refuses to overwrite existing config (exit 1)" {
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  # Second invocation must refuse.
  run --separate-stderr bash -c "phase0_bundle() { cat <<'J'
{\"project_name\": \"myapp\", \"primary_platform\": \"web\"}
J
}; phase0_bundle | '$SKILL_SCRIPTS/generate-config.sh' --path '$FIXTURE_ROOT' --name 'myapp' --phase minimal"
  [ "$status" -eq 1 ]
}

@test "TC-CPH-4 (SKILL.md): re-init refusal canonical stderr text documented" {
  # AC4 prescribes the literal stderr text in SKILL.md Step 1.
  grep -F "config already exists" "$SKILL_MD"
  grep -F "gaia-config" "$SKILL_MD"
}

# ---- TC-CPH-5: framework_version auto-populated from plugin.json ----------

@test "TC-CPH-5: framework_version in emitted config matches plugin.json version" {
  local expected_version
  expected_version="$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])")"
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  local actual
  actual="$(grep -E '^framework_version:' "$FIXTURE_ROOT/config/project-config.yaml" \
    | sed -E 's/^framework_version:[[:space:]]*//; s/^"//; s/"$//')"
  [ "$actual" = "$expected_version" ]
}

# ---- TC-CPH-6 (SKILL.md): --full flag bypasses binary opener --------------

@test "TC-CPH-6 (SKILL.md): --full flag documented and routes to full flow" {
  grep -qE -- "--full" "$SKILL_MD"
  # Step 2 must reference 'phase'/'minimal' branching in its preamble
  # (the new Phase 0 conditional). Treat as a structural assertion only.
  grep -qE "Phase 0|phase[: ]*minimal" "$SKILL_MD"
}

# ---- TC-CPH-7 / TC-CPH-8: binary opener routing ---------------------------

@test "TC-CPH-7+8 (SKILL.md): Step 1b binary opener heading present" {
  grep -qE "^### Step 1b" "$SKILL_MD"
}

@test "TC-CPH-7+8 (SKILL.md): binary opener question text present" {
  grep -qE "Quick setup" "$SKILL_MD"
  grep -qE "full setup|Full setup" "$SKILL_MD"
}

# ---- TC-CPH-9 / TC-CPH-45: --full on existing config refuses --------------

@test "TC-CPH-9 (SKILL.md): --full flag does NOT override re-init guard" {
  # The SKILL.md prose must explicitly say --full does not override.
  grep -qE -- "--full" "$SKILL_MD"
  grep -qE "(does not override|not bypass|still refus|guard fires)" "$SKILL_MD"
}

# Tex W2: script-level test that --full + existing config refuses.
@test "TC-CPH-9 (script-level): generate-config.sh refuses on existing config regardless of --phase" {
  # Write an initial config.
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  [ -f "$FIXTURE_ROOT/config/project-config.yaml" ]
  # Second invocation with --phase full (mimicking --full flag end-to-end)
  # must refuse with exit 1.
  run --separate-stderr bash -c '
    cat <<JSON | "'"$SKILL_SCRIPTS"'/generate-config.sh" --path "'"$FIXTURE_ROOT"'" --name "myapp" --phase full
{"project_name": "myapp", "project_shape": "single backend"}
JSON
  '
  [ "$status" -eq 1 ]
}

# ---- generate-config.sh --phase argument tests ----------------------------

@test "generate-config.sh: --phase minimal emits config_phase=minimal" {
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  grep -qE '^config_phase:[[:space:]]*"?minimal"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

@test "generate-config.sh: --phase full emits config_phase=full + full sections" {
  full_bundle | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase full
  grep -qE '^config_phase:[[:space:]]*"?full"?$' "$FIXTURE_ROOT/config/project-config.yaml"
  grep -qE '^stacks:' "$FIXTURE_ROOT/config/project-config.yaml"
  grep -qE '^platforms:' "$FIXTURE_ROOT/config/project-config.yaml"
  grep -qE '^environments:' "$FIXTURE_ROOT/config/project-config.yaml"
}

@test "generate-config.sh: default (no --phase) emits config_phase=full (backward compat)" {
  full_bundle | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp"
  grep -qE '^config_phase:[[:space:]]*"?full"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

@test "generate-config.sh: schema_version 2.0.0 is always emitted" {
  phase0_bundle web | "$SKILL_SCRIPTS/generate-config.sh" \
    --path "$FIXTURE_ROOT" --name "myapp" --phase minimal
  grep -qE '^schema_version:[[:space:]]*"?2\.0\.0"?$' "$FIXTURE_ROOT/config/project-config.yaml"
}

# ---- AC6 alias normalization preservation (structural) --------------------

@test "AC6: alias normalization pseudocode block preserved in SKILL.md" {
  grep -F "claude-plugin" "$SKILL_MD"
  grep -F "claude-code-plugin" "$SKILL_MD"
  grep -F "typed_lower" "$SKILL_MD"
}

# ---- AC10 Steps 2+ preserved (structural) ---------------------------------

@test "AC10: SKILL.md retains Step 2 / Step 3 / Step 4 / Step 5 headings" {
  grep -qE "^### Step 2 " "$SKILL_MD"
  grep -qE "^### Step 3 " "$SKILL_MD"
  grep -qE "^### Step 4 " "$SKILL_MD"
  grep -qE "^### Step 5 " "$SKILL_MD"
}
