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
