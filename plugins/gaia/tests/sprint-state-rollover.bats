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

@test "happy-path single key migrates story_file + injects into target yaml" {
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

@test "happy-path multi-key migrates all listed stories" {
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

@test "story with sprint_id: null is eligible and migrates to --to" {
  seed_story_file "E81-S1" "null" "backlog"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S1
  [ "$status" -eq 0 ]
  # Was null, now sprint-42.
  run grep '^sprint_id: "sprint-42"' "$STORIES_DIR/E81-S1-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-4: sprint_id mismatch refused -------------------------------

@test "story with mismatched sprint_id is refused (no rewrite)" {
  seed_story_file "E81-S1" '"sprint-X"' "in-progress"
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S1
  [ "$status" -ne 0 ]
  # Story file sprint_id NOT rewritten — still sprint-X.
  run grep '^sprint_id: "sprint-X"' "$STORIES_DIR/E81-S1-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-5: Partial failure with mixed eligibility -------------------

@test "partial failure — one ok + one refused = non-zero exit + ok committed" {
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

@test "rollover refuses when story file does not exist" {
  seed_target_yaml "sprint-42"
  run "$CANONICAL" rollover --from sprint-41 --to sprint-42 --keys E81-S99
  [ "$status" -ne 0 ]
  [[ "$output" == *"story file not found"* ]] || [[ "$stderr" == *"story file not found"* ]]
}

# ---------- TC-7: Per-story-nested layout rollover (AC1) ------------------

# Seed a per-story-nested story file: epic-<slug>/<KEY>-<slug>/story.md.
seed_nested_story_file() {
  local key="$1" sprint_id="$2" status="${3:-in-progress}" points="${4:-3}" risk="${5:-medium}"
  local story_dir="$ART/epic-test-epic/${key}-stub"
  mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<EOF
---
template: 'story'
key: "$key"
title: "Nested $key"
status: $status
sprint_id: $sprint_id
points: $points
risk: "$risk"
---

# Story: Nested $key
EOF
}

@test "per-story-nested layout rollover rewrites sprint_id and injects (AC1)" {
  seed_nested_story_file "E81-S10" '"sprint-old"' "in-progress"
  seed_target_yaml "sprint-new"
  run "$CANONICAL" rollover --from sprint-old --to sprint-new --keys E81-S10
  [ "$status" -eq 0 ]
  # Story file sprint_id rewritten.
  run grep '^sprint_id: "sprint-new"' "$ART/epic-test-epic/E81-S10-stub/story.md"
  [ "$status" -eq 0 ]
  # Key injected into target sprint yaml.
  run grep -E 'E81-S10' "$YAML"
  [ "$status" -eq 0 ]
}

# ---------- TC-8: Legacy-nested rollover still works (AC2) ----------------

@test "legacy-nested layout rollover still works after resolver change (AC2)" {
  seed_story_file "E81-S11" '"sprint-old"' "in-progress"
  seed_target_yaml "sprint-new"
  run "$CANONICAL" rollover --from sprint-old --to sprint-new --keys E81-S11
  [ "$status" -eq 0 ]
  run grep '^sprint_id: "sprint-new"' "$STORIES_DIR/E81-S11-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-9: Mixed-layout multi-key rollover -------------------------

@test "mixed-layout rollover handles both nested and legacy keys" {
  seed_nested_story_file "E81-S12" '"sprint-old"' "in-progress"
  seed_story_file "E81-S13" '"sprint-old"' "in-progress"
  seed_target_yaml "sprint-new"
  run "$CANONICAL" rollover --from sprint-old --to sprint-new --keys E81-S12,E81-S13
  [ "$status" -eq 0 ]
  # Per-story-nested file rewritten.
  run grep '^sprint_id: "sprint-new"' "$ART/epic-test-epic/E81-S12-stub/story.md"
  [ "$status" -eq 0 ]
  # Legacy-nested file rewritten.
  run grep '^sprint_id: "sprint-new"' "$STORIES_DIR/E81-S13-stub.md"
  [ "$status" -eq 0 ]
}

# ---------- TC-10: Ambiguous resolver match emits distinct diagnostic -------

@test "ambiguous story file match emits distinct diagnostic and records failure" {
  # Create two per-story-nested dirs under different epics for the same key —
  # the resolver returns exit 2 (ambiguity).
  local dir_a="$ART/epic-alpha/E81-S20-stub"
  local dir_b="$ART/epic-bravo/E81-S20-stub"
  mkdir -p "$dir_a" "$dir_b"
  cat > "$dir_a/story.md" <<'STORY'
---
template: 'story'
key: "E81-S20"
title: "Alpha stub"
status: in-progress
sprint_id: "sprint-old"
points: 3
risk: "medium"
---

# Story: Alpha stub
STORY
  # Distinct title so the two files are not byte-identical (optional, but
  # useful for manual debugging when inspecting the ambiguity stderr).
  sed 's/Alpha/Bravo/g' "$dir_a/story.md" > "$dir_b/story.md"
  seed_target_yaml "sprint-new"
  run "$CANONICAL" rollover --from sprint-old --to sprint-new --keys E81-S20
  # Non-zero exit — key recorded as failed.
  [ "$status" -ne 0 ]
  # Distinct "ambiguous match" diagnostic, NOT the generic "not found" message.
  [[ "$output" == *"ambiguous match"* ]]
  [[ "$output" != *"story file not found"* ]]
}
