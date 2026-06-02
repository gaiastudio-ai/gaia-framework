#!/usr/bin/env bash
# test-E28-S38-cluster4-skills.sh — validation tests for E28-S38
#
# Asserts that gaia-tech-research and gaia-advanced-elicitation skill
# directories are correctly scaffolded per the Cluster 4 pattern:
#   AC1: SKILL.md exists with Cluster 4 frontmatter
#   AC2: scripts/setup.sh and scripts/finalize.sh exist and match pattern
#   AC3: SKILL.md body contains legacy workflow content (objective, steps)
#   AC4: Frontmatter linter passes with zero errors
#
# Usage: bash gaia-framework/tests/test-E28-S38-cluster4-skills.sh
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

echo "=== E28-S38 Cluster 4 Skills Validation ==="
echo ""

# --- gaia-tech-research ---
echo "--- gaia-tech-research ---"

TR_DIR="$SKILLS_DIR/gaia-tech-research"
TR_SKILL="$TR_DIR/SKILL.md"
TR_SETUP="$TR_DIR/scripts/setup.sh"
TR_FINALIZE="$TR_DIR/scripts/finalize.sh"

assert "SKILL.md exists" "[ -f '$TR_SKILL' ]"
assert "scripts/setup.sh exists" "[ -f '$TR_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$TR_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$TR_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$TR_FINALIZE' ]"

# AC1: Frontmatter fields
assert "frontmatter has name field" "grep -q '^name:' '$TR_SKILL' 2>/dev/null"
assert "frontmatter name is gaia-tech-research" "grep -q '^name: gaia-tech-research' '$TR_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$TR_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$TR_SKILL' 2>/dev/null"
assert "frontmatter has context: fork" "grep -q '^context: fork' '$TR_SKILL' 2>/dev/null"

# AC2: Scripts match Cluster 4 pattern
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config.sh' '$TR_SETUP' 2>/dev/null"
assert "setup.sh references validate-gate.sh" "grep -q 'validate-gate.sh' '$TR_SETUP' 2>/dev/null"
assert "setup.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$TR_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$TR_FINALIZE' 2>/dev/null"
assert "finalize.sh references lifecycle-event.sh" "grep -q 'lifecycle-event.sh' '$TR_FINALIZE' 2>/dev/null"

# AC3: Body contains legacy workflow content
assert "body has Technology Scoping step" "grep -q 'Technology Scoping' '$TR_SKILL' 2>/dev/null"
assert "body has Technology Evaluation step" "grep -q 'Technology Evaluation' '$TR_SKILL' 2>/dev/null"
assert "body has Trade-off Analysis step" "grep -q 'Trade-off Analysis' '$TR_SKILL' 2>/dev/null"
assert "body references output file" "grep -q 'technical-research.md' '$TR_SKILL' 2>/dev/null"
assert "body has Setup section" "grep -q '## Setup' '$TR_SKILL' 2>/dev/null"
assert "body has Finalize section" "grep -q '## Finalize' '$TR_SKILL' 2>/dev/null"

echo ""

# --- gaia-advanced-elicitation ---
echo "--- gaia-advanced-elicitation ---"

AE_DIR="$SKILLS_DIR/gaia-advanced-elicitation"
AE_SKILL="$AE_DIR/SKILL.md"
AE_SETUP="$AE_DIR/scripts/setup.sh"
AE_FINALIZE="$AE_DIR/scripts/finalize.sh"

assert "SKILL.md exists" "[ -f '$AE_SKILL' ]"
assert "scripts/setup.sh exists" "[ -f '$AE_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$AE_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$AE_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$AE_FINALIZE' ]"

# AC1: Frontmatter fields
assert "frontmatter has name field" "grep -q '^name:' '$AE_SKILL' 2>/dev/null"
assert "frontmatter name is gaia-advanced-elicitation" "grep -q '^name: gaia-advanced-elicitation' '$AE_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$AE_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$AE_SKILL' 2>/dev/null"
assert "frontmatter has context: fork" "grep -q '^context: fork' '$AE_SKILL' 2>/dev/null"

# AC2: Scripts match Cluster 4 pattern
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config.sh' '$AE_SETUP' 2>/dev/null"
assert "setup.sh references validate-gate.sh" "grep -q 'validate-gate.sh' '$AE_SETUP' 2>/dev/null"
assert "setup.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$AE_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$AE_FINALIZE' 2>/dev/null"
assert "finalize.sh references lifecycle-event.sh" "grep -q 'lifecycle-event.sh' '$AE_FINALIZE' 2>/dev/null"

# AC3: Body contains legacy workflow content
assert "body has Context Gathering step" "grep -q 'Context Gathering' '$AE_SKILL' 2>/dev/null"
assert "body has Method Selection step" "grep -q 'Method Selection' '$AE_SKILL' 2>/dev/null"
assert "body has Elicitation Execution step" "grep -q 'Elicitation Execution' '$AE_SKILL' 2>/dev/null"
assert "body has Requirements Synthesis step" "grep -q 'Requirements Synthesis' '$AE_SKILL' 2>/dev/null"
assert "body references output file" "grep -q 'elicitation-report' '$AE_SKILL' 2>/dev/null"
assert "body has Setup section" "grep -q '## Setup' '$AE_SKILL' 2>/dev/null"
assert "body has Finalize section" "grep -q '## Finalize' '$AE_SKILL' 2>/dev/null"

echo ""

# --- AC4: Frontmatter linter ---
echo "--- Frontmatter Linter ---"
LINTER="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
if [ -f "$LINTER" ]; then
  lint_output=$(cd "$REPO_ROOT" && bash "$LINTER" 2>&1)
  lint_rc=$?
  assert "lint-skill-frontmatter.sh exits 0" "[ $lint_rc -eq 0 ]"
else
  echo "  SKIP: lint-skill-frontmatter.sh not found"
fi

# --- AC5: Discoverability ---
echo ""
echo "--- Discoverability ---"
assert "gaia-tech-research in skills listing" "[ -d '$TR_DIR' ]"
assert "gaia-advanced-elicitation in skills listing" "[ -d '$AE_DIR' ]"

echo ""
echo "=== Results: $passed/$total passed, $failed failed ==="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
