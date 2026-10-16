#!/usr/bin/env bats
# round-wiring.bats — SKILL.md per-line wiring tests for the per-round
# review record.  Each assertion is anchored to its exact step line
# (scoped to the step's span), so a single-line deletion mutant is
# killed.  Bats never edits the real tracked SKILL.md files.

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

  [ -f "$RAR_SKILL" ] || { echo "run-all-reviews SKILL.md not found" >&2; return 1; }
  [ -f "$DS_SKILL" ] || { echo "dev-story SKILL.md not found" >&2; return 1; }
  [ -f "$RS_SKILL" ] || { echo "run-sprint SKILL.md not found" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Helpers: extract a step span from a SKILL.md
# ---------------------------------------------------------------------------

# _extract_span <file> <start_re> <end_re>
# Prints lines from the first match of start_re up to (excluding) end_re.
_extract_span() {
  local file="$1" start_re="$2" end_re="$3"
  awk -v s="$start_re" -v e="$end_re" '
    $0 ~ s { in_span = 1 }
    in_span && $0 ~ e && NR > 1 { exit }
    in_span { print }
  ' "$file"
}

# The round-start substep span: from "Substep 2.2b" to "Substep 2.3".
_rar_round_start_span() {
  _extract_span "$1" 'Substep 2\.2b' 'Substep 2\.3[^b]'
}

# The consolidation + completion span: "Substep 2.4b" to "After Substeps 2".
_rar_completion_span() {
  _extract_span "$1" 'Substep 2\.4b' '^After Substeps 2'
}

# The deterministic-helpers span: "After Substeps 2" through "Step 4".
_rar_helpers_span() {
  _extract_span "$1" '^After Substeps 2' '### Step 4'
}

# The dev-story REWORK span: "Step 3c" to "Step 4".
_ds_rework_span() {
  _extract_span "$1" 'Step 3c.*REWORK' '### Step 4'
}

# ---------------------------------------------------------------------------
# Anchored assertions: run-all-reviews round-start substep
# ---------------------------------------------------------------------------

# The step-3 heading that is the record-round call instruction.
# Precise pattern: starts with "3." and names record-round.
assert_rar_roundstart_record_round() {
  _rar_round_start_span "$1" | grep -q '^3\..*`record-round`'
}

# The step-2 heading that is the round-info call.
assert_rar_roundstart_round_info() {
  _rar_round_start_span "$1" | grep -q '^2\..*`round-info`'
}

assert_rar_roundstart_impact_assessment() {
  _rar_round_start_span "$1" | grep -q 'call.*`impact-assessment`\|impact-assessment.*--story'
}

assert_rar_roundstart_code_tree() {
  _rar_round_start_span "$1" | grep -q '^1\..*Resolve.*code tree'
}

assert_rar_roundstart_halt_exception() {
  # The HALT-exception line: round-info exit 1 at round start.
  _rar_round_start_span "$1" | grep -q '^HALT.*except.*round-info.*exit 1'
}

assert_rar_roundstart_order() {
  local span
  span="$(_rar_round_start_span "$1")"
  local ln_tree ln_roundinfo ln_record ln_impact
  ln_tree="$(printf '%s\n' "$span" | grep -n '^1\..*Resolve.*code tree' | head -1 | cut -d: -f1)"
  ln_roundinfo="$(printf '%s\n' "$span" | grep -n '^2\..*`round-info`' | head -1 | cut -d: -f1)"
  ln_record="$(printf '%s\n' "$span" | grep -n '^3\..*`record-round`' | head -1 | cut -d: -f1)"
  ln_impact="$(printf '%s\n' "$span" | grep -n 'impact-assessment' | head -1 | cut -d: -f1)"
  [ -n "$ln_tree" ] && [ -n "$ln_roundinfo" ] && [ -n "$ln_record" ] && [ -n "$ln_impact" ] || return 1
  [ "$ln_roundinfo" -gt "$ln_tree" ] || return 1
  [ "$ln_record" -gt "$ln_roundinfo" ] || return 1
  [ "$ln_impact" -gt "$ln_record" ] || return 1
}

assert_rar_roundstart_story_key_guard() {
  _rar_round_start_span "$1" | grep -q '\.key_variables\.story_key'
}

# ---------------------------------------------------------------------------
# Anchored assertions: run-all-reviews consolidation + completion
# ---------------------------------------------------------------------------

# The step-2 heading in the completion span: "Call `complete-round`".
assert_rar_completion_complete_round() {
  _rar_completion_span "$1" | grep -q '^2\..*`complete-round`'
}

assert_rar_completion_halt() {
  _rar_completion_span "$1" | grep -qi '^   HALT.*non-zero'
}

assert_rar_completion_scope_revision() {
  _rar_completion_span "$1" | grep -q 'record-scope-revision'
}

assert_rar_completion_essential_rerun() {
  _rar_completion_span "$1" | grep -qi 're-run.*consolidation\|re-run.*reassessed\|reassessed.*re-run'
}

assert_rar_completion_unrelated_revert() {
  _rar_completion_span "$1" | grep -qi 'unrelated.*enhancement'
}

# Order: complete-round comes after consolidation and before the
# summary writer, review-gate-check and the nudge.
assert_rar_complete_before_helpers() {
  local file="$1"
  local ln_complete ln_summary ln_gatecheck ln_nudge
  ln_complete="$(grep -n '`complete-round`.*this runs after consolidation' "$file" | head -1 | cut -d: -f1)"
  ln_summary="$(grep -n 'review-summary-gen.sh --story' "$file" | head -1 | cut -d: -f1)"
  ln_gatecheck="$(grep -n 'review-gate.sh review-gate-check --story' "$file" | head -1 | cut -d: -f1)"
  ln_nudge="$(grep -n 'review-nudge.sh --story' "$file" | head -1 | cut -d: -f1)"
  [ -n "$ln_complete" ] && [ -n "$ln_summary" ] && [ -n "$ln_gatecheck" ] && [ -n "$ln_nudge" ] || return 1
  [ "$ln_complete" -lt "$ln_summary" ] || return 1
  [ "$ln_complete" -lt "$ln_gatecheck" ] || return 1
  [ "$ln_complete" -lt "$ln_nudge" ] || return 1
}

# The summary, gate-check and nudge are named in the deterministic-helpers span.
assert_rar_helpers_named() {
  local span
  span="$(_rar_helpers_span "$1")"
  grep -q 'review-summary-gen' <<<"$span" || return 1
  grep -q 'review-gate-check' <<<"$span" || return 1
  grep -q 'review-nudge' <<<"$span" || return 1
}

# Summary flags in the helpers span.
assert_rar_summary_flags() {
  local span
  span="$(_rar_helpers_span "$1")"
  grep -q '\-\-run-id' <<<"$span" || return 1
  grep -q '\-\-commit-sha' <<<"$span" || return 1
  grep -q '\-\-requirement-version' <<<"$span" || return 1
}

# record-round-report in the dispatch substep.
assert_rar_record_round_report() {
  _extract_span "$1" 'Substep 2\.3 ' 'Substep 2\.3b' | grep -q 'record-round-report'
}

# ---------------------------------------------------------------------------
# Anchored assertions: dev-story REWORK step
# ---------------------------------------------------------------------------

assert_ds_rework_round_info() {
  _ds_rework_span "$1" | grep -q 'round-info --story'
}

# Step 4 invocation: "Call `register-write.sh assert-round-complete"
assert_ds_rework_assert_round_complete() {
  _ds_rework_span "$1" | grep -q '^4\..*assert-round-complete'
}

# Step 3 binding/superseding instruction.
assert_ds_rework_bind_brief() {
  _ds_rework_span "$1" | grep -q '^3\..*bind-brief\|call.*`.*bind-brief'
}

assert_ds_rework_supersede_brief() {
  _ds_rework_span "$1" | grep -q 'supersede-brief.*rationale'
}

# Three brief branches within step 3.
assert_ds_rework_brief_none_branch() {
  _ds_rework_span "$1" | grep -qi 'brief_path none.*bind-brief\|brief_path.*none.*bind'
}

assert_ds_rework_brief_same_hash_branch() {
  _ds_rework_span "$1" | grep -qi 'SHA-256 equals.*brief_sha256\|equals.*brief_sha256.*no-op\|idempotent no-op'
}

assert_ds_rework_brief_changed_branch() {
  _ds_rework_span "$1" | grep -qi 'Otherwise.*supersede-brief'
}

# HALT on assert-round-complete non-zero, specifically from step 4.
assert_ds_rework_halt_rule() {
  _ds_rework_span "$1" | grep -qi '^4\..*HALT.*non-zero'
}

# round-info exit 1 exception: legacy story.
assert_ds_rework_roundinfo_exit1_exception() {
  _ds_rework_span "$1" | grep -qi '^1\..*Exit 1.*no orchestrated round'
}

# ---------------------------------------------------------------------------
# Anchored assertion: run-sprint correction dispatch
# ---------------------------------------------------------------------------

assert_rs_correction_dispatch() {
  local file="$1"
  grep -qi 'correction.*dispatch.*guard\|guard.*correction\|assert-round-complete\|relies.*dev-story\|guarded.*dev-story' "$file"
}

# ===========================================================================
# Tests — real SKILL.md files
# ===========================================================================

@test "run-all-reviews round-start: record-round, round-info, impact, code-tree, order, exception" {
  assert_rar_roundstart_record_round "$RAR_SKILL"
  assert_rar_roundstart_round_info "$RAR_SKILL"
  assert_rar_roundstart_impact_assessment "$RAR_SKILL"
  assert_rar_roundstart_code_tree "$RAR_SKILL"
  assert_rar_roundstart_order "$RAR_SKILL"
  assert_rar_roundstart_story_key_guard "$RAR_SKILL"
  assert_rar_roundstart_halt_exception "$RAR_SKILL"
}

@test "run-all-reviews completion: complete-round, halt, scope-revision, essential rerun, unrelated revert" {
  assert_rar_completion_complete_round "$RAR_SKILL"
  assert_rar_completion_halt "$RAR_SKILL"
  assert_rar_completion_scope_revision "$RAR_SKILL"
  assert_rar_completion_essential_rerun "$RAR_SKILL"
  assert_rar_completion_unrelated_revert "$RAR_SKILL"
}

@test "run-all-reviews order: complete-round before summary, gate-check, nudge" {
  assert_rar_complete_before_helpers "$RAR_SKILL"
}

@test "run-all-reviews helpers span names summary, review-gate-check, review-nudge" {
  assert_rar_helpers_named "$RAR_SKILL"
}

@test "run-all-reviews summary flags in helpers span" {
  assert_rar_summary_flags "$RAR_SKILL"
}

@test "run-all-reviews record-round-report in dispatch substep" {
  assert_rar_record_round_report "$RAR_SKILL"
}

@test "dev-story REWORK: round-info, assert-round-complete, bind, supersede, brief branches, halt, exit-1 exception" {
  assert_ds_rework_round_info "$DS_SKILL"
  assert_ds_rework_assert_round_complete "$DS_SKILL"
  assert_ds_rework_bind_brief "$DS_SKILL"
  assert_ds_rework_supersede_brief "$DS_SKILL"
  assert_ds_rework_brief_none_branch "$DS_SKILL"
  assert_ds_rework_brief_same_hash_branch "$DS_SKILL"
  assert_ds_rework_brief_changed_branch "$DS_SKILL"
  assert_ds_rework_halt_rule "$DS_SKILL"
  assert_ds_rework_roundinfo_exit1_exception "$DS_SKILL"
}

@test "run-sprint correction-dispatch reliance" {
  assert_rs_correction_dispatch "$RS_SKILL"
}

# ===========================================================================
# Temp-copy mutant tests — delete ONLY the target line
# ===========================================================================

# Helper: delete a single line matching a pattern from a file.
# Usage: _delete_one_line <pattern> <input_file> <output_file>
_delete_one_line() {
  local pat="$1" infile="$2" outfile="$3"
  local ln
  ln="$(grep -n "$pat" "$infile" | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || { cp "$infile" "$outfile"; return 1; }
  awk -v target="$ln" 'NR != target' "$infile" > "$outfile"
}

@test "mutant: deleting record-round step-3 heading kills roundstart test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line '^3\..*\`record-round\`' "$RAR_SKILL" "$tmp"
  run assert_rar_roundstart_record_round "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting round-info step-2 heading kills roundstart test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line '^2\..*\`round-info\`.*discover' "$RAR_SKILL" "$tmp"
  run assert_rar_roundstart_round_info "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting impact-assessment line kills roundstart test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line 'call.*impact-assessment\|impact-assessment.*--story' "$RAR_SKILL" "$tmp"
  run assert_rar_roundstart_impact_assessment "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting complete-round step-2 heading kills completion test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line '^2\..*\`complete-round\`' "$RAR_SKILL" "$tmp"
  run assert_rar_completion_complete_round "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting step-4 assert-round-complete in dev-story kills rework test" {
  local tmp="$TEST_TMP/ds-mut.md"
  _delete_one_line '^4\..*assert-round-complete' "$DS_SKILL" "$tmp"
  run assert_ds_rework_assert_round_complete "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting step-3 bind-brief in dev-story kills rework test" {
  local tmp="$TEST_TMP/ds-mut.md"
  _delete_one_line '^3\..*bind-brief\|Bind or supersede' "$DS_SKILL" "$tmp"
  run assert_ds_rework_bind_brief "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting supersede-brief line in dev-story kills rework test" {
  local tmp="$TEST_TMP/ds-mut.md"
  _delete_one_line 'supersede-brief.*rationale' "$DS_SKILL" "$tmp"
  run assert_ds_rework_supersede_brief "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting HALT-on-non-zero line kills completion halt test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line '   HALT on any non-zero' "$RAR_SKILL" "$tmp"
  run assert_rar_completion_halt "$tmp"
  [ "$status" -ne 0 ]
}

@test "mutant: deleting round-info exit 1 exception kills exception test" {
  local tmp="$TEST_TMP/rar-mut.md"
  _delete_one_line '^HALT.*except.*round-info.*exit 1' "$RAR_SKILL" "$tmp"
  run assert_rar_roundstart_halt_exception "$tmp"
  [ "$status" -ne 0 ]
}
