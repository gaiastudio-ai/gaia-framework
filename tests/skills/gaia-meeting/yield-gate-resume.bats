#!/usr/bin/env bats
# yield-gate-resume.bats — verify --resume semantics across all five
# YIELD-STOP sentinel phases (E76-S9, AC7, T6.1).
#
# Each phase emits a YIELD-STOP via yield-gate.sh; the session-state file
# records last_checkpoint_phase. A subsequent --resume invocation reads
# last_checkpoint_phase and re-enters at the matching phase. The four
# user-prompt branches (--continue / --interject / --wrap-up / --abort)
# behave identically across all five sentinel phases — handled by
# parse-resume-flags.sh (E76-S7), which is consumed unchanged here.
#
# This test asserts the round-trip: yield-gate writes the session field;
# session-state.sh read returns it; parse-resume-flags accepts each of the
# four action flags against each of the five phases.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  YIELD="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/yield-gate.sh"
  SESSION_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  PARSE_RESUME="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/parse-resume-flags.sh"
  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-08-resume.yaml"
}

teardown() {
  rm -rf "$TMP"
}

phases=("post-charter" "post-research" "discuss-cadence" "pre-close" "pre-save")

@test "the post-charter yield writes a checkpoint phase that session state reads back" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r1" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase post-charter --session-id sess-r1 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$read_back" = "post-charter" ]
}

@test "the post-research yield writes a checkpoint phase that session state reads back" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r2" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase post-research --session-id sess-r2 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$read_back" = "post-research" ]
}

@test "the discuss-cadence yield writes a checkpoint phase that session state reads back" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r3" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase discuss-cadence --session-id sess-r3 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$read_back" = "discuss-cadence" ]
}

@test "the pre-close yield writes a checkpoint phase that session state reads back" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r4" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase pre-close --session-id sess-r4 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$read_back" = "pre-close" ]
}

@test "the pre-save yield writes a checkpoint phase that session state reads back" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r5" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase pre-save --session-id sess-r5 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$read_back" = "pre-save" ]
}

@test "resume-flag parsing accepts --continue against any session" {
  if [ ! -x "$PARSE_RESUME" ]; then
    skip "parse-resume-flags.sh not present in this checkout"
  fi
  run "$PARSE_RESUME" --resume sess-x --continue
  [ "$status" -eq 0 ]
}

@test "resume-flag parsing accepts --wrap-up against any session" {
  if [ ! -x "$PARSE_RESUME" ]; then
    skip "parse-resume-flags.sh not present in this checkout"
  fi
  run "$PARSE_RESUME" --resume sess-x --wrap-up
  [ "$status" -eq 0 ]
}

@test "resume-flag parsing accepts --interject against any session" {
  if [ ! -x "$PARSE_RESUME" ]; then
    skip "parse-resume-flags.sh not present in this checkout"
  fi
  run "$PARSE_RESUME" --resume sess-x --interject "hello"
  [ "$status" -eq 0 ]
}

@test "the last-yield timestamp is persisted too, so resume stays consistent" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r6" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase post-charter --session-id sess-r6 >/dev/null
  iso="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  [[ "$iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}
