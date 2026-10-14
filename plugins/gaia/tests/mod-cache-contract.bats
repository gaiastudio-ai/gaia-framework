#!/usr/bin/env bats
# mod-cache-contract.bats -- Cache schema contract between the snapshot
# script and the hooks module. Builds a fixture project with synthetic keys,
# runs the REAL snapshot script, and pins every field path the module and
# its tests read, including those sanitizeCache gives a per-field limit.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNAPSHOT="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  FIXTURE="$BATS_TEST_TMPDIR/cache-contract"
  local stories="$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900"
  mkdir -p "$FIXTURE/.gaia/config" "$FIXTURE/.gaia/state" \
    "$stories/E900-S1-test-story" "$stories/E900-S2-test-story"

  cat > "$FIXTURE/.gaia/config/project-config.yaml" <<'YAML'
project_name: cache-contract-test
stacks:
  - name: shell
    path: "."
YAML

  # The sprint yaml says E900-S1 is in review while its story file says
  # in-progress, which yields a drift entry.
  cat > "$FIXTURE/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-test-1"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 8
goals:
  - "Test sprint for cache contract"
capacity_utilization: "80%"
epic_focus: "E900"
stories:
  - key: "E900-S1"
    title: "Test story one"
    status: "review"
    points: 5
    phase: 1
    risk_level: "high"
    blocked_by: "E900-S2"
  - key: "E900-S2"
    title: "Test story two"
    status: "done"
    points: 3
    phase: 1
YAML

  # E900-S1 needs a manual test and has all six gates passed, which yields an
  # action_needed entry.
  cat > "$stories/E900-S1-test-story/story.md" <<'STORY'
---
id: E900-S1
title: "Test story one"
status: in-progress
points: 5
phase: 1
epic_id: E900
priority: medium
manual_verification: true
created_at: "2026-10-01"
---
# Test story one

## Tasks / Subtasks

- [x] First task
- [ ] Second task

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | - |
| QA Tests | PASSED | - |
| Security Review | PASSED | - |
| Test Automation | PASSED | - |
| Test Review | PASSED | - |
| Performance Review | PASSED | - |
STORY

  cat > "$stories/E900-S2-test-story/story.md" <<'STORY'
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

  CACHE_FILE="$FIXTURE/.gaia/state/.sprint-progress-cache.json"
}

@test "real snapshot output contains every field path the module reads" {
  [ -x "$SNAPSHOT" ] || false

  run env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT"
  echo "snapshot output: $output"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ] || false

  # Each path must exist (has(), so a null value still counts) on every
  # element of the arrays it walks, and each array walked must be non-empty.
  run jq -e '
    [
      (.schema_version | type == "string"),
      (.sprint | type == "object"),
      (.sprint | has("id") and has("goal") and has("status") and has("capacity_utilization") and has("epic_focus")),
      (.sprint.status == "active"),
      (.sprint.goal == "Test sprint for cache contract"),
      (.sprint.capacity_utilization == "80%"),
      (.sprint.epic_focus == "E900"),
      (.totals | type == "object"),
      (.stories | length == 2),
      (.stories | all(has("key") and has("title") and has("slug") and has("status") and has("blocked_by") and has("risk_level") and has("tasks") and has("gates"))),
      (.stories[0].blocked_by == "E900-S2"),
      (.stories[0].risk_level == "high"),
      ([.stories[].tasks.items[]] | length == 2),
      ([.stories[].tasks.items[]] | all(has("text") and (.text | type == "string"))),
      ([.stories[].gates.rows[]] | length >= 6),
      ([.stories[].gates.rows[]] | all(has("name") and has("status"))),
      (.drift | length == 1),
      (.drift | all(has("story_key") and has("type") and has("detail"))),
      (.action_needed | length >= 1),
      (.action_needed | all(has("message") and has("command") and (.message | type == "string") and (.command | type == "string"))),
      (.phases | type == "array"),
      (.user_aliases | type == "array")
    ] | to_entries | map(select(.value != true) | .key) | if length == 0 then true else error("failed checks: \(.)") end
  ' "$CACHE_FILE"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "cache output parses as a JSON object in node" {
  [ -x "$SNAPSHOT" ] || false

  run env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ] || false

  run node -e '
const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (!d || typeof d !== "object" || Array.isArray(d)) process.exit(1);
' "$CACHE_FILE"
  [ "$status" -eq 0 ]
}
