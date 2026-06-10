#!/usr/bin/env bash
# triage-sentinel.sh — per-sprint triage proof-of-run sentinel.
#
# /gaia-triage-findings is a mandatory sprint-close prerequisite: a sprint
# cannot be closed unless triage has run for it. This helper writes (on triage
# completion) and checks (from sprint-close) a small sentinel keyed to the
# active sprint, mirroring sprint-close's existing retro-doc and
# sprint-review-sentinel prerequisite gates.
#
# Sentinel path:
#   .gaia/memory/checkpoints/triage-findings-{sprint_id}-completed.json
#
# Usage:
#   triage-sentinel.sh write --sprint-id <id> [--checkpoints-dir <dir>]
#   triage-sentinel.sh check --sprint-id <id> [--checkpoints-dir <dir>]
#
# Exit codes:
#   write: 0 on success, 1 on usage/IO error
#   check: 0 when the sentinel exists (triage ran), 1 when absent, 2 usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

MODE="${1:-}"; shift || true
SPRINT_ID=""
CKDIR=".gaia/memory/checkpoints"

while [ $# -gt 0 ]; do
  case "$1" in
    --sprint-id) SPRINT_ID="${2:-}"; shift 2 ;;
    --checkpoints-dir) CKDIR="${2:-}"; shift 2 ;;
    *) printf 'triage-sentinel.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$SPRINT_ID" ] || { printf 'triage-sentinel.sh: --sprint-id is required\n' >&2; exit 2; }
# Validate sprint id shape to keep it a safe path component.
case "$SPRINT_ID" in
  */*|*..*|"") printf 'triage-sentinel.sh: invalid sprint-id: %s\n' "$SPRINT_ID" >&2; exit 2 ;;
esac

SENTINEL="$CKDIR/triage-findings-${SPRINT_ID}-completed.json"

case "$MODE" in
  write)
    mkdir -p "$CKDIR"
    tmp="$CKDIR/.triage-sentinel.$$.tmp"
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg sid "$SPRINT_ID" '{workflow:"gaia-triage-findings", sprint_id:$sid, completed:true}' > "$tmp"
    else
      printf '{"workflow":"gaia-triage-findings","sprint_id":"%s","completed":true}\n' "$SPRINT_ID" > "$tmp"
    fi
    mv -f "$tmp" "$SENTINEL"
    printf '%s\n' "$SENTINEL"
    ;;
  check)
    if [ -f "$SENTINEL" ]; then
      exit 0
    else
      printf 'triage-sentinel.sh: triage not run for %s (sentinel absent: %s)\n' "$SPRINT_ID" "$SENTINEL" >&2
      exit 1
    fi
    ;;
  *)
    printf 'triage-sentinel.sh: mode must be write|check (got: %s)\n' "$MODE" >&2
    exit 2
    ;;
esac
