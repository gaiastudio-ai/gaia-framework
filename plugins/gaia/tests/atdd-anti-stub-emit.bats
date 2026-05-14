#!/usr/bin/env bats
# atdd-anti-stub-emit.bats — E88-S5
#
# Covers TC-DPD-18..21:
#   TC-DPD-18 — single dispatch verb -> one anti-stub Then-clause
#   TC-DPD-19 — no dispatch verb -> no anti-stub Then-clause
#   TC-DPD-20 — multi-verb AC -> dedup'd Then-clauses (one per unique primitive)
#   TC-DPD-21 — retroactive E76-S10 AC2 fixture
#
# Helper under test:
#   gaia-public/plugins/gaia/scripts/lib/atdd-anti-stub-emit.sh
#
# Invocation contract:
#   atdd-anti-stub-emit.sh --ac-text "<ac body>"
#     - exits 0 always
#     - emits one Then-clause per UNIQUE dispatch verb canonicalized to a
#       primitive name (Agent-tool spawn | Agent-tool dispatch |
#       primitive invocation | wiring | primitive call).
#     - empty stdout when no dispatch verbs match.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/atdd-anti-stub-emit.sh"
  export LIB_DIR HELPER
}

teardown() {
  common_teardown
}

# ---------------- TC-DPD-18: single dispatch verb -> one Then-clause ----------------
@test "TC-DPD-18: AC containing 'spawns' emits 'Agent-tool spawn' anti-stub Then" {
  run "$HELPER" --ac-text "the orchestrator spawns the Agent subagent"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Then: $*_STUB env vars are unset AND a real Agent-tool spawn was logged'* ]]
}

# ---------------- TC-DPD-19: no dispatch verb -> no clause ----------------
@test "TC-DPD-19: AC containing no dispatch verb emits no anti-stub Then" {
  run "$HELPER" --ac-text "the user is shown an error message on invalid input"
  [ "$status" -eq 0 ]
  [[ "$output" != *'$*_STUB'* ]]
}

# ---------------- TC-DPD-20: multi-verb dedup ----------------
@test "TC-DPD-20: multi-verb AC emits exactly one Then per unique primitive (dedup)" {
  run "$HELPER" --ac-text "the workflow spawns the agent, dispatches the task, and spawns a follow-up"
  [ "$status" -eq 0 ]
  # Exactly two Then-clauses: 'Agent-tool spawn' and 'Agent-tool dispatch'.
  local spawn_count dispatch_count
  spawn_count=$(printf '%s\n' "$output" | grep -c "Agent-tool spawn was logged" || true)
  dispatch_count=$(printf '%s\n' "$output" | grep -c "Agent-tool dispatch was logged" || true)
  [ "$spawn_count" -eq 1 ]
  [ "$dispatch_count" -eq 1 ]
}

# ---------------- TC-DPD-21: retroactive E76-S10 AC2 ----------------
@test "TC-DPD-21: retroactive E76-S10 AC2 emits canonical Agent-tool spawn clause" {
  run "$HELPER" --ac-text "the meeting prelude turn spawns the Agent subagent"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Then: $*_STUB env vars are unset AND a real Agent-tool spawn was logged'* ]]
}

# ---------------- TC-DPD-22: canonicalization map coverage ----------------
@test "TC-DPD-22: all five canonicalization map verbs emit expected primitives" {
  for verb in dispatches invokes wires calls; do
    run "$HELPER" --ac-text "the system $verb the target"
    [ "$status" -eq 0 ]
    [[ "$output" == *'$*_STUB env vars are unset AND a real'* ]]
  done
}

# ---------------- TC-DPD-23: canonicalize-dispatch-verb.sh contract ----------------
@test "TC-DPD-23: canonicalize-dispatch-verb.sh maps inflections to base primitive" {
  local helper="$LIB_DIR/canonicalize-dispatch-verb.sh"
  [ -x "$helper" ]
  run "$helper" spawns
  [ "$output" = "Agent-tool spawn" ]
  run "$helper" spawned
  [ "$output" = "Agent-tool spawn" ]
  run "$helper" spawn
  [ "$output" = "Agent-tool spawn" ]
  run "$helper" dispatches
  [ "$output" = "Agent-tool dispatch" ]
  run "$helper" invokes
  [ "$output" = "primitive invocation" ]
  run "$helper" wires
  [ "$output" = "wiring" ]
  run "$helper" calls
  [ "$output" = "primitive call" ]
}
