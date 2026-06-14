#!/usr/bin/env bats
# dev-story-yolo-activation.bats
#
# Regression for the dev-story --yolo no-op: the skill documents `yolo` /
# `--yolo` as the way to auto-advance past confirmation gates, but nothing in
# setup.sh translated that argument into an activation signal — so
# yolo-mode.sh is_yolo returned the interactive verdict even when launched with
# --yolo, and every yolo_steps gate silently took the interactive branch.
#
# The fix: setup.sh scans $ARGUMENTS (the !-Setup directive does not forward
# positional args) for `yolo` / `--yolo` and runs `yolo-mode.sh set` to create
# the cross-Bash-call .yolo-active sentinel. SKILL.md documents the activation.

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  SETUP_SH="$SKILLS_DIR/gaia-dev-story/scripts/setup.sh"
  SKILL_MD="$SKILLS_DIR/gaia-dev-story/SKILL.md"
  YOLO="$SCRIPTS_DIR/yolo-mode.sh"
  # Per-test sentinel + state so concurrent runs don't collide.
  export GAIA_YOLO_SENTINEL="$TEST_TMP/.yolo-active"
  unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT ARGUMENTS
}

teardown() {
  unset GAIA_YOLO_SENTINEL GAIA_YOLO_FLAG GAIA_YOLO_MODE \
        GAIA_YOLO_OVERRIDE GAIA_CONTEXT ARGUMENTS
  common_teardown
}

# --- setup.sh source-level wiring -------------------------------------------

@test "setup.sh detects yolo via \$ARGUMENTS (not just positional args)" {
  grep -Fq 'ARGUMENTS' "$SETUP_SH"
  grep -Eq '" yolo "|" --yolo "' "$SETUP_SH"
}

@test "setup.sh activates YOLO via yolo-mode.sh set (sentinel), not a bare export" {
  # The sanctioned activation is the cross-call sentinel; a bare GAIA_YOLO_FLAG
  # export is only the single-shell fallback.
  grep -Eq 'yolo-mode\.sh.*set|"\$YOLO_MODE_SCRIPT" set' "$SETUP_SH"
}

@test "setup.sh is syntactically valid" {
  run bash -n "$SETUP_SH"
  [ "$status" -eq 0 ]
}

# --- behavioural: the activation block sets the sentinel --------------------
# Re-implements the setup.sh block in isolation against the real yolo-mode.sh
# (running the full setup.sh needs a resolved project config; this asserts the
# detection + activation contract the block encodes).

_activate() {
  local args_blob=" $1 "
  if [[ "$args_blob" == *" yolo "* ]] || [[ "$args_blob" == *" --yolo "* ]]; then
    "$YOLO" set
  fi
}

@test "yolo arg creates the .yolo-active sentinel and is_yolo exits 0" {
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
  _activate "E107-S5 yolo"
  [ -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
}

@test "--yolo flag form also activates" {
  _activate "E107-S5 --yolo"
  [ -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" is_yolo
  [ "$status" -eq 0 ]
}

@test "no yolo arg leaves YOLO inactive (is_yolo exits non-zero)" {
  _activate "E107-S5"
  [ ! -f "$GAIA_YOLO_SENTINEL" ]
  run bash "$YOLO" is_yolo
  [ "$status" -ne 0 ]
}

# --- SKILL.md documents the activation contract ----------------------------

@test "SKILL.md documents entry-point YOLO activation (not only inheritance)" {
  run grep -Eq 'YOLO activation|\.yolo-active' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # The argument form is documented in the quick-reference table.
  grep -Eq 'yolo.*argument|`yolo`' "$SKILL_MD"
}
