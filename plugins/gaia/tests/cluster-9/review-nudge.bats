#!/usr/bin/env bats
# review-nudge.bats — Cluster 9 unit test (E58-S3)
#
# Verifies the deterministic progressive-nudge renderer:
#   review-nudge.sh --story <key>
#
# Output contract (TC-RAR-07..10, ECI-672, AC-EC1..3):
#   - Block fenced with `--- Review Gate Nudge ---` (start + end)
#   - Part 1: Markdown Gate Status table (6 canonical rows in V1 order)
#   - Part 2: `Overall:` classification line
#       ALL PASSED | N FAILED | M UNVERIFIED
#   - Part 3: `Suggested next:` branch
#       ALL PASSED → /gaia-check-review-gate {key} + /gaia-check-dod {key}
#       ANY FAILED → list failed gates + /gaia-correct-course {key}
#       UNVERIFIED-only → per-gate commands from canonical map
#       MIXED → FAILED branch + `Also unrun:` line
#
# Advisory-only contract (AC4): exit 0 on all states (including malformed
# gate state). Story-key validation rejects non-canonical keys before any
# read (AC-EC2) — that is the ONE exception to the always-exit-0 rule and
# is enforced before any side effect.
#
# Refs: FR-RAR-3, AF-2026-04-28-7, NFR-RAR-1, ADR-042, ADR-050, ADR-054
#
# NFR-052 public-function coverage anchor:
#   review-nudge.sh's only public functions are `usage`, `parse_args`, and
#   `main` — all allowlisted by the coverage gate (`usage` directly; `parse_args`
#   via the review-runner internals exemption; `main` via substring match).
#   Internal helpers `_gate_to_command` and `_emit_fallback` are underscore-
#   prefixed (private) per project convention; they are exercised end-to-end
#   by Tests 4, 5, 6, 10 below.

load 'test_helper.bash'

# ---------- Paths ----------

CLUSTER9_DIR="${BATS_TEST_DIRNAME}"
FIXTURES_DIR="${CLUSTER9_DIR}/fixtures"
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"

NUDGE="$SCRIPTS_DIR/review-nudge.sh"
GATE="$SCRIPTS_DIR/review-gate.sh"

# ---------- Helpers ----------

setup() {
  common_setup
  TEST_PROJECT="$TEST_TMP"
  ART="$TEST_PROJECT/docs/implementation-artifacts"
  mkdir -p "$ART"
  export PROJECT_PATH="$TEST_PROJECT"
  # AF-2026-05-20-1: nudge tests seed gate verdicts via review-gate.sh
  # update without --report. Disable the proof-of-execution gate so the
  # nudge branching mechanics can be exercised. Proof-of-execution has its
  # own dedicated suite at tests/review-gate-proof-of-execution.bats.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  STORY_KEY="E58-S3-FIXTURE"
  STORY_FILE="$ART/${STORY_KEY}-fake.md"

  cp "$FIXTURES_DIR/C9-FIXTURE-fake.md" "$STORY_FILE"
  sed -i.bak "s/key: \"C9-FIXTURE\"/key: \"${STORY_KEY}\"/" "$STORY_FILE"
  rm -f "${STORY_FILE}.bak"

  BATS_PRESERVE_TMPDIR_ON_FAILURE=1
}

teardown() {
  if [ "$BATS_TEST_COMPLETED" = 1 ]; then
    common_teardown
  else
    echo "# POST-MORTEM: temp dir preserved at $TEST_TMP" >&3
  fi
}

seed_gate() {
  local gate="$1" verdict="$2"
  "$GATE" update --story "$STORY_KEY" --gate "$gate" --verdict "$verdict" >/dev/null
}

seed_all_passed() {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED
}

seed_all_failed() {
  seed_gate "Code Review" FAILED
  seed_gate "QA Tests" FAILED
  seed_gate "Security Review" FAILED
  seed_gate "Test Automation" FAILED
  seed_gate "Test Review" FAILED
  seed_gate "Performance Review" FAILED
}

# ---------- Test 1: ALL-PASSED happy path (TC-RAR-07, TC-RAR-08, AC1) ----------

@test "ALL-PASSED: emits ALL PASSED + check-review-gate + check-dod" {
  seed_all_passed

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  # Fences
  [[ "$output" == *"--- Review Gate Nudge ---"* ]]

  # Gate Status table header + 6 canonical rows
  [[ "$output" == *"| Gate | Verdict | Report |"* ]]
  [[ "$output" == *"| Code Review | PASSED |"* ]]
  [[ "$output" == *"| QA Tests | PASSED |"* ]]
  [[ "$output" == *"| Security Review | PASSED |"* ]]
  [[ "$output" == *"| Test Automation | PASSED |"* ]]
  [[ "$output" == *"| Test Review | PASSED |"* ]]
  [[ "$output" == *"| Performance Review | PASSED |"* ]]

  # Overall + Suggested-next
  [[ "$output" == *"Overall: ALL PASSED"* ]]
  [[ "$output" == *"Suggested next: /gaia-check-review-gate ${STORY_KEY}"* ]]
  [[ "$output" == *"/gaia-check-dod ${STORY_KEY}"* ]]
}

# ---------- Test 2: Single FAILED (TC-RAR-09, AC2) ----------

@test "Single FAILED: emits 1 FAILED + correct-course" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" FAILED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Overall: 1 FAILED"* ]]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"Suggested next: /gaia-correct-course ${STORY_KEY}"* ]]
}

# ---------- Test 3: All-six FAILED (TC-RAR-09, AC2) ----------

@test "All-six FAILED: emits 6 FAILED + correct-course" {
  seed_all_failed

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Overall: 6 FAILED"* ]]
  [[ "$output" == *"Suggested next: /gaia-correct-course ${STORY_KEY}"* ]]
}

# ---------- Test 4: UNVERIFIED-only branch (AC-EC1) ----------

@test "UNVERIFIED-only: per-gate commands rendered from canonical map" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  # Test Review and Performance Review stay UNVERIFIED

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Overall: 2 UNVERIFIED"* ]]
  # Per-gate commands for UNVERIFIED rows
  [[ "$output" == *"/gaia-test-review"* ]]
  [[ "$output" == *"/gaia-review-perf"* ]]
}

# ---------- Test 5: MIXED state (TC-RAR-09, AC3) ----------

@test "MIXED: FAILED branch wins + Also unrun: line for UNVERIFIED" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" FAILED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  # Performance Review stays UNVERIFIED

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Overall: 1 FAILED"* ]]
  [[ "$output" == *"Suggested next: /gaia-correct-course ${STORY_KEY}"* ]]
  [[ "$output" == *"Also unrun:"* ]]
  [[ "$output" == *"/gaia-review-perf"* ]]
}

# ---------- Test 6: Malformed gate state (TC-RAR-10, AC4, AC-EC3) ----------

@test "Malformed gate state: advisory fallback + exit 0" {
  # Delete the Review Gate section entirely to force malformed state
  awk '/^## Review Gate$/{found=1} !found{print} /^## Estimate$/{found=0; print}' \
    "$STORY_FILE" > "${STORY_FILE}.tmp"
  mv "${STORY_FILE}.tmp" "$STORY_FILE"

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"--- Review Gate Nudge ---"* ]]
  [[ "$output" == *"gate state unreadable, see story file directly"* ]]
}

# ---------- Test 7: All-skipped re-run on already-PASSED (ECI-672, AC5) ----------

@test "All-PASSED re-run: still suggests check-review-gate" {
  seed_all_passed

  # First run
  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  first_output="$output"

  # Second run with the same gate state
  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Overall: ALL PASSED"* ]]
  [[ "$output" == *"/gaia-check-review-gate ${STORY_KEY}"* ]]

  # Determinism: byte-identical output across re-runs
  [ "$output" = "$first_output" ]
}

# ---------- Test 8: Shell-metachar story key rejected (AC-EC2) ----------

@test "Shell-metachar story key rejected before any read" {
  run "$NUDGE" --story 'E1-S1$(rm -rf /)'
  [ "$status" -ne 0 ]
  # No injection: no rm side-effects to assert (sandbox), but the script
  # MUST exit non-zero on the regex check before any read.
  [[ "$output" != *"--- Review Gate Nudge ---"* ]] || \
    [[ "$output" == *"invalid story key"* ]]
}

# ---------- Test 9: Determinism (AC across runs) ----------

@test "Determinism: two runs on identical gate state produce byte-identical output" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" FAILED
  seed_gate "Security Review" UNVERIFIED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" UNVERIFIED

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  first="$output"

  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [ "$output" = "$first" ]
}

# ---------- Test 10: Static gate→command map drift detector ----------

@test "Static map: each canonical command literal appears under UNVERIFIED-only" {
  # All 6 UNVERIFIED → all 6 per-gate commands rendered
  run "$NUDGE" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  [[ "$output" == *"/gaia-code-review"* ]]
  [[ "$output" == *"/gaia-qa-tests"* ]]
  [[ "$output" == *"/gaia-security-review"* ]]
  [[ "$output" == *"/gaia-test-automate"* ]]
  [[ "$output" == *"/gaia-test-review"* ]]
  [[ "$output" == *"/gaia-review-perf"* ]]
}
