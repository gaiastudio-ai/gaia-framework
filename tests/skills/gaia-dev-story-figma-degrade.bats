#!/usr/bin/env bats
# gaia-dev-story-figma-degrade.bats — TC-DSH-21 regression guard for E55-S5 (AC5)
#
# Story: E55-S5 (ATDD gate (Step 2b) + plan-structure validator + Figma graceful-degrade)
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
# PRD: FR-DSH-8 (Figma graceful-degrade — no halt)
#
# Validates the Figma graceful-degrade prose inside Step 4 of
# `plugins/gaia/skills/gaia-dev-story/SKILL.md`:
#
#   AC5 — Test 1: Figma graceful-degrade region begin/end markers are present.
#   AC5 — Test 2: Region instructs probing the Figma MCP before plan render.
#   AC5 — Test 3: Region defines the warning log token
#                 `figma_mcp_unavailable: server={name} fallback=text-only`.
#   AC5 — Test 4: Region explicitly states NO halt / proceeds with text-only.
#   AC5 — Test 5: Region only fires when frontmatter has `figma:` block.
#   AC5 — Test 6: Region sits inside Step 4 (between the Step 4 header and
#                 Step 5 header).
#
# Usage:
#   bats tests/skills/gaia-dev-story-figma-degrade.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"

  REGION_BEGIN='<!-- figma graceful-degrade begin -->'
  REGION_END='<!-- figma graceful-degrade end -->'
}

extract_figma_region() {
  awk -v b="$REGION_BEGIN" -v e="$REGION_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

# ---------- AC5 — region presence ----------

@test "AC5 Test 1: Figma graceful-degrade region markers are present" {
  grep -qF "$REGION_BEGIN" "$SKILL_FILE"
  grep -qF "$REGION_END" "$SKILL_FILE"
}

# ---------- AC5 — MCP probe ----------

@test "AC5 Test 2: region instructs probing the Figma MCP server" {
  region="$(extract_figma_region)"
  [ -n "$region" ]
  # Must mention either the canonical MCP probe or whoami fallback.
  echo "$region" | grep -qE "figma|Figma"
  echo "$region" | grep -qiE "(mcp|whoami|probe|availability|unavailable)"
}

# ---------- AC5 — warning log token (NFR-DSH-5) ----------

@test "AC5 Test 3: region defines the canonical warning log token" {
  region="$(extract_figma_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF "figma_mcp_unavailable"
  echo "$region" | grep -qF "fallback=text-only"
}

# ---------- AC5 — no halt ----------

@test "AC5 Test 4: region explicitly forbids halt — proceeds text-only" {
  region="$(extract_figma_region)"
  [ -n "$region" ]
  # Either "no halt", "do not halt", "NO halt", or "DO NOT halt".
  echo "$region" | grep -qiE "(no halt|do not halt|never halt|without halting)"
  # And references text-only fallback.
  echo "$region" | grep -qiE "text-only"
}

# ---------- AC5 — gated on figma frontmatter ----------

@test "AC5 Test 5: region gates on the story frontmatter having a figma: block" {
  region="$(extract_figma_region)"
  [ -n "$region" ]
  # The region must reference the frontmatter `figma:` field.
  echo "$region" | grep -qE "figma:"
}

# ---------- AC5 — placement inside Step 4 ----------

@test "AC5 Test 6: region sits inside Step 4 (before Step 5 header)" {
  step4_line=$(grep -nF "### Step 4 -- Plan Implementation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  region_line=$(grep -nF "$REGION_BEGIN" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step5_line=$(grep -nF "### Step 5 -- TDD Red Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step4_line" ]
  [ -n "$region_line" ]
  [ -n "$step5_line" ]
  [ "$region_line" -gt "$step4_line" ]
  [ "$region_line" -lt "$step5_line" ]
}

# ---------- AC3 / AC4 — plan-structure validator hook in Step 4 ----------

@test "Plan-structure validator: Step 4 invokes validate-plan-structure.sh" {
  # The Step 4 region (between Step 4 header and Step 5 header) must
  # reference the validator script.
  step4_line=$(grep -nF "### Step 4 -- Plan Implementation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step5_line=$(grep -nF "### Step 5 -- TDD Red Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  awk -v s="$step4_line" -v e="$step5_line" 'NR>=s && NR<e' "$SKILL_FILE" \
    | grep -qF "validate-plan-structure.sh"
}

@test "Plan-structure validator: Step 4 instructs regenerate-loop with cap" {
  step4_line=$(grep -nF "### Step 4 -- Plan Implementation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step5_line=$(grep -nF "### Step 5 -- TDD Red Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  region="$(awk -v s="$step4_line" -v e="$step5_line" 'NR>=s && NR<e' "$SKILL_FILE")"
  echo "$region" | grep -qiE "regenerate"
  # Cap at a generous bound (5).
  echo "$region" | grep -qE "(5 attempts|cap.*5|5 .*cap|bound)"
}

@test "Plan-structure validator: Step 4 instructs validator runs BEFORE the gate halt" {
  step4_line=$(grep -nF "### Step 4 -- Plan Implementation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step5_line=$(grep -nF "### Step 5 -- TDD Red Phase" "$SKILL_FILE" | head -1 | cut -d: -f1)
  region="$(awk -v s="$step4_line" -v e="$step5_line" 'NR>=s && NR<e' "$SKILL_FILE")"
  # Must say validator runs before the gate halt fires (E55-S1) and before
  # the YOLO loop (E55-S2).
  echo "$region" | grep -qiE "before.*(gate|halt|yolo)"
}
