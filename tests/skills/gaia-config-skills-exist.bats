#!/usr/bin/env bats
# gaia-config-skills-exist.bats — E71-S3 AC1 + AC10
#
# Asserts that the eight /gaia-config-* editor skills introduced by E71-S3
# exist on disk with valid SKILL.md frontmatter, and that the two mobile-
# specific config skills excluded by AC10 (E74-S11 scope) are NOT present.
#
# Test cases:
#   TC-RSV2-INIT-14 — eight editor commands exist (AC1)
#   TC-RSV2-INIT-23 — mobile-specific editors excluded (AC10)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
}

# ---------- AC1: all eight commands resolve ----------

@test "AC1 — gaia-config-env SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-env/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-env$' "$f"
  [ "$status" -eq 0 ]
  run grep -E '^description: ' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-test SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-test/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-test$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-tool SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-tool/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-tool$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-compliance SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-compliance/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-compliance$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-stack SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-stack/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-stack$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-rubric SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-rubric/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-rubric$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-validate SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-validate/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-validate$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — gaia-config-show SKILL.md exists with frontmatter" {
  local f="$SKILLS_DIR/gaia-config-show/SKILL.md"
  [ -f "$f" ]
  run grep -E '^name: gaia-config-show$' "$f"
  [ "$status" -eq 0 ]
}

@test "AC1 — every config-* SKILL.md mentions project-config.yaml in description" {
  for skill in env test tool compliance stack rubric show; do
    local f="$SKILLS_DIR/gaia-config-$skill/SKILL.md"
    run grep -i "project-config" "$f"
    [ "$status" -eq 0 ] || {
      echo "skill gaia-config-$skill missing project-config reference" >&2
      return 1
    }
  done
}

# ---------- AC10: mobile editors absent ----------

@test "AC10 — gaia-config-platform skill is NOT present (E74-S11 scope)" {
  [ ! -e "$SKILLS_DIR/gaia-config-platform" ]
}

@test "AC10 — gaia-config-device-target skill is NOT present (E74-S11 scope)" {
  [ ! -e "$SKILLS_DIR/gaia-config-device-target" ]
}

@test "AC10 — workflow-manifest.csv does not register config-platform" {
  local csv="$REPO_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
  run grep -F "config-platform" "$csv"
  [ "$status" -ne 0 ]
}

@test "AC10 — workflow-manifest.csv does not register config-device-target" {
  local csv="$REPO_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
  run grep -F "config-device-target" "$csv"
  [ "$status" -ne 0 ]
}
