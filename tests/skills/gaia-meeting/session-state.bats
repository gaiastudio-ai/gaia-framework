#!/usr/bin/env bats
# session-state.bats — gaia-meeting session-state helper (E76-S7, AC1, TC-MTG-CHKPT-1)
#
# AC1: session-state.sh round-trips the FR-MTG-33 schema fields without loss.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  SESSION="$TMP/2026-05-08-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: session-state.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC1: create writes a fresh session file with FR-MTG-33 defaults" {
  run "$HELPER" create --file "$SESSION" --session-id "2026-05-08-test"
  [ "$status" -eq 0 ]
  [ -f "$SESSION" ]
  grep -q '^session_id: "2026-05-08-test"$' "$SESSION"
  grep -q '^phase: "INVITE"$' "$SESSION"
  grep -q '^round: 0$' "$SESSION"
  grep -q '^turn_counter: 0$' "$SESSION"
  grep -q '^cadence_counter: 0$' "$SESSION"
  grep -q '^cumulative_cost: 0$' "$SESSION"
}

@test "AC1: read emits each field from the session file" {
  "$HELPER" create --file "$SESSION" --session-id "2026-05-08-test" >/dev/null
  run "$HELPER" read --file "$SESSION" --field phase
  [ "$status" -eq 0 ]
  [ "$output" = "INVITE" ]
}

@test "AC1: update mutates a single field and persists the change" {
  "$HELPER" create --file "$SESSION" --session-id "2026-05-08-test" >/dev/null
  run "$HELPER" update --file "$SESSION" --field phase --value "DISCUSS"
  [ "$status" -eq 0 ]
  run "$HELPER" read --file "$SESSION" --field phase
  [ "$output" = "DISCUSS" ]
}

@test "AC1: full-field round-trip — every FR-MTG-33 field updates and reads back" {
  "$HELPER" create --file "$SESSION" --session-id "2026-05-08-test" >/dev/null
  "$HELPER" update --file "$SESSION" --field phase --value "DISCUSS"
  "$HELPER" update --file "$SESSION" --field round --value "3"
  "$HELPER" update --file "$SESSION" --field turn_counter --value "12"
  "$HELPER" update --file "$SESSION" --field cadence_counter --value "12"
  "$HELPER" update --file "$SESSION" --field cumulative_cost --value "9876"
  "$HELPER" update --file "$SESSION" --field last_checkpoint_at --value "2026-05-08T12:00:00Z"
  "$HELPER" update --file "$SESSION" --field last_checkpoint_phase --value "DISCUSS"

  [ "$("$HELPER" read --file "$SESSION" --field phase)" = "DISCUSS" ]
  [ "$("$HELPER" read --file "$SESSION" --field round)" = "3" ]
  [ "$("$HELPER" read --file "$SESSION" --field turn_counter)" = "12" ]
  [ "$("$HELPER" read --file "$SESSION" --field cadence_counter)" = "12" ]
  [ "$("$HELPER" read --file "$SESSION" --field cumulative_cost)" = "9876" ]
  [ "$("$HELPER" read --file "$SESSION" --field last_checkpoint_at)" = "2026-05-08T12:00:00Z" ]
  [ "$("$HELPER" read --file "$SESSION" --field last_checkpoint_phase)" = "DISCUSS" ]
}

@test "AC1: read on missing file exits non-zero" {
  run "$HELPER" read --file "$TMP/does-not-exist.yaml" --field phase
  [ "$status" -ne 0 ]
}

@test "AC1: create is atomic — failed write does not leave a partial file" {
  # Send create to a path whose parent directory does not exist; the helper
  # MUST exit non-zero and MUST NOT create the partial file.
  run "$HELPER" create --file "$TMP/nope/2026-05-08-test.yaml" --session-id "x"
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/nope/2026-05-08-test.yaml" ]
}

@test "AC1: scratchpad_state and raise_hand_ledger round-trip as opaque blobs" {
  "$HELPER" create --file "$SESSION" --session-id "2026-05-08-test" >/dev/null
  "$HELPER" update --file "$SESSION" --field scratchpad_state --value 'SP-1=hello;SP-2=world'
  "$HELPER" update --file "$SESSION" --field raise_hand_ledger --value 'cycle1=A->C:honored'
  [ "$("$HELPER" read --file "$SESSION" --field scratchpad_state)" = "SP-1=hello;SP-2=world" ]
  [ "$("$HELPER" read --file "$SESSION" --field raise_hand_ledger)" = "cycle1=A->C:honored" ]
}
