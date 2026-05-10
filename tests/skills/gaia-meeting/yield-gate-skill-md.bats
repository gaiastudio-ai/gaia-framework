#!/usr/bin/env bats
# yield-gate-skill-md.bats — assert that SKILL.md Procedure section invokes
# yield-gate.sh at every one of the five canonical yield boundaries AND
# emits a substrate `AskUserQuestion` tool call at each boundary
# (E76-S9, E76-S18 / AF-2026-05-10-1, AC3 / AC8, T2.2 / T2.3).
#
# History:
#   E76-S9 / AF-2026-05-08-4 — each yield boundary execed
#     `yield-gate.sh --phase <p> --session-id <id>` as the user-facing prompt
#     mechanism; the helper emitted a turn-terminal stdout sentinel.
#   E76-S18 / AF-2026-05-10-1 — the stdout sentinel was empirically defeated
#     by harness Auto Mode and replaced by the substrate `AskUserQuestion`
#     primitive. SKILL.md now follows a two-step procedure at every boundary:
#       1. exec `yield-gate.sh --phase <p> --session-id <id> --side-effect-only`
#          (writes session-state side effects, emits ZERO stdout)
#       2. emit a substrate `AskUserQuestion` tool call (halts the LLM turn
#          at the harness layer regardless of Auto Mode)
#
# AC3/AC8 mandates the SKILL.md procedure prose carries both halves at every
# boundary — the side-effect call AND the substrate AskUserQuestion call.

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

@test "AF-2026-05-10-1: every yield boundary execs --side-effect-only" {
  # The post-AF-2026-05-10-1 contract requires `--side-effect-only` at each
  # boundary so the procedure prose explicitly documents the no-stdout intent.
  count="$(grep -c -- '--side-effect-only' "$SKILL_MD" || true)"
  # At least 5 occurrences (one per yield boundary).
  [ "$count" -ge 5 ]
}

@test "AC8: post-AF-2026-05-10-1 turn-terminal contract paragraph is present" {
  # The SKILL.md MUST contain the canonical substrate-enforced turn-terminal
  # contract sentence. Match key phrases from the prescribed text. Markdown
  # blockquote line wrapping may split phrases across consecutive `> ` lines —
  # collapse the blockquote into a single buffer before grepping so wrapped
  # phrases match.
  flat="$(grep -E '^> ' "$SKILL_MD" | sed 's/^> //' | tr '\n' ' ')"
  [[ "$flat" == *"AskUserQuestion"*"ENDS the current LLM turn"* ]]
  [[ "$flat" == *"MUST NOT emit"* ]]
  [[ "$flat" == *"substrate-enforced boundary"* ]]
}

@test "AC8: §Procedure header precedes the turn-terminal contract paragraph" {
  procedure_line="$(grep -n '^## Procedure' "$SKILL_MD" | head -1 | cut -d: -f1)"
  contract_line="$(grep -nE 'AskUserQuestion[^.]*ENDS the current LLM turn' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$procedure_line" ]
  [ -n "$contract_line" ]
  [ "$contract_line" -gt "$procedure_line" ]
}
