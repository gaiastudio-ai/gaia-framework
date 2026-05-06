#!/usr/bin/env bats
# gaia-config-section-scope.bats — E71-S3 AC2
#
# Validates that each /gaia-config-* skill is wired to the correct top-level
# section of project-config.yaml (per AC2 mapping).
#
# Mapping per AC2:
#   /gaia-config-env         -> environments
#   /gaia-config-test        -> test_execution
#   /gaia-config-tool        -> tool_adapters
#   /gaia-config-compliance  -> compliance
#   /gaia-config-stack       -> stacks
#   /gaia-config-rubric      -> rubrics
#   /gaia-config-show        -> read-only entire file (with optional section arg)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
}

assert_section_wired() {
  local skill="$1"
  local section="$2"
  local f="$SKILLS_DIR/$skill/SKILL.md"
  [ -f "$f" ] || {
    echo "missing $f" >&2
    return 1
  }
  grep -qE "$section" "$f" || {
    echo "skill $skill does not reference section '$section'" >&2
    return 1
  }
}

@test "AC2 — gaia-config-env is wired to environments section" {
  assert_section_wired gaia-config-env environments
}

@test "AC2 — gaia-config-test is wired to test_execution section" {
  assert_section_wired gaia-config-test test_execution
}

@test "AC2 — gaia-config-tool is wired to tool_adapters section" {
  assert_section_wired gaia-config-tool tool_adapters
}

@test "AC2 — gaia-config-compliance is wired to compliance section" {
  assert_section_wired gaia-config-compliance compliance
}

@test "AC2 — gaia-config-stack is wired to stacks section" {
  assert_section_wired gaia-config-stack stacks
}

@test "AC2 — gaia-config-rubric is wired to rubrics section" {
  assert_section_wired gaia-config-rubric rubrics
}

@test "AC6 — gaia-config-show advertises read-only display + optional section arg" {
  local f="$SKILLS_DIR/gaia-config-show/SKILL.md"
  [ -f "$f" ]
  grep -qiE 'read-only' "$f"
  grep -qE 'section' "$f"
}

@test "AC7 — every editor skill mentions diff preview / confirmation gate" {
  for skill in env test tool compliance stack rubric; do
    local f="$SKILLS_DIR/gaia-config-$skill/SKILL.md"
    grep -qiE 'diff' "$f" || {
      echo "skill gaia-config-$skill missing diff/confirmation gate language" >&2
      return 1
    }
    grep -qiE 'confirm' "$f" || {
      echo "skill gaia-config-$skill missing confirm language" >&2
      return 1
    }
  done
}

@test "AC9 — each editor skill mentions missing-section scaffold-or-abort" {
  for skill in env test tool compliance stack rubric; do
    local f="$SKILLS_DIR/gaia-config-$skill/SKILL.md"
    grep -qiE 'scaffold|missing section|absent' "$f" || {
      echo "skill gaia-config-$skill missing AC9 missing-section handling" >&2
      return 1
    }
  done
}

@test "registration — workflow-manifest.csv lists seven new commands" {
  local csv="$REPO_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
  for cmd in gaia-config-env gaia-config-test gaia-config-tool gaia-config-compliance gaia-config-stack gaia-config-rubric gaia-config-show; do
    grep -F "$cmd" "$csv" >/dev/null || {
      echo "workflow-manifest.csv missing $cmd" >&2
      return 1
    }
  done
}
