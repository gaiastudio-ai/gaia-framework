#!/usr/bin/env bats
# review-gate.bats — unit tests for plugins/gaia/scripts/review-gate.sh
# Public functions covered: is_canonical_gate, is_canonical_verdict,
# join_by, locate_story_file, parse_gate_rows, load_canonical_rows,
# cmd_status, cmd_check, cmd_update, main. (join_by is the internal
# string-join helper exercised end-to-end by the status/check subcommand
# tests that emit a comma-separated list of gate verdicts.)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  export PROJECT_PATH="$TEST_TMP"
  # AF-2026-05-20-1: this suite probes verdict-write mechanics, not the
  # proof-of-execution contract. Disable the proof-of-execution gate so
  # the existing fixtures (which don't dispatch real review skills) still
  # exercise the rewrite/idempotency paths. The proof-of-execution contract
  # has its own dedicated suite at tests/review-gate-proof-of-execution.bats.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  # Flat implementation-artifacts layout (per 2de74a4 — review-gate.sh
  # locates stories via {IMPLEMENTATION_ARTIFACTS}/<key>-*.md, no stories/
  # subdirectory).
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"
}
teardown() { common_teardown; }

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
| Code Review | $verdict | — |
| QA Tests | $verdict | — |
| Security Review | $verdict | — |
| Test Automation | $verdict | — |
| Test Review | $verdict | — |
| Performance Review | $verdict | — |
EOF
}

@test "review-gate.sh: --help exits 0 and lists subcommands" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"check"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"status"* ]]
}

@test "review-gate.sh: check — all PASSED returns 0" {
  seed_story R1 PASSED
  run "$SCRIPT" check --story R1
  [ "$status" -eq 0 ]
}

@test "review-gate.sh: check — any UNVERIFIED returns non-zero" {
  seed_story R2 UNVERIFIED
  run "$SCRIPT" check --story R2
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: check — any FAILED returns non-zero" {
  seed_story R3 PASSED
  sed -i.bak 's/Code Review | PASSED/Code Review | FAILED/' "$ART/R3-fake.md"
  rm -f "$ART/R3-fake.md.bak"
  run "$SCRIPT" check --story R3
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: update rewrites a single row" {
  seed_story R4 UNVERIFIED
  run "$SCRIPT" update --story R4 --gate "Code Review" --verdict PASSED
  [ "$status" -eq 0 ]
  grep -q 'Code Review | PASSED' "$ART/R4-fake.md"
  grep -q 'QA Tests | UNVERIFIED' "$ART/R4-fake.md"
}

@test "review-gate.sh: update rejects unknown gate name" {
  seed_story R5 UNVERIFIED
  run "$SCRIPT" update --story R5 --gate "Bogus Gate" --verdict PASSED
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: update rejects non-canonical verdict" {
  seed_story R6 UNVERIFIED
  run "$SCRIPT" update --story R6 --gate "Code Review" --verdict approve
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: status emits JSON summary when jq available" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  seed_story R7 PASSED
  run "$SCRIPT" status --story R7
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
}

@test "review-gate.sh: zero-match story key → non-zero" {
  run "$SCRIPT" check --story NOPE-S999
  [ "$status" -ne 0 ]
}

@test "review-gate.sh: update idempotent — second identical update exits 0" {
  seed_story R8 UNVERIFIED
  "$SCRIPT" update --story R8 --gate "QA Tests" --verdict PASSED
  run "$SCRIPT" update --story R8 --gate "QA Tests" --verdict PASSED
  [ "$status" -eq 0 ]
  [ "$(grep -c 'QA Tests | PASSED' "$ART/R8-fake.md")" = "1" ]
}

# ---------------------------------------------------------------------------
# E37-S1 — review-gate-check sub-operation
#
# Composite Review Gate check: emits COMPLETE/BLOCKED/PENDING summary and
# deterministic exit codes (0/1/2). Read-only, additive to existing
# check/update/status sub-operations. Fixtures mirror ADR-054 semantics:
#   - all-PASSED  → exit 0 / COMPLETE
#   - one-FAILED  → exit 1 / BLOCKED (FAILED dominates over PENDING)
#   - mixed-pending (UNVERIFIED/NOT STARTED, no FAILED) → exit 2 / PENDING
# ---------------------------------------------------------------------------

# Seed a story with explicit per-gate verdicts. Order is fixed: Code Review,
# QA Tests, Security Review, Test Automation, Test Review, Performance Review.
seed_story_mixed() {
  local key="$1" v1="$2" v2="$3" v3="$4" v4="$5" v5="$6" v6="$7"
  cat > "$ART/${key}-fake.md" <<EOF
---
template: 'story'
key: "$key"
---

# Story: Fake

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $v1 | — |
| QA Tests | $v2 | — |
| Security Review | $v3 | — |
| Test Automation | $v4 | — |
| Test Review | $v5 | — |
| Performance Review | $v6 | — |

## Tail
EOF
}

@test "review-gate-check: AC1 — all PASSED → exit 0, COMPLETE, table present" {
  seed_story_mixed CRG1 PASSED PASSED PASSED PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG1
  [ "$status" -eq 0 ]
  [[ "$output" == *"| Review | Status | Report |"* ]]
  [[ "$output" == *"Code Review"* ]]
  [[ "$output" == *"Performance Review"* ]]
  [[ "$output" == *"Review Gate: COMPLETE"* ]]
  [[ "$output" != *"Blocking gates:"* ]]
  [[ "$output" != *"Pending gates:"* ]]
}

@test "review-gate-check: AC2 — any FAILED → exit 1, BLOCKED, Blocking gates list" {
  seed_story_mixed CRG2 PASSED FAILED PASSED PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate: BLOCKED"* ]]
  [[ "$output" == *"Blocking gates:"* ]]
  [[ "$output" == *"QA Tests"* ]]
}

@test "review-gate-check: AC2 — FAILED dominates over PENDING → exit 1 BLOCKED" {
  # 4 PASSED + 1 FAILED + 1 NOT STARTED — FAILED wins over PENDING per ADR-054.
  seed_story_mixed CRG2B PASSED PASSED PASSED FAILED PASSED "NOT STARTED"
  run "$SCRIPT" review-gate-check --story CRG2B
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate: BLOCKED"* ]]
  [[ "$output" == *"Blocking gates:"* ]]
  [[ "$output" == *"Test Automation"* ]]
  # The pending row must NOT appear as a pending-list item when BLOCKED.
  [[ "$output" != *"Pending gates:"* ]]
}

@test "review-gate-check: AC3 — UNVERIFIED (no FAILED) → exit 2 PENDING, Pending gates list" {
  seed_story_mixed CRG3 UNVERIFIED PASSED PASSED PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG3
  [ "$status" -eq 2 ]
  [[ "$output" == *"Review Gate: PENDING"* ]]
  [[ "$output" == *"Pending gates:"* ]]
  [[ "$output" == *"Code Review"* ]]
  [[ "$output" != *"Blocking gates:"* ]]
}

@test "review-gate-check: AC3 — NOT STARTED treated as PENDING" {
  seed_story_mixed CRG3B PASSED PASSED "NOT STARTED" PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG3B
  [ "$status" -eq 2 ]
  [[ "$output" == *"Review Gate: PENDING"* ]]
  [[ "$output" == *"Pending gates:"* ]]
  [[ "$output" == *"Security Review"* ]]
}

@test "review-gate-check: AC3 — mixed UNVERIFIED + NOT STARTED → PENDING lists both" {
  seed_story_mixed CRG3C PASSED UNVERIFIED "NOT STARTED" PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG3C
  [ "$status" -eq 2 ]
  [[ "$output" == *"Review Gate: PENDING"* ]]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"Security Review"* ]]
}

@test "review-gate-check: AC4 — sequence of 3 fixtures yields 0/1/2 deterministically" {
  seed_story_mixed CRG4A PASSED PASSED PASSED PASSED PASSED PASSED
  seed_story_mixed CRG4B PASSED FAILED PASSED PASSED PASSED PASSED
  seed_story_mixed CRG4C PASSED PASSED UNVERIFIED PASSED PASSED PASSED

  run "$SCRIPT" review-gate-check --story CRG4A
  [ "$status" -eq 0 ]

  run "$SCRIPT" review-gate-check --story CRG4B
  [ "$status" -eq 1 ]

  run "$SCRIPT" review-gate-check --story CRG4C
  [ "$status" -eq 2 ]
}

@test "review-gate-check: AC4 — stderr is empty on COMPLETE path" {
  seed_story_mixed CRG4D PASSED PASSED PASSED PASSED PASSED PASSED
  local errfile="$TEST_TMP/crg4d.err"
  run bash -c "'$SCRIPT' review-gate-check --story CRG4D 2>'$errfile'"
  [ "$status" -eq 0 ]
  [ ! -s "$errfile" ]
}

@test "review-gate-check: AC4 — stderr is empty on BLOCKED path" {
  seed_story_mixed CRG4E PASSED FAILED PASSED PASSED PASSED PASSED
  local errfile="$TEST_TMP/crg4e.err"
  run bash -c "'$SCRIPT' review-gate-check --story CRG4E 2>'$errfile'"
  [ "$status" -eq 1 ]
  [ ! -s "$errfile" ]
}

@test "review-gate-check: AC4 — stderr is empty on PENDING path" {
  seed_story_mixed CRG4F PASSED PASSED UNVERIFIED PASSED PASSED PASSED
  local errfile="$TEST_TMP/crg4f.err"
  run bash -c "'$SCRIPT' review-gate-check --story CRG4F 2>'$errfile'"
  [ "$status" -eq 2 ]
  [ ! -s "$errfile" ]
}

@test "review-gate-check: AC6 — read-only invariant, story file shasum unchanged" {
  seed_story_mixed CRG6 PASSED PASSED PASSED PASSED PASSED PASSED
  local before after
  before=$(shasum -a 256 "$ART/CRG6-fake.md" | awk '{print $1}')
  run "$SCRIPT" review-gate-check --story CRG6
  [ "$status" -eq 0 ]
  after=$(shasum -a 256 "$ART/CRG6-fake.md" | awk '{print $1}')
  [ "$before" = "$after" ]
}

@test "review-gate-check: AC6 — no new files created alongside story" {
  seed_story_mixed CRG6B PASSED FAILED PASSED PASSED PASSED PASSED
  local before_count
  before_count=$(find "$ART" -type f | wc -l)
  run "$SCRIPT" review-gate-check --story CRG6B
  [ "$status" -eq 1 ]
  local after_count
  after_count=$(find "$ART" -type f | wc -l)
  [ "$before_count" = "$after_count" ]
}

@test "review-gate-check: TC-CRG-7 — idempotent reruns yield identical stdout + exit" {
  seed_story_mixed CRG7 PASSED PASSED UNVERIFIED PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story CRG7
  local status1="$status" output1="$output"
  run "$SCRIPT" review-gate-check --story CRG7
  [ "$status" = "$status1" ]
  [ "$output" = "$output1" ]
}

@test "review-gate-check: --help mentions review-gate-check" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-gate-check"* ]]
  [[ "$output" == *"COMPLETE"* ]]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PENDING"* ]]
}

@test "review-gate-check: missing story key → non-zero with stderr" {
  local errfile="$TEST_TMP/missing.err"
  run bash -c "'$SCRIPT' review-gate-check --story NOPE-S999 2>'$errfile'"
  [ "$status" -ne 0 ]
  [ -s "$errfile" ]
}

# NFR-052 unit tests for new public functions ----------------------------------
#
# Covered public functions (review-gate.sh):
#   - classify_review_gate — pure ADR-054 dominance classifier
#   - cmd_review_gate_check — the review-gate-check sub-operation entry point
#
# Tests target classify_review_gate and cmd_review_gate_check by invoking
# the sub-operation with hand-crafted fixtures that isolate each verdict
# branch.

@test "nfr-052: classify_review_gate — all-PASSED classifies as COMPLETE via cmd_review_gate_check" {
  seed_story_mixed NFR1 PASSED PASSED PASSED PASSED PASSED PASSED
  run "$SCRIPT" review-gate-check --story NFR1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate: COMPLETE"* ]]
}

@test "nfr-052: classify_review_gate — single FAILED classifies as BLOCKED via cmd_review_gate_check" {
  seed_story_mixed NFR2 PASSED PASSED PASSED PASSED FAILED PASSED
  run "$SCRIPT" review-gate-check --story NFR2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate: BLOCKED"* ]]
}

@test "nfr-052: classify_review_gate — only UNVERIFIED classifies as PENDING via cmd_review_gate_check" {
  seed_story_mixed NFR3 UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED
  run "$SCRIPT" review-gate-check --story NFR3
  [ "$status" -eq 2 ]
  [[ "$output" == *"Review Gate: PENDING"* ]]
}

@test "nfr-052: cmd_review_gate_check — all six PENDING gates listed in Pending gates" {
  seed_story_mixed NFR4 UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED UNVERIFIED
  run "$SCRIPT" review-gate-check --story NFR4
  [ "$status" -eq 2 ]
  [[ "$output" == *"Code Review"* ]]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"Security Review"* ]]
  [[ "$output" == *"Test Automation"* ]]
  [[ "$output" == *"Test Review"* ]]
  [[ "$output" == *"Performance Review"* ]]
}

# Direct unit tests for classify_review_gate extracted via awk (same
# pattern as e35-s2-approval-gate-units.bats for NFR-052 coverage).
# Extracts only the classify_review_gate definition and re-runs it in
# the test subshell, bypassing the dispatcher.

_load_classify_helper() {
  eval "$(awk '
    /^classify_review_gate[[:space:]]*\(\)/ { printing = 1 }
    printing { print }
    printing && /^}/ { printing = 0; exit }
  ' "$SCRIPT")"
}

@test "nfr-052: classify_review_gate — extracted helper returns BLOCKED for any FAILED" {
  _load_classify_helper
  run classify_review_gate PASSED PASSED FAILED PASSED PASSED PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}

@test "nfr-052: classify_review_gate — extracted helper returns PENDING for UNVERIFIED no FAILED" {
  _load_classify_helper
  run classify_review_gate PASSED PASSED UNVERIFIED PASSED PASSED PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "PENDING" ]
}

@test "nfr-052: classify_review_gate — extracted helper returns COMPLETE when all PASSED" {
  _load_classify_helper
  run classify_review_gate PASSED PASSED PASSED PASSED PASSED PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "COMPLETE" ]
}

@test "nfr-052: classify_review_gate — extracted helper treats NOT STARTED as PENDING" {
  _load_classify_helper
  run classify_review_gate PASSED PASSED PASSED PASSED PASSED "NOT STARTED"
  [ "$status" -eq 0 ]
  [ "$output" = "PENDING" ]
}

@test "nfr-052: classify_review_gate — extracted helper FAILED dominates over PENDING" {
  _load_classify_helper
  run classify_review_gate PASSED UNVERIFIED FAILED PASSED "NOT STARTED" PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKED" ]
}
