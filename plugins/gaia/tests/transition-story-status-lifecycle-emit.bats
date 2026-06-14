#!/usr/bin/env bats
# transition-story-status-lifecycle-emit.bats
#
# Regression guard: the unified status-write path MUST emit a `state_transition`
# lifecycle event on every committed (non-no-op) transition.
#
# Background: when the story-status write path was unified into
# transition-story-status.sh, the lifecycle-event emission that the prior
# sprint-state.sh transition path performed was not carried over. That silently
# blinded throughput-telemetry.sh (which derives per-story wall-clock by
# differencing state_transition timestamps) for every sprint after the cutover —
# the state_transition stream went dark while story_injected events kept flowing
# (injection was never migrated off sprint-state.sh). These tests pin the
# emission back in place so it can never silently regress again.
#
# Usage:
#   bats plugins/gaia/tests/transition-story-status-lifecycle-emit.bats

setup() {
  # Derive REPO_ROOT from the test dir so a repo/checkout rename can't break us.
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-emit-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"

  STORY_KEY="TSS-EMIT-01"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-fixture.md"
  SPRINT_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  EPICS_MD="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.jsonl"

  cat >"$STORY_FILE" <<'EOF'
---
template: 'story'
key: "TSS-EMIT-01"
title: "Emit fixture"
epic: "TSS"
status: in-progress
priority: "P2"
risk: "low"
author: "test"
---

# Story: Emit fixture

> **Status:** in-progress
EOF

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: TSS-EMIT-01
    status: "in-progress"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## Epic TSS — Emit fixture epic

### Story TSS-EMIT-01: Emit fixture

- **Status:** in-progress
EOF

  cat >"$INDEX_YAML" <<'EOF'
last_updated: "2026-06-14T00:00:00Z"
stories:
  TSS-EMIT-01:
    status: "in-progress"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
}

teardown() {
  chmod -R u+w "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

count_transition_events() {
  grep -c '"event_type":"state_transition"' "$EVENTS_LOG" 2>/dev/null || echo 0
}

@test "a committed transition emits one state_transition lifecycle event" {
  run bash "$TRANSITION" TSS-EMIT-01 --to review --from in-progress
  [ "$status" -eq 0 ]
  [ -f "$EVENTS_LOG" ]
  [ "$(count_transition_events)" -eq 1 ]
}

@test "the emitted event carries the correct story_key and from/to payload" {
  bash "$TRANSITION" TSS-EMIT-01 --to review --from in-progress
  run cat "$EVENTS_LOG"
  [[ "$output" == *'"story_key":"TSS-EMIT-01"'* ]]
  [[ "$output" == *'"event_type":"state_transition"'* ]]
  [[ "$output" == *'"from":"in-progress","to":"review"'* ]]
}

@test "a self-transition no-op emits NO state_transition event" {
  # First land in 'review', then attempt review -> review (a no-op edge).
  bash "$TRANSITION" TSS-EMIT-01 --to review --from in-progress
  local before
  before="$(count_transition_events)"
  run bash "$TRANSITION" TSS-EMIT-01 --to review --from review
  [ "$status" -eq 0 ]
  # Count is unchanged — a no-op is not a real edge and must not skew cycle-time.
  [ "$(count_transition_events)" -eq "$before" ]
}

@test "the emitted event is parseable by throughput-telemetry (stories_counted > 0)" {
  # Two real edges a measurable gap apart -> a derivable wall-clock.
  bash "$TRANSITION" TSS-EMIT-01 --to review --from in-progress
  GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1 \
    bash "$TRANSITION" TSS-EMIT-01 --to done --from review
  run bash "$SCRIPTS_DIR/throughput-telemetry.sh" --events "$EVENTS_LOG" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"stories_counted": 1'* ]] || [[ "$output" == *'"stories_counted":1'* ]]
}
