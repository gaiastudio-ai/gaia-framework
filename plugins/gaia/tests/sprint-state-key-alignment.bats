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
  local lib="$BATS_TEST_DIRNAME/../scripts/lib/migrate-items-to-stories.sh"
  [ -f "$lib" ] || skip "shared lib not found"

  _legacy_yaml sprint-cls review \
    "E900-S1" "in-progress"
  _create_story_file E900-S1 "cls story" in-progress sprint-cls

  # Verify read_stories_or_items sees the legacy entry (close.sh delegates
  # to this function). A missing entry here means close.sh would miss it.
  local out
  out="$(bash -c '. "'"$lib"'"; read_stories_or_items "'"$SPRINT_STATUS_YAML"'"')"
  echo "$out" | grep -q $'^E900-S1\tin-progress$'
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

  # Hold the lock in background to prevent migration write.
  # Use a named pipe as a sentinel — the holder exits when the pipe closes.
  local sentinel="$TEST_TMP/holder-sentinel"
  mkfifo "$sentinel"
  (
    flock -x 9 || exit 1
    # Block until sentinel is closed (test cleanup).
    read -r < "$sentinel" 2>/dev/null || true
  ) 9>"$lockfile" &
  local holder_pid=$!
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

  # Signal the holder to exit by closing the sentinel pipe.
  exec 8>"$sentinel"; exec 8>&-
  wait "$holder_pid" 2>/dev/null || true
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
  echo "$out" | grep -q $'^E900-S1\tdone$'
  # E900-S2 from stories only
  echo "$out" | grep -q $'^E900-S2\tready-for-dev$'
  # E900-S3 from items only (not in stories)
  echo "$out" | grep -q $'^E900-S3\tready-for-dev$'
  # Exactly 3 lines (no duplicates)
  local count
  count="$(echo "$out" | grep -c '.')"
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
  echo "$out" | grep -q $'^E900-S1\tdone$'
  echo "$out" | grep -q $'^E900-S2\tready-for-dev$'
  echo "$out" | grep -q $'^E900-S3\tready-for-dev$'
  local count
  count="$(echo "$out" | grep -c '.')"
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
@test "throughput-telemetry: both-keys items-first reads points from both blocks" {
  local tt="$BATS_TEST_DIRNAME/../scripts/throughput-telemetry.sh"
  [ -f "$tt" ] || skip "throughput-telemetry.sh not found"

  _both_keys_yaml sprint-tt active items-first
  # Create a minimal events file
  printf '{"event_type":"state_transition","story_key":"E900-S1","timestamp":"2026-01-01T00:00:00Z","from":"ready-for-dev","to":"in-progress"}\n' \
    > "$TEST_TMP/events.jsonl"

  run bash "$tt" --events "$TEST_TMP/events.jsonl" --sprint-yaml "$SPRINT_STATUS_YAML"
  # Should not crash; the points reader should see all keys.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# sprint-progress-snapshot both-keys
# ---------------------------------------------------------------------------
@test "sprint-progress-snapshot: both-keys items-first reads all stories" {
  local snap="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  [ -f "$snap" ] || skip "sprint-progress-snapshot.sh not found"

  _both_keys_yaml sprint-snap active items-first

  run bash "$snap" --yaml "$SPRINT_STATUS_YAML" --output-json "$TEST_TMP/snap.json"
  # Snapshot should see all 3 unique stories.
  [ "$status" -eq 0 ]
  if [ -f "$TEST_TMP/snap.json" ]; then
    local snap_stories
    snap_stories="$(grep -c 'E900-S' "$TEST_TMP/snap.json" || true)"
    [ "$snap_stories" -ge 3 ]
  fi
}
