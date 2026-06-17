#!/usr/bin/env bats
# gaia-sprint-review-orchestration.bats — /gaia-sprint-review 8-step orchestration tests.
#
# Story: E93-S3 — /gaia-sprint-review skill scaffold (Mode A) + Track A Val
#                 dispatch + composite verdict + UNVERIFIED bypass.
# Anchor: ADR-108 (sprint-level state machine + agent-assisted sprint review).
#
# Coverage (per traceability matrix §34 row 4129, 17 TCs):
#   TC-SGR-18..20 — pre-condition gate (all-done happy, non-done refusal, no-goals refusal)
#   TC-SGR-21..23 — composite verdict (all-PASSED→PASSED, FAILED→correction,
#                   infra-only→UNVERIFIED)
#   TC-SGR-24    — main-turn Mode A orchestration class (also in anti-pattern bats;
#                   here we verify the 8-step structure)
#   TC-SGR-25..27 — composite verdict edge cases (early-term, PARTIAL, one-FAILED)
#   TC-SGR-33..34 — correction-loop findings + handoff
#   TC-SGR-35..36 — UNVERIFIED bypass full flow
#   TC-SGR-42    — skill scaffold structural smoke
#   TC-SGR-44    — E83 + E87 dual-sentinel write/assert
#
# Hermetic strategy: fixtures live under tests/fixtures/sprint-review/. Val
# dispatch is mocked by pre-staging sentinel envelopes so bats never invokes
# the real Agent tool.

load 'test_helper.bash'

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/gaia-sprint-review"
SKILL_MD="$SKILL_DIR/SKILL.md"
SCRIPTS="$SKILL_DIR/scripts"
COMPOSE_VERDICT="$SCRIPTS/compose-verdict.sh"
WRITE_VAL_SENTINEL="$SCRIPTS/write-val-sentinel.sh"
TRACK_B_DISPATCH="$SCRIPTS/track-b-dispatch.sh"
SETUP_SH="$SCRIPTS/setup.sh"
FINALIZE_SH="$SCRIPTS/finalize.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# TC-SGR-42 — skill scaffold structural smoke
# ---------------------------------------------------------------------------

@test "skill scaffold: SKILL.md exists at canonical path" {
  [ -f "$SKILL_MD" ] || {
    echo "SKILL.md not found at $SKILL_MD (TDD red)"
    return 1
  }
}

@test "skill scaffold: SKILL.md frontmatter contains required keys" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  frontmatter=$(awk '/^---$/{f++; next} f==1{print}' "$SKILL_MD")
  for key in 'name:[[:space:]]*gaia-sprint-review' 'description:' 'argument-hint:' 'allowed-tools:' 'orchestration_class:[[:space:]]*heavy-procedural'; do
    echo "$frontmatter" | grep -qE "^$key" || {
      echo "Frontmatter missing required key matching: $key"
      echo "Frontmatter content:"
      echo "$frontmatter"
      return 1
    }
  done
}

@test "skill scaffold: SKILL.md body has 4 canonical top-level sections (Setup, Critical Rules, Steps, Finalize)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  for section in '^## Setup$' '^## Critical Rules$' '^## Steps$' '^## Finalize$'; do
    grep -qE "$section" "$SKILL_MD" || {
      echo "SKILL.md body missing required section heading: $section"
      return 1
    }
  done
}

@test "skill scaffold: 5 helper scripts present + executable" {
  for script in "$SETUP_SH" "$FINALIZE_SH" "$WRITE_VAL_SENTINEL" "$TRACK_B_DISPATCH" "$COMPOSE_VERDICT"; do
    [ -x "$script" ] || {
      echo "Missing or non-executable script: $script"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# TC-SGR-18..20 — pre-condition gate (mocked via direct call into the skill's
# script tier OR via SKILL.md prose grep — Step 1 prose mentions the gate)
# ---------------------------------------------------------------------------

@test "pre-condition gate: SKILL.md Step 1 prose names the all-stories-done check" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'all[- ]stories[- ]done|stories must be.*done|status.*done.*before' "$SKILL_MD" || {
    echo "Step 1 prose does not document the all-stories-done pre-condition gate (AC3)"
    return 1
  }
}

@test "pre-condition refusal: SKILL.md documents canonical refusal stderr" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'refuse|REFUSE.*non-done|non-done.*REFUSE|complete or roll-over' "$SKILL_MD" || {
    echo "Step 1 prose does not document the canonical refusal message for non-done stories (AC3)"
    return 1
  }
}

@test "no-goals refusal: SKILL.md Step 1 documents no-goals refusal path" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'no sprint goals|empty goals|goals.*missing|no.*goals.*defined' "$SKILL_MD" || {
    echo "Step 1 prose does not document the no-sprint-goals refusal path (FR-488 AC3)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-21, 26, 27 — composite verdict reducer happy + edge cases
# ---------------------------------------------------------------------------

@test "composite PASSED: compose-verdict.sh emits PASSED for (PASSED, PASSED)" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b PASSED 2>&1)
  [ "$result" = "PASSED" ]
}

@test "composite PASSED-equivalent: SKIPPED Track B + PASSED Track A → PASSED ( stub path)" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b SKIPPED 2>&1)
  [ "$result" = "PASSED" ]
}

@test "composite PARTIAL: PARTIAL Track A + PASSED Track B → PASSED (PARTIAL does not block)" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a PARTIAL --track-b PASSED 2>&1)
  [ "$result" = "PASSED" ]
}

@test "composite FAILED on Track B one-FAILED: PASSED A + FAILED B → FAILED" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a PASSED --track-b FAILED 2>&1)
  [ "$result" = "FAILED" ]
}

@test "composite FAILED (Track A all-FAILED): FAILED A + any B → FAILED" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a FAILED --track-b PASSED 2>&1)
  [ "$result" = "FAILED" ]
}

@test "composite UNVERIFIED: UNVERIFIED A + PASSED B → UNVERIFIED" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a UNVERIFIED --track-b PASSED 2>&1)
  [ "$result" = "UNVERIFIED" ]
}

@test "composite-verdict rejects non-canonical inputs with canonical stderr (Tex tightening)" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  run bash "$COMPOSE_VERDICT" --track-a foo --track-b PASSED
  [ "$status" -ne 0 ]
  # Tex TDR-E93S3-002: tighten to "non-canonical" specifically (the actual canonical stderr token).
  [[ "$output" == *"non-canonical"* ]]
}

# ---------------------------------------------------------------------------
# Tex TDR-E93S3-001 — additional verdict-pair coverage. Story AC7 / NFR-070
# defines precedence FAILED > UNVERIFIED > PASSED. The following 3 pairs
# confirm that precedence under composition.
# ---------------------------------------------------------------------------

@test "composite (FAILED, FAILED) → FAILED" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a FAILED --track-b FAILED 2>&1)
  [ "$result" = "FAILED" ]
}

@test "composite (UNVERIFIED, FAILED) → FAILED (FAILED precedence over UNVERIFIED)" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a UNVERIFIED --track-b FAILED 2>&1)
  [ "$result" = "FAILED" ]
}

@test "composite (UNVERIFIED, UNVERIFIED) → UNVERIFIED" {
  [ -x "$COMPOSE_VERDICT" ] || skip "compose-verdict.sh not yet implemented (TDD red)"
  result=$(bash "$COMPOSE_VERDICT" --track-a UNVERIFIED --track-b UNVERIFIED 2>&1)
  [ "$result" = "UNVERIFIED" ]
}

# ---------------------------------------------------------------------------
# Tex TDR-E93S3-003 — AC4 + AC8 prose-grep coverage (was missing in Red phase).
# ---------------------------------------------------------------------------

@test "prose: SKILL.md Step 2 invokes sprint-state.sh transition --to review" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'sprint-state\.sh transition.*--sprint.*--to review' "$SKILL_MD" || {
    echo "Step 2 prose does not invoke sprint-state.sh transition --to review (AC4)"
    return 1
  }
}

@test "prose: SKILL.md Step 6 PASSED handoff names /gaia-sprint-close" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE '/gaia-sprint-close.*finalize|invoke /gaia-sprint-close' "$SKILL_MD" || {
    echo "Step 6 prose does not emit canonical handoff to /gaia-sprint-close (AC8)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-22, 23 — composite verdict outcomes routed to correction or
# UNVERIFIED (SKILL.md prose-level verification)
# ---------------------------------------------------------------------------

@test "FAILED routing: SKILL.md Step 7 prose documents correction transition + action-items + handoff" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'review.*correction|active.*correction|sprint-state\.sh.*correction' "$SKILL_MD" || {
    echo "Step 7 prose does not document the review→correction transition (AC9)"
    return 1
  }
  grep -qE 'action-items\.yaml|action-items|story_injection' "$SKILL_MD" || {
    echo "Step 7 prose does not document action-items.yaml findings recording (AC9)"
    return 1
  }
}

@test "UNVERIFIED routing: SKILL.md Step 8 prose documents criteria spec bypass path" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'sprint-review-unverifiable-criteria\.md|AI-2026-05-16-5|UNVERIFIED.*bypass' "$SKILL_MD" || {
    echo "Step 8 prose does not document the UNVERIFIED bypass path per AI-5 criteria spec (AC10)"
    return 1
  }
  grep -qE 'set-review-justification' "$SKILL_MD" || {
    echo "Step 8 prose does not invoke sprint-state.sh set-review-justification (AC10)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-33, 34 — correction-loop findings + handoff
# ---------------------------------------------------------------------------

@test "correction-loop findings: SKILL.md Step 7 invokes type-target-resolver via /gaia-meeting path" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'type-target-resolver\.sh|sprint-correction' "$SKILL_MD" || {
    echo "Step 7 prose does not invoke type-target-resolver.sh or use type: sprint-correction (AC9)"
    return 1
  }
}

@test "story_injection handoff: SKILL.md Step 7 references /gaia-correct-course story_injection" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE '/gaia-correct-course.*story_injection|story_injection.*correct-course' "$SKILL_MD" || {
    echo "Step 7 prose does not emit canonical handoff to /gaia-correct-course story_injection (AC9)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-35, 36 — UNVERIFIED bypass mechanical signal capture + Val
# justification-validation routing
# ---------------------------------------------------------------------------

@test "UNVERIFIED bypass: SKILL.md Step 8 captures mechanical signals (C1/C2/C3, qualifying_ratio)" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'C1.*C2.*C3|primary_criterion|qualifying_ratio' "$SKILL_MD" || {
    echo "Step 8 prose does not collect AI-5 mechanical signals (AC10)"
    return 1
  }
}

@test "UNVERIFIED bypass: SKILL.md Step 8 dispatches Val justification-validation + handoff to sprint-close" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'justification.*validation|Val.*UNVERIFIED.*PASSED|Val.*justification' "$SKILL_MD" || {
    echo "Step 8 prose does not dispatch the second Val pass for justification-validation (AC10)"
    return 1
  }
  grep -qE '/gaia-sprint-close.*UNVERIFIED|UNVERIFIED.*sprint-close|bypass.*closed' "$SKILL_MD" || {
    echo "Step 8 prose does not emit canonical handoff to /gaia-sprint-close with UNVERIFIED-bypass marker (AC10)"
    return 1
  }
}

# ---------------------------------------------------------------------------
# TC-SGR-44 — E83 + E87 dual-sentinel write/assert (write-val-sentinel.sh
# helper smoke + Step 3 prose verification)
# ---------------------------------------------------------------------------

@test "dual-sentinel: write-val-sentinel.sh exists + writes E83 dispatch sentinel" {
  [ -x "$WRITE_VAL_SENTINEL" ] || skip "write-val-sentinel.sh not yet implemented (TDD red)"
  # Smoke-test: feed mock Val return JSON, expect sentinel at the canonical path
  cd "$TEST_TMP"
  mkdir -p .gaia/memory/checkpoints
  mock_val_return='{"status":"PASS","summary":"mock","findings":[],"agent":"val"}'
  result=$(printf '%s' "$mock_val_return" | bash "$WRITE_VAL_SENTINEL" --sprint-id sprint-99 2>&1 || true)
  # The helper should either write the sentinel or print a usage error on missing flags.
  # Verify the script accepts --sprint-id and emits a path on stdout / writes to .gaia/memory/checkpoints/
  echo "$result" | grep -qE 'sentinel.*written|sprint-99.*val-dispatched|sprint-review-sprint-99-val-dispatched' || {
    echo "write-val-sentinel.sh did not write the E83 dispatch sentinel for sprint-99"
    echo "Output: $result"
    return 1
  }
}

@test "dual-sentinel: SKILL.md Step 3 prose names both dispatch sentinel + envelope sentinel" {
  [ -f "$SKILL_MD" ] || skip "SKILL.md not yet implemented (TDD red)"
  grep -qE 'sprint-review-.*-val-dispatched\.json' "$SKILL_MD" || {
    echo "Step 3 prose does not name the dispatch sentinel path (AC5)"
    return 1
  }
  grep -qE 'write-val-envelope\.sh|assert.agent.envelope|assert_agent_envelope' "$SKILL_MD" || {
    echo "Step 3 prose does not name the envelope sentinel writer/asserter (AC5)"
    return 1
  }
}
