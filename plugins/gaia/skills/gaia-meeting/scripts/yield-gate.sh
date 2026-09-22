#!/usr/bin/env bash
# yield-gate.sh — write the canonical yield-boundary session-state side
# effects at any of the five `/gaia-meeting` yield boundaries.
#
# History
# -------
# - Original implementation installed the canonical 3-line stdout block
#   (phase marker + prompt + a turn-terminal stdout sentinel) as the
#   script-side turn-terminal mechanism. The intent was to move
#   yield-boundary enforcement from prose-side LLM discipline to script-side.
# - Subsequent amendment — empirical verification showed the stdout sentinel
#   was defeated by harness Auto Mode; the harness does not stop on stdout
#   content. The yield-boundary contract was amended: yield boundaries now use
#   the substrate `AskUserQuestion` primitive, which halts the LLM turn at the
#   substrate level regardless of Auto Mode. This script no longer emits the
#   3-line stdout block. It RETAINS the session-state side-effect writes —
#   those remain the source of truth for `--resume` re-entry consistency. The
#   orchestrator (SKILL.md §Procedure prose) emits the AskUserQuestion call
#   AFTER this helper writes its side effects.
#
# Usage:
#   yield-gate.sh --phase <p> --session-id <id> [--side-effect-only]
#
# The `--side-effect-only` flag is accepted for forward-compatibility and is
# the DEFAULT behaviour — the flag is a no-op vs. the default invocation. It
# exists so SKILL.md procedure prose can explicitly document the
# side-effect-only intent at every yield boundary.
#
# Phase enum:
#   post-charter, post-research, discuss-cadence, pre-close, pre-save
#
# Side effects (the only effects this helper produces):
#   session-state.sh update --field last_yield_boundary   --value <boundary>
#   session-state.sh update --field last_checkpoint_phase --value <lifecycle-phase>
#   session-state.sh update --field last_yield_emitted_at --value <iso8601-utc>
#
# The boundary name and the lifecycle phase are two different vocabularies and
# live in two different fields. `last_yield_boundary` answers "which of the
# five yield points fired"; `last_checkpoint_phase` answers "which lifecycle
# phase does `--resume` re-enter at" and is constrained to the seven canonical
# phases. Writing the boundary name into the phase field is rejected by
# session-state.sh, so each yield writes both, derived from one another via
# `lifecycle_phase_for_boundary` below.
#
# Output:
#   none — the helper writes ZERO bytes to stdout. The stdout-sentinel
#   emission was removed. The substrate-correct user-facing prompt mechanism
#   is the LLM-emitted `AskUserQuestion` tool call rendered AFTER this helper
#   completes.
#
# Exit codes:
#   0 = success
#   2 = malformed args (unknown phase, empty/missing session-id, unknown flag)

set -euo pipefail

# Locale pin per Tech Notes ("Locale + portability") so character class
# comparisons and `date` output stay portable across BSD and GNU.
export LC_ALL=C

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

# Memory-tree segment, resolved through the shared paths helper rather than
# spelled out here, so a move of the tree is picked up automatically.
#
# The helper is sourced in a subshell pinned to a sentinel root: the session
# path below is project-relative when PROJECT_ROOT is unset, and the helper's
# walk-up from CWD would otherwise resolve some unrelated ancestor as the root
# and turn the path absolute against the wrong tree. Pinning the root
# suppresses the walk-up; stripping it back off leaves just the segment.
_gaia_memory_segment() {
  local lib _sentinel
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/gaia-paths.sh"
  [ -r "$lib" ] || return 1
  _sentinel="/gaia-path-segment-probe"
  (
    # shellcheck disable=SC2030  # the subshell is the point: the probe root must
    # not escape into the caller's environment.
    PROJECT_ROOT="$_sentinel"
    _GAIA_PATHS_LOADED=""
    # shellcheck source=../../../scripts/lib/gaia-paths.sh
    # shellcheck disable=SC1091  # resolved at runtime from the plugin root.
    . "$lib" >/dev/null 2>&1 || exit 1
    [ -n "${GAIA_MEMORY_DIR:-}" ] || exit 1
    printf '%s' "${GAIA_MEMORY_DIR#"$_GAIA_ROOT_CANON"/}"
  )
}

MEMORY_SEGMENT="$(_gaia_memory_segment || true)"
if [[ -z "$MEMORY_SEGMENT" ]]; then
  echo "yield-gate.sh: could not resolve the memory tree via the shared paths helper" >&2
  exit 3
fi

PHASE=""
SESSION_ID=""
# `--side-effect-only` is accepted but currently a no-op vs. the default —
# side-effect-only is the only behaviour. Captured here explicitly so callers
# passing the flag receive a clean exit and so the parser does not reject a
# recognised flag.
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

# Map a yield boundary to the lifecycle phase `--resume` re-enters at.
#
# Each boundary sits at a known point in the lifecycle, and re-entry resumes
# the phase the meeting was about to perform — not the one it just finished,
# which would replay work already done:
#   post-charter    -> RESEARCH  (charter accepted; preludes come next)
#   post-research   -> DISCUSS   (preludes landed; discussion comes next)
#   discuss-cadence -> DISCUSS   (mid-discussion; resume continues the rounds)
#   pre-close       -> CLOSE     (about to draft close-time triage/artifacts)
#   pre-save        -> SAVE      (about to write artifacts to disk)
lifecycle_phase_for_boundary() {
  case "$1" in
    post-charter)    printf 'RESEARCH' ;;
    post-research)   printf 'DISCUSS' ;;
    discuss-cadence) printf 'DISCUSS' ;;
    pre-close)       printf 'CLOSE' ;;
    pre-save)        printf 'SAVE' ;;
    *)               return 1 ;;
  esac
}

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

# `SIDE_EFFECT_ONLY` is intentionally not consulted below — the helper has no
# other behaviour to gate. Reading it once silences shellcheck's "unused
# variable" warning without changing behaviour.
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
# The meeting-sessions directory of the memory tree is the only canonical
# location; the legacy fallback was removed with the consolidation migration.
# With the default tree this resolves to
# `<root>/.gaia/memory/meeting-sessions/<id>.yaml` — the segment comes from
# the shared paths helper so a tree move is picked up without editing this
# line. Env override wins.
if [ -n "${GAIA_MEETING_SESSION_FILE:-}" ]; then
  SESSION_FILE="$GAIA_MEETING_SESSION_FILE"
else
  # shellcheck disable=SC2031  # the segment probe's PROJECT_ROOT is scoped to
  # its own subshell; this reads the caller's value, which is unchanged.
  SESSION_FILE="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}${MEMORY_SEGMENT}/meeting-sessions/${SESSION_ID}.yaml"
fi

# ISO-8601 UTC timestamp — BSD- and GNU-portable.
ISO8601_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Side-effect-only writes. The two fields are written BEFORE any user-facing
# prompt mechanism so `--resume` reads a consistent state regardless of how
# the user responds. The stdout-sentinel emit was removed — the side-effect
# ordering invariant is preserved by the orchestrator's procedure: this helper
# runs to completion THEN the LLM emits the substrate `AskUserQuestion` tool
# call. The session-state writes are still the FIRST thing on the wire.
#
# When the session file does not yet exist (e.g., the helper is being
# exercised standalone in a test stub), session-state.sh exits non-zero on
# `update`. We tolerate that exit so yield-gate remains useful in
# helper-stubbed test contexts — the caller (orchestrator) is expected to
# have called `session-state.sh create` earlier in the lifecycle.
#
# Tolerated is NOT the same as silent. A rejected write means `--resume` will
# re-enter at a stale point, which is exactly the class of defect that hides
# when stderr is discarded. Every failed write therefore names its field and
# relays the helper's own diagnostic on stderr. stdout stays empty — the
# zero-stdout contract is what the substrate depends on, stderr is not part
# of it.
write_session_field() {
  local field="$1"
  local value="$2"
  local err
  if ! err="$("$SESSION_STATE_BIN" update \
      --file "$SESSION_FILE" \
      --field "$field" \
      --value "$value" 2>&1 >/dev/null)"; then
    echo "yield-gate.sh: warning: failed to write ${field} to ${SESSION_FILE}" >&2
    [ -n "$err" ] && echo "yield-gate.sh: ${SESSION_STATE_BIN}: ${err}" >&2
    return 1
  fi
  return 0
}

# Record which boundary fired, the lifecycle phase `--resume` re-enters at,
# and when. `|| true` keeps a stubbed-helper context non-fatal; the warning
# above is what makes a rejected write visible.
write_session_field last_yield_boundary "$PHASE" || true

RESUME_PHASE="$(lifecycle_phase_for_boundary "$PHASE")"
write_session_field last_checkpoint_phase "$RESUME_PHASE" || true

write_session_field last_yield_emitted_at "$ISO8601_NOW" || true

# NO stdout output. The substrate `AskUserQuestion` tool call is the
# user-facing prompt mechanism — it is emitted by the LLM in the enclosing
# `/gaia-meeting` orchestration AFTER this helper returns. See SKILL.md
# §Procedure for the canonical sequence at each of the 5 yield boundaries
# (post-CHARTER, post-RESEARCH, discuss-cadence, pre-CLOSE, pre-SAVE).

exit 0
