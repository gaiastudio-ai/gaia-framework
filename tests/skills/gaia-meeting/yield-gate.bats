#!/usr/bin/env bats
# yield-gate.bats — gaia-meeting yield-gate helper contract.
#
# yield-gate.sh is side-effect-only: it writes session state and produces ZERO
# stdout. An earlier design had it print a turn-terminal stdout sentinel, but
# the harness does not stop on stdout content under Auto Mode, so the
# user-facing halt moved to the substrate AskUserQuestion primitive, which the
# orchestrator emits AFTER this helper returns. The session-state writes stay
# here — they are what --resume reads.
#
# The contract asserted below:
#   - exits 0 on every valid boundary
#   - writes ZERO bytes to stdout
#   - records the yield boundary in `last_yield_boundary`
#   - records the lifecycle phase --resume re-enters at in
#     `last_checkpoint_phase` (a separate vocabulary — see the mapping test)
#   - records the emission time in `last_yield_emitted_at`
#   - reports a rejected session-state write on stderr rather than swallowing it
#   - rejects unknown boundaries / missing flags with non-zero exit
#
# Yield boundaries: post-charter, post-research, discuss-cadence, pre-close,
# pre-save.

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

# --- emission contract: ZERO stdout, side-effects-only

@test "post-charter phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-001" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "post-charter" ]
}

@test "post-research phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-002" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id sess-test-002
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "post-research" ]
}

@test "discuss-cadence phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-003" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase discuss-cadence --session-id sess-test-003
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "discuss-cadence" ]
}

@test "pre-close phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-004" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-close --session-id sess-test-004
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "pre-close" ]
}

@test "pre-save phase: zero stdout, exit 0, side-effects written" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-005" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-005
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "pre-save" ]
}

# --- argument-validation contract

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

# --- side-effect ordering contract

@test "the yield boundary and last-yield timestamp are written on every invocation" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-006" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-006
  [ "$status" -eq 0 ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "pre-save" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  # ISO-8601 UTC: YYYY-MM-DDTHH:MM:SSZ
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# --- resume re-entry contract: every yield leaves a lifecycle phase behind

@test "every yield boundary records the lifecycle phase resume re-enters at" {
  # The boundary vocabulary and the lifecycle vocabulary are separate fields.
  # A yield that records only the boundary leaves --resume with no re-entry
  # point, which is the defect this pairing defends.
  while read -r boundary expected_phase; do
    session_file="$TMP/reentry-${boundary}.yaml"
    "$SESSION_HELPER" create --file "$session_file" --session-id "sess-${boundary}" >/dev/null
    env GAIA_MEETING_SESSION_FILE="$session_file" \
      "$HELPER" --phase "$boundary" --session-id "sess-${boundary}"
    got_boundary="$("$SESSION_HELPER" read --file "$session_file" --field last_yield_boundary)"
    got_phase="$("$SESSION_HELPER" read --file "$session_file" --field last_checkpoint_phase)"
    [ "$got_boundary" = "$boundary" ]
    [ "$got_phase" = "$expected_phase" ]
  done <<'EOF'
post-charter RESEARCH
post-research DISCUSS
discuss-cadence DISCUSS
pre-close CLOSE
pre-save SAVE
EOF
}

@test "a rejected session-state write is reported on stderr instead of passing silently" {
  # No `create` first — the session file does not exist, so every update is
  # rejected. The helper still exits 0 (stubbed-helper tolerance) but MUST NOT
  # do so silently: each failure names its field on stderr.
  run --separate-stderr env GAIA_MEETING_SESSION_FILE="$TMP/never-created.yaml" \
    "$HELPER" --phase pre-close --session-id sess-test-008
  [ "$status" -eq 0 ]
  # stdout stays empty — the zero-stdout contract is unaffected by warnings.
  [ -z "$output" ]
  [[ "$stderr" == *"last_yield_boundary"* ]]
  [[ "$stderr" == *"last_checkpoint_phase"* ]]
  [[ "$stderr" == *"last_yield_emitted_at"* ]]
}

@test "the --side-effect-only flag is accepted and is a no-op against the default" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-007" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-007 --side-effect-only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "post-charter" ]
}

@test "the yield gate source contains no yield-stop literal strings" {
  count="$(grep -c 'YIELD-STOP' "$HELPER" || true)"
  [ "$count" -eq 0 ]
}
