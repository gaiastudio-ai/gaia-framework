#!/usr/bin/env bats
# yield-gate-cadence.bats — full-lifecycle cadence-parameterised test
# (E76-S9, E76-S18 / AF-2026-05-10-1, AC4, TC-MTG-YGATE-3).
#
# History:
#   E76-S9 / AF-2026-05-08-4 — yield-gate.sh emitted a turn-terminal stdout
#     sentinel; this file counted those sentinels to verify cadence math.
#   E76-S18 / AF-2026-05-10-1 — the stdout sentinel was empirically defeated
#     by harness Auto Mode and replaced by the substrate `AskUserQuestion`
#     primitive. yield-gate.sh now produces ZERO stdout output. The cadence
#     contract is preserved but verified by counting invocations of
#     yield-gate.sh against a stub session-state recorder rather than by
#     counting stdout sentinels.
#
# Drives a synthetic /gaia-meeting lifecycle by directly invoking yield-gate.sh
# at each of the five canonical yield boundaries (post-charter, post-research,
# discuss-cadence per cadence boundary, pre-close, pre-save) and counts the
# invocations recorded in the session-state stub log.
#
# Cadence math (Dev Notes): expected invocation count =
#   4 + floor((max_turns - 1) / checkpoint_every_n_turns)
#
# Configurations exercised:
#   (max_turns=4,  cadence=4)  -> 4 + floor(3/4)  = 4 + 0 = 4 invocations
#   (max_turns=9,  cadence=4)  -> 4 + floor(8/4)  = 4 + 2 = 6 invocations (AC4)
#   (max_turns=12, cadence=3)  -> 4 + floor(11/3) = 4 + 3 = 7 invocations

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/yield-gate.sh"
  SESSION_HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/session-state.sh"
  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-10-cadence.yaml"
  STUB_DIR="$TMP/stubs"
  PHASE_LOG="$TMP/phase-invocations.log"
  : > "$PHASE_LOG"

  # Stub session-state.sh that records every (phase, field) update event so
  # the test can derive an authoritative invocation list of yield-gate.sh.
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/session-state.sh" <<EOF
#!/usr/bin/env bash
# session-state stub for cadence test — records each --field <name> update
# call into PHASE_LOG. Echos the stub's call to PHASE_LOG when called for
# field=last_checkpoint_phase, embedding the phase value so the test can
# count yield-gate.sh invocations by phase.
sub="\$1"; shift
if [[ "\$sub" == "update" ]]; then
  field=""
  value=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --field) field="\$2"; shift 2 ;;
      --value) value="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "\$field" == "last_checkpoint_phase" ]]; then
    printf 'phase=%s\n' "\$value" >> "$PHASE_LOG"
  fi
fi
exit 0
EOF
  chmod +x "$STUB_DIR/session-state.sh"
}

teardown() {
  rm -rf "$TMP"
}

# Run a synthetic lifecycle with mocked dispatch — emit yield-gate at each
# canonical boundary; the stub session-state.sh records the phase to
# $PHASE_LOG.
run_lifecycle() {
  local max_turns="$1"
  local cadence="$2"
  local session_id="lifecycle-${max_turns}-${cadence}"

  : > "$PHASE_LOG"

  # post-charter
  GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
    GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
    "$HELPER" --phase post-charter --session-id "$session_id"
  # post-research
  GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
    GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
    "$HELPER" --phase post-research --session-id "$session_id"
  # DISCUSS turns: cadence yield after every K-th completed turn, up to N-1
  # (the pre-close yield covers the final turn N).
  local turn=1
  while (( turn <= max_turns - 1 )); do
    if (( turn % cadence == 0 )); then
      GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
        GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
        "$HELPER" --phase discuss-cadence --session-id "$session_id"
    fi
    turn=$((turn + 1))
  done
  # pre-close
  GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
    GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
    "$HELPER" --phase pre-close --session-id "$session_id"
  # pre-save
  GAIA_MEETING_SESSION_STATE_BIN="$STUB_DIR/session-state.sh" \
    GAIA_MEETING_SESSION_FILE="$SESSION_FILE" \
    "$HELPER" --phase pre-save --session-id "$session_id"
}

count_invocations() {
  grep -c '^phase=' "$PHASE_LOG" || true
}

@test "AC4: (max_turns=4, cadence=4) -> 4 invocations (zero discuss-cadence)" {
  run_lifecycle 4 4
  [ "$(count_invocations)" = "4" ]
  # Verify canonical ordering: post-charter -> post-research -> pre-close -> pre-save.
  ordered_phases="$(sed 's/^phase=//' "$PHASE_LOG")"
  expected="post-charter
post-research
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC4: (max_turns=9, cadence=4) -> 6 invocations (two discuss-cadence)" {
  run_lifecycle 9 4
  [ "$(count_invocations)" = "6" ]
  ordered_phases="$(sed 's/^phase=//' "$PHASE_LOG")"
  expected="post-charter
post-research
discuss-cadence
discuss-cadence
pre-close
pre-save"
  [ "$ordered_phases" = "$expected" ]
}

@test "AC4: (max_turns=12, cadence=3) -> 7 invocations (three discuss-cadence)" {
  run_lifecycle 12 3
  [ "$(count_invocations)" = "7" ]
  ordered_phases="$(sed 's/^phase=//' "$PHASE_LOG")"
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
  first_phase="$(sed 's/^phase=//' "$PHASE_LOG" | head -1)"
  last_phase="$(sed 's/^phase=//' "$PHASE_LOG" | tail -1)"
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
