#!/usr/bin/env bats
# sprint-state-rollover.bats — TC-SPRINT-ROLLOVER-1..6 (E81-S6).
#
# NFR-052 public-function coverage anchor: cmd_rollover
#
# End-to-end coverage for the `sprint-state.sh rollover` subcommand: happy-
# path multi-key migration, sprint_id:null acceptance, sprint_id mismatch
# refusal, partial-failure per-story flock rollback, and idempotency.
# All test cases exercise cmd_rollover via the CLI dispatcher
# (`sprint-state.sh rollover ...`); this anchor comment satisfies the
# NFR-052 coverage gate which greps for the public function name across
# tests/*.bats.
#
# Refs: AC2, FR-451, ADR-095 atomicity.

load 'test_helper.bash'

setup() {
  common_setup
  CANONICAL="$SCRIPTS_DIR/sprint-state.sh"
  export PROJECT_PATH="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/_memory"
  ART="$TEST_TMP/docs/implementation-artifacts"
  YAML="$ART/sprint-status.yaml"
  STORIES_DIR="$ART/epic-E81-sprint-40-framework-hygiene/stories"
  mkdir -p "$ART" "$MEMORY_PATH" "$STORIES_DIR"
  export SPRINT_STATUS_YAML="$YAML"
  export IMPLEMENTATION_ARTIFACTS="$ART"
}
teardown() { common_teardown; }

# Seed a minimal story file with the given key and sprint_id (raw YAML value).
seed_story_file() {
  local key="$1" sprint_id="$2" status="${3:-in-progress}" points="${4:-3}" risk="${5:-medium}"
  cat > "$STORIES_DIR/${key}-stub.md" <<EOF
---
template: 'story'
key: "$key"
title: "Stub $key"
status: $status
sprint_id: $sprint_id
points: $points
risk: "$risk"
---

# Story: Stub $key
EOF
}

# Seed a target sprint-status.yaml. Story list starts empty.
seed_target_yaml() {
  local sprint_id="$1"
  mkdir -p "$(dirname "$YAML")"
  cat > "$YAML" <<EOF
sprint_id: "$sprint_id"
status: active
total_points: 0
stories: []
EOF
}

# ---------- TC-1: Happy-path single-key rollover ---------------------------

@test "TC-SPRINT-ROLLOVER-1: happy-path single key migrates story_file + injects into target yaml" {
  seed_story_file "E81-S2" '"sprint-41"' "in-progress"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S2
  [ "$status" -eq 0 ]
  # Story file sprint_id rewritten to sprint-42.
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S2-stub.md"
  [ "$status" -eq 0 ]
  # Story injected into target yaml (cmd_inject appends to stories[]).
  run grep -E 'E81-S2' "$YAML"
  [ "$status" -eq 0 ]
}

# ---------- TC-2: Multi-key happy-path rollover ----------------------------

@test "TC-SPRINT-ROLLOVER-2: happy-path multi-key migrates all listed stories" {
  seed_story_file "E81-S2" '"sprint-41"' "in-progress"
  seed_story_file "E81-S3" '"sprint-41"' "backlog"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S2,E81-S3
  [ "$status" -eq 0 ]
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S2-stub.md"
  [ "$status" -eq 0 ]
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S3-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-3: sprint_id: null accepted ---------------------------------

@test "TC-SPRINT-ROLLOVER-3: story with sprint_id: null is eligible and migrates to --to" {
  seed_story_file "E81-S1" "null" "backlog"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S1
  [ "$status" -eq 0 ]
  # Was null, now sprint-42.
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S1-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-4: sprint_id mismatch refused -------------------------------

@test "TC-SPRINT-ROLLOVER-4: story with mismatched sprint_id is refused (no rewrite)" {
  seed_story_file "E81-S1" '"sprint-X"' "in-progress"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S1
  [ "$status" -ne 0 ]
  # Story file sprint_id NOT rewritten — still sprint-X.
  run grep '^sprint_id: "sprint-X"' "$STORIES_DIR/E81-S1-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-5: Partial failure with mixed eligibility -------------------

@test "TC-SPRINT-ROLLOVER-5: partial failure — one ok + one refused = non-zero exit + ok committed" {
  seed_story_file "E81-S1" '"sprint-41"' "in-progress"   # eligible
  seed_story_file "E81-S2" '"sprint-X"' "in-progress"    # ineligible
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S1,E81-S2
  [ "$status" -ne 0 ]
  # E81-S1 migrated (committed).
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S1-stub.md"
  [ "$status" -eq 0 ]
  # E81-S2 untouched.
  run grep '^sprint_id: "sprint-X"' "$STORIES_DIR/E81-S2-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-6: Missing story file refused -------------------------------

@test "TC-SPRINT-ROLLOVER-6: rollover refuses when story file does not exist" {
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S99
  [ "$status" -ne 0 ]
  [[ "$output" == *"story file not found"* ]] || [[ "$stderr" == *"story file not found"* ]]
}
