#!/usr/bin/env bats
# mod-interleave.bats -- Concurrent read/write atomicity of the sprint cache.
# Runs the REAL snapshot script repeatedly while a reader parses the cache,
# proving the reader only ever sees a complete JSON object. A deliberately
# non-atomic writer proves the reader's check can fail.

load 'test_helper.bash'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNAPSHOT="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  FIXTURE="$BATS_TEST_TMPDIR/interleave"
  mkdir -p "$FIXTURE/.gaia/config" "$FIXTURE/.gaia/state" \
    "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-interleave"

  cat > "$FIXTURE/.gaia/config/project-config.yaml" <<'YAML'
project_name: interleave-test
stacks:
  - name: shell
    path: "."
YAML

  cat > "$FIXTURE/.gaia/state/sprint-status.yaml" <<'YAML'
sprint_id: "sprint-interleave"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals:
  - "Interleave test"
stories:
  - key: "E900-S1"
    title: "Interleave story"
    status: "in-progress"
    points: 5
    phase: 1
YAML

  cat > "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-interleave/story.md" <<'STORY'
---
id: E900-S1
title: "Interleave story"
status: in-progress
points: 5
phase: 1
epic_id: E900
priority: medium
created_at: "2026-10-01"
---
# Interleave story
STORY

  CACHE_FILE="$FIXTURE/.gaia/state/.sprint-progress-cache.json"
}

teardown() {
  # Never leave a writer behind, whatever happened in the test.
  if [ -n "${WRITER_PID:-}" ]; then
    kill "$WRITER_PID" 2>/dev/null || true
    wait "$WRITER_PID" 2>/dev/null || true
  fi
}

# _read_while_alive PID FILE LIMIT_SECONDS -- reads FILE while PID runs, for
# at most LIMIT_SECONDS of wall-clock time. An empty file, a partial file or
# anything that is not a JSON object counts as a bad read. Sets READS, BAD
# and TIMED_OUT.
_read_while_alive() {
  local pid="$1" file="$2" limit="$3" deadline
  READS=0
  BAD=0
  TIMED_OUT=0
  deadline=$((SECONDS + limit))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      TIMED_OUT=1
      break
    fi
    if [ -e "$file" ]; then
      READS=$((READS + 1))
      if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
        BAD=$((BAD + 1))
      fi
    fi
  done
}

@test "a reader sees only complete cache objects during repeated snapshot writes" {
  [ -x "$SNAPSHOT" ] || false
  local fails="$BATS_TEST_TMPDIR/writer-fails"
  : > "$fails"

  # The first write happens before the reader starts, so every read below
  # overlaps a later write.
  run env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ] || false

  (
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT" > /dev/null 2>&1 || echo "run $i exited $?" >> "$fails"
    done
  ) &
  WRITER_PID=$!

  _read_while_alive "$WRITER_PID" "$CACHE_FILE" 120
  echo "reads: $READS, bad reads: $BAD, timed out: $TIMED_OUT"
  [ "$TIMED_OUT" -eq 0 ]
  wait "$WRITER_PID"
  WRITER_PID=""

  echo "writer failures: $(cat "$fails")"
  [ ! -s "$fails" ]
  [ "$BAD" -eq 0 ]
  # At least one read per write on average.
  [ "$READS" -ge 15 ]
}

@test "the reader's check catches a writer that truncates before it writes" {
  local target="$BATS_TEST_TMPDIR/nonatomic.json"
  printf '{"a":1}' > "$target"
  (
    i=0
    while [ "$i" -lt 40 ]; do
      : > "$target"
      sleep 0.02
      printf '{"a":' > "$target"
      sleep 0.02
      printf '{"a":1}' > "$target"
      sleep 0.01
      i=$((i + 1))
    done
  ) &
  WRITER_PID=$!

  _read_while_alive "$WRITER_PID" "$target" 60
  wait "$WRITER_PID"
  WRITER_PID=""
  echo "reads: $READS, bad reads: $BAD, timed out: $TIMED_OUT"
  [ "$TIMED_OUT" -eq 0 ]
  [ "$READS" -gt 0 ]
  [ "$BAD" -gt 0 ]
}

@test "the snapshot script writes the cache only through a same-directory temp file and mv" {
  [ -f "$SNAPSHOT" ] || false
  # Code lines only: comments are dropped so a comment cannot satisfy a check.
  local code="$BATS_TEST_TMPDIR/code.sh"
  grep -v '^[[:space:]]*#' "$SNAPSHOT" > "$code"

  # The temp file is created next to its target.
  grep -q '_TMP="\${1}\.tmp\.' "$code"

  # Every cache write is a temp file created for the cache, then renamed.
  run grep -c '_new_tmp "\$CACHE_FILE"' "$code"
  [ "$output" -ge 2 ]
  run grep -cE 'mv -f "\$[a-z_]+" "\$CACHE_FILE"' "$code"
  [ "$output" -ge 2 ]

  # Nothing writes the cache in place.
  run grep -nE '>>?[[:space:]]*"\$CACHE_FILE"|(cp|tee|install)[^|;]*"\$CACHE_FILE"' "$code"
  echo "$output"
  [ "$status" -eq 1 ]
  run grep -nE 'mv [^|;]*"\$CACHE_FILE"' "$code"
  echo "$output"
  run grep -cvE 'mv -f "\$[a-z_]+" "\$CACHE_FILE"' <<< "$output"
  [ "$output" -eq 0 ]
}
