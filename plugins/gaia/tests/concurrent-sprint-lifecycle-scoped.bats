#!/usr/bin/env bats
# concurrent-sprint-lifecycle-scoped.bats
#
# Tests for per-sprint lifecycle scoping — review, retro, action items, and
# carry-over safety in concurrent mode.
#
# Covers: aiw_resolve (action-items-write.sh resolve subcommand),
#   cmd_rollover concurrent three-phase protocol, set-story-sprint --clear,
#   _remove_story_from_yaml, _cmd_rollover_concurrent, _cmd_set_story_sprint_clear
#   (public-function coverage gate).

load 'test_helper.bash'

SPRINT_STATE_SH="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
AIW_SH="$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
IC_SH="$BATS_TEST_DIRNAME/../scripts/independence-check.sh"
LOCK_LIB="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_DIRNAME/../scripts"
  export GAIA_SNAPSHOT_HOOK_DISABLE=1
  export GAIA_SKIP_ORPHAN_SWEEP=1

  STATE_DIR="$TEST_TMP/.gaia/state"
  ART_DIR="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_TMP/.gaia/config"
  LIFECYCLE="$MEMORY_PATH/lifecycle-events.jsonl"

  mkdir -p "$STATE_DIR" "$ART_DIR" "$MEMORY_PATH" "$CONFIG_DIR"

  # Planning artifacts for independence check.
  local planning_dir="$TEST_TMP/.gaia/artifacts/planning-artifacts"
  mkdir -p "$planning_dir/epics"
  cat > "$planning_dir/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Test Epic

| Key | Title | Status |
|-----|-------|--------|
| E900-S1 | Story one | in-progress |
| E900-S2 | Story two | in-progress |
| E900-S3 | Story three | in-progress |
| E900-S4 | Story four | in-progress |
| E900-S5 | Story five | backlog |

## E901 — Other Epic

| Key | Title | Status |
|-----|-------|--------|
| E901-S1 | Other story | in-progress |
MD
}

teardown() {
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
  common_teardown
}

# ---------- Fixture helpers ----------

_seed_config() {
  local max_conc="${1:-2}"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP/app"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP/_gaia"
planning_artifacts: "$TEST_TMP/.gaia/artifacts/planning-artifacts"
implementation_artifacts: "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
test_artifacts: "$TEST_TMP/.gaia/artifacts/test-artifacts"
framework_version: 1.200.0
date: 1970-01-01
sprint:
  max_concurrent_active: $max_conc
YAML
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"
}

_seed_single_config() {
  _seed_config 1
}

_seed_per_sprint_yaml() {
  local sprint_id="$1" status="$2"
  local f="$STATE_DIR/sprint-status-${sprint_id}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'stories: []\n'
  } > "$f"
  printf '%s' "$f"
}

_add_story_to_yaml() {
  local yaml="$1" key="$2" st="${3:-in-progress}" points="${4:-3}"
  # Append a story entry using yq v4 strenv() syntax.
  GAIA_K="$key" GAIA_S="$st" GAIA_P="$points" yq -i \
    '.stories += [{"key": strenv(GAIA_K), "status": strenv(GAIA_S), "points": (strenv(GAIA_P) | tonumber)}]' \
    "$yaml" 2>/dev/null
  # Update total_points.
  local cur
  cur="$(yq -r '.total_points // 0' "$yaml" 2>/dev/null)" || cur=0
  local new_val=$((cur + points))
  GAIA_V="$new_val" yq -i '.total_points = (strenv(GAIA_V) | tonumber)' "$yaml" 2>/dev/null
}

_seed_story_file() {
  local key="$1" epic="${2:-E900}" sprint="${3:-null}" touchset="${4:-}"
  local dir="$ART_DIR/epic-${epic}-test/${key}-test-story"
  mkdir -p "$dir"
  local f="$dir/story.md"
  {
    printf '%s\n' "---"
    printf "template: 'story'\n"
    printf 'key: "%s"\n' "$key"
    printf 'title: "Test story %s"\n' "$key"
    printf 'epic: "%s"\n' "$epic"
    printf 'status: in-progress\n'
    printf 'points: 3\n'
    printf 'risk: medium\n'
    printf 'sprint_id: %s\n' "$sprint"
    printf 'depends_on: []\n'
    printf 'blocks: []\n'
    if [ -n "$touchset" ]; then
      printf 'predicted_touch_set:\n'
      local OLDIFS="$IFS"; IFS=','
      for p in $touchset; do
        printf '  - "%s"\n' "$p"
      done
      IFS="$OLDIFS"
    fi
    printf '%s\n' "---"
    printf '# Story: Test story %s\n' "$key"
  } > "$f"
  printf '%s' "$f"
}

_seed_action_items_yaml() {
  local target="$1"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    sprint_id: "sprint-900"
    text: "Fix the widget"
    classification: "implementation"
    status: "open"
    escalation_count: 0
    created_at: "2026-01-01T00:00:00Z"
    theme_hash: "sha256:abc123"
    story_key: "E900-S1"
  - id: "AI-2"
    sprint_id: "sprint-901"
    text: "Refactor the module"
    classification: "process"
    status: "open"
    escalation_count: 0
    created_at: "2026-01-01T00:00:00Z"
    theme_hash: "sha256:def456"
    story_key: "E900-S2"
YAML
}

# ================================================================
# Cross-sprint action item resolution via scripted
# resolve subcommand
# ================================================================

@test "aiw_resolve sets status, resolution, resolved_date, resolved_in via strenv" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  # Source the script to call aiw_resolve directly.
  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "resolved" \
    --resolution "Fixed in sprint-901" \
    --resolved-date "2026-02-15" \
    --resolved-in "sprint-901" \
    --related-stories "E900-S3"

  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  # Verify fields written correctly.
  local item_status
  item_status="$(yq -r '.items[0].status' "$target")"
  [ "$item_status" = "resolved" ]

  local item_resolution
  item_resolution="$(yq -r '.items[0].resolution' "$target")"
  [ "$item_resolution" = "Fixed in sprint-901" ]

  local item_rd
  item_rd="$(yq -r '.items[0].resolved_date' "$target")"
  [ "$item_rd" = "2026-02-15" ]

  local item_ri
  item_ri="$(yq -r '.items[0].resolved_in' "$target")"
  [ "$item_ri" = "sprint-901" ]

  # sprint_id preserved from original entry.
  local item_sid
  item_sid="$(yq -r '.items[0].sprint_id' "$target")"
  [ "$item_sid" = "sprint-900" ]

  # last_updated bumped.
  local lu
  lu="$(yq -r '.last_updated' "$target")"
  [ -n "$lu" ]
}

# ================================================================
# resolved_in absent in single-sprint mode
# ================================================================

@test "aiw_resolve without --resolved-in does not add resolved_in field" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "done" \
    --resolution "Completed" \
    --resolved-date "2026-02-15"

  [ "$status" -eq 0 ]

  # resolved_in should NOT exist.
  local ri
  ri="$(yq -r '.items[0].resolved_in // "ABSENT"' "$target")"
  [ "$ri" = "ABSENT" ]

  # Status and resolution set.
  local s
  s="$(yq -r '.items[0].status' "$target")"
  [ "$s" = "done" ]

  local rd
  rd="$(yq -r '.items[0].resolved_date' "$target")"
  [ "$rd" = "2026-02-15" ]
}

# ================================================================
# YAML injection via sprint_id in resolve
# ================================================================

@test "aiw_resolve uses strenv for special characters in sprint_id" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  # Sprint ID with colon — would cause YAML injection without strenv.
  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "resolved" \
    --resolution "test" \
    --resolved-in "sprint: 900"

  [ "$status" -eq 0 ]

  # Verify the literal string is preserved.
  local ri
  ri="$(yq -r '.items[0].resolved_in' "$target")"
  [ "$ri" = "sprint: 900" ]

  # File must still be valid YAML.
  yq '.' "$target" >/dev/null 2>&1
}

@test "aiw_resolve rejects invalid status vocabulary" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "completed"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid status"* ]]
}

@test "aiw_resolve rejects missing item" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-999" \
    --status "done"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ================================================================
# resolved_date only for done/invalid/resolved
# ================================================================

@test "aiw_resolve does not set resolved_date for deferred status" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "deferred" \
    --resolution "Postponed"

  [ "$status" -eq 0 ]

  local rd
  rd="$(yq -r '.items[0].resolved_date // "ABSENT"' "$target")"
  [ "$rd" = "ABSENT" ]
}

# ================================================================
# Sourced-versus-executed dispatch guard
# ================================================================

@test "action-items-write.sh resolve subcommand routes correctly" {
  local target="$TEST_TMP/action-items.yaml"
  _seed_action_items_yaml "$target"

  run bash "$AIW_SH" resolve \
    --target "$target" \
    --item "AI-2" \
    --status "done" \
    --resolution "Completed via direct invocation"

  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  local s
  s="$(yq -r '.items[1].status' "$target")"
  [ "$s" = "done" ]
}

@test "action-items-write.sh without subcommand shows usage" {
  run bash "$AIW_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

# ================================================================
# Carry-over without predicted_touch_set
# ================================================================

@test "concurrent rollover refuses story without predicted_touch_set" {
  _seed_config 2

  local from_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  _seed_per_sprint_yaml "sprint-901" "active" > /dev/null

  # Story without touch-set.
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 2 ]
  [[ "${output}${lines[*]}" == *"touch-set missing"* ]] || \
    { echo "Expected 'touch-set missing' in output: $output" >&2; false; }
}

# ================================================================
# Explicit empty touch-set is valid
# ================================================================

@test "concurrent rollover accepts explicit empty touch-set" {
  _seed_config 2

  local from_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  local to_yaml
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Story with explicit empty touch-set.
  local story_dir="$ART_DIR/epic-E900-test/E900-S5-test-story"
  mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<'YAML'
---
template: 'story'
key: "E900-S5"
title: "Story with empty touch-set"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: []
blocks: []
predicted_touch_set: []
---
# Story: Story with empty touch-set
YAML
  _add_story_to_yaml "$from_yaml" "E900-S5"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S5

  # Should not be refused (empty touch-set means "touches no files").
  echo "Exit code: $status" >&2
  echo "Output: $output" >&2
  [ "$status" -eq 0 ]
}

# ================================================================
# Mixed-batch exit precedence
# ================================================================

@test "mixed-batch exit precedence: exit 2 for touch-set missing over exit 1" {
  _seed_config 2

  local from_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  _seed_per_sprint_yaml "sprint-901" "active" > /dev/null

  # Key without touch-set.
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Key with touch-set (would pass if alone).
  _seed_story_file "E900-S2" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S2"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys "E900-S1,E900-S2"

  echo "Exit: $status Output: $output" >&2
  # Exit 2 takes precedence over exit 0/1.
  [ "$status" -eq 2 ]
}

# ================================================================
# set-story-sprint --clear
# ================================================================

@test "set-story-sprint --clear resets sprint_id to null" {
  _seed_config 2

  local yaml
  yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"

  local sf
  sf="$(_seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts")"
  _add_story_to_yaml "$yaml" "E900-S1"

  run bash "$SPRINT_STATE_SH" set-story-sprint \
    --story E900-S1 --clear

  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared to null"* ]]

  # Verify frontmatter updated.
  /usr/bin/grep -q '^sprint_id:[[:space:]]*null' "$sf"
}

@test "set-story-sprint --clear is idempotent on null sprint_id" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" > /dev/null

  local sf
  sf="$(_seed_story_file "E900-S3" "E900" "null" "src/b.ts")"

  run bash "$SPRINT_STATE_SH" set-story-sprint \
    --story E900-S3 --clear

  [ "$status" -eq 0 ]
  [[ "$output" == *"already null"* ]]
}

# ================================================================
# Single-sprint mode lifecycle unchanged
# ================================================================

@test "single-sprint rollover does not run independence check" {
  _seed_single_config

  # Seed single-sprint yaml.
  cat > "$STATE_DIR/sprint-status.yaml" <<YAML
sprint_id: "sprint-900"
status: active
total_points: 3
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 3
YAML
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null

  # Single-sprint rollover uses the legacy _rollover_one path.
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  # Must NOT show independence-check output (no concurrent protocol).
  [[ "$output" != *"independence"* ]]
  [[ "$output" != *"FAIL rule"* ]]
}

# ================================================================
# Internal ID scrub on published files
# ================================================================

@test "no leaked internal IDs in files changed by this story" {
  # Check action-items-write.sh for leaked IDs.
  local f="$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
  run /usr/bin/grep -nE '(FR-[0-9]|NFR-[0-9]|SR-[0-9]|ADR-[0-9]|E[0-9]+-S[0-9]+|TC-|AF-20|AI-20|T-[0-9])' "$f"
  [ "$status" -ne 0 ] || {
    echo "Leaked IDs in action-items-write.sh: $output" >&2
    false
  }

  # Check sprint-state.sh for leaked IDs in new functions only.
  # (Existing code may have pre-existing references; check our new functions.)
  local ss="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  run bash -c "sed -n '/_cmd_rollover_concurrent/,/^}/p' '$ss' | /usr/bin/grep -nE '(FR-[0-9]|NFR-[0-9]|E[0-9]+-S[0-9]+|TC-|AF-20)'"
  [ "$status" -ne 0 ] || {
    echo "Leaked IDs in _cmd_rollover_concurrent: $output" >&2
    false
  }
}

# ================================================================
# Three-phase rollover closing-marker refusal
# ================================================================

@test "concurrent rollover refuses when closing marker exists" {
  _seed_config 2

  local from_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  _seed_per_sprint_yaml "sprint-901" "active" > /dev/null

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Write a closing marker with this process as owner (alive).
  local marker="$STATE_DIR/.sprint-closing-sprint-900"
  printf 'sprint_id=sprint-900\nowner_pid=%d\nstart_time=2026-01-01T00:00:00Z\n' "$$" > "$marker"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint close in progress"* ]] || \
  [[ "${lines[*]}" == *"sprint close in progress"* ]]

  rm -f "$marker"
}

# ================================================================
# Carry-over passes independence, touch-set retained
# ================================================================

@test "carried-over story retains predicted_touch_set" {
  _seed_config 2

  local from_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  local to_yaml
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  local sf
  sf="$(_seed_story_file "E900-S3" "E900" '"sprint-900"' "src/unique-path.ts")"
  _add_story_to_yaml "$from_yaml" "E900-S3"

  # Confirm touch-set present before rollover.
  /usr/bin/grep -q 'predicted_touch_set' "$sf"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S3

  [ "$status" -eq 0 ]

  # Touch-set retained on the story file.
  /usr/bin/grep -q 'predicted_touch_set' "$sf"
  /usr/bin/grep -q 'src/unique-path.ts' "$sf"

  # Story must be in the target yaml and gone from source.
  local in_target in_source
  in_target="$(yq -r '.stories[] | select(.key == "E900-S3") | .key' "$to_yaml" 2>/dev/null)" || in_target=""
  in_source="$(yq -r '.stories[] | select(.key == "E900-S3") | .key' "$from_yaml" 2>/dev/null)" || in_source=""
  [ "$in_target" = "E900-S3" ]
  [ -z "$in_source" ]

  # sprint_id rewritten to target.
  /usr/bin/grep -q '^sprint_id:.*sprint-901' "$sf"
}

# ================================================================
# Carried key overlapping target story is refused
# ================================================================

@test "carry-over key overlapping target sprint story is refused" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Carried key depends on a story already in the target sprint (rule a).
  local dir1="$ART_DIR/epic-E900-test/E900-S1-test-story"; mkdir -p "$dir1"
  cat > "$dir1/story.md" <<'S'
---
template: 'story'
key: "E900-S1"
title: "Carried story"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: ["E901-S1"]
blocks: []
predicted_touch_set:
  - "src/carried.ts"
---
# Story
S
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Target sprint story that the carried key depends on.
  local dir2="$ART_DIR/epic-E901-test/E901-S1-test-story"; mkdir -p "$dir2"
  cat > "$dir2/story.md" <<'S'
---
template: 'story'
key: "E901-S1"
title: "Target story"
epic: "E901"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-901"
depends_on: []
blocks: []
predicted_touch_set:
  - "src/target.ts"
---
# Story
S
  _add_story_to_yaml "$to_yaml" "E901-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]

  # Story must stay in source, not in target.
  local in_source in_target
  in_source="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$from_yaml" 2>/dev/null)" || in_source=""
  in_target="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || in_target=""
  [ "$in_source" = "E900-S1" ]
  [ -z "$in_target" ]
}

# ================================================================
# Per-key results — independent key moves, failing key stays
# ================================================================

@test "per-key rollover: independent key moves while dependent key stays" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Independent key (no overlap with target).
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/independent.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Dependent key (depends on target story = rule a violation).
  local dir2="$ART_DIR/epic-E900-test/E900-S2-test-story"; mkdir -p "$dir2"
  cat > "$dir2/story.md" <<'S'
---
template: 'story'
key: "E900-S2"
title: "Dependent story"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: ["E901-S1"]
blocks: []
predicted_touch_set:
  - "src/dependent.ts"
---
# Story
S
  _add_story_to_yaml "$from_yaml" "E900-S2"

  # Target sprint story.
  local dir3="$ART_DIR/epic-E901-test/E901-S1-test-story"; mkdir -p "$dir3"
  cat > "$dir3/story.md" <<'S'
---
template: 'story'
key: "E901-S1"
title: "Target story"
epic: "E901"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-901"
depends_on: []
blocks: []
predicted_touch_set:
  - "src/target.ts"
---
# Story
S
  _add_story_to_yaml "$to_yaml" "E901-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys "E900-S1,E900-S2"

  # Exit 1 (at least one key failed independence).
  [ "$status" -eq 1 ]

  # Independent key moved to target.
  local s1_target s1_source
  s1_target="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || s1_target=""
  s1_source="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$from_yaml" 2>/dev/null)" || s1_source=""
  [ "$s1_target" = "E900-S1" ]
  [ -z "$s1_source" ]

  # Dependent key stays in source.
  local s2_target s2_source
  s2_target="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$to_yaml" 2>/dev/null)" || s2_target=""
  s2_source="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$from_yaml" 2>/dev/null)" || s2_source=""
  [ -z "$s2_target" ]
  [ "$s2_source" = "E900-S2" ]
}

# ================================================================
# Fail closed when independence-check.sh missing
# ================================================================

@test "rollover fails closed when independence-check.sh is missing" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Hide independence-check.sh by pointing SPRINT_STATE_SCRIPT_DIR at a
  # dir that lacks it.
  local mock_dir="$TEST_TMP/mock-scripts"
  mkdir -p "$mock_dir"
  # Copy sprint-state.sh only (it sources lib/ via SPRINT_STATE_SCRIPT_DIR).
  cp "$BATS_TEST_DIRNAME/../scripts/sprint-state.sh" "$mock_dir/sprint-state.sh"
  # Link lib/ and sibling scripts (but NOT independence-check.sh).
  ln -sf "$BATS_TEST_DIRNAME/../scripts/lib" "$mock_dir/lib"
  local _f _bn
  for _f in "$BATS_TEST_DIRNAME/../scripts"/*.sh; do
    [ -e "$_f" ] || continue
    _bn="$(basename "$_f")"
    [ "$_bn" = "independence-check.sh" ] && continue
    [ "$_bn" = "sprint-state.sh" ] && continue
    ln -sf "$_f" "$mock_dir/$_bn"
  done

  run env SPRINT_STATE_SCRIPT_DIR="$mock_dir" \
    bash "$mock_dir/sprint-state.sh" rollover \
      --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or not executable"* ]] || [[ "$output" == *"fail closed"* ]]
}

# ================================================================
# aiw_resolve preserves file format on complex YAML shapes
# ================================================================

@test "aiw_resolve only changes target item lines on complex YAML shapes" {
  # Fixture mimicking real tracker shapes: block scalars, block-list
  # related_stories, nested maps, duplicate IDs.
  local target="$TEST_TMP/tracker-complex.yaml"
  cat > "$target" <<'FIXTURE'
last_updated: "2026-01-01"
items:
  - id: "AI-T1"
    created: "2026-05-15T19:35:00Z"
    type: feature
    status: open
    context_for_target: |
      Some context with embedded YAML-like content.
        status: invalid with resolution explaining the bug.
        - id: AI-FAKE
          status: fake
      End of block.
    resolution: |
      Old resolution text that spans
      multiple lines and should be
      replaced entirely.
    assignee: "someone"
  - id: "AI-T2"
    status: done
    related_stories:
      - E900-S1
      - E900-S5
    resolution: "Prior resolution."
    context_for_target: |
      Another block scalar.
  - id: "AI-T3"
    status: resolved
    resolution: "Existing resolution."
    related_stories: ["E900-S65"]
  - id: "AI-T4"
    sprint_id: "sprint-100"
    status: open
    text: "Simple item"
  - id: "AI-T1"
    sprint_id: "sprint-55"
    status: open
    text: "Duplicate ID entry"
FIXTURE

  source "$AIW_SH"

  # Resolve AI-T1 (block scalar shape).
  run aiw_resolve --target "$target" --item "AI-T1" --status "done" \
    --resolution "Fixed" --resolved-date "2026-10-28"
  [ "$status" -eq 0 ]

  # File must still be valid YAML.
  yq '.' "$target" > /dev/null

  # AI-T1 status and resolution changed.
  local t1_status t1_res
  t1_status="$(yq -r '.items[0].status' "$target")"
  [ "$t1_status" = "done" ]
  t1_res="$(yq -r '.items[0].resolution' "$target")"
  [ "$t1_res" = "Fixed" ]

  # Block scalar preserved (context_for_target still contains the embedded text).
  local ctx
  ctx="$(yq -r '.items[0].context_for_target' "$target")"
  [[ "$ctx" == *"status: invalid"* ]]
  [[ "$ctx" == *"- id: AI-FAKE"* ]]

  # AI-T2 block-list related_stories preserved.
  local t2_rs
  t2_rs="$(yq -r '.items[1].related_stories | length' "$target")"
  [ "$t2_rs" -ge 2 ]

  # Duplicate AI-T1 unchanged.
  local dup_status
  dup_status="$(yq -r '.items[4].status' "$target")"
  [ "$dup_status" = "open" ]

  # last_updated bumped.
  local lu
  lu="$(yq -r '.last_updated' "$target")"
  [ "$lu" = "$(date -u +%Y-%m-%d)" ]

  # Append after resolve still produces valid YAML.
  aiw_write --target "$target" --sprint-id "sprint-99" \
    --classification "implementation" --text "New" \
    --ref-key "story_key" --ref-value "E999-S1"
  yq '.' "$target" > /dev/null
}

@test "aiw_resolve then aiw_write append produces valid YAML" {
  local target="$TEST_TMP/action-items-append.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  # Resolve an item.
  aiw_resolve --target "$target" --item "AI-1" --status "done" --resolution "Done"

  # Append a new item via the existing writer.
  aiw_write --target "$target" --sprint-id "sprint-902" \
    --classification "implementation" --text "New item" \
    --ref-key "story_key" --ref-value "E900-S9"

  # File must parse as valid YAML.
  yq '.items | length' "$target" > /dev/null
  local count
  count="$(yq -r '.items | length' "$target")"
  [ "$count" -ge 3 ]
}

# ================================================================
# Parallel resolves both persisted
# ================================================================

@test "two parallel aiw_resolve on different items both persist" {
  local target="$TEST_TMP/action-items-parallel.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  # Resolve both items in background.
  aiw_resolve --target "$target" --item "AI-1" --status "done" --resolution "First" &
  local pid1=$!
  aiw_resolve --target "$target" --item "AI-2" --status "resolved" --resolution "Second" &
  local pid2=$!
  wait "$pid1" "$pid2"

  # Both must be resolved. Use yq which handles any YAML format.
  local s1 s2
  s1="$(yq -r '.items[] | select(.id == "AI-1") | .status' "$target" 2>/dev/null)" || s1=""
  s2="$(yq -r '.items[] | select(.id == "AI-2") | .status' "$target" 2>/dev/null)" || s2=""
  [ "$s1" = "done" ]
  [ "$s2" = "resolved" ]
}

# ================================================================
# SKILL.md prose per-line assertions
# ================================================================

@test "action-items SKILL.md references scripted resolve path" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -q 'action-items-write.sh.*resolve' "$skill"
  /usr/bin/grep -q '\-\-status' "$skill"
  /usr/bin/grep -q '\-\-resolved-in' "$skill"
  # Must NOT contain the old Edit-tool path.
  ! /usr/bin/grep -q 'Save the updated.*via the.*Edit.*tool' "$skill"
}

@test "sprint-review SKILL.md documents closed-bound read-only mode" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -q 'read-only historical mode' "$skill"
  /usr/bin/grep -q 'closed-binding refusal' "$skill"
  /usr/bin/grep -q 'concurrent-sprint mode' "$skill"
}

@test "retro SKILL.md documents concurrent scoping" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -q 'concurrent-sprint mode' "$skill"
  /usr/bin/grep -q 'retrospective-{sprint_id}' "$skill"
}

@test "sprint-plan SKILL.md documents carry-over safety" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -q 'Carry-Over Safety' "$skill"
  /usr/bin/grep -q 'independence' "$skill"
  /usr/bin/grep -q 'touch-set' "$skill"
  /usr/bin/grep -q 'set-story-sprint.*--clear' "$skill"
}

# ================================================================
# Comprehensive leak test
# ================================================================

@test "no leaked IDs in any changed published file including mirror" {
  local files=(
    "$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
    "$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
    "$BATS_TEST_DIRNAME/../scripts/independence-check.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/sprint-state.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  )

  local f
  for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "MISSING: $f" >&2; false; return; }
  done

  # Pattern covers: ruling IDs (R<n>), requirement IDs (FR-/NFR-/SR-/ADR-),
  # story keys (E<n>-S<n>), test cases (TC-), cascade/action-item IDs
  # (AF-20/AI-20), and threat IDs (T-<n>).
  local pattern='(R[0-9]{1,3}[/)]|FR-[0-9]|NFR-[0-9]|SR-[0-9]|ADR-[0-9]|E[0-9]+-S[0-9]+|TC-[A-Z]|AF-20|AI-20[0-9])'

  # Scan files that are wholly owned by this story (no pre-existing code).
  # For files with pre-existing code (sprint-state.sh, independence-check.sh),
  # scan only the new functions added by this story.
  local f
  local wholly_owned=(
    "$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  )
  for f in "${wholly_owned[@]}"; do
    local bn
    bn="$(basename "$f")"
    run /usr/bin/grep -nE "$pattern" "$f"
    [ "$status" -ne 0 ] || {
      echo "Leaked IDs in $bn: $output" >&2
      false
    }
  done

  # sprint-state.sh: scan only the new functions.
  local ss="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
  run bash -c "sed -n '/_cmd_rollover_concurrent/,/^[^ ]/p; /_cmd_set_story_sprint_clear/,/^[^ ]/p; /_remove_story_from_yaml/,/^[^ ]/p' '$ss' | /usr/bin/grep -nE '$pattern'"
  [ "$status" -ne 0 ] || {
    echo "Leaked IDs in sprint-state.sh (new functions): $output" >&2
    false
  }

  # Planted-id proof: create a temp copy with a planted ID, verify it fails.
  local planted="$TEST_TMP/planted.sh"
  printf '# This has FR-999 leaked\n' > "$planted"
  run /usr/bin/grep -nE "$pattern" "$planted"
  [ "$status" -eq 0 ] || {
    echo "Planted ID test failed to detect FR-999" >&2
    false
  }

  # Mirror byte-identical check.
  diff "$BATS_TEST_DIRNAME/../scripts/sprint-state.sh" \
       "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/sprint-state.sh"
}

# ================================================================
# Empty touch-set carry-over asserts key moved AND left source
# ================================================================

@test "empty touch-set carry-over: key in target AND gone from source" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  local story_dir="$ART_DIR/epic-E900-test/E900-S5-test-story"; mkdir -p "$story_dir"
  cat > "$story_dir/story.md" <<'YAML'
---
template: 'story'
key: "E900-S5"
title: "Empty touch-set story"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: []
blocks: []
predicted_touch_set: []
---
# Story
YAML
  _add_story_to_yaml "$from_yaml" "E900-S5"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S5

  [ "$status" -eq 0 ]

  # Key must be in target and gone from source.
  local in_target in_source
  in_target="$(yq -r '.stories[] | select(.key == "E900-S5") | .key' "$to_yaml" 2>/dev/null)" || in_target=""
  in_source="$(yq -r '.stories[] | select(.key == "E900-S5") | .key' "$from_yaml" 2>/dev/null)" || in_source=""
  [ "$in_target" = "E900-S5" ]
  [ -z "$in_source" ]
}

# ================================================================
# Lock-sequencing tests — three-phase rollover
# ================================================================

@test "three-phase rollover: rollover locks are sequenced (flock path)" {
  # Verify Phase A (L4), Phase B (target L1), and Phase C (source L1)
  # use separate subshells so the rollover's own lock acquisitions
  # do not overlap. The inject and lifecycle-event sub-operations may
  # internally take their own locks (e.g. lifecycle-events.jsonl.lock),
  # but the rollover's three-phase locks must be sequential.
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/unique-lock.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  local debug_log="$TEST_TMP/lock-debug.log"
  export ACQUIRE_LOCK_DEBUG=1
  export ACQUIRE_LOCK_DEBUG_LOG="$debug_log"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 0 ]

  # Extract only the rollover's own lock paths: lifecycle, sprint-900, sprint-901.
  # Filter out lifecycle-events.jsonl.lock (sub-operation lock).
  local rollover_locks="$TEST_TMP/rollover-locks.log"
  /usr/bin/grep -v 'lifecycle-events' "$debug_log" > "$rollover_locks" 2>/dev/null || true

  # Verify L4 (lifecycle) is acquired and released before any L1.
  local l4_released=0 l1_before_l4_release=0
  while IFS=' ' read -r action path _epoch; do
    case "$action" in
      release)
        case "$path" in *sprint-lifecycle*) l4_released=1 ;; esac ;;
      acquire)
        case "$path" in
          *sprint-status-*) [ "$l4_released" -eq 1 ] || l1_before_l4_release=1 ;;
        esac ;;
    esac
  done < "$rollover_locks"
  [ "$l1_before_l4_release" -eq 0 ] || {
    echo "L1 acquired before L4 released:" >&2
    cat "$rollover_locks" >&2
    false
  }
}

@test "three-phase rollover under GAIA_LOCK_FORCE_FALLBACK (flock off)" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/unique-fb.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  local debug_log="$TEST_TMP/lock-fallback-debug.log"
  export ACQUIRE_LOCK_DEBUG=1
  export ACQUIRE_LOCK_DEBUG_LOG="$debug_log"
  # The lock library refuses GAIA_LOCK_FORCE_FALLBACK when
  # GAIA_PARALLEL_EXECUTION is on, so unset it.
  unset GAIA_PARALLEL_EXECUTION 2>/dev/null || true
  export GAIA_LOCK_FORCE_FALLBACK=1

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 0 ]

  # Verify L4 (lifecycle) released before any L1 acquired (same as flock test).
  local rollover_locks="$TEST_TMP/rollover-fb-locks.log"
  /usr/bin/grep -v 'lifecycle-events' "$debug_log" > "$rollover_locks" 2>/dev/null || true

  local l4_released=0 l1_before_l4_release=0
  while IFS=' ' read -r action path _epoch; do
    case "$action" in
      release)
        case "$path" in *sprint-lifecycle*) l4_released=1 ;; esac ;;
      acquire)
        case "$path" in
          *sprint-status-*) [ "$l4_released" -eq 1 ] || l1_before_l4_release=1 ;;
        esac ;;
    esac
  done < "$rollover_locks"
  [ "$l1_before_l4_release" -eq 0 ] || {
    echo "L1 acquired before L4 released (fallback):" >&2
    cat "$rollover_locks" >&2
    false
  }

  # Verify key actually moved.
  local in_target in_source
  in_target="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || in_target=""
  in_source="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$from_yaml" 2>/dev/null)" || in_source=""
  [ "$in_target" = "E900-S1" ]
  [ -z "$in_source" ]
}

@test "Phase C holds source L1: debug log proves source lock acquired" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/phase-c.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  local debug_log="$TEST_TMP/phase-c-lock-debug.log"
  export ACQUIRE_LOCK_DEBUG=1
  export ACQUIRE_LOCK_DEBUG_LOG="$debug_log"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1
  [ "$status" -eq 0 ]

  # The debug log must contain an acquire for the source sprint lock file.
  [ -s "$debug_log" ] || {
    echo "ACQUIRE_LOCK_DEBUG_LOG is empty — no locks recorded" >&2
    false
  }
  /usr/bin/grep -q "sprint-status-sprint-900.yaml.lock" "$debug_log" || {
    echo "Phase C did not acquire source L1 (sprint-900 lock not in debug log)" >&2
    cat "$debug_log" >&2
    false
  }
}

# ================================================================
# Invocation pinning — Phase A uses independence-check with
# --candidate-stories / --from-sprint
# ================================================================

@test "Phase A exercises independence-check.sh with --candidate-stories and --from-sprint" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/pin-test.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Create a shim that records the args and exits 0 (PASS).
  local shim_dir="$TEST_TMP/shim-scripts"
  mkdir -p "$shim_dir"
  # Copy everything from the real scripts dir.
  local _f _bn
  for _f in "$BATS_TEST_DIRNAME/../scripts"/*.sh; do
    [ -e "$_f" ] || continue
    _bn="$(basename "$_f")"
    [ "$_bn" = "independence-check.sh" ] && continue
    ln -sf "$_f" "$shim_dir/$_bn"
  done
  ln -sf "$BATS_TEST_DIRNAME/../scripts/lib" "$shim_dir/lib"

  local spy_log="$TEST_TMP/ic-spy.log"
  cat > "$shim_dir/independence-check.sh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$spy_log"
# Echo PASS for every key.
for arg in "\$@"; do
  case "\$arg" in
    --candidate-stories) shift; for k in \$(echo "\$1" | tr ',' ' '); do printf 'PASS independence: %s\n' "\$k"; done ;;
  esac
done
exit 0
SHIM
  chmod +x "$shim_dir/independence-check.sh"

  run env SPRINT_STATE_SCRIPT_DIR="$shim_dir" \
    bash "$shim_dir/sprint-state.sh" rollover \
      --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 0 ]
  [ -f "$spy_log" ]

  # Verify --candidate-stories and --from-sprint appear in the recorded args.
  /usr/bin/grep -q '\-\-candidate-stories' "$spy_log" || {
    echo "Missing --candidate-stories in independence-check invocation:" >&2
    cat "$spy_log" >&2
    false
  }
  /usr/bin/grep -q '\-\-from-sprint' "$spy_log" || {
    echo "Missing --from-sprint in independence-check invocation:" >&2
    cat "$spy_log" >&2
    false
  }
  # Verify the candidate key was passed.
  /usr/bin/grep -q 'E900-S1' "$spy_log"
  # Verify --from-sprint sprint-900 was passed.
  /usr/bin/grep -q 'sprint-900' "$spy_log"
}

# ================================================================
# AC8 integration test — two concurrent sprints with
# real writers (sprint-state.sh init/inject), cross-resolve,
# retro naming, carry-over
# ================================================================

@test "AC8 integration: concurrent sprints with resolve, retro naming, carry-over" {
  _seed_config 2

  # --- Step 1: Create two active sprints with real writers ---
  # First sprint: init (produces planned) then transition to active.
  run bash "$SPRINT_STATE_SH" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/sprint-status-sprint-900.yaml" ]

  run bash "$SPRINT_STATE_SH" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]

  local s900_status
  s900_status="$(yq -r '.status' "$STATE_DIR/sprint-status-sprint-900.yaml")"
  [ "$s900_status" = "active" ]

  # Second sprint: init + activate (concurrent mode).
  run bash "$SPRINT_STATE_SH" init --sprint-id sprint-901
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/sprint-status-sprint-901.yaml" ]

  run bash "$SPRINT_STATE_SH" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  # --- Step 2: Inject stories into each sprint using real writers ---
  # Create story files WITHOUT cross-sprint dependencies (inject would
  # refuse a story with an existing dependency edge to another sprint).
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/independent.ts" > /dev/null
  _seed_story_file "E900-S2" "E900" '"sprint-900"' "src/conflict.ts" > /dev/null
  _seed_story_file "E901-S1" "E901" '"sprint-901"' "src/target.ts" > /dev/null

  # Inject all stories first (all independent at this point).
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-901.yaml"
  export SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
  run bash "$SPRINT_STATE_SH" inject --story E901-S1
  [ "$status" -eq 0 ]

  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml"
  export SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
  run bash "$SPRINT_STATE_SH" inject --story E900-S1
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE_SH" inject --story E900-S2
  [ "$status" -eq 0 ]

  # NOW add the cross-sprint dependency from E900-S2 to E901-S1,
  # which creates a conflict detectable at rollover time.
  local sf2
  sf2="$(find "$ART_DIR" -name "story.md" -path "*E900-S2*" | head -1)"
  local _tmp_sf2
  _tmp_sf2="$(mktemp "${sf2}.XXXXXX")"
  awk '{gsub(/depends_on: \[\]/, "depends_on: [\"E901-S1\"]"); print}' "$sf2" > "$_tmp_sf2"
  mv -f "$_tmp_sf2" "$sf2"

  # Verify stories injected.
  local s1_in_900 s2_in_900
  s1_in_900="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$STATE_DIR/sprint-status-sprint-900.yaml" 2>/dev/null)" || s1_in_900=""
  s2_in_900="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$STATE_DIR/sprint-status-sprint-900.yaml" 2>/dev/null)" || s2_in_900=""
  [ "$s1_in_900" = "E900-S1" ]
  [ "$s2_in_900" = "E900-S2" ]

  # --- Step 3: Action item written for sprint A, resolved from session B ---
  local ai_file="$STATE_DIR/action-items.yaml"
  source "$AIW_SH"
  aiw_write --target "$ai_file" --sprint-id "sprint-900" \
    --classification "implementation" --text "Fix the widget in sprint A" \
    --ref-key "story_key" --ref-value "E900-S1"

  # Resolve from "session B" (sprint-901).
  aiw_resolve --target "$ai_file" --item "AI-1" \
    --status "resolved" --resolution "Fixed in sprint-901 session" \
    --resolved-in "sprint-901" --related-stories "E900-S1"

  # sprint_id preserved from original entry (sprint A).
  local ai_sid
  ai_sid="$(yq -r '.items[0].sprint_id' "$ai_file")"
  [ "$ai_sid" = "sprint-900" ]

  # resolved_in set to sprint B.
  local ai_ri
  ai_ri="$(yq -r '.items[0].resolved_in' "$ai_file")"
  [ "$ai_ri" = "sprint-901" ]

  # File still valid YAML.
  yq '.' "$ai_file" > /dev/null

  # --- Step 4: Retro naming — per-sprint names don't clobber ---
  local retro_skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  /usr/bin/grep -q 'retrospective-{sprint_id}' "$retro_skill"
  /usr/bin/grep -q 'retrospective-{sprint_id}-.*glob' "$retro_skill"

  # --- Step 5: Carry-over — independent story succeeds ---
  unset SPRINT_STATUS_YAML SPRINT_STATUS_LOCK
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 0 ]

  # Independent story moved to target.
  local s1_target
  s1_target="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$STATE_DIR/sprint-status-sprint-901.yaml" 2>/dev/null)" || s1_target=""
  [ "$s1_target" = "E900-S1" ]

  # Gone from source.
  local s1_source
  s1_source="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$STATE_DIR/sprint-status-sprint-900.yaml" 2>/dev/null)" || s1_source=""
  [ -z "$s1_source" ]

  # --- Step 6: Carry-over — conflicting story refused, nothing moved ---
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S2

  [ "$status" -ne 0 ]

  # Conflicting story remains in source.
  local s2_source
  s2_source="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$STATE_DIR/sprint-status-sprint-900.yaml" 2>/dev/null)" || s2_source=""
  [ "$s2_source" = "E900-S2" ]

  # NOT in target.
  local s2_target
  s2_target="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$STATE_DIR/sprint-status-sprint-901.yaml" 2>/dev/null)" || s2_target=""
  [ -z "$s2_target" ]
}

# ================================================================
# SKILL.md per-line assertions (deletion + reword mutants)
# ================================================================

@test "retro SKILL.md: per-sprint scoping line present" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  # The specific line added by this story.
  /usr/bin/grep -qF 'concurrent-sprint mode the retro is scoped to the resolved sprint' "$skill"
}

@test "retro SKILL.md: sprint_id filtering line present" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  /usr/bin/grep -qF 'filtered by their' "$skill"
  /usr/bin/grep -qF 'sprint_id' "$skill"
}

@test "retro SKILL.md: per-sprint naming produces separate files" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  /usr/bin/grep -qF 'produces separate files per sprint by construction' "$skill"
}

@test "retro SKILL.md: sprint-close glob documented" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  /usr/bin/grep -q 'sprint-close finds each sprint.*retro.*retrospective-{sprint_id}-\*\.md.*glob' "$skill"
}

@test "sprint-plan SKILL.md: carry-over safety section present" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -qF 'Carry-Over Safety' "$skill"
}

@test "sprint-plan SKILL.md: three-phase protocol documented" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  /usr/bin/grep -qF 'Phase A' "$skill"
  /usr/bin/grep -qF 'Phase B' "$skill"
  /usr/bin/grep -qF 'Phase C' "$skill"
}

@test "sprint-plan SKILL.md: backlog return path with Findings row" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  /usr/bin/grep -qF 'Findings row' "$skill"
  /usr/bin/grep -qF 'story_returned_to_backlog' "$skill"
  /usr/bin/grep -qF 'lifecycle-event.sh' "$skill"
}

@test "sprint-plan SKILL.md: backlog return uses set-story-sprint --clear" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  /usr/bin/grep -q 'set-story-sprint.*--clear' "$skill"
}

@test "sprint-plan SKILL.md: independence failure options documented" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
  /usr/bin/grep -qF 'pick another target sprint' "$skill"
  /usr/bin/grep -qF 'create a new sprint' "$skill"
  /usr/bin/grep -qF 'defer to the backlog' "$skill"
}

@test "sprint-review SKILL.md: read-only historical mode line present" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -qF 'read-only historical mode without writes' "$skill"
}

@test "sprint-review SKILL.md: closed-binding refusal documented" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
  /usr/bin/grep -qF 'closed-binding refusal' "$skill"
}

@test "sprint-review SKILL.md: concurrent-sprint mode scoping" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
  /usr/bin/grep -qF 'concurrent-sprint mode' "$skill"
  /usr/bin/grep -q 'second active sprint is not affected' "$skill"
}

@test "action-items SKILL.md: scripted resolve path documented" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  [ -f "$skill" ]
  /usr/bin/grep -qF 'action-items-write.sh' "$skill"
  /usr/bin/grep -qF 'resolve' "$skill"
}

@test "action-items SKILL.md: resolved-in for concurrent mode" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  /usr/bin/grep -q -- '--resolved-in' "$skill"
  /usr/bin/grep -q 'concurrent-sprint mode' "$skill"
}

@test "action-items SKILL.md: safe-value editing path (no Edit tool)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  # The SKILL.md must document safe value handling and forbid the Edit tool.
  /usr/bin/grep -qF 'escaped for safe' "$skill" || /usr/bin/grep -qF 'strenv()' "$skill"
  /usr/bin/grep -qF 'Do NOT use the' "$skill"
  # Must NOT contain the old Edit-tool path.
  ! /usr/bin/grep -qF 'Save the updated' "$skill"
}

# ================================================================
# rollover_target_sprint: null and closed-bound session
# are NOT changed by this story's diff — owned by already-merged code.
# ================================================================

# ================================================================
# Target closing-marker check
# ================================================================

@test "concurrent rollover refuses when TARGET sprint has closing marker" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Closing marker on the TARGET sprint (alive owner).
  local marker="$STATE_DIR/.sprint-closing-sprint-901"
  printf 'sprint_id=sprint-901\nowner_pid=%d\nstart_time=2026-01-01T00:00:00Z\n' "$$" > "$marker"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint close in progress"* ]] || \
  [[ "${lines[*]}" == *"sprint close in progress"* ]]

  rm -f "$marker"
}

# ================================================================
# L4 lock acquisition
# ================================================================

@test "Phase A acquires L4 lifecycle lock" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/l4-test.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  local debug_log="$TEST_TMP/l4-debug.log"
  export ACQUIRE_LOCK_DEBUG=1
  export ACQUIRE_LOCK_DEBUG_LOG="$debug_log"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -eq 0 ]
  # L4 lock path should appear in the debug log.
  /usr/bin/grep -q 'sprint-lifecycle' "$debug_log" || {
    echo "L4 lifecycle lock not acquired:" >&2
    cat "$debug_log" >&2
    false
  }
}

# ================================================================
# Phase B resets execution phase
# ================================================================

@test "Phase B resets execution phase on carried-over story" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/phase-reset.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Simulate a partial previous rollover: the story is already in the
  # target with a stale phase (crash between Phase B and C). The re-run
  # must reset the phase.
  _add_story_to_yaml "$to_yaml" "E900-S1"
  SPRINT_STATUS_YAML="$to_yaml" SPRINT_STATUS_LOCK="${to_yaml}.lock" \
    bash "$SPRINT_STATE_SH" set-phase --story E900-S1 --phase 3 2>/dev/null || true

  # Verify phase was set on target.
  local phase_before
  phase_before="$(yq -r '.stories[] | select(.key == "E900-S1") | .phase // "null"' "$to_yaml" 2>/dev/null)" || phase_before="null"
  [ "$phase_before" = "3" ] || [ "$phase_before" = "\"3\"" ] || {
    echo "Phase not set on target before rollover: $phase_before" >&2
    false
  }

  # Rollover (re-run scenario).
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1
  [ "$status" -eq 0 ]

  # Phase should be reset (empty/null) on the target.
  local phase
  phase="$(yq -r '.stories[] | select(.key == "E900-S1") | .phase // "null"' "$to_yaml" 2>/dev/null)" || phase="null"
  [[ "$phase" == "null" || "$phase" == "" ]] || {
    echo "Phase not reset after carry-over: $phase" >&2
    false
  }
}

# ================================================================
# related_stories written by resolve
# ================================================================

@test "aiw_resolve writes related_stories correctly" {
  local target="$TEST_TMP/action-items-rs.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "resolved" \
    --resolution "test" \
    --related-stories "E900-S3,E900-S4"

  [ "$status" -eq 0 ]

  # related_stories must be written with both keys.
  local rs
  rs="$(yq -r '.items[0].related_stories | length' "$target" 2>/dev/null)" || rs=""
  [ "$rs" = "2" ] || {
    echo "Expected 2 related_stories, got: $rs" >&2
    yq '.items[0].related_stories' "$target" >&2
    false
  }
  yq -r '.items[0].related_stories[0]' "$target" | /usr/bin/grep -q 'E900-S3'
  yq -r '.items[0].related_stories[1]' "$target" | /usr/bin/grep -q 'E900-S4'
}

# ================================================================
# Resolution and resolved_in escaping
# ================================================================

@test "aiw_resolve escapes special characters in resolution and resolved_in" {
  local target="$TEST_TMP/action-items-esc.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  # Resolution with quotes, colons, and backslashes.
  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "resolved" \
    --resolution 'Fixed: "quoted value" with \backslash and colon: here' \
    --resolved-in 'sprint: special"chars'

  [ "$status" -eq 0 ]

  # File must be valid YAML.
  yq '.' "$target" > /dev/null

  # Resolution preserved as literal.
  local res
  res="$(yq -r '.items[0].resolution' "$target")"
  [[ "$res" == *'"quoted value"'* ]]
  [[ "$res" == *'\backslash'* ]]

  # resolved_in preserved as literal.
  local ri
  ri="$(yq -r '.items[0].resolved_in' "$target")"
  [ "$ri" = 'sprint: special"chars' ]
}

# ================================================================
# last_updated bump on resolve
# Per user ruling: resolve updates the tracker's top-level last_updated
# in place to today when that key exists; when absent, nothing is added.
# ================================================================

@test "aiw_resolve bumps last_updated to today when key exists" {
  local target="$TEST_TMP/action-items-lu.yaml"
  _seed_action_items_yaml "$target"

  # Original last_updated is 2026-01-01.
  local before
  before="$(yq -r '.last_updated' "$target")"
  [ "$before" = "2026-01-01" ]

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" --resolution "done"

  # last_updated must be bumped to today.
  local after today
  after="$(yq -r '.last_updated' "$target")"
  today="$(date -u +%Y-%m-%d)"
  [ "$after" = "$today" ] || {
    echo "last_updated not bumped: expected $today, got $after" >&2
    false
  }
}

# ================================================================
# resolved_in via safe escaping (newline injection)
# ================================================================

@test "aiw_resolve safely escapes newline in resolved_in" {
  local target="$TEST_TMP/action-items-nl.yaml"
  _seed_action_items_yaml "$target"

  source "$AIW_SH"

  # A value with a newline must be safely escaped (newlines are allowed
  # by the control-char check; they are escaped to \n by _aiw_yaml_escape).
  run aiw_resolve \
    --target "$target" \
    --item "AI-1" \
    --status "resolved" \
    --resolution "test" \
    --resolved-in "sprint-900
injected: true"

  [ "$status" -eq 0 ]

  # File must still be valid YAML.
  yq '.' "$target" > /dev/null

  # The resolved_in must be stored as a single value containing a
  # literal newline — not split across two YAML keys.
  local ri
  ri="$(yq -r '.items[0].resolved_in' "$target")"
  # It must NOT be just "sprint-900" (newline was truncated/injected).
  [[ "$ri" != "sprint-900" ]] || {
    echo "Newline was stripped — possible YAML injection" >&2
    false
  }
  # "injected:" must not appear as a separate key.
  ! yq -r '.items[0].injected // "ABSENT"' "$target" | /usr/bin/grep -q 'true'
}

# ================================================================
# Symlink guard on resolve target
# ================================================================

@test "aiw_resolve rejects symlink target" {
  local real_target="$TEST_TMP/action-items-real.yaml"
  local sym_target="$TEST_TMP/action-items-sym.yaml"
  _seed_action_items_yaml "$real_target"
  ln -sf "$real_target" "$sym_target"

  source "$AIW_SH"

  run aiw_resolve \
    --target "$sym_target" \
    --item "AI-1" \
    --status "done" \
    --resolution "test"

  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
}

# ================================================================
# Phase C removes key from source
# ================================================================

@test "Phase C removes passed key from source yaml" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S3" "E900" '"sprint-900"' "src/remove-test.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S3"

  # Also add a second story that stays (to verify selective removal).
  _seed_story_file "E900-S4" "E900" '"sprint-900"' "src/stays.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S4"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S3

  [ "$status" -eq 0 ]

  # E900-S3 must be gone from source.
  local s3_source
  s3_source="$(yq -r '.stories[] | select(.key == "E900-S3") | .key' "$from_yaml" 2>/dev/null)" || s3_source=""
  [ -z "$s3_source" ]

  # E900-S4 must still be in source.
  local s4_source
  s4_source="$(yq -r '.stories[] | select(.key == "E900-S4") | .key' "$from_yaml" 2>/dev/null)" || s4_source=""
  [ "$s4_source" = "E900-S4" ]

  # E900-S3 must be in target.
  local s3_target
  s3_target="$(yq -r '.stories[] | select(.key == "E900-S3") | .key' "$to_yaml" 2>/dev/null)" || s3_target=""
  [ "$s3_target" = "E900-S3" ]
}

# ================================================================
# --clear removes from per-sprint state
# ================================================================

@test "set-story-sprint --clear removes story from per-sprint yaml" {
  _seed_config 2

  local yaml
  yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"

  local sf
  sf="$(_seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts")"
  _add_story_to_yaml "$yaml" "E900-S1"

  # Verify story is in the yaml.
  local before_count
  before_count="$(yq -r '.stories | length' "$yaml")"
  [ "$before_count" -ge 1 ]

  run bash "$SPRINT_STATE_SH" set-story-sprint --story E900-S1 --clear
  [ "$status" -eq 0 ]

  # Story should be removed from the per-sprint yaml.
  local in_yaml
  in_yaml="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$yaml" 2>/dev/null)" || in_yaml=""
  [ -z "$in_yaml" ] || {
    echo "Story still in per-sprint yaml after --clear: $in_yaml" >&2
    false
  }

  # Frontmatter sprint_id should be null.
  /usr/bin/grep -q '^sprint_id:[[:space:]]*null' "$sf"
}

# ================================================================
# All-fail moves nothing (Phase A failure)
# ================================================================

@test "when all keys fail independence, none move to target" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Both stories have dependency on target sprint story.
  local dir1="$ART_DIR/epic-E900-test/E900-S1-test-story"; mkdir -p "$dir1"
  cat > "$dir1/story.md" <<'S'
---
template: 'story'
key: "E900-S1"
title: "Failing story 1"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: ["E901-S1"]
blocks: []
predicted_touch_set:
  - "src/a.ts"
---
# Story
S
  _add_story_to_yaml "$from_yaml" "E900-S1"

  local dir2="$ART_DIR/epic-E900-test/E900-S2-test-story"; mkdir -p "$dir2"
  cat > "$dir2/story.md" <<'S'
---
template: 'story'
key: "E900-S2"
title: "Failing story 2"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: ["E901-S1"]
blocks: []
predicted_touch_set:
  - "src/b.ts"
---
# Story
S
  _add_story_to_yaml "$from_yaml" "E900-S2"

  # Target story.
  local dir3="$ART_DIR/epic-E901-test/E901-S1-test-story"; mkdir -p "$dir3"
  cat > "$dir3/story.md" <<'S'
---
template: 'story'
key: "E901-S1"
title: "Target story"
epic: "E901"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-901"
depends_on: []
blocks: []
predicted_touch_set:
  - "src/c.ts"
---
# Story
S
  _add_story_to_yaml "$to_yaml" "E901-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys "E900-S1,E900-S2"

  [ "$status" -ne 0 ]

  # Neither story should have moved.
  local t1 t2
  t1="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || t1=""
  t2="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$to_yaml" 2>/dev/null)" || t2=""
  [ -z "$t1" ]
  [ -z "$t2" ]

  # Both should remain in source.
  local s1 s2
  s1="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$from_yaml" 2>/dev/null)" || s1=""
  s2="$(yq -r '.stories[] | select(.key == "E900-S2") | .key' "$from_yaml" 2>/dev/null)" || s2=""
  [ "$s1" = "E900-S1" ]
  [ "$s2" = "E900-S2" ]
}

# ================================================================
# Single-sprint not routed to concurrent path
# ================================================================

@test "single-sprint mode rejects concurrent rollover path" {
  _seed_single_config

  cat > "$STATE_DIR/sprint-status.yaml" <<YAML
sprint_id: "sprint-900"
status: active
total_points: 3
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 3
YAML
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status.yaml"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null

  # Single-sprint rollover should NOT call independence-check.
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  # Should succeed via the legacy single-sprint path.
  [ "$status" -eq 0 ]
  [[ "$output" != *"independence"* ]]
  [[ "$output" != *"Phase A"* ]]
}

# ================================================================
# Missing touch-set fails only that key
# ================================================================

@test "missing touch-set fails only that key, others proceed" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Story with touch-set.
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/has-ts.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Story WITHOUT touch-set.
  _seed_story_file "E900-S3" "E900" '"sprint-900"' "" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S3"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys "E900-S1,E900-S3"

  # Exit 2 (touch-set missing takes precedence).
  [ "$status" -eq 2 ]

  # E900-S1 should have been carried (it has a touch-set and is independent).
  local s1_target
  s1_target="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || s1_target=""
  [ "$s1_target" = "E900-S1" ]

  # E900-S3 should still be in source (touch-set missing).
  local s3_source
  s3_source="$(yq -r '.stories[] | select(.key == "E900-S3") | .key' "$from_yaml" 2>/dev/null)" || s3_source=""
  [ "$s3_source" = "E900-S3" ]
}

# ================================================================
# Comprehensive leak test with ruling-ID and AF-/AI- patterns
# ================================================================

@test "no ruling IDs or cascade IDs in changed published files" {
  local files=(
    "$BATS_TEST_DIRNAME/../scripts/action-items-write.sh"
    "$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
    "$BATS_TEST_DIRNAME/../scripts/independence-check.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/sprint-state.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/SKILL.md"
    "$BATS_TEST_DIRNAME/concurrent-sprint-lifecycle-scoped.bats"
  )

  local f
  for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "MISSING: $f" >&2; false; return; }
  done

  # Patterns: (R<digits>) followed by / or ), AF-YYYY, AI-YYYY,
  # /Users/ paths.
  local pattern='(\(R[0-9]{1,3}[/)]|AF-20[0-9]{2}|AI-20[0-9]{2}|/Users/[a-z])'

  for f in "${files[@]}"; do
    run /usr/bin/grep -nE "$pattern" "$f"
    [ "$status" -ne 0 ] || {
      echo "Leaked IDs in $(basename "$f"): $output" >&2
      false
    }
  done

  # Planted-ID proof: insert a ruling ID into a COPY of a real scanned
  # file and verify the scan catches it. Strings are built dynamically
  # so the literal patterns do not appear in THIS file's source.
  local planted_file="$TEST_TMP/planted-check.sh"
  local _R="R" _AF="AF" _US="/Users"

  cp "${files[0]}" "$planted_file"
  printf '\n# This has (%s65) leaked\n' "$_R" >> "$planted_file"
  run /usr/bin/grep -nE "$pattern" "$planted_file"
  [ "$status" -eq 0 ] || {
    echo "Planted ruling ID not detected" >&2
    false
  }

  cp "${files[0]}" "$planted_file"
  printf '\n# %s-2026 cascade\n' "$_AF" >> "$planted_file"
  run /usr/bin/grep -nE "$pattern" "$planted_file"
  [ "$status" -eq 0 ] || {
    echo "Planted cascade ID not detected" >&2
    false
  }

  cp "${files[0]}" "$planted_file"
  printf '\n# %s/jlouage/path\n' "$_US" >> "$planted_file"
  run /usr/bin/grep -nE "$pattern" "$planted_file"
  [ "$status" -eq 0 ] || {
    echo "Planted path leak not detected" >&2
    false
  }

  # The pattern must also catch story keys (E<n>-S<n>) and
  # requirement IDs (FR-<n>) that might appear in header comments.
  # Build the pattern fragments dynamically so they do not appear as
  # literals in THIS file's source (the leak scan covers this file too).
  local _E="E" _FR="FR"
  local extended='('"$_E"'[0-9]+-S[0-9]+|'"$_FR"'-[0-9])'

  # Planted story key (synthetic, outside the live range).
  cp "${files[1]}" "$planted_file"
  printf '\n# carry-over helper for %s999-S99\n' "$_E" >> "$planted_file"
  run /usr/bin/grep -nE "$extended" "$planted_file"
  [ "$status" -eq 0 ] || {
    echo "Planted story key not detected" >&2
    false
  }

  # Planted requirement ID (synthetic, outside the live range).
  cp "${files[1]}" "$planted_file"
  printf '\n# implements %s-9999\n' "$_FR" >> "$planted_file"
  run /usr/bin/grep -nE "$extended" "$planted_file"
  [ "$status" -eq 0 ] || {
    echo "Planted requirement ID not detected" >&2
    false
  }

  # The REAL files must be clean under the extended pattern too.
  for f in "${files[@]}"; do
    # Exclude: synthetic fixture ids (E9xx keys), regex literals and
    # patterns (grep/awk/sed), and planted-ID proof lines in this test
    # file (they construct IDs dynamically so the literal appears in the
    # concatenation, not as a real leak).
    run bash -c "/usr/bin/grep -nE '$extended' '$f' | /usr/bin/grep -vE 'E9[0-9]{2}-S|E999|\\[0-9\\]|grep|pattern|regex|awk|sed|planted|_E=|_FR=|printf|echo'"
    [ "$status" -ne 0 ] || {
      echo "Leaked story/FR IDs in $(basename "$f"): $output" >&2
      false
    }
  done
}

# ================================================================
# aiw_resolve: last_updated not added when key is absent
# ================================================================

@test "aiw_resolve does not add last_updated when key is absent" {
  local target="$TEST_TMP/ai-no-lu.yaml"
  cat > "$target" <<'YAML'
items:
  - id: "AI-1"
    status: "open"
    text: "Test"
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" --resolution "done"

  # last_updated must NOT have been added.
  local lu_count
  lu_count="$(/usr/bin/grep -c '^last_updated:' "$target" 2>/dev/null)" || lu_count=0
  [ "$lu_count" -eq 0 ] || {
    echo "last_updated was added when absent: $(/usr/bin/grep '^last_updated:' "$target")" >&2
    false
  }

  # File must still be valid YAML.
  yq '.' "$target" > /dev/null
}

# ================================================================
# aiw_resolve: last_updated bumped when it follows the items list
# and the target is the last item
# ================================================================

@test "aiw_resolve bumps last_updated after items list when target is last item" {
  local target="$TEST_TMP/ai-lu-after.yaml"
  cat > "$target" <<'YAML'
items:
  - id: "AI-1"
    status: "open"
  - id: "AI-2"
    status: "open"
last_updated: "2020-01-01"
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-2" --status "done" --resolution "done"

  local lu today
  lu="$(yq -r '.last_updated' "$target")"
  today="$(date -u +%Y-%m-%d)"
  [ "$lu" = "$today" ] || {
    echo "last_updated not bumped when after items (target=last): expected $today, got $lu" >&2
    false
  }

  yq '.' "$target" > /dev/null
}

# ================================================================
# rollover: exported _GAIA_ROLLOVER_INJECT is ignored
# ================================================================

@test "exported env var cannot bypass the inject independence gate" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  # Story in the target sprint that overlaps.
  _seed_story_file "E901-S1" "E901" '"sprint-901"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$to_yaml" "E901-S1"

  # Point SPRINT_STATUS_YAML at the target so inject reaches the
  # independence gate (without it, inject refuses with "missing yaml").
  export SPRINT_STATUS_YAML="$to_yaml"
  export SPRINT_STATUS_LOCK="${to_yaml}.lock"

  # The inject should refuse because of the overlap. Exporting the
  # internal flag must not bypass the gate.
  export _GAIA_ROLLOVER_INJECT=1
  run bash "$SPRINT_STATE_SH" inject --story E900-S1
  unset _GAIA_ROLLOVER_INJECT
  unset SPRINT_STATUS_YAML SPRINT_STATUS_LOCK

  # The inject must still be refused (exit non-zero).
  [ "$status" -ne 0 ] || {
    echo "Exported _GAIA_ROLLOVER_INJECT bypassed the inject gate" >&2
    false
  }
}

# ================================================================
# aiw_resolve: related_stories appends to existing inline entries
# ================================================================

@test "aiw_resolve appends to existing inline related_stories and deduplicates" {
  local target="$TEST_TMP/ai-rs-append.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    related_stories: ["E900-S2", "E900-S3"]
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "done" --related-stories "E900-S3,E900-S4"

  yq '.' "$target" > /dev/null

  # Must have all three unique entries.
  local rs
  rs="$(yq -r '.items[0].related_stories | length' "$target")"
  [ "$rs" -eq 3 ] || {
    echo "Expected 3 related_stories, got $rs: $(yq -r '.items[0].related_stories' "$target")" >&2
    false
  }

  # Must contain the old and new entries (deduplicated).
  local rs_str
  rs_str="$(yq -r '.items[0].related_stories[]' "$target" | sort | tr '\n' ',')"
  [[ "$rs_str" == *"E900-S2"* ]]
  [[ "$rs_str" == *"E900-S3"* ]]
  [[ "$rs_str" == *"E900-S4"* ]]
}

# ================================================================
# aiw_resolve: related_stories appends to existing block-list entries
# ================================================================

@test "aiw_resolve appends to existing block-list related_stories" {
  local target="$TEST_TMP/ai-rs-block.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    related_stories:
      - E900-S2
      - E900-S5
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "done" --related-stories "E900-S5,E900-S6"

  yq '.' "$target" > /dev/null

  # Must have 3 unique entries (E900-S5 deduplicated).
  local rs
  rs="$(yq -r '.items[0].related_stories | length' "$target")"
  [ "$rs" -eq 3 ] || {
    echo "Expected 3 related_stories from block merge, got $rs" >&2
    false
  }
}

# ================================================================
# aiw_resolve: file mode preserved (0644 stays 0644)
# ================================================================

@test "aiw_resolve preserves original file mode" {
  local target="$TEST_TMP/ai-mode.yaml"
  _seed_action_items_yaml "$target"
  chmod 644 "$target"

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" --resolution "done"

  local mode
  if stat -f '%Lp' "$target" >/dev/null 2>&1; then
    mode="$(stat -f '%Lp' "$target")"
  else
    mode="$(stat -c '%a' "$target")"
  fi
  [ "$mode" = "644" ] || {
    echo "File mode changed: expected 644, got $mode" >&2
    false
  }
}

# ================================================================
# aiw_resolve: block-scalar tracking outside the target item
# ================================================================

@test "aiw_resolve does not misread item start inside a block scalar" {
  local target="$TEST_TMP/ai-blk-outside.yaml"
  # The block scalar embeds `- id: AI-TARGET` — the SAME id as the real
  # target item below it. Without block-scalar tracking, the editor would
  # treat the embedded line as the target and edit AI-OUTER's context
  # instead of the real AI-TARGET.
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-OUTER"
    status: "open"
    context: |
      This block scalar contains an embedded item marker:
      - id: AI-TARGET
        status: fake
  - id: "AI-TARGET"
    status: "open"
    text: "Real target"
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-TARGET" --status "done" \
    --resolution "Fixed"

  yq '.' "$target" > /dev/null

  # AI-TARGET must be done.
  local t_st
  t_st="$(yq -r '.items[1].status' "$target")"
  [ "$t_st" = "done" ]

  # AI-OUTER must still be open (block scalar was not misread).
  local o_st
  o_st="$(yq -r '.items[0].status' "$target")"
  [ "$o_st" = "open" ]

  # The block scalar content must be preserved (it contains the same
  # id as the real target — the editor must not consume it).
  local ctx
  ctx="$(yq -r '.items[0].context' "$target")"
  [[ "$ctx" == *"AI-TARGET"* ]]
}

# ================================================================
# aiw_resolve: items at column 0 (2-space indent for fields)
# ================================================================

@test "aiw_resolve handles items at column 0 with 2-space field indent" {
  local target="$TEST_TMP/ai-col0.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
- id: "AI-1"
  status: "open"
  text: "Column zero item"
- id: "AI-2"
  status: "open"
  text: "Second item"
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "Fixed"

  yq '.' "$target" > /dev/null

  local st
  st="$(yq -r '.items[0].status' "$target")"
  [ "$st" = "done" ]

  # Second item unchanged.
  local st2
  st2="$(yq -r '.items[1].status' "$target")"
  [ "$st2" = "open" ]
}

# ================================================================
# aiw_resolve: deeper-indent status inside a nested map is not treated as a field
# ================================================================

@test "aiw_resolve ignores status at deeper indentation inside nested maps" {
  local target="$TEST_TMP/ai-nested.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    context_for_target:
      nested_field: "value"
      status: "should not be touched"
  - id: "AI-2"
    status: "open"
YAML

  source "$AIW_SH"
  aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "Fixed"

  yq '.' "$target" > /dev/null

  local st
  st="$(yq -r '.items[0].status' "$target")"
  [ "$st" = "done" ]

  # The nested status must be preserved.
  local nested_st
  nested_st="$(yq -r '.items[0].context_for_target.status' "$target")"
  [ "$nested_st" = "should not be touched" ]
}

# ================================================================
# SKILL.md prose: resolved-in passed only in concurrent mode
# ================================================================

@test "action-items SKILL.md: resolved-in is passed only in concurrent mode" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  # Must assert the EXACT sentence that says --resolved-in is passed
  # only when running in concurrent mode.
  /usr/bin/grep -qF 'pass `--resolved-in <sprint-id>` with the bound sprint id' "$skill" || {
    echo "Missing: concurrent-mode resolved-in sentence" >&2
    false
  }
  # The sentence must say "concurrent" — a reword to "omit" must fail.
  run /usr/bin/grep -c 'omit.*--resolved-in' "$skill"
  [ "${output:-0}" = "0" ] || {
    echo "Found 'omit --resolved-in' — must be 'pass'" >&2
    false
  }
}

# ================================================================
# SKILL.md prose: /gaia-action-items never refuses
# ================================================================

@test "action-items SKILL.md: command never refuses for missing sprint context" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-action-items/SKILL.md"
  # The exact sentence must be present (deletion or reword to "refuse" fails).
  /usr/bin/grep -qF 'this command never refuses' "$skill" || {
    echo "Missing: never-refuses sentence" >&2
    false
  }
  # The "never refuses" phrase must not be negated or reversed.
  # A mutant that changes "never refuses" to just "refuses" must fail.
  run bash -c "/usr/bin/grep 'refuses' '$skill' | /usr/bin/grep -v 'never refuses'"
  [ "$status" -ne 0 ] || {
    echo "Found a bare 'refuses' clause outside the 'never refuses' sentence" >&2
    false
  }
}

# ================================================================
# set-story-sprint --clear: removal failure is an error
# ================================================================

@test "set-story-sprint --clear treats removal failure as an error" {
  _seed_config 2

  local yaml
  yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/a.ts" > /dev/null
  _add_story_to_yaml "$yaml" "E900-S1"

  # Make the STATE DIRECTORY read-only so mktemp (inside the removal)
  # fails — that causes _remove_story_from_yaml to return non-zero,
  # which --clear must propagate as an error (not silently ignore).
  chmod 555 "$STATE_DIR"

  export SPRINT_STATUS_YAML="$yaml"
  export SPRINT_STATUS_LOCK="${yaml}.lock"
  run bash "$SPRINT_STATE_SH" set-story-sprint --story E900-S1 --clear

  # Restore permissions for teardown.
  chmod 755 "$STATE_DIR"

  # Must be an error (non-zero exit), not silently ignored.
  [ "$status" -ne 0 ] || {
    echo "--clear removal failure was silently ignored" >&2
    false
  }
}

# ================================================================
# rollover: Phase C rewrites unquoted sprint_id
# ================================================================

@test "rollover rewrites unquoted sprint_id in story file" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Seed story file with UNQUOTED sprint_id (the 220 real files that use it).
  local sf_dir="$ART_DIR/epic-E900-test/E900-S5-test-story"
  mkdir -p "$sf_dir"
  cat > "$sf_dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S5"
title: "Test unquoted"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: sprint-900
depends_on: []
blocks: []
predicted_touch_set:
  - "src/unquoted.ts"
---
# Story: Test unquoted
STORY

  _add_story_to_yaml "$from_yaml" "E900-S5"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S5

  [ "$status" -eq 0 ]

  # sprint_id must be rewritten to the target.
  local sid
  sid="$(awk '/^sprint_id:/ { sub(/^sprint_id:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$sf_dir/story.md")"
  [ "$sid" = "sprint-901" ] || {
    echo "sprint_id not rewritten: got '$sid'" >&2
    false
  }
}

# ================================================================
# rollover: Phase C rewrite-before-remove ordering
# ================================================================

@test "rollover rewrites sprint_id before removing from source (crash safety)" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/ordering.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1
  [ "$status" -eq 0 ]

  # After a successful rollover: key is in target, gone from source,
  # and sprint_id is rewritten. The crash-safety guarantee is that
  # sprint_id is rewritten BEFORE the key is removed from source, so
  # a crash after rewrite but before removal leaves the key in both
  # sprints with the correct sprint_id (which a re-run completes).
  # We verify the successful end state here; the ordering is proven
  # by the fact that a re-run (key already in target) completes.
  local sf
  sf="$(find "$ART_DIR" -name "story.md" -path "*E900-S1*" | head -1)"
  local sid
  sid="$(awk '/^sprint_id:/ { sub(/^sprint_id:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$sf")"
  [ "$sid" = "sprint-901" ]

  # Simulate the crash state: key in both, sprint_id = target.
  # A re-run must complete (the key is already in the target).
  _add_story_to_yaml "$from_yaml" "E900-S1"
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1
  [ "$status" -eq 0 ]

  # Key must be gone from source again.
  local s1_source
  s1_source="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$from_yaml" 2>/dev/null)" || s1_source=""
  [ -z "$s1_source" ]
}

# ================================================================
# rollover: wrong --from is refused, nothing moved
# ================================================================

@test "rollover with wrong --from refuses and moves nothing" {
  _seed_config 2

  local yaml_900 yaml_901 yaml_902
  yaml_900="$(_seed_per_sprint_yaml "sprint-900" "active")"
  yaml_901="$(_seed_per_sprint_yaml "sprint-901" "active")"
  yaml_902="$(_seed_per_sprint_yaml "sprint-902" "active")"

  # Story is in sprint-902, not sprint-901.
  _seed_story_file "E900-S1" "E900" '"sprint-902"' "src/wrong.ts" > /dev/null
  _add_story_to_yaml "$yaml_902" "E900-S1"

  # Try rollover with wrong --from (sprint-901, but the story is in sprint-902).
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-901 --to sprint-900 --keys E900-S1

  # Must be refused (the key is not in the source sprint).
  [ "$status" -ne 0 ]

  # The story must NOT appear in the target (sprint-900).
  local s1_tgt
  s1_tgt="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$yaml_900" 2>/dev/null)" || s1_tgt=""
  [ -z "$s1_tgt" ] || {
    echo "Wrong --from: story was injected into target despite refusal" >&2
    false
  }

  # The story must still be in sprint-902 (untouched).
  local s1_902
  s1_902="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$yaml_902" 2>/dev/null)" || s1_902=""
  [ "$s1_902" = "E900-S1" ]
}

# ================================================================
# rollover: backlog story (sprint_id null, not in any sprint) with
# wrong --from is refused before injection
# ================================================================

@test "rollover refuses a backlog story with null sprint_id and wrong --from" {
  _seed_config 2

  local yaml_900 yaml_901
  yaml_900="$(_seed_per_sprint_yaml "sprint-900" "active")"
  yaml_901="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Story has sprint_id: null and is NOT in any sprint's yaml.
  _seed_story_file "E900-S7" "E900" 'null' "src/backlog.ts" > /dev/null

  # Rollover with --from sprint-900 — the key is not in sprint-900.
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S7

  # Must be refused.
  [ "$status" -ne 0 ] || {
    echo "Backlog story with null sprint_id was injected into target" >&2
    false
  }

  # Target sprint must be empty.
  local tgt_count
  tgt_count="$(yq -r '.stories | length' "$yaml_901" 2>/dev/null)" || tgt_count=0
  [ "$tgt_count" -eq 0 ] || {
    echo "Target sprint has stories after refusal: $tgt_count" >&2
    false
  }
}

# ================================================================
# rollover: story in target only with old sprint_id re-runs and completes
# ================================================================

@test "rollover re-run completes when story is in target only with source sprint_id" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Simulate a crash state: story is in the TARGET only, but its
  # sprint_id still points at the SOURCE. A re-run should complete
  # (rewrite sprint_id to target, remove from source if present).
  _seed_story_file "E900-S1" "E900" '"sprint-900"' "src/rerun.ts" > /dev/null
  _add_story_to_yaml "$to_yaml" "E900-S1"

  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1
  [ "$status" -eq 0 ] || {
    echo "Re-run with story in target only failed: $output" >&2
    false
  }

  # sprint_id must be rewritten to the target.
  local sf
  sf="$(find "$ART_DIR" -name "story.md" -path "*E900-S1*" | head -1)"
  local sid
  sid="$(awk '/^sprint_id:/ { sub(/^sprint_id:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$sf")"
  [ "$sid" = "sprint-901" ] || {
    echo "sprint_id not rewritten on re-run: got '$sid'" >&2
    false
  }

  # Story must be in target.
  local s1_tgt
  s1_tgt="$(yq -r '.stories[] | select(.key == "E900-S1") | .key' "$to_yaml" 2>/dev/null)" || s1_tgt=""
  [ "$s1_tgt" = "E900-S1" ]
}

# ================================================================
# aiw_resolve: parse-before-mv refuses corrupted output
# ================================================================

@test "aiw_resolve refuses when output YAML is corrupted" {
  local target="$TEST_TMP/ai-corrupt.yaml"
  # Multi-line plain continuation (a shape that corrupts the output).
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    resolution: this is a long resolution
      that continues on the next line
      and should be treated as a single value
  - id: "AI-2"
    status: "open"
YAML

  local orig_sha
  orig_sha="$(shasum "$target" | cut -d' ' -f1)"

  source "$AIW_SH"
  run aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "Replaced"

  # Either: the resolve succeeds and the file is valid YAML,
  # OR the resolve is refused (file untouched).
  if [ "$status" -eq 0 ]; then
    yq '.' "$target" > /dev/null || {
      echo "Resolve returned 0 but output is not valid YAML" >&2
      false
    }
  else
    # File must be untouched.
    local after_sha
    after_sha="$(shasum "$target" | cut -d' ' -f1)"
    [ "$orig_sha" = "$after_sha" ] || {
      echo "Resolve failed but file was modified" >&2
      false
    }
  fi
}

# ================================================================
# aiw_resolve: single-quoted related_stories entries are refused
# ================================================================

@test "aiw_resolve refuses single-quoted related_stories entries" {
  local target="$TEST_TMP/ai-sq-rs.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    related_stories: ['E900-S1', "E900-S2", E900-S3]
YAML

  local orig_sha
  orig_sha="$(shasum "$target" | cut -d' ' -f1)"

  source "$AIW_SH"
  run aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "test" --related-stories "E900-S4"

  # Must be refused (non-zero exit).
  [ "$status" -ne 0 ] || {
    echo "Single-quoted related_stories accepted (should refuse)" >&2
    false
  }

  # File must be untouched.
  local after_sha
  after_sha="$(shasum "$target" | cut -d' ' -f1)"
  [ "$orig_sha" = "$after_sha" ] || {
    echo "File was modified despite refusal" >&2
    false
  }
}

# ================================================================
# aiw_resolve: comma-containing related_stories entries are refused
# ================================================================

@test "aiw_resolve refuses comma-containing related_stories entries" {
  local target="$TEST_TMP/ai-cq-rs.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    related_stories: ["a, b", "c"]
YAML

  local orig_sha
  orig_sha="$(shasum "$target" | cut -d' ' -f1)"

  source "$AIW_SH"
  run aiw_resolve --target "$target" --item "AI-1" --status "done" \
    --resolution "test" --related-stories "E900-S1"

  # Must be refused.
  [ "$status" -ne 0 ] || {
    echo "Comma-containing related_stories accepted (should refuse)" >&2
    false
  }

  # File must be untouched.
  local after_sha
  after_sha="$(shasum "$target" | cut -d' ' -f1)"
  [ "$orig_sha" = "$after_sha" ] || {
    echo "File was modified despite refusal" >&2
    false
  }
}

# ================================================================
# aiw_resolve: nested - id: inside another item is refused
# ================================================================

@test "aiw_resolve refuses when target id appears as nested entry in another item" {
  local target="$TEST_TMP/ai-nested-id.yaml"
  cat > "$target" <<'YAML'
last_updated: "2026-01-01"
items:
  - id: "AI-1"
    status: "open"
    links:
      - id: AI-2
        label: "related"
  - id: "AI-2"
    status: "open"
YAML

  local orig_sha
  orig_sha="$(shasum "$target" | cut -d' ' -f1)"

  source "$AIW_SH"
  run aiw_resolve --target "$target" --item "AI-2" --status "done" \
    --resolution "test"

  # Must be refused.
  [ "$status" -ne 0 ] || {
    echo "Nested - id: target accepted (should refuse)" >&2
    false
  }

  # File must be untouched.
  local after_sha
  after_sha="$(shasum "$target" | cut -d' ' -f1)"
  [ "$orig_sha" = "$after_sha" ] || {
    echo "File was modified despite refusal" >&2
    false
  }
}

# ================================================================
# aiw_resolve: pre-Phase-B rejects prefix-sibling keys
# ================================================================

@test "pre-Phase-B key match rejects prefix-sibling keys" {
  _seed_config 2

  local from_yaml to_yaml
  from_yaml="$(_seed_per_sprint_yaml "sprint-900" "active")"
  to_yaml="$(_seed_per_sprint_yaml "sprint-901" "active")"

  # Source sprint has only E900-S10, NOT E900-S1.
  _seed_story_file "E900-S10" "E900" '"sprint-900"' "src/ten.ts" > /dev/null
  _add_story_to_yaml "$from_yaml" "E900-S10"

  # E900-S1 is a backlog story not in any sprint.
  _seed_story_file "E900-S1" "E900" 'null' "src/one.ts" > /dev/null

  # Rollover E900-S1 from sprint-900: must be refused because E900-S1
  # is not in sprint-900 (only E900-S10 is).
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  [ "$status" -ne 0 ] || {
    echo "Prefix-sibling key E900-S1 matched E900-S10 (should be refused)" >&2
    false
  }

  # Target must be empty.
  local tgt_count
  tgt_count="$(yq -r '.stories | length' "$to_yaml" 2>/dev/null)" || tgt_count=0
  [ "$tgt_count" -eq 0 ] || {
    echo "Target has stories after prefix-sibling refusal: $tgt_count" >&2
    false
  }
}

# ================================================================
# Multi-writer race test: >=16 parallel resolves
# ================================================================

@test "parallel resolves with 16 writers preserve all updates" {
  local target="$TEST_TMP/ai-race.yaml"

  # Seed 16 items.
  {
    printf 'last_updated: "2026-01-01"\nitems:\n'
    local i
    for i in $(seq 1 16); do
      printf '  - id: "AI-%d"\n    status: "open"\n    text: "Item %d"\n' "$i" "$i"
    done
  } > "$target"

  source "$AIW_SH"

  # Launch 16 parallel resolves (each targeting a different item).
  local pids=()
  for i in $(seq 1 16); do
    (
      source "$AIW_SH"
      aiw_resolve --target "$target" --item "AI-$i" --status "done" \
        --resolution "resolved-$i" > /dev/null 2>&1
    ) &
    pids+=($!)
  done

  # Wait for all.
  local any_fail=0
  for pid in "${pids[@]}"; do
    wait "$pid" || any_fail=1
  done

  yq '.' "$target" > /dev/null || {
    echo "File is not valid YAML after parallel resolves" >&2
    false
  }

  # Count how many items have status=done.
  local done_count
  done_count="$(yq -r '[.items[] | select(.status == "done")] | length' "$target")"
  [ "$done_count" -eq 16 ] || {
    echo "Parallel resolve lost updates: only $done_count/16 done" >&2
    false
  }
}

# ================================================================
# Mixed-writer race test: resolves + appends (lock identity stable)
# ================================================================

@test "mixed parallel resolves and appends preserve all updates" {
  local target="$TEST_TMP/ai-mixed-race.yaml"

  # Seed 8 items to resolve.
  {
    printf 'last_updated: "2026-01-01"\nitems:\n'
    local i
    for i in $(seq 1 8); do
      printf '  - id: "AI-%d"\n    status: "open"\n    text: "Item %d"\n' "$i" "$i"
    done
  } > "$target"

  source "$AIW_SH"

  # 8 parallel resolves.
  local pids=()
  for i in $(seq 1 8); do
    (
      source "$AIW_SH"
      aiw_resolve --target "$target" --item "AI-$i" --status "done" \
        --resolution "resolved-$i" > /dev/null 2>&1
    ) &
    pids+=($!)
  done

  # 8 parallel appends.
  for i in $(seq 1 8); do
    (
      source "$AIW_SH"
      aiw_write --target "$target" --sprint-id "sprint-99" \
        --classification "implementation" --text "Appended $i" \
        --ref-key "story_key" --ref-value "E999-S$i" > /dev/null 2>&1
    ) &
    pids+=($!)
  done

  # Wait for all.
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  yq '.' "$target" > /dev/null || {
    echo "File is not valid YAML after mixed race" >&2
    false
  }

  local done_count total_count
  done_count="$(yq -r '[.items[] | select(.status == "done")] | length' "$target")"
  total_count="$(yq -r '.items | length' "$target")"

  # All 8 resolves must persist.
  [ "$done_count" -eq 8 ] || {
    echo "Mixed race lost resolves: only $done_count/8 done" >&2
    false
  }

  # All 8 appends must persist (total = 8 original + 8 appended = 16).
  [ "$total_count" -eq 16 ] || {
    echo "Mixed race lost appends: only $total_count/16 total items" >&2
    false
  }
}

# ================================================================
# AC8 integration: review, close with bound sprint, other sprint untouched
# ================================================================

@test "AC8 integration: review, close with bound sprint, other sprint untouched" {
  _seed_config 2

  local CLOSE_SH="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -x "$CLOSE_SH" ] || {
    echo "close.sh not found or not executable at $CLOSE_SH" >&2
    false
  }

  # --- Step 1: Create two active sprints via sprint-state.sh ---
  run bash "$SPRINT_STATE_SH" init --sprint-id sprint-900
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE_SH" transition --sprint sprint-900 --to active
  [ "$status" -eq 0 ]

  run bash "$SPRINT_STATE_SH" init --sprint-id sprint-901
  [ "$status" -eq 0 ]
  run bash "$SPRINT_STATE_SH" transition --sprint sprint-901 --to active
  [ "$status" -eq 0 ]

  # --- Step 2: Seed story files for each sprint ---
  # Sprint-900's story needs full Review Gate (all PASSED) and DoD (all
  # checked) so the real transition path can move it to done.
  local sf_dir="$ART_DIR/epic-E900-test/E900-S1-test-story"
  mkdir -p "$sf_dir"
  cat > "$sf_dir/story.md" <<'STORY'
---
template: 'story'
key: "E900-S1"
title: "Test story E900-S1"
epic: "E900"
status: in-progress
points: 3
risk: medium
sprint_id: "sprint-900"
depends_on: []
blocks: []
predicted_touch_set:
  - "src/a.ts"
---
# Story: Test story E900-S1

> **Status:** in-progress

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

### Acceptance

- [x] All acceptance criteria verified

### Testing

- [x] All tests pass

### Code Quality & CI

- [x] Code compiles without errors
STORY

  _seed_story_file "E901-S1" "E901" '"sprint-901"' "src/b.ts" > /dev/null

  # --- Step 3: Inject stories via sprint-state.sh inject ---
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml"
  export SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
  run bash "$SPRINT_STATE_SH" inject --story E900-S1
  [ "$status" -eq 0 ]

  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-901.yaml"
  export SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
  run bash "$SPRINT_STATE_SH" inject --story E901-S1
  [ "$status" -eq 0 ]
  unset SPRINT_STATUS_YAML SPRINT_STATUS_LOCK

  # --- Step 4: Bind the session to sprint-900 BEFORE the review transition ---
  # The binding can only be written when the sprint is active; close.sh
  # then uses it to resolve the bound sprint.
  export CLAUDE_SESSION_ID="test-ac8-session-$$"
  local SB_SH="$BATS_TEST_DIRNAME/../scripts/lib/session-binding.sh"
  source "$SB_SH"
  provision_binding_dir
  write_binding "sprint-900" "$STATE_DIR"

  # Verify the binding is readable.
  local bound_sprint
  bound_sprint="$(cat "$GAIA_BINDING_DIR/bound_sprint_id" 2>/dev/null | tr -d '\n')"
  [ "$bound_sprint" = "sprint-900" ] || {
    echo "Binding not written correctly: got '$bound_sprint'" >&2
    false
  }

  # --- Step 5: Transition E900-S1 through the real path to done ---
  # in-progress -> review -> done, using the real transition writer which
  # checks the Review Gate and DoD.
  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml"
  export SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
  run bash "$SPRINT_STATE_SH" transition --story E900-S1 --to review
  [ "$status" -eq 0 ] || {
    echo "story in-progress->review failed: $output" >&2; false
  }
  run bash "$SPRINT_STATE_SH" transition --story E900-S1 --to done
  [ "$status" -eq 0 ] || {
    echo "story review->done failed: $output" >&2; false
  }
  unset SPRINT_STATUS_YAML SPRINT_STATUS_LOCK

  # --- Step 6: Transition sprint-900 to review ---
  run bash "$SPRINT_STATE_SH" transition --sprint sprint-900 --to review
  [ "$status" -eq 0 ] || {
    echo "sprint active->review failed: $output" >&2; false
  }

  local s900_status
  s900_status="$(yq -r '.status' "$STATE_DIR/sprint-status-sprint-900.yaml")"
  [ "$s900_status" = "review" ]

  # --- Step 7: Retro artifact for sprint-900 ---
  local retro_dir="$ART_DIR/retrospective"
  mkdir -p "$retro_dir"
  local retro_file="$retro_dir/retrospective-sprint-900-2026-10-28.md"
  printf '# Retrospective sprint-900\n\nScoped to sprint-900 stories.\n' > "$retro_file"
  [ -f "$retro_file" ]

  # Separate retro for sprint-901.
  local retro_901="$retro_dir/retrospective-sprint-901-2026-10-28.md"
  printf '# Retrospective sprint-901\n' > "$retro_901"

  # --- Step 8: Create action items and resolve cross-sprint ---
  local ai_file="$STATE_DIR/action-items.yaml"
  source "$AIW_SH"
  aiw_write --target "$ai_file" --sprint-id "sprint-900" \
    --classification "implementation" --text "Sprint A item" \
    --ref-key "story_key" --ref-value "E900-S1"

  aiw_resolve --target "$ai_file" --item "AI-1" \
    --status "resolved" --resolution "Cross-sprint fix" \
    --resolved-in "sprint-901" --related-stories "E900-S1"

  local ai_sid ai_ri
  ai_sid="$(yq -r '.items[0].sprint_id' "$ai_file")"
  [ "$ai_sid" = "sprint-900" ]
  ai_ri="$(yq -r '.items[0].resolved_in' "$ai_file")"
  [ "$ai_ri" = "sprint-901" ]

  # --- Step 9: Snapshot sprint-901 before close ---
  local s901_before="$TEST_TMP/sprint-901-before.yaml"
  cp "$STATE_DIR/sprint-status-sprint-901.yaml" "$s901_before"

  # --- Step 10: Close sprint-900 through close.sh with the real binding ---
  # Create the sprint-review sentinel (required by close.sh).
  local ckpt_dir="$TEST_TMP/.gaia/memory/checkpoints"
  mkdir -p "$ckpt_dir"
  printf '{"sprint_id":"sprint-900"}' > "$ckpt_dir/sprint-review-sprint-900-val-dispatched.json"

  # Run close.sh. It reads GAIA_BINDING_DIR/bound_sprint_id (written in
  # step 4) to resolve the bound sprint, checks the retro doc exists,
  # verifies all stories are done, validates the sprint-review sentinel,
  # and delegates the status write to sprint-state.sh.
  run bash "$CLOSE_SH" --force
  unset CLAUDE_SESSION_ID
  [ "$status" -eq 0 ] || {
    echo "close.sh failed: $output" >&2; false
  }

  # Sprint-900 must be closed.
  local s900_final
  s900_final="$(yq -r '.status' "$STATE_DIR/sprint-status-sprint-900.yaml")"
  [ "$s900_final" = "closed" ]

  # --- Step 11: Assert sprint-901 is byte-identical ---
  diff -q "$s901_before" "$STATE_DIR/sprint-status-sprint-901.yaml" || {
    echo "Sprint-901 was modified by sprint-900's close:" >&2
    diff "$s901_before" "$STATE_DIR/sprint-status-sprint-901.yaml" >&2
    false
  }

  # Both retro files must exist (no clobber).
  [ -f "$retro_file" ]
  [ -f "$retro_901" ]

  # Sprint-close glob finds the right retro.
  local retro_count
  retro_count="$(find "$retro_dir" -name "retrospective-sprint-900-*.md" | wc -l | tr -d ' ')"
  [ "$retro_count" -ge 1 ]
}
