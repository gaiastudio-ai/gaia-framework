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

# Sub-second timer: python3 if available, else date +%s.
_perf_now() {
  python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s
}
# Check elapsed <= budget (supports fractional seconds via python3).
_perf_check() {
  local elapsed="$1" budget="$2"
  python3 -c "import sys; sys.exit(0 if float('$elapsed') <= float('$budget') else 1)" 2>/dev/null || {
    # Fallback: integer comparison.
    local e_int="${elapsed%%.*}"
    [ "${e_int:-0}" -le "$budget" ]
  }
}

@test "30-story activation check within 5 seconds" {
  # Two 30-story sprints with disjoint touch-sets.
  create_perf_sprint "sprint-900" "active" "E900" 1 30
  create_perf_sprint "sprint-903" "planned" "E903" 1 30

  local out_f="$TEST_DIR/_30story_out.txt"
  local rc=0
  local t0 t1 elapsed
  t0="$(_perf_now)"
  bash "$IC_SCRIPT" --candidate sprint-903 --active sprint-900 > "$out_f" 2>&1 || rc=$?
  t1="$(_perf_now)"
  elapsed="$(python3 -c "print($t1-$t0)" 2>/dev/null || echo "$((${t1%%.*} - ${t0%%.*}))")"

  [ "$rc" -eq 0 ]
  /usr/bin/grep -q "PASS rules (c),(d):" "$out_f"
  _perf_check "$elapsed" 5
}

@test "3-sprint re-check within 5 seconds" {
  # 3 active sprints of 15 stories each, plus candidate (60 stories total).
  # Cold re-check budget: 5s (user ruling moved 2s to warm-cache gate).
  create_perf_sprint "sprint-900" "active" "E900" 1 15
  create_perf_sprint "sprint-901" "active" "E901" 1 15
  create_perf_sprint "sprint-902" "active" "E902" 1 15
  create_perf_sprint "sprint-903" "planned" "E903" 1 15

  # Call directly (no bats `run` subshell overhead) with inline timing.
  local out_f="$TEST_DIR/_3sprint_out.txt"
  local rc=0
  local t0 t1 elapsed
  t0="$(_perf_now)"
  bash "$IC_SCRIPT" --candidate sprint-903 > "$out_f" 2>&1 || rc=$?
  t1="$(_perf_now)"
  elapsed="$(python3 -c "print($t1-$t0)" 2>/dev/null || echo "$((${t1%%.*} - ${t0%%.*}))")"

  [ "$rc" -eq 0 ]
  /usr/bin/grep -q "PASS rules (c),(d):" "$out_f"
  _perf_check "$elapsed" 5
}

@test "500 glob patterns expansion within 3 seconds" {
  # Tests the glob-expansion phase only (_expand_globs), not the full check.
  # 500 glob patterns, each matching one file under PROJECT_ROOT.
  local g=0
  while [ "$g" -lt 500 ]; do
    mkdir -p "$TEST_DIR/gaia-public/perf-globs/d${g}"
    touch "$TEST_DIR/gaia-public/perf-globs/d${g}/f.sh"
    g=$((g + 1))
  done

  # Build patterns file (one glob per line).
  local patterns_f="$TEST_DIR/patterns.txt"
  : > "$patterns_f"
  g=0
  while [ "$g" -lt 500 ]; do
    printf 'gaia-public/perf-globs/d%d/*.sh\n' "$g" >> "$patterns_f"
    g=$((g + 1))
  done

  # Test the glob expansion phase via a wrapper script that sources
  # independence-check.sh and calls _expand_globs directly.
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local wrapper="$TEST_DIR/expand_wrapper.sh"
  cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL
export PROJECT_ROOT="$TEST_DIR"
export CLAUDE_PROJECT_ROOT="$TEST_DIR"
export GAIA_SKIP_ORPHAN_SWEEP=1
export GAIA_SNAPSHOT_HOOK_DISABLE=1
. "$PLUGIN_ROOT/scripts/lib/touch-set-sanitizer.sh"
. "$PLUGIN_ROOT/scripts/lib/exec-with-timeout.sh"
. "$PLUGIN_ROOT/scripts/independence-check.sh" 2>/dev/null || true
_expand_globs "\$1" "\$2" "\$3"
WRAP
  chmod +x "$wrapper"

  local output_f="$TEST_DIR/expanded.txt"
  local t0 t1 elapsed
  t0="$(_perf_now)"
  bash "$wrapper" "$patterns_f" "$TEST_DIR" "$output_f"
  t1="$(_perf_now)"
  elapsed="$(python3 -c "print($t1-$t0)" 2>/dev/null || echo "$((${t1%%.*} - ${t0%%.*}))")"

  # Verify expansion found the files.
  local line_count
  line_count="$(wc -l < "$output_f" | tr -d ' ')"
  [ "$line_count" -ge 500 ]

  _perf_check "$elapsed" 3
}
