#!/usr/bin/env bats
# yield-gate.bats — gaia-meeting yield-gate helper post-AF-2026-05-10-1
#
# History:
#   E76-S9 / AF-2026-05-08-4 — yield-gate.sh emitted a canonical 3-line stdout
#     block (phase marker + prompt + turn-terminal stdout sentinel). This file
#     used to assert that emission contract (TC-MTG-YGATE-1, TC-MTG-YGATE-2).
#   E76-S18 / AF-2026-05-10-1 — the stdout-sentinel emission was empirically
#     defeated by harness Auto Mode on 2026-05-09 (memory rule
#     `feedback_askuserquestion_under_automode.md`). The substrate-correct
#     primitive is `AskUserQuestion` which halts the LLM turn at the harness
#     layer. yield-gate.sh now produces ZERO stdout output and only writes
#     the session-state side effects (`last_checkpoint_phase` and
#     `last_yield_emitted_at`). The substrate `AskUserQuestion` tool call is
#     emitted by the LLM in the enclosing /gaia-meeting orchestration AFTER
#     yield-gate.sh returns (see SKILL.md §Procedure §Substrate-enforced
#     turn-terminal yield contract).
#
# This test file holds the post-AF-2026-05-10-1 contract for yield-gate.sh:
#   - exits 0 on every valid phase
#   - writes ZERO bytes to stdout
#   - writes BOTH session-state fields (`last_checkpoint_phase`,
#     `last_yield_emitted_at`)
#   - rejects unknown phases / missing flags with non-zero exit
#
# The cross-cuts:
#   - tests/skills/gaia-meeting/yield-gate-auq.bats — E76-S18 AC7/AC8 contract
#   - tests/skills/gaia-meeting/gaia-meeting-stdout-sentinel-forbid.bats —
#     E76-S15 anti-pattern check on SKILL.md
#
# Phase enum: post-charter, post-research, discuss-cadence, pre-close, pre-save.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/yield-gate.sh"
  SESSION_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-10-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: yield-gate.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# --- post-AF-2026-05-10-1 emission contract: ZERO stdout, side-effects-only

@test "post-charter phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-001" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "post-charter" ]
}

@test "post-research phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-002" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id sess-test-002
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "post-research" ]
}

@test "discuss-cadence phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-003" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase discuss-cadence --session-id sess-test-003
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "discuss-cadence" ]
}

@test "pre-close phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-004" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-close --session-id sess-test-004
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "pre-close" ]
}

@test "pre-save phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-005" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-005
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "pre-save" ]
}

# --- argument-validation contract (unchanged from E76-S9)

@test "invalid phase rejects with non-zero exit and usage line" {
  run "$HELPER" --phase bogus-phase --session-id sess-x
  [ "$status" -ne 0 ]
  [[ "$output$stderr" == *"phase"* ]] || [[ "${stderr:-}" == *"phase"* ]] || true
}

@test "missing --session-id rejects with non-zero exit" {
  run "$HELPER" --phase post-charter
  [ "$status" -ne 0 ]
}

@test "missing --phase rejects with non-zero exit" {
  run "$HELPER" --session-id sess-x
  [ "$status" -ne 0 ]
}

@test "empty --session-id rejects with non-zero exit" {
  run "$HELPER" --phase post-charter --session-id ""
  [ "$status" -ne 0 ]
}

# --- side-effect ordering contract (preserved from AF-2026-05-08-4)

@test "AC2: session-state writes (last_checkpoint_phase + last_yield_emitted_at) fire on every invocation" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-006" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-006
  [ "$status" -eq 0 ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "pre-save" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  # ISO-8601 UTC: YYYY-MM-DDTHH:MM:SSZ
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "AF-2026-05-10-1: --side-effect-only flag is accepted (no-op vs default)" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-007" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-007 --side-effect-only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "post-charter" ]
}

@test "AF-2026-05-10-1: yield-gate.sh source contains ZERO YIELD-STOP literal strings" {
  count="$(grep -c 'YIELD-STOP' "$HELPER" || true)"
  [ "$count" -eq 0 ]
}
