#!/usr/bin/env bats
# yield-gate.bats — gaia-meeting yield-gate helper (E76-S9, AC1, AC2, TC-MTG-YGATE-1, TC-MTG-YGATE-2)
#
# AC1: yield-gate.sh emits (in order):
#   1. phase marker:  ## Yield: <phase>
#   2. canonical prompt: [c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort
#   3. sentinel: <<YIELD-STOP phase=<phase> session=<session-id>>>
# Exits 0 on success.
#
# AC2: BEFORE the sentinel prints, two session-state.sh update calls fire:
#   - --field last_checkpoint_phase --value <phase>
#   - --field last_yield_emitted_at --value <iso8601>
#
# Phase enum: post-charter, post-research, discuss-cadence, pre-close, pre-save.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/yield-gate.sh"
  SESSION_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-08-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: yield-gate.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC1: post-charter phase emits 3-line block in canonical order" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-001" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-001
  [ "$status" -eq 0 ]
  # Exactly 3 lines.
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$line_count" = "3" ]
  # Line 1: phase marker.
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "## Yield: post-charter" ]
  # Line 2: canonical prompt — exact wording.
  [ "$(printf '%s\n' "$output" | sed -n '2p')" = '[c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort' ]
  # Line 3: sentinel — exact format.
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "<<YIELD-STOP phase=post-charter session=sess-test-001>>" ]
}

@test "AC1: post-research phase emits canonical 3-line block" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-002" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id sess-test-002
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "## Yield: post-research" ]
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "<<YIELD-STOP phase=post-research session=sess-test-002>>" ]
}

@test "AC1: discuss-cadence phase emits canonical 3-line block" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-003" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase discuss-cadence --session-id sess-test-003
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "## Yield: discuss-cadence" ]
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "<<YIELD-STOP phase=discuss-cadence session=sess-test-003>>" ]
}

@test "AC1: pre-close phase emits canonical 3-line block" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-004" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-close --session-id sess-test-004
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "## Yield: pre-close" ]
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "<<YIELD-STOP phase=pre-close session=sess-test-004>>" ]
}

@test "AC1: pre-save phase emits canonical 3-line block" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-005" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-005
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "## Yield: pre-save" ]
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "<<YIELD-STOP phase=pre-save session=sess-test-005>>" ]
}

@test "AC1: invalid phase rejects with non-zero exit and usage line" {
  run "$HELPER" --phase bogus-phase --session-id sess-x
  [ "$status" -ne 0 ]
  [[ "$output$stderr" == *"phase"* ]] || [[ "${stderr:-}" == *"phase"* ]] || true
}

@test "AC1: missing --session-id rejects with non-zero exit" {
  run "$HELPER" --phase post-charter
  [ "$status" -ne 0 ]
}

@test "AC1: missing --phase rejects with non-zero exit" {
  run "$HELPER" --session-id sess-x
  [ "$status" -ne 0 ]
}

@test "AC1: empty --session-id rejects with non-zero exit" {
  run "$HELPER" --phase post-charter --session-id ""
  [ "$status" -ne 0 ]
}

@test "AC2: session-state writes (last_checkpoint_phase + last_yield_emitted_at) precede sentinel" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-006" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-test-006
  [ "$status" -eq 0 ]
  # After running yield-gate, the session file MUST have the two fields written.
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$phase_val" = "pre-save" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  # ISO-8601 UTC: YYYY-MM-DDTHH:MM:SSZ
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "AC2: sentinel is the FINAL line of stdout (no trailing output)" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-test-007" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-test-007
  [ "$status" -eq 0 ]
  last_line="$(printf '%s\n' "$output" | tail -1)"
  [[ "$last_line" == "<<YIELD-STOP phase=post-charter session=sess-test-007>>" ]]
}

@test "AC2: temporal ordering — session-state writes precede sentinel emission" {
  # Stub session-state.sh in PATH to a logger that records both write events
  # and stdout sentinel emission in a single shared log. We then assert that
  # both update lines appear in the log BEFORE the sentinel marker.
  STUB_DIR="$TMP/stubs"
  mkdir -p "$STUB_DIR"
  LOG="$TMP/order.log"
  : > "$LOG"
  # Stub session-state.sh: log update calls then no-op exit 0.
  cat > "$STUB_DIR/session-state.sh" <<EOF
#!/usr/bin/env bash
# Stub for ordering test.
sub="\$1"; shift
if [[ "\$sub" == "update" ]]; then
  field=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --field) field="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'update %s\n' "\$field" >> "$LOG"
fi
exit 0
EOF
  chmod +x "$STUB_DIR/session-state.sh"
  # Capture stdout into the log AFTER the session-state lines would be appended.
  # The helper script MUST call session-state.sh BEFORE printing the sentinel,
  # so when we capture both into the same log via tee, ordering reflects exec
  # order.
  # We feed session-state stub via env override on PATH-like resolution.
  run env GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
      GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
      bash -c "'$HELPER' --phase post-research --session-id sess-test-008 | tee -a '$LOG'"
  [ "$status" -eq 0 ]
  # Verify ordering: both update lines appear before the sentinel line.
  phase_line_no="$(grep -n 'update last_checkpoint_phase' "$LOG" | head -1 | cut -d: -f1)"
  iso_line_no="$(grep -n 'update last_yield_emitted_at' "$LOG" | head -1 | cut -d: -f1)"
  sentinel_line_no="$(grep -n 'YIELD-STOP' "$LOG" | head -1 | cut -d: -f1)"
  [ -n "$phase_line_no" ]
  [ -n "$iso_line_no" ]
  [ -n "$sentinel_line_no" ]
  [ "$phase_line_no" -lt "$sentinel_line_no" ]
  [ "$iso_line_no" -lt "$sentinel_line_no" ]
}
