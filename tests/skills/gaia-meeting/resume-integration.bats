#!/usr/bin/env bats
# resume-integration.bats — TC-MTG-CHKPT-3 / TC-MTG-CHKPT-4 / TC-MTG-CHKPT-5
# integration coverage: session-state preservation across `--resume` flows.
# (E76-S7, AC3)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATE_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  PARSE_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/parse-resume-flags.sh"
  TMP="$(mktemp -d)"
  SESSION="$TMP/2026-05-08-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

@test "TC-MTG-CHKPT-3: --resume --continue preserves cadence_counter, raise_hand_ledger, scratchpad_state" {
  # Seed a paused-at-post-RESEARCH session.
  "$STATE_HELPER" create --file "$SESSION" --session-id "2026-05-08-test"
  "$STATE_HELPER" update --file "$SESSION" --field phase --value "RESEARCH"
  "$STATE_HELPER" update --file "$SESSION" --field last_checkpoint_phase --value "RESEARCH"
  "$STATE_HELPER" update --file "$SESSION" --field cadence_counter --value "8"
  "$STATE_HELPER" update --file "$SESSION" --field raise_hand_ledger --value "cycle1=A->C:honored"
  "$STATE_HELPER" update --file "$SESSION" --field scratchpad_state --value "SP-1=alpha;SP-2=beta"
  "$STATE_HELPER" update --file "$SESSION" --field cumulative_cost --value "12345"

  # Parse `--resume <id> --continue`.
  run "$PARSE_HELPER" --resume 2026-05-08-test --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=continue"* ]]

  # Re-enter: read everything back. Each field MUST be preserved verbatim.
  [ "$("$STATE_HELPER" read --file "$SESSION" --field last_checkpoint_phase)" = "RESEARCH" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field cadence_counter)" = "8" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field raise_hand_ledger)" = "cycle1=A->C:honored" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field scratchpad_state)" = "SP-1=alpha;SP-2=beta" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field cumulative_cost)" = "12345" ]
}

@test "TC-MTG-CHKPT-4: --resume --interject carries the interjection payload through the parser" {
  "$STATE_HELPER" create --file "$SESSION" --session-id "2026-05-08-test"
  "$STATE_HELPER" update --file "$SESSION" --field phase --value "DISCUSS"
  "$STATE_HELPER" update --file "$SESSION" --field last_checkpoint_phase --value "DISCUSS"

  run "$PARSE_HELPER" --resume 2026-05-08-test --interject "review the auth ADR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=interject"* ]]
  [[ "$output" == *"interject_text=review the auth ADR"* ]]

  # The session file's last_checkpoint_phase MUST still be DISCUSS — the
  # parser does not mutate state; mutation happens in the orchestrator after
  # injection.
  [ "$("$STATE_HELPER" read --file "$SESSION" --field last_checkpoint_phase)" = "DISCUSS" ]
}

@test "TC-MTG-CHKPT-5: --resume --wrap-up preserves research and discuss state" {
  "$STATE_HELPER" create --file "$SESSION" --session-id "2026-05-08-test"
  "$STATE_HELPER" update --file "$SESSION" --field phase --value "DISCUSS"
  "$STATE_HELPER" update --file "$SESSION" --field round --value "2"
  "$STATE_HELPER" update --file "$SESSION" --field turn_counter --value "7"
  "$STATE_HELPER" update --file "$SESSION" --field cadence_counter --value "7"
  "$STATE_HELPER" update --file "$SESSION" --field scratchpad_state --value "SP-1=keepme"

  run "$PARSE_HELPER" --resume 2026-05-08-test --wrap-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=wrap_up"* ]]

  # State preserved — the orchestrator will jump to CLOSE without losing work.
  [ "$("$STATE_HELPER" read --file "$SESSION" --field round)" = "2" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field turn_counter)" = "7" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field cadence_counter)" = "7" ]
  [ "$("$STATE_HELPER" read --file "$SESSION" --field scratchpad_state)" = "SP-1=keepme" ]
}
