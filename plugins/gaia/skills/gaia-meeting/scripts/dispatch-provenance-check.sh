#!/usr/bin/env bash
# dispatch-provenance-check.sh — gaia-meeting transcript provenance scanner (E76-S10, AC4).
#
# ## Production callsites
#
# - `gaia-framework/plugins/gaia/skills/gaia-meeting/SKILL.md` Phase 7 SAVE
#   (L789-870 region) — wired pre-disk via E76-S22 / ADR-106. The SAVE
#   pipes the in-memory transcript into this script via `--stdin` immediately
#   after the AskUserQuestion pre-SAVE yield and BEFORE the three
#   write-boundary.sh writes. On non-zero exit, Phase 7 invokes
#   `halt-event.sh` with the canonical error format and aborts all writes.
#
# Per ADR-106 rule #4 (Static-Audit Script Wiring Discipline): this header
# section is the single source of truth keeping reviewers from re-discovering
# the wiring. Update it when callsites change.
#
# Scans a saved transcript file and asserts every per-turn header carries the
# canonical `dispatched_via:` value for its phase:
#
#   RESEARCH (prelude) -> dispatched_via: subagent
#   DISCUSS  (turn)    -> dispatched_via: subagent
#   CHARTER  (turn)    -> dispatched_via: charter
#   any [i]nterject    -> dispatched_via: interject
#
# Failure mode: any RESEARCH/DISCUSS turn missing `dispatched_via:`, or whose
# value is not `subagent`, FAILS with a non-zero exit and a line naming the
# offending turn (turn-id + phase + observed value).
#
# Turn boundaries are detected by the canonical bracketed header line emitted
# by `turn-header.sh` — `[round R / turn T / Speaker (Role) / ...]`. Each turn
# block runs from its bracketed header up to the next bracketed header (or EOF).
# Within a block we look for `Phase:` and `dispatched_via:` (case-sensitive
# field names, lowercase value). Missing field => failure for RESEARCH/DISCUSS.
#
# Usage:
#   dispatch-provenance-check.sh <transcript-file>
#   dispatch-provenance-check.sh --stdin < transcript-content        # E76-S22
#   cat transcript.md | dispatch-provenance-check.sh                 # auto-stdin
#
# Exit codes:
#   0 = all turns carry canonical provenance
#   1 = at least one turn fails the provenance check (offending turns named on stdout)
#   2 = malformed args / file not found

set -euo pipefail
export LC_ALL=C

# E76-S22 / ADR-106: stdin mode for Phase 7 SAVE pre-disk wiring.
# Modes:
#   1. positional-arg <transcript-file>   (legacy, bats backward-compat)
#   2. explicit --stdin                    (pipeline-friendly)
#   3. no arg + stdin not a TTY            (auto-detect)
TRANSCRIPT="${1-}"
TRANSCRIPT_TMP=""

cleanup_tmp() {
  if [[ -n "$TRANSCRIPT_TMP" && -f "$TRANSCRIPT_TMP" ]]; then
    rm -f "$TRANSCRIPT_TMP"
  fi
}
trap cleanup_tmp EXIT

if [[ "$TRANSCRIPT" == "--stdin" ]]; then
  TRANSCRIPT_TMP="$(mktemp)"
  cat > "$TRANSCRIPT_TMP"
  TRANSCRIPT="$TRANSCRIPT_TMP"
elif [[ -z "$TRANSCRIPT" ]]; then
  if [[ ! -t 0 ]]; then
    TRANSCRIPT_TMP="$(mktemp)"
    cat > "$TRANSCRIPT_TMP"
    TRANSCRIPT="$TRANSCRIPT_TMP"
  else
    echo "dispatch-provenance-check.sh: usage: dispatch-provenance-check.sh <transcript-file> | --stdin" >&2
    exit 2
  fi
fi
if [[ ! -f "$TRANSCRIPT" ]]; then
  echo "dispatch-provenance-check.sh: transcript file not found: $TRANSCRIPT" >&2
  exit 2
fi

# Walk the transcript line by line. A "turn block" starts at a line matching
# the canonical bracketed header `[round N / turn N / ...]`. Within each block,
# we record `Phase:` and `dispatched_via:` until the next header (or EOF).
fail_count=0
turn_round=""
turn_num=""
turn_speaker=""
turn_phase=""
turn_id=""
turn_dispatched_via=""

emit_failure() {
  local reason="$1"
  local label
  if [[ -n "$turn_id" ]]; then
    label="turn $turn_id"
  elif [[ -n "$turn_num" ]]; then
    label="turn $turn_num"
  else
    label="turn (unknown)"
  fi
  printf 'FAIL: %s phase=%s speaker=%s dispatched_via=%s — %s\n' \
    "$label" "${turn_phase:-<missing>}" "${turn_speaker:-<unknown>}" \
    "${turn_dispatched_via:-<missing>}" "$reason"
}

evaluate_block() {
  # Skip empty blocks (file lead-in before any header).
  if [[ -z "$turn_phase" && -z "$turn_round" && -z "$turn_speaker" ]]; then
    return 0
  fi
  local phase_upper
  phase_upper="$(printf '%s' "$turn_phase" | tr '[:lower:]' '[:upper:]')"
  case "$phase_upper" in
    RESEARCH|DISCUSS)
      if [[ -z "$turn_dispatched_via" ]]; then
        emit_failure "missing dispatched_via on RESEARCH/DISCUSS turn"
        fail_count=$((fail_count + 1))
        return 0
      fi
      if [[ "$turn_dispatched_via" != "subagent" && "$turn_dispatched_via" != "interject" ]]; then
        emit_failure "RESEARCH/DISCUSS turn must carry dispatched_via: subagent or interject"
        fail_count=$((fail_count + 1))
        return 0
      fi
      ;;
    CHARTER)
      if [[ -z "$turn_dispatched_via" ]]; then
        emit_failure "missing dispatched_via on CHARTER turn"
        fail_count=$((fail_count + 1))
        return 0
      fi
      if [[ "$turn_dispatched_via" != "charter" ]]; then
        emit_failure "CHARTER turn must carry dispatched_via: charter"
        fail_count=$((fail_count + 1))
        return 0
      fi
      ;;
    *)
      # INVITE / CLOSE / SAVE / unknown: no enforcement at this layer.
      ;;
  esac
  return 0
}

reset_block() {
  turn_round=""
  turn_num=""
  turn_speaker=""
  turn_phase=""
  turn_id=""
  turn_dispatched_via=""
}

while IFS= read -r line || [[ -n "$line" ]]; do
  # Bracketed header: start of a new turn block. Evaluate the previous block
  # first, then reset and parse the round / turn / speaker fields.
  if [[ "$line" =~ ^\[round[[:space:]]+([0-9]+)[[:space:]]+/[[:space:]]+turn[[:space:]]+([0-9]+)[[:space:]]+/[[:space:]]+([^/]+)[[:space:]]+/ ]]; then
    evaluate_block
    reset_block
    turn_round="${BASH_REMATCH[1]}"
    turn_num="${BASH_REMATCH[2]}"
    # Trim trailing whitespace from speaker capture.
    turn_speaker="${BASH_REMATCH[3]}"
    turn_speaker="${turn_speaker%"${turn_speaker##*[![:space:]]}"}"
    continue
  fi
  if [[ "$line" =~ ^Phase:[[:space:]]+(.+)$ ]]; then
    turn_phase="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ ^Turn:[[:space:]]+(.+)$ ]]; then
    turn_id="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ ^dispatched_via:[[:space:]]+(.+)$ ]]; then
    turn_dispatched_via="${BASH_REMATCH[1]}"
    continue
  fi
done < "$TRANSCRIPT"

# Evaluate trailing block (the loop only evaluates the previous block when a
# new header is encountered; the last block needs an explicit pass).
evaluate_block

if [[ "$fail_count" -gt 0 ]]; then
  printf '\ndispatch-provenance-check.sh: %d turn(s) failed provenance check\n' "$fail_count"
  exit 1
fi

exit 0
