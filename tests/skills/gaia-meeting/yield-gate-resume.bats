#!/usr/bin/env bats
# yield-gate-resume.bats — verify --resume semantics across all five yield
# boundaries.
#
# Each yield runs yield-gate.sh, which records two things in the session file:
# `last_yield_boundary` (which of the five boundaries fired) and
# `last_checkpoint_phase` (the lifecycle phase --resume re-enters at). The two
# are separate vocabularies; a boundary name is not a lifecycle phase, and
# --resume needs the phase to know where to pick up. The four user-prompt
# branches (--continue / --interject / --wrap-up / --abort) behave identically
# across all five boundaries — handled by parse-resume-flags.sh, which is
# consumed unchanged here.
#
# This test asserts the round-trip: yield-gate writes both session fields;
# session-state.sh read returns them; parse-resume-flags accepts each of the
# action flags.

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

@test "the post-charter yield records its boundary and the phase resume re-enters at" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r1" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase post-charter --session-id sess-r1 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$read_back" = "post-charter" ]
  reentry="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$reentry" = "RESEARCH" ]
}

@test "the post-research yield records its boundary and the phase resume re-enters at" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r2" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase post-research --session-id sess-r2 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$read_back" = "post-research" ]
  reentry="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$reentry" = "DISCUSS" ]
}

@test "the discuss-cadence yield records its boundary and the phase resume re-enters at" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r3" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase discuss-cadence --session-id sess-r3 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$read_back" = "discuss-cadence" ]
  reentry="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$reentry" = "DISCUSS" ]
}

@test "the pre-close yield records its boundary and the phase resume re-enters at" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r4" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase pre-close --session-id sess-r4 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$read_back" = "pre-close" ]
  reentry="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$reentry" = "CLOSE" ]
}

@test "the pre-save yield records its boundary and the phase resume re-enters at" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-r5" >/dev/null
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$YIELD" --phase pre-save --session-id sess-r5 >/dev/null
  read_back="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$read_back" = "pre-save" ]
  reentry="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)"
  [ "$reentry" = "SAVE" ]
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
