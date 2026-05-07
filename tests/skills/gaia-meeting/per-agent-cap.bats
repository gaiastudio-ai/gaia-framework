#!/usr/bin/env bats
# per-agent-cap.bats — gaia-meeting per-agent token cap accountant (E76-S6)
#
# AC5 / FR-MTG-29 / TC-MTG-GUARD-3: default per-agent cap = 25 000 tokens,
# cumulative across research, discussion, raise-hand, and research interrupts.
# On cap-cross: agent muted (one-way, no unmute), single MUTED event emitted,
# remaining agents continue.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/per-agent-cap.sh"
  TMP="$(mktemp -d)"
  STATE="$TMP/agents.state"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: per-agent-cap.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC5: accumulate increments per-agent cumulative tokens" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 1000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 500
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --get --agent theo
  [ "$status" -eq 0 ]
  [ "$output" = "1500" ]
}

@test "AC5: agent is not muted under cap" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 24999
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --is-muted --agent theo
  [ "$status" -eq 1 ]
}

@test "AC5: agent muted on cap cross (default 25000)" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
  [[ "$output" == *"theo"* ]]
  run "$HELPER" --state "$STATE" --is-muted --agent theo
  [ "$status" -eq 0 ]
}

@test "AC5: agent muted only once — second cap cross does not emit duplicate MUTED" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 1000
  [ "$status" -eq 0 ]
  [[ "$output" != *"MUTED"* ]]
}

@test "AC5: --per-agent-cap override changes the threshold" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 100 --per-agent-cap 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
}

@test "AC5: muting is one-way — no unmute path" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --unmute --agent theo
  [ "$status" -eq 3 ]
}

@test "AC5: remaining agents continue when one is muted" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --is-muted --agent derek
  [ "$status" -eq 1 ]
  run "$HELPER" --state "$STATE" --accumulate --agent derek --tokens 100
  [ "$status" -eq 0 ]
}

@test "AC5: --tokens must be non-negative integer" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens abc
  [ "$status" -eq 3 ]
}
