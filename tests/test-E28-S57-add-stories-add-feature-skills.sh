#!/usr/bin/env bash
# test-E28-S57-add-stories-add-feature-skills.sh — validation tests for E28-S57
#
# Asserts that gaia-add-stories and gaia-add-feature skill directories are
# correctly scaffolded per the E28 conversion pattern:
#   AC1: SKILL.md exists with valid frontmatter (name, description, allowed-tools)
#   AC2: add-feature preserves patch/enhancement/feature classification and cascade matrix
#   AC3: Shared setup.sh / finalize.sh pattern applied
#   AC4: Frontmatter linter compatibility (structural check — deferred to E28-S59)
#
# Usage: bash gaia-framework/tests/test-E28-S57-add-stories-add-feature-skills.sh
# Exit 0 when all assertions pass, 1 on any failure.

set -uo pipefail
LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"

passed=0
failed=0
total=0

assert() {
  local desc="$1"
  total=$((total + 1))
  if eval "$2"; then
    echo "  PASS: $desc"
    passed=$((passed + 1))
  else
    echo "  FAIL: $desc"
    failed=$((failed + 1))
  fi
}

echo "=== E28-S57 add-stories & add-feature Skills Validation ==="
echo ""

# ========== gaia-add-stories ==========
echo "--- gaia-add-stories ---"

AS_DIR="$SKILLS_DIR/gaia-add-stories"
AS_SKILL="$AS_DIR/SKILL.md"
AS_SETUP="$AS_DIR/scripts/setup.sh"
AS_FINALIZE="$AS_DIR/scripts/finalize.sh"

# AC1: SKILL.md exists with valid frontmatter
assert "SKILL.md exists" "[ -f '$AS_SKILL' ]"
assert "frontmatter has name field" "grep -q '^name: gaia-add-stories' '$AS_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$AS_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$AS_SKILL' 2>/dev/null"

# AC3: Shared setup.sh / finalize.sh
assert "scripts/setup.sh exists" "[ -f '$AS_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$AS_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$AS_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$AS_FINALIZE' ]"

# AC1: SKILL.md body contains legacy workflow content
assert "SKILL.md contains story protection mandate" "grep -qi 'story protection' '$AS_SKILL' 2>/dev/null || grep -qi 'read-only' '$AS_SKILL' 2>/dev/null"
assert "SKILL.md contains epic decision logic" "grep -qi 'epic' '$AS_SKILL' 2>/dev/null"
assert "SKILL.md contains protection validation" "grep -qi 'protection' '$AS_SKILL' 2>/dev/null"

# AC3: setup.sh references shared foundation scripts
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config' '$AS_SETUP' 2>/dev/null"
assert "setup.sh references validate-gate.sh" "grep -q 'validate-gate' '$AS_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint' '$AS_FINALIZE' 2>/dev/null"

echo ""

# ========== gaia-add-feature ==========
echo "--- gaia-add-feature ---"

AF_DIR="$SKILLS_DIR/gaia-add-feature"
AF_SKILL="$AF_DIR/SKILL.md"
AF_SETUP="$AF_DIR/scripts/setup.sh"
AF_FINALIZE="$AF_DIR/scripts/finalize.sh"

# AC1: SKILL.md exists with valid frontmatter
assert "SKILL.md exists" "[ -f '$AF_SKILL' ]"
assert "frontmatter has name field" "grep -q '^name: gaia-add-feature' '$AF_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$AF_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$AF_SKILL' 2>/dev/null"

# AC2: Classification vocabulary preserved
assert "SKILL.md contains 'patch' classification" "grep -q 'patch' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md contains 'enhancement' classification" "grep -q 'enhancement' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md contains 'feature' classification" "grep -q 'feature' '$AF_SKILL' 2>/dev/null"

# AC2: Cascade matrix preserved
assert "SKILL.md contains cascade matrix" "grep -qi 'cascade' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md references PRD in cascade" "grep -qi 'prd' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md references architecture in cascade" "grep -qi 'architecture' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md references test plan in cascade" "grep -qi 'test.plan' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md references traceability in cascade" "grep -qi 'traceability' '$AF_SKILL' 2>/dev/null"
assert "SKILL.md references threat model in cascade" "grep -qi 'threat.model' '$AF_SKILL' 2>/dev/null"

# AC3: Shared setup.sh / finalize.sh
assert "scripts/setup.sh exists" "[ -f '$AF_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$AF_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$AF_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$AF_FINALIZE' ]"

# AC3: setup.sh references shared foundation scripts
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config' '$AF_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint' '$AF_FINALIZE' 2>/dev/null"

# AC2: add-feature acts as orchestrator delegating to sub-workflows
assert "SKILL.md mentions orchestrator or delegation" "grep -qi 'orchestrat\|delegat\|sub-workflow\|subagent\|cascade' '$AF_SKILL' 2>/dev/null"

# AC4: Frontmatter structural lint readiness (deferred to E28-S59)
# Both SKILL.md files must have the triple-dash fenced frontmatter block
assert "add-stories SKILL.md has opening frontmatter fence" "head -1 '$AS_SKILL' | grep -q '^---' 2>/dev/null"
assert "add-feature SKILL.md has opening frontmatter fence" "head -1 '$AF_SKILL' | grep -q '^---' 2>/dev/null"

echo ""
echo "=== Results: $passed passed, $failed failed, $total total ==="
exit "$failed"
