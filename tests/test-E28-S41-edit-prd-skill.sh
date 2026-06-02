#!/usr/bin/env bash
# test-E28-S41-edit-prd-skill.sh — validation tests for E28-S41
#
# Asserts that gaia-edit-prd skill directory is correctly scaffolded per
# the Cluster 5 planning pattern (P5-S2):
#   AC1: SKILL.md exists with Cluster 5 frontmatter (name, description,
#        allowed-tools, subagent routing)
#   AC2: Cascade-aware edit logic preserved from legacy edit-prd workflow
#   AC3: scripts/setup.sh and scripts/finalize.sh conform to Cluster 4 shared pattern
#   AC4: Subagent routing to pm (Derek) — no inline persona content
#   AC5: Frontmatter linter passes with zero errors
#
# Usage: bash gaia-framework/tests/test-E28-S41-edit-prd-skill.sh
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

echo "=== E28-S41 edit-prd Skill Validation ==="
echo ""

EP_DIR="$SKILLS_DIR/gaia-edit-prd"
EP_SKILL="$EP_DIR/SKILL.md"
EP_SETUP="$EP_DIR/scripts/setup.sh"
EP_FINALIZE="$EP_DIR/scripts/finalize.sh"

# --- AC1: SKILL.md exists with correct frontmatter ---
echo "--- AC1: SKILL.md Frontmatter ---"

assert "SKILL.md exists" "[ -f '$EP_SKILL' ]"
assert "frontmatter has name field" "grep -q '^name:' '$EP_SKILL' 2>/dev/null"
assert "frontmatter name is gaia-edit-prd" "grep -q '^name: gaia-edit-prd' '$EP_SKILL' 2>/dev/null"
assert "frontmatter has description field" "grep -q '^description:' '$EP_SKILL' 2>/dev/null"
assert "frontmatter has allowed-tools field" "grep -q '^allowed-tools:' '$EP_SKILL' 2>/dev/null"
assert "frontmatter has context: fork" "grep -q '^context: fork' '$EP_SKILL' 2>/dev/null"

echo ""

# --- AC2: Cascade-aware edit logic ---
echo "--- AC2: Cascade-Aware Edit Logic ---"

assert "body has Load PRD step" "grep -q 'Load PRD' '$EP_SKILL' 2>/dev/null"
assert "body has Identify Changes step" "grep -q 'Identify Changes' '$EP_SKILL' 2>/dev/null"
assert "body has Apply Edits step" "grep -q 'Apply Edits' '$EP_SKILL' 2>/dev/null"
assert "body has Architecture Cascade Check step" "grep -q 'Architecture Cascade Check' '$EP_SKILL' 2>/dev/null"
assert "body references architecture.md" "grep -q 'architecture.md' '$EP_SKILL' 2>/dev/null"
assert "body references cascade impact classification" "grep -q 'NONE\|MINOR\|SIGNIFICANT' '$EP_SKILL' 2>/dev/null"
assert "body references prd.md output" "grep -q 'prd.md' '$EP_SKILL' 2>/dev/null"
assert "body has Setup section" "grep -q '## Setup' '$EP_SKILL' 2>/dev/null"
assert "body has Finalize section" "grep -q '## Finalize' '$EP_SKILL' 2>/dev/null"

echo ""

# --- AC3: Scripts conform to Cluster 4 shared pattern ---
echo "--- AC3: Shared Script Pattern ---"

assert "scripts/setup.sh exists" "[ -f '$EP_SETUP' ]"
assert "scripts/finalize.sh exists" "[ -f '$EP_FINALIZE' ]"
assert "setup.sh is executable" "[ -x '$EP_SETUP' ]"
assert "finalize.sh is executable" "[ -x '$EP_FINALIZE' ]"
assert "setup.sh references resolve-config.sh" "grep -q 'resolve-config.sh' '$EP_SETUP' 2>/dev/null"
assert "setup.sh references validate-gate.sh" "grep -q 'validate-gate.sh' '$EP_SETUP' 2>/dev/null"
assert "setup.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$EP_SETUP' 2>/dev/null"
assert "finalize.sh references checkpoint.sh" "grep -q 'checkpoint.sh' '$EP_FINALIZE' 2>/dev/null"
assert "finalize.sh references lifecycle-event.sh" "grep -q 'lifecycle-event.sh' '$EP_FINALIZE' 2>/dev/null"

echo ""

# --- AC4: Subagent routing to pm ---
echo "--- AC4: Subagent Routing ---"

assert "SKILL.md routes to pm subagent" "grep -q 'agents/pm' '$EP_SKILL' 2>/dev/null"
assert "SKILL.md does not inline Derek persona" "! grep -q 'You are.*Derek' '$EP_SKILL' 2>/dev/null"
assert "SKILL.md mentions pm delegation" "grep -q 'pm.*subagent\|subagent.*pm\|pm.*Derek\|Derek.*pm' '$EP_SKILL' 2>/dev/null"

echo ""

# --- AC5: Frontmatter linter ---
echo "--- AC5: Frontmatter Linter ---"
LINTER="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
if [ -f "$LINTER" ]; then
  lint_output=$(cd "$REPO_ROOT" && bash "$LINTER" 2>&1)
  lint_rc=$?
  assert "lint-skill-frontmatter.sh exits 0" "[ $lint_rc -eq 0 ]"
else
  echo "  SKIP: lint-skill-frontmatter.sh not found"
fi

echo ""

# --- Adversarial Review Preservation ---
echo "--- Adversarial Review Preservation ---"
assert "body has Adversarial Review step" "grep -q 'Adversarial Review' '$EP_SKILL' 2>/dev/null"
assert "body references adversarial-triggers.yaml" "grep -q 'adversarial-triggers.yaml' '$EP_SKILL' 2>/dev/null"

echo ""
echo "=== Results: $passed/$total passed, $failed failed ==="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
