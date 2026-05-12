#!/usr/bin/env bats
# val-bridge-migration.bats — coverage for E87 Val Bridge Migration consumer skills.
#
# Anchor: ADR-104 — Val Bridge Migration: Main-Turn Agent Dispatch Across Val-Consuming Skills.
#
# This file accumulates per-story migration tests as E87-S2..S5 land. E87-S2
# adds TC-VBR-12 (and its meta variants 12c/12d/12e/12f) covering the
# `/gaia-val-validate` + `validator.md` frontmatter + persona sentinel-write
# migration.
#
# E87-S2 coverage:
#   TC-VBR-12   — Forged sentinel (agent=val, no persona_sig) is rejected by
#                 assert_agent_envelope (primary forgery-resistance, NFR-064).
#   TC-VBR-12c  — Neither /gaia-val-validate SKILL.md nor validator.md
#                 contains `context: fork` in the dispatch frontmatter.
#   TC-VBR-12d  — /gaia-val-validate SKILL.md grep-count of
#                 `assert_agent_envelope` is >= 1 (helper is consumed).
#   TC-VBR-12e  — /gaia-val-validate SKILL.md contains an ADR-104 reference
#                 in a changelog or revision-history section.
#   TC-VBR-12f  — validator.md instructs the Val persona to emit the envelope
#                 sentinel (persona_sig / envelope-sentinel reference present).

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
HELPER="$PLUGIN_ROOT/scripts/lib/assert-agent-envelope.sh"
SKILL_MD="$PLUGIN_ROOT/skills/gaia-val-validate/SKILL.md"
VALIDATOR_MD="$PLUGIN_ROOT/agents/validator.md"
FORGED_FIXTURE="$BATS_TEST_DIRNAME/fixtures/assert-agent-envelope/forged.json"

# Canonical HALT prefix — literal string from E87-S1 (no regex drift).
HALT_PREFIX='HALT: Val agent envelope assertion failed'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---------------- TC-VBR-12: forged sentinel rejected (primary) ----------------
@test "TC-VBR-12: forged sentinel (no persona_sig) is rejected by assert_agent_envelope — NFR-064" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-12c: frontmatter migration ----------------
@test "TC-VBR-12c: /gaia-val-validate SKILL.md frontmatter does not declare context: fork" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  # Inspect only the frontmatter block (between the leading --- and the next ---).
  run awk '/^---$/{c++; next} c==1{print}' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # Guard against vacuous green if awk emits empty (no frontmatter delimiters).
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

@test "TC-VBR-12c (validator.md sibling): validator.md frontmatter does not declare context: fork" {
  [ -f "$VALIDATOR_MD" ] || skip "validator.md not present"
  run awk '/^---$/{c++; next} c==1{print}' "$VALIDATOR_MD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

# ---------------- TC-VBR-12d: helper consumption ----------------
@test "TC-VBR-12d: SKILL.md references assert_agent_envelope (helper is consumed)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$SKILL_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-12e: ADR-104 changelog ----------------
@test "TC-VBR-12e: SKILL.md contains ADR-104 reference (changelog/migration note)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not present"
  grep -q 'ADR-104' "$SKILL_MD"
}

# ---------------- TC-VBR-12f: persona sentinel-write contract ----------------
@test "TC-VBR-12f: validator.md instructs the Val persona to emit the envelope sentinel" {
  [ -f "$VALIDATOR_MD" ] || skip "validator.md not present"
  # Any of three markers is sufficient: persona_sig field, envelope-sentinel prose, or canonical sentinel path slug.
  grep -Eq 'persona_sig|envelope sentinel|val-envelope-' "$VALIDATOR_MD"
}

# ============================================================================
# E87-S3 coverage:
#   TC-VBR-9          — /gaia-validate-story SKILL.md references assert_agent_envelope
#   TC-VBR-9-runtime  — validate-story dispatch path HALTs against forged sentinel
#   TC-VBR-9b         — /gaia-validate-story frontmatter does not declare context: fork
#   TC-VBR-9c         — /gaia-validate-story SKILL.md contains no self-judgment
#                       fallthrough prose ("inline Val", "auto-judged", "main-turn
#                       inline validation")
#   TC-VBR-10         — /gaia-fix-story SKILL.md references assert_agent_envelope
#   TC-VBR-10-runtime — fix-story dispatch path HALTs against forged sentinel
#   TC-VBR-10b        — /gaia-fix-story SKILL.md contains no self-judgment fallthrough prose
#   TC-VBR-10c        — Both migrated SKILL.md files contain ADR-104 reference
# ============================================================================

VALIDATE_STORY_MD="$PLUGIN_ROOT/skills/gaia-validate-story/SKILL.md"
FIX_STORY_MD="$PLUGIN_ROOT/skills/gaia-fix-story/SKILL.md"

# ---------------- TC-VBR-9: validate-story envelope-assert grep ----------------
@test "TC-VBR-9: /gaia-validate-story SKILL.md references assert_agent_envelope" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$VALIDATE_STORY_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-9-runtime: validate-story forgery HALT ----------------
@test "TC-VBR-9-runtime: validate-story dispatch path HALTs on forged sentinel — NFR-064" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-9b: validate-story frontmatter migrated ----------------
@test "TC-VBR-9b: /gaia-validate-story SKILL.md frontmatter does not declare context: fork" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  run awk '/^---$/{c++; next} c==1{print}' "$VALIDATE_STORY_MD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  ! grep -Eq '^context:[[:space:]]*fork' <<< "$output"
}

# ---------------- TC-VBR-9c: validate-story no fallthrough prose ----------------
@test "TC-VBR-9c: /gaia-validate-story SKILL.md contains no inline-Val / auto-judged fallthrough prose" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  # Scan for the documented bypass class. A "removed" callout in a Changelog
  # entry could legitimately mention these phrases; we exempt explicit
  # Changelog lines (lines that contain "Changelog" or "(removed)").
  hits=$(grep -E 'inline Val|auto-judged|main-turn inline validation' "$VALIDATE_STORY_MD" 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT fall' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-10: fix-story envelope-assert grep ----------------
@test "TC-VBR-10: /gaia-fix-story SKILL.md references assert_agent_envelope" {
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  count=$(grep -c "assert_agent_envelope" "$FIX_STORY_MD" || true)
  [ "$count" -ge 1 ]
}

# ---------------- TC-VBR-10-runtime: fix-story forgery HALT ----------------
@test "TC-VBR-10-runtime: fix-story dispatch path HALTs on forged sentinel — closes feedback_fix_story_inline_revalidation_bypass.md" {
  [ -f "$HELPER" ] || skip "E87-S1 helper not present"
  [ -f "$FORGED_FIXTURE" ] || skip "E87-S1 forged fixture not present"
  source "$HELPER"
  run assert_agent_envelope "$FORGED_FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HALT_PREFIX"* ]]
}

# ---------------- TC-VBR-10b: fix-story no fallthrough prose ----------------
@test "TC-VBR-10b: /gaia-fix-story SKILL.md contains no inline-Val / main-turn-inline-validation fallthrough prose" {
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  hits=$(grep -E 'inline Val|auto-judged|main-turn inline validation' "$FIX_STORY_MD" 2>/dev/null | grep -v -E 'Changelog|\(removed\)|removed the|no longer|MUST NOT|do NOT fall' || true)
  [ -z "$hits" ]
}

# ---------------- TC-VBR-10c: both migrated SKILL.md files reference ADR-104 ----------------
@test "TC-VBR-10c: both validate-story and fix-story SKILL.md contain ADR-104 reference" {
  [ -f "$VALIDATE_STORY_MD" ] || skip "validate-story SKILL.md not present"
  [ -f "$FIX_STORY_MD" ] || skip "fix-story SKILL.md not present"
  grep -q 'ADR-104' "$VALIDATE_STORY_MD"
  grep -q 'ADR-104' "$FIX_STORY_MD"
}
