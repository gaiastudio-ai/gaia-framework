#!/usr/bin/env bats
# e41-s1-yolo-mode.bats — regression suite for plugins/gaia/scripts/yolo-mode.sh
#
# Story: E41-S1 (YOLO Mode Contract + Helper)
# Architecture: §10.30.4 (canonical is_yolo helper)
# ADR: ADR-057 (YOLO Mode Contract for V2 Phase 4 Commands)
#
# Coverage:
#   TC-YOLO-1  — GAIA_YOLO_FLAG=1 -> exit 0
#   TC-YOLO-2  — GAIA_YOLO_MODE=1 -> exit 0 (inheritance)
#   TC-YOLO-3  — neither set      -> exit 1
#   TC-YOLO-12 — GAIA_CONTEXT=memory-save -> exit 1 (E9-S8 invariant)
#   ECI-496    — --yolo and --no-yolo: opt-out wins (GAIA_YOLO_OVERRIDE=no)
#   ECI-497    — GAIA_YOLO_MODE + GAIA_YOLO_OVERRIDE=no: opt-out wins
#   ECI-500    — GAIA_YOLO_MODE with falsy values ("0"/"false"/"no"/"") -> exit 1
#   ECI-507    — Nested propagation: parent YOLO -> child -> grandchild
#
# Per architecture.md §10.30.4 the precedence order (top wins):
#   1. GAIA_CONTEXT=memory-save -> exit 1
#   2. GAIA_YOLO_OVERRIDE=no    -> exit 1
#   3. GAIA_YOLO_FLAG=1         -> exit 0
#   4. GAIA_YOLO_MODE=1         -> exit 0
#   5. default                  -> exit 1

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/yolo-mode.sh"
}

teardown() { common_teardown; }

# Strip every YOLO-related env so each test starts from a clean baseline.
clean_env() {
  unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT
}

# --- Existence + invocation contract ----------------------------------------

@test "yolo-mode.sh: file exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "yolo-mode.sh: defines public is_yolo function" {
  # NFR-052 public-function coverage: the function name MUST be parseable
  # by run-with-coverage.sh's grep ('^[a-z_][a-z0-9_]*\(\) {').
  grep -qE '^is_yolo\(\)[[:space:]]*\{' "$SCRIPT"
}

@test "yolo-mode.sh: sourceable without side effects" {
  clean_env
  run bash -c "source '$SCRIPT'"
  [ "$status" -eq 0 ]
}

# --- TC-YOLO-1 -------------------------------------------------------------

@test "GAIA_YOLO_FLAG=1 yields exit 0" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=1 is_yolo"
  [ "$status" -eq 0 ]
}

# --- TC-YOLO-2 -------------------------------------------------------------

@test "GAIA_YOLO_MODE=1 (inheritance) yields exit 0" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=1 is_yolo"
  [ "$status" -eq 0 ]
}

# --- TC-YOLO-3 -------------------------------------------------------------

@test "neither flag nor inheritance set yields exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && is_yolo"
  [ "$status" -eq 1 ]
}

# --- TC-YOLO-12 ------------------------------------------------------------

@test "GAIA_CONTEXT=memory-save forces exit 1 even with GAIA_YOLO_MODE=1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_CONTEXT=memory-save GAIA_YOLO_MODE=1 is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_CONTEXT=memory-save forces exit 1 even with GAIA_YOLO_FLAG=1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_CONTEXT=memory-save GAIA_YOLO_FLAG=1 is_yolo"
  [ "$status" -eq 1 ]
}

# --- ECI-496: --yolo + --no-yolo (opt-out wins) ----------------------------

@test "GAIA_YOLO_FLAG=1 + GAIA_YOLO_OVERRIDE=no => exit 1 (opt-out wins)" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=1 GAIA_YOLO_OVERRIDE=no is_yolo"
  [ "$status" -eq 1 ]
}

# --- ECI-497: inheritance env + explicit opt-out ---------------------------

@test "GAIA_YOLO_MODE=1 + GAIA_YOLO_OVERRIDE=no => exit 1 (opt-out wins)" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=1 GAIA_YOLO_OVERRIDE=no is_yolo"
  [ "$status" -eq 1 ]
}

# --- ECI-500: only the exact string "1" activates --------------------------

@test "GAIA_YOLO_MODE=0 => exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=0 is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_YOLO_MODE=false => exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=false is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_YOLO_MODE=no => exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=no is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_YOLO_MODE=\"\" (empty string) => exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE='' is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_YOLO_FLAG=0 => exit 1 (only \"1\" activates)" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=0 is_yolo"
  [ "$status" -eq 1 ]
}

@test "GAIA_YOLO_FLAG=true => exit 1 (only \"1\" activates)" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=true is_yolo"
  [ "$status" -eq 1 ]
}

# --- ECI-507: Nested subagent propagation ----------------------------------

@test "parent YOLO env propagates to child and grandchild via GAIA_YOLO_MODE" {
  clean_env
  # Simulate two levels of nested subprocess that inherit env.
  run bash -c "
    source '$SCRIPT'
    GAIA_YOLO_MODE=1 bash -c '
      source \"$SCRIPT\"
      bash -c \"source \\\"$SCRIPT\\\" && is_yolo\"
    '
  "
  [ "$status" -eq 0 ]
}

@test "grandchild --no-yolo override breaks propagation" {
  clean_env
  run bash -c "
    source '$SCRIPT'
    GAIA_YOLO_MODE=1 bash -c '
      bash -c \"source \\\"$SCRIPT\\\" && GAIA_YOLO_OVERRIDE=no is_yolo\"
    '
  "
  [ "$status" -eq 1 ]
}

# --- Precedence regression -------------------------------------------------

@test "precedence: memory-save beats GAIA_YOLO_OVERRIDE=no (both yield exit 1, memory-save evaluated first)" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_CONTEXT=memory-save GAIA_YOLO_OVERRIDE=no is_yolo"
  [ "$status" -eq 1 ]
}

@test "precedence: GAIA_YOLO_FLAG=1 beats GAIA_YOLO_MODE=0" {
  clean_env
  # FLAG=1 alone activates (rule 3); MODE=0 is irrelevant for the flag path.
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=1 GAIA_YOLO_MODE=0 is_yolo"
  [ "$status" -eq 0 ]
}

# --- Direct invocation (not just sourced) ----------------------------------

@test "yolo-mode.sh: direct invocation as 'is_yolo' subcommand also works" {
  clean_env
  # When invoked directly the script should expose the same exit semantics.
  run env GAIA_YOLO_FLAG=1 "$SCRIPT" is_yolo
  [ "$status" -eq 0 ]
  run env -i HOME="$HOME" PATH="$PATH" "$SCRIPT" is_yolo
  [ "$status" -eq 1 ]
}
