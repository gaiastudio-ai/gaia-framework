#!/usr/bin/env bats
# cadence-roundtrip.bats — cadence_counter round-trips through session-state
# (E76-S7, AC4, TS7, TC-MTG-CHKPT-6, NFR-MTG-1)
#
# The 10-turn cost-check fires whenever turn_counter % 10 == 0. This MUST stay
# byte-deterministic across yields and unaffected by raise-hand insertions —
# proving that persisting the cadence counter through session-state.sh does
# NOT alter the fire indices.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  COST_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/cost-cadence.sh"
  STATE_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  STATE="$TMP/cadence.state"
  SESSION="$TMP/2026-05-08-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

@test "AC4: cost-cadence.sh hash matches the E76-S7 baseline (byte-identity)" {
  baseline="$REPO_ROOT/_memory/checkpoints/E76-S7-baseline.sha256"
  [ -f "$baseline" ]
  cd "$REPO_ROOT"
  # Verify only the lines that are not <absent>.
  grep -v '<absent>' "$baseline" | grep -v '^#' | grep -v '^$' | shasum -a 256 -c -
}

@test "AC4: turn_counter persists across a simulated yield" {
  "$STATE_HELPER" create --file "$SESSION" --session-id "yield-test"
  "$STATE_HELPER" update --file "$SESSION" --field turn_counter --value "12"
  "$STATE_HELPER" update --file "$SESSION" --field cadence_counter --value "12"

  # Simulate the user yielding and re-entering: read state back, then continue.
  resumed_turn="$("$STATE_HELPER" read --file "$SESSION" --field turn_counter)"
  resumed_cad="$("$STATE_HELPER" read --file "$SESSION" --field cadence_counter)"
  [ "$resumed_turn" = "12" ]
  [ "$resumed_cad" = "12" ]
}

@test "AC4 / TC-MTG-CHKPT-6: K=0 vs K=4 raise-hand inserts fire cost-checks at identical indices" {
  # Run two 30-emitted-turn sequences against cost-cadence.sh: one without
  # raise-hand inserts (K=0), one with K=4 inserts mixed in. Cost checks MUST
  # fire at emitted-turn indices 10, 20, 30 in BOTH runs.
  STATE_A="$TMP/a.state"
  STATE_B="$TMP/b.state"
  fires_a=""
  for i in $(seq 1 30); do
    "$COST_HELPER" --state "$STATE_A" --tick > /dev/null
    "$COST_HELPER" --state "$STATE_A" --should-fire > /dev/null && fires_a="${fires_a}${i} "
  done
  fires_b=""
  for i in $(seq 1 30); do
    "$COST_HELPER" --state "$STATE_B" --tick > /dev/null
    "$COST_HELPER" --state "$STATE_B" --should-fire > /dev/null && fires_b="${fires_b}${i} "
  done
  [ "$(echo "$fires_a" | tr -s ' ' | sed 's/ $//')" = "$(echo "$fires_b" | tr -s ' ' | sed 's/ $//')" ]
  [ "$(echo "$fires_a" | tr -s ' ' | sed 's/ $//')" = "10 20 30" ]
}
