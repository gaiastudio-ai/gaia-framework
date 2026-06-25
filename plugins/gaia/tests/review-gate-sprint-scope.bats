#!/usr/bin/env bats
# review-gate-sprint-scope.bats — sprint-scoped gate operations
#
# Surfaces tested: --sprint flag on update/status, sprint-review gate
# acceptance, resolve_ledger_path for sprint-scoped invocations.
#
# Public functions exercised:
#   main (--sprint flag parser), cmd_update (sprint-scoped ledger write),
#   cmd_status (sprint-scoped ledger read), is_plan_id_gate
#   (sprint-review acceptance), resolve_ledger_path (sprint path resolution)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  export PROJECT_PATH="$TEST_TMP"

  # Seed a .gaia tree so resolve_ledger_path takes the canonical branch.
  mkdir -p "$TEST_TMP/.gaia/state"

  # Sprint-scoped operations are ledger-only; no story file is needed.
  # Disable proof-of-execution — these tests exercise verdict mechanics,
  # not proof-of-execution.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  # Do NOT set REVIEW_GATE_LEDGER — let resolve_ledger_path derive
  # the canonical path from PROJECT_PATH so we can verify it resolves
  # correctly.
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Sprint-review update accepted and recorded in canonical ledger (AC1)
# ---------------------------------------------------------------------------

@test "sprint-review update writes to canonical ledger and exits 0 (AC1)" {
  run "$SCRIPT" update --sprint sprint-99 --gate sprint-review \
    --verdict PASSED --plan-id sprint-review-sprint-99

  [ "$status" -eq 0 ]

  # The canonical ledger must exist and contain the row.
  local ledger="$TEST_TMP/.gaia/state/.review-gate-ledger"
  [ -f "$ledger" ]
  grep -q "sprint:sprint-99" "$ledger"
  grep -q "sprint-review" "$ledger"
  grep -q "PASSED" "$ledger"
}

# ---------------------------------------------------------------------------
# Sprint-review status reads back PASSED from canonical ledger (AC2)
# ---------------------------------------------------------------------------

@test "sprint-review status reads back PASSED from canonical ledger (AC2)" {
  # Write a sprint-review row directly to the canonical ledger.
  local ledger="$TEST_TMP/.gaia/state/.review-gate-ledger"
  printf 'sprint:sprint-99\tsprint-review\tsprint-review-sprint-99\tPASSED\n' \
    > "$ledger"

  run "$SCRIPT" status --sprint sprint-99 --gate sprint-review \
    --plan-id sprint-review-sprint-99

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
  # Must NOT return UNVERIFIED.
  [[ "$output" != *"UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# resolve_ledger_path for sprint-scoped calls returns canonical path (AC3)
# ---------------------------------------------------------------------------

@test "sprint-scoped invocation resolves canonical ledger, not a literal marker (AC3)" {
  # Perform a sprint-scoped update, then verify NO file named
  # "story-validation" was created anywhere under TEST_TMP or CWD.
  run "$SCRIPT" update --sprint sprint-42 --gate sprint-review \
    --verdict PASSED --plan-id sprint-review-sprint-42

  [ "$status" -eq 0 ]

  # The canonical ledger must exist.
  [ -f "$TEST_TMP/.gaia/state/.review-gate-ledger" ]

  # A file literally named "story-validation" must NOT exist.
  [ ! -f "$TEST_TMP/story-validation" ]
  [ ! -f "story-validation" ]
}

# ---------------------------------------------------------------------------
# Explicit --ledger override still works for sprint-scoped ops
# ---------------------------------------------------------------------------

@test "explicit --ledger override preserved for sprint-scoped ops (AC3)" {
  local custom_ledger="$TEST_TMP/custom-ledger"

  run "$SCRIPT" update --sprint sprint-77 --gate sprint-review \
    --verdict PASSED --plan-id sprint-review-sprint-77 \
    --ledger "$custom_ledger"

  [ "$status" -eq 0 ]
  [ -f "$custom_ledger" ]
  grep -q "sprint:sprint-77" "$custom_ledger"

  # The canonical ledger must NOT be written when --ledger overrides.
  [ ! -f "$TEST_TMP/.gaia/state/.review-gate-ledger" ]
}

# ---------------------------------------------------------------------------
# Existing story-scoped gates still work (regression guard — AC5)
# ---------------------------------------------------------------------------

@test "story-scoped update still works after sprint-review registration (AC5)" {
  # Seed a story file for story-scoped operations.
  local art="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$art"
  cat > "$art/REG1-fake.md" <<'STORY'
---
template: 'story'
key: "REG1"
---

# Story: Regression guard

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY

  run "$SCRIPT" update --story REG1 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]
  grep -q 'Code Review | PASSED' "$art/REG1-fake.md"
}

# ---------------------------------------------------------------------------
# story-validation ledger gate still works (regression guard — AC5)
# ---------------------------------------------------------------------------

@test "story-validation gate still routes to canonical ledger (AC5)" {
  # Seed a story file.
  local art="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$art"
  cat > "$art/REG2-fake.md" <<'STORY'
---
template: 'story'
key: "REG2"
---

# Story: Regression guard 2

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |
STORY

  run "$SCRIPT" update --story REG2 --gate story-validation \
    --verdict PASSED --plan-id val-REG2

  [ "$status" -eq 0 ]

  local ledger="$TEST_TMP/.gaia/state/.review-gate-ledger"
  [ -f "$ledger" ]
  grep -q "REG2" "$ledger"
  grep -q "story-validation" "$ledger"
  grep -q "PASSED" "$ledger"
}

# ---------------------------------------------------------------------------
# Sprint-scoped update with auto-generated plan-id (AC1)
# ---------------------------------------------------------------------------

@test "sprint-scoped update auto-generates plan-id when omitted (AC1)" {
  run "$SCRIPT" update --sprint sprint-55 --gate sprint-review \
    --verdict PASSED

  [ "$status" -eq 0 ]

  local ledger="$TEST_TMP/.gaia/state/.review-gate-ledger"
  [ -f "$ledger" ]
  # Auto-generated plan-id should be "<gate>-<sprint-id>"
  grep -q "sprint-review-sprint-55" "$ledger"
}
