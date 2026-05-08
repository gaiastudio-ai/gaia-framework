#!/usr/bin/env bats
# turn-header.bats — gaia-meeting turn-header.sh tests, including the
# E76-S10 --dispatched-via extension (AC3).

setup() {
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HELPER="$SKILL_DIR/scripts/turn-header.sh"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

@test "Pre-flight: turn-header.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# Backward-compat: legacy invocation (no --phase, no --dispatched-via) emits
# the canonical bracketed header silently — pre-existing call sites in the
# fixture-capture path predate E76-S10. The grace WARNING fires only when
# --phase is set to CHARTER/INVITE/CLOSE/SAVE (T3.4 migration scope).
@test "AC3 grace: legacy invocation (no --phase) emits header silently" {
  run --separate-stderr "$HELPER" --round 1 --turn 1 --speaker Theo --role Architect \
                                   --turn-cost 100 --running-total 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"[round 1 / turn 1 / Theo (Architect)"* ]]
  [[ "$stderr" != *"WARNING:"* ]]
}

# AC3: --dispatched-via subagent is accepted and emitted in the header
@test "AC3: --dispatched-via subagent is accepted and emitted in the header" {
  run "$HELPER" --round 1 --turn 1 --speaker Theo --role Architect \
                --turn-cost 100 --running-total 100 \
                --phase RESEARCH --dispatched-via subagent
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: subagent"* ]]
}

# AC3: --dispatched-via interject is accepted
@test "AC3: --dispatched-via interject is accepted" {
  run "$HELPER" --round 1 --turn 1 --speaker Julien --role User \
                --turn-cost 0 --running-total 100 \
                --phase DISCUSS --dispatched-via interject
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: interject"* ]]
}

# AC3: --dispatched-via charter is accepted
@test "AC3: --dispatched-via charter is accepted" {
  run "$HELPER" --round 0 --turn 0 --speaker Facilitator --role Facilitator \
                --turn-cost 0 --running-total 0 \
                --phase CHARTER --dispatched-via charter
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: charter"* ]]
}

# AC3: invalid --dispatched-via value rejected with exit 2
@test "AC3: invalid --dispatched-via value is rejected with exit 2" {
  run "$HELPER" --round 1 --turn 1 --speaker Theo --role Architect \
                --turn-cost 100 --running-total 100 \
                --phase RESEARCH --dispatched-via bogus
  [ "$status" -eq 2 ]
}

# AC3: missing --dispatched-via on RESEARCH phase is REQUIRED -> exit 2
@test "AC3: missing --dispatched-via on RESEARCH phase fails with exit 2" {
  run "$HELPER" --round 1 --turn 1 --speaker Theo --role Architect \
                --turn-cost 100 --running-total 100 --phase RESEARCH
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dispatched-via"* ]] || [[ "$output" == *"required"* ]]
}

# AC3: missing --dispatched-via on DISCUSS phase is REQUIRED -> exit 2
@test "AC3: missing --dispatched-via on DISCUSS phase fails with exit 2" {
  run "$HELPER" --round 1 --turn 1 --speaker Theo --role Architect \
                --turn-cost 100 --running-total 100 --phase DISCUSS
  [ "$status" -eq 2 ]
}

# AC3: missing --dispatched-via on CHARTER phase emits grace WARNING but proceeds
@test "AC3: missing --dispatched-via on CHARTER emits grace warning but proceeds" {
  run --separate-stderr "$HELPER" --round 0 --turn 0 --speaker Facilitator --role Facilitator \
                                   --turn-cost 0 --running-total 0 --phase CHARTER
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING:"* ]]
  [[ "$stderr" == *"sprint-41"* ]]
}

# AC3: missing --dispatched-via on INVITE phase emits grace WARNING but proceeds
@test "AC3: missing --dispatched-via on INVITE emits grace warning but proceeds" {
  run --separate-stderr "$HELPER" --round 0 --turn 0 --speaker Facilitator --role Facilitator \
                                   --turn-cost 0 --running-total 0 --phase INVITE
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING:"* ]]
}
