#!/usr/bin/env bats
# sprint-progress-snapshot.bats — core functional tests for the sprint progress
# snapshot script: cache schema, totals, by-status counts, phases, per-story
# detail, detection rules, incremental refresh, and edge cases.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"

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
teardown() { common_teardown; }

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
  jq -e 'has("waiting_agent_threshold_seconds")' "$CACHE"
  # No agent_activity key
  jq -e 'has("agent_activity") | not' "$CACHE"

  # Per-story detail: tasks, gates, manual_test
  jq -e '.stories[0].tasks | has("done", "total", "items")' "$CACHE"
  jq -e '.stories[0].gates | has("passed", "total", "rows")' "$CACHE"
  jq -e '.stories[0].gates.total == 6' "$CACHE"
  jq -e '.stories[0].manual_test | has("required", "verdict")' "$CACHE"

  # waiting_agent_threshold_seconds defaults to 120
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
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
  - id: "AI-100"
    title: "Check the deploy logs"
    status: "open"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-101"
    title: "Resolved item"
    status: "resolved"
    assignee: "user"
    created_at: "2026-10-02"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = "AI-100" ]
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
  - id: "AI-200"
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
- id: "AI-300"
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
  write_story E900-S1 done 5

  # Pre-seed a valid cache
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Start a reader loop in background
  local reader_log="$TEST_TMP/reader.log"
  (
    for i in $(seq 1 20); do
      if [ -f "$CACHE" ]; then
        jq -e '.' "$CACHE" >/dev/null 2>&1 && echo "ok" >> "$reader_log" || echo "PARTIAL" >> "$reader_log"
      fi
      sleep 0.05
    done
  ) &
  local reader_pid=$!

  # Run the snapshot again (overwrite)
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  wait "$reader_pid" 2>/dev/null || true
  # No PARTIAL reads
  if [ -f "$reader_log" ]; then
    run grep -c "PARTIAL" "$reader_log"
    [ "$output" = "0" ]
  fi
}

@test "rule a and rule c coexist ordered correctly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  write_story_with_gates E900-S1 review 5 true \
    PASSED PASSED PASSED PASSED PASSED PASSED
  write_action_items <<'YAML'
items:
  - id: "AI-400"
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

@test "rule c and rule d coexist ordered correctly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:done:8"
  write_story E900-S1 done 5
  write_story E900-S2 done 8
  write_action_items <<'YAML'
items:
  - id: "AI-500"
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

  # Cold run
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SIDECAR" ]

  # Set mtime backward (simulates git checkout)
  touch -t 202501010000 "$sf"

  # Should detect backward mtime change and re-parse
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
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
  - id: "AI-600"
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
  - id: "AI-700"
    title: "Already resolved"
    status: "resolved"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-701"
    title: "Already done"
    status: "done"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-702"
    title: "Deferred"
    status: "deferred"
    assignee: "user"
    created_at: "2026-10-02"
  - id: "AI-703"
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
  awk -F'\t' -v k="E900-S1" -v mt="$new_mt" -v path="$sf" '
    $1=="story" && $2==k { print "story\t" k "\t" path "\t" mt; next }
    { print }
  ' "$SIDECAR" > "${SIDECAR}.tmp" && mv "${SIDECAR}.tmp" "$SIDECAR"

  # Warm run — files "unchanged" (sidecar matches), but the story-file mtime
  # is now > 48h from current time: stale_review must appear
  run "$SCRIPT"
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
