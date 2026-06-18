#!/usr/bin/env bats
# deploy-skill-rename.bats — category-first rename of the deploy/release skill
# family + one-sprint redirect stubs.
#
# Validates:
#   - the renamed skill directory exists with correct frontmatter
#   - the old name has a redirect stub with deprecation notice
#   - workflow-manifest.csv references the new name
#   - gaia-help.csv references the new name
#   - lifecycle-sequence.yaml references the new name

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  KNOWLEDGE_DIR="$PLUGIN_ROOT/knowledge"
}

teardown() { common_teardown; }

# ===========================================================================
# The renamed skill (gaia-deploy-post) exists with correct frontmatter
# ===========================================================================

@test "the renamed skill directory gaia-deploy-post exists" {
  [ -d "$SKILLS_DIR/gaia-deploy-post" ]
}

@test "the renamed skill SKILL.md has name: gaia-deploy-post in frontmatter" {
  local skill_file="$SKILLS_DIR/gaia-deploy-post/SKILL.md"
  [ -f "$skill_file" ]
  run grep "^name: gaia-deploy-post" "$skill_file"
  [ "$status" -eq 0 ]
}

@test "the renamed skill has its scripts directory preserved" {
  [ -f "$SKILLS_DIR/gaia-deploy-post/scripts/setup.sh" ]
  [ -f "$SKILLS_DIR/gaia-deploy-post/scripts/finalize.sh" ]
}

# ===========================================================================
# The old name has a redirect stub with deprecation notice
# ===========================================================================

@test "the old skill directory gaia-post-deploy still exists as a redirect stub" {
  [ -d "$SKILLS_DIR/gaia-post-deploy" ]
  [ -f "$SKILLS_DIR/gaia-post-deploy/SKILL.md" ]
}

@test "the redirect stub has deprecated frontmatter fields" {
  local stub="$SKILLS_DIR/gaia-post-deploy/SKILL.md"
  run grep "replaced_by:" "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gaia-deploy-post"* ]]

  run grep "deprecated_since:" "$stub"
  [ "$status" -eq 0 ]
}

@test "the redirect stub contains a deprecation notice section" {
  local stub="$SKILLS_DIR/gaia-post-deploy/SKILL.md"
  assert_file_contains "$stub" "Deprecation Notice"
  assert_file_contains "$stub" "gaia-deploy-post"
}

@test "the redirect stub does not contain the full original skill body" {
  local stub="$SKILLS_DIR/gaia-post-deploy/SKILL.md"
  # The original had 5 steps (Health Checks, Smoke Tests, Metric Validation,
  # Canary Analysis, Generate Report). The stub must NOT have those.
  assert_file_excludes "$stub" "Canary Analysis"
  assert_file_excludes "$stub" "Metric Validation"
}

# ===========================================================================
# workflow-manifest.csv references the new name
# ===========================================================================

@test "workflow-manifest.csv references gaia-deploy-post as the command" {
  local manifest="$KNOWLEDGE_DIR/workflow-manifest.csv"
  run grep "gaia-deploy-post" "$manifest"
  [ "$status" -eq 0 ]
}

@test "workflow-manifest.csv does not reference gaia-post-deploy as a live command" {
  local manifest="$KNOWLEDGE_DIR/workflow-manifest.csv"
  # The old name may appear in a deprecated row, but the primary row
  # must use the new name.
  local live_row
  live_row="$(grep 'post-deploy-verify' "$manifest" | grep -v 'deprecated' | head -1)"
  [[ "$live_row" == *"gaia-deploy-post"* ]]
}

# ===========================================================================
# gaia-help.csv references the new name
# ===========================================================================

@test "gaia-help.csv references gaia-deploy-post as the command" {
  local help_csv="$KNOWLEDGE_DIR/gaia-help.csv"
  run grep "gaia-deploy-post" "$help_csv"
  [ "$status" -eq 0 ]
}

@test "gaia-help.csv does not reference gaia-post-deploy as a live command" {
  local help_csv="$KNOWLEDGE_DIR/gaia-help.csv"
  local live_row
  live_row="$(grep 'post-deploy-verify' "$help_csv" | grep -v -i 'deprecated' | head -1)"
  [[ "$live_row" == *"gaia-deploy-post"* ]]
}

# ===========================================================================
# lifecycle-sequence.yaml references the new name
# ===========================================================================

@test "lifecycle-sequence.yaml references the new command name" {
  local sequence="$KNOWLEDGE_DIR/lifecycle-sequence.yaml"
  assert_file_contains "$sequence" "/gaia-deploy-post"
}

# ===========================================================================
# Already category-first skills remain unchanged
# ===========================================================================

@test "gaia-deploy skill directory still exists unchanged" {
  [ -d "$SKILLS_DIR/gaia-deploy" ]
  run grep "^name: gaia-deploy$" "$SKILLS_DIR/gaia-deploy/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "gaia-deploy-checklist skill directory still exists unchanged" {
  [ -d "$SKILLS_DIR/gaia-deploy-checklist" ]
  run grep "^name: gaia-deploy-checklist$" "$SKILLS_DIR/gaia-deploy-checklist/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "gaia-release skill directory still exists unchanged" {
  [ -d "$SKILLS_DIR/gaia-release" ]
  run grep "^name: gaia-release$" "$SKILLS_DIR/gaia-release/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "gaia-release-plan skill directory still exists unchanged" {
  [ -d "$SKILLS_DIR/gaia-release-plan" ]
  run grep "^name: gaia-release-plan$" "$SKILLS_DIR/gaia-release-plan/SKILL.md"
  [ "$status" -eq 0 ]
}
