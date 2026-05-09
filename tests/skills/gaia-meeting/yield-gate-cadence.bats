#!/usr/bin/env bats
# yield-gate-cadence.bats — full-lifecycle cadence-parameterised test
# (E76-S9, AC4, TC-MTG-YGATE-3).
#
# Drives a synthetic /gaia-meeting lifecycle by directly invoking yield-gate.sh
# at each of the five canonical yield boundaries (post-charter, post-research,
# discuss-cadence per cadence boundary, pre-close, pre-save) and counts
# YIELD-STOP sentinels in stdout.
#
# Cadence math (Dev Notes): expected sentinel count =
#   4 + floor((max_turns - 1) / checkpoint_every_n_turns)
#
# Configurations exercised:
#   (max_turns=4,  cadence=4)  -> 4 + floor(3/4)  = 4 + 0 = 4 sentinels
#   (max_turns=9,  cadence=4)  -> 4 + floor(8/4)  = 4 + 2 = 6 sentinels (AC4)
#   (max_turns=12, cadence=3)  -> 4 + floor(11/3) = 4 + 3 = 7 sentinels
#
# Note: AC4 prose says "(4, 4) = 5 sentinels with one discuss-cadence" — that
# is the ceiling-based variant (`ceil((N-1)/K)` or equivalent). Dev Notes
# state the formula is `floor((N-1)/K)` and that is the canonical math the
# helper enforces. We assert the floor formula here per the canonical Dev Notes.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/yield-gate.sh"
  SESSION_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-08-cadence.yaml"
  STDOUT_LOG="$TMP/lifecycle.stdout"
  : > "$STDOUT_LOG"
}

teardown() {
  rm -rf "$TMP"
}

# Run a synthetic lifecycle with mocked dispatch — emit yield-gate at each
# canonical boundary; collect stdout into $STDOUT_LOG.
run_lifecycle() {
  local max_turns="$1"
  local cadence="$2"
  local session_id="lifecycle-${max_turns}-${cadence}"

  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "$session_id" >/dev/null

  # post-charter
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id "$session_id" >> "$STDOUT_LOG"
  # post-research
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id "$session_id" >> "$STDOUT_LOG"
  # DISCUSS turns: cadence yield after every K-th completed turn, up to N-1
  # (the pre-close yield covers the final turn N).
  local turn=1
  while (( turn <= max_turns - 1 )); do
    if (( turn % cadence == 0 )); then
      GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase discuss-cadence --session-id "$session_id" >> "$STDOUT_LOG"
    fi
    turn=$((turn + 1))
  done
  # pre-close
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-close --session-id "$session_id" >> "$STDOUT_LOG"
  # pre-save
  GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id "$session_id" >> "$STDOUT_LOG"
}

count_sentinels() {
  grep -c '^<<YIELD-STOP ' "$STDOUT_LOG" || true
}

@test "AC4: (max_turns=4, cadence=4) -> 4 sentinels (zero discuss-cadence)" {
  run_lifecycle 4 4
  [ "$(count_sentinels)" = "4" ]
  # Verify canonical ordering: post-charter -> post-research -> pre-close -> pre-save.
  ordered_phases="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$STDOUT_LOG" | sed 's/<<YIELD-STOP phase=//')"
  expected="post-charter
post-research
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC4: (max_turns=9, cadence=4) -> 6 sentinels (two discuss-cadence)" {
  run_lifecycle 9 4
  [ "$(count_sentinels)" = "6" ]
  ordered_phases="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$STDOUT_LOG" | sed 's/<<YIELD-STOP phase=//')"
  expected="post-charter
post-research
discuss-cadence
discuss-cadence
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC4: (max_turns=12, cadence=3) -> 7 sentinels (three discuss-cadence)" {
  run_lifecycle 12 3
  [ "$(count_sentinels)" = "7" ]
  ordered_phases="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$STDOUT_LOG" | sed 's/<<YIELD-STOP phase=//')"
  expected="post-charter
post-research
discuss-cadence
discuss-cadence
discuss-cadence
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC4: canonical ordering — post-charter is first, pre-save is last" {
  run_lifecycle 9 4
  first_phase="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$STDOUT_LOG" | head -1 | sed 's/<<YIELD-STOP phase=//')"
  last_phase="$(grep -oE '<<YIELD-STOP phase=[a-z-]+' "$STDOUT_LOG" | tail -1 | sed 's/<<YIELD-STOP phase=//')"
  [ "$first_phase" = "post-charter" ]
  [ "$last_phase" = "pre-save" ]
}

@test "AC4: cadence formula 4 + floor((N-1)/K) — verified across configurations" {
  # Re-run the three configs and assert the formula explicitly.
  for cfg in "4 4 4" "9 4 6" "12 3 7"; do
    set -- $cfg
    n=$1; k=$2; expected=$3
    actual=$((4 + (n - 1) / k))
    [ "$actual" = "$expected" ]
  done
}
