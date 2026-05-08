#!/usr/bin/env bats
# yield-gate-skill-md.bats — assert that SKILL.md Procedure section invokes
# yield-gate.sh at every one of the five canonical yield boundaries
# (E76-S9, AC3, T2.2 / T2.3).
#
# AC3 mandates: each of the five yield boundaries is implemented as a
# literal exec of `yield-gate.sh --phase <p> --session-id <id>`, AND the
# §Procedure prose contains the verbatim turn-terminal contract paragraph.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_MD="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
}

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "AC3: post-charter boundary execs yield-gate.sh" {
  grep -q 'yield-gate.sh --phase post-charter' "$SKILL_MD"
}

@test "AC3: post-research boundary execs yield-gate.sh" {
  grep -q 'yield-gate.sh --phase post-research' "$SKILL_MD"
}

@test "AC3: discuss-cadence boundary execs yield-gate.sh" {
  grep -q 'yield-gate.sh --phase discuss-cadence' "$SKILL_MD"
}

@test "AC3: pre-close boundary execs yield-gate.sh" {
  grep -q 'yield-gate.sh --phase pre-close' "$SKILL_MD"
}

@test "AC3: pre-save boundary execs yield-gate.sh" {
  grep -q 'yield-gate.sh --phase pre-save' "$SKILL_MD"
}

@test "AC3: turn-terminal contract paragraph is present (verbatim sentence)" {
  # The SKILL.md MUST contain the canonical turn-terminal contract sentence.
  # Match key phrases from the AC3-prescribed text. Markdown blockquote line
  # wrapping may split phrases across consecutive `> ` lines — collapse the
  # blockquote into a single buffer before grepping so wrapped phrases match.
  flat="$(grep -E '^> ' "$SKILL_MD" | sed 's/^> //' | tr '\n' ' ')"
  [[ "$flat" == *"YIELD-STOP sentinel ENDS the current LLM turn"* ]]
  [[ "$flat" == *"MUST NOT emit"* ]]
  [[ "$flat" == *"any further output after the sentinel"* ]]
  [[ "$flat" == *"script-enforced boundary"* ]]
}

@test "AC3: §Procedure header precedes the turn-terminal contract paragraph" {
  procedure_line="$(grep -n '^## Procedure' "$SKILL_MD" | head -1 | cut -d: -f1)"
  contract_line="$(grep -n 'YIELD-STOP sentinel ENDS the current LLM turn' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$procedure_line" ]
  [ -n "$contract_line" ]
  [ "$contract_line" -gt "$procedure_line" ]
}
