#!/usr/bin/env bats
# checkpoint-reaper.bats — 30-day reaper for _memory/checkpoints AND
# _memory/meeting-sessions (E76-S7, AC5, TS8)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/scripts/lib/checkpoint-reaper.sh"
  TMP="$(mktemp -d)"
  CHECKPOINT_DIR="$TMP/_memory/checkpoints"
  SESSION_DIR="$TMP/_memory/meeting-sessions"
  mkdir -p "$CHECKPOINT_DIR" "$SESSION_DIR"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: checkpoint-reaper.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC5: 31-day-old session file is reaped" {
  OLD="$SESSION_DIR/2026-04-01-stale.yaml"
  echo "session_id: stale" > "$OLD"
  # Backdate 31 days
  touch -t "$(date -u -v-31d +%Y%m%d0000 2>/dev/null || date -u -d '31 days ago' +%Y%m%d0000)" "$OLD"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ ! -e "$OLD" ]
}

@test "AC5: 29-day-old session file is retained" {
  YOUNG="$SESSION_DIR/2026-04-09-fresh.yaml"
  echo "session_id: fresh" > "$YOUNG"
  touch -t "$(date -u -v-29d +%Y%m%d0000 2>/dev/null || date -u -d '29 days ago' +%Y%m%d0000)" "$YOUNG"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ -e "$YOUNG" ]
}

@test "AC5: reaper walks BOTH _memory/checkpoints/ AND _memory/meeting-sessions/" {
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

@test "AC5: --dry-run does not delete" {
  OLD="$SESSION_DIR/2026-04-01-stale.yaml"
  echo "session_id: stale" > "$OLD"
  touch -t "$(date -u -v-31d +%Y%m%d0000 2>/dev/null || date -u -d '31 days ago' +%Y%m%d0000)" "$OLD"
  run "$HELPER" --root "$TMP" --age-days 30 --dry-run
  [ "$status" -eq 0 ]
  [ -e "$OLD" ]
  [[ "$output" == *"$OLD"* ]]
}

@test "AC5: 30-day-old file is at the boundary — kept (strictly > 30 days reaps)" {
  EDGE="$SESSION_DIR/edge.yaml"
  echo "session_id: edge" > "$EDGE"
  touch -t "$(date -u -v-30d +%Y%m%d0000 2>/dev/null || date -u -d '30 days ago' +%Y%m%d0000)" "$EDGE"
  run "$HELPER" --root "$TMP" --age-days 30 --apply
  [ "$status" -eq 0 ]
  [ -e "$EDGE" ]
}
