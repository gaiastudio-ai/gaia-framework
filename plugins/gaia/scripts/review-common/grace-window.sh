#!/usr/bin/env bash
# grace-window.sh — GAIA review-common grace window helper
#
# Compares a GATING-flip activation timestamp to "now" and emits the gating
# mode: WARNING-with-explanation during the seven-day grace window, BLOCK after.
#
# Public API (entry point):
#   grace-window.sh --flip-timestamp <epoch> [--now <epoch>]
#   grace-window.sh --help
#
# Output (stdout):
#   mode=<WARNING|BLOCK>
#   days_elapsed=<int>
#   days_remaining=<int>            (0 when mode=BLOCK)
#   recommendation=<text>           (only when mode=WARNING)
#
# Exit codes:
#   0  success
#   1  caller error — missing required flag, invalid epoch
#
# Calendar-time semantics (story Dev Notes): the grace window is seven calendar
# days (7 * 86400 seconds) measured from the flip activation timestamp. The
# boundary at exactly 7 days is BLOCK (grace expired). The script does not
# honor DST or leap seconds — both inputs are POSIX epoch seconds.
#

set -euo pipefail
LC_ALL=C
export LC_ALL
TZ=UTC
export TZ

SCRIPT_NAME="grace-window.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — 7-day grace window helper

Usage:
  $SCRIPT_NAME --flip-timestamp <epoch> [--now <epoch>]
  $SCRIPT_NAME --help

Stdout:
  mode=<WARNING|BLOCK>
  days_elapsed=<int>
  days_remaining=<int>
  recommendation=<text>          (WARNING only)

Exit codes: 0 success; 1 caller error.
EOF
}

is_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

FLIP=""
NOW=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flip-timestamp) [ "$#" -ge 2 ] || die 1 "--flip-timestamp requires an epoch"; FLIP="$2"; shift 2 ;;
    --now)            [ "$#" -ge 2 ] || die 1 "--now requires an epoch"; NOW="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$FLIP" ] || die 1 "missing required --flip-timestamp <epoch>"
is_int "$FLIP" || die 1 "invalid --flip-timestamp '$FLIP' (must be integer epoch seconds)"

if [ -z "$NOW" ]; then
  NOW="$(date -u +%s)"
fi
is_int "$NOW" || die 1 "invalid --now '$NOW' (must be integer epoch seconds)"

GRACE_SECONDS=$((7 * 86400))
ELAPSED=$((NOW - FLIP))
if [ "$ELAPSED" -lt 0 ]; then ELAPSED=0; fi

# Days elapsed (floor division of seconds / 86400).
DAYS_ELAPSED=$((ELAPSED / 86400))

if [ "$ELAPSED" -ge "$GRACE_SECONDS" ]; then
  MODE="BLOCK"
  DAYS_REMAINING=0
else
  MODE="WARNING"
  REMAINING_SECONDS=$((GRACE_SECONDS - ELAPSED))
  # Round UP so any partial day still in the window counts: ceil(rem/86400).
  DAYS_REMAINING=$(( (REMAINING_SECONDS + 86399) / 86400 ))
fi

printf 'mode=%s\n' "$MODE"
printf 'days_elapsed=%d\n' "$DAYS_ELAPSED"
printf 'days_remaining=%d\n' "$DAYS_REMAINING"
if [ "$MODE" = "WARNING" ]; then
  printf 'recommendation=resolve before grace window closes (%d days remaining)\n' "$DAYS_REMAINING"
fi
exit 0
