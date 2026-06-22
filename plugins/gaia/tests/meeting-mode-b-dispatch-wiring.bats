#!/usr/bin/env bats
# meeting-mode-b-dispatch-wiring.bats — pins the wiring that makes /gaia-meeting
# actually dispatch persistent teammates under Mode B (team orchestration mode).
#
# The earlier Mode B meeting migration left two gaps: turn-header.sh rejected
# `--dispatched-via teammate` (the hard blocker), and the meeting SKILL.md
# dispatch contract had no team-mode branch (it dispatched subagents
# unconditionally). This suite covers the BASH bookkeeping layer of the fix.
# The LIVE persistent-teammate round-trip (background Agent + the team message
# primitive) is live-only verification, NOT bats-coverable — the bash layer is
# all that can be asserted here.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MSCRIPTS="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts"
  TURN_HEADER="$MSCRIPTS/turn-header.sh"
  PROV="$MSCRIPTS/dispatch-provenance-check.sh"
  BRIDGE="$MSCRIPTS/meeting-mode-b-bridge.sh"
  DT="$REPO_ROOT/plugins/gaia/scripts/lib/dispatch-teammate.sh"
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  export GAIA_SESSION_DIR="$BATS_TEST_TMPDIR/session"
  mkdir -p "$GAIA_SESSION_DIR"
}

# --- AC1: turn-header accepts teammate (the blocker) ------------------------

@test "turn-header renders dispatched_via: teammate without error (AC1)" {
  run bash "$TURN_HEADER" --round 1 --turn 1 --speaker "Theo" --role "Architect" \
    --turn-cost 100 --running-total 100 --phase DISCUSS --dispatched-via teammate
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: teammate"* ]]
}

@test "turn-header still rejects an invalid dispatched-via value (AC1)" {
  run bash "$TURN_HEADER" --round 1 --turn 1 --speaker "X" --role "Y" \
    --turn-cost 1 --running-total 1 --phase DISCUSS --dispatched-via bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"teammate"* ]]   # the error string lists teammate as valid
}

@test "turn-header still accepts subagent — Mode A unchanged (AC5)" {
  run bash "$TURN_HEADER" --round 1 --turn 1 --speaker "X" --role "Y" \
    --turn-cost 1 --running-total 1 --phase DISCUSS --dispatched-via subagent
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: subagent"* ]]
}

# --- AC4: provenance gate accepts a teammate-marked turn --------------------

@test "dispatch-provenance-check passes a DISCUSS turn marked dispatched_via: teammate (AC4)" {
  local transcript="$BATS_TEST_TMPDIR/t.md"
  cat > "$transcript" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
dispatched_via: teammate

architect: the design holds [inference]
EOF
  run bash "$PROV" --stdin < "$transcript"
  [ "$status" -eq 0 ]
}

@test "dispatch-provenance-check still passes a subagent turn — Mode A (AC5)" {
  local transcript="$BATS_TEST_TMPDIR/t2.md"
  cat > "$transcript" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
dispatched_via: subagent

architect: the design holds [inference]
EOF
  run bash "$PROV" --stdin < "$transcript"
  [ "$status" -eq 0 ]
}

# --- AC2/AC3: the SKILL.md procedure has the team-mode branch ---------------

@test "SKILL.md Phase 1 INVITE has a SESSION_MODE=team teammate spawn step (AC2)" {
  grep -q 'Mode-B teammate spawn' "$SKILL"
  grep -q 'meeting_spawn_participant' "$SKILL"
}

@test "SKILL.md RESEARCH + DISCUSS have a Mode-B dispatch branch (AC2)" {
  # Two distinct Mode-B dispatch branch blocks (one per phase).
  local n
  n="$(grep -c 'Mode-B dispatch branch' "$SKILL")"
  [ "$n" -ge 2 ]
  grep -q 'dispatched-via teammate' "$SKILL"
  grep -q 'SendMessage' "$SKILL"
}

@test "SKILL.md SAVE has a Mode-B teammate teardown via shutdown_all (AC3)" {
  grep -q 'Mode-B teammate teardown' "$SKILL"
  grep -q 'shutdown_all' "$SKILL"
}

@test "SKILL.md provenance HALT prose names both subagent and teammate (AC4)" {
  grep -q "dispatched_via: teammate" "$SKILL"
  # the HALT line accepts either marker
  grep -qE "subagent.*or.*teammate|subagent'.* or .*'dispatched_via: teammate" "$SKILL"
}

# --- AC7: bookkeeping layer end-to-end under substrate=available -------------

@test "bridge spawn → relay → provenance-pass → shutdown_all (bookkeeping E2E, AC7)" {
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  unset GAIA_MODE_B_SUBSTRATE
  # spawn a non-reviewer teammate via the bridge
  local handle
  handle="$(bash -c "source '$BRIDGE' 2>/dev/null; meeting_spawn_participant gaia:architect 'ctx' 2>/dev/null | tail -1")"
  [ -n "$handle" ]
  # relay a turn (writes the transcript with teammate metadata)
  bash -c "source '$BRIDGE' 2>/dev/null; meeting_relay_turn '$handle' 'architect: design holds' >/dev/null 2>&1"
  [ -f "$GAIA_SESSION_DIR/transcript.md" ]
  # teardown brings the active count to zero
  bash -c "source '$DT' 2>/dev/null; shutdown_all >/dev/null 2>&1; [ \"\$(_dt_active_count)\" = 0 ]"
}

@test "bridge refuses a reviewer persona as a teammate under the live path (AC6)" {
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  unset GAIA_MODE_B_SUBSTRATE
  run bash -c "source '$BRIDGE' 2>/dev/null; meeting_spawn_participant gaia:validator 'ctx'"
  [ "$status" -ne 0 ]
}
