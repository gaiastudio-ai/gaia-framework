#!/usr/bin/env bats
# sprint-progress-snapshot-bash32.bats — the sprint progress snapshot script
# must keep working on bash 3.2, the shell macOS ships as /bin/bash.
#
# One test reads the script for constructs that need bash 4 or later and runs
# everywhere.  The others run the script with a bash 3.x interpreter (by
# default /bin/bash, or the one SNAPSHOT_BASH32 names) through a cold build, a
# warm run, a retargeted story link and the lock paths.  They skip, with the
# reason, on a host that has no bash 3.x.

# bats file_tags=sprint-progress

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/sprint-progress-snapshot.sh"
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state" "$PROJECT_ROOT/.gaia/config"
  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  SIDECAR="$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  LOCK_FILE="$CACHE.lock"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
}
teardown() { common_teardown; }

# need_bash32 — set BASH32 to a bash 3.x interpreter, or skip the test.
need_bash32() {
  local b="${SNAPSHOT_BASH32:-/bin/bash}" major=""
  [ -x "$b" ] && major="$("$b" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)" || true
  if [ "$major" != "3" ]; then
    skip "needs bash 3.x at $b (the stock macOS shell); found major version '${major:-none}'"
  fi
  BASH32="$b"
}

# within_secs SECS CMD... — run CMD; stop it and fail with 124 when it is
# still running after SECS seconds, so a wait that never ends fails the test
# instead of hanging the suite.
within_secs() {
  local secs="$1" pid i=0; shift
  "$@" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt $((secs * 20)) ]; then
      kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
      echo "still running after ${secs}s"; return 124
    fi
    sleep 0.05
  done
  wait "$pid"
}

# run32 [ARGS...] — run the snapshot script with the bash 3.x interpreter.
run32() { run --separate-stderr "$BASH32" "$SCRIPT" "$@"; }

write_sprint_yaml() {
  {
    printf 'sprint_id: "sprint-test"\nstatus: active\nstart_date: "2026-10-01"\n'
    printf 'end_date: "2026-10-14"\ntotal_points: 10\nvelocity_capacity: 100\nstories:\n'
    local row key st
    for row in "$@"; do
      key="${row%%:*}"; st="${row#*:}"
      printf '  - key: "%s"\n    title: "Story %s"\n    status: "%s"\n    points: 5\n' "$key" "$key" "$st"
    done
  } > "$SPRINT_STATUS_YAML"
}

write_story() {
  local key="$1" status="$2" dir="$IMPL/epic-test/$1-story"
  mkdir -p "$dir"
  printf -- '---\nkey: "%s"\ntitle: "Story %s"\nstatus: %s\npoints: 5\n---\n\n## Tasks / Subtasks\n\n- [x] Task 1\n- [ ] Task 2\n' \
    "$key" "$key" "$status" > "$dir/story.md"
}

backdate_tree() {
  find "$PROJECT_ROOT" \( -type f -o -type d \) -exec touch -t 202610010000 {} + 2>/dev/null || true
}

# mark_cache — plant a title that only a warm run keeps (a cold build
# rewrites it from the story file).
mark_cache() {
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
}

@test "the snapshot script uses no construct that needs bash 4 or later" {
  [ -f "$SCRIPT" ]
  # Comment lines are prose, not code.
  local code; code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  [ -n "$code" ]
  local found=0 pat
  for pat in \
    '(local|declare|typeset|readonly)[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-[a-zA-Z]*[AnlucL]' \
    '(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)' \
    '\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)' \
    '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaUuLK]\}' \
    '\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]' \
    '\|&' \
    ';;&|;&' \
    'wait[[:space:]]+-n' \
    'printf[[:space:]][^|;]*%\([^)]*\)T' \
    'shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe|autocd)'; do
    if grep -nE -- "$pat" <<< "$code" >&2; then
      echo "bash 4+ construct matched: $pat" >&2
      found=1
    fi
  done
  [ "$found" -eq 0 ]
  # The bash 5 clock variables are trusted only on bash 5: on an older shell
  # a value inherited from the environment never moves.
  grep -qE '^if \[ "\$\{BASH_VERSINFO\[0\]:-0\}" -lt 5 \]; then unset EPOCHSECONDS EPOCHREALTIME; fi$' "$SCRIPT"
}

@test "bash 3.2: a cold build then a warm run" {
  need_bash32
  write_sprint_yaml "E900-S1:in-progress" "E900-S2:done"
  write_story E900-S1 in-progress
  write_story E900-S2 done
  backdate_tree
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S2"]' ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  grep -q '^v4' "$SIDECAR"
  # Nothing changed: the next run is warm and keeps the planted title.
  mark_cache
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
  # A story file that changed is noticed: the run goes cold again.
  printf -- '---\nkey: "E900-S1"\ntitle: "Edited"\nstatus: review\npoints: 5\n---\n' > "$IMPL/epic-test/E900-S1-story/story.md"
  touch -t 202610020000 "$IMPL/epic-test/E900-S1-story/story.md"
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[0].title, .stories[0].status]' "$CACHE")" = '["Edited","review"]' ]
}

@test "bash 3.2: a story link pointed at another file is noticed on the warm path" {
  need_bash32
  write_sprint_yaml "E900-S1:in-progress" "E900-S2:done"
  write_story E900-S2 done
  local shared="$IMPL/shared-notes"
  mkdir -p "$shared" "$IMPL/epic-test/E900-S1-linked"
  printf -- '---\nkey: "E900-S1"\ntitle: "TARGET-A"\nstatus: in-progress\npoints: 5\n---\n' > "$shared/a.md"
  printf -- '---\nkey: "E900-S1"\ntitle: "TARGET-B"\nstatus: review\npoints: 5\n---\n' > "$shared/b.md"
  local link="$IMPL/epic-test/E900-S1-linked/story.md"
  ln -s "$shared/a.md" "$link"
  backdate_tree
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "TARGET-A" ]
  grep -q "^link	E900-S1	" "$SIDECAR"
  # Unchanged: warm.
  mark_cache
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
  # Point the link at the other file.  Both targets carry the same mtime and
  # the story directories are untouched: only the link entry tells.
  touch -r "$shared/a.md" "$shared/b.md"
  rm -f "$link"; ln -s "$shared/b.md" "$link"
  run32
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[0].title, .stories[0].status]' "$CACHE")" = '["TARGET-B","review"]' ]
}

@test "bash 3.2: the fallback lock skips a live holder, reaps an old empty lock and releases its own" {
  need_bash32
  write_sprint_yaml "E900-S1:done"
  write_story E900-S1 done
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run32
  [ "$status" -eq 0 ]
  grep -q "lock not taken (held by live process $$), skipping" <<< "$stderr"
  [ ! -e "$CACHE" ]
  : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run32
  [ "$status" -eq 0 ]
  grep -q 'replacing an empty lock file nobody holds' <<< "$stderr"
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  [ ! -e "$LOCK_FILE" ]
}

@test "bash 3.2: an aged reap mutex that cannot be removed is given up on within about 2 s" {
  need_bash32
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  local t0 t1
  t0="$(date +%s)"
  run within_secs 10 "$BASH32" -c '. "$1"; if _await_reap "$2"; then echo CLEARED; else echo "GAVE UP"; fi' \
    _ "$SCRIPT" "$LOCK_FILE.reaping"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$output" = "GAVE UP" ]
  # Whole-second clock: the wait stops once SECONDS moved on by 2 (at most
  # about 2 s), well before 100 passes of an age check and a 20 ms sleep,
  # which take about 4 s on bash 3.2.
  [ $(( t1 - t0 )) -le 3 ]
  [ -e "$LOCK_FILE.reaping/stray" ]
}

@test "bash 3.2: clock values inherited from the environment cannot stall the reap wait or the build" {
  need_bash32
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  local t0 t1
  t0="$(date +%s)"
  run within_secs 10 env EPOCHREALTIME=1000.000001 EPOCHSECONDS=1000 "$BASH32" -c '
    . "$1"
    printf "[%s][%s]\n" "${EPOCHREALTIME:-}" "${EPOCHSECONDS:-}"
    if _await_reap "$2"; then echo CLEARED; else echo "GAVE UP"; fi' _ "$SCRIPT" "$LOCK_FILE.reaping"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "[][]" ]
  [ "${lines[1]}" = "GAVE UP" ]
  [ $(( t1 - t0 )) -le 3 ]
  # A full run with the same environment builds and records real mtimes.
  rm -rf "$LOCK_FILE.reaping"
  write_sprint_yaml "E900-S1:done"
  write_story E900-S1 done
  backdate_tree
  run within_secs 20 env EPOCHREALTIME=1000.000001 EPOCHSECONDS=1000 "$BASH32" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  ! grep -q racy "$SIDECAR" || false
}
