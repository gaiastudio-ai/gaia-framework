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

@test "accumulate increments the per-agent cumulative tokens" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 1000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 500
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --get --agent theo
  [ "$status" -eq 0 ]
  [ "$output" = "1500" ]
}

@test "an agent is not muted while under the cap" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 24999
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --is-muted --agent theo
  [ "$status" -eq 1 ]
}

@test "an agent is muted on crossing the cap (default 25000)" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
  [[ "$output" == *"theo"* ]]
  run "$HELPER" --state "$STATE" --is-muted --agent theo
  [ "$status" -eq 0 ]
}

@test "an agent is muted only once — a second cap cross emits no duplicate MUTED" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 1000
  [ "$status" -eq 0 ]
  [[ "$output" != *"MUTED"* ]]
}

@test "--per-agent-cap override changes the threshold" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 100 --per-agent-cap 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUTED"* ]]
}

@test "muting is one-way — there is no unmute path" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --unmute --agent theo
  [ "$status" -eq 3 ]
}

@test "remaining agents continue when one is muted" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens 25000
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --is-muted --agent derek
  [ "$status" -eq 1 ]
  run "$HELPER" --state "$STATE" --accumulate --agent derek --tokens 100
  [ "$status" -eq 0 ]
}

@test "--tokens must be a non-negative integer" {
  run "$HELPER" --state "$STATE" --accumulate --agent theo --tokens abc
  [ "$status" -eq 3 ]
}
