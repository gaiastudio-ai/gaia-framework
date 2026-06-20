#!/usr/bin/env bats
# dispatch-provenance-teammate.bats — teammate dispatch-provenance allowlist.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting" && pwd)"
  CHECKER="$SKILL_DIR/scripts/dispatch-provenance-check.sh"
  export SKILL_DIR CHECKER
}

teardown() {
  common_teardown
}

# teammate value on a RESEARCH turn passes the gate (AC1)
@test "dispatched_via:teammate on RESEARCH turn passes audit (AC1)" {
  local t="$TEST_TMP/transcript-teammate.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: teammate
EOF
  run "$CHECKER" "$t"
  [ "$status" -eq 0 ]
}

# teammate value on a DISCUSS turn passes the gate (AC1 — second phase)
@test "dispatched_via:teammate on DISCUSS turn passes audit (AC1)" {
  local t="$TEST_TMP/transcript-teammate-discuss.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Nate (SM) / per-turn-cost 80 tokens / running-total 80 tokens]
Phase: DISCUSS
Turn: t1
dispatched_via: teammate
EOF
  run "$CHECKER" "$t"
  [ "$status" -eq 0 ]
}

# subagent still passes (AC2)
@test "dispatched_via:subagent still passes audit (AC2)" {
  local t="$TEST_TMP/transcript-subagent.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: subagent
EOF
  run "$CHECKER" "$t"
  [ "$status" -eq 0 ]
}

# interject still passes (AC3)
@test "dispatched_via:interject still passes audit (AC3)" {
  local t="$TEST_TMP/transcript-interject.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: interject
EOF
  run "$CHECKER" "$t"
  [ "$status" -eq 0 ]
}

# unknown value is rejected with non-zero exit and a diagnostic (AC4)
@test "dispatched_via:unknown_value is rejected with non-zero exit (AC4)" {
  local t="$TEST_TMP/transcript-unknown.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
Turn: t1
dispatched_via: unknown_value
EOF
  run "$CHECKER" "$t"
  [ "$status" -ne 0 ]
}

# rejection diagnostic lists the allowed values incl. teammate (AC4)
@test "rejection diagnostic lists allowed values including teammate (AC4)" {
  local t="$TEST_TMP/transcript-bad.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
Turn: t1
dispatched_via: unknown_value
EOF
  run "$CHECKER" "$t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"teammate"* ]]
}
