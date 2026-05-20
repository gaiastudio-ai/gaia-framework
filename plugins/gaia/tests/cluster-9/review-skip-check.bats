#!/usr/bin/env bats
# review-skip-check.bats — Cluster 9 unit test (E58-S1)
#
# Verifies the deterministic skip-already-PASSED filter:
#   review-skip-check.sh --story <key> [--force]
#
# Output contract (TC-RAR-01..03, ECI-667, ECI-669):
#   exit 0 — JSON {"skip":[...],"run":[...]} in canonical short-name order
#   exit 1 — story not found
#   exit 2 — malformed gate state (unknown verdict, zero rows, unknown flag)
#
# Refs: FR-RAR-1, AF-2026-04-28-7, ADR-054, ADR-050

load 'test_helper.bash'

# ---------- Paths ----------

CLUSTER9_DIR="${BATS_TEST_DIRNAME}"
FIXTURES_DIR="${CLUSTER9_DIR}/fixtures"
# Override SCRIPTS_DIR from test_helper (cluster-9 lives two levels deep)
SCRIPTS_DIR="$(cd "${BATS_TEST_DIRNAME}/../../scripts" && pwd)"

SKIP_CHECK="$SCRIPTS_DIR/review-skip-check.sh"
GATE="$SCRIPTS_DIR/review-gate.sh"

# Canonical short-name order from the story spec
CANONICAL_SHORT_NAMES='["code-review","qa-tests","security-review","test-automate","test-review","review-perf"]'

# ---------- Helpers ----------

setup() {
  common_setup
  TEST_PROJECT="$TEST_TMP"
  ART="$TEST_PROJECT/docs/implementation-artifacts"
  mkdir -p "$ART"
  export PROJECT_PATH="$TEST_PROJECT"
  # AF-2026-05-20-1: skip-check tests seed the gate via review-gate.sh
  # update with no report file. Disable the proof-of-execution gate so
  # the skip-check mechanics can be exercised. Proof-of-execution has
  # its own dedicated suite.
  export REVIEW_GATE_PROOF_OF_EXECUTION=off

  STORY_KEY="E58-S1-FIXTURE"
  STORY_FILE="$ART/${STORY_KEY}-fake.md"

  # Seed a fresh fixture story with all six rows UNVERIFIED.
  cp "$FIXTURES_DIR/C9-FIXTURE-fake.md" "$STORY_FILE"
  # Rename the key in frontmatter to match the test's STORY_KEY so
  # locate_story_file resolves correctly.
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

# Set a single gate's verdict via review-gate.sh update.
seed_gate() {
  local gate="$1" verdict="$2"
  "$GATE" update --story "$STORY_KEY" --gate "$gate" --verdict "$verdict" >/dev/null
}

# Seed all six gates to PASSED.
seed_all_passed() {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" PASSED
}

# Seed all six gates to FAILED.
seed_all_failed() {
  seed_gate "Code Review" FAILED
  seed_gate "QA Tests" FAILED
  seed_gate "Security Review" FAILED
  seed_gate "Test Automation" FAILED
  seed_gate "Test Review" FAILED
  seed_gate "Performance Review" FAILED
}

# ---------- Test 1: Happy path — 5 of 6 PASSED → 1 in run (TC-RAR-01) ----------

@test "happy path: 5 of 6 PASSED leaves 1 in run" {
  seed_gate "Code Review" PASSED
  seed_gate "QA Tests" PASSED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" PASSED
  seed_gate "Test Review" PASSED
  # Performance Review stays UNVERIFIED

  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  # Output is well-formed JSON
  echo "$output" | jq -e '.' >/dev/null

  # skip contains 5 entries in canonical short-name order
  local skip
  skip=$(echo "$output" | jq -c '.skip')
  [ "$skip" = '["code-review","qa-tests","security-review","test-automate","test-review"]' ]

  # run contains exactly the non-PASSED gate
  local run_list
  run_list=$(echo "$output" | jq -c '.run')
  [ "$run_list" = '["review-perf"]' ]
}

# ---------- Test 2: All FAILED → all 6 in run (TC-RAR-01) ----------

@test "all FAILED: skip empty, run all 6 in canonical order" {
  seed_all_failed

  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.skip == []' >/dev/null
  local run_list
  run_list=$(echo "$output" | jq -c '.run')
  [ "$run_list" = "$CANONICAL_SHORT_NAMES" ]
}

# ---------- Test 3: All UNVERIFIED → all 6 in run (TC-RAR-01) ----------

@test "all UNVERIFIED: skip empty, run all 6 in canonical order" {
  # No seeding — fixture is initialized to UNVERIFIED.
  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.skip == []' >/dev/null
  local run_list
  run_list=$(echo "$output" | jq -c '.run')
  [ "$run_list" = "$CANONICAL_SHORT_NAMES" ]
}

# ---------- Test 4: --force override (TC-RAR-02) ----------

@test "force override: all PASSED but --force runs all 6" {
  seed_all_passed

  run "$SKIP_CHECK" --story "$STORY_KEY" --force
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.skip == []' >/dev/null
  local run_list
  run_list=$(echo "$output" | jq -c '.run')
  [ "$run_list" = "$CANONICAL_SHORT_NAMES" ]
}

# ---------- Test 5: Missing story → exit 1 (TC-RAR-03) ----------

@test "missing story: exit 1 with stderr 'story not found'" {
  run "$SKIP_CHECK" --story "NONEXISTENT-S99"
  [ "$status" -eq 1 ]
  [[ "$output" == *"story not found"* ]]
}

# ---------- Test 6: Malformed verdict token → exit 2 (TC-RAR-03) ----------

@test "malformed verdict: lowercase 'passed' → exit 2" {
  # Inject a non-canonical verdict directly into the gate row.
  sed -i.bak 's/Code Review | UNVERIFIED/Code Review | passed/' "$STORY_FILE"
  rm -f "${STORY_FILE}.bak"

  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 2 ]
  # Stderr names the offending row (gate name or verdict token).
  [[ "$output" == *"Code Review"* ]] || [[ "$output" == *"passed"* ]] || [[ "$output" == *"malformed"* ]]
}

# ---------- Test 7: Zero-row gate table → exit 2 (ECI-667) ----------

@test "zero-row gate table: exit 2 with 'gate table empty'" {
  # Create a story file with the Review Gate header but zero data rows.
  local empty_story="$ART/E58-S1-EMPTYGATE-fake.md"
  cat > "$empty_story" <<'STORY'
---
template: 'story'
key: "E58-S1-EMPTYGATE"
status: review
---

# Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|

> Story moves to done only when ALL reviews show PASSED.
STORY

  run "$SKIP_CHECK" --story "E58-S1-EMPTYGATE"
  [ "$status" -eq 2 ]
  # Either upstream review-gate.sh reports the malformed table OR
  # review-skip-check.sh reports gate table empty — both are AC5 compliant.
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"fewer than six"* ]] || [[ "$output" == *"row"* ]]
}

# ---------- Test 8: Non-atomicity caveat documented in script header (ECI-669) ----------

@test "non-atomicity caveat: header comment documents the contract" {
  # Inspect the script header — the caveat MUST be present.
  run grep -i "non-atomic\|verdict overwrite is safe\|best-effort skip" "$SKIP_CHECK"
  [ "$status" -eq 0 ]
}

# ---------- Test 9: Unknown flag → exit 2 with usage ----------

@test "unknown flag: exit 2 with usage to stderr" {
  run "$SKIP_CHECK" --story "$STORY_KEY" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]] || [[ "$output" == *"unknown"* ]]
}

# ---------- Test 10: Mixed state — 3 PASSED, 2 FAILED, 1 UNVERIFIED ----------

@test "mixed state: 3 PASSED in skip, 3 non-PASSED in run, canonical order preserved" {
  seed_gate "Code Review" PASSED
  # QA Tests stays UNVERIFIED
  seed_gate "Security Review" PASSED
  seed_gate "Test Automation" FAILED
  seed_gate "Test Review" PASSED
  seed_gate "Performance Review" FAILED

  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  local skip
  skip=$(echo "$output" | jq -c '.skip')
  [ "$skip" = '["code-review","security-review","test-review"]' ]

  local run_list
  run_list=$(echo "$output" | jq -c '.run')
  [ "$run_list" = '["qa-tests","test-automate","review-perf"]' ]
}

# ---------- Test 11: JSON shape is single-line and well-formed ----------

@test "JSON output: single-line and matches schema" {
  seed_all_passed

  run "$SKIP_CHECK" --story "$STORY_KEY"
  [ "$status" -eq 0 ]

  # Single line of stdout
  local line_count
  line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$line_count" -eq 1 ]

  # Has exactly the two top-level keys
  echo "$output" | jq -e 'keys == ["run","skip"]' >/dev/null
}
