#!/usr/bin/env bats
# orchestration-warning.bats — E84-S4 / ADR-093 / FR-446 lossy-mode warning.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/orchestration-warning.sh"
  CHECKPOINT_DIR="$TEST_TMP/checkpoints"
  mkdir -p "$CHECKPOINT_DIR"
}
teardown() { common_teardown; }

# ---- AC1: heavy-procedural + Mode A → warn ----

@test "AC1: heavy-procedural + subagent emits warning" {
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-1 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running in subagent mode"* ]]
  [[ "$output" == *"Mode A"* ]]
  [[ "$output" == *"lossy"* ]]
  [[ "$output" == *"ADR-093"* ]]
}

# ---- AC2: conversational + Mode A → warn ----

@test "AC2: conversational + subagent emits warning" {
  run "$SCRIPT" --skill-class conversational --mode subagent \
    --session-id sess-2 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running in subagent mode"* ]]
  [[ "$output" == *"lossy"* ]]
}

# ---- AC3: light-procedural → no warn ----

@test "AC3: light-procedural produces no warning" {
  run "$SCRIPT" --skill-class light-procedural --mode subagent \
    --session-id sess-3 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- AC3b: reviewer → no warn ----

@test "AC3b: reviewer produces no warning (clean-room invariant)" {
  run "$SCRIPT" --skill-class reviewer --mode subagent \
    --session-id sess-4 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- AC4: Mode B → no warn (any class) ----

@test "AC4: heavy-procedural + team produces no warning" {
  run "$SCRIPT" --skill-class heavy-procedural --mode team \
    --session-id sess-5 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC4: conversational + team produces no warning" {
  run "$SCRIPT" --skill-class conversational --mode team \
    --session-id sess-6 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- AC5: one-shot per session ----

@test "AC5: second invocation in same session is silent (marker honored)" {
  # First invocation: warning emitted, marker dropped.
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-7 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mode A"* ]]

  # Marker file must exist now.
  [ -e "$CHECKPOINT_DIR/orchestration-warning-shown.sess-7" ]

  # Second invocation with same session_id: silent.
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-7 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC5b: different session_id re-emits the warning" {
  # First session
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-A --checkpoint-path "$CHECKPOINT_DIR"
  [[ "$output" == *"Mode A"* ]]

  # Different session — should warn again.
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-B --checkpoint-path "$CHECKPOINT_DIR"
  [[ "$output" == *"Mode A"* ]]
}

# ---- session_id resolution ----

@test "session_id defaults to CLAUDE_SESSION_ID when not passed" {
  run env CLAUDE_SESSION_ID=env-derived-id \
    "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mode A"* ]]
  [ -e "$CHECKPOINT_DIR/orchestration-warning-shown.env-derived-id" ]
}

@test "session_id falls back to pid-PPID when CLAUDE_SESSION_ID unset" {
  run env -u CLAUDE_SESSION_ID \
    "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  # Marker should be pid-<digits>
  found=$(ls "$CHECKPOINT_DIR" | grep -c "^orchestration-warning-shown\.pid-[0-9]" || true)
  [ "$found" -ge 1 ]
}

# ---- path-traversal guard on session_id ----

@test "session_id with traversal sequence is rejected" {
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id "../evil" --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"path-traversal"* ]]
}

@test "session_id with slash is rejected" {
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id "a/b" --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 2 ]
}

# ---- enum validation ----

@test "invalid skill-class exits 2" {
  run "$SCRIPT" --skill-class bogus-class --mode subagent \
    --session-id sess-z --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --skill-class"* ]]
}

@test "invalid mode exits 2" {
  run "$SCRIPT" --skill-class heavy-procedural --mode bogus-mode \
    --session-id sess-z --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --mode"* ]]
}

# ---- arg parsing ----

@test "missing --skill-class exits 2" {
  run "$SCRIPT" --mode subagent --session-id sess-z
  [ "$status" -eq 2 ]
}

@test "missing --mode exits 2" {
  run "$SCRIPT" --skill-class heavy-procedural --session-id sess-z
  [ "$status" -eq 2 ]
}

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

# ---- AF-2026-05-18-2: surface-above-fold contract ----

@test "AF-2026-05-18-2: SURFACE-WARNING banner is the first stdout line" {
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-surface-1 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  first_line=$(printf '%s' "$output" | sed -n '1p')
  [[ "$first_line" == "SURFACE-WARNING: $CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-1" ]]
}

@test "AF-2026-05-18-2: sentinel file is written with the full warning body" {
  run "$SCRIPT" --skill-class conversational --mode subagent \
    --session-id sess-surface-2 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  sentinel="$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-2"
  [ -f "$sentinel" ]
  body=$(cat "$sentinel")
  [[ "$body" == *"running in subagent mode"* ]]
  [[ "$body" == *"Mode A"* ]]
  [[ "$body" == *"ADR-093"* ]]
  [[ "$body" == *"shown once per session"* ]]
}

@test "AF-2026-05-18-2: full warning still emitted to stdout (backward compat)" {
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-surface-3 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running in subagent mode"* ]]
  [[ "$output" == *"For the full-fidelity experience"* ]]
  [[ "$output" == *"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"* ]]
}

@test "AF-2026-05-18-2: suppressed paths do NOT write sentinel" {
  # Mode B → no sentinel
  run "$SCRIPT" --skill-class conversational --mode team \
    --session-id sess-surface-4 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-4" ]

  # Reviewer class → no sentinel
  run "$SCRIPT" --skill-class reviewer --mode subagent \
    --session-id sess-surface-5 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-5" ]

  # One-shot suppression → first call writes sentinel, second does NOT overwrite
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-surface-6 --checkpoint-path "$CHECKPOINT_DIR"
  [ -f "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-6" ]
  first_mtime=$(stat -f '%m' "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-6" 2>/dev/null || stat -c '%Y' "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-6")
  sleep 1
  run "$SCRIPT" --skill-class heavy-procedural --mode subagent \
    --session-id sess-surface-6 --checkpoint-path "$CHECKPOINT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  second_mtime=$(stat -f '%m' "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-6" 2>/dev/null || stat -c '%Y' "$CHECKPOINT_DIR/orchestration-warning-pending.sess-surface-6")
  [ "$first_mtime" -eq "$second_mtime" ]
}
