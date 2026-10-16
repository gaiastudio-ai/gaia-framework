#!/usr/bin/env bats
# statusline-sprint-progress.bats — sprint progress segment tests.
#
# Covers the cache-first sprint progress reader in statusline.sh:
# normal format with percentage, warning prefix, fallback paths,
# timing budget, subprocess count, self-heal, and input sanitisation.
#
# Every mid-test [[ ]] assertion ends in `|| false`: bash 3.2 does not stop a
# test on a failing [[ ]] that is not the last command, so without it the
# assertion would pass silently when bats runs under the stock macOS shell.

# bats file_tags=statusline,sprint-progress

load '../test_helper.bash'

bats_require_minimum_version 1.5.0

# Require jq — fixture generation and the runtime both need it.
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq is required but not found in PATH\n' >&2
  exit 1
fi

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

# _render_bytes FILE — render with no colour, no hyperlinks and ASCII glyphs,
# writing the raw stdout bytes to FILE and stderr to FILE.err. Used where the
# test must see bytes that bash variables cannot hold (NUL).
_render_bytes() {
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  env -u TERM_PROGRAM NO_COLOR=1 COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json" > "$1" 2> "$1.err"
}

# _assert_printable FILE — every byte in FILE is printable ASCII or a newline
# (the status line has two lines). Fails on ESC, BEL, NUL, DEL, C1 and any
# other non-ASCII byte, and prints what it found.
_assert_printable() {
  local extra
  extra="$(LC_ALL=C tr -d '\040-\176\n' < "$1" | od -An -c)"
  if [ -n "$extra" ]; then
    echo "unexpected bytes in output:$extra"
    return 1
  fi
}

# _render_bytes_within SECS FILE — _render_bytes, but fail with 124 when the
# render is still running after SECS seconds. On a timeout every reader left
# blocked on a FIFO in the fixture (FIFOS array) is released again and again
# until the render has exited on its own, so no process outlives the test;
# the render also never inherits the bats output descriptors.
_render_bytes_within() {
  local secs="$1" out="$2" pid i=0 f timed_out=0
  _render_bytes "$out" 3>&- 4>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt $((secs * 20)) ]; then
      timed_out=1
      for f in "${FIFOS[@]:-}"; do
        if [ -p "$f" ]; then { exec 9<>"$f"; exec 9>&-; } 2>/dev/null || true; fi
      done
      [ "$i" -lt $((secs * 40)) ] || { kill "$pid" 2>/dev/null || true; break; }
    fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null || true
  if [ "$timed_out" = "1" ]; then
    echo "render still running after ${secs}s"
    return 124
  fi
}

# _set_pct_literal TEXT — replace the progress_pct number in the cache with
# TEXT exactly as written (jq would normalise the literal, so sed is used).
_set_pct_literal() {
  sed "s/\"progress_pct\":[^,}]*/\"progress_pct\":$1/" "$CACHE_FILE" > "$CACHE_FILE.tmp"
  mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  grep -qF "\"progress_pct\":$1" "$CACHE_FILE"
}

# _setup_project [KEY:STATUS ...] — create the fixture project and build the
# cache with the real snapshot writer. Default: one done, one in progress.
_setup_project() {
  export PROJECT_PATH="$TEST_TMP/project"
  if [ "$#" -eq 0 ]; then
    set -- "E900-S1:done" "E900-S2:in-progress"
  fi
  _build_fixture "$PROJECT_PATH" "$@"
  CACHE_FILE="$PROJECT_PATH/.gaia/state/.sprint-progress-cache.json"
  YAML_FILE="$PROJECT_PATH/.gaia/state/sprint-status.yaml"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  mkdir -p "$PROJECT_PATH/plugins/gaia/.claude-plugin"
  printf '{"name":"gaia","version":"9.9.9-test"}\n' > "$PROJECT_PATH/plugins/gaia/.claude-plugin/plugin.json"
}

# _setup_project_all_done — every story done, so the real writer itself puts
# the "sprint can be closed" item in action_needed (100% progress).
_setup_project_all_done() {
  _setup_project "E900-S1:done" "E900-S2:done"
  [ "$(jq '.action_needed | length' "$CACHE_FILE")" -ge 1 ]
  [ "$(jq -r '.action_needed[0].type' "$CACHE_FILE")" = "sprint_can_close" ]
}

# ---------------------------------------------------------------------------
# Normal format with percentage (AC1)
# ---------------------------------------------------------------------------

@test "rich theme: cache present renders sprint id with percentage" {
  _setup_project
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
}

@test "rich theme only: minimal theme hides sprint segment even with cache" {
  _setup_project
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=minimal \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]] || false
}

@test "progress_pct 0 renders sprint-900 0%" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 0' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 0%"* ]] || false
}

@test "progress_pct 100 renders sprint-900 100%" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 100' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 100%"* ]] || false
}

@test "COLUMNS=80 still shows the sprint segment" {
  _setup_project
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=80 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
}

# ---------------------------------------------------------------------------
# Warning prefix (AC2)
# ---------------------------------------------------------------------------

@test "ASCII warning prefix when action_needed non-empty" {
  _setup_project_all_done
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"! sprint-900 100%"* ]] || false
}

@test "UTF-8 warning glyph when action_needed non-empty and ASCII unset" {
  _setup_project_all_done
  run _render_noascii
  [ "$status" -eq 0 ]
  # The warning sign U+26A0 (bytes E2 9A A0, no variation selector), a space,
  # then the segment.
  [[ "$output" == *$'\xe2\x9a\xa0'" sprint-900 100%"* ]] || false
}

@test "Nerd Font warning glyph when action_needed non-empty and Nerd Font set" {
  _setup_project_all_done
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  run env COLUMNS=200 GAIA_STATUSLINE_NERDFONT=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  # The Nerd Font triangle U+F071 (bytes EF 81 B1).
  [[ "$output" == *$'\xef\x81\xb1'" sprint-900 100%"* ]] || false
}

@test "warning colour escape precedes glyph when colours enabled" {
  _setup_project_all_done
  run _render_color
  [ "$status" -eq 0 ]
  # COLOR_WARN in truecolor mode: ESC[38;2;255;176;0m (from statusline-colors.sh)
  # The warning chunk starts with this escape, then the glyph, then the text.
  [[ "$output" == *$'\033[38;2;255;176;0m! sprint-900 100%'* ]] || false
}

@test "no-warning case uses muted colour and has no glyph" {
  _setup_project
  # action_needed is empty (default from fixture), so no warning
  run _render_color
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
  # COLOR_MUTED in truecolor: ESC[38;2;128;128;128m
  [[ "$output" == *$'\033[38;2;128;128;128m'"sprint-900 50%"* ]] || false
  # No warning glyph
  [[ "$output" != *"!"*"sprint-900"* ]] || false
}

# ---------------------------------------------------------------------------
# Fallback paths (AC3)
# ---------------------------------------------------------------------------

@test "missing cache fallback: shows sprint id only from yaml" {
  _setup_project
  rm -f "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
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
  run --separate-stderr env PATH="$narrow_bin" COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "malformed JSON cache: fallback to sprint id from yaml" {
  _setup_project
  printf 'NOT VALID JSON\n' > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "missing progress_pct field: fallback to sprint id from yaml" {
  _setup_project
  local tmp
  tmp="$(jq 'del(.totals.progress_pct)' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "float progress_pct triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 65.5' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"65"* ]] || false
}

@test "non-array action_needed triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.action_needed = "bogus"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "sprint.id as a number triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = 42' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "sprint as a string (non-object) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint = "not-an-object"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "action_needed null triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.action_needed = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "progress_pct out of range (negative) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = -1' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "progress_pct out of range (101) triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 101' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "jq null for sprint.id triggers fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = null' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "empty object cache counts as missing fields and falls back to the yaml" {
  _setup_project
  printf '{}\n' > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "top-level null cache counts as missing fields and falls back to the yaml" {
  _setup_project
  printf 'null\n' > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "integral progress_pct literals render in canonical integer form" {
  _setup_project
  local lit want
  for lit in "50.0:50" "-0:0" "1E+2:100" "5e1:50" "50.$(printf '0%.0s' $(seq 1 400)):50"; do
    want="${lit##*:}"
    _set_pct_literal "${lit%:*}"
    run --separate-stderr _render
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"sprint-900 ${want}%"* ]] || false
    [[ "$output" != *"sprint-900 ${lit%:*}%"* ]] || false
    [ "${#output}" -lt 400 ]
  done
}

@test "sprint id of 64 characters renders, 65 characters falls back" {
  _setup_project
  local id64 id65 tmp
  id64="s$(printf 'a%.0s' $(seq 1 63))"
  id65="${id64}a"
  tmp="$(jq --arg id "$id64" '.sprint.id = $id' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"$id64 50%"* ]] || false
  tmp="$(jq --arg id "$id65" '.sprint.id = $id' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" != *"$id65"* ]] || false
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "lookalike letters and digits outside ASCII fail the allowlist" {
  _setup_project
  local id tmp
  # Fullwidth digits, Arabic-Indic digits, a Cyrillic letter that looks like
  # "s", and a fullwidth letter: each must fall back to the yaml id.
  for id in 'sprint-\uff19\uff10\uff10' 'sprint-\u0669\u0660\u0660' '\u0455print-900' 'sprint-\uff38'; do
    tmp="$(jq ".sprint.id = \"$id\"" "$CACHE_FILE")"
    printf '%s\n' "$tmp" > "$CACHE_FILE"
    run --separate-stderr _render
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *"sprint-900"* ]] || false
    [[ "$output" != *"%"* ]] || false
  done
}

@test "a FIFO at the cache path is ignored and the render does not block" {
  _setup_project
  rm -f "$CACHE_FILE"
  mkfifo "$CACHE_FILE"
  FIFOS=("$CACHE_FILE")
  _render_bytes_within 5 "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900" "$TEST_TMP/out.txt"
  run grep -qF "%" "$TEST_TMP/out.txt"
  [ "$status" -ne 0 ]
}

@test "a FIFO at the yaml path is ignored and the render does not block" {
  _setup_project
  rm -f "$CACHE_FILE" "$YAML_FILE"
  mkfifo "$YAML_FILE"
  FIFOS=("$YAML_FILE")
  _render_bytes_within 5 "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  run grep -qF "sprint-" "$TEST_TMP/out.txt"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Shared walk-up from the project root
# ---------------------------------------------------------------------------

@test "walk-up finds the cache and yaml two levels above the project root" {
  local top="$TEST_TMP/top"
  _build_fixture "$top" "E900-S1:done" "E900-S2:in-progress"
  export PROJECT_PATH="$top/sub/project"
  mkdir -p "$PROJECT_PATH"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
}

@test "walk-up: invalid cache at the project root falls back to the yaml one level up" {
  local top="$TEST_TMP/top"
  _build_fixture "$top" "E900-S1:done" "E900-S2:in-progress"
  export PROJECT_PATH="$top/project"
  mkdir -p "$PROJECT_PATH/.gaia/state"
  # Cache at depth 0 with an invalid percentage; no yaml at depth 0.
  jq '.totals.progress_pct = 65.5' "$top/.gaia/state/.sprint-progress-cache.json" \
    > "$PROJECT_PATH/.gaia/state/.sprint-progress-cache.json"
  rm -f "$top/.gaia/state/.sprint-progress-cache.json"
  STDIN_JSON='{"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"'"$PROJECT_PATH"'"}}'
  run --separate-stderr _render
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
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
  [[ "$output" != *"sprint-900"* ]] || false
  [[ "$output" != *"POISONED"* ]] || false
}

@test "cache sprint closed suppresses segment without yaml fallback" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.status = "closed"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-900"* ]] || false
  [[ "$output" != *"POISONED"* ]] || false
}

# ---------------------------------------------------------------------------
# No yaml read when cache valid (AC6)
# ---------------------------------------------------------------------------

@test "no yaml read when cache valid: poisoned yaml not consumed" {
  _setup_project
  printf 'sprint_id: "POISONED"\nstatus: active\n' > "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
  [[ "$output" != *"POISONED"* ]] || false
}

@test "no yaml read when cache valid: unreadable yaml still renders" {
  [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
  _setup_project
  chmod 000 "$YAML_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900 50%"* ]] || false
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
  [[ "$output" != *"sprint-900"* ]] || false
  chmod 644 "$YAML_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Render time budget (AC4)
# ---------------------------------------------------------------------------

# _now_ns — print the current epoch in nanoseconds: GNU date, Homebrew gdate,
# bash 5 EPOCHREALTIME, or perl. Fails (never skips) when none is available.
_now_ns() {
  local ns
  ns="$(date +%s%N 2>/dev/null)" || ns=""
  if [[ $ns =~ ^[0-9]{16,}$ ]]; then printf '%s' "$ns"; return 0; fi
  ns="$(gdate +%s%N 2>/dev/null)" || ns=""
  if [[ $ns =~ ^[0-9]{16,}$ ]]; then printf '%s' "$ns"; return 0; fi
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s000' "${EPOCHREALTIME//./}"; return 0; fi
  ns="$(perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1e9' 2>/dev/null)" || ns=""
  if [[ $ns =~ ^[0-9]{16,}$ ]]; then printf '%s' "$ns"; return 0; fi
  echo "no nanosecond clock available (need GNU date, gdate, bash 5 or perl)" >&2
  return 1
}

# _median N... — print the median of the given integers.
_median() {
  printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

# _render_ms DIR — render once for the project at DIR; print elapsed ms.
_render_ms() {
  local t0 t1
  t0="$(_now_ns)" || return 1
  COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$1" PROJECT_ROOT="$1" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
  t1="$(_now_ns)" || return 1
  printf '%s' "$(( (t1 - t0) / 1000000 ))"
}

# _timing_fixture DIR [absent] — the 30-story project built by the real
# writer; with "absent", the cache is removed afterwards.
_timing_fixture() {
  _build_30_story_fixture "$1"
  mkdir -p "$1/plugins/gaia/.claude-plugin"
  printf '{"name":"gaia","version":"9.9.9-test"}\n' > "$1/plugins/gaia/.claude-plugin/plugin.json"
  [ "${2:-}" != "absent" ] || rm -f "$1/.gaia/state/.sprint-progress-cache.json"
  printf '%s' '{"model":{"id":"claude-opus","display_name":"Opus"}}' > "$TEST_TMP/.stdin.json"
}

# _median_of_5 DIR LABEL — two warm-up renders, then five timed renders; print
# every sample to the TAP stream and the median on stdout.
_median_of_5() {
  local dir="$1" label="$2" samples="" i ms
  _render_ms "$dir" >/dev/null
  _render_ms "$dir" >/dev/null
  for i in 1 2 3 4 5; do
    ms="$(_render_ms "$dir")" || return 1
    samples="${samples:+$samples }$ms"
  done
  # shellcheck disable=SC2086
  printf '# %s: runs(ms)=[%s] median=%s ms budget=100 ms\n' "$label" "$samples" "$(_median $samples)" >&3
  # shellcheck disable=SC2086
  _median $samples
}

# The absolute budget depends on the host: a loaded laptop misses it with the
# pre-change script too. These two run on demand (bats --filter-tags
# hardware-dependent) and are skipped in CI, like the other whole-script
# render budget test.

# bats test_tags=hardware-dependent
@test "render median within 100ms with a 30-story cache present" {
  _timing_fixture "$TEST_TMP/project30"
  local med
  med="$(_median_of_5 "$TEST_TMP/project30" "cache present")"
  [ "$med" -le 100 ]
}

# bats test_tags=hardware-dependent
@test "render median within 100ms with the cache absent" {
  _timing_fixture "$TEST_TMP/project30b" absent
  local med
  med="$(_median_of_5 "$TEST_TMP/project30b" "cache absent")"
  [ "$med" -le 100 ]
}

# Host-independent guard that runs everywhere: the cache path must not be
# slower than the yaml path it replaces (the pre-change behaviour, still used
# when the cache is absent). Both are timed interleaved on the same host, so
# host speed cancels out; the cache path runs fewer subprocesses and measures
# at or below the yaml path, and the 1.5x factor absorbs scheduler noise.
@test "cache-present render is no slower than 1.5x the cache-absent render" {
  _timing_fixture "$TEST_TMP/p-present"
  _timing_fixture "$TEST_TMP/p-absent" absent
  local i ms sp="" sa="" mp ma
  _render_ms "$TEST_TMP/p-present" >/dev/null
  _render_ms "$TEST_TMP/p-absent" >/dev/null
  for i in 1 2 3 4 5; do
    ms="$(_render_ms "$TEST_TMP/p-present")" || return 1
    sp="${sp:+$sp }$ms"
    ms="$(_render_ms "$TEST_TMP/p-absent")" || return 1
    sa="${sa:+$sa }$ms"
  done
  # shellcheck disable=SC2086
  mp="$(_median $sp)"
  # shellcheck disable=SC2086
  ma="$(_median $sa)"
  printf '# present runs(ms)=[%s] median=%s; absent runs(ms)=[%s] median=%s\n' "$sp" "$mp" "$sa" "$ma" >&3
  [ $(( mp * 2 )) -le $(( ma * 3 )) ]
}

# ---------------------------------------------------------------------------
# Subprocess count (AC4)
# ---------------------------------------------------------------------------

# Every external command the runtime launches is counted with a PATH shim:
# one wrapper per executable name on PATH logs its name and then runs the real
# binary. This sees top-level and nested launches alike and works on bash 3.2.
# bash, sh and env are not wrapped (they start the runtime itself).
#
# Frozen baseline: the cache-absent render of the fixture project (sandboxed
# HOME, no plugin cache, no git repository). It equals the count of the script
# before the sprint progress cache existed:
#   awk=1 basename=1 cat=1 cksum=1 dirname=1 git=1 grep=2 head=2 jq=8 sed=2
# With a valid cache: one more jq, and no grep, head or sed for the yaml.

# _build_exec_shim DIR LOG — write the wrappers into DIR, logging to LOG.
_build_exec_shim() {
  local shim="$1" log="$2" d f n
  mkdir -p "$shim"
  : > "$log"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"
      case "$n" in bash|sh|env) continue ;; *[!A-Za-z0-9._+-]*) continue ;; esac
      [ -e "$shim/$n" ] && continue
      [ -f "$f" ] && [ -x "$f" ] || continue
      printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$n" "$log" "$f" > "$shim/$n"
    done
  done
  unset IFS
  chmod +x "$shim"/*
}

# _count_execs LOG — render through the shim; print "name=count ..." sorted
# by name, and the total as the last word ("total=N").
_count_execs() {
  local log="$1" shim="$TEST_TMP/exec-shim"
  [ -d "$shim" ] || _build_exec_shim "$shim" "$log"
  : > "$log"
  printf '%s' "$STDIN_JSON" > "$TEST_TMP/.stdin.json"
  PATH="$shim:$PATH" COLUMNS=200 GAIA_STATUSLINE_ASCII=1 GAIA_STATUSLINE_THEME=rich \
    HOME="$HOME" PROJECT_PATH="$PROJECT_PATH" PROJECT_ROOT="$PROJECT_PATH" \
    "$RUNTIME" < "$TEST_TMP/.stdin.json" >/dev/null 2>&1
  sort "$log" | uniq -c | awk '{ printf "%s=%s ", $2, $1; t += $1 } END { printf "total=%d\n", t }'
}

@test "cache-absent subprocess count matches the frozen baseline" {
  _setup_project
  rm -f "$CACHE_FILE"
  local counts
  counts="$(_count_execs "$TEST_TMP/exec.log")"
  echo "# cache absent: $counts" >&3
  [ "$counts" = "awk=1 basename=1 cat=1 cksum=1 dirname=1 git=1 grep=2 head=2 jq=8 sed=2 total=20" ]
}

@test "cache-present render: one more jq, no yaml grep, head or sed, fewer launches" {
  _setup_project
  local present absent
  present="$(_count_execs "$TEST_TMP/exec.log")"
  rm -f "$CACHE_FILE"
  absent="$(_count_execs "$TEST_TMP/exec.log")"
  echo "# cache present: $present" >&3
  echo "# cache absent:  $absent" >&3
  [ "$present" = "awk=1 basename=1 cat=1 cksum=1 dirname=1 git=1 jq=9 total=15" ]
  [ "$absent" = "awk=1 basename=1 cat=1 cksum=1 dirname=1 git=1 grep=2 head=2 jq=8 sed=2 total=20" ]
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
  [[ "$output" == *"sprint-900 50%"* ]] || false
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
  [[ "$output" == *"sprint-900 50%"* ]] || false
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
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900 50%" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
}

@test "OSC-8 terminated by BEL stripped from sprint.id" {
  _setup_project
  # Build the dirty id inside jq to embed BEL (U+0007) reliably.
  local tmp
  tmp="$(jq '.sprint.id = "\u001b]8;;http://x\u0007sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900 50%" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
}

@test "OSC-8 terminated by ESC-backslash stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "\u001b]8;;http://x\u001b\\sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900 50%" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
}

@test "bare BEL stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "sprint\u0007-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900 50%" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
}

@test "NUL stripped from sprint.id" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "\u0000sprint-900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900 50%" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
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
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

@test "allowlist rejects space in sprint.id after stripping" {
  _setup_project
  local tmp
  tmp="$(jq '.sprint.id = "sprint 900"' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  run _render
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"sprint 900"* ]] || false
  [[ "$output" != *"%"* ]] || false
}

# _write_yaml_id RAW — set the yaml sprint_id line to RAW (may hold escapes).
_write_yaml_id() {
  { printf 'sprint_id: "%s"\n' "$1"; grep -v '^sprint_id:' "$YAML_FILE"; } > "$YAML_FILE.tmp"
  mv "$YAML_FILE.tmp" "$YAML_FILE"
}

@test "yaml fallback strips OSC-8 and CSI sequences from the sprint id" {
  _setup_project
  rm -f "$CACHE_FILE"
  _write_yaml_id "$(printf '\033]8;;http://example.invalid/x\033\\sprint-900\033]8;;\033\\\033[2J')"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
  run grep -qF "example.invalid" "$TEST_TMP/out.txt"
  [ "$status" -ne 0 ]
}

@test "yaml fallback after an invalid cache also sanitises the sprint id" {
  _setup_project
  local tmp
  tmp="$(jq '.totals.progress_pct = 65.5' "$CACHE_FILE")"
  printf '%s\n' "$tmp" > "$CACHE_FILE"
  _write_yaml_id "$(printf '\033[2J\033]8;;http://example.invalid/x\007sprint-900')"
  _render_bytes "$TEST_TMP/out.txt"
  [ ! -s "$TEST_TMP/out.txt.err" ]
  grep -qF "sprint-900" "$TEST_TMP/out.txt"
  _assert_printable "$TEST_TMP/out.txt"
}

@test "yaml sprint id that fails the allowlist shows no sprint segment" {
  _setup_project
  rm -f "$CACHE_FILE"
  local id
  for id in 'sprint/../x' 'sprint 900' "$(printf 'sprint-\357\274\231')" "$(printf '\033]8;;http://example.invalid/x')"; do
    _write_yaml_id "$id"
    _render_bytes "$TEST_TMP/out.txt"
    [ ! -s "$TEST_TMP/out.txt.err" ]
    _assert_printable "$TEST_TMP/out.txt"
    run grep -qF "sprint" "$TEST_TMP/out.txt"
    [ "$status" -ne 0 ]
  done
}

# ---------------------------------------------------------------------------
# Changelog rollout note (AC5)
# ---------------------------------------------------------------------------

@test "changelog rollout note covers the segment, self-heal and the manual refresh" {
  # The note lives under [Unreleased] until a release moves it under a version
  # heading, so read the whole changelog rather than one section.
  local unreleased
  unreleased="$(cat "$PLUGIN_ROOT/CHANGELOG.md")"
  [ -n "$unreleased" ]
  [[ "$unreleased" == *"status line shows sprint progress percentage"* ]] || false
  [[ "$unreleased" == *"warning prefix"* ]] || false
  [[ "$unreleased" == *"self-heal mechanism copies the updated runtime automatically after a plugin update"* ]] || false
  [[ "$unreleased" == *'run `/gaia-statusline-refresh` as a manual fallback'* ]] || false
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
  [[ "$output" == *"sprint-900 50%"* ]] || false
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
  [[ "$output" == *"sprint-900 50%"* ]] || false
}

@test "bash 3.2: warning prefix renders" {
  _bash32_or_system
  _setup_project_all_done
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"! sprint-900 100%"* ]] || false
}

@test "bash 3.2: cache-absent fallback shows sprint id only" {
  _bash32_or_system
  _setup_project
  rm -f "$CACHE_FILE"
  run _run_bash32
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]] || false
  [[ "$output" != *"%"* ]] || false
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
  [[ "$output" != *"POISONED"* ]] || false
  [[ "$output" != *"sprint-900"* ]] || false
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
  [[ "$output" == *"sprint-900 50%"* ]] || false
}
