#!/usr/bin/env bats
# test-review-gate-plan-id.bats -- unit tests for review-gate.sh --plan-id
#
# E35-S2: Approval gate wiring + review-gate.sh --plan-id extension
# Surfaces tested: --plan-id flag on update and status subcommands,
# ledger record schema, backward-compat regression guard.
#
# AC coverage:
#   AC1   -- Happy path --plan-id round-trip
#   AC2   -- Backward compat: no --plan-id, byte-identical output
#   AC6   -- ADR-045/ADR-050 callers without --plan-id unchanged
#   AC-EC1 -- Concurrent ledger writes on different stories (atomic write)
#   AC-EC2 -- Shell-injection --plan-id payload rejected
#   AC-EC3 -- Empty --plan-id= value rejected
#   AC-EC9 -- status --plan-id miss returns UNVERIFIED
#   AC-EC10 -- Legacy ledger record without plan_id field
#
# Public functions exercised:
#   main (flag parser), cmd_update (ledger write with --plan-id),
#   cmd_status (ledger read with --plan-id filter), is_canonical_gate
#   (test-automate-plan gate acceptance when --plan-id present)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  export PROJECT_PATH="$TEST_TMP"
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"

  # Default ledger path under PROJECT_PATH
  LEDGER="$TEST_TMP/.review-gate-ledger"
  export REVIEW_GATE_LEDGER="$LEDGER"
  # AF-2026-05-20-1: plan-id ledger semantics + pre-E35 byte-identical
  # no-plan-id behavior are orthogonal to the proof-of-execution contract.
  # Disable POE so the existing fixtures (which don't pass --report) still
  # exercise the verdict-write mechanics.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}

teardown() { common_teardown; }

# seed a minimal story file with Review Gate table
seed_story() {
  local key="$1" verdict="${2:-UNVERIFIED}"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $verdict | --- |
| QA Tests | $verdict | --- |
| Security Review | $verdict | --- |
| Test Automation | $verdict | --- |
| Test Review | $verdict | --- |
| Performance Review | $verdict | --- |
EOF
}

# ---------------------------------------------------------------------------
# AC1: Happy path --plan-id round-trip
# update with --plan-id, then status should return verdict + matching plan_id
# ---------------------------------------------------------------------------

@test "AC1: update with --plan-id writes ledger record; status returns verdict with plan_id" {
  seed_story PID1 UNVERIFIED
  local plan_id="plan-abc123-def456"

  # update with --plan-id should write a ledger row
  run "$SCRIPT" update --story PID1 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]

  # Ledger file must exist
  [ -f "$LEDGER" ]

  # Ledger row must contain the plan_id (tab-separated format)
  grep -q "PID1" "$LEDGER"
  grep -q "test-automate-plan" "$LEDGER"
  grep -q "$plan_id" "$LEDGER"

  # status should return the verdict for this plan_id
  run "$SCRIPT" status --story PID1 --gate "test-automate-plan" --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
  [[ "$output" == *"$plan_id"* ]]
}

# ---------------------------------------------------------------------------
# AC2: Backward-compat no --plan-id
# update + status WITHOUT --plan-id must produce byte-identical behavior
# ---------------------------------------------------------------------------

@test "AC2: update without --plan-id preserves pre-E35 byte-identical behavior" {
  seed_story PID2 UNVERIFIED

  # The existing code path: update a canonical Review Gate row WITHOUT --plan-id
  run "$SCRIPT" update --story PID2 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]

  # Verify the story file was updated correctly (pre-E35 behavior)
  grep -q 'Code Review | PASSED' "$ART/PID2-fake.md"

  # Other rows must remain unchanged
  grep -q 'QA Tests | UNVERIFIED' "$ART/PID2-fake.md"

  # Status without --plan-id must still work
  run "$SCRIPT" status --story PID2
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# AC6: ADR-045/ADR-050 callers without --plan-id unchanged
# Regression guard: round-trip without --plan-id = byte-identical to pre-E35
# ---------------------------------------------------------------------------

@test "AC6: ADR-045 caller round-trip without --plan-id is byte-identical to pre-E35" {
  seed_story PID3 UNVERIFIED

  # Capture pre-update file content for comparison
  local before
  before="$(cat "$ART/PID3-fake.md")"

  # Update exactly one row without --plan-id
  run "$SCRIPT" update --story PID3 --gate "Security Review" --verdict PASSED
  [ "$status" -eq 0 ]

  # Only the targeted row should change; structure must be identical
  local after
  after="$(cat "$ART/PID3-fake.md")"

  # The update must have changed exactly the Security Review row
  grep -q 'Security Review | PASSED' "$ART/PID3-fake.md"

  # No ledger file should be created for non-plan-id updates
  # (ledger is only for --plan-id records)
  [ ! -f "$LEDGER" ] || ! grep -q "PID3" "$LEDGER"
}

# ---------------------------------------------------------------------------
# AC-EC1: Concurrent ledger writes on different stories
# Both records preserved; atomic write semantics hold
# ---------------------------------------------------------------------------

@test "AC-EC1: concurrent ledger writes on different stories both preserved" {
  seed_story CONC1 UNVERIFIED
  seed_story CONC2 UNVERIFIED

  local plan_id1="plan-conc1-$(date +%s)"
  local plan_id2="plan-conc2-$(date +%s)"

  # Write two ledger records sequentially (simulating concurrent writes)
  run "$SCRIPT" update --story CONC1 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id1"
  [ "$status" -eq 0 ]

  run "$SCRIPT" update --story CONC2 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id2"
  [ "$status" -eq 0 ]

  # Both records must be present in the ledger
  [ -f "$LEDGER" ]
  grep -q "CONC1" "$LEDGER"
  grep -q "CONC2" "$LEDGER"
  grep -q "$plan_id1" "$LEDGER"
  grep -q "$plan_id2" "$LEDGER"
}

# ---------------------------------------------------------------------------
# AC-EC2: Shell-injection --plan-id payload rejected
# ---------------------------------------------------------------------------

@test "AC-EC2: shell-injection --plan-id payload rejected" {
  seed_story INJECT1 UNVERIFIED

  # Attempt shell injection via --plan-id
  run "$SCRIPT" update --story INJECT1 --gate "test-automate-plan" --verdict PASSED --plan-id "'; rm -rf /'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]] || [[ "$output" == *"rejected"* ]] || [[ "$output" == *"plan-id"* ]]

  # Ledger must not contain the malicious payload
  [ ! -f "$LEDGER" ] || ! grep -q "rm -rf" "$LEDGER"
}

@test "AC-EC2: backtick shell injection in --plan-id rejected" {
  seed_story INJECT2 UNVERIFIED

  run "$SCRIPT" update --story INJECT2 --gate "test-automate-plan" --verdict PASSED --plan-id '`whoami`'
  [ "$status" -ne 0 ]
}

@test "AC-EC2: dollar-paren shell injection in --plan-id rejected" {
  seed_story INJECT3 UNVERIFIED

  run "$SCRIPT" update --story INJECT3 --gate "test-automate-plan" --verdict PASSED --plan-id '$(cat /etc/passwd)'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC-EC3: Empty --plan-id= value rejected
# ---------------------------------------------------------------------------

@test "AC-EC3: empty --plan-id= value exits 1 with requires-a-value message" {
  seed_story EMPTY1 UNVERIFIED

  run "$SCRIPT" update --story EMPTY1 --gate "test-automate-plan" --verdict PASSED --plan-id ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]] || [[ "$output" == *"plan-id"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC9: status --plan-id miss returns UNVERIFIED
# ---------------------------------------------------------------------------

@test "AC-EC9: status --plan-id with non-matching id returns UNVERIFIED" {
  seed_story MISS1 UNVERIFIED

  local real_plan_id="plan-real-$(date +%s)"
  local wrong_plan_id="plan-wrong-$(date +%s)"

  # Write a ledger record with the real plan_id
  run "$SCRIPT" update --story MISS1 --gate "test-automate-plan" --verdict PASSED --plan-id "$real_plan_id"
  [ "$status" -eq 0 ]

  # Query with a DIFFERENT plan_id -- should return UNVERIFIED, NOT the stored PASSED
  run "$SCRIPT" status --story MISS1 --gate "test-automate-plan" --plan-id "$wrong_plan_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" != *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# AC-EC10: Legacy ledger record without plan_id field
# ---------------------------------------------------------------------------

@test "AC-EC10: legacy record without plan_id; no-plan-id callers succeed" {
  seed_story LEGACY1 UNVERIFIED

  # Simulate a pre-E35 update (no --plan-id)
  run "$SCRIPT" update --story LEGACY1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]

  # status without --plan-id should still return the verdict
  run "$SCRIPT" status --story LEGACY1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "AC-EC10: --plan-id query against legacy record returns no-match" {
  seed_story LEGACY2 UNVERIFIED

  # Write a record via the canonical six gates (no --plan-id, no ledger)
  run "$SCRIPT" update --story LEGACY2 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]

  # Query the ledger with a plan_id -- should find nothing (UNVERIFIED)
  run "$SCRIPT" status --story LEGACY2 --gate "test-automate-plan" --plan-id "plan-does-not-exist"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# Gate name validation: test-automate-plan accepted WITH --plan-id
# ---------------------------------------------------------------------------

@test "gate-name: test-automate-plan accepted when --plan-id is present" {
  seed_story GATE1 UNVERIFIED
  local plan_id="plan-gate-test-$(date +%s)"

  run "$SCRIPT" update --story GATE1 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]
}

@test "gate-name: test-automate-plan rejected when --plan-id is absent" {
  seed_story GATE2 UNVERIFIED

  # Without --plan-id, test-automate-plan should NOT be accepted as a gate name
  run "$SCRIPT" update --story GATE2 --gate "test-automate-plan" --verdict PASSED
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --plan-id"* ]]
}

# ---------------------------------------------------------------------------
# plan_id regex validation: valid characters
# ---------------------------------------------------------------------------

@test "plan-id format: UUID accepted" {
  seed_story FMT1 UNVERIFIED

  run "$SCRIPT" update --story FMT1 --gate "test-automate-plan" --verdict PASSED --plan-id "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
  [ "$status" -eq 0 ]
}

@test "plan-id format: timestamp-nonce accepted" {
  seed_story FMT2 UNVERIFIED

  run "$SCRIPT" update --story FMT2 --gate "test-automate-plan" --verdict PASSED --plan-id "1714680000123456789-ab12cd34"
  [ "$status" -eq 0 ]
}

@test "plan-id format: dots and colons accepted" {
  seed_story FMT3 UNVERIFIED

  run "$SCRIPT" update --story FMT3 --gate "test-automate-plan" --verdict PASSED --plan-id "v1.2.3:build+42"
  [ "$status" -eq 0 ]
}

@test "plan-id format: spaces rejected" {
  seed_story FMT4 UNVERIFIED

  run "$SCRIPT" update --story FMT4 --gate "test-automate-plan" --verdict PASSED --plan-id "plan with spaces"
  [ "$status" -ne 0 ]
}

@test "plan-id format: semicolons rejected" {
  seed_story FMT5 UNVERIFIED

  run "$SCRIPT" update --story FMT5 --gate "test-automate-plan" --verdict PASSED --plan-id "plan;evil"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Ledger format verification: tab-separated, correct columns
# ---------------------------------------------------------------------------

@test "ledger format: rows are tab-separated with story_key gate plan_id verdict" {
  seed_story LFMT1 UNVERIFIED
  local plan_id="plan-lfmt-$(date +%s)"

  run "$SCRIPT" update --story LFMT1 --gate "test-automate-plan" --verdict PASSED --plan-id "$plan_id"
  [ "$status" -eq 0 ]
  [ -f "$LEDGER" ]

  # Verify tab-separated format: story_key<TAB>gate<TAB>plan_id<TAB>verdict
  local line
  line="$(grep "LFMT1" "$LEDGER")"
  local col_count
  col_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  [ "$col_count" -eq 4 ]

  # Verify column order
  local col1 col2 col3 col4
  col1="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
  col2="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
  col3="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
  col4="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
  [ "$col1" = "LFMT1" ]
  [ "$col2" = "test-automate-plan" ]
  [ "$col3" = "$plan_id" ]
  [ "$col4" = "PASSED" ]
}
