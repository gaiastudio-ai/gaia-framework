#!/usr/bin/env bats
# advisory-manual-test-gate.bats — advisory manual-test review gate (AC1+AC2)
#
# Verifies the advisory 7th review gate for manual testing:
#   AC1 — manual-test verdict lives on the extended ledger tier, EXCLUDED
#          from the canonical blocking composite (six-gate set UNMODIFIED).
#   AC2 — advisory manual-test FAILED surfaces a WARNING, does NOT block
#          review->done; opt-in gating mode blocks on FAILED.

load 'test_helper.bash'

# ---------- Paths ----------

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  common_setup
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT="$SCRIPTS_DIR/review-gate.sh"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"
  mkdir -p "$TEST_TMP/.gaia/state"
  mkdir -p "$TEST_TMP/.gaia/config"

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export REVIEW_GATE_LEDGER="$TEST_TMP/.gaia/state/.review-gate-ledger"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}

teardown() { common_teardown; }

# seed a story with all six canonical gates at a given verdict + optional
# manual_verification frontmatter flag
seed_story() {
  local key="$1" verdict="${2:-UNVERIFIED}" manual_flag="${3:-}"
  local fm_extra=""
  if [ -n "$manual_flag" ]; then
    fm_extra="manual_verification: $manual_flag"
  fi
  cat > "$ART/${key}-fixture.md" <<EOF
---
template: 'story'
key: "$key"
title: "Advisory gate fixture"
epic: "ADV"
status: review
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
${fm_extra}
---

# Story: Advisory gate fixture

> **Status:** review

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $verdict | -- |
| QA Tests | $verdict | -- |
| Security Review | $verdict | -- |
| Test Automation | $verdict | -- |
| Test Review | $verdict | -- |
| Performance Review | $verdict | -- |
EOF
}

# seed supporting files for transition-story-status
seed_transition_env() {
  local key="$1"
  cat > "$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml" <<EOF
sprint_id: "fixture-sprint"
stories:
  - key: $key
    status: "review"
EOF
  cat > "$TEST_TMP/docs/planning-artifacts/epics-and-stories.md" <<EOF
# Epics and Stories

## Epic ADV — Advisory gate test

### Story ${key}: Advisory gate fixture

- **Epic:** ADV
- **Status:** review
EOF
  cat > "$TEST_TMP/docs/implementation-artifacts/story-index.yaml" <<EOF
last_updated: "2026-01-01T00:00:00Z"
stories:
  ${key}:
    title: "Advisory gate fixture"
    epic: "ADV"
    status: "review"
    sprint_id: "fixture-sprint"
EOF
  export SPRINT_STATUS_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  export EPICS_AND_STORIES="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  export STORY_INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  export STORY_STATUS_LOCK="$TEST_TMP/_memory/.story-status.lock"
}

# =====================================================================
# AC1: manual-test on the extended ledger tier
# =====================================================================

@test "manual-test update writes to ledger, not to the markdown table" {
  seed_story MG01 PASSED
  run bash "$SCRIPT" update --story MG01 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-run-001"
  [ "$status" -eq 0 ]

  # Ledger must contain the verdict
  assert_file_contains "$REVIEW_GATE_LEDGER" "manual-test"
  assert_file_contains "$REVIEW_GATE_LEDGER" "FAILED"

  # Story file markdown table must NOT contain manual-test
  assert_file_excludes "$ART/MG01-fixture.md" "manual-test"
}

@test "review-gate-check stays COMPLETE with manual-test FAILED in ledger" {
  seed_story MG02 PASSED
  # Record a FAILED manual-test verdict on the ledger
  bash "$SCRIPT" update --story MG02 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-run-002"
  # Composite check must still be COMPLETE (exit 0) — six canonical gates all PASSED
  run bash "$SCRIPT" review-gate-check --story MG02
  [ "$status" -eq 0 ]
}

@test "CANONICAL_GATES has exactly 6 entries (regression guard)" {
  # Extract the CANONICAL_GATES array from review-gate.sh and count entries
  local count
  count=$(awk '
    /^CANONICAL_GATES=\(/ { in_arr=1; next }
    in_arr && /^\)/ { exit }
    in_arr && /^[[:space:]]*"/ { n++ }
    END { print n+0 }
  ' "$SCRIPT")
  [ "$count" -eq 6 ]
}

@test "manual-test gate requires --plan-id" {
  seed_story MG03 PASSED
  run bash "$SCRIPT" update --story MG03 --gate "manual-test" --verdict PASSED
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --plan-id"* ]]
}

@test "status returns ledger verdict for manual-test gate" {
  seed_story MG04 PASSED
  bash "$SCRIPT" update --story MG04 --gate "manual-test" \
    --verdict PASSED --plan-id "mt-run-004"
  run bash "$SCRIPT" status --story MG04 --gate "manual-test" --plan-id "mt-run-004"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"plan_id":"mt-run-004"'* ]]
  [[ "$output" == *'"verdict":"PASSED"'* ]]
}

# =====================================================================
# AC2: advisory FAILED -> WARNING, not blocked
# =====================================================================

@test "manual_verification:true + six PASSED + manual-test FAILED -> transition exit 0 + stderr WARNING" {
  seed_story MG05 PASSED "true"
  seed_transition_env MG05
  # Record FAILED manual-test in ledger
  bash "$SCRIPT" update --story MG05 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-run-005"
  # Transition review->done must succeed (exit 0) but emit WARNING
  run bash "$TRANSITION" MG05 --to done 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"advisory"* ]] || [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"manual-test"* ]]
}

@test "manual_verification:true + six PASSED + manual-test PASSED -> no warning" {
  seed_story MG06 PASSED "true"
  seed_transition_env MG06
  bash "$SCRIPT" update --story MG06 --gate "manual-test" \
    --verdict PASSED --plan-id "mt-run-006"
  run bash "$TRANSITION" MG06 --to done 2>&1
  [ "$status" -eq 0 ]
  # No advisory warning should appear
  local warning_count
  warning_count=$(printf '%s\n' "$output" | grep -ci "advisory" || true)
  [ "$warning_count" -eq 0 ]
}

@test "manual_verification:true + six PASSED + no manual-test entry -> no warning" {
  seed_story MG07 PASSED "true"
  seed_transition_env MG07
  # No manual-test ledger entry at all
  run bash "$TRANSITION" MG07 --to done 2>&1
  [ "$status" -eq 0 ]
  local warning_count
  warning_count=$(printf '%s\n' "$output" | grep -ci "advisory" || true)
  [ "$warning_count" -eq 0 ]
}

@test "manual_test_mode=gating + FAILED -> transition exits non-zero" {
  seed_story MG08 PASSED "true"
  seed_transition_env MG08
  bash "$SCRIPT" update --story MG08 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-run-008"
  # Create config with manual_test_mode: gating
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<EOF
review_gate:
  manual_test_mode: gating
EOF
  export GAIA_SHARED_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"
  run bash "$TRANSITION" MG08 --to done 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"manual-test"* ]]
}
