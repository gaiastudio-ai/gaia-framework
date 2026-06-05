#!/usr/bin/env bats
# dev-story-tdd-gate-wiring.bats — bats coverage for E57-S4
#
# Story: E57-S4 — SKILL.md gate wiring at Steps 5/6/7 (Red/Green/Refactor)
#
# Acceptance Criteria covered:
#   AC1 — SKIP branch: text-level assertion that each hook block dispatches
#         on `SKIP` by continuing without prompting.
#   AC2 — PROMPT branch: each hook contains an `AskUserQuestion` with the
#         exact verbatim labels `review-myself`, `route-to-qa`,
#         `proceed-anyway` (case-sensitive, hyphen-sensitive, in that order).
#   AC3 — QA_AUTO branch: each hook dispatches the `tdd-reviewer` subagent
#         (or shares dispatch payload with `route-to-qa`).
#   AC4 — `proceed-anyway` records a timestamped decision in the dev-story
#         checkpoint.
#   AC5 — Regression: removing the gate hook from any of Steps 5/6/7 causes
#         this test to FAIL naming the missing hook.
#
# Refs: FR-TDR-5, AF-2026-04-28-6, ADR-063, ADR-067, TC-TDR-01, TC-TDR-02,
#       TC-TDR-04, TC-DSS-09.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story" && pwd)/SKILL.md"
  export SKILL_MD
  [ -f "$SKILL_MD" ] || { echo "SKILL.md not found at $SKILL_MD" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC5 — Regression: each step's hook block MUST exist. Marker pairs identify
# the canonical insertion points; missing or unbalanced markers FAIL the test
# naming the missing hook.
# ---------------------------------------------------------------------------

@test "AC5: Step 5 (Red) tdd-review-gate hook block is present" {
  run grep -c '<!-- E57-S4: step5 tdd-review-gate begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- E57-S4: step5 tdd-review-gate end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "AC5: Step 6 (Green) tdd-review-gate hook block is present" {
  run grep -c '<!-- E57-S4: step6 tdd-review-gate begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- E57-S4: step6 tdd-review-gate end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "AC5: Step 7 (Refactor) tdd-review-gate hook block is present" {
  run grep -c '<!-- E57-S4: step7 tdd-review-gate begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- E57-S4: step7 tdd-review-gate end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Hook invocation — the gate script call MUST appear inside each block.
# ---------------------------------------------------------------------------

@test "AC5: each tdd-review-gate hook block invokes tdd-review-gate.sh" {
  # The script name must appear at least 3 times — once per hook block.
  run grep -c 'tdd-review-gate\.sh' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "AC5: Step 5 hook block passes phase=red to tdd-review-gate.sh" {
  # Extract the Step 5 hook block and verify it contains 'red' as the phase.
  block="$(awk '/<!-- E57-S4: step5 tdd-review-gate begin -->/,/<!-- E57-S4: step5 tdd-review-gate end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  echo "$block" | grep -Fq 'tdd-review-gate.sh'
  echo "$block" | grep -Eq '\bred\b'
}

@test "AC5: Step 6 hook block passes phase=green to tdd-review-gate.sh" {
  block="$(awk '/<!-- E57-S4: step6 tdd-review-gate begin -->/,/<!-- E57-S4: step6 tdd-review-gate end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  echo "$block" | grep -Fq 'tdd-review-gate.sh'
  echo "$block" | grep -Eq '\bgreen\b'
}

@test "AC5: Step 7 hook block passes phase=refactor to tdd-review-gate.sh" {
  block="$(awk '/<!-- E57-S4: step7 tdd-review-gate begin -->/,/<!-- E57-S4: step7 tdd-review-gate end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  echo "$block" | grep -Fq 'tdd-review-gate.sh'
  echo "$block" | grep -Eq '\brefactor\b'
}

# ---------------------------------------------------------------------------
# AC2 — Verbatim 3-option AskUserQuestion labels. Each hook block MUST
# contain all three labels exactly: `review-myself`, `route-to-qa`,
# `proceed-anyway` (case-sensitive, hyphen-sensitive).
# ---------------------------------------------------------------------------

assert_block_has_verbatim_labels() {
  local marker="$1"
  local block
  block="$(awk "/<!-- E57-S4: ${marker} tdd-review-gate begin -->/,/<!-- E57-S4: ${marker} tdd-review-gate end -->/" "$SKILL_MD")"
  [ -n "$block" ]
  echo "$block" | grep -Fq 'review-myself'
  echo "$block" | grep -Fq 'route-to-qa'
  echo "$block" | grep -Fq 'proceed-anyway'
}

@test "AC2: Step 5 hook contains verbatim labels review-myself, route-to-qa, proceed-anyway" {
  assert_block_has_verbatim_labels step5
}

@test "AC2: Step 6 hook contains verbatim labels review-myself, route-to-qa, proceed-anyway" {
  assert_block_has_verbatim_labels step6
}

@test "AC2: Step 7 hook contains verbatim labels review-myself, route-to-qa, proceed-anyway" {
  assert_block_has_verbatim_labels step7
}

@test "AC2: verbatim labels appear in canonical order review-myself, route-to-qa, proceed-anyway" {
  # In each block, the order MUST be review-myself first, then route-to-qa,
  # then proceed-anyway. Use byte offsets (grep -bo) so labels on the same
  # line still resolve a strict relative order.
  for marker in step5 step6 step7; do
    block="$(awk "/<!-- E57-S4: ${marker} tdd-review-gate begin -->/,/<!-- E57-S4: ${marker} tdd-review-gate end -->/" "$SKILL_MD")"
    rm_off="$(printf '%s\n' "$block" | grep -boF 'review-myself' | head -1 | cut -d: -f1)"
    rq_off="$(printf '%s\n' "$block" | grep -boF 'route-to-qa' | head -1 | cut -d: -f1)"
    pa_off="$(printf '%s\n' "$block" | grep -boF 'proceed-anyway' | head -1 | cut -d: -f1)"
    [ -n "$rm_off" ] && [ -n "$rq_off" ] && [ -n "$pa_off" ]
    [ "$rm_off" -lt "$rq_off" ]
    [ "$rq_off" -lt "$pa_off" ]
  done
}

# ---------------------------------------------------------------------------
# AC1 — SKIP branch dispatch must be documented in each hook (continues to
# the next step without prompting).
# ---------------------------------------------------------------------------

@test "AC1: each hook block documents the SKIP dispatch (no prompt)" {
  for marker in step5 step6 step7; do
    block="$(awk "/<!-- E57-S4: ${marker} tdd-review-gate begin -->/,/<!-- E57-S4: ${marker} tdd-review-gate end -->/" "$SKILL_MD")"
    [ -n "$block" ]
    echo "$block" | grep -Fq 'SKIP'
  done
}

# ---------------------------------------------------------------------------
# AC3 — QA_AUTO branch dispatches the tdd-reviewer subagent. Each hook block
# names QA_AUTO and the tdd-reviewer dispatch.
# ---------------------------------------------------------------------------

@test "AC3: each hook block dispatches QA_AUTO to the tdd-reviewer subagent" {
  for marker in step5 step6 step7; do
    block="$(awk "/<!-- E57-S4: ${marker} tdd-review-gate begin -->/,/<!-- E57-S4: ${marker} tdd-review-gate end -->/" "$SKILL_MD")"
    [ -n "$block" ]
    echo "$block" | grep -Fq 'QA_AUTO'
    # tdd-reviewer subagent name appears (Tex / tdd-reviewer / agents/tdd-reviewer.md).
    echo "$block" | grep -Eq 'tdd-reviewer'
  done
}

# ---------------------------------------------------------------------------
# AC4 — `proceed-anyway` records a timestamped decision in the checkpoint.
# ---------------------------------------------------------------------------

@test "AC4: each hook block documents proceed-anyway checkpoint persistence" {
  for marker in step5 step6 step7; do
    block="$(awk "/<!-- E57-S4: ${marker} tdd-review-gate begin -->/,/<!-- E57-S4: ${marker} tdd-review-gate end -->/" "$SKILL_MD")"
    [ -n "$block" ]
    # Block names checkpoint persistence and timestamp recording on
    # proceed-anyway. Accept either 'checkpoint' + 'timestamp' phrasing.
    echo "$block" | grep -Eqi 'checkpoint'
    echo "$block" | grep -Eqi 'timestamp|timestamped'
  done
}

# ---------------------------------------------------------------------------
# Hook ordering — each hook block must appear AFTER its corresponding step
# header. The Step N header precedes the matching marker in file order.
# ---------------------------------------------------------------------------

@test "Step 5 hook block follows Step 5 -- TDD Red Phase header" {
  step5_line="$(grep -n '^### Step 5 -- TDD Red Phase' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- E57-S4: step5 tdd-review-gate begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step5_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step5_line" ]
}

@test "Step 6 hook block follows Step 6 -- TDD Green Phase header" {
  step6_line="$(grep -n '^### Step 6 -- TDD Green Phase' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- E57-S4: step6 tdd-review-gate begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step6_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step6_line" ]
}

@test "Step 7 hook block follows Step 7 -- TDD Refactor Phase header" {
  step7_line="$(grep -n '^### Step 7 -- TDD Refactor Phase' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- E57-S4: step7 tdd-review-gate begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step7_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step7_line" ]
}

# ---------------------------------------------------------------------------
# Hook strict ordering relative to other gates in the same step block.
# ---------------------------------------------------------------------------

@test "Step 6 tdd-review-gate hook precedes Step 6b advisory hints" {
  hook_line="$(grep -n '<!-- E57-S4: step6 tdd-review-gate begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  step6b_line="$(grep -n '<!-- E55-S7: step 6b begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$hook_line" ] && [ -n "$step6b_line" ]
  [ "$hook_line" -lt "$step6b_line" ]
}

@test "Step 7 tdd-review-gate hook precedes Step 7b Val pass" {
  hook_line="$(grep -n '<!-- E57-S4: step7 tdd-review-gate begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  step7b_line="$(grep -n '<!-- E55-S4: step 7b begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$hook_line" ] && [ -n "$step7b_line" ]
  [ "$hook_line" -lt "$step7b_line" ]
}

# ---------------------------------------------------------------------------
# ADR cross-reference — ADR-063 verdict surfacing and ADR-067 hard-CRITICAL
# halt MUST be referenced in at least one hook block. Per Task 5,
# `route-to-qa` surfaces the verdict per ADR-063 and HALTs on CRITICAL per
# ADR-067.
# ---------------------------------------------------------------------------

@test "tdd-review-gate hook blocks reference ADR-063 verdict surfacing" {
  # ADR-063 governs verdict surfacing from the tdd-reviewer subagent.
  # The behavioral anchor is "Surface the verdict" — present in each block's
  # route-to-qa and QA_AUTO branches.
  hooks="$(awk '/<!-- E57-S4: step[567] tdd-review-gate begin -->/,/<!-- E57-S4: step[567] tdd-review-gate end -->/' "$SKILL_MD")"
  echo "$hooks" | grep -Fq 'Surface the verdict'
}

@test "tdd-review-gate hook blocks reference ADR-067 hard-CRITICAL halt" {
  # ADR-067 governs the hard-CRITICAL halt that YOLO MUST NOT auto-resolve.
  # The behavioral anchor is "YOLO MUST NOT auto-resolve CRITICAL findings" —
  # present in the step5 block and mirrored by "HALT on \`severity: CRITICAL\`"
  # throughout all three blocks.
  hooks="$(awk '/<!-- E57-S4: step[567] tdd-review-gate begin -->/,/<!-- E57-S4: step[567] tdd-review-gate end -->/' "$SKILL_MD")"
  echo "$hooks" | grep -Eq 'HALT on.*severity: CRITICAL|YOLO MUST NOT auto-resolve CRITICAL'
}
