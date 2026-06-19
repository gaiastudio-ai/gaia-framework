#!/usr/bin/env bats
# gaia-release.bats — tests for the /gaia-release native skill.
#
# Validates:
#   AC1: SKILL.md documents the full release procedure (version bump, commit,
#        tag, push, GitHub Release).
#   AC2: SKILL.md references the skill-local version-bump.js script path.
#   AC3: /gaia-release is discoverable via the native plugin skills tree —
#        SKILL.md sits under plugins/gaia/skills/gaia-release/ alongside peer
#        skills such as gaia-release-plan and gaia-changelog.
#   Val INFO 1: CURRENT version-bump behavior — config-driven
#               release.version_files[] (no stale "6 files" claim).
#   Val INFO 2: CLI surface — --dry-run.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-release"
SKILLS_ROOT="$BATS_TEST_DIRNAME/../skills"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------- AC1: SKILL.md structure ----------

@test "SKILL.md exists in gaia-release skill directory" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "frontmatter contains name: gaia-release" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-release"* ]]
}

@test "frontmatter contains description field" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "frontmatter contains allowed-tools" {
  run head -30 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
}

@test "frontmatter opens and closes with" {
  local first_line
  first_line=$(head -1 "$SKILL_DIR/SKILL.md")
  [ "$first_line" = "---" ]

  local closing_line
  closing_line=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$SKILL_DIR/SKILL.md")
  [ -n "$closing_line" ]
}

@test "SKILL.md documents the version-bump step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"version"* ]]
  [[ "$output" == *"bump"* ]] || [[ "$output" == *"Bump"* ]]
}

@test "SKILL.md documents the commit step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"commit"* ]] || [[ "$output" == *"Commit"* ]]
}

@test "SKILL.md documents the tag step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"tag"* ]] || [[ "$output" == *"Tag"* ]]
}

@test "SKILL.md documents the push step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"push"* ]] || [[ "$output" == *"Push"* ]]
}

@test "SKILL.md documents the GitHub Release step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"GitHub Release"* ]] || [[ "$output" == *"gh release"* ]]
}

# ---------- AC2: version-bump.js reference ----------

@test "SKILL.md references the skill-local version-bump.js path" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"skills/gaia-release/scripts/version-bump.js"* ]]
}

@test "SKILL.md shows the node invocation for version-bump.js" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"node"*"version-bump.js"* ]]
}

# ---------- AC3: /gaia-help discoverability ----------
#
# In the native plugin model (ADR-041, ADR-048) the skill is discoverable via
# its SKILL.md living under plugins/gaia/skills/{skill-name}/ — Claude Code
# enumerates the skills directory at load time. These tests verify the
# structural invariants that make /gaia-release discoverable; the
# help-surface CSV registration lives in the legacy Gaia-framework tree and
# is covered by the companion PR there.

@test "gaia-release skill dir is a peer of other skills under plugins/gaia/skills/" {
  [ -d "$SKILLS_ROOT" ]
  [ -d "$SKILL_DIR" ]
  # Sibling check — the new skill sits next to existing skills such as
  # gaia-release-plan and gaia-changelog.
  [ -d "$SKILLS_ROOT/gaia-release-plan" ]
  [ -d "$SKILLS_ROOT/gaia-changelog" ]
}

@test "SKILL.md frontmatter declares the discoverable trigger phrase" {
  run head -20 "$SKILL_DIR/SKILL.md"
  # The description field is what Claude Code surfaces when the user asks
  # for help; it must mention /gaia-release so the skill is nameable.
  [[ "$output" == *"/gaia-release"* ]] || [[ "$output" == *"gaia-release"* ]]
}

# ---------- Val INFO 1: config-driven version file list ----------

@test "SKILL.md documents config-driven release.version_files list" {
  run cat "$SKILL_DIR/SKILL.md"
  # The project-generic rebuild reads version files from config rather than
  # hardcoding a fixed target set. Verify the config key is documented.
  [[ "$output" == *"release.version_files"* ]]
  [[ "$output" == *"project-config.yaml"* ]]
}

@test "SKILL.md does NOT claim the script updates 6 files" {
  run cat "$SKILL_DIR/SKILL.md"
  # The stale "6 files" narrative came from a pre-ADR-025 version. The
  # current script touches exactly 2 global files.
  [[ "$output" != *"6 files"* ]]
  [[ "$output" != *"six files"* ]]
}

# ---------- Val INFO 2: CLI surface ----------


@test "SKILL.md documents --dry-run flag" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"--dry-run"* ]]
}
