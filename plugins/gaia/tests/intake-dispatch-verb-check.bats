#!/usr/bin/env bats
# intake-dispatch-verb-check.bats — E88-S2 intake-time enforcement
#
# Covers TC-DPD-7..9 (positive / negative / override) and TC-DPD-11
# (SSOT static audit — SKILL.md must reference the matcher library, never
# inline the taxonomy entries).
#
# The helper under test:
#   gaia-public/plugins/gaia/scripts/lib/intake-dispatch-verb-check.sh
#
# Invocation contract:
#   intake-dispatch-verb-check.sh --story-file <path>
#     - exit 0 when no dispatch-verb AC lacks integration-test pairing
#     - exit 1 (HALT) when a dispatch-verb AC has neither a sibling
#       integration-test AC nor a `<!-- gaia:contract-only: ... -->`
#       override; canonical stderr per AC1
#     - For each contract-only override, the helper writes a
#       `**Contract-only ACs:**` subsection into the story Dev Notes

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/intake-dispatch-verb-check.sh"
  export LIB_DIR HELPER
}

teardown() {
  common_teardown
}

_write_story() {
  # _write_story <path> <ac_blocks...>
  local path="$1"; shift
  cat > "$path" <<EOF
---
key: "E99-S1"
title: "test story"
---

## Acceptance Criteria

$*

## Dev Notes

Original notes.
EOF
}

# ---------------- TC-DPD-7 (positive) ----------------
@test "dispatch-verb AC + companion integration-test AC -> intake passes" {
  local story="$TEST_TMP/positive.md"
  _write_story "$story" \
$'**AC1.** When the orchestrator spawns the subagent...\n\n**AC2.** bats integration test exists at tests/foo.bats covering the spawn path.\n'
  run "$HELPER" --story-file "$story"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-8 (negative) ----------------
@test "dispatch-verb AC alone -> intake HALTs with canonical message" {
  local story="$TEST_TMP/negative.md"
  _write_story "$story" \
$'**AC1.** When the orchestrator spawns the subagent, then the envelope must round-trip.\n\n**AC2.** Unrelated AC about prose.\n'
  run "$HELPER" --story-file "$story"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dispatch-verb AC #1"* ]]
  [[ "$output" == *"lacks a companion integration-test AC"* ]]
}

# ---------------- TC-DPD-9 (override) ----------------
@test "contract-only override -> intake passes; reason recorded in Dev Notes" {
  local story="$TEST_TMP/override.md"
  _write_story "$story" \
$'**AC1.** When the orchestrator spawns the subagent. <!-- gaia:contract-only: dispatch is to test substrate only -->\n\n**AC2.** Unrelated AC.\n'
  run "$HELPER" --story-file "$story"
  [ "$status" -eq 0 ]
  grep -q '\*\*Contract-only ACs:\*\*' "$story"
  grep -q 'dispatch is to test substrate only' "$story"
}

# ---------------- TC-DPD-11 (SSOT static audit) ----------------
@test "SKILL.md files reference matcher library, not inline taxonomy" {
  local PLUGIN_DIR
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # gaia-create-story SKILL.md must reference the matcher library OR the
  # helper script that wraps it (intake-dispatch-verb-check.sh).
  local create_skill="$PLUGIN_DIR/skills/gaia-create-story/SKILL.md"
  [ -f "$create_skill" ]
  grep -qE 'dispatch-verb-match\.sh|intake-dispatch-verb-check\.sh' "$create_skill"

  # gaia-add-feature SKILL.md must reference the matcher or the helper.
  local add_feature_skill="$PLUGIN_DIR/skills/gaia-add-feature/SKILL.md"
  [ -f "$add_feature_skill" ]
  grep -qE 'dispatch-verb-match\.sh|intake-dispatch-verb-check\.sh' "$add_feature_skill"

  # Neither SKILL.md may reproduce the full dispatch-verb taxonomy list
  # (drift signal: 3+ distinct taxonomy entries appearing as bare tokens).
  # Use the E88-S1 SSOT audit threshold convention (>=3 entries = drift).
  for skill in "$create_skill" "$add_feature_skill"; do
    local distinct
    distinct="$(grep -wFf "$PLUGIN_DIR/knowledge/taxonomy/dispatch-verbs.txt" "$skill" 2>/dev/null \
      | grep -oE 'spawns|dispatches|invokes|wires|calls' \
      | sort -u | wc -l | tr -d ' ')"
    if [ "${distinct:-0}" -ge 3 ]; then
      printf 'TC-DPD-11: SKILL.md %s reproduces taxonomy entries (>=3 distinct): %s\n' \
        "$skill" "$distinct" >&2
      return 1
    fi
  done
}
