#!/usr/bin/env bats
# mod-interleave.bats -- Concurrent read/write atomicity test.
# Runs the REAL snapshot script in a loop while a reader loop
# parses the cache, proving it is always valid JSON or absent.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNAPSHOT="$REPO_ROOT/plugins/gaia/scripts/sprint-progress-snapshot.sh"
  FIXTURE="${BATS_TMPDIR}/interleave-$$"
  mkdir -p "$FIXTURE/.gaia/config"
  mkdir -p "$FIXTURE/.gaia/state"
  mkdir -p "$FIXTURE/.gaia/artifacts/implementation-artifacts/epic-e900/E900-S1-interleave"

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
  rm -rf "$FIXTURE"
}

# Guarantee overlap -- reader loops while writer process is alive (bounded),
# assert reader performed >= N reads during the writer's lifetime and zero parse failures.
@test "concurrent reader always gets valid JSON during repeated snapshot writes" {
  [ -x "$SNAPSHOT" ] || false

  READER_LOG="${BATS_TMPDIR}/reader-log-$$"
  WRITER_PID_FILE="${BATS_TMPDIR}/writer-pid-$$"

  # Writer: run snapshot 15 times in sequence, record PID
  (
    echo $$ > "$WRITER_PID_FILE"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      env PROJECT_ROOT="$FIXTURE" bash "$SNAPSHOT" 2>/dev/null
    done
  ) &
  WRITER_PID=$!

  # Reader: bounded loop while writer is alive, try to parse cache
  PARSE_ERRORS=0
  READ_COUNT=0
  MAX_ITERS=200
  ITER=0
  while kill -0 "$WRITER_PID" 2>/dev/null && [ "$ITER" -lt "$MAX_ITERS" ]; do
    ITER=$((ITER + 1))
    if [ -f "$CACHE_FILE" ]; then
      READ_COUNT=$((READ_COUNT + 1))
      if ! jq '.' "$CACHE_FILE" > /dev/null 2>&1; then
        PARSE_ERRORS=$((PARSE_ERRORS + 1))
      fi
    fi
  done

  # Wait for writer (bounded)
  wait "$WRITER_PID" 2>/dev/null || true

  # Assert zero parse errors
  echo "reads during writer lifetime: $READ_COUNT, parse errors: $PARSE_ERRORS"
  [ "$PARSE_ERRORS" -eq 0 ]

  # Reader performed >= 3 reads during writer lifetime
  [ "$READ_COUNT" -ge 3 ] || {
    echo "expected >= 3 reads during writer, got $READ_COUNT"
    false
  }

  # The cache file should exist after writes
  [ -f "$CACHE_FILE" ]
}

@test "snapshot script uses mktemp plus mv atomic pattern" {
  [ -f "$SNAPSHOT" ] || false

  # The script must use mktemp for atomic writes
  grep -q 'mktemp' "$SNAPSHOT"

  # The script must use mv to atomically replace the cache
  grep -q 'mv ' "$SNAPSHOT"
}
