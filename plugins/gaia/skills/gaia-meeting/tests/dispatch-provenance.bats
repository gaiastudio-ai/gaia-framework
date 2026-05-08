#!/usr/bin/env bats
# dispatch-provenance.bats — gaia-meeting transcript provenance static check (E76-S10)
#
# Covers AC4 / TC-MTG-DISPATCH-3.
#
# The harness scans a transcript file and asserts the per-turn header
# `dispatched_via:` field matches the canonical value for the turn's phase:
#   RESEARCH (prelude) -> dispatched_via: subagent
#   DISCUSS  (turn)    -> dispatched_via: subagent
#   any [i]nterject    -> dispatched_via: interject
#   CHARTER turn       -> dispatched_via: charter
#
# Usage from a harness:
#   TRANSCRIPT_FILE=path/to/transcript.md bats dispatch-provenance.bats

setup() {
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECKER="$SKILL_DIR/scripts/dispatch-provenance-check.sh"
  FIXTURES="$SKILL_DIR/tests/fixtures"
}

@test "Pre-flight: dispatch-provenance-check.sh exists and is executable" {
  [ -x "$CHECKER" ]
}

@test "Pre-flight: inline-roleplay fixture exists" {
  [ -f "$FIXTURES/transcript-inline-roleplay-2026-05-08.md" ]
}

@test "Pre-flight: dispatched fixture exists" {
  [ -f "$FIXTURES/transcript-dispatched-2026-05-08.md" ]
}

# AC4 / AC5: inline-roleplay fixture FAILS the provenance check
@test "AC4/AC5: inline-roleplay fixture FAILS the provenance check" {
  run "$CHECKER" "$FIXTURES/transcript-inline-roleplay-2026-05-08.md"
  [ "$status" -ne 0 ]
  # Failure message names at least one offending turn
  [[ "$output" == *"turn"* ]]
  [[ "$output" == *"dispatched_via"* ]]
}

# AC4 / AC5: dispatched fixture PASSES the provenance check
@test "AC4/AC5: dispatched fixture PASSES the provenance check" {
  run "$CHECKER" "$FIXTURES/transcript-dispatched-2026-05-08.md"
  [ "$status" -eq 0 ]
}

# AC4: missing-field RESEARCH turn FAILS naming the offending turn
@test "AC4: missing dispatched_via on a RESEARCH turn FAILS with naming" {
  TMP="$(mktemp -d)"
  cat > "$TMP/t.md" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
[Prelude] Theo
EOF
  run "$CHECKER" "$TMP/t.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"t1"* ]] || [[ "$output" == *"turn 1"* ]]
  rm -rf "$TMP"
}

# AC4: wrong-value RESEARCH turn FAILS
@test "AC4: dispatched_via: charter on a RESEARCH turn FAILS" {
  TMP="$(mktemp -d)"
  cat > "$TMP/t.md" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: charter
[Prelude] Theo
EOF
  run "$CHECKER" "$TMP/t.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"t1"* ]] || [[ "$output" == *"RESEARCH"* ]]
  rm -rf "$TMP"
}

# AC4: well-formed minimal transcript PASSES
@test "AC4: well-formed minimal transcript PASSES" {
  TMP="$(mktemp -d)"
  cat > "$TMP/t.md" <<'EOF'
[round 0 / turn 0 / Facilitator (Facilitator) / per-turn-cost 0 tokens / running-total 0 tokens]
Phase: CHARTER
Turn: c1
dispatched_via: charter

[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: subagent
[Prelude] Theo

[round 1 / turn 2 / Theo (Architect) / per-turn-cost 100 tokens / running-total 200 tokens]
Phase: DISCUSS
Turn: t2
dispatched_via: subagent

[round 1 / turn 3 / Julien (User) / per-turn-cost 0 tokens / running-total 200 tokens]
Phase: DISCUSS
Turn: t3
dispatched_via: interject
EOF
  run "$CHECKER" "$TMP/t.md"
  [ "$status" -eq 0 ]
  rm -rf "$TMP"
}

# AC4: DISCUSS turn lacking the field FAILS
@test "AC4: missing dispatched_via on a DISCUSS turn FAILS" {
  TMP="$(mktemp -d)"
  cat > "$TMP/t.md" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
Turn: t1
EOF
  run "$CHECKER" "$TMP/t.md"
  [ "$status" -ne 0 ]
  rm -rf "$TMP"
}
