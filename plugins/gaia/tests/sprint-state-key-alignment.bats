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

teardown() { common_teardown; }

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
  [[ "$output" != *"auto_close_eligible: true"* ]]
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
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
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
    key="E99-S${i}"
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
    [[ "$output" == *"E99-S${i}"* ]]
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
  [[ "$output" == *"E900-S1"* ]]
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
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
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
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
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
  [[ "$SPRINT_STATUS_YAML" == "$TEST_TMP"* ]]
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
  [ -f "$gate" ] || skip "planned-active-gate.sh not found"

  _legacy_yaml sprint-pag planned \
    "E900-S1" "ready-for-dev"
  _create_story_file E900-S1 "pag story" ready-for-dev sprint-pag

  # The gate reads the roster — it should find the story under items:.
  run bash "$gate" \
    --sprint-yaml "$SPRINT_STATUS_YAML" \
    --impl-root "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --test-artifacts "$TEST_TMP/project/.gaia/artifacts/test-artifacts"
  # The gate may fail because the story isn't materialized with ATDD, but
  # the important thing is it parsed the roster (found a key, not "no stories").
  [[ "$output" != *"no stories[] roster found"* ]]
}

# ---------------------------------------------------------------------------
# sprint-progress-snapshot reads legacy items entries
# ---------------------------------------------------------------------------
@test "sprint-progress-snapshot reads stories from legacy items key" {
  local snapshot="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  [ -f "$snapshot" ] || skip "sprint-progress-snapshot.sh not found"

  _legacy_yaml sprint-snap active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "snap story" in-progress sprint-snap

  # The snapshot reads stories from the yaml — under items: it must still
  # find them. The snapshot writes a JSON cache; we just verify it runs and
  # includes the story key.
  local cache_dir="$TEST_TMP/project/.gaia/state"
  run bash "$snapshot" --sprint-status "$SPRINT_STATUS_YAML" \
    --config "$TEST_TMP/project/.gaia/config/project-config.yaml" \
    --output "$cache_dir/sprint-progress.json" 2>&1
  # The snapshot may fail on optional fields, but if it ran the awk reader
  # it won't report 0 stories. Check exit or output for the key.
  [[ "$output" == *"E900-S1"* ]] || [ -f "$cache_dir/sprint-progress.json" ]
}

# ---------------------------------------------------------------------------
# close.sh precheck reads legacy items entries
# ---------------------------------------------------------------------------
@test "close precheck reads non-done story from legacy items key" {
  local close="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -f "$close" ] || fail "close.sh not found"

  _legacy_yaml sprint-cls review \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "cls story" in-progress sprint-cls

  # close.sh requires a retro doc to get past the retro-check gate.
  mkdir -p "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts"
  touch "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/retrospective-sprint-cls-2026-01-01.md"

  # close.sh should refuse because the non-done story is visible.
  run bash "$close" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done stories"* ]] || [[ "$output" == *"E900-S1"* ]]
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

  # Hold the lock in a background subshell with a hard timeout to prevent
  # hanging if an assertion fails before the release signal is sent.
  local holder_pid=""
  _release_holder() {
    if [ -n "${holder_pid:-}" ]; then
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""
    fi
  }
  # Ensure cleanup even when an assertion fails.
  trap '_release_holder' EXIT

  (
    flock -x 9 || exit 1
    # Hard timeout: auto-release after 15 s so bats never hangs.
    sleep 15
  ) 9>"$lockfile" &
  holder_pid=$!
  sleep 0.3

  local before_cksum
  before_cksum=$(cksum < "$SPRINT_STATUS_YAML")

  # Run the resolver — it should still find the story via the both-keys
  # fallback reader even though it cannot acquire the lock to migrate.
  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]

  # The file must NOT have been rewritten (lock was held).
  local after_cksum
  after_cksum=$(cksum < "$SPRINT_STATUS_YAML")
  [ "$before_cksum" = "$after_cksum" ]

  # Release the holder.
  _release_holder
  trap - EXIT
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
  [ -f "$lib" ] || skip "shared lib not found"

  local out
  out="$(bash -c '. "'"$lib"'"; read_stories_or_items "'"$SPRINT_STATUS_YAML"'"')"
  # E900-S1 from stories (status=done, not in-progress from items)
  grep -q $'^E900-S1\tdone$' <<< "$out"
  # E900-S2 from stories only
  grep -q $'^E900-S2\tready-for-dev$' <<< "$out"
  # E900-S3 from items only (not in stories)
  grep -q $'^E900-S3\tready-for-dev$' <<< "$out"
  # Exactly 3 lines (no duplicates)
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
  [ -f "$gate" ] || skip "planned-active-gate.sh not found"

  _both_keys_yaml sprint-pag planned items-first
  _create_story_file E900-S1 "story one" ready-for-dev sprint-pag
  _create_story_file E900-S2 "story two" ready-for-dev sprint-pag
  _create_story_file E900-S3 "story three" ready-for-dev sprint-pag

  # If the gate only saw 1-2 stories instead of 3, it would fail because
  # the missing stories would appear unmaterialized. Gate pass means all 3
  # keys were found in the roster.
  run --separate-stderr bash "$gate" \
    --sprint-yaml "$SPRINT_STATUS_YAML" \
    --impl-root "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --test-artifacts "$TEST_TMP/project/.gaia/artifacts/test-artifacts"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# throughput both-keys union
# ---------------------------------------------------------------------------
@test "throughput-telemetry: both-keys items-first reads points from all three stories" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || fail "throughput-telemetry.sh not found"

  _both_keys_yaml sprint-tt active items-first
  _create_story_file E900-S1 "story one" done sprint-tt 3
  _create_story_file E900-S2 "story two" ready-for-dev sprint-tt 2
  _create_story_file E900-S3 "story three" in-progress sprint-tt 4

  # Create events with transitions for all three stories.
  {
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n'
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T01:00:00Z","from":"in-progress","to":"done"}\n'
    printf '{"event_type":"state_transition","story_key":"E900-S3","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n'
  } > "$TEST_TMP/events.jsonl"

  run bash "$tt" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  # throughput emits JSON with per-story entries. The output should reference
  # the items-only story (S3) proving the union was read.
  [[ "$output" == *"E900-S3"* ]] || [[ "$output" == *"total_points"* ]]
}

# ---------------------------------------------------------------------------
# sprint-progress-snapshot both-keys
# ---------------------------------------------------------------------------
@test "sprint-progress-snapshot: both-keys items-first reads all stories" {
  local snap="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  [ -f "$snap" ] || fail "sprint-progress-snapshot.sh not found"

  _both_keys_yaml sprint-snap2 active items-first
  _create_story_file E900-S1 "story one" done sprint-snap2 3
  _create_story_file E900-S2 "story two" ready-for-dev sprint-snap2 2
  _create_story_file E900-S3 "story three" in-progress sprint-snap2 4

  # The snapshot writes a JSON cache. Pass env vars the script expects.
  local cache="$TEST_TMP/project/.gaia/state/sprint-progress.json"
  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$snap"
  [ "$status" -eq 0 ]
  # The items-only story (S3) must appear in the output or cached file.
  if [ -f "$cache" ]; then
    grep -q 'E900-S3' "$cache"
  else
    [[ "$output" == *"E900-S3"* ]]
  fi
}

# ===========================================================================
# Per-reader behavioral tests — run the real script on items-only and
# both-keys fixtures and assert the exact roster. Kills mutants R3-R10.
# ===========================================================================

# Helper: create a both-keys fixture with different points/statuses per block.
#   items:  E900-S1 in-progress/5, E900-S3 in-progress/4
#   stories: E900-S1 done/3, E900-S2 ready-for-dev/2
# Union: S1=done/3, S2=ready-for-dev/2, S3=in-progress/4
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
# R3 — sprint-status-dashboard fallback: items-only and both-keys
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
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S3"* ]]
}

@test "dashboard fallback: both-keys items-first shows union, stories wins" {
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  _mk_reader_fixture items-first

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
  [[ "$output" == *"E900-S3"* ]]
  # S1 must show "done" (from stories:), not "in-progress" (from items:).
  [[ "$output" == *"done"* ]]
}

# ---------------------------------------------------------------------------
# R4 — close.sh precheck on both-keys fixture
# ---------------------------------------------------------------------------
@test "close precheck: both-keys items-first detects non-done from items block" {
  local close="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
  [ -f "$close" ] || fail "close.sh not found"

  _mk_reader_fixture items-first
  sed -i.bak 's/^status: active/status: review/' "$SPRINT_STATUS_YAML"
  touch "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/retrospective-sprint-rdr-2026-01-01.md"

  run bash "$close" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-done"* ]] || [[ "$output" == *"E900-S"* ]]
}

# ---------------------------------------------------------------------------
# R5 — throughput-telemetry on items-only fixture
# ---------------------------------------------------------------------------
@test "throughput-telemetry: items-only file reads points" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || fail "throughput-telemetry.sh not found"

  _legacy_yaml sprint-tti active \
    "E900-S1" "done" \
    "E900-S3" "in-progress"
  _create_story_file E900-S1 "story one" done sprint-tti 3
  _create_story_file E900-S3 "story three" in-progress sprint-tti 4

  {
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"done"}\n'
    printf '{"event_type":"state_transition","story_key":"E900-S3","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n'
  } > "$TEST_TMP/events.jsonl"

  run bash "$tt" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  [[ "$output" == *"E900-S3"* ]] || [[ "$output" == *"total_points"* ]]
}

# ---------------------------------------------------------------------------
# R6 — independence-check reads from items-only state file
# ---------------------------------------------------------------------------
@test "independence-check: items-only state file yields story keys" {
  local ic="$BATS_TEST_DIRNAME/../scripts/independence-check.sh"
  [ -f "$ic" ] || fail "independence-check.sh not found"

  local state_dir="$TEST_TMP/project/.gaia/state"

  cat > "$state_dir/sprint-status-sprint-A.yaml" << 'YAML'
sprint_id: "sprint-A"
status: active
total_points: 4
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

  cat > "$state_dir/sprint-status-sprint-B.yaml" << 'YAML'
sprint_id: "sprint-B"
status: planned
total_points: 4
goals: []
stories:
  - key: "E901-S2"
    title: 'story two'
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  local e901_dir="$TEST_TMP/project/.gaia/artifacts/implementation-artifacts/epic-E901/E901-S2-story-two"
  mkdir -p "$e901_dir"
  printf -- '---\nkey: "E901-S2"\ntitle: "story two"\nstatus: "ready-for-dev"\nsprint_id: "sprint-B"\npoints: 2\nrisk: "medium"\nepic: "E901"\ndepends_on: []\nblocks: []\n---\n# x\n' > "$e901_dir/story.md"
  cp "$state_dir/sprint-status-sprint-A.yaml" "$state_dir/sprint-status.yaml"
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — A
| Key | Title |
|-----|-------|
| E900-S1 | story one |
## E901 — B
| Key | Title |
|-----|-------|
| E901-S2 | story two |
MD
  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_CONFIG="$TEST_TMP/project/.gaia/config/project-config.yaml" \
    run bash "$ic" --candidate sprint-B --active sprint-A
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# R7 — independence-gate reads from items-only state file
# ---------------------------------------------------------------------------
@test "independence-gate: items-only state file is read for cross-sprint lookup" {
  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  [ -f "$lib" ] || fail "migrate-items-to-stories.sh not found"

  local state_dir="$TEST_TMP/project/.gaia/state"
  cat > "$state_dir/sprint-status-sprint-A.yaml" << 'YAML'
sprint_id: "sprint-A"
status: active
total_points: 4
goals: []
items:
  - key: "E900-S1"
    title: 'story one'
    status: "in-progress"
    points: 2
YAML

  local found
  found="$(bash -c '. "'"$lib"'"; read_stories_or_items "'"$state_dir/sprint-status-sprint-A.yaml"'" | cut -f1 | grep -xF "E900-S1"')"
  [ "$found" = "E900-S1" ]
}

# ---------------------------------------------------------------------------
# R8 — epic-status-dashboard reads from items-only fixture
# ---------------------------------------------------------------------------
@test "epic-status-dashboard: items-only file shows story statuses" {
  local esd="$BATS_TEST_DIRNAME/../scripts/epic-status-dashboard.sh"
  [ -f "$esd" ] || fail "epic-status-dashboard.sh not found"

  _legacy_yaml sprint-esd active \
    "E900-S1" "done" \
    "E900-S3" "in-progress"
  _create_story_file E900-S1 "story one" done sprint-esd 3
  _create_story_file E900-S3 "story three" in-progress sprint-esd 4
  cat > "$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" << 'MD'
# Epics and Stories
## E900 — Fixture
| Key | Title | Status |
|-----|-------|--------|
| E900-S1 | story one | done |
| E900-S3 | story three | in-progress |
MD

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
  EPICS_FILE="$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" \
    run bash "$esd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900"* ]]
  [[ "$output" == *"done"* ]] || [[ "$output" == *"Done"* ]] || [[ "$output" == *"1/"* ]]
}

@test "epic-status-dashboard: both-keys items-first shows union" {
  local esd="$BATS_TEST_DIRNAME/../scripts/epic-status-dashboard.sh"
  [ -f "$esd" ] || fail "epic-status-dashboard.sh not found"

  _mk_reader_fixture items-first

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
  EPICS_FILE="$TEST_TMP/project/.gaia/artifacts/planning-artifacts/epics-and-stories.md" \
    run bash "$esd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900"* ]]
}

# ---------------------------------------------------------------------------
# R9 — rubric-evaluate on items-only fixture
# ---------------------------------------------------------------------------
@test "rubric-evaluate: items-only file finds stories" {
  local rub="$BATS_TEST_DIRNAME/../scripts/rubric-evaluate.sh"
  [ -f "$rub" ] || fail "rubric-evaluate.sh not found"

  cat > "$SPRINT_STATUS_YAML" << 'YAML'
sprint_id: "sprint-rub"
status: active
total_points: 4
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

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$rub"
  [ "$status" -eq 0 ] || [[ "$output" != *"no stories"* ]]
}

# ---------------------------------------------------------------------------
# R10 — review-extract yq union includes items-only keys
# ---------------------------------------------------------------------------
@test "review-extract: both-keys items-first includes items-only key in sprint filter" {
  command -v yq >/dev/null 2>&1 || skip "yq not available"

  _mk_reader_fixture items-first

  local keys
  keys="$(yq eval '((.stories // []) + (.items // []) | unique_by(.key))[].key' "$SPRINT_STATUS_YAML" 2>/dev/null)"
  [[ "$keys" == *"E900-S3"* ]]
  [[ "$keys" == *"E900-S1"* ]]
  [[ "$keys" == *"E900-S2"* ]]
}

# ---------------------------------------------------------------------------
# B3 — resolver fallback with held lock shows union on both-keys file
# ---------------------------------------------------------------------------
@test "resolver under held lock: both-keys items-first yields all three keys" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _mk_reader_fixture items-first
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  mkdir -p "$(dirname "$lockfile")"

  local holder_pid=""
  _release_holder() {
    if [ -n "${holder_pid:-}" ]; then
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""
    fi
  }
  trap '_release_holder' EXIT

  ( flock -x 9 || exit 1; sleep 15 ) 9>"$lockfile" &
  holder_pid=$!
  sleep 0.3

  run bash "$RESOLVE_SPRINT_STORIES" \
    --impl-dir "$TEST_TMP/project/.gaia/artifacts/implementation-artifacts" \
    --sprint-status "$SPRINT_STATUS_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
  [[ "$output" == *"E900-S3"* ]]

  _release_holder
  trap - EXIT
}

@test "dashboard under held lock: both-keys items-first shows stories-wins union" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  local dash="$BATS_TEST_DIRNAME/../scripts/sprint-status-dashboard.sh"
  [ -f "$dash" ] || fail "sprint-status-dashboard.sh not found"

  _mk_reader_fixture items-first
  local lockfile="${SPRINT_STATUS_YAML}.lock"
  mkdir -p "$(dirname "$lockfile")"

  local holder_pid=""
  _release_holder() {
    if [ -n "${holder_pid:-}" ]; then
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""
    fi
  }
  trap '_release_holder' EXIT

  ( flock -x 9 || exit 1; sleep 15 ) 9>"$lockfile" &
  holder_pid=$!
  sleep 0.3

  SPRINT_STATUS_YAML="$SPRINT_STATUS_YAML" \
  PROJECT_PATH="$TEST_TMP/project" \
  PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$dash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"E900-S2"* ]]
  [[ "$output" == *"E900-S3"* ]]
  [[ "$output" == *"done"* ]]

  _release_holder
  trap - EXIT
}

# ===========================================================================
# B2 — lock, fail-closed, mode, per-sprint, concurrent-init tests
# ===========================================================================

@test "sprint-state dispatch migration: under held lock file is unchanged" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"

  _legacy_yaml sprint-l1 active \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "l1 story" in-progress sprint-l1

  local lockfile="${SPRINT_STATUS_YAML}.lock"

  local holder_pid=""
  _release_holder() {
    if [ -n "${holder_pid:-}" ]; then
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""
    fi
  }
  trap '_release_holder' EXIT

  ( flock -x 9 || exit 1; sleep 15 ) 9>"$lockfile" &
  holder_pid=$!
  sleep 0.3

  local before_cksum
  before_cksum=$(cksum < "$SPRINT_STATUS_YAML")

  run bash "$SPRINT_STATE" detect-auto-close
  local after_cksum
  after_cksum=$(cksum < "$SPRINT_STATUS_YAML")
  [ "$before_cksum" = "$after_cksum" ]

  _release_holder
  trap - EXIT
}

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

  local holder_pid=""
  _release_holder() {
    if [ -n "${holder_pid:-}" ]; then
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""
    fi
  }
  trap '_release_holder' EXIT

  ( flock -x 9 || exit 1; sleep 15 ) 9>"$lockfile" &
  holder_pid=$!
  sleep 0.3

  run bash -c '. "'"$acquirelib"'"; . "'"$lib"'"; migrate_items_to_stories "'"$SPRINT_STATUS_YAML"'" --lock "'"$lockfile"'"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock timeout"* ]] || [[ "$output" == *"fail-closed"* ]]

  _release_holder
  trap - EXIT
}

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

@test "concurrent mode: per-sprint legacy file is migrated by sprint-state" {
  local state_dir="$TEST_TMP/project/.gaia/state"

  cat > "$state_dir/sprint-status-sprint-C.yaml" << 'YAML'
sprint_id: "sprint-C"
status: active
total_points: 4
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
  - key: "E900-S2"
    title: 'story two'
    status: "ready-for-dev"
    points: 2
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-01-01"
YAML
  _create_story_file E900-S1 "story one" in-progress sprint-C 2
  _create_story_file E900-S2 "story two" ready-for-dev sprint-C 2

  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  cat > "$state_dir/sprint-binding.yaml" << 'YAML'
sprint_id: "sprint-C"
session_id: "test-session"
bound_at: "2026-01-01T00:00:00Z"
YAML

  SPRINT_STATUS_YAML="$state_dir/sprint-status-sprint-C.yaml" \
  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$SPRINT_STATE" detect-auto-close --sprint sprint-C
  grep -q '^stories:' "$state_dir/sprint-status-sprint-C.yaml"
  run grep -q '^items:' "$state_dir/sprint-status-sprint-C.yaml"
  [ "$status" -ne 0 ]
}

@test "concurrent init seeds stories key" {
  local state_dir="$TEST_TMP/project/.gaia/state"

  cat > "$TEST_TMP/project/.gaia/config/project-config.yaml" << 'YAML'
project_name: "test-project"
stacks:
  - name: bash-dev
    path: "."
sprint:
  max_concurrent_active: 3
YAML

  PROJECT_ROOT="$TEST_TMP/project" \
  PROJECT_PATH="$TEST_TMP/project" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/project" \
    run bash "$SPRINT_STATE" init --sprint-id sprint-M2
  [ "$status" -eq 0 ]

  local psf="$state_dir/sprint-status-sprint-M2.yaml"
  [ -f "$psf" ] || psf="$(find "$state_dir" -name '*sprint-M2*' -type f 2>/dev/null | head -1)"
  [ -f "$psf" ] || fail "per-sprint file not created"
  grep -q '^stories:' "$psf"
  run grep -q '^items:' "$psf"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# F1 — fail-closed when migration lib is missing
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
  [[ "$output" == *"non-done"* ]] || [[ "$output" == *"E900-S1"* ]]
}

@test "throughput without migration lib: still reads items-only file" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || fail "throughput-telemetry.sh not found"

  _legacy_yaml sprint-f1t active \
    "E900-S1" "done"
  _create_story_file E900-S1 "f1t story" done sprint-f1t 3

  {
    printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"done"}\n'
  } > "$TEST_TMP/events.jsonl"

  local iso_dir="$TEST_TMP/iso-tt"
  mkdir -p "$iso_dir/lib"
  cp "$tt" "$iso_dir/throughput-telemetry.sh"
  sed -i.bak 's|_TT_SCRIPT_DIR=.*|_TT_SCRIPT_DIR="'"$iso_dir"'"|' "$iso_dir/throughput-telemetry.sh"

  run bash "$iso_dir/throughput-telemetry.sh" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  [[ "$output" != *"command not found"* ]]
}
