#!/usr/bin/env bats
# e77-s9-init-plugin-option.bats — Tier 1 — `/gaia-init` option 6: Claude Code plugin (FR-411).
# Story: E77-S9.
#
# Acceptance criteria coverage:
#   AC1 — option 6 "Claude Code plugin" is listed alongside options 1-5 in the menu (SKILL.md).
#   AC2 — selecting option 6 produces project-config.yaml with project_kind: "claude-code-plugin"
#         and stack: claude-code-plugin reference.
#   AC3 — selecting option 6 seeds shellcheck, bats, markdownlint, yamllint in tool_adapters:.
#   AC4 — option 7 ("multi-plugin marketplace") is NOT in the menu and is NOT seeded.
#   AC5 — selecting any of options 1-5 leaves existing behavior unchanged (backward compat).

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-init" && pwd)"
  SKILL_SCRIPTS="$SKILL_DIR/scripts"
  STACKS_DIR="$(cd "$BATS_TEST_DIRNAME/../config/stacks" && pwd)"
}
teardown() { common_teardown; }

# --- AC1: SKILL.md menu lists option 6 ------------------------------------

@test "AC1: SKILL.md project-shape list includes claude-code-plugin (option 6)" {
  grep -F 'claude-code-plugin' "$SKILL_DIR/SKILL.md"
}

@test "AC1: SKILL.md describes claude-code-plugin as 'Claude Code plugin'" {
  # The user-facing label for option 6.
  grep -E 'Claude Code plugin' "$SKILL_DIR/SKILL.md"
}

# --- AC4: option 7 ("multi-plugin marketplace") is NOT in menu ------------

@test "AC4: SKILL.md does NOT include option 7 'multi-plugin marketplace'" {
  ! grep -F 'multi-plugin marketplace' "$SKILL_DIR/SKILL.md"
}

@test "AC4: SKILL.md does NOT include 'marketplace' in project-shape list" {
  # The project-shape question MUST stay at 6 options. Marketplace is out of scope.
  ! grep -E '^[[:space:]]*-[[:space:]]+marketplace[[:space:]]*$' "$SKILL_DIR/SKILL.md"
}

# --- AC2: generate-config.sh emits project_kind + stack reference ---------

@test "AC2: generate-config.sh emits project_kind: claude-code-plugin when project_shape=claude-code-plugin" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  [ -s "$TEST_TMP/proj/config/project-config.yaml" ]
  grep -E '^project_kind:[[:space:]]*"?claude-code-plugin"?[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC2: generate-config.sh emits stacks block referencing claude-code-plugin when project_shape=claude-code-plugin" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  grep -F 'stacks:' "$TEST_TMP/proj/config/project-config.yaml"
  # The stack name must reference the claude-code-plugin stack file.
  grep -E '^[[:space:]]*-[[:space:]]+name:[[:space:]]*"?claude-code-plugin"?[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

# --- AC3: tool_adapters seeded with shellcheck/bats/markdownlint/yamllint -

@test "AC3: generate-config.sh seeds tool_adapters when project_shape=claude-code-plugin" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  grep -F 'tool_adapters:' "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC3: tool_adapters includes shellcheck for plugin shape" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  # Match the canonical list-item line "  - shellcheck" so the test does not
  # accept a coincidental path-substring match in project_root: lines.
  grep -E '^[[:space:]]*-[[:space:]]+shellcheck[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC3: tool_adapters includes bats for plugin shape" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  grep -E '^[[:space:]]*-[[:space:]]+bats[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC3: tool_adapters includes markdownlint for plugin shape" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  grep -E '^[[:space:]]*-[[:space:]]+markdownlint[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC3: tool_adapters includes yamllint for plugin shape" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  grep -E '^[[:space:]]*-[[:space:]]+yamllint[[:space:]]*$' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

# --- AC4: NOT seeded with multi-plugin marketplace ------------------------

@test "AC4: generate-config.sh does NOT seed 'multi-plugin' or 'marketplace' for claude-code-plugin shape" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "claude-code-plugin"
}
JSON
  # Inspect only YAML-content lines, skipping the project_root: / project_path:
  # / memory_path: / checkpoint_path: / installed_path: lines whose values
  # are bats temp paths that may legitimately contain "multi-plugin" /
  # "marketplace" tokens from the test name itself. Only fail on actual
  # config-key references to those tokens.
  ! grep -vE '^(project_root|project_path|memory_path|checkpoint_path|installed_path):' \
      "$TEST_TMP/proj/config/project-config.yaml" \
    | grep -E 'multi-plugin|marketplace'
}

# --- AC5: backward compatibility — non-plugin shapes do NOT seed plugin defaults

@test "AC5: non-plugin shape (single backend) does NOT emit project_kind: claude-code-plugin" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "single backend",
  "stacks": [{"name": "api", "language": "node", "paths": ["services/api"]}]
}
JSON
  ! grep -E '^project_kind:[[:space:]]*"?claude-code-plugin"?' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC5: non-plugin shape (single backend) does NOT seed tool_adapters: with plugin defaults" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "single backend",
  "stacks": [{"name": "api", "language": "node", "paths": ["services/api"]}]
}
JSON
  # Plugin-specific tool_adapters block must not appear when shape is not plugin.
  ! grep -E 'shellcheck|^[[:space:]]+- bats[[:space:]]*$|markdownlint|yamllint' \
    "$TEST_TMP/proj/config/project-config.yaml"
}

@test "AC5: backward compat — mobile shape still emits stacks/platforms unchanged" {
  mkdir -p "$TEST_TMP/proj/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "project_shape": "mobile only",
  "stacks": [{"name": "app", "language": "swift", "paths": ["apps/ios"]}],
  "platforms": ["ios"]
}
JSON
  grep -F 'stacks:' "$TEST_TMP/proj/config/project-config.yaml"
  grep -F 'platforms:' "$TEST_TMP/proj/config/project-config.yaml"
  grep -F 'ios' "$TEST_TMP/proj/config/project-config.yaml"
}

# --- Integration: stack file exists at runtime (Technical Notes) ----------

@test "Stack file dependency: claude-code-plugin.yaml is present in config/stacks/" {
  [ -f "$STACKS_DIR/claude-code-plugin.yaml" ]
}
