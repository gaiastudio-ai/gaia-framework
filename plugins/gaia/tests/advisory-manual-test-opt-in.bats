#!/usr/bin/env bats
# advisory-manual-test-opt-in.bats — opt-in manual_verification frontmatter (AC3)
#
# Verifies the opt-in behavior of the advisory manual-test gate:
#   AC3 — manual_verification: true -> gate applies (warning on FAILED);
#          field absent -> no warning; field false -> no warning;
#          six gates not all PASSED -> composite still refuses (not a bypass).

load 'test_helper.bash'

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

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ART"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export REVIEW_GATE_LEDGER="$TEST_TMP/.gaia/state/.review-gate-ledger"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
}

teardown() { common_teardown; }

# seed a story with configurable manual_verification and gate verdicts
seed_story_opt() {
  local key="$1" verdict="${2:-PASSED}" manual_flag="${3:-}"
  local fm_manual=""
  if [ "$manual_flag" = "__absent__" ]; then
    fm_manual=""
  elif [ -n "$manual_flag" ]; then
    fm_manual="manual_verification: $manual_flag"
  fi
  cat > "$ART/${key}-fixture.md" <<EOF
---
template: 'story'
key: "$key"
title: "Opt-in gate fixture"
epic: "OPT"
status: review
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
${fm_manual}
---

# Story: Opt-in gate fixture

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

## Epic OPT — Opt-in gate test

### Story ${key}: Opt-in gate fixture

- **Epic:** OPT
- **Status:** review
EOF
  cat > "$TEST_TMP/docs/implementation-artifacts/story-index.yaml" <<EOF
last_updated: "2026-01-01T00:00:00Z"
stories:
  ${key}:
    title: "Opt-in gate fixture"
    epic: "OPT"
    status: "review"
    sprint_id: "fixture-sprint"
EOF
  export SPRINT_STATUS_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  export EPICS_AND_STORIES="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  export STORY_INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  export STORY_STATUS_LOCK="$TEST_TMP/_memory/.story-status.lock"
}

# =====================================================================
# AC3: opt-in via manual_verification frontmatter
# =====================================================================

@test "manual_verification: true + FAILED -> warning emitted on transition" {
  seed_story_opt OI01 PASSED "true"
  seed_transition_env OI01
  bash "$SCRIPT" update --story OI01 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-oi-001"
  run bash "$TRANSITION" OI01 --to done 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"manual-test"* ]]
}

@test "manual_verification absent -> no warning even with FAILED manual-test" {
  seed_story_opt OI02 PASSED "__absent__"
  seed_transition_env OI02
  bash "$SCRIPT" update --story OI02 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-oi-002"
  run bash "$TRANSITION" OI02 --to done 2>&1
  [ "$status" -eq 0 ]
  local advisory_count
  advisory_count=$(printf '%s\n' "$output" | grep -ci "advisory" || true)
  [ "$advisory_count" -eq 0 ]
}

@test "manual_verification: false -> no warning even with FAILED manual-test" {
  seed_story_opt OI03 PASSED "false"
  seed_transition_env OI03
  bash "$SCRIPT" update --story OI03 --gate "manual-test" \
    --verdict FAILED --plan-id "mt-oi-003"
  run bash "$TRANSITION" OI03 --to done 2>&1
  [ "$status" -eq 0 ]
  local advisory_count
  advisory_count=$(printf '%s\n' "$output" | grep -ci "advisory" || true)
  [ "$advisory_count" -eq 0 ]
}

@test "six gates not all PASSED -> composite still refuses (advisory is not a bypass)" {
  seed_story_opt OI04 UNVERIFIED "true"
  seed_transition_env OI04
  # Even with manual_verification: true, if the six canonical gates aren't
  # all PASSED, transition must be refused (exit 8 from composite gate).
  run bash "$TRANSITION" OI04 --to done 2>&1
  [ "$status" -ne 0 ]
}
