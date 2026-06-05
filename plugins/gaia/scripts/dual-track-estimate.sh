#!/usr/bin/env bash
# dual-track-estimate.sh — dual-track estimation: points + agent-wall-clock
#
# Keeps `points` as the RELATIVE complexity/risk signal (unchanged — every
# existing consumer of points is untouched) and derives a PARALLEL
# agent_wall_clock_estimate (~Xh) = measured median minutes/point × story
# points. Estimates render in agent-hours/days, NEVER calendar-months. When no
# closed-sprint telemetry exists (cold start), the wall-clock estimate renders
# as "uncalibrated (no closed-sprint telemetry)" rather than a fabricated
# number.
#
# Cold-start detection keys on the telemetry layer's `stories_counted == 0`
# (equivalently median_minutes_per_point == null), NOT on a 0 minutes/point
# value — integer division in the telemetry layer can yield 0 for a fast,
# genuinely-calibrated story. A calibrated mpp of 0 is a sub-minute rounding
# case, rendered as "<1h", not "uncalibrated".
#
# Reuses throughput-telemetry.sh as the single source of measured throughput —
# this script does NOT re-derive throughput (SSOT). READ-ONLY.
#
# Invocation:
#   dual-track-estimate.sh --points N [--events <jsonl>] [--sprint-yaml <yaml>]
#                          [--archive-dir <dir>] [--json]
#   dual-track-estimate.sh --help
#
# Exit codes:
#   0 — rendered
#   1 — bad arguments (missing --points, unknown flag)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="dual-track-estimate.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TELEMETRY="$SCRIPT_DIR/throughput-telemetry.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
dual-track-estimate.sh — points (unchanged) + agent-wall-clock estimate (~Xh)

Usage:
  dual-track-estimate.sh --points N [--events <jsonl>] [--sprint-yaml <yaml>]
                         [--archive-dir <dir>] [--json]

Derives a parallel agent-wall-clock estimate = measured median minutes/point
(from throughput-telemetry.sh) × points. Renders agent-hours/days, never
calendar-months. Cold start (no closed-sprint telemetry) renders
"uncalibrated (no closed-sprint telemetry)" — never a fabricated number.
READ-ONLY — output on stdout.
USAGE
  exit 0
fi

POINTS=""
EVENTS=""
SPRINT_YAML="${SPRINT_STATUS_YAML:-}"
ARCHIVE_DIR=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --points) POINTS="${2:-}"; shift 2 ;;
    --events) EVENTS="${2:-}"; shift 2 ;;
    --sprint-yaml) SPRINT_YAML="${2:-}"; shift 2 ;;
    --archive-dir) ARCHIVE_DIR="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$POINTS" ] || die "--points N is required (try --help)"
printf '%s\n' "$POINTS" | grep -Eq '^[0-9]+$' || die "--points must be a non-negative integer, got: $POINTS"

# ---------- Pull measured throughput from the SSOT ----------
# We invoke throughput-telemetry.sh --json and read median_minutes_per_point +
# stories_counted. Cold start = stories_counted == 0 (no closed-sprint events).
MPP="null"
COUNTED=0
if [ -n "$EVENTS" ] && [ -r "$EVENTS" ] && [ -x "$TELEMETRY" ]; then
  tele_args=(--events "$EVENTS" --json)
  [ -n "$SPRINT_YAML" ] && tele_args+=(--sprint-yaml "$SPRINT_YAML")
  [ -n "$ARCHIVE_DIR" ] && tele_args+=(--archive-dir "$ARCHIVE_DIR")
  tele="$(bash "$TELEMETRY" "${tele_args[@]}" 2>/dev/null || true)"
  if [ -n "$tele" ]; then
    MPP="$(printf '%s' "$tele" | jq -r '.median_minutes_per_point // "null"' 2>/dev/null || echo null)"
    COUNTED="$(printf '%s' "$tele" | jq -r '.stories_counted // 0' 2>/dev/null || echo 0)"
  fi
fi

# ---------- Decide calibrated vs cold-start ----------
# Cold start strictly when no stories were counted (no telemetry) OR mpp is
# null. A numeric mpp (including 0) means calibrated.
CALIBRATED=false
MINUTES="null"
if [ "$COUNTED" -gt 0 ] 2>/dev/null && [ "$MPP" != "null" ] && [ -n "$MPP" ]; then
  CALIBRATED=true
  MINUTES=$(( MPP * POINTS ))
fi

# ---------- Render helper (inline; no exported public function) ----------
# Convert minutes -> human agent-time string: <60 -> "<1h" or "Nm"; >=60 ->
# "~X.Yh"; >=480 (8h agent-day) -> "~X.Yd". NEVER months.
EST_STR=""
if [ "$CALIBRATED" = true ]; then
  if [ "$MINUTES" -lt 60 ]; then
    if [ "$MINUTES" -lt 1 ]; then EST_STR="<1h"; else EST_STR="~${MINUTES}m"; fi
  elif [ "$MINUTES" -lt 480 ]; then
    # hours to one decimal
    EST_STR="~$(awk -v m="$MINUTES" 'BEGIN{printf "%.1f", m/60}')h"
  else
    # agent-days (8h day)
    EST_STR="~$(awk -v m="$MINUTES" 'BEGIN{printf "%.1f", m/480}')d"
  fi
else
  EST_STR="uncalibrated (no closed-sprint telemetry)"
fi

# ---------- Output ----------
if [ "$JSON_OUT" -eq 1 ]; then
  if [ "$CALIBRATED" = true ]; then
    jq -n --argjson points "$POINTS" --argjson mins "$MINUTES" --arg est "$EST_STR" \
      '{points: $points, calibrated: true, agent_wall_clock_minutes: $mins, agent_wall_clock_estimate: $est}'
  else
    jq -n --argjson points "$POINTS" --arg est "$EST_STR" \
      '{points: $points, calibrated: false, agent_wall_clock_minutes: null, agent_wall_clock_estimate: $est}'
  fi
  exit 0
fi

printf 'dual-track estimate\n'
printf 'points: %s   (relative complexity/risk — unchanged)\n' "$POINTS"
printf 'agent_wall_clock_estimate: %s\n' "$EST_STR"
exit 0
