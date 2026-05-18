#!/usr/bin/env bash
# orchestration-warning.sh — E84-S4 / ADR-093 / FR-446.
#
# Emits a one-shot per-session warning when a heavy-procedural or
# conversational skill starts in Mode A (subagent dispatch). Mode A is
# lossy for those skill classes because each subagent dispatch creates
# a fresh forked context that cannot return rich state to the parent
# orchestrator — the orchestrator receives only structured returns
# (summary, findings, verdict), not the full reasoning trace.
#
# Mode B (Agent Teams persistent teammates) preserves in-conversation
# state across dispatches and is the recommended mode for these classes.
# The warning informs the user of the trade-off and how to enable Mode B.
#
# One-shot semantics:
#   A marker file at $CHECKPOINT_PATH/orchestration-warning-shown.{session_id}
#   suppresses repeat warnings within the same session. The marker is
#   keyed on session_id, so a new session re-emits the warning once.
#
# When NO warning is emitted (silent exit 0):
#   - skill class is `light-procedural` (cheap; no continuity benefit)
#   - skill class is `reviewer` (one-shot fork by design; NFR-060)
#   - active mode is `team` (Mode B; full fidelity; no trade-off)
#   - marker file for this session already exists (one-shot honored)
#
# Exit codes:
#   0 — script completed (warning emitted or suppressed)
#   2 — usage error
#
# POSIX discipline: bash 3.2 compatible (macOS default).

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_NAME="orchestration-warning.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  orchestration-warning.sh --skill-class <class> --mode <mode>
                           [--session-id <id>]
                           [--checkpoint-path <dir>]

Arguments:
  --skill-class:     one of {reviewer, light-procedural, heavy-procedural,
                     conversational}. Typically read from the calling skill's
                     SKILL.md orchestration_class frontmatter.
  --mode:            one of {subagent, team}. Typically the output of
                     detect-orchestration-mode.sh at skill startup.
  --session-id:      session identifier used to key the one-shot marker.
                     Defaults to ${CLAUDE_SESSION_ID:-PID-of-orchestrator}.
  --checkpoint-path: directory for the marker file. Defaults to
                     ${CHECKPOINT_PATH:-./_memory/checkpoints}.

Emits the lossy-mode warning to stdout once per session when
skill-class ∈ {heavy-procedural, conversational} AND mode == subagent.
USAGE
}

skill_class=""
mode=""
session_id=""
checkpoint_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skill-class) skill_class="${2:-}"; shift 2 ;;
    --skill-class=*) skill_class="${1#--skill-class=}"; shift ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --mode=*) mode="${1#--mode=}"; shift ;;
    --session-id) session_id="${2:-}"; shift 2 ;;
    --session-id=*) session_id="${1#--session-id=}"; shift ;;
    --checkpoint-path) checkpoint_path="${2:-}"; shift 2 ;;
    --checkpoint-path=*) checkpoint_path="${1#--checkpoint-path=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$skill_class" ] || { printf '%s: --skill-class is required\n' "$SCRIPT_NAME" >&2; exit 2; }
[ -n "$mode" ] || { printf '%s: --mode is required\n' "$SCRIPT_NAME" >&2; exit 2; }

# ---- Validate enums ----
case "$skill_class" in
  reviewer|light-procedural|heavy-procedural|conversational) ;;
  *)
    printf '%s: invalid --skill-class: %s\n' "$SCRIPT_NAME" "$skill_class" >&2
    exit 2 ;;
esac
case "$mode" in
  subagent|team) ;;
  *)
    printf '%s: invalid --mode: %s\n' "$SCRIPT_NAME" "$mode" >&2
    exit 2 ;;
esac

# ---- Resolve session_id ----
if [ -z "$session_id" ]; then
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    session_id="$CLAUDE_SESSION_ID"
  else
    # Fallback: parent process id of this script (the orchestrator's PID
    # in practice). Stable for the lifetime of the parent shell.
    session_id="pid-${PPID:-0}"
  fi
fi

# Path-traversal guard on session_id.
case "$session_id" in
  */*|*..*|.*)
    printf '%s: session_id rejected (path-traversal): %s\n' "$SCRIPT_NAME" "$session_id" >&2
    exit 2 ;;
esac

# ---- Suppression: skill class outside the warn set ----
case "$skill_class" in
  reviewer|light-procedural)
    exit 0 ;;
esac

# ---- Suppression: Mode B is the full-fidelity model ----
if [ "$mode" = "team" ]; then
  exit 0
fi

# ---- Resolve checkpoint_path ----
if [ -z "$checkpoint_path" ]; then
  checkpoint_path="${CHECKPOINT_PATH:-./_memory/checkpoints}"
fi
mkdir -p "$checkpoint_path" 2>/dev/null || {
  # If we cannot mkdir, emit the warning anyway (better noisy than silent).
  :
}

marker="${checkpoint_path}/orchestration-warning-shown.${session_id}"
if [ -e "$marker" ]; then
  # One-shot honored — silent exit.
  exit 0
fi

# AF-2026-05-18-2 — surface-above-fold contract.
#
# Claude Code's CLI auto-collapses Bash tool-call output beyond a few lines,
# so a multi-line warning emitted to stdout can be invisible to users who
# don't expand the tool call. To surface the warning above the collapse
# fold, this helper now:
#
#   1. Writes the full warning text to a sentinel file at
#      ${checkpoint_path}/orchestration-warning-pending.${session_id}.
#   2. Prints a single-line `SURFACE-WARNING: <sentinel-path>` banner as
#      the FIRST stdout line — short enough to stay above any auto-collapse
#      threshold, and a machine-recognizable marker the SKILL.md prelude
#      pattern can match.
#   3. Continues to print the full warning text to stdout for backward
#      compatibility with existing callers, fixtures, and bats tests that
#      grep for the warning body.
#
# Callers that want to surface the warning to the user (the GAIA SKILL.md
# prelude pattern does this) `cat` the sentinel file and emit its contents
# as user-visible conversation text. Callers that don't care continue to
# behave as before.
sentinel="${checkpoint_path}/orchestration-warning-pending.${session_id}"

warning_body() {
  cat <<'WARN'

────────────────────────────────────────────────────────────────────────────
GAIA orchestration: running in subagent mode (Mode A)

The skill you're invoking belongs to a class (heavy-procedural or
conversational) whose output benefits from cross-step context. Mode A
dispatches each sub-agent in its own forked context, so context may
be lossy between steps — sub-agents return summaries, not full reasoning.

For the full-fidelity experience, enable Mode B (Agent Teams):
  1. Set CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in your environment.
  2. Add orchestration.mode: team to config/project-config.yaml.

Mode B uses persistent teammates that preserve in-conversation state
across dispatches. See ADR-093 (Orchestrator-as-Bridge) for the contract.

This warning is shown once per session.
────────────────────────────────────────────────────────────────────────────

WARN
}

# Write sentinel file first; if the write fails, fall through to stdout
# only — better noisy than silent.
warning_body > "$sentinel" 2>/dev/null || true

# Above-fold marker. Single line, machine-parsable; SKILL.md preludes match
# the `SURFACE-WARNING: ` prefix and `cat` the path that follows.
printf 'SURFACE-WARNING: %s\n' "$sentinel"

# Backward-compatible full warning to stdout.
warning_body

# Drop the marker so subsequent invocations stay silent for this session.
: > "$marker" 2>/dev/null || true

exit 0
