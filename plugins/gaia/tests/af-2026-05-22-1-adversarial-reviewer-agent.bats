#!/usr/bin/env bats
# AF-2026-05-22-1: wire concrete adversarial-reviewer agent.
# Closes the bug where /gaia-create-prd Step 13 dispatched a non-existent
# `gaia:adversarial-review` agent. New persona at agents/adversarial-reviewer.md
# (Sage) is referenced by name from all 6 skills that invoke adversarial review.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- Agent persona file exists and conforms to schema ---

@test "AF-2026-05-22-1: adversarial-reviewer.md persona file exists" {
  [ -f "$PLUGIN_ROOT/agents/adversarial-reviewer.md" ]
}

@test "AF-2026-05-22-1: persona frontmatter declares name: adversarial-reviewer" {
  grep -qE '^name: adversarial-reviewer$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona frontmatter declares model: claude-opus-4-7 (ADR-074 review-rigor pin)" {
  grep -qE '^model: claude-opus-4-7$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona frontmatter declares context: main" {
  grep -qE '^context: main$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona frontmatter allowed-tools is read-only set (no Write/Edit)" {
  grep -qE '^allowed-tools: \[Read, Grep, Glob, Bash\]$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona body has Mission, Persona, Memory, Rules sections" {
  grep -qE '^## Mission$'  "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^## Persona$'  "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^## Memory$'   "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^## Rules$'    "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona Memory section invokes memory-loader.sh with ground-truth scope" {
  # Test05 F-010 / AF-2026-05-27-4: the header MUST use ${CLAUDE_PLUGIN_ROOT}
  # (the documented Claude Code substrate var), NOT ${PLUGIN_DIR} (which is not
  # a substrate var and expands to empty, silently no-op'ing the memory load).
  grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh adversarial-reviewer ground-truth' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  ! grep -qF '${PLUGIN_DIR}/scripts/memory-loader.sh adversarial-reviewer ground-truth' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona declares the envelope output contract" {
  # Assert the contract (the canonical return-envelope field shape), not an
  # internal identifier (scrubbed from published source).
  grep -qE 'status.*summary.*artifacts.*findings.*next|findings|sentinel_envelope' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qiE 'envelope' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

@test "AF-2026-05-22-1: persona has Review Lenses section covering PRD/Architecture/UX/Test-plan" {
  grep -qE '^## Review Lenses$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^\*\*PRD:\*\*$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^\*\*Architecture:\*\*$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
  grep -qE '^\*\*UX design:\*\*$' "$PLUGIN_ROOT/agents/adversarial-reviewer.md"
}

# --- All 6 consumer SKILL.md files reference adversarial-reviewer by name ---

@test "AF-2026-05-22-1: gaia-create-prd Step 13 dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
  ! grep -qE 'spawn a subagent to run the adversarial review' "$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
}

@test "AF-2026-05-22-1: gaia-edit-prd dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-edit-prd/SKILL.md"
  ! grep -qE 'spawn a subagent to run the adversarial review' "$PLUGIN_ROOT/skills/gaia-edit-prd/SKILL.md"
}

@test "AF-2026-05-22-1: gaia-create-arch dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-create-arch/SKILL.md"
}

@test "AF-2026-05-22-1: gaia-edit-arch dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-edit-arch/SKILL.md"
  ! grep -qE 'spawn a subagent to run the adversarial review' "$PLUGIN_ROOT/skills/gaia-edit-arch/SKILL.md"
}

@test "AF-2026-05-22-1: gaia-edit-ux dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-edit-ux/SKILL.md"
  ! grep -qE 'spawn a subagent to run the adversarial review' "$PLUGIN_ROOT/skills/gaia-edit-ux/SKILL.md"
}

@test "AF-2026-05-22-1: gaia-brownfield Phase 8b dispatches adversarial-reviewer by name" {
  grep -qF '**`adversarial-reviewer`**' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  ! grep -qE 'Spawn a subagent that runs the shared adversarial-review task' "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
}

# --- Adversarial-reviewer is NOT named `gaia-adversarial-review` (the bug filename) ---

@test "AF-2026-05-22-1: no skill dispatches the buggy non-existent 'gaia-adversarial-review' or 'adversarial-review' agent name" {
  ! grep -rqE 'gaia:adversarial-review[^e]|gaia-adversarial-review[^e]' "$PLUGIN_ROOT/skills/" 2>/dev/null || true
  # Concrete agent name must be 'adversarial-reviewer' (with -er suffix)
  grep -rqF 'adversarial-reviewer' "$PLUGIN_ROOT/skills/gaia-create-prd/SKILL.md"
}
