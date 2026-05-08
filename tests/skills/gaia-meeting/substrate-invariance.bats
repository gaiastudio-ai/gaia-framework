#!/usr/bin/env bats
# substrate-invariance.bats — TC-MTG-CHKPT-7 (E76-S7, AC6)
#
# The user-visible behaviour of the checkpoint-yield prompt block, yield
# boundaries, resumed phase, and cumulative-cost rounding MUST be identical
# under Substrate A (Claude Agent Teams) and Substrate B (sequential-fork
# fallback). This test exercises the substrate-invariant surface — the
# helper scripts that drive the user-visible behaviour — and verifies that
# their outputs do not depend on substrate selection.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATE_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  PARSE_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/parse-resume-flags.sh"
  COST_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/cost-cadence.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "AC6 / TC-MTG-CHKPT-7: parse-resume-flags output is identical regardless of substrate (no substrate-specific branches)" {
  # The parser MUST NOT consult any substrate-environment variable. We verify
  # by running it under two different SUBSTRATE env values and diffing
  # output.
  out_a="$(SUBSTRATE=agent-teams "$PARSE_HELPER" --resume 2026-05-08-test --continue)"
  out_b="$(SUBSTRATE=sequential-fork "$PARSE_HELPER" --resume 2026-05-08-test --continue)"
  [ "$out_a" = "$out_b" ]
}

@test "AC6 / TC-MTG-CHKPT-7: session-state round-trip is byte-identical regardless of substrate" {
  SESSION_A="$TMP/a.yaml"
  SESSION_B="$TMP/b.yaml"
  SUBSTRATE=agent-teams "$STATE_HELPER" create --file "$SESSION_A" --session-id "2026-05-08-test"
  SUBSTRATE=sequential-fork "$STATE_HELPER" create --file "$SESSION_B" --session-id "2026-05-08-test"
  diff "$SESSION_A" "$SESSION_B"
}

@test "AC6 / TC-MTG-CHKPT-7: cost-cadence fire indices are identical across substrates for a 30-emitted-turn run" {
  STATE_A="$TMP/a.state"
  STATE_B="$TMP/b.state"
  fires_a=""
  for i in $(seq 1 30); do
    SUBSTRATE=agent-teams "$COST_HELPER" --state "$STATE_A" --tick > /dev/null
    SUBSTRATE=agent-teams "$COST_HELPER" --state "$STATE_A" --should-fire > /dev/null && fires_a="${fires_a}${i} "
  done
  fires_b=""
  for i in $(seq 1 30); do
    SUBSTRATE=sequential-fork "$COST_HELPER" --state "$STATE_B" --tick > /dev/null
    SUBSTRATE=sequential-fork "$COST_HELPER" --state "$STATE_B" --should-fire > /dev/null && fires_b="${fires_b}${i} "
  done
  [ "$(echo "$fires_a" | tr -s ' ' | sed 's/ $//')" = "$(echo "$fires_b" | tr -s ' ' | sed 's/ $//')" ]
}
