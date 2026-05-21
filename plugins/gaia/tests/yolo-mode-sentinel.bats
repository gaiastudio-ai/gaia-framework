#!/usr/bin/env bats
# yolo-mode-sentinel.bats — AF-2026-05-21-4 Finding 2
#
# Asserts the cross-Bash-tool-call YOLO state persistence via the
# .gaia/state/.yolo-active sentinel file. Env vars (GAIA_YOLO_FLAG /
# GAIA_YOLO_MODE) don't survive across Claude Code Bash tool calls, so
# the sentinel-file fallback is the durable contract.

load 'test_helper.bash'

setup() {
  common_setup
  YOLO="$SCRIPTS_DIR/yolo-mode.sh"
  # Sentinel directory per-test so concurrent runs don't collide.
  export GAIA_YOLO_SENTINEL="$TEST_TMP/.yolo-active"
  # Ensure no inherited env state contaminates the test.
  unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT
}

teardown() {
  unset GAIA_YOLO_SENTINEL GAIA_YOLO_FLAG GAIA_YOLO_MODE \
        GAIA_YOLO_OVERRIDE GAIA_CONTEXT
  common_teardown
}

@test "AF-2026-05-21-4 #2: is_yolo returns 1 when no env and no sentinel" {
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
}

@test "AF-2026-05-21-4 #2: yolo-mode.sh set creates the sentinel file" {
  run bash "$YOLO" set
  [ "$status" -eq 0 ]
  [ -f "$GAIA_YOLO_SENTINEL" ]
}

@test "AF-2026-05-21-4 #2: is_yolo returns 0 when sentinel exists (no env)" {
  bash "$YOLO" set
  [ -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
}

@test "AF-2026-05-21-4 #2: cross-process persistence — sentinel survives bash invocations" {
  # The root failure: env-var YOLO state is lost between Bash tool calls.
  # Demonstrate the sentinel survives.
  bash "$YOLO" set
  # Simulate the "next Bash tool call" with NO env exports
  run env -i bash -c "GAIA_YOLO_SENTINEL='$GAIA_YOLO_SENTINEL' bash '$YOLO' is_yolo"
  [ "$status" -eq 0 ]
}

@test "AF-2026-05-21-4 #2: yolo-mode.sh clear removes the sentinel" {
  bash "$YOLO" set
  [ -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" clear
  [ "$status" -eq 0 ]
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
}

@test "AF-2026-05-21-4 #2: set + clear are idempotent" {
  # set twice
  bash "$YOLO" set
  run bash "$YOLO" set
  [ "$status" -eq 0 ]
  [ -f "$GAIA_YOLO_SENTINEL" ]
  # clear twice
  bash "$YOLO" clear
  run bash "$YOLO" clear
  [ "$status" -eq 0 ]
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
}

@test "AF-2026-05-21-4 #2: GAIA_YOLO_OVERRIDE=no wins over the sentinel" {
  bash "$YOLO" set
  GAIA_YOLO_OVERRIDE=no run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
}

@test "AF-2026-05-21-4 #2: GAIA_CONTEXT=memory-save wins over the sentinel" {
  bash "$YOLO" set
  GAIA_CONTEXT=memory-save run bash "$YOLO" is_yolo
  [ "$status" -eq 1 ]
}

@test "AF-2026-05-21-4 #2: help text documents the sentinel + set/clear subcommands" {
  run bash "$YOLO" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"set"* ]]
  [[ "$output" == *"clear"* ]]
  [[ "$output" == *"sentinel"* ]]
}

@test "AF-2026-05-21-4 #2: env-var GAIA_YOLO_FLAG=1 still wins (precedence rule 3)" {
  # Regression guard: the new sentinel rule must NOT shadow the env-var rules
  # for callers that DO export GAIA_YOLO_FLAG=1 (e.g. tests with controlled env).
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
  GAIA_YOLO_FLAG=1 run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
}

@test "AF-2026-05-21-4 #2: yolo_set + yolo_clear are sourceable library functions" {
  # NFR-052 public-function coverage: explicitly reference the function names
  # so the deterministic public-function grep at run-with-coverage.sh sees
  # them in this bats file. The functions ARE exercised by the `bash
  # yolo-mode.sh set` / `clear` subcommand tests above (those internally
  # invoke yolo_set / yolo_clear) — this test pins the canonical name
  # binding for the coverage gate.
  run bash -c "source '$YOLO' && declare -F yolo_set yolo_clear"
  [ "$status" -eq 0 ]
  [[ "$output" == *"yolo_set"* ]]
  [[ "$output" == *"yolo_clear"* ]]
  # Direct library invocation — exercises both functions via their canonical
  # names, complementing the subcommand-form tests above.
  bash -c "source '$YOLO' && GAIA_YOLO_SENTINEL='$GAIA_YOLO_SENTINEL' yolo_set"
  [ -f "$GAIA_YOLO_SENTINEL" ]
  bash -c "source '$YOLO' && GAIA_YOLO_SENTINEL='$GAIA_YOLO_SENTINEL' yolo_clear"
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
}
