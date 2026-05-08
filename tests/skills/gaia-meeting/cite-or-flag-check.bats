#!/usr/bin/env bats
# cite-or-flag-check.bats — facilitator cite-or-flag invariant (E76-S2)
#
# Covers AC6, AC7, AC10 / TC-MTG-RESEARCH-3, TC-MTG-RESEARCH-6, TC-MTG-GUARD-1.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/cite-or-flag-check.sh"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

@test "Pre-flight: cite-or-flag-check.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# AC6 / TC-MTG-RESEARCH-3: classification per-line
@test "AC6: line with file-path citation classifies as 'cited'" {
  run "$HELPER" --classify-line "We rely on docs/planning-artifacts/foo.md for context."
  [ "$status" -eq 0 ]
  [ "$output" = "cited" ]
}

@test "AC6: line with URL classifies as 'cited'" {
  run "$HELPER" --classify-line "Per https://anthropic.com/agents the limit is 10."
  [ "$status" -eq 0 ]
  [ "$output" = "cited" ]
}

@test "AC6: line with _memory/ reference classifies as 'cited'" {
  run "$HELPER" --classify-line "From _memory/Theo-sidecar/decisions/d.md we know X."
  [ "$status" -eq 0 ]
  [ "$output" = "cited" ]
}

@test "AC6: line with [inference] token classifies as 'inference'" {
  run "$HELPER" --classify-line "I think X is faster than Y [inference]."
  [ "$status" -eq 0 ]
  [ "$output" = "inference" ]
}

@test "AC6: factual claim with neither marker classifies as 'unflagged-inference'" {
  run "$HELPER" --classify-line "The function foo() returns false on empty input."
  [ "$status" -eq 0 ]
  [ "$output" = "unflagged-inference" ]
}

# AC7 / TC-MTG-GUARD-1: HALT on unflagged-inference draft turn
@test "AC7: --gate-draft-turn passes when every claim line is cited or [inference]" {
  draft="$TMP_DIR/draft.txt"
  cat > "$draft" <<'EOF'
Per docs/planning-artifacts/architecture/12-12-adr-detail-records.md, ADR-084 mandates this.
Honestly I think this is the right call [inference].
EOF
  run "$HELPER" --gate-draft-turn "$draft"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "AC7 / TC-MTG-GUARD-1: --gate-draft-turn HALTs on unflagged-inference line" {
  draft="$TMP_DIR/draft.txt"
  cat > "$draft" <<'EOF'
The function bar() returns 42 unconditionally.
Per docs/foo.md we know X.
EOF
  run "$HELPER" --gate-draft-turn "$draft"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HALT"* ]] || [[ "$output" == *"unflagged-inference"* ]] || [[ "$output" == *"halt"* ]]
}

@test "AC7: HALT output identifies the offending line text" {
  draft="$TMP_DIR/draft.txt"
  printf 'The OFFENDING_TOKEN_X is set to true.\n' > "$draft"
  run "$HELPER" --gate-draft-turn "$draft"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OFFENDING_TOKEN_X"* ]]
}

@test "AC7: questions and meta-conversation are NOT classified as factual claims" {
  run "$HELPER" --classify-line "Should we adopt approach X?"
  [ "$status" -eq 0 ]
  [ "$output" = "non-claim" ]
}

# AC10 / TC-MTG-RESEARCH-6: deterministic static check from saved file alone
@test "AC10: --verify-transcript on a clean saved meeting passes" {
  transcript="$TMP_DIR/meeting.md"
  cat > "$transcript" <<'EOF'
---
charter: "Decide whether to adopt X for Y"
research_phase: enabled
web_search: enabled
---

## Phase: DISCUSS

Per docs/foo.md, X is recommended.
This will be faster [inference].
EOF
  run "$HELPER" --verify-transcript "$transcript"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "AC10 / TC-MTG-RESEARCH-6: --verify-transcript fails on unflagged claim" {
  transcript="$TMP_DIR/meeting.md"
  cat > "$transcript" <<'EOF'
---
charter: "X"
---

## Phase: DISCUSS

The bar() function definitely returns 17 always.
EOF
  run "$HELPER" --verify-transcript "$transcript"
  [ "$status" -ne 0 ]
}

@test "AC10: --verify-transcript is deterministic — same input -> same output" {
  transcript="$TMP_DIR/m.md"
  cat > "$transcript" <<'EOF'
---
charter: "X"
---

## Phase: DISCUSS

Per docs/foo.md X.
This is faster [inference].
EOF
  out1=$("$HELPER" --verify-transcript "$transcript" 2>&1; echo "exit=$?")
  out2=$("$HELPER" --verify-transcript "$transcript" 2>&1; echo "exit=$?")
  [ "$out1" = "$out2" ]
}
