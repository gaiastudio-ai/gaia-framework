#!/usr/bin/env bash
# test-E28-S42-validate-prd-skill.sh — validation tests for E28-S42
#
# Asserts that gaia-validate-prd skill directory is correctly scaffolded per
# the Cluster 5 planning pattern (P5-S3):
#   AC1: SKILL.md exists with Cluster 5 frontmatter (name, description,
#        allowed-tools, Cluster 5 marker)
#   AC2: Body redirects to gaia-val-validate, forwarding PRD artifact path
#   AC3: ADR-045 deprecation notice preserved
#   AC4: scripts/setup.sh and scripts/finalize.sh conform to Cluster 4/5 shared pattern
#   AC5: No duplicated validation logic — redirect only
#   AC6: Frontmatter linter passes with zero errors
#
# Usage: bash gaia-framework/tests/test-E28-S42-validate-prd-skill.sh
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

echo "=== E28-S42 validate-prd Skill Validation ==="
echo ""

VP_DIR="$SKILLS_DIR/gaia-validate-prd"
VP_SKILL="$VP_DIR/SKILL.md"
VP_SETUP="$VP_DIR/scripts/setup.sh"
VP_FINALIZE="$VP_DIR/scripts/finalize.sh"

# --- AC1: SKILL.md exists with correct Cluster 5 frontmatter ---
echo "--- AC1: SKILL.md Frontmatter ---"

assert "SKILL.md exists" "[ -f '$VP_SKILL' ]"
assert "frontmatter has name field" "grep -q '^name:' '$VP_SKILL' 2>/dev/null"
assert "frontmatter name is gaia-validate-prd" "grep -q '^name: gaia-validate-prd' '$VP_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$VP_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$VP_SKILL' 2>/dev/null"
assert "frontmatter has context: fork" "grep -q '^context: fork' '$VP_SKILL' 2>/dev/null"

echo ""

# --- AC2: Redirect to gaia-val-validate ---
echo "--- AC2: Redirect to gaia-val-validate ---"

assert "body references gaia-val-validate" "grep -q 'gaia-val-validate' '$VP_SKILL' 2>/dev/null"
assert "body mentions forwarding/passing PRD path" "grep -qi 'forward\|pass.*path\|artifact.*path\|prd.*path' '$VP_SKILL' 2>/dev/null"
assert "body invokes gaia-val-validate skill" "grep -q '/gaia-val-validate\|gaia-val-validate' '$VP_SKILL' 2>/dev/null"
assert "body has redirect step" "grep -qi 'redirect\|delegate\|route\|invoke.*val-validate' '$VP_SKILL' 2>/dev/null"

echo ""

# --- AC3: Deprecation notice (ADR-045) ---
echo "--- AC3: Deprecation Notice ---"

assert "body contains deprecation notice" "grep -qi 'deprecated\|deprecation' '$VP_SKILL' 2>/dev/null"
assert "deprecation notice names gaia-val-validate as canonical" "grep -qi 'deprecated.*gaia-val-validate\|gaia-val-validate.*canonical\|prefer.*gaia-val-validate\|legacy.*entry.*point' '$VP_SKILL' 2>/dev/null"
assert "body references ADR-045" "grep -q 'ADR-045' '$VP_SKILL' 2>/dev/null"

echo ""

# --- AC4: Shared scripts conform to Cluster 4/5 pattern ---
echo "--- AC4: Shared Script Pattern ---"

assert "scripts/setup.sh exists" "[ -f '$VP_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$VP_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$VP_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$VP_FINALIZE' ]"
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config.sh' '$VP_SETUP' 2>/dev/null"
assert "setup.sh references validate-gate.sh" "grep -q 'validate-gate.sh' '$VP_SETUP' 2>/dev/null"
assert "setup.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$VP_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$VP_FINALIZE' 2>/dev/null"
assert "finalize.sh references lifecycle-event.sh" "grep -q 'lifecycle-event.sh' '$VP_FINALIZE' 2>/dev/null"

echo ""

# --- AC5: No duplicated validation logic ---
echo "--- AC5: No Duplicated Logic ---"

assert "body does NOT contain completeness check logic" "! grep -qi 'required sections exist.*overview.*personas' '$VP_SKILL' 2>/dev/null"
assert "body does NOT contain structural validation logic" "! grep -qi 'numbered sequentially.*FR-001' '$VP_SKILL' 2>/dev/null"
assert "body does NOT contain quality check steps" "! grep -qi 'for each requirement verify.*testable.*unambiguous' '$VP_SKILL' 2>/dev/null"
assert "body does NOT contain consistency check steps" "! grep -qi 'cross-reference all sections for contradictions' '$VP_SKILL' 2>/dev/null"
assert "body has Setup section" "grep -q '## Setup' '$VP_SKILL' 2>/dev/null"
assert "body has Finalize section" "grep -q '## Finalize' '$VP_SKILL' 2>/dev/null"

echo ""

# --- AC6: Frontmatter linter ---
echo "--- AC6: Frontmatter Linter ---"
LINTER="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
if [ -f "$LINTER" ]; then
  lint_output=$(cd "$REPO_ROOT" && bash "$LINTER" 2>&1)
  lint_rc=$?
  assert "lint-skill-frontmatter.sh exits 0" "[ $lint_rc -eq 0 ]"
else
  echo "  SKIP: lint-skill-frontmatter.sh not found"
fi

echo ""

# --- Discoverability ---
echo "--- Discoverability ---"
assert "gaia-validate-prd dir exists in skills listing" "[ -d '$VP_DIR' ]"
assert "gaia-validate-prd is distinct from gaia-val-validate" "[ '$VP_DIR' != '$SKILLS_DIR/gaia-val-validate' ]"

echo ""
echo "=== Results: $passed/$total passed, $failed failed ==="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
