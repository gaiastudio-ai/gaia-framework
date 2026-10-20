#!/usr/bin/env bats
# concurrent-sprint-lifecycle.bats
#
# Tests for the sprint close and release ordering contract:
# two-phase close protocol, release pre-check, back-compat,
# transitional state, recovery, marker-based injection refusal,
# post-close audit, and internal ID scrub.
#
# Covers: cmd_close, _cmd_close_single, _cmd_close_concurrent,
#   _cmd_close_resume, _close_post_audit, _close_non_done_stories,
#   _close_emit_sprint_transitioned, _close_run_snapshot,
#   _closing_marker_owner_alive, _closing_marker_sprint_id,
#   _write_closing_marker, _closing_marker_path, _holder_sidecar_path
#   (public-function coverage gate).

load 'test_helper.bash'

SPRINT_STATE_SH="$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
CLOSE_SH="$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
PRE_RELEASE_SH="$BATS_TEST_DIRNAME/../skills/gaia-release/scripts/pre-release-sprint-check.sh"
LOCK_LIB="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export MEMORY_PATH="$TEST_TMP/.gaia/memory"
  export SPRINT_STATE_SCRIPT_DIR="$BATS_TEST_DIRNAME/../scripts"
  export GAIA_SNAPSHOT_HOOK_DISABLE=1
  export GAIA_SKIP_ORPHAN_SWEEP=1

  STATE_DIR="$TEST_TMP/.gaia/state"
  ART_DIR="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  ARCHIVE_DIR="$ART_DIR/sprint-archive"
  CKPT_DIR="$MEMORY_PATH/checkpoints"
  CONFIG_DIR="$TEST_TMP/.gaia/config"
  LIFECYCLE="$MEMORY_PATH/lifecycle-events.jsonl"

  mkdir -p "$STATE_DIR" "$ART_DIR" "$ARCHIVE_DIR" "$MEMORY_PATH" "$CKPT_DIR" "$CONFIG_DIR"
}

teardown() {
  # Kill any background processes.
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
  common_teardown
}

# ---------- Fixture helpers ----------

_seed_config() {
  local max_conc="${1:-2}"
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
sprint:
  max_concurrent_active: $max_conc
YAML
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"
}

_seed_single_config() {
  cat > "$CONFIG_DIR/project-config.yaml" <<YAML
sprint:
  max_concurrent_active: 1
YAML
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"
}

_seed_per_sprint_yaml() {
  local sprint_id="$1" status="$2" done_count="${3:-3}" total="${4:-3}"
  local f="$STATE_DIR/sprint-status-${sprint_id}.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$status"
    printf 'total_points: %d\n' "$((total * 3))"
    printf 'stories:\n'
    local i
    for i in $(seq 1 "$total"); do
      local s="done"
      [ "$i" -gt "$done_count" ] && s="in-progress"
      printf '  - key: "E900-S%d"\n' "$i"
      printf '    title: "Story %d"\n' "$i"
      printf '    status: %s\n' "$s"
      printf '    points: 3\n'
      printf '    risk_level: medium\n'
    done
  } > "$f"
}

_seed_proxy_yaml() {
  local sprint_id="$1" status="$2"
  local f="$STATE_DIR/sprint-status.yaml"
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: %s\n' "$status"
    printf 'total_points: 9\n'
    printf 'stories:\n'
    printf '  - key: "E900-S1"\n    status: done\n    points: 3\n'
  } > "$f"
  export SPRINT_STATUS_YAML="$f"
}

_seed_sentinel() {
  local sprint_id="$1"
  printf '{"sprint_id":"%s"}' "$sprint_id" \
    > "$CKPT_DIR/sprint-review-${sprint_id}-val-dispatched.json"
}

_seed_retro() {
  local sprint_id="$1"
  touch "$ART_DIR/retrospective-${sprint_id}-2026-10-20.md"
}

_seed_last_activated() {
  local sprint_id="$1"
  printf '%s' "$sprint_id" > "$STATE_DIR/.last-activated-sprint"
}

_seed_lifecycle_event_sh() {
  local plugin_scripts="$BATS_TEST_DIRNAME/../scripts"
  # Use the real lifecycle-event.sh if available.
  if [ -x "$plugin_scripts/lifecycle-event.sh" ]; then
    return 0
  fi
  # Stub.
  cat > "$plugin_scripts/lifecycle-event.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
event_type="" workflow="" data="{}"
while [ $# -gt 0 ]; do
  case "$1" in
    --type) event_type="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --story) shift 2 ;;
    --data) data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
memory="${MEMORY_PATH:-.gaia/memory}"
mkdir -p "$memory"
printf '{"event_type":"%s","workflow":"%s","data":%s}\n' \
  "$event_type" "$workflow" "$data" >> "$memory/lifecycle-events.jsonl"
STUB
  chmod +x "$plugin_scripts/lifecycle-event.sh"
}

_read_status() {
  local f="$1"
  awk '/^status:/ { sub(/^status:[[:space:]]*/, ""); gsub(/"/, ""); print }' "$f"
}

_read_closed_at() {
  local f="$1"
  awk '/^closed_at:/ { sub(/^closed_at:[[:space:]]*/, ""); gsub(/"/, ""); print }' "$f"
}

# ============================================================================
# Back-compat: single-sprint mode (no lifecycle lock)
# ============================================================================

@test "single-sprint close: no lifecycle lock file created, status closed" {
  _seed_single_config
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_retro "sprint-900"

  export SPRINT_STATE_SH="$SPRINT_STATE_SH"
  run "$CLOSE_SH" --force
  [ "$status" -eq 0 ]

  [ "$(_read_status "$SPRINT_STATUS_YAML")" = "closed" ]
  # No lifecycle lock file should have been created.
  [ ! -f "$STATE_DIR/.sprint-lifecycle.lock" ]
}

@test "single-sprint re-close exits 0 with already closed" {
  _seed_single_config
  _seed_proxy_yaml "sprint-900" "closed"
  # Write closed_at for the idempotency message.
  printf 'closed_at: "2026-10-20T00:00:00Z"\n' >> "$SPRINT_STATUS_YAML"
  _seed_retro "sprint-900"

  run "$CLOSE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
}

# ============================================================================
# Concurrent mode: two-phase close
# ============================================================================

@test "concurrent close writes status closed and closed_at atomically" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_retro "sprint-900"
  _seed_last_activated "sprint-900"

  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
  [ "$(_read_closed_at "$per_sprint")" = "2026-10-20T12:00:00Z" ]

  # No closing marker or sidecar should remain.
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
  [ ! -f "$STATE_DIR/.sprint-lifecycle.holder" ]
}

@test "concurrent close records close inputs for resume" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --force --rollover-keys "" 2>/dev/null

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  # close_inputs block should exist.
  grep -q 'close_inputs:' "$per_sprint"
  grep -q 'force_bypass:' "$per_sprint"
  grep -q 'closed_at:.*2026-10-20T12:00:00Z' "$per_sprint"
}

# ============================================================================
# Transitional state: limit 1 + per-sprint files = concurrent path
# ============================================================================

@test "transitional state routes to concurrent path with lifecycle lock" {
  _seed_single_config
  # Create a per-sprint file even though limit is 1 = transitional state.
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
  # close_inputs present = concurrent path was taken.
  grep -q 'close_inputs:' "$per_sprint"
}

# ============================================================================
# Release pre-check
# ============================================================================

@test "release pre-check reports ids of closed sprints" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "closed" 3 3
  _seed_per_sprint_yaml "sprint-901" "active" 3 3
  _seed_proxy_yaml "sprint-900" "closed"

  run "$PRE_RELEASE_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
  # Active sprint should not be reported.
  local active_count
  active_count="$(printf '%s\n' "$output" | grep -c 'sprint-901' || true)"
  [ "$active_count" -eq 0 ]
}

@test "release pre-check is a no-op in single-sprint mode" {
  _seed_single_config
  _seed_proxy_yaml "sprint-900" "active"

  run "$PRE_RELEASE_SH"
  [ "$status" -eq 0 ]
  # No output in single-sprint mode.
  [ -z "$output" ]
}

@test "release pre-check exits 3 when closing marker persists to timeout" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"

  # Plant a closing marker with a live pid (our own).
  printf 'sprint_id=sprint-900\nowner_pid=%d\nstart_time=2026-10-20T12:00:00Z\n' "$$" \
    > "$STATE_DIR/.sprint-closing-sprint-900"

  # Set a very short timeout for the test.
  export GAIA_PRE_RELEASE_TIMEOUT=2
  export GAIA_PRE_RELEASE_POLL_MS=200

  run "$PRE_RELEASE_SH"
  [ "$status" -eq 3 ]
  [[ "$output" == *"sprint close in progress"* ]]
  [[ "$output" == *"sprint-900"* ]]

  # Cleanup.
  rm -f "$STATE_DIR/.sprint-closing-sprint-900"
}

# ============================================================================
# Closing marker blocks injection
# ============================================================================

@test "inject refuses while closing marker is present" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"

  # Plant a closing marker.
  printf 'sprint_id=sprint-900\nowner_pid=%d\nstart_time=2026-10-20T12:00:00Z\n' "$$" \
    > "$STATE_DIR/.sprint-closing-sprint-900"

  # Create a story file for injection.
  local story_dir="$ART_DIR/epic-E900-test/E900-S4-test/story.md"
  mkdir -p "$(dirname "$story_dir")"
  cat > "$story_dir" <<'YAML'
---
template: 'story'
key: "E900-S4"
title: "Test story"
epic: "E900"
status: ready-for-dev
sprint_id: "sprint-900"
points: 3
risk: medium
---
# Story: Test story
YAML

  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml"
  export IMPLEMENTATION_ARTIFACTS="$ART_DIR"

  run "$SPRINT_STATE_SH" inject --story "E900-S4" --sprint-id "sprint-900"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sprint close in progress -- injection refused"* ]]

  # Cleanup.
  rm -f "$STATE_DIR/.sprint-closing-sprint-900"
}

@test "inject succeeds after closing marker is removed" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"

  # No closing marker.
  local story_dir="$ART_DIR/epic-E900-test/E900-S4-test/story.md"
  mkdir -p "$(dirname "$story_dir")"
  cat > "$story_dir" <<'YAML'
---
template: 'story'
key: "E900-S4"
title: "Test story"
epic: "E900"
status: ready-for-dev
sprint_id: "sprint-900"
points: 3
risk: medium
---
# Story: Test story
YAML

  export SPRINT_STATUS_YAML="$STATE_DIR/sprint-status-sprint-900.yaml"
  export IMPLEMENTATION_ARTIFACTS="$ART_DIR"

  run "$SPRINT_STATE_SH" inject --story "E900-S4" --sprint-id "sprint-900"
  [ "$status" -eq 0 ]
}

@test "no closing marker in single-sprint mode" {
  _seed_single_config
  _seed_proxy_yaml "sprint-900" "active"

  local story_dir="$ART_DIR/epic-E900-test/E900-S5-test/story.md"
  mkdir -p "$(dirname "$story_dir")"
  cat > "$story_dir" <<'YAML'
---
template: 'story'
key: "E900-S5"
title: "Test story 5"
epic: "E900"
status: ready-for-dev
sprint_id: "sprint-900"
points: 3
risk: medium
---
# Story: Test story 5
YAML

  export IMPLEMENTATION_ARTIFACTS="$ART_DIR"

  run "$SPRINT_STATE_SH" inject --story "E900-S5"
  [ "$status" -eq 0 ]
}

# ============================================================================
# Post-close audit
# ============================================================================

@test "post-close audit rolls back when non-done non-rollover story found" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 2 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Sprint has 3 stories, only 2 done (E900-S3 is in-progress).
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -ne 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  # Sprint should be rolled back to review (not closed).
  [ "$(_read_status "$per_sprint")" = "review" ]
}

@test "post-close audit rollback via injection seam restores pre-close status" {
  # Use the test-only injection seam to add a non-done story AFTER the
  # status write but BEFORE the post-close audit. This bypasses the
  # Phase B pre-check so the audit itself runs and rolls back.
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"

  # Write the injection script: inserts a non-done story into the stories block.
  # The story must appear BEFORE the first top-level key after stories:
  # (i.e. before closed_at:) so the awk parser in _close_non_done_stories sees it.
  local inject_script="$TEST_TMP/inject-non-done.sh"
  cat > "$inject_script" <<'SH'
#!/usr/bin/env bash
yaml="$1"
awk '
  /^closed_at:/ && !injected {
    printf "  - key: \"E900-S99\"\n"
    printf "    title: \"Injected late\"\n"
    printf "    status: in-progress\n"
    printf "    points: 2\n"
    printf "    risk_level: low\n"
    injected=1
  }
  { print }
' "$yaml" > "${yaml}.injected"
mv "${yaml}.injected" "$yaml"
SH
  chmod +x "$inject_script"

  export _GAIA_CLOSE_INJECT_AFTER_WRITE="$inject_script"

  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -ne 0 ]

  # Sprint must be rolled back to review (the exact pre-close status, not active).
  [ "$(_read_status "$per_sprint")" = "review" ]

  # Diagnostic names the injected story.
  [[ "$output" == *"E900-S99"* ]]

  unset _GAIA_CLOSE_INJECT_AFTER_WRITE
}

@test "post-close audit passes with rollover-exempt stories" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 2 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # E900-S3 is in-progress but declared as rollover.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --rollover-keys "E900-S3"
  [ "$status" -eq 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
}

# ============================================================================
# Four event edges
# ============================================================================

@test "review-to-closed with sentinel emits sprint_transitioned" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_transitioned"' "$LIFECYCLE"
}

@test "review-to-closed with bypass env emits sprint_transitioned" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"
  export GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --force 2>/dev/null

  [ -f "$LIFECYCLE" ]
  grep -q '"event_type":"sprint_transitioned"' "$LIFECYCLE"
}

@test "force without sentinel and bypass unset emits no lifecycle event" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"
  unset GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --force 2>/dev/null

  # With --force but no bypass env, review-to-closed should NOT emit.
  if [ -f "$LIFECYCLE" ]; then
    local count
    count="$(grep -c '"event_type":"sprint_transitioned"' "$LIFECYCLE" || true)"
    [ "$count" -eq 0 ]
  fi
}

@test "active-to-closed emits no sprint_transitioned event" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status active 2>/dev/null

  if [ -f "$LIFECYCLE" ]; then
    local count
    count="$(grep -c '"event_type":"sprint_transitioned"' "$LIFECYCLE" || true)"
    [ "$count" -eq 0 ]
  fi
}

# ============================================================================
# Same-sprint double close
# ============================================================================

@test "concurrent re-close of already-closed sprint exits 0" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # First close.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # Second close of the same sprint.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T13:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]

  # closed_at should be unchanged (first close's timestamp).
  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_closed_at "$per_sprint")" = "2026-10-20T12:00:00Z" ]
}

@test "same-sprint concurrent double close: only one writes, other exits cleanly" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Launch two concurrent close processes for the same sprint.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review >"$TEST_TMP/close-a.out" 2>&1 &
  local pid_a=$!

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:01:00Z" \
    --pre-close-status review >"$TEST_TMP/close-b.out" 2>&1 &
  local pid_b=$!

  local rc_a=0 rc_b=0
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?

  # At least one must succeed (exit 0); the other is 0 (idempotent) or 3 (retry).
  local successes=0
  [ "$rc_a" -eq 0 ] && successes=$((successes + 1))
  [ "$rc_b" -eq 0 ] && successes=$((successes + 1))
  [ "$successes" -ge 1 ]

  # Sprint must be closed.
  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]

  # closed_at must be set and consistent (one value, not corrupted).
  local closed_at
  closed_at="$(_read_closed_at "$per_sprint")"
  [ -n "$closed_at" ]

  # No closing marker or sidecar should remain.
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
  [ ! -f "$STATE_DIR/.sprint-lifecycle.holder" ]
}

@test "stale-owner marker replaced on next close" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Plant a stale marker with a dead pid.
  printf 'sprint_id=sprint-900\nowner_pid=99999\nstart_time=2026-10-20T12:00:00Z\n' \
    > "$STATE_DIR/.sprint-closing-sprint-900"

  # Close should replace the stale marker and proceed.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
}

# ============================================================================
# Resume: closed but no archive
# ============================================================================

@test "resume completes for closed sprint with missing archive" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Close the sprint (creates close_inputs).
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # Verify it's closed.
  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]

  # Resume (the sprint-state.sh close writer handles it).
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume"* ]] || [[ "$output" == *"already closed"* ]]
}

# ============================================================================
# Proxy post-write hook
# ============================================================================

@test "proxy shows closed after concurrent close of last-activated sprint" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # The proxy file should show status: closed.
  local proxy="$STATE_DIR/sprint-status.yaml"
  if [ -f "$proxy" ]; then
    [ "$(_read_status "$proxy")" = "closed" ]
  fi
}

# ============================================================================
# Snapshot refresh on close
# ============================================================================

@test "per-sprint cache removed after close" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Create a per-sprint cache file.
  printf '{}' > "$STATE_DIR/.sprint-progress-cache-sprint-900.json"

  # Create a stub snapshot script.
  local snapshot_stub="$BATS_TEST_DIRNAME/../scripts/sprint-progress-snapshot.sh"
  local snapshot_backup=""
  if [ -f "$snapshot_stub" ]; then
    snapshot_backup="$(mktemp)"
    cp "$snapshot_stub" "$snapshot_backup"
  fi
  cat > "$snapshot_stub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint) sprint_id="$2"; shift 2 ;;
    *) shift ;;
  esac
done
state_dir="${PROJECT_ROOT:-.}/.gaia/state"
rm -f "${state_dir}/.sprint-progress-cache-${sprint_id}.json"
SH
  chmod +x "$snapshot_stub"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # Cache should be removed.
  [ ! -f "$STATE_DIR/.sprint-progress-cache-sprint-900.json" ]

  # Restore original snapshot script.
  if [ -n "$snapshot_backup" ]; then
    mv "$snapshot_backup" "$snapshot_stub"
  fi
}

# ============================================================================
# Symlink refusal (strict mode)
# ============================================================================

@test "close refuses symlink at lifecycle lock path with exit 4" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Plant a symlink at the lifecycle lock path.
  ln -sf /dev/null "$STATE_DIR/.sprint-lifecycle.lock"

  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 4 ] || [ "$status" -eq 3 ]
  # Diagnostic should mention the path.
  [[ "$output" == *"lock"* ]] || [[ "$output" == *"symlink"* ]] || [[ "$output" == *"sprint close in progress"* ]]

  rm -f "$STATE_DIR/.sprint-lifecycle.lock"
}

@test "release pre-check refuses symlink at lifecycle lock path" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "closed" 3 3
  _seed_proxy_yaml "sprint-900" "closed"

  ln -sf /dev/null "$STATE_DIR/.sprint-lifecycle.lock"

  run "$PRE_RELEASE_SH"
  [ "$status" -ne 0 ]

  rm -f "$STATE_DIR/.sprint-lifecycle.lock"
}

# ============================================================================
# Internal ID scrub
# ============================================================================

@test "no internal traceability IDs in published files" {
  local files_to_check=(
    "$BATS_TEST_DIRNAME/../scripts/sprint-state.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/close.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-release/scripts/pre-release-sprint-check.sh"
    "$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/SKILL.md"
    "$BATS_TEST_DIRNAME/../skills/gaia-release/SKILL.md"
  )

  local hits=0
  local f
  for f in "${files_to_check[@]}"; do
    [ -f "$f" ] || continue
    # Check for leaked internal IDs (FR-nnn, ADR-nnn, E##-S##, etc.)
    # Exclude test fixtures and regex patterns.
    local count
    count="$(/usr/bin/grep -cE '\bFR-[0-9]+\b|\bADR-[0-9]+\b|\bSR-[0-9]+\b|\bNFR-[0-9]+\b' "$f" 2>/dev/null)" || count=0
    hits=$((hits + count))
    # Check for E##-S## story keys (but allow E900-S* test fixtures).
    count="$(/usr/bin/grep -cE '\bE[0-9]+-S[0-9]+\b' "$f" 2>/dev/null)" || count=0
    if [ "$count" -gt 0 ]; then
      # Filter out allowed patterns (E900-S* test fixtures, regex patterns).
      local real_leaks
      real_leaks="$(/usr/bin/grep -E '\bE[0-9]+-S[0-9]+\b' "$f" | /usr/bin/grep -cvE 'E900-S|E[0-9]+-S\[0-9\]' 2>/dev/null)" || real_leaks=0
      hits=$((hits + real_leaks))
    fi
  done

  [ "$hits" -eq 0 ]
}

# ============================================================================
# Sole-writer guard: close.sh has no direct yq writes
# ============================================================================

@test "close.sh contains no direct yq -i writes to the state file" {
  local count
  count="$(/usr/bin/grep -cE 'yq -i.*status.*closed|yq -i.*closed_at|yq.*-i.*YAML_PATH' "$CLOSE_SH" 2>/dev/null)" || count=0
  [ "$count" -eq 0 ]
}

@test "re-adding a direct yq write to close.sh turns the sole-writer test red" {
  # Create a temporary copy of close.sh with a yq -i write added back.
  local mutant="$TEST_TMP/close-mutant.sh"
  cp "$CLOSE_SH" "$mutant"
  printf '\nyq -i ".status = \"closed\"" "$YAML_PATH"\n' >> "$mutant"

  local count
  count="$(/usr/bin/grep -cE 'yq -i.*status.*closed|yq -i.*closed_at|yq.*-i.*YAML_PATH' "$mutant" 2>/dev/null)" || count=0
  [ "$count" -gt 0 ]
}

# ============================================================================
# FCFS ordering (flock acquisition order determines order)
# ============================================================================

@test "two different sprints close concurrently and both succeed" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_per_sprint_yaml "sprint-901" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_sentinel "sprint-901"
  _seed_last_activated "sprint-900"

  # Launch two concurrent close processes for different sprints.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review >"$TEST_TMP/close-900.out" 2>&1 &
  local pid_900=$!

  "$SPRINT_STATE_SH" close --sprint-id "sprint-901" --closed-at "2026-10-20T12:00:01Z" \
    --pre-close-status review >"$TEST_TMP/close-901.out" 2>&1 &
  local pid_901=$!

  local rc_900=0 rc_901=0
  wait "$pid_900" || rc_900=$?
  wait "$pid_901" || rc_901=$?

  # Both must succeed.
  [ "$rc_900" -eq 0 ]
  [ "$rc_901" -eq 0 ]

  # Both sprints must be closed.
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "closed" ]
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-901.yaml")" = "closed" ]

  # No markers or sidecars remain.
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-901" ]
  [ ! -f "$STATE_DIR/.sprint-lifecycle.holder" ]
}

# ============================================================================
# Holder sidecar visible to waiters
# ============================================================================

@test "holder sidecar removed after phase A completes" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Close sprint-900.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # After close completes, sidecar must be gone.
  [ ! -f "$STATE_DIR/.sprint-lifecycle.holder" ]
  # Closing marker must also be gone (removed by owning process after Phase B).
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
}

# ============================================================================
# Fallback lock mode (GAIA_LOCK_FORCE_FALLBACK=1)
# ============================================================================

@test "close works with GAIA_LOCK_FORCE_FALLBACK=1" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  export GAIA_LOCK_FORCE_FALLBACK=1
  export GAIA_PARALLEL_EXECUTION=0

  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
}

@test "resume runs proxy hook when closed sprint is last-activated" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Close the sprint.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # Sprint is closed; proxy should show closed.
  if [ -f "$STATE_DIR/sprint-status.yaml" ]; then
    [ "$(_read_status "$STATE_DIR/sprint-status.yaml")" = "closed" ]
  fi

  # Resume.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]

  # Proxy still shows closed after resume.
  if [ -f "$STATE_DIR/sprint-status.yaml" ]; then
    [ "$(_read_status "$STATE_DIR/sprint-status.yaml")" = "closed" ]
  fi
}

# ============================================================================
# SIGKILL recovery via test-only pause seams (task 5.6)
# ============================================================================

@test "SIGKILL during Phase A: marker and sidecar cleaned on retry" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  local pause_file="$TEST_TMP/phase-a-ready"
  export _GAIA_CLOSE_PAUSE_PHASE_A="$pause_file"
  export GAIA_PARALLEL_EXECUTION=0

  # Launch close in background; it will pause in Phase A.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review >"$TEST_TMP/kill-a.out" 2>&1 &
  local holder_pid=$!

  # Wait for the ready signal.
  local tries=0
  while [ ! -f "$pause_file" ] && [ "$tries" -lt 30 ]; do
    sleep 1
    tries=$((tries + 1))
  done
  [ -f "$pause_file" ]

  # Marker should exist at this point.
  [ -f "$STATE_DIR/.sprint-closing-sprint-900" ]

  # SIGKILL all descendants then the holder itself.
  # Use recursive kill: find all descendants via pgrep.
  local _desc
  _desc="$(pgrep -P "$holder_pid" 2>/dev/null)" || true
  for _dp in $_desc; do
    local _gd
    _gd="$(pgrep -P "$_dp" 2>/dev/null)" || true
    for _gp in $_gd; do kill -9 "$_gp" 2>/dev/null || true; done
    kill -9 "$_dp" 2>/dev/null || true
  done
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  rm -f "$pause_file"

  unset _GAIA_CLOSE_PAUSE_PHASE_A

  # Sprint should NOT be closed (killed before Phase B).
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "review" ]

  # Retry: the stale marker should be replaced and close succeeds.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "closed" ]

  # No markers remain.
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
  [ ! -f "$STATE_DIR/.sprint-lifecycle.holder" ]
}

@test "SIGKILL during Phase B after status write: creates resume precondition" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  local pause_file="$TEST_TMP/phase-b-ready"
  export _GAIA_CLOSE_PAUSE_PHASE_B="$pause_file"
  export GAIA_PARALLEL_EXECUTION=0

  # Launch close in background; it will pause after the status write.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review >"$TEST_TMP/kill-b.out" 2>&1 &
  local holder_pid=$!

  # Wait for the ready signal.
  local tries=0
  while [ ! -f "$pause_file" ] && [ "$tries" -lt 30 ]; do
    sleep 1
    tries=$((tries + 1))
  done
  [ -f "$pause_file" ]

  # Sprint should be closed (status write completed before pause).
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "closed" ]

  # SIGKILL all descendants then the holder itself.
  local _desc
  _desc="$(pgrep -P "$holder_pid" 2>/dev/null)" || true
  for _dp in $_desc; do
    local _gd
    _gd="$(pgrep -P "$_dp" 2>/dev/null)" || true
    for _gp in $_gd; do kill -9 "$_gp" 2>/dev/null || true; done
    kill -9 "$_dp" 2>/dev/null || true
  done
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  rm -f "$pause_file"

  unset _GAIA_CLOSE_PAUSE_PHASE_B

  # Closing marker may still be present (owning process was killed).
  # The stale marker has a dead pid, so the next close replaces it.

  # Resume: sprint is closed but audit/archive may be incomplete.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]

  # Sprint still closed.
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "closed" ]
  # Markers cleaned up.
  [ ! -f "$STATE_DIR/.sprint-closing-sprint-900" ]
}

@test "pause seams are inert when unset" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Ensure the env vars are unset.
  unset _GAIA_CLOSE_PAUSE_PHASE_A
  unset _GAIA_CLOSE_PAUSE_PHASE_B
  unset _GAIA_CLOSE_INJECT_AFTER_WRITE

  # Close should succeed without any pause.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]
  [ "$(_read_status "$STATE_DIR/sprint-status-sprint-900.yaml")" = "closed" ]
}

# ============================================================================
# Resume end-to-end (task 5.17 / 5.18)
# ============================================================================

@test "resume after normal close reuses recorded closed_at" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Close the sprint with a specific timestamp.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  [ "$(_read_status "$per_sprint")" = "closed" ]
  [ "$(_read_closed_at "$per_sprint")" = "2026-10-20T12:00:00Z" ]

  # Resume with a different timestamp — recorded one is used.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T13:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]

  # closed_at unchanged (recorded value).
  [ "$(_read_closed_at "$per_sprint")" = "2026-10-20T12:00:00Z" ]
}

@test "resume after force close reuses recorded bypass" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --force 2>/dev/null

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  # close_inputs should record force_bypass: 1.
  grep -q 'force_bypass: 1' "$per_sprint"

  # Resume.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]
}

@test "resume after force-with-rollover close reuses recorded rollover keys" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 2 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --rollover-keys "E900-S3" 2>/dev/null

  local per_sprint="$STATE_DIR/sprint-status-sprint-900.yaml"
  grep -q 'rollover_keys:.*E900-S3' "$per_sprint"

  # Resume.
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review --resume
  [ "$status" -eq 0 ]
}

@test "re-close with archive present exits 0 already closed" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "review" 3 3
  _seed_proxy_yaml "sprint-900" "review"
  _seed_sentinel "sprint-900"
  _seed_last_activated "sprint-900"

  # Close and create a fake archive.
  "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T12:00:00Z" \
    --pre-close-status review 2>/dev/null

  # Re-close (already closed).
  run "$SPRINT_STATE_SH" close --sprint-id "sprint-900" --closed-at "2026-10-20T13:00:00Z" \
    --pre-close-status review
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
}

# ============================================================================
# Release pre-check marker poll (task 5.20)
# ============================================================================

@test "release pre-check polls until marker removed then reports closed" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"

  # Plant a closing marker.
  printf 'sprint_id=sprint-900\nowner_pid=%d\nstart_time=now\n' "$$" \
    > "$STATE_DIR/.sprint-closing-sprint-900"

  # Remove the marker after 1 second in the background.
  (sleep 1; rm -f "$STATE_DIR/.sprint-closing-sprint-900";
   # Mark the sprint as closed so the pre-check reports it.
   sed -i.bak 's/^status: active/status: closed/' "$STATE_DIR/sprint-status-sprint-900.yaml") &
  local cleanup_pid=$!

  export GAIA_PRE_RELEASE_TIMEOUT=5
  export GAIA_PRE_RELEASE_POLL_MS=200

  run "$PRE_RELEASE_SH"
  wait "$cleanup_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [[ "$output" == *"sprint-900"* ]]
}

@test "release pre-check with stale marker blocks until timeout" {
  _seed_config 2
  _seed_per_sprint_yaml "sprint-900" "active" 3 3
  _seed_proxy_yaml "sprint-900" "active"

  # Plant a closing marker with a live pid (our own — never removed).
  printf 'sprint_id=sprint-900\nowner_pid=%d\nstart_time=now\n' "$$" \
    > "$STATE_DIR/.sprint-closing-sprint-900"

  export GAIA_PRE_RELEASE_TIMEOUT=2
  export GAIA_PRE_RELEASE_POLL_MS=200

  run "$PRE_RELEASE_SH"

  [ "$status" -eq 3 ]
  [[ "$output" == *"sprint close in progress"* ]]
  [[ "$output" == *"sprint-900"* ]]

  rm -f "$STATE_DIR/.sprint-closing-sprint-900"
}
