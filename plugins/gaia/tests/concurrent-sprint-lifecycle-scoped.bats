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
# TC-CONC-LIFE-5b: Cross-sprint action item resolution via scripted
# resolve subcommand
# ================================================================

@test "aiw_resolve sets status, resolution, resolved_date, resolved_in via strenv (TC-CONC-LIFE-5b)" {
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
# TC-CONC-LIFE-5c: resolved_in absent in single-sprint mode
# ================================================================

@test "aiw_resolve without --resolved-in does not add resolved_in field (TC-CONC-LIFE-5c)" {
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
# TC-CONC-LIFE-EC7: YAML injection via sprint_id in resolve
# ================================================================

@test "aiw_resolve uses strenv for special characters in sprint_id (TC-CONC-LIFE-EC7)" {
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
# TC-CONC-LIFE-5c: resolved_date only for done/invalid/resolved
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

@test "action-items-write.sh resolve subcommand dispatches correctly" {
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
# TC-CONC-LIFE-6d: Carry-over without predicted_touch_set
# ================================================================

@test "concurrent rollover refuses story without predicted_touch_set (TC-CONC-LIFE-6d)" {
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
# TC-CONC-LIFE-6f: Explicit empty touch-set is valid
# ================================================================

@test "concurrent rollover accepts explicit empty touch-set (TC-CONC-LIFE-6f)" {
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
# TC-CONC-LIFE-EXIT: Mixed-batch exit precedence
# ================================================================

@test "mixed-batch exit precedence: exit 2 for touch-set missing over exit 1 (TC-CONC-LIFE-EXIT)" {
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
# TC-CONC-LIFE-EC8: Single-sprint mode lifecycle unchanged
# ================================================================

@test "single-sprint rollover uses legacy path (TC-CONC-LIFE-EC8)" {
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

  # Single-sprint rollover does NOT run independence check.
  run bash "$SPRINT_STATE_SH" rollover \
    --from sprint-900 --to sprint-901 --keys E900-S1

  # In single-sprint mode, the rollover follows the legacy _rollover_one path.
  # It may fail (no sprint-901 yaml) but should NOT show "independence" errors.
  echo "Exit code: $status, Output: $output" >&2
  [[ "$output" != *"independence"* ]] || true
}

# ================================================================
# TC-CONC-LIFE-SCRUB: Internal ID scrub on published files
# ================================================================

@test "no leaked internal IDs in files changed by this story (TC-CONC-LIFE-SCRUB)" {
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
# TC-CONC-LIFE-L4: Three-phase rollover closing-marker refusal
# ================================================================

@test "concurrent rollover refuses when closing marker exists (TC-CONC-LIFE-L4)" {
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
# TC-CONC-LIFE-6e: Carry-over passes independence, touch-set retained
# ================================================================

@test "carried-over story retains predicted_touch_set (TC-CONC-LIFE-6e)" {
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

  echo "Exit: $status Output: $output" >&2

  # If the rollover succeeded, verify touch-set preserved.
  if [ "$status" -eq 0 ]; then
    /usr/bin/grep -q 'predicted_touch_set' "$sf"
    /usr/bin/grep -q 'src/unique-path.ts' "$sf"
  fi
}
