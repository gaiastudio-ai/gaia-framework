#!/usr/bin/env bats
# meeting-dispatch-provenance-integration.bats — E76-S22 ADR-106 wiring.
#
# Covers TC-DPC-1..5:
#   TC-DPC-1: SAVE transcript with all turns dispatched_via:subagent -> PASS.
#   TC-DPC-2: SAVE transcript with one DISCUSS turn missing field -> HALT.
#   TC-DPC-3: SAVE transcript with prelude turn using inline-surrogate -> HALT.
#   TC-DPC-4: HALT stderr matches canonical error format.
#   TC-DPC-5: stdin-mode invocation works against in-memory transcript fixture.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting" && pwd)"
  CHECKER="$SKILL_DIR/scripts/dispatch-provenance-check.sh"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  export SKILL_DIR CHECKER SKILL_MD
}

teardown() {
  common_teardown
}

# ---------------- TC-DPC-1: clean transcript PASSES ----------------
@test "TC-DPC-1: clean transcript (all turns dispatched_via:subagent) passes audit" {
  local t="$TEST_TMP/transcript-clean.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: subagent

[round 1 / turn 2 / Theo (Architect) / per-turn-cost 100 tokens / running-total 200 tokens]
Phase: DISCUSS
Turn: t2
dispatched_via: subagent
EOF
  run "$CHECKER" "$t"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPC-2: missing dispatched_via -> HALT ----------------
@test "TC-DPC-2: DISCUSS turn missing dispatched_via fails audit" {
  local t="$TEST_TMP/transcript-missing.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
Turn: t1
EOF
  run "$CHECKER" "$t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ---------------- TC-DPC-3: inline-surrogate prelude -> HALT ----------------
@test "TC-DPC-3: prelude turn with dispatched_via:inline-surrogate fails audit" {
  local t="$TEST_TMP/transcript-inline.md"
  cat > "$t" <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: inline-surrogate
EOF
  run "$CHECKER" "$t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ---------------- TC-DPC-4: canonical error format ----------------
@test "TC-DPC-4: SKILL.md Phase 7 SAVE wires the canonical halt-event error string" {
  # The SKILL.md wiring at Phase 7 SAVE must reference the canonical error
  # substring per AC3.
  run grep -F "dispatch-provenance-check failed" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPC-5: stdin-mode invocation ----------------
@test "TC-DPC-5: stdin-mode invocation works on clean transcript" {
  local content
  content="$(cat <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: RESEARCH
Turn: t1
dispatched_via: subagent
EOF
)"
  run bash -c "printf '%s\n' \"\$1\" | '$CHECKER' --stdin" -- "$content"
  [ "$status" -eq 0 ]
}

@test "TC-DPC-5b: stdin-mode invocation fails on bad transcript" {
  local content
  content="$(cat <<'EOF'
[round 1 / turn 1 / Theo (Architect) / per-turn-cost 100 tokens / running-total 100 tokens]
Phase: DISCUSS
Turn: t1
EOF
)"
  run bash -c "printf '%s\n' \"\$1\" | '$CHECKER' --stdin" -- "$content"
  [ "$status" -ne 0 ]
}

# ---------------- AC6: audit-script header lists production callsites ----------------
@test "AC6: dispatch-provenance-check.sh header has Production callsites section" {
  run grep -F "Production callsites" "$CHECKER"
  [ "$status" -eq 0 ]
}

@test "AC6: production callsite cites gaia-meeting SKILL.md Phase 7 SAVE" {
  run grep -F "gaia-meeting/SKILL.md" "$CHECKER"
  [ "$status" -eq 0 ]
}

# ---------------- AC2: SKILL.md Phase 7 SAVE invokes dispatch-provenance-check.sh ----------------
@test "AC2: SKILL.md Phase 7 SAVE invokes dispatch-provenance-check.sh" {
  run grep -F "dispatch-provenance-check.sh" "$SKILL_MD"
  [ "$status" -eq 0 ]
}
