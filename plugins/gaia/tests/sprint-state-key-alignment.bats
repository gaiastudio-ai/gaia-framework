#!/usr/bin/env bats
# sprint-state-key-alignment.bats — behavioral tests for the items-to-stories
# key alignment and legacy migration.
#
# Every test creates its own temp project layout, runs the REAL sprint-state.sh
# entry point, and asserts observable behavior (not grep patterns).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SPRINT_STATE="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
RESOLVE_SPRINT_STORIES="$BATS_TEST_DIRNAME/../skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"

# _setup_project — scaffold a minimal project tree in TEST_TMP.
_setup_project() {
  mkdir -p "$TEST_TMP/project/.gaia/state"
  mkdir -p "$TEST_TMP/project/.gaia/config"
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/planning-artifacts"
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/test-artifacts"
  mkdir -p "$TEST_TMP/project/.gaia/memory"
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" <<'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
YAML
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP/project"
  export PROJECT_PATH="$TEST_TMP/project"
  export SPRINT_STATUS_YAML="$TEST_TMP/project/.gaia/state/sprint-status.yaml"
}

# _create_story_file KEY TITLE STATUS SPRINT_ID [POINTS] [RISK]
_create_story_file() {
  local key="$1" title="$2" status="$3" sprint_id="$4"
  local points="${5:-2}" risk="${6:-medium}"
  local epic
  epic=$(printf '%s' "$key" | sed 's/-S[0-9]*//')
  local dir="$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-${epic}/${key}-${title// /-}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "${title}"
status: "${status}"
sprint_id: "${sprint_id}"
points: ${points}
risk: "${risk}"
epic: "${epic}"
---
# Story: ${title}
EOF
}

# _legacy_yaml — create a legacy sprint-status.yaml with stories under items:
_legacy_yaml() {
  local sprint_id="$1" status="$2"
  shift 2
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'items:\n'
    while [ $# -gt 0 ]; do
      local key="$1" s_status="$2"
      shift 2
      printf '  - key: "%s"\n' "$key"
      printf '    title: '\''story %s'\''\n' "$key"
      printf '    status: "%s"\n' "$s_status"
      printf '    points: 2\n'
      printf '    risk_level: "medium"\n'
      printf '    assignee: null\n'
      printf '    blocked_by: null\n'
      printf '    updated: "2026-01-01"\n'
    done
  } > "$SPRINT_STATUS_YAML"
}

# _both_keys_yaml SPRINT STATUS ORDER
#   ORDER=items-first | stories-first
#   Creates a yaml with:
#     items: E900-S1 (in-progress), E900-S3 (ready-for-dev)  [items-only key]
#     stories: E900-S1 (done), E900-S2 (ready-for-dev)       [stories-only key]
#   E900-S1 appears in BOTH blocks (stories version should win).
_both_keys_yaml() {
  local sprint_id="$1" s="$2" order="${3:-items-first}"
  local items_block stories_block
  items_block="$(cat <<'ITEMS'
items:
  - key: "E900-S1"
    title: 'item story one'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
  - key: "E900-S3"
    title: 'item story three'
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
ITEMS
)"
  stories_block="$(cat <<'STORIES'
stories:
  - key: "E900-S1"
    title: 'stories story one'
    status: "done"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
  - key: "E900-S2"
    title: 'stories story two'
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
STORIES
)"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$s"
    printf 'total_points: 6\n'
    printf 'goals:\n  - "goal one"\n'
    if [ "$order" = "items-first" ]; then
      printf '%s\n%s\n' "$items_block" "$stories_block"
    else
      printf '%s\n%s\n' "$stories_block" "$items_block"
    fi
  } > "$SPRINT_STATUS_YAML"
}

setup() {
  common_setup
  _setup_project
}

teardown() {
  # Clean up any lock holders started by _start_holder.
  if [ -f "${TEST_TMP:-}/holder_pids" ]; then
    while IFS= read -r _hpid; do
      kill "$_hpid" 2>/dev/null || true
      wait "$_hpid" 2>/dev/null || true
    done < "$TEST_TMP/holder_pids"
  fi
  common_teardown
}

# ---------------------------------------------------------------------------
# AC1 — init seeds stories: not items:
# ---------------------------------------------------------------------------
@test "init seeds stories key, not items key" {
  run bash "$SPRINT_STATE" init --sprint-id sprint-999
  [ "$status" -eq 0 ]
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
  grep -q '^sprint_id:' "$SPRINT_STATUS_YAML"
  grep -q '^status: planned' "$SPRINT_STATUS_YAML"
  grep -q '^total_points: 0' "$SPRINT_STATUS_YAML"
  grep -q '^goals:' "$SPRINT_STATUS_YAML"
}

# ---------------------------------------------------------------------------
# AC3 — migration: inject onto legacy items-only file
# ---------------------------------------------------------------------------
@test "inject onto legacy items-only file migrates and appends" {
  _legacy_yaml sprint-inj active \
    "E900-S1" "in-progress" \
    "E900-S2" "ready-for-dev"
  _create_story_file E900-S1 "story one" in-progress sprint-inj
  _create_story_file E900-S2 "story two" ready-for-dev sprint-inj
  _create_story_file E900-S3 "story three" ready-for-dev sprint-inj

  # Inject a new story — the migration runs before inject touches the file.
  run bash "$SPRINT_STATE" inject --story E900-S3
  [ "$status" -eq 0 ]

  # After migration+inject: all three stories under stories:, no items: key.
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
  # All three keys present.
  grep -q '"E900-S1"' "$SPRINT_STATUS_YAML"
  grep -q '"E900-S2"' "$SPRINT_STATUS_YAML"
  grep -q '"E900-S3"' "$SPRINT_STATUS_YAML"
}

# ---------------------------------------------------------------------------
# AC3 — migration: detect-auto-close sees migrated entries
# ---------------------------------------------------------------------------
@test "detect-auto-close sees non-done story under legacy items key" {
  _legacy_yaml sprint-dac active \
    "E900-S1" "in-progress" \
    "E900-S2" "done"
  _create_story_file E900-S1 "story one" in-progress sprint-dac
  _create_story_file E900-S2 "story two" "done" sprint-dac

  # detect-auto-close should find the non-done story and NOT recommend close.
  run bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -eq 0 ]
  # The output must NOT say "auto_close_eligible: true" — the in-progress story
  # under the legacy items: key must be visible to the done-check.
  [[ "$output" != *"auto_close_eligible: true"* ]] || false
  # Non-vacuous: confirm the yaml was migrated (items: -> stories:) so the
  # done-check actually inspected the entries rather than vacuously passing.
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — migration: transition --sprint gate refuses when non-done
# ---------------------------------------------------------------------------
@test "transition --sprint gate sees migrated non-done story under items key" {
  _legacy_yaml sprint-gate active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "story one" in-progress sprint-gate

  # Transition to review should be refused because E900-S1 is not done.
  run --separate-stderr bash "$SPRINT_STATE" transition --sprint sprint-gate --to review
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — migration: reconcile sees migrated entries
# ---------------------------------------------------------------------------
@test "reconcile processes migrated entries from legacy items key" {
  _legacy_yaml sprint-rec active \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "story one" ready-for-dev sprint-rec

  # Reconcile should find the story and process it.
  run bash "$SPRINT_STATE" reconcile --sprint-id sprint-rec
  [ "$status" -eq 0 ]
  # After reconcile, items: should be migrated to stories:.
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — triage reader sees migrated entries
# ---------------------------------------------------------------------------
@test "triage reader finds stories from legacy items-only file" {
  _legacy_yaml sprint-tri active \
    "E900-S1" "in-progress" \
    "E900-S2" "ready-for-dev"
  _create_story_file E900-S1 "story one" in-progress sprint-tri
  _create_story_file E900-S2 "story two" ready-for-dev sprint-tri

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false
  [[ "$output" == *"E900-S2"* ]] || false
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC4 — 20 stories round-trip
# ---------------------------------------------------------------------------
@test "triage finds all 20 stories after init and inject" {
  run bash "$SPRINT_STATE" init --sprint-id sprint-test
  [ "$status" -eq 0 ]

  local i key
  for i in $(seq 1 20); do
    key="E900-S${i}"
    _create_story_file "$key" "test story ${i}" ready-for-dev sprint-test
    run bash "$SPRINT_STATE" inject --story "$key"
    [ "$status" -eq 0 ]
  done

  run bash "$SPRINT_STATE" transition --sprint sprint-test --to active
  [ "$status" -eq 0 ]

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]

  local count
  count=$(printf '%s\n' "$output" | grep -c '.' || true)
  [ "$count" -eq 20 ]

  for i in $(seq 1 20); do
    [[ "$output" == *"E900-S${i}"* ]] || false
  done
}

# ---------------------------------------------------------------------------
# AC5a — fresh init creates stories: not items:
# ---------------------------------------------------------------------------
@test "fresh init creates stories key (AC5a)" {
  run bash "$SPRINT_STATE" init --sprint-id sprint-fresh
  [ "$status" -eq 0 ]
  grep -q '^stories: \[\]' "$SPRINT_STATUS_YAML"
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC5b — legacy items-only file: reader finds stories
# ---------------------------------------------------------------------------
@test "triage reader finds story in legacy items-only file (AC5b)" {
  _legacy_yaml sprint-5b active \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "legacy story" ready-for-dev sprint-5b

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false
}

# ---------------------------------------------------------------------------
# AC5c — both keys: items-before-stories order
# ---------------------------------------------------------------------------
@test "both keys (items before stories) — all entries found after migration" {
  _create_story_file E900-S1 "items story" in-progress sprint-both
  _create_story_file E900-S2 "stories story" ready-for-dev sprint-both

  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-both"
status: active
total_points: 4
goals: []
items:
  - key: "E900-S1"
    title: 'items story'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
stories:
  - key: "E900-S2"
    title: 'stories story'
    status: "ready-for-dev"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  # After migration: both stories present (items entries merged into stories).
  [[ "$output" == *"E900-S1"* ]] || false
  [[ "$output" == *"E900-S2"* ]] || false
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC5c — both keys: stories-before-items order
# ---------------------------------------------------------------------------
@test "both keys (stories before items) — all entries found after migration" {
  _create_story_file E900-S1 "stories story" ready-for-dev sprint-rev
  _create_story_file E900-S2 "items story" in-progress sprint-rev

  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-rev"
status: active
total_points: 4
goals: []
stories:
  - key: "E900-S1"
    title: 'stories story'
    status: "ready-for-dev"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
items:
  - key: "E900-S2"
    title: 'items story'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  # After migration: both stories present.
  [[ "$output" == *"E900-S1"* ]] || false
  [[ "$output" == *"E900-S2"* ]] || false
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC5c — both keys with duplicate key: stories wins
# ---------------------------------------------------------------------------
@test "both keys with duplicate key — stories version wins" {
  _create_story_file E900-S1 "the story" "done" sprint-dup

  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-dup"
status: active
total_points: 2
goals: []
items:
  - key: "E900-S1"
    title: 'items version'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
stories:
  - key: "E900-S1"
    title: 'stories version'
    status: "done"
    points: 2
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML

  # After migration, the stories version should win.
  run bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -eq 0 ]
  # Only one entry for E900-S1 should remain.
  local key_count
  key_count=$(grep -c '"E900-S1"' "$SPRINT_STATUS_YAML" || true)
  [ "$key_count" -eq 1 ]
  # The status should be "done" (from stories:), not "in-progress" (from items:).
  grep -A 2 '"E900-S1"' "$SPRINT_STATUS_YAML" | grep -q '"done"'
}

# ---------------------------------------------------------------------------
# AC5d — empty stories list: graceful
# ---------------------------------------------------------------------------
@test "empty stories list handled gracefully (AC5d)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-empty"
status: active
total_points: 0
goals: []
stories: []
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty legacy items list handled gracefully (AC5d legacy)" {
  cat > "$SPRINT_STATUS_YAML" <<'YAML'
sprint_id: "sprint-empty-leg"
status: active
total_points: 0
goals: []
items: []
YAML

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# AC6 — bash version compat (structural check)
# ---------------------------------------------------------------------------
@test "no bash 4+ syntax in sprint-state.sh and migration lib" {
  local script="$SPRINT_STATE"
  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  [ -f "$script" ]
  [ -f "$lib" ]
  local violations
  violations=$(grep -nE 'local -A |declare -A |\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}|readarray |mapfile |\|\&' "$script" "$lib" || true)
  [ -z "$violations" ]
}

# ---------------------------------------------------------------------------
# AC8 — fixtures use temp dirs only
# ---------------------------------------------------------------------------
@test "all fixtures use temp dirs, not the real plugin tree" {
  [ -d "$TEST_TMP" ]
  [ -d "$TEST_TMP/project/.gaia/state" ]
  [[ "$SPRINT_STATUS_YAML" == "$TEST_TMP"* ]] || false
}

# ---------------------------------------------------------------------------
# root cause — reproduce the original 1-of-20 symptom
# ---------------------------------------------------------------------------
@test "legacy yaml with 19 items + 1 story — migration makes all 20 visible" {
  # Reproduce the exact shape from the upstream issue: sprint-plan wrote 19
  # stories under items:, then inject added 1 story under stories:.
  # Without migration, triage sees only the stories: block = 1 story.
  {
    printf 'sprint_id: "sprint-repro"\n'
    printf 'status: active\n'
    printf 'total_points: 40\n'
    printf 'goals: []\n'
    printf 'items:\n'
    for i in $(seq 1 19); do
      printf '  - key: "E900-S%d"\n' "$i"
      printf '    title: '\''planned story %d'\''\n' "$i"
      printf '    status: "done"\n'
      printf '    points: 2\n'
      printf '    risk_level: "medium"\n'
      printf '    assignee: null\n'
      printf '    blocked_by: null\n'
      printf '    updated: "2026-01-01"\n'
    done
    printf 'stories:\n'
    printf '  - key: "E900-S20"\n'
    printf '    title: '\''injected story'\''\n'
    printf '    status: "done"\n'
    printf '    points: 2\n'
    printf '    risk_level: "medium"\n'
    printf '    assignee: null\n'
    printf '    blocked_by: null\n'
    printf '    updated: "2026-01-01"\n'
  } > "$SPRINT_STATUS_YAML"

  # Create story files for all 20.
  for i in $(seq 1 20); do
    _create_story_file "E900-S${i}" "story ${i}" "done" sprint-repro
  done

  # After migration (triggered by resolve-sprint-stories.sh), triage should
  # find all 20 stories.
  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'E900-S' || true)
  [ "$count" -eq 20 ]
}

@test "migration merges items into stories — no data loss" {
  {
    printf 'sprint_id: "sprint-merge"\n'
    printf 'status: active\n'
    printf 'total_points: 6\n'
    printf 'goals: []\n'
    printf 'items:\n'
    printf '  - key: "E900-S1"\n'
    printf '    title: '\''item story'\''\n'
    printf '    status: "done"\n'
    printf '    points: 2\n'
    printf '    risk_level: "medium"\n'
    printf '    assignee: null\n'
    printf '    blocked_by: null\n'
    printf '    updated: "2026-01-01"\n'
    printf '  - key: "E900-S2"\n'
    printf '    title: '\''item story 2'\''\n'
    printf '    status: "in-progress"\n'
    printf '    points: 2\n'
    printf '    risk_level: "medium"\n'
    printf '    assignee: null\n'
    printf '    blocked_by: null\n'
    printf '    updated: "2026-01-01"\n'
    printf 'stories:\n'
    printf '  - key: "E900-S3"\n'
    printf '    title: '\''stories story'\''\n'
    printf '    status: "ready-for-dev"\n'
    printf '    points: 2\n'
    printf '    risk_level: "low"\n'
    printf '    assignee: null\n'
    printf '    blocked_by: null\n'
    printf '    updated: "2026-01-01"\n'
  } > "$SPRINT_STATUS_YAML"
  _create_story_file E900-S1 "item story" "done" sprint-merge
  _create_story_file E900-S2 "item story 2" in-progress sprint-merge
  _create_story_file E900-S3 "stories story" ready-for-dev sprint-merge

  # Trigger migration via detect-auto-close (any subcommand works).
  run bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -eq 0 ]

  # Verify: items: is gone, stories: has all 3 entries.
  run grep -q '^items:' "$SPRINT_STATUS_YAML"
  [ "$status" -ne 0 ]
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  grep -q '"E900-S1"' "$SPRINT_STATUS_YAML"
  grep -q '"E900-S2"' "$SPRINT_STATUS_YAML"
  grep -q '"E900-S3"' "$SPRINT_STATUS_YAML"
}

# ---------------------------------------------------------------------------
# Migration idempotency
# ---------------------------------------------------------------------------
@test "migration is idempotent — running twice produces same result" {
  _legacy_yaml sprint-idem active \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "story one" ready-for-dev sprint-idem

  # First migration via detect-auto-close.
  run bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -eq 0 ]
  local first_content
  first_content=$(cat "$SPRINT_STATUS_YAML")

  # Second run — should be a no-op.
  run bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -eq 0 ]
  local second_content
  second_content=$(cat "$SPRINT_STATUS_YAML")

  [ "$first_content" = "$second_content" ]
}

# ---------------------------------------------------------------------------
# planned-active-gate sees legacy items entries
# ---------------------------------------------------------------------------
@test "planned-active-gate reads stories from legacy items key" {
  local gate="$BATS_TEST_DIRNAME/../scripts/planned-active-gate.sh"
  [ -f "$gate" ] || fail "planned-active-gate.sh not found"

  _legacy_yaml sprint-pag planned \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "pag story" ready-for-dev sprint-pag

  run bash "$gate" \
    --sprint-yaml "$SPRINT_STATUS_YAML" \
    --impl-root "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --test-artifacts "$TEST_TMP/project/.gaia/artifacts/test-artifacts"
  [[ "$output" != *"no stories[] roster found"* ]] || false
}

# ---------------------------------------------------------------------------
# sprint-progress-snapshot reads legacy items entries
# ---------------------------------------------------------------------------
@test "sprint-progress-snapshot reads stories from legacy items key" {
  local snapshot="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  [ -f "$snapshot" ] || fail "sprint-progress-snapshot.sh not found"

  _legacy_yaml sprint-snap active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "snap story" in-progress sprint-snap

  local cache_dir="$TEST_TMP/project/.gaia/state"
  run bash "$snapshot" --sprint-status "$SPRINT_STATUS_YAML" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --output "$cache_dir/sprint-progress.json" 2>&1
  [[ "$output" == *"E900-S1"* ]] || [ -f "$cache_dir/sprint-progress.json" ]
}

# ---------------------------------------------------------------------------
# close.sh precheck refuses when non-done story is under items key
# ---------------------------------------------------------------------------
@test "close precheck reads non-done story from legacy items key" {
  local close="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -f "$close" ] || fail "close.sh not found"

  _legacy_yaml sprint-cls review \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "cls story" in-progress sprint-cls
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts"
  touch "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/retrospective-sprint-cls-2026-01-01.md"

  run bash "$close" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done stories"* ]] || [[ "$output" == *"E900-S1"* ]] || false
}

# ---------------------------------------------------------------------------
# Held-lock helper: wait until the lock is confirmed held, with a bound.
# ---------------------------------------------------------------------------
_wait_for_lock() {
  local lockfile="$1" tries=0
  while [ "$tries" -lt 40 ]; do
    if ! flock -n 9 9>"$lockfile" 2>/dev/null; then return 0; fi
    exec 9>&-
    sleep 0.1; tries=$((tries + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Held-lock helper: start a lock holder, register its PID for teardown.
# ---------------------------------------------------------------------------
_start_holder() {
  local lockfile="$1"
  ( flock -x 9 || exit 1; exec sleep 20 ) 9>"$lockfile" &
  local pid=$!
  printf '%s\n' "$pid" >> "$TEST_TMP/holder_pids"
  _wait_for_lock "$lockfile"
}

# ---------------------------------------------------------------------------
# resolver under held lock falls back to both-keys reader (no rewrite)
# ---------------------------------------------------------------------------
@test "resolve-sprint-stories with held lock reads both keys without rewriting" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _legacy_yaml sprint-locktest active \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "lock story" ready-for-dev sprint-locktest

  local lockfile="${SPRINT_STATUS_YAML}.lock"
  mkdir -p "$(dirname "$lockfile")"
  _start_holder "$lockfile"

  local before_cksum
  before_cksum=$(cksum < "$SPRINT_STATUS_YAML")

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false

  local after_cksum
  after_cksum=$(cksum < "$SPRINT_STATUS_YAML")
  [ "$before_cksum" = "$after_cksum" ]
}

# ---------------------------------------------------------------------------
# Both-keys union tests for read_stories_or_items (shared lib)
# ---------------------------------------------------------------------------
@test "read_stories_or_items: items-first both-keys returns union, stories wins" {
  _both_keys_yaml sprint-union active items-first
  _create_story_file E900-S1 "story one" done sprint-union
  _create_story_file E900-S2 "story two" ready-for-dev sprint-union
  _create_story_file E900-S3 "story three" ready-for-dev sprint-union

  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  [ -f "$lib" ] || fail "shared lib not found"

  local out
  out="$(bash -c '. "'"$lib"'"; read_stories_or_items "'"$SPRINT_STATUS_YAML"'"')"
  grep -q $'^E900-S1\tdone$' <<< "$out"
  grep -q $'^E900-S2\tready-for-dev$' <<< "$out"
  grep -q $'^E900-S3\tready-for-dev$' <<< "$out"
  local count
  count="$(grep -c '.' <<< "$out")"
  [ "$count" -eq 3 ]
}

@test "read_stories_or_items: stories-first both-keys returns same union" {
  _both_keys_yaml sprint-union2 active stories-first
  _create_story_file E900-S1 "story one" done sprint-union2
  _create_story_file E900-S2 "story two" ready-for-dev sprint-union2
  _create_story_file E900-S3 "story three" ready-for-dev sprint-union2

  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  local out
  out="$(bash -c '. "'"$lib"'"; read_stories_or_items "'"$SPRINT_STATUS_YAML"'"')"
  grep -q $'^E900-S1\tdone$' <<< "$out"
  grep -q $'^E900-S2\tready-for-dev$' <<< "$out"
  grep -q $'^E900-S3\tready-for-dev$' <<< "$out"
  local count
  count="$(grep -c '.' <<< "$out")"
  [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# planned-active-gate both-keys union
# ---------------------------------------------------------------------------
@test "planned-active-gate: both-keys items-first sees all three keys" {
  local gate="$BATS_TEST_DIRNAME/../scripts/planned-active-gate.sh"
  [ -f "$gate" ] || fail "planned-active-gate.sh not found"

  _both_keys_yaml sprint-pag planned items-first
  _create_story_file E900-S1 "story one" ready-for-dev sprint-pag
  _create_story_file E900-S2 "story two" ready-for-dev sprint-pag
  _create_story_file E900-S3 "story three" ready-for-dev sprint-pag

  run --separate-stderr bash "$gate" \
    --sprint-yaml "$SPRINT_STATUS_YAML" \
    --impl-root "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --test-artifacts "$TEST_TMP/project/.gaia/artifacts/test-artifacts"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# throughput: items-only fixture — points joined for a completed story
# ---------------------------------------------------------------------------
@test "throughput-telemetry: items-only file joins points for completed story" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || fail "throughput-telemetry.sh not found"

  _legacy_yaml sprint-tti active \
    "E900-S1" "done"
  _create_story_file E900-S1 "story one" done sprint-tti 3

  # Two transitions: enough for throughput to compute a wall-clock entry.
  {
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n'
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T01:00:00Z","from":"in-progress","to":"done"}\n'
  } > "$TEST_TMP/events.jsonl"

  run bash "$tt" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  # A stories-only reader returns no points from items-only yaml, so
  # median_minutes_per_point shows "(no data)". The union reader joins
  # the points and computes a numeric median.
  [[ "$output" != *'median_minutes_per_point: (no data)'* ]] || false
}

# ---------------------------------------------------------------------------
# sprint-progress-snapshot: both-keys items-first reads all stories
# ---------------------------------------------------------------------------
@test "sprint-progress-snapshot: both-keys items-first reads all stories" {
  local snap="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  [ -f "$snap" ] || fail "sprint-progress-snapshot.sh not found"

  _both_keys_yaml sprint-snap2 active items-first
  _create_story_file E900-S1 "story one" done sprint-snap2 3
  _create_story_file E900-S2 "story two" ready-for-dev sprint-snap2 2
  _create_story_file E900-S3 "story three" in-progress sprint-snap2 4

  local cache="$TEST_TMP/project/.gaia/state/sprint-progress.json"
  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$snap"
  [ "$status" -eq 0 ]
  if [ -f "$cache" ]; then
    grep -q 'E900-S3' "$cache"
  else
    [[ "$output" == *"E900-S3"* ]] || false
  fi
}

# ===========================================================================
# Per-reader behavioral tests on items-only and both-keys fixtures.
# Each runs the real script entry point and asserts content that only
# the union reader produces.
# ===========================================================================

# Helper to set up the reviewer's canonical fixture (different points per
# block so we can detect which block was consumed).
_mk_reader_fixture() {
  local order="${1:-items-first}"
  _both_keys_yaml sprint-rdr active "$order"
  _create_story_file E900-S1 "story one" done sprint-rdr 3
  _create_story_file E900-S2 "story two" ready-for-dev sprint-rdr 2
  _create_story_file E900-S3 "story three" in-progress sprint-rdr 4
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories

## E900 — Fixture

| Key | Title | Status |
|-----|-------|--------|
| E900-S1 | story one | done |
| E900-S2 | story two | ready-for-dev |
| E900-S3 | story three | in-progress |
MD
}

# ---------------------------------------------------------------------------
# Dashboard fallback: items-only — all entries visible
# ---------------------------------------------------------------------------
@test "dashboard fallback: items-only file shows all entries" {
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  _legacy_yaml sprint-dash active \
    "E900-S1" "in-progress" \
    "E900-S3" "ready-for-dev"
  _create_story_file E900-S1 "story one" in-progress sprint-dash
  _create_story_file E900-S3 "story three" ready-for-dev sprint-dash
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Fixture
| Key | Title | Status |
|-----|-------|--------|
| E900-S1 | story one | in-progress |
| E900-S3 | story three | ready-for-dev |
MD

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false
  [[ "$output" == *"E900-S3"* ]] || false
}

# ---------------------------------------------------------------------------
# Dashboard under held lock: both orders — exact row and total assertions
# ---------------------------------------------------------------------------
@test "dashboard under held lock items-first: each key once, stories wins, correct total" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  _mk_reader_fixture items-first
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  _start_holder "$lockfile"

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]

  # E900-S1 must appear exactly once with the stories: value (done, 3).
  local s1_count
  s1_count=$(printf '%s\n' "$output" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$output" == *"E900-S1"*"done"* ]] || false
  # E900-S2 and E900-S3 must each appear.
  [[ "$output" == *"E900-S2"* ]] || false
  [[ "$output" == *"E900-S3"* ]] || false
  # Total must be 3 stories.
  [[ "$output" == *"Total: 3 stories"* ]] || false
}

@test "dashboard under held lock stories-first: each key once, stories wins, correct total" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  _mk_reader_fixture stories-first
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  _start_holder "$lockfile"

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]

  local s1_count
  s1_count=$(printf '%s\n' "$output" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$output" == *"E900-S1"*"done"* ]] || false
  [[ "$output" == *"E900-S2"* ]] || false
  [[ "$output" == *"E900-S3"* ]] || false
  [[ "$output" == *"Total: 3 stories"* ]] || false
}

# ---------------------------------------------------------------------------
# Close precheck on both-keys: detects non-done from items block
# ---------------------------------------------------------------------------
@test "close precheck: both-keys items-first detects non-done from items block" {
  local close="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -f "$close" ] || fail "close.sh not found"

  _mk_reader_fixture items-first
  sed -i.bak 's/^status: active/status: review/' "$SPRINT_STATUS_YAML"
  touch "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/retrospective-sprint-rdr-2026-01-01.md"

  run bash "$close" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done"* ]] || [[ "$output" == *"E900-S"* ]] || false
}

# ---------------------------------------------------------------------------
# Independence-check: items-only state file — shared epic causes failure
# A stories-only reader would see 0 keys for sprint A and pass vacuously.
# ---------------------------------------------------------------------------
@test "independence-check: items-only active sprint triggers shared-epic failure" {
  local ic="$BATS_TEST_DIRNAME/../scripts/independence-check.sh"
  [ -f "$ic" ] || fail "independence-check.sh not found"

  local state_dir="$TEST_TMP/project/.gaia/state"

  # Active sprint A: items-only, epic E900.
  cat > "$state_dir/sprint-status-sprint-A.yaml" << 'YAML'
sprint_id: "sprint-A"
status: active
total_points: 2
goals: []
items:
  - key: "E900-S1"
    title: 'story one'
    status: "in-progress"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  _create_story_file E900-S1 "story one" in-progress sprint-A 2

  # Candidate sprint B: stories key, SAME epic E900 — rule (b) must fire.
  cat > "$state_dir/sprint-status-sprint-B.yaml" << 'YAML'
sprint_id: "sprint-B"
status: planned
total_points: 2
goals: []
stories:
  - key: "E900-S2"
    title: 'story two'
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  _create_story_file E900-S2 "story two" ready-for-dev sprint-B 2
  cp "$state_dir/sprint-status-sprint-A.yaml" "$state_dir/sprint-status.yaml"
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Shared
| Key | Title |
|-----|-------|
| E900-S1 | story one |
| E900-S2 | story two |
MD
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  # With items: read, sprint A has E900-S1 in epic E900 and sprint B has
  # E900-S2 in epic E900 — rule (b) fires FAIL.
  # Without items: read, sprint A has 0 keys — all rules are vacuous -> PASS.
  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_CONFIG="$TEST_TMP/project/.gaia/config/project-config.yaml" \
    run bash "$ic" --candidate sprint-B --active sprint-A
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]] || false
}

# ---------------------------------------------------------------------------
# Independence-gate: items-only state file — cross-sprint lookup finds key
# ---------------------------------------------------------------------------
@test "independence-gate: carry-over key under items-only detected by gate" {
  local ig="$BATS_TEST_DIRNAME/../scripts/independence-gate.sh"
  [ -f "$ig" ] || fail "independence-gate.sh not found"

  local state_dir="$TEST_TMP/project/.gaia/state"
  # Active sprint-A: E900-S1 under items: only.
  printf 'sprint_id: "sprint-A"\nstatus: active\ntotal_points: 2\ngoals: []\nitems:\n  - key: "E900-S1"\n    title: '\''story one'\''\n    status: "in-progress"\n    points: 2\n' > "$state_dir/sprint-status-sprint-A.yaml"
  cp "$state_dir/sprint-status-sprint-A.yaml" "$state_dir/sprint-status.yaml"

  # Candidate sprint-B carries E900-S1 over.
  printf 'sprint_id: "sprint-B"\nstatus: planned\ntotal_points: 2\ngoals: []\nstories:\n  - key: "E900-S1"\n    title: '\''story one'\''\n    status: "in-progress"\n    points: 2\n' > "$state_dir/sprint-status-sprint-B.yaml"

  # Story file with predicted_touch_set (needed for rules c/d).
  local sf="$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S1-story-one/story.md"
  mkdir -p "$(dirname "$sf")"
  printf -- '---\nkey: "E900-S1"\ntitle: "story one"\nstatus: "in-progress"\nsprint_id: "sprint-B"\npoints: 2\nrisk: "medium"\nepic: "E900"\ndepends_on: []\nblocks: []\npredicted_touch_set: []\n---\n# Story: story one\n' > "$sf"

  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Fixture
| Key | Title |
|-----|-------|
| E900-S1 | story one |
MD
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  # The gate reads sprint-A's items: to find the carry-over key. With the
  # carry-over detected, it passes --skip-key-in-sprint to independence-check,
  # and the shared-epic rule skips E900-S1 -> PASS.
  # A stories-only reader misses the key, so the gate does NOT skip it in
  # independence-check, and rule (b) fires FAIL (shared epic E900).
  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_CONFIG="$TEST_TMP/project/.gaia/config/project-config.yaml" \
    run bash "$ig" "$sf" --candidate sprint-B
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (a),(b)"* ]] || false
  [[ "$output" != *"FAIL rule (b)"* ]] || false
}

# ---------------------------------------------------------------------------
# Epic-status-dashboard: items-only fixture shows yaml status, not story file
# ---------------------------------------------------------------------------
@test "epic-status-dashboard: items-only yaml status overrides story file" {
  local esd="$BATS_TEST_DIRNAME/../scripts/epic-status-dashboard.sh"
  [ -f "$esd" ] || fail "epic-status-dashboard.sh not found"

  # Yaml says in-progress via items:; story file says done.
  # The dashboard prefers the yaml status. A stories-only reader would miss
  # the yaml entry and fall back to the story file, showing "done".
  _legacy_yaml sprint-esd active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "story one" done sprint-esd 3
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Fixture
| Key | Title | Status |
|-----|-------|--------|
| E900-S1 | story one | in-progress |
MD

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
  EPICS_FILE="$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" \
    run bash "$esd"
  [ "$status" -eq 0 ]
  # The yaml says in-progress. Without items: reading, the fallback to story
  # file shows done. With items: reading, in-progress appears.
  # The yaml says in-progress, so the done percentage must be 0.
  # A stories-only reader misses the yaml entry, falls back to the story file
  # which says done, and reports 100%.
  [[ "$output" == *"0%"* ]] || [[ "$output" == *"| 0 |"*"| 1 |"* ]] || false
  [[ "$output" != *"100%"* ]] || false
}

# ---------------------------------------------------------------------------
# Rubric-evaluate: items-only fixture finds stories
# ---------------------------------------------------------------------------
@test "rubric-evaluate: items-only file computes goal shares" {
  local rub="$BATS_TEST_DIRNAME/../scripts/rubric-evaluate.sh"
  [ -f "$rub" ] || fail "rubric-evaluate.sh not found"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-rub"
status: active
total_points: 7
goals:
  - "deliver feature"
items:
  - key: "E900-S1"
    title: 'story one'
    status: "done"
    points: 3
    goal_index: 0
  - key: "E900-S3"
    title: 'story three'
    status: "in-progress"
    points: 4
    goal_index: 0
YAML
  _create_story_file E900-S1 "story one" done sprint-rub 3
  _create_story_file E900-S3 "story three" in-progress sprint-rub 4

  # Create a minimal rubric file for rubric-evaluate.
  local rubric="$TEST_TMP/rubric.yaml"
  printf 'rubric:\n  name: "test"\n  version: "1.0"\n  categories: []\n' > "$rubric"

  run bash "$rub" --sprint-status "$SPRINT_STATUS_YAML" --rubric "$rubric"
  # A stories-only Python reader sees no stories block and exits 2 with
  # "no stories[] block". The items: reader finds the two stories.
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Review-extract: both-keys fixture includes items-only key in story list
# ---------------------------------------------------------------------------
@test "review-extract: per-story review for items-only key is included in output" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  local re="$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts/review-extract.sh"
  [ -f "$re" ] || fail "review-extract.sh not found"

  _mk_reader_fixture items-first

  # Per-story review for E900-S3 (items-only key) WITHOUT sprint_id in
  # frontmatter. Without sprint_id, review-extract falls back to matching
  # via SPRINT_STORY_KEYS. A stories-only yq query drops E900-S3, so
  # this review would be excluded.
  local s3dir="$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E900/E900-S3-story-three/reviews"
  mkdir -p "$s3dir"
  printf -- '---\ntype: "code-review"\n---\n# Code Review\n**Verdict:** PASSED\n' > "$s3dir/code-review-E900-S3.md"

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  GAIA_STATE_DIR="$TEST_TMP/project/.gaia/state" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$re" --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" --sprint-id sprint-rdr
  [ "$status" -eq 0 ]
  # The items-only key's review must appear. A stories-only yq query
  # would exclude E900-S3 from SPRINT_STORY_KEYS, dropping its review.
  [[ "$output" == *"E900-S3"* ]] || false
}

# ---------------------------------------------------------------------------
# Resolver under held lock: both-keys items-first yields all three keys
# ---------------------------------------------------------------------------
@test "resolver under held lock: both-keys items-first yields all three keys" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _mk_reader_fixture items-first
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  _start_holder "$lockfile"

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false
  [[ "$output" == *"E900-S2"* ]] || false
  [[ "$output" == *"E900-S3"* ]] || false
}

# ===========================================================================
# Lock, fail-closed, mode, per-sprint, and concurrent-init tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Dispatch migration under held lock: fail-closed exit and file unchanged
# ---------------------------------------------------------------------------
@test "dispatch migration under held lock: non-zero exit and fail-closed message" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _legacy_yaml sprint-l2 active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "l2 story" in-progress sprint-l2

  local lockfile="${SPRINT_STATUS_YAML}.lock"
  _start_holder "$lockfile"

  local before_cksum
  before_cksum=$(cksum < "$SPRINT_STATUS_YAML")

  # detect-auto-close triggers the dispatch migration at pre-dispatch.
  # With the lock held, it must exit non-zero with a fail-closed message.
  run --separate-stderr bash "$SPRINT_STATE" detect-auto-close
  [ "$status" -ne 0 ]
  local all_out="${output}${stderr}"
  [[ "$all_out" == *"lock timeout"* ]] || [[ "$all_out" == *"fail-closed"* ]] || false

  local after_cksum
  after_cksum=$(cksum < "$SPRINT_STATUS_YAML")
  [ "$before_cksum" = "$after_cksum" ]
}

# ---------------------------------------------------------------------------
# Migration lib lock timeout: exits non-zero with fail-closed message
# ---------------------------------------------------------------------------
@test "migration lib: lock timeout exits non-zero" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _legacy_yaml sprint-l3 active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "l3 story" in-progress sprint-l3

  local lockfile="${SPRINT_STATUS_YAML}.lock"
  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  local acquirelib="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"
  [ -f "$lib" ] || fail "migrate-items-to-stories.sh not found"
  [ -f "$acquirelib" ] || fail "acquire-lock.sh not found"

  _start_holder "$lockfile"

  run bash -c '. "'"$acquirelib"'"; . "'"$lib"'"; migrate_items_to_stories "'"$SPRINT_STATUS_YAML"'" --lock "'"$lockfile"'"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock timeout"* ]] || [[ "$output" == *"fail-closed"* ]] || false
}

# ---------------------------------------------------------------------------
# Migration preserves file mode
# ---------------------------------------------------------------------------
@test "migration preserves file mode" {
  _legacy_yaml sprint-l5 active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "l5 story" in-progress sprint-l5

  chmod 640 "$SPRINT_STATUS_YAML"
  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  [ -f "$lib" ] || fail "migrate-items-to-stories.sh not found"

  run bash -c '. "'"$lib"'"; migrate_items_to_stories "'"$SPRINT_STATUS_YAML"'"'
  [ "$status" -eq 0 ]
  grep -q '^stories:' "$SPRINT_STATUS_YAML"
  local mode
  if stat -c %a / >/dev/null 2>&1; then
    mode="$(stat -c %a "$SPRINT_STATUS_YAML")"
  else
    mode="$(stat -f %Lp "$SPRINT_STATUS_YAML")"
  fi
  [ "$mode" = "640" ]
}

# ---------------------------------------------------------------------------
# Concurrent mode: per-sprint legacy file is migrated (not the default file)
# ---------------------------------------------------------------------------
@test "concurrent mode: per-sprint both-keys file is migrated by transition" {
  local state_dir="$TEST_TMP/project/.gaia/state"

  # Default sprint-status.yaml is a closed sprint (not the per-sprint file).
  cat > "$state_dir/sprint-status.yaml" << 'YAML'
sprint_id: "sprint-old"
status: closed
total_points: 0
goals: []
stories: []
YAML

  # Per-sprint file for sprint-C: both keys, stories-first.
  cat > "$state_dir/sprint-status-sprint-C.yaml" << 'YAML'
sprint_id: "sprint-C"
status: active
total_points: 6
goals: []
stories:
  - key: "E900-S1"
    title: "one"
    status: "done"
    points: 3
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
items:
  - key: "E900-S2"
    title: "two"
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
  - key: "E900-S3"
    title: "three"
    status: "in-progress"
    points: 4
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  _create_story_file E900-S1 "one" done sprint-C 3
  _create_story_file E900-S2 "two" ready-for-dev sprint-C 2
  _create_story_file E900-S3 "three" in-progress sprint-C 4

  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  # Do NOT export SPRINT_STATUS_YAML — sprint-state.sh must resolve the
  # per-sprint file from the --sprint argument via concurrent-mode logic.
  unset SPRINT_STATUS_YAML
  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
    run --separate-stderr bash "$SPRINT_STATE" transition --sprint sprint-C --to review
  # Transition should refuse: E900-S2 and E900-S3 are non-done.
  # The refusal message goes to stderr.
  [ "$status" -ne 0 ]
  local all_out="${output}${stderr}"
  [[ "$all_out" == *"E900-S2"* ]] || [[ "$all_out" == *"E900-S3"* ]] || [[ "$all_out" == *"non-done"* ]] || false
  # The per-sprint file must have been migrated (items: removed).
  grep -q '^stories:' "$state_dir/sprint-status-sprint-C.yaml"
  run grep -q '^items:' "$state_dir/sprint-status-sprint-C.yaml"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Concurrent init: second sprint seeded with stories: not items:
# ---------------------------------------------------------------------------
@test "concurrent init after single-mode sprint: second sprint seeds stories key" {
  local state_dir="$TEST_TMP/project/.gaia/state"

  # Init sprint-A in single mode.
  run bash "$SPRINT_STATE" init --sprint-id sprint-A
  [ "$status" -eq 0 ]

  # Switch to concurrent mode.
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  # Init sprint-B — this goes through the concurrent seed path.
  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$SPRINT_STATE" init --sprint-id sprint-B
  [ "$status" -eq 0 ]

  local psf="$state_dir/sprint-status-sprint-B.yaml"
  [ -f "$psf" ] || psf="$(find "$state_dir" -name '*sprint-B*' -type f 2>/dev/null | head -1)"
  [ -f "$psf" ] || fail "per-sprint file not created"
  grep -q '^stories:' "$psf"
  run grep -q '^items:' "$psf"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Fail-closed when the migration lib is missing
# ===========================================================================

@test "close.sh without migration lib: non-done story still blocks close" {
  local close="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -f "$close" ] || fail "close.sh not found"

  _legacy_yaml sprint-f1 review \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "f1 story" in-progress sprint-f1
  touch "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/retrospective-sprint-f1-2026-01-01.md"

  # Create an isolated tree without the migration lib.
  local iso_dir="$TEST_TMP/iso-close"
  mkdir -p "$iso_dir/scripts/lib"
  cp "$close" "$iso_dir/close.sh"
  local plugin_scripts="$BATS_TEST_DIRNAME/../scripts"
  cp "$plugin_scripts/lifecycle-event.sh" "$iso_dir/scripts/" 2>/dev/null || true
  cp "$plugin_scripts/lib/acquire-lock.sh" "$iso_dir/scripts/lib/" 2>/dev/null || true

  sed -i.bak 's|PLUGIN_SCRIPTS_DIR=.*|PLUGIN_SCRIPTS_DIR="'"$iso_dir"'/scripts"|' "$iso_dir/close.sh"

  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
    run bash "$iso_dir/close.sh" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done"* ]] || [[ "$output" == *"E900-S1"* ]] || false
}

@test "throughput without migration lib: items-only yaml joins points via fallback" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || fail "throughput-telemetry.sh not found"

  _legacy_yaml sprint-f1t active \
    "E900-S1" "done"
  # Do NOT create story files — only the yaml carries the points.

  {
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n'
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T01:00:00Z","from":"in-progress","to":"done"}\n'
  } > "$TEST_TMP/events.jsonl"

  # Isolated tree without the lib — the inline fallback handles items:.
  local iso_dir="$TEST_TMP/iso-tt"
  mkdir -p "$iso_dir/lib"
  cp "$tt" "$iso_dir/throughput-telemetry.sh"
  sed -i.bak 's|_TT_SCRIPT_DIR=.*|_TT_SCRIPT_DIR="'"$iso_dir"'"|' "$iso_dir/throughput-telemetry.sh"

  run bash "$iso_dir/throughput-telemetry.sh" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]] || false
  [[ "$output" != *'median_minutes_per_point: (no data)'* ]] || false
}

# ===========================================================================
# Additional readers outside the main diff: both-keys union by key
# ===========================================================================

@test "ppo_read_phases: items-first both-keys gives stories phase" {
  local ppo="$BATS_TEST_DIRNAME/../scripts/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || fail "phase-parallel-orchestrator.sh not found"

  # items: E900-S1 phase 1; stories: E900-S1 phase 2, E900-S2 phase 1.
  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-ppo"
status: active
total_points: 4
goals: []
items:
  - key: "E900-S1"
    title: "iv"
    status: "in-progress"
    points: 2
    phase: 1
stories:
  - key: "E900-S1"
    title: "sv"
    status: "done"
    points: 2
    phase: 2
  - key: "E900-S2"
    title: "so"
    status: "ready-for-dev"
    points: 2
    phase: 1
YAML

  local out s1_count
  out="$(bash -c '. "'"$ppo"'"; ppo_read_phases "'"$SPRINT_STATUS_YAML"'"')"
  s1_count=$(printf '%s\n' "$out" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$out" == *"E900-S1|2"* ]] || false
  [[ "$out" == *"E900-S2|1"* ]] || false
}

@test "ppo_read_phases: stories-first both-keys gives stories phase" {
  local ppo="$BATS_TEST_DIRNAME/../scripts/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || fail "phase-parallel-orchestrator.sh not found"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-ppo"
status: active
total_points: 4
goals: []
stories:
  - key: "E900-S1"
    title: "sv"
    status: "done"
    points: 2
    phase: 2
  - key: "E900-S2"
    title: "so"
    status: "ready-for-dev"
    points: 2
    phase: 1
items:
  - key: "E900-S1"
    title: "iv"
    status: "in-progress"
    points: 2
    phase: 1
YAML

  local out s1_count
  out="$(bash -c '. "'"$ppo"'"; ppo_read_phases "'"$SPRINT_STATUS_YAML"'"')"
  s1_count=$(printf '%s\n' "$out" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$out" == *"E900-S1|2"* ]] || false
  [[ "$out" == *"E900-S2|1"* ]] || false
}

@test "sprint-progress-audit: items-first both-keys gives stories status" {
  local spa="$BATS_TEST_DIRNAME/../scripts/sprint-progress-audit.sh"
  [ -f "$spa" ] || fail "sprint-progress-audit.sh not found"

  # Extract the real _extract_stories from the real script.
  local fn_file="$TEST_TMP/extract_stories.sh"
  sed -n '/^_extract_stories()/,/^}/p' "$spa" > "$fn_file"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-spa"
status: active
total_points: 4
goals: []
items:
  - key: "E900-S1"
    title: "iv"
    status: "in-progress"
    points: 2
stories:
  - key: "E900-S1"
    title: "sv"
    status: "done"
    points: 2
  - key: "E900-S2"
    title: "so"
    status: "ready-for-dev"
    points: 2
YAML

  local out s1_count
  out="$(_SPRINT_STATUS="$SPRINT_STATUS_YAML" bash -c '_SPRINT_STATUS="'"$SPRINT_STATUS_YAML"'"; . "'"$fn_file"'"; _extract_stories')"
  s1_count=$(printf '%s\n' "$out" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$out" == *"E900-S1|done"* ]] || false
  [[ "$out" == *"E900-S2|ready-for-dev"* ]] || false
}

@test "sprint-progress-audit: stories-first both-keys gives stories status" {
  local spa="$BATS_TEST_DIRNAME/../scripts/sprint-progress-audit.sh"
  [ -f "$spa" ] || fail "sprint-progress-audit.sh not found"

  local fn_file="$TEST_TMP/extract_stories.sh"
  sed -n '/^_extract_stories()/,/^}/p' "$spa" > "$fn_file"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-spa"
status: active
total_points: 4
goals: []
stories:
  - key: "E900-S1"
    title: "sv"
    status: "done"
    points: 2
  - key: "E900-S2"
    title: "so"
    status: "ready-for-dev"
    points: 2
items:
  - key: "E900-S1"
    title: "iv"
    status: "in-progress"
    points: 2
YAML

  local out s1_count
  out="$(_SPRINT_STATUS="$SPRINT_STATUS_YAML" bash -c '_SPRINT_STATUS="'"$SPRINT_STATUS_YAML"'"; . "'"$fn_file"'"; _extract_stories')"
  s1_count=$(printf '%s\n' "$out" | grep -c 'E900-S1' || true)
  [ "$s1_count" -eq 1 ]
  [[ "$out" == *"E900-S1|done"* ]] || false
  [[ "$out" == *"E900-S2|ready-for-dev"* ]] || false
}

@test "dashboard: items entry with empty title renders correctly" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-et"
status: active
total_points: 2
goals: []
items:
  - key: "E900-S1"
    title: ""
    status: "in-progress"
    points: 2
YAML
  _create_story_file E900-S1 "story one" in-progress sprint-et 2
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Fixture
| Key | Title |
|-----|-------|
| E900-S1 | story one |
MD
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  _start_holder "$lockfile"

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]] || false
  # When the buffer separator does not preserve empty fields, the empty
  # title collapses and the status shifts into the title column. Verify the
  # status is in its own column, not shifted left.
  local row
  row="$(printf '%s\n' "$output" | grep 'E900-S1')"
  # The dashboard format is: %-12s %-38s %-14s %s
  # Correct:  "  E900-S1      <empty>                                 in-progress    2"
  # Shifted:  "  E900-S1      in-progress                             2              "
  [[ "$row" == *"in-progress"*"2"* ]] || false
  # Also: the title column (chars 15-52) must NOT contain "in-progress".
  # In the correct layout, the title is empty so that range is spaces.
  local title_col="${row:14:38}"
  [[ "$title_col" != *"in-progress"* ]] || false
}
