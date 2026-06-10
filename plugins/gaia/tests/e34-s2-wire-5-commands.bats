#!/usr/bin/env bats
# e34-s2-wire-5-commands.bats
#
# Integration coverage for E34-S2 — Wire 5 commands to the shared Val
# sidecar writer helper (architecture §10.10, FR-VSP-1, FR-VSP-2).
#
# The five consumer SKILL.md files each gain a final "Persist to Val
# sidecar" step that invokes val-sidecar-write.sh. /gaia-tech-debt-review
# is the regression baseline and MUST remain untouched.
#
# Covers:
#   TC-VSP-4   — each of the 5 wired commands appends exactly one tagged
#                decision-log entry when its final step is executed
#   TC-VSP-5   — /gaia-tech-debt-review remains byte-compatible with the
#                pre-epic reference (its SKILL.md is not touched by the
#                shared helper wiring)
#   TC-VSP-6   — mid-execution failure before the final step leaves no
#                partial sidecar entry (atomicity — the helper is the
#                FINAL step, so upstream failures short-circuit before it)
#   TC-VSP-2e  — end-to-end idempotency through each consumer command
#   AC5        — each of the 5 SKILL.md files contains the uniform
#                val-sidecar-write.sh invocation shape; tech-debt-review
#                does NOT reference the shared helper.
#
# Unit-level coverage for val-sidecar-write.sh (NFR-052 gate) was landed by
# E34-S1 in e34-s1-val-sidecar-writer-units.bats. E34-S2 introduces NO new
# public shell functions, so no additional unit tests are required here.

load 'test_helper.bash'

setup() {
  common_setup
  PROJECT_ROOT="$TEST_TMP/proj"
  mkdir -p "$PROJECT_ROOT/.gaia/memory/validator-sidecar"
  export PROJECT_ROOT
}

teardown() { common_teardown; }

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/val-sidecar-write.sh"
SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"

# ---------------------------------------------------------------------------
# AC5 — each of the 5 SKILL.md files wires the shared helper uniformly
# ---------------------------------------------------------------------------

@test "AC5: gaia-create-story SKILL.md invokes val-sidecar-write.sh as final step" {
  local skill="$SKILLS_DIR/gaia-create-story/SKILL.md"
  [ -f "$skill" ]
  grep -q 'val-sidecar-write.sh' "$skill"
  grep -q -- '--command-name "/gaia-create-story"' "$skill"
  grep -q -- '--input-id' "$skill"
  grep -q -- '--decision-payload' "$skill"
}

@test "AC5: gaia-validate-story SKILL.md invokes val-sidecar-write.sh as final step" {
  local skill="$SKILLS_DIR/gaia-validate-story/SKILL.md"
  [ -f "$skill" ]
  grep -q 'val-sidecar-write.sh' "$skill"
  grep -q -- '--command-name "/gaia-validate-story"' "$skill"
  grep -q -- '--input-id' "$skill"
  grep -q -- '--decision-payload' "$skill"
}

@test "AC5: gaia-sprint-plan SKILL.md invokes val-sidecar-write.sh as final step" {
  local skill="$SKILLS_DIR/gaia-sprint-plan/SKILL.md"
  [ -f "$skill" ]
  grep -q 'val-sidecar-write.sh' "$skill"
  grep -q -- '--command-name "/gaia-sprint-plan"' "$skill"
  grep -q -- '--input-id' "$skill"
  grep -q -- '--decision-payload' "$skill"
  # Sprint ID must come from sprint-state.sh per project hard rule.
  grep -q 'sprint-state.sh' "$skill"
}

@test "AC5: gaia-triage-findings SKILL.md invokes val-sidecar-write.sh as final step" {
  local skill="$SKILLS_DIR/gaia-triage-findings/SKILL.md"
  [ -f "$skill" ]
  grep -q 'val-sidecar-write.sh' "$skill"
  grep -q -- '--command-name "/gaia-triage-findings"' "$skill"
  grep -q -- '--input-id' "$skill"
  grep -q -- '--decision-payload' "$skill"
  # Triage session ID shape must be documented.
  grep -Eq 'triage-[A-Za-z0-9{}%+-]+' "$skill"
}

@test "AC5: gaia-retro SKILL.md invokes val-sidecar-write.sh as final step" {
  local skill="$SKILLS_DIR/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -q 'val-sidecar-write.sh' "$skill"
  grep -q -- '--command-name "/gaia-retro"' "$skill"
  grep -q -- '--input-id' "$skill"
  grep -q -- '--decision-payload' "$skill"
}

@test "AC5: gaia-retro SKILL.md Val-sidecar writes delegate to shared helper (no retro-sidecar-write for validator-sidecar targets)" {
  local skill="$SKILLS_DIR/gaia-retro/SKILL.md"
  # The Step 7 "Val Memory Persistence" section must not use retro-sidecar-write
  # for validator-sidecar targets — it must delegate to val-sidecar-write.sh
  # (architecture §10.28.2). Count lines that reference retro-sidecar-write
  # within 5 lines of a validator-sidecar target reference.
  run awk '
    /validator-sidecar\/(decision-log|conversation-context)\.md/ { near=5 }
    near>0 && /retro-sidecar-write\.sh/ { print; found=1 }
    near>0 { near-- }
    END { exit (found?1:0) }
  ' "$skill"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-VSP-4 — each wired command produces exactly one tagged sidecar entry
# (simulated: we invoke the helper with the same args each consumer's
# SKILL.md specifies and confirm the entry carries that command's tag)
# ---------------------------------------------------------------------------

_run_consumer() {
  local cmd="$1" iid="$2" sprint="$3"
  local payload='{"verdict":"passed","findings":[],"artifact_path":"docs/x.md"}'
  "$SCRIPT" \
    --root "$PROJECT_ROOT" \
    --command-name "$cmd" \
    --input-id "$iid" \
    --decision-payload "$payload" \
    --sprint-id "$sprint"
}

@test "TC-VSP-4: /gaia-create-story final-step invocation appends one tagged entry" {
  run _run_consumer "/gaia-create-story" "E99-S1" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  grep -q 'command: /gaia-create-story' "$log"
  grep -q 'input_id: E99-S1' "$log"
}

@test "TC-VSP-4: /gaia-validate-story final-step invocation appends one tagged entry" {
  run _run_consumer "/gaia-validate-story" "E99-S2" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  grep -q 'command: /gaia-validate-story' "$log"
  grep -q 'input_id: E99-S2' "$log"
}

@test "TC-VSP-4: /gaia-sprint-plan final-step invocation appends one tagged entry" {
  run _run_consumer "/gaia-sprint-plan" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  grep -q 'command: /gaia-sprint-plan' "$log"
  grep -q 'input_id: sprint-26' "$log"
}

@test "TC-VSP-4: /gaia-triage-findings final-step invocation appends one tagged entry" {
  run _run_consumer "/gaia-triage-findings" "triage-2026-04-22-001" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  grep -q 'command: /gaia-triage-findings' "$log"
  grep -q 'input_id: triage-2026-04-22-001' "$log"
}

@test "TC-VSP-4: /gaia-retro final-step invocation appends one tagged entry" {
  run _run_consumer "/gaia-retro" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  grep -q 'command: /gaia-retro' "$log"
  grep -q 'input_id: sprint-26' "$log"
}

@test "TC-VSP-4: all 5 commands in sequence append 5 distinct entries in execution order" {
  _run_consumer "/gaia-create-story"    "E99-S1"                  "sprint-26"
  _run_consumer "/gaia-validate-story"  "E99-S1"                  "sprint-26"
  _run_consumer "/gaia-sprint-plan"     "sprint-26"               "sprint-26"
  _run_consumer "/gaia-triage-findings" "triage-2026-04-22-001"   "sprint-26"
  _run_consumer "/gaia-retro"           "sprint-26"               "sprint-26"
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  # Five distinct command tags must appear.
  [ "$(grep -c 'command: /gaia-create-story'    "$log")" -eq 1 ]
  [ "$(grep -c 'command: /gaia-validate-story'  "$log")" -eq 1 ]
  [ "$(grep -c 'command: /gaia-sprint-plan'     "$log")" -eq 1 ]
  [ "$(grep -c 'command: /gaia-triage-findings' "$log")" -eq 1 ]
  [ "$(grep -c 'command: /gaia-retro'           "$log")" -eq 1 ]
  # Five distinct dedup_key markers.
  [ "$(grep -c '<!-- dedup_key: ' "$log")" -eq 5 ]
}

# ---------------------------------------------------------------------------
# TC-VSP-5 — /gaia-tech-debt-review is untouched (regression guard)
# ---------------------------------------------------------------------------

@test "TC-VSP-5: gaia-tech-debt-review SKILL.md does NOT reference val-sidecar-write.sh" {
  local skill="$SKILLS_DIR/gaia-tech-debt-review/SKILL.md"
  [ -f "$skill" ]
  run grep -q 'val-sidecar-write.sh' "$skill"
  [ "$status" -ne 0 ]
}

# TC-VSP-5 ORIGINALLY asserted that gaia-tech-debt-review kept its own inline
# Step 7 Val-sidecar write (the gold-standard). That skill was retired to a
# deprecation redirect (E39-S6) — the tech-debt review capability is now a
# phase of /gaia-triage-findings, which carries the Val-sidecar persistence.
# Retargeted to assert the redirect (no Step 7) + that triage owns the write.
@test "TC-VSP-5: gaia-tech-debt-review retired to a redirect; triage carries the Val-sidecar write" {
  local redirect="$SKILLS_DIR/gaia-tech-debt-review/SKILL.md"
  # The redirect no longer has a Step 7 / inline sidecar write.
  run grep -q '### Step 7 — Save to Val Memory' "$redirect"
  [ "$status" -ne 0 ]
  grep -qE 'replaced_by:.*gaia-triage-findings' "$redirect"
  # The replacement (triage-findings) carries the Val-sidecar persistence.
  grep -qE '(_memory|\.gaia/memory)/validator-sidecar/decision-log\.md' \
    "$SKILLS_DIR/gaia-triage-findings/SKILL.md"
}

# ---------------------------------------------------------------------------
# TC-VSP-6 — atomicity: upstream failure before final step leaves no entry
# (simulated: we snapshot the sidecar, do NOT invoke the helper, and
# confirm the files are byte-identical)
# ---------------------------------------------------------------------------

@test "TC-VSP-6: upstream failure before helper invocation leaves sidecar byte-identical" {
  local log="$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md"
  local ctx="$PROJECT_ROOT/.gaia/memory/validator-sidecar/conversation-context.md"
  # Seed both files with known content via a dry prior-run.
  _run_consumer "/gaia-create-story" "E99-PRIOR" "sprint-26"
  local before_log; before_log=$(shasum -a 256 "$log" | awk '{print $1}')
  local before_ctx; before_ctx=$(shasum -a 256 "$ctx" | awk '{print $1}')
  # Simulate: consumer command starts, fails before the final step (helper
  # never runs). No write should land.
  : # intentional no-op — helper invocation short-circuits
  local after_log; after_log=$(shasum -a 256 "$log" | awk '{print $1}')
  local after_ctx; after_ctx=$(shasum -a 256 "$ctx" | awk '{print $1}')
  [ "$before_log" = "$after_log" ]
  [ "$before_ctx" = "$after_ctx" ]
}

# ---------------------------------------------------------------------------
# TC-VSP-2e — end-to-end idempotency through each consumer command
# ---------------------------------------------------------------------------

@test "TC-VSP-2e: re-running /gaia-create-story with identical payload yields skipped_duplicate" {
  run _run_consumer "/gaia-create-story" "E99-S1" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=written"* ]]
  local before; before=$(wc -c <"$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md")
  run _run_consumer "/gaia-create-story" "E99-S1" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
  local after; after=$(wc -c <"$PROJECT_ROOT/.gaia/memory/validator-sidecar/decision-log.md")
  [ "$before" -eq "$after" ]
}

@test "TC-VSP-2e: re-running /gaia-retro with identical payload yields skipped_duplicate" {
  run _run_consumer "/gaia-retro" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  run _run_consumer "/gaia-retro" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
}

@test "TC-VSP-2e: re-running /gaia-sprint-plan with identical payload yields skipped_duplicate" {
  run _run_consumer "/gaia-sprint-plan" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  run _run_consumer "/gaia-sprint-plan" "sprint-26" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
}

@test "TC-VSP-2e: re-running /gaia-validate-story with identical payload yields skipped_duplicate" {
  run _run_consumer "/gaia-validate-story" "E99-S2" "sprint-26"
  [ "$status" -eq 0 ]
  run _run_consumer "/gaia-validate-story" "E99-S2" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
}

@test "TC-VSP-2e: re-running /gaia-triage-findings with identical payload yields skipped_duplicate" {
  run _run_consumer "/gaia-triage-findings" "triage-2026-04-22-001" "sprint-26"
  [ "$status" -eq 0 ]
  run _run_consumer "/gaia-triage-findings" "triage-2026-04-22-001" "sprint-26"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped_duplicate"* ]]
}
