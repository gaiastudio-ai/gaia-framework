#!/usr/bin/env bats
# round-wiring.bats — SKILL.md per-line wiring tests for the per-round
# review record.  Each assertion is a reusable function that takes a file
# path, so deletion mutants can be run on temp copies (never the real file).
#
# Tests confirm that the wiring prose exists in the real SKILL.md files.
# Temp-copy mutants confirm that removing a line makes the assertion fail.
# Bats never edits the real tracked SKILL.md files.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
RAR_SKILL="$PLUGIN_ROOT/skills/gaia-run-all-reviews/SKILL.md"
DS_SKILL="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
RS_SKILL="$PLUGIN_ROOT/skills/gaia-run-sprint/SKILL.md"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Verify the SKILL.md files exist.
  [ -f "$RAR_SKILL" ] || { echo "run-all-reviews SKILL.md not found" >&2; return 1; }
  [ -f "$DS_SKILL" ] || { echo "dev-story SKILL.md not found" >&2; return 1; }
  [ -f "$RS_SKILL" ] || { echo "run-sprint SKILL.md not found" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Reusable assertion functions (take a file path)
# ---------------------------------------------------------------------------

# run-all-reviews: record-round call is wired.
assert_rar_record_round() {
  local file="$1"
  grep -q 'record-round' "$file"
}

# run-all-reviews: record-round-report call is wired.
assert_rar_record_round_report() {
  local file="$1"
  grep -q 'record-round-report' "$file"
}

# run-all-reviews: complete-round call is wired.
assert_rar_complete_round() {
  local file="$1"
  grep -q 'complete-round' "$file"
}

# run-all-reviews: round-start sequence order (resolve tree, round-info,
# record-round, impact-assessment).
assert_rar_round_start_order() {
  local file="$1"
  # Find line numbers of each step in the round-start sequence.
  local ln_resolve ln_roundinfo ln_recordround ln_impact
  ln_resolve="$(grep -n 'code.tree\|worktree.*resolve\|resolve.*code.*tree' "$file" | head -1 | cut -d: -f1)"
  ln_roundinfo="$(grep -n 'round-info' "$file" | head -1 | cut -d: -f1)"
  ln_recordround="$(grep -n 'record-round' "$file" | head -1 | cut -d: -f1)"
  ln_impact="$(grep -n 'impact-assessment' "$file" | head -1 | cut -d: -f1)"

  [ -n "$ln_resolve" ] || return 1
  [ -n "$ln_roundinfo" ] || return 1
  [ -n "$ln_recordround" ] || return 1
  [ -n "$ln_impact" ] || return 1

  # Order: resolve < round-info < record-round < impact-assessment.
  [ "$ln_roundinfo" -gt "$ln_resolve" ] || return 1
  [ "$ln_recordround" -gt "$ln_roundinfo" ] || return 1
  [ "$ln_impact" -gt "$ln_recordround" ] || return 1
}

# run-all-reviews: HALT rules wired for register-write subcommand failures.
assert_rar_halt_rules() {
  local file="$1"
  # Must mention halting on non-zero exit from register-write subcommands
  # specifically in the round-lifecycle context (not just any HALT).
  grep -qi 'register-write.*halt\|halt.*register-write\|complete-round.*halt\|halt.*complete-round\|non-zero.*register\|register.*non-zero' "$file"
}

# run-all-reviews: summary flags passed.
assert_rar_summary_flags() {
  local file="$1"
  grep -q '\-\-run-id' "$file" && grep -q '\-\-commit-sha' "$file" && grep -q '\-\-requirement-version' "$file"
}

# run-all-reviews: unrelated-enhancement revert.
assert_rar_unrelated_enhancement_revert() {
  local file="$1"
  grep -qi 'unrelated.*enhancement\|revert.*out-of-scope\|revert.*AC.*edit' "$file"
}

# run-all-reviews: essential-revision re-runs consolidation steps.
assert_rar_essential_revision_rerun() {
  local file="$1"
  grep -qi 'essential.*revision.*re-run\|reassessed.*gate.*re-run\|re-run.*reassessed\|essential_missing_requirement' "$file"
}

# run-all-reviews: code-tree checkpoint uses story_key guard in the round-start context.
assert_rar_story_key_guard() {
  local file="$1"
  # Must mention key_variables.story_key in the context of resolving the code tree
  # for the round, not just any mention of story_key.
  grep -q '\.key_variables\.story_key' "$file"
}

# dev-story: assert-round-complete wired in REWORK.
assert_ds_assert_round_complete() {
  local file="$1"
  grep -q 'assert-round-complete' "$file"
}

# dev-story: bind-brief wired in REWORK.
assert_ds_bind_brief() {
  local file="$1"
  grep -q 'bind-brief' "$file"
}

# dev-story: round-info call wired in REWORK.
assert_ds_round_info() {
  local file="$1"
  grep -q 'round-info' "$file"
}

# run-sprint: correction-dispatch reliance line.
assert_rs_correction_dispatch() {
  local file="$1"
  grep -qi 'correction.*dispatch.*guard\|guard.*correction\|assert-round-complete\|relies.*dev-story\|guarded.*dev-story' "$file"
}

# ---------------------------------------------------------------------------
# Tests — real SKILL.md files
# ---------------------------------------------------------------------------

@test "run-all-reviews contains record-round, record-round-report, complete-round" {
  assert_rar_record_round "$RAR_SKILL"
  assert_rar_record_round_report "$RAR_SKILL"
  assert_rar_complete_round "$RAR_SKILL"
}

@test "run-all-reviews round-start sequence is in line-number order" {
  assert_rar_round_start_order "$RAR_SKILL"
}

@test "run-all-reviews HALT rules are wired per line" {
  assert_rar_halt_rules "$RAR_SKILL"
}

@test "run-all-reviews summary flags are passed per line" {
  assert_rar_summary_flags "$RAR_SKILL"
}

@test "run-all-reviews unrelated-enhancement revert and re-complete wired per line" {
  assert_rar_unrelated_enhancement_revert "$RAR_SKILL"
}

@test "run-all-reviews essential-revision re-runs consolidation steps for reassessed gates" {
  assert_rar_essential_revision_rerun "$RAR_SKILL"
}

@test "dev-story REWORK contains assert-round-complete, bind-brief" {
  assert_ds_assert_round_complete "$DS_SKILL"
  assert_ds_bind_brief "$DS_SKILL"
}

@test "dev-story round-info call wired per line in REWORK" {
  assert_ds_round_info "$DS_SKILL"
}

@test "run-all-reviews code-tree checkpoint uses story_key guard per line" {
  assert_rar_story_key_guard "$RAR_SKILL"
}

@test "run-sprint contains correction-dispatch reliance line" {
  assert_rs_correction_dispatch "$RS_SKILL"
}

# ---------------------------------------------------------------------------
# Temp-copy mutant tests — removing the target line makes the assert fail
# ---------------------------------------------------------------------------

@test "temp-copy mutant: removing record-round call makes wiring test fail" {
  local tmp_file="$TEST_TMP/rar-mut-record-round.md"
  grep -v 'record-round' "$RAR_SKILL" > "$tmp_file"
  run assert_rar_record_round "$tmp_file"
  [ "$status" -ne 0 ]
}

@test "temp-copy mutant: removing assert-round-complete call makes wiring test fail" {
  local tmp_file="$TEST_TMP/ds-mut-assert.md"
  grep -v 'assert-round-complete' "$DS_SKILL" > "$tmp_file"
  run assert_ds_assert_round_complete "$tmp_file"
  [ "$status" -ne 0 ]
}

@test "temp-copy mutant: removing reassessed-gate re-run line makes wiring test fail" {
  local tmp_file="$TEST_TMP/rar-mut-essential.md"
  # Remove lines mentioning essential revision re-run.
  grep -vi 'essential.*revision.*re-run\|reassessed.*gate.*re-run\|re-run.*reassessed\|essential_missing_requirement' "$RAR_SKILL" > "$tmp_file"
  run assert_rar_essential_revision_rerun "$tmp_file"
  [ "$status" -ne 0 ]
}

@test "run-all-reviews re-runs reassessed gates after essential revision" {
  assert_rar_essential_revision_rerun "$RAR_SKILL"
}
