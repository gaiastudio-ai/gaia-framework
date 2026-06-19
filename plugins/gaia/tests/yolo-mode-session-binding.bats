#!/usr/bin/env bats
# yolo-mode-session-binding.bats — regression guard for the stale-sentinel leak.
#
# A .yolo-active sentinel left by a PRIOR session must NOT silently flip a fresh
# interactive session into YOLO. yolo_set stamps the current session id into the
# sentinel; is_yolo Rule 5 honors it only when the stored id matches the current
# session, reaping a stale (mismatched/empty) sentinel. When no session id is
# resolvable on either side, the legacy existence-based contract is preserved.

load 'test_helper.bash'

setup() {
  common_setup
  YOLO="$SCRIPTS_DIR/yolo-mode.sh"
  export GAIA_YOLO_SENTINEL="$TEST_TMP/.yolo-active"
  unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT
}

teardown() {
  unset GAIA_YOLO_SENTINEL GAIA_YOLO_FLAG GAIA_YOLO_MODE \
        GAIA_YOLO_OVERRIDE GAIA_CONTEXT CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  common_teardown
}

# --- the #1594 reproduction ------------------------------------------------

@test "stale sentinel from a PRIOR session does not activate YOLO" {
  # Session A sets YOLO.
  CLAUDE_CODE_SESSION_ID="session-A" bash "$YOLO" set
  [ -f "$GAIA_YOLO_SENTINEL" ]
  # Session B (a later, interactive session) must NOT inherit A's YOLO.
  CLAUDE_CODE_SESSION_ID="session-B" run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
}

@test "a stale cross-session sentinel is reaped on read" {
  CLAUDE_CODE_SESSION_ID="session-A" bash "$YOLO" set
  [ -f "$GAIA_YOLO_SENTINEL" ]
  CLAUDE_CODE_SESSION_ID="session-B" run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
  # Reaped, so it can't leak into any later session either.
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
}

@test "legacy empty/0-byte sentinel does not activate a real session" {
  # The exact in-the-wild artifact: a 0-byte file from old code.
  : > "$GAIA_YOLO_SENTINEL"
  [ -f "$GAIA_YOLO_SENTINEL" ]
  CLAUDE_CODE_SESSION_ID="session-real" run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
}

# --- same-session still works (the legitimate cross-Bash-call contract) ----

@test "sentinel set and read within the SAME session stays active" {
  CLAUDE_CODE_SESSION_ID="session-X" bash "$YOLO" set
  CLAUDE_CODE_SESSION_ID="session-X" run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
}

@test "CLAUDE_SESSION_ID is honored as the fallback session id" {
  unset CLAUDE_CODE_SESSION_ID
  CLAUDE_SESSION_ID="sess-fallback" bash "$YOLO" set
  CLAUDE_SESSION_ID="sess-fallback" run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
  CLAUDE_SESSION_ID="sess-other" run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
}

# --- no-session fallback (CI / sourced) preserves legacy existence ---------

@test "no resolvable session id falls back to legacy existence contract" {
  # Neither session var set on set OR read → existence alone activates.
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$YOLO" set
  run env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
      bash -c "GAIA_YOLO_SENTINEL='$GAIA_YOLO_SENTINEL' bash '$YOLO' is_yolo"
  [ "$status" -eq 0 ]
}

@test "stamp written by set is the current session id" {
  CLAUDE_CODE_SESSION_ID="abc123" bash "$YOLO" set
  run head -n1 "$GAIA_YOLO_SENTINEL"
  [ "$output" = "abc123" ]
}
