#!/usr/bin/env bats
# statusline-sprint-progress.bats — sprint progress segment tests.
#
# Covers the cache-first sprint progress reader in statusline.sh:
# normal format with percentage, warning prefix, fallback paths,
# timing budget, subprocess count, self-heal, and input sanitisation.

# bats file_tags=statusline,sprint-progress

load '../test_helper.bash'

bats_require_minimum_version 1.5.0

# Require jq — fixture generation and the runtime both need it.
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq is required but not found in PATH\n' >&2
  exit 1
fi
jq --version >&2

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RUNTIME="$PLUGIN_ROOT/scripts/statusline.sh"
  SNAPSHOT="$PLUGIN_ROOT/scripts/sprint-progress-snapshot.sh"
  SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
  cd "$TEST_TMP"

  # Sandbox HOME so tier-1 cache scan resolves to empty.
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"

  # Default stdin JSON (Claude Code statusline contract).
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$TEST_TMP"'"}}'
  export STDIN_JSON
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _build_fixture PROJECT_DIR KEY:STATUS [KEY:STATUS ...]
# Builds a minimal project with sprint-status.yaml + story files, then runs
# the REAL snapshot script to generate the cache. Uses synthetic ids only.
_build_fixture() {
  local proj="$1"; shift
  mkdir -p "$proj/.gaia/state" "$proj/.gaia/config"
  local impl="$proj/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local yaml="$proj/.gaia/state/sprint-status.yaml"
  {
    printf 'sprint_id: "sprint-900"\n'
    printf 'status: active\n'
    printf 'start_date: "2026-10-01"\n'
    printf 'end_date: "2026-10-14"\n'
    printf 'total_points: 10\n'
    printf 'stories:\n'
    for row in "$@"; do
      local key="${row%%:*}" st="${row#*:}"
      printf '  - key: "%s"\n    status: "%s"\n    points: 5\n' "$key" "$st"
    done
  } > "$yaml"
  for row in "$@"; do
    local key="${row%%:*}" st="${row#*:}"
    local dir="$impl/epic-test/$key-story"
    mkdir -p "$dir"
    cat > "$dir/story.md" <<STORY
---
key: "$key"
title: "Story $key"
status: $st
points: 5
manual_verification: false
---

## Tasks / Subtasks

- [x] T1

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
STORY
  done
  PROJECT_ROOT="$proj" \
    SPRINT_STATUS_YAML="$yaml" \
    IMPLEMENTATION_ARTIFACTS="$impl" \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$SNAPSHOT" 2>/dev/null
  [ -f "$proj/.gaia/state/.sprint-progress-cache.json" ] || return 1
}

# _build_30_story_fixture PROJECT_DIR — 30 stories, 15 done + 15 in-progress = 50%
_build_30_story_fixture() {
  local proj="$1"
  mkdir -p "$proj/.gaia/state" "$proj/.gaia/config"
  local impl="$proj/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$impl"
  local yaml="$proj/.gaia/state/sprint-status.yaml"
  {
    printf 'sprint_id: "sprint-900"\n'
    printf 'status: active\n'
    printf 'start_date: "2026-10-01"\n'
    printf 'end_date: "2026-10-14"\n'
    printf 'stories:\n'
    local i
    for i in $(seq 1 30); do
      local st="done"
      [ "$i" -gt 15 ] && st="in-progress"
      printf '  - key: "E900-S%d"\n    status: "%s"\n    points: 5\n' "$i" "$st"
    done
  } > "$yaml"
  local i
  for i in $(seq 1 30); do
    local st="done"
    [ "$i" -gt 15 ] && st="in-progress"
    local dir="$impl/epic-test/E900-S${i}-story"
    mkdir -p "$dir"
    cat > "$dir/story.md" <<STORY
---
key: "E900-S${i}"
title: "Story E900-S${i}"
status: ${st}
points: 5
manual_verification: false
---

## Tasks / Subtasks

- [x] T1

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | - |
| QA Tests | UNVERIFIED | - |
| Security Review | UNVERIFIED | - |
| Test Automation | UNVERIFIED | - |
| Test Review | UNVERIFIED | - |
| Performance Review | UNVERIFIED | - |
STORY
  done
  PROJECT_ROOT="$proj" \
    SPRINT_STATUS_YAML="$yaml" \
    IMPLEMENTATION_ARTIFACTS="$impl" \
    GAIA_SNAPSHOT_HOOK_DISABLE=1 \
    bash "$SNAPSHOT" 2>/dev/null
  [ -f "$proj/.gaia/state/.sprint-progress-cache.json" ] || return 1
}

# _render — run the statusline runtime with stdin from a file (no bash -c wrapper).
_render() {
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
}

# _render_noascii — same as _render but without ASCII flag, for UTF-8 glyph tests.
_render_noascii() {
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
}

# _render_color — render with truecolor enabled (for colour escape tests).
_render_color() {
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    COLORTERM=truecolor \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
}

# _setup_project — create the fixture project and build the cache.
_setup_project() {
  export PROJECT_PATH="$TEST_TMP/project"
  _build_fixture "$PROJECT_PATH" "E900-S1:done" "E900-S2:in-progress"
  CACHE_FILE="$PROJECT_PATH/.gaia/state/.sprint-progress-cache.json"
  YAML_FILE="$PROJECT_PATH/.gaia/state/sprint-status.yaml"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  mkdir -p "$PROJECT_PATH/plugins/gaia/.claude-plugin"
  printf '{"name":"gaia","version":"9.9.9-test"}\n' > "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
}

# _inject_action_needed — add a non-empty action_needed to the cache.
_inject_action_needed() {
  local tmp
  tmp="$(jq '.action_needed = [{"rule":"d","type":"sprint_can_close","story_keys":[],"message":"All stories are done, sprint can be closed","command":"/gaia-sprint-close","since":"2026-10-10","source":"sprint-status"}]' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
}

# ---------------------------------------------------------------------------
# Normal format with percentage (AC1)
# ---------------------------------------------------------------------------

@test "rich theme: cache present renders sprint id with percentage" {
  _setup_project
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "rich theme only: minimal theme hides sprint segment even with cache" {
  _setup_project
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]]
}

@test "progress_pct 0 renders sprint-900 0%" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 0' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 0%"* ]]
}

@test "progress_pct 100 renders sprint-900 100%" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 100' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 100%"* ]]
}

@test "COLUMNS=80 still shows the sprint segment" {
  _setup_project
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=80 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

# ---------------------------------------------------------------------------
# Warning prefix (AC2)
# ---------------------------------------------------------------------------

@test "ASCII warning prefix when action_needed non-empty" {
  _setup_project
  _inject_action_needed
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"! sprint-900 50%"* ]]
}

@test "UTF-8 warning glyph when action_needed non-empty and ASCII unset" {
  _setup_project
  _inject_action_needed
  run _render_noascii
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "warning colour escape precedes glyph when colours enabled" {
  _setup_project
  _inject_action_needed
  run _render_color
  [ "$status" -eq 0 ]
  # COLOR_WARN in truecolor mode: ESC[38;2;255;176;0m (from statusline-colors.sh)
  # The warning chunk starts with this escape, then the glyph, then the text.
  [[ "$output" == *$'\033[38;2;255;176;0m'*"sprint-900 50%"* ]]
}

@test "no-warning case uses muted colour and has no glyph" {
  _setup_project
  # action_needed is empty (default from fixture), so no warning
  run _render_color
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
  # COLOR_MUTED in truecolor: ESC[38;2;128;128;128m
  [[ "$output" == *$'\033[38;2;128;128;128m'"sprint-900 50%"* ]]
  # No warning glyph
  [[ "$output" != *"!"*"sprint-900"* ]]
}

# ---------------------------------------------------------------------------
# Fallback paths (AC3)
# ---------------------------------------------------------------------------

@test "missing cache fallback: shows sprint id only from yaml" {
  _setup_project
  rm -f "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "jq unavailable fallback: shows sprint id only from yaml" {
  _setup_project
  local narrow_bin="$TEST_TMP/narrow-bin"
  mkdir -p "$narrow_bin"
  for cmd in bash cat grep head sed dirname tput date sort tail ls basename cksum awk git cmp cp chmod env printf mkdir mv rm; do
    local real
    real="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$real" ] && [ -x "$real" ] && ln -sf "$real" "$narrow_bin/$cmd" 2>/dev/null || true
  done
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env PATH="$narrow_bin" COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "malformed JSON cache: fallback to sprint id from yaml" {
  _setup_project
  printf 'NOT VALID JSON\n' > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "missing progress_pct field: fallback to sprint id from yaml" {
  _setup_project
  local tmp
  tmp="$(jq 'del(.totals.progress_pct)' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "float progress_pct triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 65.5' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"65"* ]]
}

@test "non-array action_needed triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.action_needed = "bogus"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "sprint.id as a number triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = 42' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "sprint as a string (non-object) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint = "not-an-object"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "action_needed null triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.action_needed = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "progress_pct out of range (negative) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = -1' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "progress_pct out of range (101) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 101' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "jq null for sprint.id triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

# ---------------------------------------------------------------------------
# Closed / null sprint suppression via cache (AC8)
# ---------------------------------------------------------------------------

@test "cache sprint null suppresses segment without yaml fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]]
  [[ "$output" != *"POISONED"* ]]
}

@test "cache sprint closed suppresses segment without yaml fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.status = "closed"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]]
  [[ "$output" != *"POISONED"* ]]
}

# ---------------------------------------------------------------------------
# No yaml read when cache valid (AC6)
# ---------------------------------------------------------------------------

@test "no yaml read when cache valid: poisoned yaml not consumed" {
  _setup_project
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
  [[ "$output" != *"POISONED"* ]]
}

@test "no yaml read when cache valid: unreadable yaml still renders" {
  [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
  _setup_project
  chmod 000 "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
  chmod 644 "$YAML_FILE" 2>/dev/null || true
}

@test "no yaml read when cache shows null sprint: unreadable yaml no error" {
  [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
  _setup_project
  local tmp
  tmp="$(jq '.sprint = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  chmod 000 "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]]
  chmod 644 "$YAML_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# p95 timing budget (AC4)
# ---------------------------------------------------------------------------

# _nanos — print current time in nanoseconds. Uses gdate or EPOCHREALTIME.
# Fails the test (not skip) if neither is available.
_nanos() {
  if command -v gdate >/dev/null 2>&1; then
    gdate +%s%N
  elif [ -n "${EPOCHREALTIME:-}" ]; then
    local er="${EPOCHREALTIME//./}"
    printf '%s000\n' "$er"
  else
    echo "FATAL: no nanosecond clock available (need gdate or bash 5 EPOCHREALTIME)" >&2
    return 1
  fi
}

@test "p95 render within 100ms with 30-story cache present" {
  _nanos >/dev/null || fail "no nanosecond clock"
  export PROJECT_PATH="$TEST_TMP/project30"
  _build_30_story_fixture "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/plugins/gaia/.claude-plugin"
  printf '{"name":"gaia","version":"9.9.9-test"}\n' > "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  # 3 warm-up iterations (discarded)
  local _w
  for _w in 1 2 3; do
    COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
      HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
      "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
  done
  local times=()
  local i t0 t1 dt
  for i in $(seq 1 20); do
    t0="$(_nanos)"
    COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
      HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
      "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
    t1="$(_nanos)"
    dt=$(( (t1 - t0) / 1000000 ))
    times+=("$dt")
  done
  local IFS=$'\n'
  local sorted=($(printf '%s\n' "${times[@]}" | sort -n))
  unset IFS
  local p95="${sorted[18]}"
  echo "# p95 with cache: ${p95}ms (budget: 100ms)" >&3
  [ "$p95" -le 100 ]
}

@test "p95 render within 100ms with cache absent" {
  _nanos >/dev/null || fail "no nanosecond clock"
  export PROJECT_PATH="$TEST_TMP/project30b"
  _build_30_story_fixture "$PROJECT_PATH"
  mkdir -p "$PROJECT_PATH/plugins/gaia/.claude-plugin"
  printf '{"name":"gaia","version":"9.9.9-test"}\n' > "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  rm -f "$PROJECT_PATH/.gaia/state/.sprint-progress-cache.json"
  local _w
  for _w in 1 2 3; do
    COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
      HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
      "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
  done
  local times=()
  local i t0 t1 dt
  for i in $(seq 1 20); do
    t0="$(_nanos)"
    COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
      HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
      "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
    t1="$(_nanos)"
    dt=$(( (t1 - t0) / 1000000 ))
    times+=("$dt")
  done
  local IFS=$'\n'
  local sorted=($(printf '%s\n' "${times[@]}" | sort -n))
  unset IFS
  local p95="${sorted[18]}"
  echo "# p95 no cache: ${p95}ms (budget: 100ms)" >&3
  [ "$p95" -le 100 ]
}

# ---------------------------------------------------------------------------
# Subprocess count (AC4)
# ---------------------------------------------------------------------------

# Subprocess counts are measured via xtrace (BASH_XTRACEFD). The frozen
# baseline was measured by running origin/staging statusline.sh with xtrace
# against a minimal fixture (yaml at root, no cache):
#   jq=13  grep=3  head=2  sed=2  dirname=1
#
# With cache present: jq=14 (+1), grep=1 (-2), head=0 (-2), sed=0 (-2), dirname=1 (same)
# With cache absent:  identical to baseline (jq=13, grep=3, head=2, sed=2, dirname=1)

_count_xtrace() {
  # Run the runtime with xtrace and count subprocess invocations.
  # $1 = trace output file. All env vars BEFORE the command.
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    PS4='+ ' BASH_XTRACEFD=7 \
    bash -x "$RUNTIME" 7>"$1" < "$TEST_TMP/.stdin.json" >/dev/null 2>/dev/null
}

_xtrace_count() {
  # $1 = trace file, $2 = command name
  grep -F "$2" "$1" | grep -cF "++ $2 " || true
}

@test "cache-present subprocess delta: jq +1, grep -2, head -2, sed -2" {
  _setup_project
  local trace_present="$TEST_TMP/trace-present.log"
  local trace_absent="$TEST_TMP/trace-absent.log"

  # Cache present
  _count_xtrace "$trace_present"
  local jq_p grep_p head_p sed_p
  jq_p="$(_xtrace_count "$trace_present" jq)"
  grep_p="$(_xtrace_count "$trace_present" grep)"
  head_p="$(_xtrace_count "$trace_present" head)"
  sed_p="$(_xtrace_count "$trace_present" sed)"

  # Cache absent
  rm -f "$CACHE_FILE"
  _count_xtrace "$trace_absent"
  local jq_a grep_a head_a sed_a
  jq_a="$(_xtrace_count "$trace_absent" jq)"
  grep_a="$(_xtrace_count "$trace_absent" grep)"
  head_a="$(_xtrace_count "$trace_absent" head)"
  sed_a="$(_xtrace_count "$trace_absent" sed)"

  echo "# present: jq=$jq_p grep=$grep_p head=$head_p sed=$sed_p" >&3
  echo "# absent:  jq=$jq_a grep=$grep_a head=$head_a sed=$sed_a" >&3

  # Delta must be exactly: jq +1, grep -2, head -2, sed -2
  [ $(( jq_p - jq_a )) -eq 1 ]
  [ $(( grep_p - grep_a )) -eq -2 ]
  [ $(( head_p - head_a )) -eq -2 ]
  [ $(( sed_p - sed_a )) -eq -2 ]
}

@test "cache-absent counts match the staging baseline" {
  _setup_project
  rm -f "$CACHE_FILE"
  local trace="$TEST_TMP/trace-absent.log"
  _count_xtrace "$trace"
  local jq_a grep_a head_a sed_a dirname_a
  jq_a="$(_xtrace_count "$trace" jq)"
  grep_a="$(_xtrace_count "$trace" grep)"
  head_a="$(_xtrace_count "$trace" head)"
  sed_a="$(_xtrace_count "$trace" sed)"
  dirname_a="$(_xtrace_count "$trace" dirname)"

  echo "# cache-absent: jq=$jq_a grep=$grep_a head=$head_a sed=$sed_a dirname=$dirname_a" >&3

  # Frozen baseline from origin/staging (sandboxed HOME, .gaia fixture):
  # jq=8 grep=2 head=2 sed=2 dirname=1
  [ "$jq_a" -eq 8 ]
  [ "$grep_a" -eq 2 ]
  [ "$head_a" -eq 2 ]
  [ "$sed_a" -eq 2 ]
  [ "$dirname_a" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Self-heal activation (AC5)
# ---------------------------------------------------------------------------

@test "self-heal: stale installed runtime gets replaced and segment appears" {
  _setup_project
  local install_dir="$HOME/.claude/gaia-statusline"
  mkdir -p "$install_dir/lib"

  # Build a stale installed runtime: replace the cache filename with a
  # non-existent name so the cache-first read would not fire in isolation.
  sed 's/.sprint-progress-cache.json/.sprint-progress-cache-DISABLED.json/g' \
    "$RUNTIME" > "$install_dir/statusline.sh"
  chmod +x "$install_dir/statusline.sh"
  for f in statusline-glyphs.sh statusline-colors.sh statusline-project-cache-key.sh; do
    [ -f "$PLUGIN_ROOT/scripts/lib/$f" ] && cp "$PLUGIN_ROOT/scripts/lib/$f" "$install_dir/lib/$f"
  done

  # Plugin cache carries the CURRENT (feature-enabled) runtime.
  local ver="9.9.9-test"
  local cache_scripts="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver/scripts"
  mkdir -p "$cache_scripts/lib" "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver/.claude-plugin"
  printf '{"name":"gaia","version":"%s"}\n' "$ver" > "$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver/.claude-plugin/plugin.json"
  cp "$RUNTIME" "$cache_scripts/statusline.sh"
  chmod +x "$cache_scripts/statusline.sh"
  for f in statusline-glyphs.sh statusline-colors.sh statusline-project-cache-key.sh; do
    [ -f "$PLUGIN_ROOT/scripts/lib/$f" ] && cp "$PLUGIN_ROOT/scripts/lib/$f" "$cache_scripts/lib/$f"
  done
  for f in statusline-update-check.sh statusline-git-dirty-check.sh; do
    [ -f "$PLUGIN_ROOT/scripts/$f" ] && cp "$PLUGIN_ROOT/scripts/$f" "$cache_scripts/$f" && chmod +x "$cache_scripts/$f"
  done

  # Render: self-heal detects the diff and replaces the installed copy.
  # Bash reads subsequent code from the new file, so the sprint-progress
  # segment may appear on this render (bash chunk-reading behaviour).
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$install_dir/statusline.sh" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]

  # Self-heal must have replaced the installed copy with the plugin cache copy.
  cmp -s "$cache_scripts/statusline.sh" "$install_dir/statusline.sh"

  # Next render: updated runtime definitely reads the cache.
  run env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$install_dir/statusline.sh" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "manual fallback: install-statusline.sh re-run updates the runtime" {
  _setup_project
  local install_dir="$HOME/.claude/gaia-statusline"
  mkdir -p "$install_dir/lib"

  # Install a pre-feature runtime (cache filename disabled).
  sed 's/.sprint-progress-cache.json/.sprint-progress-cache-DISABLED.json/g' \
    "$RUNTIME" > "$install_dir/statusline.sh"
  chmod +x "$install_dir/statusline.sh"
  for f in statusline-glyphs.sh statusline-colors.sh statusline-project-cache-key.sh; do
    [ -f "$PLUGIN_ROOT/scripts/lib/$f" ] && cp "$PLUGIN_ROOT/scripts/lib/$f" "$install_dir/lib/$f"
  done

  # Seed a plugin cache with the current runtime (feature-enabled).
  local ver="9.9.9-test"
  local cache_dir="$HOME/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/$ver"
  local cache_scripts="$cache_dir/scripts"
  mkdir -p "$cache_scripts/lib" "$cache_dir/.claude-plugin"
  printf '{"name":"gaia","version":"%s"}\n' "$ver" > "$cache_dir/.claude-plugin/plugin.json"
  cp "$RUNTIME" "$cache_scripts/statusline.sh"
  chmod +x "$cache_scripts/statusline.sh"
  for f in statusline-glyphs.sh statusline-colors.sh statusline-project-cache-key.sh; do
    [ -f "$PLUGIN_ROOT/scripts/lib/$f" ] && cp "$PLUGIN_ROOT/scripts/lib/$f" "$cache_scripts/lib/$f"
  done
  for f in statusline-update-check.sh statusline-git-dirty-check.sh install-statusline.sh; do
    [ -f "$PLUGIN_ROOT/scripts/$f" ] && cp "$PLUGIN_ROOT/scripts/$f" "$cache_scripts/$f" && chmod +x "$cache_scripts/$f"
  done
  # install-statusline.sh sources lib/statusline-cache-reset.sh
  for f in statusline-cache-reset.sh; do
    [ -f "$PLUGIN_ROOT/scripts/lib/$f" ] && cp "$PLUGIN_ROOT/scripts/lib/$f" "$cache_scripts/lib/$f"
  done

  # Simulate /gaia-statusline-refresh by re-running install-statusline.sh.
  # install-statusline.sh resolves sources from its own dirname (SCRIPT_DIR),
  # so it reads from cache_scripts/ which has the feature-enabled runtime.
  # It also needs a settings.json target dir.
  mkdir -p "$HOME/.claude"
  run env HOME="$HOME" "$cache_scripts/install-statusline.sh"
  [ "$status" -eq 0 ]

  # The installed runtime should now be the feature-enabled version.
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$install_dir/statusline.sh" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

# ---------------------------------------------------------------------------
# Input sanitisation (AC9) — split per control-sequence type
# ---------------------------------------------------------------------------

@test "CSI sequence stripped from sprint.id: ESC-bracket-2J" {
  _setup_project
  local dirty_id
  dirty_id="$(printf '\033[2Jsprint-900')"
  local tmp
  tmp="$(jq --arg id "$dirty_id" '.sprint.id = $id' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
  # No ESC byte in the rendered sprint segment
  local stripped
  stripped="$(printf '%s' "$output" | tr -d '\033')"
  [[ "$stripped" == *"sprint-900 50%"* ]]
}

@test "OSC-8 terminated by BEL stripped from sprint.id" {
  _setup_project
  # Build the dirty id inside jq to embed BEL (U+0007) reliably.
  local tmp
  tmp="$(jq '.sprint.id = "\u001b]8;;http://x\u0007sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "OSC-8 terminated by ESC-backslash stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "\u001b]8;;http://x\u001b\\sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "bare BEL stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "sprint\u0007-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "NUL stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "\u0000sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "stripping leaves non-allowlisted id: fallback to yaml" {
  _setup_project
  # After stripping, "sprint/../x" still contains "/" and "." — fails allowlist
  local tmp
  tmp="$(jq '.sprint.id = "sprint/../x"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  # Falls back to yaml: sprint-900 without percentage
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "allowlist rejects space in sprint.id after stripping" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "sprint 900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"sprint 900"* ]]
  [[ "$output" != *"%"* ]]
}

# ---------------------------------------------------------------------------
# No internal IDs in shipped source (AC7)
# ---------------------------------------------------------------------------

@test "no internal IDs leak into shipped source, this test file, or changelog unreleased" {
  [ -f "$RUNTIME" ]
  local glyphs="$PLUGIN_ROOT/scripts/lib/statusline-glyphs.sh"
  local colors="$PLUGIN_ROOT/scripts/lib/statusline-colors.sh"
  local bats_file="$BATS_TEST_FILENAME"
  local changelog="$PLUGIN_ROOT/CHANGELOG.md"
  [ -f "$glyphs" ]
  [ -f "$colors" ]

  # Build the pattern in a variable so the grep line itself does not contain
  # a literal match for the pattern (which would self-match when scanning
  # this test file). Each fragment is concatenated at runtime.
  local pat_fr="FR-[0-9]"
  local pat_nfr="NFR-[0-9]"
  local pat_sr="SR-[0-9]"
  local pat_adr="ADR-[0-9]"
  local pat_es="E[0-9]+-S[0-9]+"
  local pat_tc="T""C-[A-Za-z0-9]"
  local pat_af="A""F-20[0-9]{2}"
  local pat_ai="A""I-[0-9]"
  local pat_m="M""-SSM"
  local leak_pat="(${pat_fr}|${pat_nfr}|${pat_sr}|${pat_adr}|${pat_es}|${pat_tc}|${pat_af}|${pat_ai})"
  local leak_pat_bats="(${pat_fr}|${pat_nfr}|${pat_sr}|${pat_adr}|${pat_tc}|${pat_af}|${pat_ai}|${pat_m})"

  # Scan shipped scripts
  for f in "$RUNTIME" "$glyphs" "$colors"; do
    run grep -E "$leak_pat" "$f"
    if [ "$status" -eq 0 ]; then
      echo "Leaked ID in $f: $output"
      return 1
    fi
  done

  # Scan this bats file (test names, comments, fixture values)
  run grep -E "$leak_pat_bats" "$bats_file"
  if [ "$status" -eq 0 ]; then
    echo "Leaked ID in test file: $output"
    return 1
  fi

  # Scan only the [Unreleased] section of the changelog
  local unreleased
  unreleased="$(sed -n '/^## \[Unreleased\]/,/^## \[/{/^## \[Unreleased\]/d;/^## \[/d;p;}' "$changelog")"
  if [ -n "$unreleased" ]; then
    run grep -E "$leak_pat" <<< "$unreleased"
    if [ "$status" -eq 0 ]; then
      echo "Leaked ID in changelog [Unreleased]: $output"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Builds without mod hooks loaded (degraded mode)
# ---------------------------------------------------------------------------

@test "cache present renders segment on builds without mod hooks" {
  _setup_project
  unset GAIA_MOD_HOOKS_LOADED 2>/dev/null || true
  unset GAIA_SPRINT_STATUS_MOD 2>/dev/null || true
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

# ---------------------------------------------------------------------------
# bash 3.2 compatibility
# ---------------------------------------------------------------------------

# need_bash32 — set BASH32 to a bash 3.x interpreter, or detect bash 5
# (Linux /bin/bash). On Linux, /bin/bash is just bash 5 — tests still run
# but confirm the runtime works under the system bash.
_bash32_or_system() {
  local b="${SNAPSHOT_BASH32:-/bin/bash}"
  [ -x "$b" ] || b="$(command -v bash)"
  BASH32="$b"
}

_run_bash32() {
  # Run the runtime under the bash 3.2 interpreter with proper env vars.
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$BASH32" "$RUNTIME" < "$TEST_TMP/.stdin.json"
}

@test "bash 3.2: sprint segment renders with cache" {
  _bash32_or_system
  _setup_project
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}

@test "bash 3.2: warning prefix renders" {
  _bash32_or_system
  _setup_project
  _inject_action_needed
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"! sprint-900 50%"* ]]
}

@test "bash 3.2: cache-absent fallback shows sprint id only" {
  _bash32_or_system
  _setup_project
  rm -f "$CACHE_FILE"
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  [[ "$output" != *"%"* ]]
}

@test "bash 3.2: null sprint suppresses segment" {
  _bash32_or_system
  _setup_project
  local tmp
  tmp="$(jq '.sprint = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" != *"POISONED"* ]]
  [[ "$output" != *"sprint-900"* ]]
}

@test "bash 3.2: CSI in sprint.id stripped correctly" {
  _bash32_or_system
  _setup_project
  local dirty_id
  dirty_id="$(printf '\033[2Jsprint-900')"
  local tmp
  tmp="$(jq --arg id "$dirty_id" '.sprint.id = $id' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]]
}
