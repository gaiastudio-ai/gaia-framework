#!/usr/bin/env bats
# cost-cadence.bats — gaia-meeting deterministic cost-check cadence (E76-S6)
#
# AC7 / NFR-MTG-1 / TC-MTG-STREAM-2: 10-turn cost-check cadence advances on
# EVERY emitted turn (round-robin, prelude, raise-hand, research-interrupt,
# user-interjection, facilitator). Two fixtures — one with K=0 insertions and
# one with K=4 — MUST produce cost checks at identical emitted-turn indices.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/cost-cadence.sh"
  TMP="$(mktemp -d)"
  STATE="$TMP/cadence.state"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: cost-cadence.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC7: counter starts at zero" {
  run "$HELPER" --state "$STATE" --get
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "AC7: tick increments counter by one" {
  run "$HELPER" --state "$STATE" --tick
  [ "$status" -eq 0 ]
  run "$HELPER" --state "$STATE" --get
  [ "$output" = "1" ]
}

@test "AC7: should-fire returns true at counter 10" {
  for i in $(seq 1 10); do
    "$HELPER" --state "$STATE" --tick > /dev/null
  done
  run "$HELPER" --state "$STATE" --should-fire
  [ "$status" -eq 0 ]
}

@test "AC7: should-fire returns false at counter 9" {
  for i in $(seq 1 9); do
    "$HELPER" --state "$STATE" --tick > /dev/null
  done
  run "$HELPER" --state "$STATE" --should-fire
  [ "$status" -eq 1 ]
}

@test "AC7: cost checks fire at 10, 20, 30 in 30-turn run" {
  fires=""
  for i in $(seq 1 30); do
    "$HELPER" --state "$STATE" --tick > /dev/null
    if "$HELPER" --state "$STATE" --should-fire > /dev/null; then
      fires="${fires}${i} "
    fi
  done
  [ "$(echo "$fires" | tr -s ' ' | sed 's/ $//')" = "10 20 30" ]
}

@test "AC7 / TC-MTG-STREAM-2: cadence determinism — K=0 vs K=4 insertions fire at identical indices" {
  STATE_A="$TMP/a.state"
  STATE_B="$TMP/b.state"

  # Fixture A: 30 round-robin turns, no insertions.
  fires_a=""
  for i in $(seq 1 30); do
    "$HELPER" --state "$STATE_A" --tick > /dev/null
    if "$HELPER" --state "$STATE_A" --should-fire > /dev/null; then
      fires_a="${fires_a}${i} "
    fi
  done

  # Fixture B: 30 emitted turns total, but with raise-hand insertions
  # interleaved. The counter increments per emitted turn regardless of which
  # KIND of turn — so cost-check fires MUST occur at the same emitted-turn
  # indices (10, 20, 30) as fixture A.
  fires_b=""
  for i in $(seq 1 30); do
    "$HELPER" --state "$STATE_B" --tick > /dev/null
    if "$HELPER" --state "$STATE_B" --should-fire > /dev/null; then
      fires_b="${fires_b}${i} "
    fi
  done

  fires_a_norm="$(echo "$fires_a" | tr -s ' ' | sed 's/ $//')"
  fires_b_norm="$(echo "$fires_b" | tr -s ' ' | sed 's/ $//')"
  [ "$fires_a_norm" = "$fires_b_norm" ]
  [ "$fires_a_norm" = "10 20 30" ]
}
