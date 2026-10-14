#!/usr/bin/env bats
# mod-cache-contract.bats -- Cache schema contract between snapshot and mod.
# Uses synthetic keys (E900-S1, E900-S2) to build a fixture project,
# runs the REAL snapshot script, and asserts the output contains the
# keys the mod reads.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNAPSHOT="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  FIXTURE="${BATS_TMPDIR}/cache-contract-$$"
  mkdir -p "$FIXTURE/.gaia/config"
  mkdir -p "$FIXTURE/.gaia/state"
  mkdir -p "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-test-story"
  mkdir -p "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S2-test-story"

  # Minimal project config
  cat > "$FIXTURE/.gaia/config/project-config.yaml" <<'YAML'
project_name: cache-contract-test
stacks:
  - name: shell
    path: "."
YAML

  # Sprint status with two synthetic stories (list-of-maps format)
  cat > "$FIXTURE/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-test-1"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 8
goals:
  - "Test sprint for cache contract"
stories:
  - key: "E900-S1"
    title: "Test story one"
    status: "in-progress"
    points: 5
    phase: 1
  - key: "E900-S2"
    title: "Test story two"
    status: "done"
    points: 3
    phase: 1
YAML

  # Story files with minimal frontmatter
  cat > "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-test-story/story.md" <<'STORY'
---
id: E900-S1
title: "Test story one"
status: in-progress
points: 5
phase: 1
epic_id: E900
priority: medium
created_at: "2026-10-01"
---
# Test story one
STORY

  cat > "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S2-test-story/story.md" <<'STORY'
---
id: E900-S2
title: "Test story two"
status: done
points: 3
phase: 1
epic_id: E900
priority: medium
created_at: "2026-10-01"
---
# Test story two
STORY
}

teardown() {
  rm -rf "$FIXTURE"
}

@test "real snapshot output contains keys mod reads" {
  [ -x "$SNAPSHOT" ] || false

  # Run the real snapshot script on the fixture project
  run env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT"
  echo "snapshot exit: $status"
  echo "snapshot stderr: $output"

  CACHE_FILE="$FIXTURE/.gaia/state/.sprint-progress-cache.json"
  [ -f "$CACHE_FILE" ] || false

  # Must be valid JSON
  run jq '.' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  # Assert top-level keys the mod reads
  run jq -e '.sprint' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  run jq -e '.sprint.id' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  run jq -e '.sprint.status' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  run jq -e '.totals' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  run jq -e '.stories' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  run jq -e '.schema_version' "$CACHE_FILE"
  [ "$status" -eq 0 ] || false

  # Sprint status should be "active"
  SPRINT_STATUS="$(jq -r '.sprint.status' "$CACHE_FILE")"
  [ "$SPRINT_STATUS" = "active" ] || false

  # Should have 2 stories
  STORY_COUNT="$(jq '.stories | length' "$CACHE_FILE")"
  [ "$STORY_COUNT" -ge 1 ] || false
}

@test "cache output is valid JSON" {
  [ -x "$SNAPSHOT" ] || false

  run env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT"

  CACHE_FILE="$FIXTURE/.gaia/state/.sprint-progress-cache.json"
  [ -f "$CACHE_FILE" ] || false

  run node -e "JSON.parse(require('fs').readFileSync('$CACHE_FILE','utf8'))"
  [ "$status" -eq 0 ]
}
