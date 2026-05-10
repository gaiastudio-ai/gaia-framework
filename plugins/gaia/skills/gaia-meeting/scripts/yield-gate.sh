#!/usr/bin/env bash
# yield-gate.sh — write the canonical yield-boundary session-state side
# effects at any of the five `/gaia-meeting` yield boundaries (E76-S9 + AF-2026-05-08-4
# session-state contract; AF-2026-05-10-1 substrate-replacement amendment;
# E76-S18 / FR-MTG-32 / FR-MTG-33; ADR-083 third in-place amendment).
#
# History
# -------
# - AF-2026-05-08-4 (E76-S9) installed the canonical 3-line stdout block
#   (phase marker + prompt + a turn-terminal stdout sentinel) as the
#   script-side turn-terminal mechanism. The intent was to move
#   yield-boundary enforcement from prose-side LLM discipline to script-side.
# - AF-2026-05-10-1 (E76-S18) — empirical verification on 2026-05-09 showed
#   the stdout sentinel was defeated by harness Auto Mode; the harness does
#   not stop on stdout content. The ADR-083 contract was amended: yield
#   boundaries now use the substrate `AskUserQuestion` primitive, which halts
#   the LLM turn at the substrate level regardless of Auto Mode. This script
#   no longer emits the 3-line stdout block. It RETAINS the session-state
#   side-effect writes — those remain the source of truth for `--resume`
#   re-entry consistency. The orchestrator (SKILL.md §Procedure prose) emits
#   the AskUserQuestion call AFTER this helper writes its side effects.
#
# Memory rule precedent: `_memory/feedback_askuserquestion_under_automode.md`.
#
# Usage:
#   yield-gate.sh --phase <p> --session-id <id> [--side-effect-only]
#
# The `--side-effect-only` flag is accepted for forward-compatibility and
# is the DEFAULT behaviour under AF-2026-05-10-1 — the flag is a no-op vs.
# the default invocation. It exists so SKILL.md procedure prose can
# explicitly document the side-effect-only intent at every yield boundary.
#
# Phase enum:
#   post-charter, post-research, discuss-cadence, pre-close, pre-save
#
# Side effects (the only effects this helper produces):
#   session-state.sh update --field last_checkpoint_phase --value <phase>
#   session-state.sh update --field last_yield_emitted_at --value <iso8601-utc>
#
# Output:
#   none — the helper writes ZERO bytes to stdout. AF-2026-05-10-1 removed
#   the stdout-sentinel emission. The substrate-correct user-facing prompt
#   mechanism is the LLM-emitted `AskUserQuestion` tool call rendered AFTER
#   this helper completes.
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
# `--side-effect-only` is accepted but currently a no-op vs. the default —
# AF-2026-05-10-1 made side-effect-only the only behaviour. Captured here
# explicitly so callers passing the flag receive a clean exit and so the
# parser does not reject a recognised flag.
SIDE_EFFECT_ONLY=0

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
  yield-gate.sh --phase <post-charter|post-research|discuss-cadence|pre-close|pre-save> --session-id <id> [--side-effect-only]
EOF
}

# Argument parsing.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)              PHASE="${2-}"; shift 2 ;;
    --phase=*)            PHASE="${1#--phase=}"; shift ;;
    --session-id)         SESSION_ID="${2-}"; shift 2 ;;
    --session-id=*)       SESSION_ID="${1#--session-id=}"; shift ;;
    --side-effect-only)   SIDE_EFFECT_ONLY=1; shift ;;
    *)
      echo "yield-gate.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# `SIDE_EFFECT_ONLY` is intentionally not consulted below — under
# AF-2026-05-10-1 the helper has no other behaviour to gate. Reading it once
# silences shellcheck's "unused variable" warning without changing behaviour.
: "$SIDE_EFFECT_ONLY"

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

# Side-effect-only writes. Per AF-2026-05-08-4 the two fields are written
# BEFORE any user-facing prompt mechanism so `--resume` reads a consistent
# state regardless of how the user responds. AF-2026-05-10-1 removed the
# subsequent stdout-sentinel emit — the side-effect ordering invariant is
# preserved by the orchestrator's procedure: this helper runs to completion
# THEN the LLM emits the substrate `AskUserQuestion` tool call. The
# session-state writes are still the FIRST thing on the wire.
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

# AF-2026-05-10-1: NO stdout output. The substrate `AskUserQuestion` tool
# call is the user-facing prompt mechanism — it is emitted by the LLM in the
# enclosing `/gaia-meeting` orchestration AFTER this helper returns. See
# SKILL.md §Procedure for the canonical sequence at each of the 5 yield
# boundaries (post-CHARTER, post-RESEARCH, discuss-cadence, pre-CLOSE,
# pre-SAVE).

exit 0
