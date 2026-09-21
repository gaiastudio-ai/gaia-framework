#!/usr/bin/env bats
# checkpoint-reaper.bats — 30-day reaper for the checkpoint and meeting-session
# directories of the runtime memory tree.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/scripts/lib/checkpoint-reaper.sh"
  # Canonicalize the fixture root: on macOS mktemp hands back a /var symlink
  # path while the paths helper resolves to /private/var, and the reaper prints
  # the paths it walked — a dry-run case compares those strings.
  TMP="$(cd "$(mktemp -d)" && pwd -P)"

  # The reaper walks the memory tree beneath the --root it is handed. Ask the
  # shared paths helper where that tree sits rather than restating the layout,
  # so a move of the runtime tree does not silently make these cases seed
  # files the reaper never looks at (which is exactly how they last broke).
  MEMORY_DIR="$(
    PROJECT_ROOT="$TMP" _GAIA_PATHS_LOADED="" \
    bash -c '. "$1/plugins/gaia/scripts/lib/gaia-paths.sh" >/dev/null 2>&1;
             printf "%s" "$GAIA_MEMORY_DIR"' _ "$REPO_ROOT"
  )"
  CHECKPOINT_DIR="$MEMORY_DIR/checkpoints"
  SESSION_DIR="$MEMORY_DIR/meeting-sessions"
  mkdir -p "$CHECKPOINT_DIR" "$SESSION_DIR"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: checkpoint-reaper.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "a 31-day-old session file is reaped" {
  OLD="$SESSION_DIR/2026-04-01-stale.yaml"
  echo "session_id: stale" > "$OLD"
  # Backdate 31 days
  touch -t "$(date -u -v-31d +%Y%m%d0000 2>/dev/null || date -u -d '31 days ago' +%Y%m%d0000)" "$OLD"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ ! -e "$OLD" ]
}

@test "a 29-day-old session file is retained" {
  YOUNG="$SESSION_DIR/2026-04-09-fresh.yaml"
  echo "session_id: fresh" > "$YOUNG"
  touch -t "$(date -u -v-29d +%Y%m%d0000 2>/dev/null || date -u -d '29 days ago' +%Y%m%d0000)" "$YOUNG"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ -e "$YOUNG" ]
}

@test "one reaper run walks both the checkpoint and the meeting-session directories" {
  # Two old files: one under each directory. Both must be reaped by ONE reaper.
  CK="$CHECKPOINT_DIR/old-ck.json"
  SS="$SESSION_DIR/old-ss.yaml"
  echo '{}' > "$CK"
  echo "session_id: old" > "$SS"
  touch -t "$(date -u -v-40d +%Y%m%d0000 2>/dev/null || date -u -d '40 days ago' +%Y%m%d0000)" "$CK" "$SS"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ ! -e "$CK" ]
  [ ! -e "$SS" ]
}

@test "--dry-run does not delete" {
  OLD="$SESSION_DIR/2026-04-01-stale.yaml"
  echo "session_id: stale" > "$OLD"
  touch -t "$(date -u -v-31d +%Y%m%d0000 2>/dev/null || date -u -d '31 days ago' +%Y%m%d0000)" "$OLD"
  run "$HELPER" --root "$TMP" --age-days 30 --dry-run
  [ "$status" -eq 0 ]
  [ -e "$OLD" ]
  [[ "$output" == *"$OLD"* ]]
}

@test "a 30-day-old file is at the boundary — kept (strictly > 30 days reaps)" {
  EDGE="$SESSION_DIR/edge.yaml"
  echo "session_id: edge" > "$EDGE"
  touch -t "$(date -u -v-30d +%Y%m%d0000 2>/dev/null || date -u -d '30 days ago' +%Y%m%d0000)" "$EDGE"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ -e "$EDGE" ]
}
