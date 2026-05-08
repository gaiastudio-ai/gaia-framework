#!/usr/bin/env bash
# yield-gate.sh — emit the canonical yield block + turn-terminal sentinel
# at any of the five `/gaia-meeting` yield boundaries (E76-S9, AC1, AC2,
# FR-MTG-32, FR-MTG-33, ADR-083 amendment).
#
# This helper moves yield-boundary enforcement from prose-side LLM discipline
# (E76-S7) to script-side. The `<<YIELD-STOP ...>>` sentinel on stdout is
# treated as turn-terminal by the SKILL.md Procedure section — the LLM MUST
# NOT emit any further output after the sentinel until re-entered via
# `/gaia-meeting --resume <session-id>`.
#
# Usage:
#   yield-gate.sh --phase <p> --session-id <id>
#
# Phase enum:
#   post-charter, post-research, discuss-cadence, pre-close, pre-save
#
# Output (stdout, in this exact order):
#   1. ## Yield: <phase>
#   2. [c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort
#   3. <<YIELD-STOP phase=<phase> session=<session-id>>>
#
# Side effects (run BEFORE the sentinel is printed — AC2):
#   session-state.sh update --field last_checkpoint_phase --value <phase>
#   session-state.sh update --field last_yield_emitted_at --value <iso8601-utc>
#
# Exit codes:
#   0 = success
#   2 = malformed args (unknown phase, empty/missing session-id, unknown flag)

set -euo pipefail

# Locale pin per Tech Notes ("Locale + portability") so character class
# comparisons and `date` output stay portable across BSD and GNU.
export LC_ALL=C

PHASE=""
SESSION_ID=""

# Single-source-of-truth phase enum. Order matches the SKILL.md Procedure
# section (post-charter -> post-research -> discuss-cadence -> pre-close ->
# pre-save).
VALID_PHASES=(
  "post-charter"
  "post-research"
  "discuss-cadence"
  "pre-close"
  "pre-save"
)

usage() {
  cat >&2 <<'EOF'
yield-gate.sh: usage:
  yield-gate.sh --phase <post-charter|post-research|discuss-cadence|pre-close|pre-save> --session-id <id>
EOF
}

# Argument parsing.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)         PHASE="${2-}"; shift 2 ;;
    --phase=*)       PHASE="${1#--phase=}"; shift ;;
    --session-id)    SESSION_ID="${2-}"; shift 2 ;;
    --session-id=*)  SESSION_ID="${1#--session-id=}"; shift ;;
    *)
      echo "yield-gate.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$PHASE" ]]; then
  echo "yield-gate.sh: --phase is required" >&2
  usage
  exit 2
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "yield-gate.sh: --session-id is required and must be non-empty" >&2
  usage
  exit 2
fi

# Validate phase against the canonical enum.
phase_valid="0"
for p in "${VALID_PHASES[@]}"; do
  if [[ "$PHASE" == "$p" ]]; then
    phase_valid="1"
    break
  fi
done
if [[ "$phase_valid" != "1" ]]; then
  echo "yield-gate.sh: unknown phase: $PHASE" >&2
  usage
  exit 2
fi

# Locate the session-state.sh helper. Prefer an explicit override
# (GAIA_MEETING_SESSION_STATE_BIN) so tests can stub the helper without
# touching PATH. Otherwise resolve siblingwise to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE_BIN="${GAIA_MEETING_SESSION_STATE_BIN:-${SCRIPT_DIR}/session-state.sh}"

# Locate the session file. Prefer an explicit override
# (GAIA_MEETING_SESSION_FILE) — the orchestrator typically constructs the
# `_memory/meeting-sessions/{YYYY-MM-DD}-{slug}.yaml` path and exports it.
# When unset, fall back to a conventional path derived from the session id.
SESSION_FILE="${GAIA_MEETING_SESSION_FILE:-_memory/meeting-sessions/${SESSION_ID}.yaml}"

# ISO-8601 UTC timestamp — BSD- and GNU-portable.
ISO8601_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Side effects FIRST — write the two session-state fields BEFORE printing the
# turn-terminal sentinel. Per AC2, this ordering means `--resume` reads a
# consistent state regardless of whether the LLM honours the STOP.
#
# When the session file does not yet exist (e.g., the helper is being
# exercised standalone in a test stub), session-state.sh exits non-zero on
# `update`. We tolerate that exit so yield-gate remains useful in
# helper-stubbed test contexts — the caller (orchestrator) is expected to
# have called `session-state.sh create` earlier in the lifecycle.
"$SESSION_STATE_BIN" update \
  --file "$SESSION_FILE" \
  --field last_checkpoint_phase \
  --value "$PHASE" \
  >/dev/null 2>&1 || true

"$SESSION_STATE_BIN" update \
  --file "$SESSION_FILE" \
  --field last_yield_emitted_at \
  --value "$ISO8601_NOW" \
  >/dev/null 2>&1 || true

# Emit the canonical 3-line yield block. Order is load-bearing — the bats
# tests in tests/skills/gaia-meeting/yield-gate.bats assert each line by
# position.

# 1. Phase marker.
printf '## Yield: %s\n' "$PHASE"

# 2. Canonical prompt block — verbatim from SKILL.md "Canonical user-prompt
#    block". Single source of truth, do not paraphrase.
printf '[c]ontinue / [p]ause / [i]nterject "..." / [w]rap-up / [a]bort\n'

# 3. Turn-terminal sentinel — its own line, no trailing text. The SKILL.md
#    Procedure section treats this as the literal end-of-turn marker. Any
#    deviation breaks the regex parsers in the bats tests.
printf '<<YIELD-STOP phase=%s session=%s>>\n' "$PHASE" "$SESSION_ID"

exit 0
