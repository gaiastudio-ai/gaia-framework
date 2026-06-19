#!/usr/bin/env bats
# deferral-phrase-match.bats — Unit tests for the deferral-phrase matcher (E88-S1)
# Covers TC-DPD-5 stem-collision + positive matches for each v1 phrase.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  export LIB_DIR
  MATCHER="$LIB_DIR/deferral-phrase-match.sh"
  export MATCHER
}

teardown() {
  common_teardown
}

# Positive matches — one per v1 phrase (6 entries).
@test "deferral-phrase-match: matches 'deferred' (positive)" {
  run "$MATCHER" "this work is deferred to next sprint"
  [ "$status" -eq 0 ]
  [[ "$output" == *deferred* ]]
}

@test "deferral-phrase-match: matches 'follow-up integration story' (positive)" {
  run "$MATCHER" "see follow-up integration story for wiring"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follow-up integration story"* ]]
}

@test "deferral-phrase-match: matches 'stub seam' (positive)" {
  run "$MATCHER" "this is a stub seam awaiting implementation"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub seam"* ]]
}

@test "deferral-phrase-match: matches 'harness wiring lands' (positive)" {
  run "$MATCHER" "once harness wiring lands in next sprint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"harness wiring lands"* ]]
}

@test "deferral-phrase-match: matches 'not-yet-wired' (positive)" {
  run "$MATCHER" "the not-yet-wired hook fires later"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not-yet-wired"* ]]
}

@test "deferral-phrase-match: matches 'production wiring' (positive)" {
  run "$MATCHER" "production wiring will be added in S5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"production wiring"* ]]
}

# TC-DPD-5 — stem-collision: 'wires the production wiring up' matches the
# multi-word deferral phrase 'production wiring' (grep -wF matches a whole-word
# phrase boundary).
@test "stem-collision — 'wires the production wiring up' matches 'production wiring'" {
  run "$MATCHER" "wires the production wiring up"
  [ "$status" -eq 0 ]
  [[ "$output" == *"production wiring"* ]]
}

# TC-DPD-5 — negative: 'uses workflow internally' must NOT match.
@test "'uses workflow internally' does NOT match any deferral phrase" {
  run "$MATCHER" "uses workflow internally"
  [ "$status" -eq 1 ]
}

# Sourcing the matcher exposes the function.
@test "deferral-phrase-match: sourcing matcher exposes match_deferral_phrase_in_text" {
  # shellcheck source=/dev/null
  source "$MATCHER"
  run match_deferral_phrase_in_text "this is deferred work"
  [ "$status" -eq 0 ]
  [[ "$output" == *deferred* ]]
}
