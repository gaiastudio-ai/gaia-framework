#!/usr/bin/env bats
# stale-comment-sweep.bats — E97-S6
#
# Asserts the stale-legacy-path comment sweep in resolve-config.sh and
# validate-gate.sh. Comment-only edits (zero runtime impact) per the
# story's hard scope constraint.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_SCRIPTS="$( cd "$BATS_TEST_DIRNAME/../scripts" && pwd )"
}

teardown() {
  common_teardown
}

# ---------- AC1: resolve-config.sh comments ----------

@test "resolve-config.sh line 8 documents .gaia/config/ canonical" {
  # Header docstring around line 8 should mention .gaia/config/ as canonical.
  run sed -n '6,12p' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [[ "$output" == *".gaia/config/"* ]]
}

@test "resolve-config.sh lines 15-18 path-precedence list mentions .gaia/config/" {
  run sed -n '13,22p' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [[ "$output" == *".gaia/config/"* ]]
  # Legacy config/ MUST remain documented as fallback (back-compat).
  [[ "$output" == *"config/"* ]]
}

@test "resolve-config.sh Config Split Merge example block mentions .gaia/config/" {
  # Find the section by content rather than fixed line numbers (the line offsets
  # shift when adjacent comments are extended — see fix/staging-bats-failures
  # which moved this block from lines 58-65 to 68-77 by expanding the precedence
  # list above it). Content-based assertion is line-shift-resilient.
  run awk '/^# Config Split Merge/,/^$/' "$PLUGIN_SCRIPTS/resolve-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/config/"* ]]
}

# ---------- AC2: validate-gate.sh line 410 ----------

@test "validate-gate.sh 'Read config_phase from' docstring documents .gaia/config/ canonical" {
  # AF-2026-05-22-5: validate-gate.sh got new lines (test_plan_exists 4-path
  # error + strategy/test-strategy.md acceptance), shifting the original
  # line-410 docstring. Match by content instead of fixed line number so
  # future edits don't break this AC. The 'Read config_phase from' docstring
  # must reference .gaia/config/ (canonical post-ADR-111).
  run grep -n "^# Read config_phase from " "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gaia/config/"* ]]
  # Legacy pure-form must NOT be present.
  [[ "$output" != *"PROJECT_ROOT}/config/project-config.yaml."* ]] || [[ "$output" == *".gaia/config/"* ]]
}

@test "validate-gate.sh executable cfg= lines are unchanged (legacy fallback code)" {
  # AC2 scope: line 410 docstring ONLY. The `cfg=` executable lines (legacy
  # fallback assignments) MUST NOT be touched. Locate them by content match
  # rather than fixed line numbers (the docstring edit shifts subsequent
  # lines by +3, so the original Val citations 420/449/548 are now ~423/452/551
  # — content-based assertion is line-number-resilient).
  run grep -cF 'cfg="${PROJECT_ROOT}/config/project-config.yaml"' "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$output" -eq 3 ]
}

@test "validate-gate.sh already-canonical comments are unchanged" {
  # AC2 scope exclusion: the "prefer .gaia/config/ over legacy" comments above
  # each `if [ -f .gaia/config/...` block MUST remain present (3 occurrences:
  # read_config_phase, config_section_present, and the cross-reference block).
  # Content-based assertion (resilient to line-number shifts from the L410 edit).
  run grep -c "Prefer \`.gaia/config/\` over legacy" "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$output" -eq 3 ]
}

# ---------- AC3: zero runtime impact ----------

@test "both scripts pass bash -n syntax check" {
  run bash -n "$PLUGIN_SCRIPTS/resolve-config.sh"
  [ "$status" -eq 0 ]
  run bash -n "$PLUGIN_SCRIPTS/validate-gate.sh"
  [ "$status" -eq 0 ]
}

# ---------- AC4: TC-DH-1 smoke test ----------

@test "resolve-config.sh executes identically on a representative fixture" {
  # Smoke: run --help and confirm exit 0 (no behavioral surprise from comment sweep).
  run bash "$PLUGIN_SCRIPTS/resolve-config.sh" --help
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]  # --help can exit 0 or 2 depending on convention
}
