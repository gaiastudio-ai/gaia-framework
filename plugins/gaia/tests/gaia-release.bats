#!/usr/bin/env bats
# gaia-release.bats — E28-S167 tests for the /gaia-release native skill.
#
# Validates:
#   AC1: SKILL.md documents the full release procedure (version bump, commit,
#        tag, push, GitHub Release).
#   AC2: SKILL.md references scripts/version-bump.js.
#   AC3: /gaia-release is discoverable via the native plugin skills tree —
#        SKILL.md sits under plugins/gaia/skills/gaia-release/ alongside peer
#        skills such as gaia-release-plan and gaia-changelog.
#   Val INFO 1: CURRENT version-bump behavior (2 global files per ADR-025
#               Model B) — no stale "6 files" claim.
#   Val INFO 2: Full CLI surface — --modules, --prerelease rc,
#               --strip-prerelease, --dry-run.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-release"
SKILLS_ROOT="$BATS_TEST_DIRNAME/../skills"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------- AC1: SKILL.md structure ----------

@test "AC1: SKILL.md exists in gaia-release skill directory" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "AC1: frontmatter contains name: gaia-release" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"name: gaia-release"* ]]
}

@test "AC1: frontmatter contains description field" {
  run head -20 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"description:"* ]]
}

@test "AC1: frontmatter contains allowed-tools" {
  run head -30 "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"allowed-tools:"* ]]
}

@test "AC1: frontmatter opens and closes with ---" {
  local first_line
  first_line=$(head -1 "$SKILL_DIR/SKILL.md")
  [ "$first_line" = "---" ]

  local closing_line
  closing_line=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$SKILL_DIR/SKILL.md")
  [ -n "$closing_line" ]
}

@test "AC1: SKILL.md documents the version-bump step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"version"* ]]
  [[ "$output" == *"bump"* ]] || [[ "$output" == *"Bump"* ]]
}

@test "AC1: SKILL.md documents the commit step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"commit"* ]] || [[ "$output" == *"Commit"* ]]
}

@test "AC1: SKILL.md documents the tag step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"tag"* ]] || [[ "$output" == *"Tag"* ]]
}

@test "AC1: SKILL.md documents the push step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"push"* ]] || [[ "$output" == *"Push"* ]]
}

@test "AC1: SKILL.md documents the GitHub Release step" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"GitHub Release"* ]] || [[ "$output" == *"gh release"* ]]
}

# ---------- AC2: version-bump.js reference ----------

@test "AC2: SKILL.md references scripts/version-bump.js" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"scripts/version-bump.js"* ]]
}

@test "AC2: SKILL.md shows npm run version:bump or the node invocation" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"npm run version:bump"* ]] \
    || [[ "$output" == *"node scripts/version-bump.js"* ]]
}

# ---------- AC3: /gaia-help discoverability ----------
#
# In the native plugin model (ADR-041, ADR-048) the skill is discoverable via
# its SKILL.md living under plugins/gaia/skills/{skill-name}/ — Claude Code
# enumerates the skills directory at load time. These tests verify the
# structural invariants that make /gaia-release discoverable; the
# help-surface CSV registration lives in the legacy Gaia-framework tree and
# is covered by the companion PR there.

@test "AC3: gaia-release skill dir is a peer of other skills under plugins/gaia/skills/" {
  [ -d "$SKILLS_ROOT" ]
  [ -d "$SKILL_DIR" ]
  # Sibling check — the new skill sits next to existing skills such as
  # gaia-release-plan and gaia-changelog.
  [ -d "$SKILLS_ROOT/gaia-release-plan" ]
  [ -d "$SKILLS_ROOT/gaia-changelog" ]
}

@test "AC3: SKILL.md frontmatter declares the discoverable trigger phrase" {
  run head -20 "$SKILL_DIR/SKILL.md"
  # The description field is what Claude Code surfaces when the user asks
  # for help; it must mention /gaia-release so the skill is nameable.
  [[ "$output" == *"/gaia-release"* ]] || [[ "$output" == *"gaia-release"* ]]
}

# ---------- Val INFO 1: ADR-025 Model B (2 global files) ----------

@test "VAL-INFO-1: SKILL.md documents Model B (2 global files)" {
  run cat "$SKILL_DIR/SKILL.md"
  # The version-bump script updates exactly 2 global targets; verify the
  # SKILL.md names both and states the 2-target constraint.
  [[ "$output" == *"package.json"* ]]
  [[ "$output" == *"global.yaml"* ]]
  [[ "$output" =~ "2 global" ]]
}

@test "VAL-INFO-1: SKILL.md does NOT claim the script updates 6 files" {
  run cat "$SKILL_DIR/SKILL.md"
  # The stale "6 files" narrative came from a pre-ADR-025 version. The
  # current script touches exactly 2 global files.
  [[ "$output" != *"6 files"* ]]
  [[ "$output" != *"six files"* ]]
}

# ---------- Val INFO 2: full CLI surface ----------

@test "VAL-INFO-2: SKILL.md documents --modules flag" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"--modules"* ]]
}

@test "VAL-INFO-2: SKILL.md documents --prerelease rc flag" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"--prerelease"* ]]
  [[ "$output" == *"rc"* ]]
}

@test "VAL-INFO-2: SKILL.md documents --strip-prerelease flag" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"--strip-prerelease"* ]]
}

@test "VAL-INFO-2: SKILL.md documents --dry-run flag" {
  run cat "$SKILL_DIR/SKILL.md"
  [[ "$output" == *"--dry-run"* ]]
}
