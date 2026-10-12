#!/usr/bin/env bats
# sprint-progress-snapshot-perf.bats — performance budget tests for the sprint
# progress snapshot: cold < 1.5 s, warm < 200 ms (exact, no CI multiplier),
# and batched find resolution on a realistic tree.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"

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
# Timing helper — nanosecond-resolution where available
# ---------------------------------------------------------------------------

# _now_ns — print the current epoch in nanoseconds.
# Uses date +%s%N (GNU), gdate +%s%N (Homebrew), or perl fallback.
_now_ns() {
  # GNU coreutils
  local ns
  ns="$(date +%s%N 2>/dev/null)" || ns=""
  if [ -n "$ns" ] && [ "$ns" != "%N" ] && [ "${#ns}" -gt 10 ]; then
    printf '%s' "$ns"
    return 0
  fi
  # Homebrew gdate
  ns="$(gdate +%s%N 2>/dev/null)" || ns=""
  if [ -n "$ns" ] && [ "$ns" != "%N" ] && [ "${#ns}" -gt 10 ]; then
    printf '%s' "$ns"
    return 0
  fi
  # Perl fallback (microsecond resolution, padded to ns)
  perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1e9' 2>/dev/null
}

# _elapsed_ms — print elapsed milliseconds between two nanosecond timestamps.
_elapsed_ms() {
  local start="$1" end="$2"
  printf '%s' "$(( (end - start) / 1000000 ))"
}

# ---------------------------------------------------------------------------
# Fixture generator — 30-story sprint with realistic structure
# ---------------------------------------------------------------------------

_generate_30_story_sprint() {
  local statuses=("done" "in-progress" "review" "blocked" "ready-for-dev")
  local yaml_stories=""
  local total_pts=0
  local i key status pts

  for i in $(seq 1 30); do
    key="E900-S${i}"
    status="${statuses[$(( (i - 1) % 5 ))]}"
    pts=$(( (i % 8) + 1 ))
    total_pts=$((total_pts + pts))

    # Create story file
    local slug
    slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-perf"
    local dir="$IMPL/epic-perf/${key}-${slug}"
    mkdir -p "$dir"
    cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Performance test story ${i} with enough text to exercise parsing"
status: ${status}
points: ${pts}
manual_verification: false
depends_on: []
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Build the component
- [ ] Task 2: Wire integration
- [x] Task 3: Write unit tests
- [ ] Task 4: Review and polish
- [x] Task 5: Update docs

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

## Definition of Done

- [x] All done
EOF

    yaml_stories="${yaml_stories}
  - key: \"${key}\"
    title: \"Performance test story ${i}\"
    status: \"${status}\"
    points: ${pts}
    risk_level: \"medium\"
    assignee: null
    blocked_by: null
    updated: \"2026-10-01\"
    phase: $(( (i - 1) / 10 + 1 ))"
  done

  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-perf"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: ${total_pts}
velocity_capacity: 120
goals:
  - "Performance validation"
stories:${yaml_stories}
EOF
}

# ---------------------------------------------------------------------------
# Performance budget tests
# ---------------------------------------------------------------------------

@test "cold run under 1.5 seconds with 30 story fixtures" {
  _generate_30_story_sprint

  # Best of 3 runs to absorb scheduler noise
  local best_ms=999999
  local attempt
  for attempt in 1 2 3; do
    # Remove cache and sidecar for a cold start
    rm -f "$CACHE" "$SIDECAR"

    local t_start t_end elapsed
    t_start="$(_now_ns)"
    run "$SCRIPT"
    t_end="$(_now_ns)"
    [ "$status" -eq 0 ]

    elapsed="$(_elapsed_ms "$t_start" "$t_end")"
    if [ "$elapsed" -lt "$best_ms" ]; then
      best_ms="$elapsed"
    fi
  done

  # Budget: cold < 1500 ms (exact, no CI multiplier)
  printf 'Best cold run: %s ms (budget: 1500 ms)\n' "$best_ms"
  [ "$best_ms" -lt 1500 ]

  # Validate the cache is complete
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]
}

@test "warm run under 200 milliseconds with unchanged files" {
  _generate_30_story_sprint

  # Cold run to prime the cache and sidecar
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  [ -f "$SIDECAR" ]

  # Best of 3 warm runs
  local best_ms=999999
  local attempt
  for attempt in 1 2 3; do
    local t_start t_end elapsed
    t_start="$(_now_ns)"
    run "$SCRIPT"
    t_end="$(_now_ns)"
    [ "$status" -eq 0 ]

    elapsed="$(_elapsed_ms "$t_start" "$t_end")"
    if [ "$elapsed" -lt "$best_ms" ]; then
      best_ms="$elapsed"
    fi
  done

  # Budget: warm < 200 ms (exact, no CI multiplier)
  printf 'Best warm run: %s ms (budget: 200 ms)\n' "$best_ms"
  [ "$best_ms" -lt 200 ]
}

@test "batched find resolves paths in realistic tree of thousands of files" {
  _generate_30_story_sprint

  # Pad the implementation-artifacts tree with 2000 decoy files to stress
  # the batched find resolution
  local decoy_dir="$IMPL/epic-decoy"
  mkdir -p "$decoy_dir"
  local j
  for j in $(seq 1 200); do
    mkdir -p "$decoy_dir/noise-${j}"
    # 10 .md files per directory = 2000 total decoy files
    local k
    for k in $(seq 1 10); do
      printf -- '---\ntemplate: other\n---\n# Noise\n' > "$decoy_dir/noise-${j}/file-${k}.md"
    done
  done

  # Cold run on the expanded tree
  rm -f "$CACHE" "$SIDECAR"

  local best_ms=999999
  local attempt
  for attempt in 1 2 3; do
    rm -f "$CACHE" "$SIDECAR"
    local t_start t_end elapsed
    t_start="$(_now_ns)"
    run "$SCRIPT"
    t_end="$(_now_ns)"
    [ "$status" -eq 0 ]

    elapsed="$(_elapsed_ms "$t_start" "$t_end")"
    if [ "$elapsed" -lt "$best_ms" ]; then
      best_ms="$elapsed"
    fi
  done

  # Still within cold budget even with thousands of decoy files
  printf 'Best cold run with %s decoy files: %s ms (budget: 1500 ms)\n' \
    "2000" "$best_ms"
  [ "$best_ms" -lt 1500 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]
}
