#!/usr/bin/env bats
# dispatch-verb-match.bats — Unit tests for the dispatch-verb matcher (E88-S1)
# Covers TC-DPD-4 stem-collision + positive matches for each v1 verb.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  export LIB_DIR
  MATCHER="$LIB_DIR/dispatch-verb-match.sh"
  export MATCHER
}

teardown() {
  common_teardown
}

# Positive matches — one per v1 verb (5 entries).
@test "dispatch-verb-match: matches 'spawns' (positive)" {
  run "$MATCHER" "the orchestrator spawns a sub-agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *spawns* ]]
}

@test "dispatch-verb-match: matches 'dispatches' (positive)" {
  run "$MATCHER" "the skill dispatches the validator"
  [ "$status" -eq 0 ]
  [[ "$output" == *dispatches* ]]
}

@test "dispatch-verb-match: matches 'invokes' (positive)" {
  run "$MATCHER" "the orchestrator invokes the agent tool"
  [ "$status" -eq 0 ]
  [[ "$output" == *invokes* ]]
}

@test "dispatch-verb-match: matches 'wires' (positive)" {
  run "$MATCHER" "the harness wires the bridge in"
  [ "$status" -eq 0 ]
  [[ "$output" == *wires* ]]
}

@test "dispatch-verb-match: matches 'calls' (positive)" {
  run "$MATCHER" "the script calls the helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *calls* ]]
}

# TC-DPD-4 — stem-collision: 'wires the production wiring up' matches 'wires'
# (dispatch) and MUST NOT erroneously match a deferral substring through this
# matcher.
@test "TC-DPD-4: stem-collision — 'wires the production wiring up' matches 'wires'" {
  run "$MATCHER" "wires the production wiring up"
  [ "$status" -eq 0 ]
  [[ "$output" == *wires* ]]
  # Must not match the bare deferral phrase 'production wiring' as a dispatch verb.
  [[ "$output" != *"production wiring"* ]]
}

# TC-DPD-4 — stem-collision: 'harness wiring lands in next sprint' MUST NOT
# match any dispatch verb (no bare 'wires' with word boundaries).
@test "TC-DPD-4: stem-collision — 'harness wiring lands in next sprint' does NOT match dispatch" {
  run "$MATCHER" "harness wiring lands in next sprint"
  [ "$status" -eq 1 ]
}

# Negative — irrelevant text.
@test "dispatch-verb-match: irrelevant text exits 1" {
  run "$MATCHER" "the rain in spain"
  [ "$status" -eq 1 ]
}

# TC-DPD-7 — sourcing the matcher exposes the function.
@test "TC-DPD-7: sourcing matcher exposes match_dispatch_verb_in_text" {
  # shellcheck source=/dev/null
  source "$MATCHER"
  run match_dispatch_verb_in_text "spawns the subagent"
  [ "$status" -eq 0 ]
  [[ "$output" == *spawns* ]]
}
