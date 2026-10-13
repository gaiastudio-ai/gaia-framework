#!/usr/bin/env bats
# sprint-progress-snapshot-perf.bats — performance budget tests for the sprint
# progress snapshot: cold < 1.5 s, warm < 200 ms (exact budgets, no CI
# multiplier), measured as the MEDIAN of 5 runs per mode; batched find
# resolution on a realistic tree; a realistic action-items registry; and a
# 300-story sprint that must finish inside the 10 s hook timeout.

# bats file_tags=sprint-progress,perf

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$(snapshot_script_under_test "$SCRIPTS_DIR/sprint-progress-snapshot.sh")"

  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"

  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  SIDECAR="$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  PARSED="$PROJECT_ROOT/.gaia/state/.sprint-progress-parsed"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Timing helper — nanosecond-resolution where available
# ---------------------------------------------------------------------------

# _now_ns — print the current epoch in nanoseconds.
# Uses date +%s%N (GNU), gdate +%s%N (Homebrew), or perl fallback.  An older
# BSD date prints "<epoch>N" for %N, so the value must be all digits.
_now_ns() {
  # GNU coreutils
  local ns
  ns="$(date +%s%N 2>/dev/null)" || ns=""
  if [[ $ns =~ ^[0-9]{16,}$ ]]; then
    printf '%s' "$ns"
    return 0
  fi
  # Homebrew gdate
  ns="$(gdate +%s%N 2>/dev/null)" || ns=""
  if [[ $ns =~ ^[0-9]{16,}$ ]]; then
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

# _median N... — print the median of the given integers.
_median() {
  printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

# _time_runs MODE RUNS — run the snapshot RUNS times and print the elapsed
# milliseconds of each run on one line.  MODE "cold" removes the cache,
# sidecar and parse cache before every run; "warm" leaves them in place;
# "yaml" is the shape of a run after a status transition: the sprint yaml
# and one story file get a new mtime before every run, while the cache,
# sidecar and parse cache stay.  Each mode checks that every sample really
# ran the way it is labelled.
_time_runs() {
  local mode="$1" runs="$2" i t0 t1 out="" stamp prev=""
  for i in $(seq 1 "$runs"); do
    case "$mode" in
      cold)
        rm -f "$CACHE" "$SIDECAR" "$PARSED"
        # Nothing for a warm path to serve: this sample is a cold build.
        [ ! -e "$CACHE" ] && [ ! -e "$SIDECAR" ] && [ ! -e "$PARSED" ] || return 1 ;;
      yaml)
        prev="$(_sidecar_yaml_mtime)"
        stamp="$(printf '2026090%d0000' "$i")"
        touch -t "$stamp" "$SPRINT_STATUS_YAML" "$IMPL/epic-perf/E900-S1-e900-s1-perf/story.md" ;;
    esac
    t0="$(_now_ns)"
    "$SCRIPT" >/dev/null 2>&1 || return 1
    t1="$(_now_ns)"
    case "$mode" in
      cold) [ -s "$CACHE" ] && [ -s "$SIDECAR" ] || return 1 ;;
      # The sidecar now records the new yaml mtime (a warm run never
      # rewrites it): the run rebuilt.
      yaml) [ "$(_sidecar_yaml_mtime)" != "$prev" ] \
              && [ "$(_sidecar_yaml_mtime)" = "$(_snap_mtime "$SPRINT_STATUS_YAML")" ] || return 1 ;;
    esac
    out="${out:+$out }$(_elapsed_ms "$t0" "$t1")"
  done
  printf '%s' "$out"
}

# _sidecar_yaml_mtime — the sprint yaml mtime the sidecar recorded.
_sidecar_yaml_mtime() {
  awk -F'\t' '$1 == "meta" && $2 == "__sprint_status__" { print $4 }' "$SIDECAR"
}

# _snap_mtime FILE — the mtime in epoch seconds (GNU or BSD stat).
_snap_mtime() {
  if stat -c %Y / >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

# _flat_top_level N — N plain files directly in the story tree root, the
# shape of a legacy flat layout (every story and review file at the top).
_flat_top_level() {
  awk -v n="$1" -v impl="$IMPL" 'BEGIN {
    for (i = 1; i <= n; i++) { f = impl "/flat-note-" i ".md"; printf "# note %d\n", i > f; close(f) }
  }'
}

# _report LABEL BUDGET SAMPLES... — print samples + median to the TAP stream.
_report() {
  local label="$1" budget="$2"; shift 2
  printf '# %s: runs(ms)=[%s] median=%s ms budget=%s ms\n' \
    "$label" "$*" "$(_median "$@")" "$budget" >&3
}

# backdate_tree — fixture files and directories older than the run, so the
# warm path is not defeated by entries written in the snapshot's own second.
backdate_tree() {
  find "$PROJECT_ROOT" \( -type f -o -type d \) -exec touch -t 202610010000 {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Fixture generator — N-story sprint with realistic structure
# ---------------------------------------------------------------------------

_generate_sprint() {
  local count="${1:-30}"
  # One awk process writes every story file, the ledger and the yaml (a
  # shell loop of thousands of printf calls is slow under bats' tracing).
  awk -v n="$count" -v impl="$IMPL" -v yaml="$SPRINT_STATUS_YAML" \
      -v ledger="$PROJECT_ROOT/.gaia/state/.review-gate-ledger" '
  BEGIN {
    split("done in-progress review blocked ready-for-dev", sts, " ")
    total = 0; ys = ""
    for (i = 1; i <= n; i++) {
      key = "E900-S" i; st = sts[((i - 1) % 5) + 1]; pts = (i % 8) + 1; total += pts
      dir = impl "/epic-perf/" key "-e900-s" i "-perf"
      system("mkdir -p \"" dir "\"")
      f = dir "/story.md"
      printf "---\ntemplate: '\''story'\''\nkey: \"%s\"\ntitle: \"Performance test story %d; with enough text to exercise parsing\"\nstatus: %s\npoints: %d\nmanual_verification: true\ndepends_on: []\n---\n\n# Story: %s\n\n> **Status:** %s\n\n## Acceptance Criteria\n\n", key, i, st, pts, key, st > f
      for (a = 1; a <= 8; a++) printf "- [ ] **AC%d:** Given a context, when an action; then a result.\n", a > f
      printf "\n## Tasks / Subtasks\n\n" > f
      for (t = 1; t <= 12; t++) printf "- [%s] Task %d: do this; then that\n  - [x] %d.1 subtask\n", (t % 2 ? " " : "x"), t, t > f
      printf "\n## Dev Notes\n\n" > f
      for (l = 1; l <= 120; l++) printf "Dev note line %d with some text.\n", l > f
      printf "\n## Review Gate\n\n| Review | Status | Report |\n|--------|--------|--------|\n| Code Review | PASSED | — |\n| QA Tests | PASSED | — |\n| Security Review | PASSED | — |\n| Test Automation | PASSED | — |\n| Test Review | UNVERIFIED | — |\n| Performance Review | UNVERIFIED | — |\n\n## Definition of Done\n\n- [x] All done\n" > f
      close(f)
      printf "%s\tmanual-test\tplan-1\tUNVERIFIED\n", key > ledger
      ys = ys sprintf("  - key: \"%s\"\n    title: \"Performance test story %d\"\n    status: \"%s\"\n    points: %d\n    risk_level: \"medium\"\n    assignee: null\n    blocked_by: null\n    phase: %d\n", key, i, st, pts, int((i - 1) / 10) + 1)
    }
    printf "sprint_id: \"sprint-perf\"\nstatus: active\nstart_date: \"2026-10-01\"\nend_date: \"2026-10-14\"\ntotal_points: %d\nvelocity_capacity: 120\ngoals:\n  - \"Performance validation\"\nstories:\n%s", total, ys > yaml
  }'
}

_generate_30_story_sprint() { _generate_sprint 30; }

# _generate_registry N — action-items registry of N items, about half open
# or in progress, a mix of assignees (some matching the default "user" alias).
_generate_registry() {
  awk -v n="$1" 'BEGIN {
    split("open in-progress resolved done", sts, " ")
    print "items:"
    for (i = 1; i <= n; i++) {
      asn = (i % 5 == 0) ? "user" : "agent-" (i % 7)
      printf "  - id: \"AI-9%03d\"\n    title: \"Follow-up item %d; check the logs\"\n    type: \"process\"\n    status: \"%s\"\n    assignee: \"%s\"\n    created_at: \"2026-09-%02d\"\n    context_for_target: \"Some longer context text for item %d\"\n", i, i, sts[(i % 4) + 1], asn, (i % 28) + 1, i
    }
  }' > "$PROJECT_ROOT/.gaia/state/action-items.yaml"
}

# ---------------------------------------------------------------------------
# Performance budget tests (median of 5, exact budgets)
# ---------------------------------------------------------------------------

@test "cold run under 1.5 seconds with 30 story fixtures" {
  _generate_30_story_sprint
  backdate_tree
  local samples
  samples="$(_time_runs cold 5)"
  # shellcheck disable=SC2086
  _report "cold 30 stories" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]
}

@test "warm run under 200 milliseconds with unchanged files" {
  _generate_30_story_sprint
  backdate_tree
  # Prime the cache and sidecar.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  [ -f "$SIDECAR" ]
  local samples
  samples="$(_time_runs warm 5)"
  # shellcheck disable=SC2086
  _report "warm 30 stories" 200 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 200 ]
}

@test "batched find resolves paths in realistic tree of thousands of files" {
  _generate_30_story_sprint

  # Pad the implementation-artifacts tree with 2000 decoy files to stress
  # the batched find resolution
  local decoy_dir="$IMPL/epic-decoy"
  mkdir -p "$decoy_dir"
  local j k
  for j in $(seq 1 200); do
    mkdir -p "$decoy_dir/noise-${j}"
    for k in $(seq 1 10); do
      printf -- '---\ntemplate: other\n---\n# Noise\n' > "$decoy_dir/noise-${j}/file-${k}.md"
    done
  done
  backdate_tree

  local samples
  samples="$(_time_runs cold 5)"
  # shellcheck disable=SC2086
  _report "cold 30 stories + 2000 decoy files" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]
}

@test "cold run under 1.5 seconds with a realistic action-items registry" {
  _generate_30_story_sprint
  _generate_registry 270
  backdate_tree
  local samples
  samples="$(_time_runs cold 5)"
  # shellcheck disable=SC2086
  _report "cold 30 stories + 270-item registry" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" -gt 0 ]
}

@test "run after a status transition stays under 1.5 seconds with 30 stories" {
  _generate_30_story_sprint
  _generate_registry 270
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local samples
  samples="$(_time_runs yaml 5)"
  # shellcheck disable=SC2086
  _report "after a transition, 30 stories + 270-item registry" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]
}

@test "a story tree with 3000 flat top-level files stays under 1.5 seconds" {
  _generate_30_story_sprint
  _flat_top_level 3000
  backdate_tree
  [ "$(find "$IMPL" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "3001" ]
  local samples
  samples="$(_time_runs cold 5)"
  # shellcheck disable=SC2086
  _report "cold 30 stories + 3000 flat top-level files" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]

  samples="$(_time_runs yaml 5)"
  # shellcheck disable=SC2086
  _report "after a transition, 30 stories + 3000 flat top-level files" 1500 $samples
  # shellcheck disable=SC2086
  [ "$(_median $samples)" -lt 1500 ]
}

@test "300-story sprint finishes inside the 10 second hook timeout" {
  _generate_sprint 300
  _generate_registry 270
  backdate_tree
  local samples
  samples="$(_time_runs cold 1)"
  _report "cold 300 stories + 270-item registry" 10000 "$samples"
  [ "$samples" -lt 10000 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "300" ]
}

@test "warm run with every story file symlinked costs about the same as with regular files" {
  _generate_sprint 300
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local regular
  regular="$(_time_runs warm 5)"
  # shellcheck disable=SC2086
  _report "warm 300 regular story files" "-" $regular

  # Move every story file into a store inside the project and leave a link
  # in its place: each story is now found through a link.
  local store="$PROJECT_ROOT/story-store" f n=0
  mkdir -p "$store"
  while IFS= read -r f; do
    n=$((n + 1))
    mv "$f" "$store/story-$n.md"
    ln -s "$store/story-$n.md" "$f"
  done < <(find "$IMPL/epic-perf" -name story.md -type f)
  [ "$n" -eq 300 ]
  backdate_tree
  rm -f "$CACHE" "$SIDECAR" "$PARSED"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "300" ]
  [ "$(awk -F'\t' '$1 == "link"' "$SIDECAR" | wc -l | tr -d ' ')" = "300" ]

  local before linked
  before="$(cksum < "$SIDECAR")"
  linked="$(_time_runs warm 5)"
  # The warm path served every sample: it never rewrites the sidecar.
  [ "$(cksum < "$SIDECAR")" = "$before" ]
  # shellcheck disable=SC2086
  _report "warm 300 symlinked story files" "$(( 2 * $(_median $regular) ))" $linked
  # A check that compares every link with every story grows with the square
  # of the story count and takes several times longer here.
  # shellcheck disable=SC2086
  [ "$(_median $linked)" -le "$(( 2 * $(_median $regular) ))" ]
}

# ---------------------------------------------------------------------------
# Process count (a per-story fork would hide inside the time budgets)
# ---------------------------------------------------------------------------

# _install_exec_counter DIR LOG — PATH shims that log each external command
# the snapshot starts, then run the real one.
_install_exec_counter() {
  local dir="$1" log="$2" tool real
  mkdir -p "$dir"
  for tool in awk cat cp date find flock git jq ln mkdir mktemp mv readlink realpath rm sed \
              sleep sort stat touch tr wc yq; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    case "$real" in /*) ;; *) continue ;; esac
    printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$log" "$real" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
}

# _count_execs LOG — run the snapshot once through the shims; print the count.
_count_execs() {
  : > "$1"
  PATH="$TEST_TMP/count-bin:$PATH" "$SCRIPT" >/dev/null 2>&1 || return 1
  wc -l < "$1" | tr -d ' '
}

@test "process count: the warm path stays small and the cold path does not grow with story count" {
  local log="$TEST_TMP/execs"
  _install_exec_counter "$TEST_TMP/count-bin" "$log"

  _generate_sprint 30
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Warm: a marker title proves the counted run took the warm path.
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  local warm; warm="$(_count_execs "$log")"
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]
  local warm_list; warm_list="$(sort "$log" | uniq -c | tr -s ' ' | tr '\n' ',')"

  rm -f "$CACHE" "$SIDECAR" "$PARSED"
  local cold30; cold30="$(_count_execs "$log")"
  [ "$(jq '.totals.total_stories' "$CACHE")" = "30" ]

  _generate_sprint 60
  backdate_tree
  rm -f "$CACHE" "$SIDECAR" "$PARSED"
  local cold60; cold60="$(_count_execs "$log")"
  [ "$(jq '.totals.total_stories' "$CACHE")" = "60" ]
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq '.stories[0].title = "WARM-PATH-MARKER"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  local warm60; warm60="$(_count_execs "$log")"
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "WARM-PATH-MARKER" ]

  printf '# processes: warm=%s [%s] warm60=%s cold30=%s cold60=%s\n' "$warm" "$warm_list" "$warm60" "$cold30" "$cold60" >&3
  # The warm path runs 8 programs on this host: flock, jq, mv, rm, two
  # realpath (a one-time probe for -e, then the batch) and two stat (the
  # flavour probe at load, then the batch).  Two more are allowed for a host
  # where a probe resolves differently (for example a stat or realpath that
  # needs the per-path fallback); anything that grows with the story count
  # is caught by the equality checks, which have no headroom.
  [ "$warm" -le 10 ]
  [ "$warm60" -eq "$warm" ]
  [ "$cold60" -eq "$cold30" ]
}

@test "the perf timer falls back when date has no nanosecond support" {
  # An older BSD date prints "<epoch>N" for +%s%N; gdate is absent.
  local stub="$TEST_TMP/old-date"; mkdir -p "$stub"
  printf '#!/bin/sh\necho 1700000000N\n' > "$stub/date"
  printf '#!/bin/sh\nexit 127\n' > "$stub/gdate"
  chmod +x "$stub/date" "$stub/gdate"
  local ns; ns="$(PATH="$stub:$PATH" _now_ns)"
  [[ $ns =~ ^[0-9]{16,}$ ]]
}
