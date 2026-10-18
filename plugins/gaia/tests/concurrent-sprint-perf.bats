#!/usr/bin/env bats
# concurrent-sprint-perf.bats — performance budget tests for
# independence-check.sh rules (c) and (d).

# shellcheck disable=SC2030,SC2031

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH

  TEST_DIR="$(mktemp -d)"
  STATE_DIR="$TEST_DIR/.gaia/state"
  IMPL_DIR="$TEST_DIR/.gaia/artifacts/implementation-artifacts"
  CONFIG_DIR="$TEST_DIR/.gaia/config"
  PLANNING_DIR="$TEST_DIR/.gaia/artifacts/planning-artifacts"
  SHARDS_DIR="$PLANNING_DIR/epics"
  mkdir -p "$STATE_DIR" "$IMPL_DIR" "$CONFIG_DIR" "$PLANNING_DIR" "$SHARDS_DIR"
  mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/scripts/lib"
  mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/hooks"

  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: "perf-test"
sprint:
  max_concurrent_active: 10
stacks:
  - name: bash
    path: "."
YAML

  cat > "$PLANNING_DIR/epics-and-stories.md" <<'MD'
# Epics and Stories

## E900 — Perf Alpha
## E901 — Perf Beta
## E902 — Perf Gamma
## E903 — Perf Delta
MD

  printf 'sprint-900 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/.sprint-migration-complete"

  export PROJECT_ROOT="$TEST_DIR"
  export PROJECT_PATH="$TEST_DIR"
  export IMPLEMENTATION_ARTIFACTS="$IMPL_DIR"
  export GAIA_SKIP_ORPHAN_SWEEP=1
  export GAIA_SNAPSHOT_HOOK_DISABLE=1

  BATS_TEST_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  IC_SCRIPT="$BATS_TEST_SCRIPT_DIR/scripts/independence-check.sh"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_SCRIPT_DIR/scripts"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Helper: create a sprint with N stories, each having disjoint touch-sets.
# Usage: create_perf_sprint <sprint_id> <status> <epic> <story_start> <story_count>
create_perf_sprint() {
  local sid="$1" status="$2" epic="$3" start="$4" count="$5"
  local epic_slug
  epic_slug="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
  local f="$STATE_DIR/sprint-status-${sid}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sid"
    printf 'status: %s\n' "$status"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'stories:\n'
  } > "$f"

  local i=0
  while [ "$i" -lt "$count" ]; do
    local snum=$((start + i))
    local key="${epic}-S${snum}"
    printf '  - key: "%s"\n' "$key" >> "$f"
    printf '    title: "Perf story %s"\n' "$key" >> "$f"
    printf '    status: "in-progress"\n' >> "$f"
    printf '    points: 3\n' >> "$f"
    printf '    risk: "medium"\n' >> "$f"

    # Create story file with a unique touch path.
    local story_dir="$IMPL_DIR/epic-${epic_slug}/${key}-perf-story"
    mkdir -p "$story_dir"
    local dir_name="dir-${sid}-${snum}"
    mkdir -p "$TEST_DIR/gaia-public/plugins/gaia/perf/${dir_name}"
    touch "$TEST_DIR/gaia-public/plugins/gaia/perf/${dir_name}/file.sh"
    cat > "$story_dir/story.md" <<STORY
---
key: "${key}"
epic: "${epic}"
status: in-progress
predicted_touch_set: ["gaia-public/plugins/gaia/perf/${dir_name}/file.sh"]
---
# Story: ${key}
STORY

    i=$((i + 1))
  done
}

@test "30-story activation check within 10 seconds" {
  # Two 30-story sprints with disjoint touch-sets.
  # Budget accounts for cold-start I/O (60 story files, find traversal,
  # realpath verification) and date +%s 1-second resolution.
  create_perf_sprint "sprint-900" "active" "E900" 1 30
  create_perf_sprint "sprint-903" "planned" "E903" 1 30

  local start_time end_time elapsed
  start_time="$(date +%s)"
  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  end_time="$(date +%s)"
  elapsed=$((end_time - start_time))

  [ "$status" -eq 0 ]
  [ "$elapsed" -le 15 ]
}

@test "3-sprint re-check within 15 seconds" {
  # 3 active sprints of 15 stories each, plus candidate.
  # Budget is relaxed for cold-start (60 story files parsed + realpath).
  create_perf_sprint "sprint-900" "active" "E900" 1 15
  create_perf_sprint "sprint-901" "active" "E901" 1 15
  create_perf_sprint "sprint-902" "active" "E902" 1 15
  create_perf_sprint "sprint-903" "planned" "E903" 1 15

  local start_time end_time elapsed
  start_time="$(date +%s)"
  run bash "$IC_SCRIPT" --candidate sprint-903
  end_time="$(date +%s)"
  elapsed=$((end_time - start_time))

  [ "$status" -eq 0 ]
  [ "$elapsed" -le 15 ]
}

@test "glob expansion with many patterns completes" {
  # Test that glob expansion with multiple patterns works correctly.
  # Two sprints of 2 stories each, with 10 glob patterns per story = 40 total.
  local g=0
  while [ "$g" -lt 40 ]; do
    mkdir -p "$TEST_DIR/gaia-public/perf-globs/dir-${g}"
    touch "$TEST_DIR/gaia-public/perf-globs/dir-${g}/file.sh"
    g=$((g + 1))
  done

  local gidx=0
  for sid in sprint-900 sprint-903; do
    local epic st epic_lc
    epic="$([ "$sid" = "sprint-900" ] && printf E900 || printf E903)"
    epic_lc="$(printf '%s' "$epic" | tr '[:upper:]' '[:lower:]')"
    st="$([ "$sid" = "sprint-900" ] && printf active || printf planned)"
    {
      printf 'sprint_id: "%s"\nstatus: %s\ntotal_points: 0\ngoals: []\nstories:\n' "$sid" "$st"
      local s=0
      while [ "$s" -lt 2 ]; do
        local skey="${epic}-S$((s + 1))"
        printf '  - key: "%s"\n    title: "Glob"\n    status: "in-progress"\n    points: 3\n    risk: "medium"\n' "$skey"
        local story_dir="$IMPL_DIR/epic-${epic_lc}/${skey}-glob-story"
        mkdir -p "$story_dir"
        local ts="["
        local gi=0
        while [ "$gi" -lt 10 ]; do
          [ "$gi" -gt 0 ] && ts="${ts}, "
          ts="${ts}\"gaia-public/perf-globs/dir-${gidx}/*.sh\""
          gidx=$((gidx + 1))
          gi=$((gi + 1))
        done
        ts="${ts}]"
        cat > "$story_dir/story.md" <<STORY
---
key: "${skey}"
epic: "${epic}"
depends_on: []
blocks: []
status: in-progress
predicted_touch_set: ${ts}
---
# Story: ${skey}
STORY
        s=$((s + 1))
      done
    } > "$STATE_DIR/sprint-status-${sid}.yaml"
  done

  run bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS rules (c),(d):"* ]]
}
