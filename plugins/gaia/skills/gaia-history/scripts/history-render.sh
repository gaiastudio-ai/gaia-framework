#!/usr/bin/env bash
# history-render.sh — read-only project-history renderer for /gaia-history
#
# Surfaces three views, all read-only:
#   1. Velocity trend across the last N closed sprints (from sprint-archive yamls).
#   2. Estimate accuracy — estimated points vs. measured throughput
#      (delegates to throughput-telemetry.sh for the measured median).
#   3. Recurring-finding patterns from retro docs ("What Could Improve" themes
#      that appear across more than one retro).
#
# READ-ONLY: writes nothing; output is produced exclusively on stdout. The skill
# that invokes this (gaia-history) declares allowed-tools: [Read, Bash].
#
# Invocation:
#   history-render.sh [--archive-dir <dir>] [--retros-dir <dir>]
#                     [--events <jsonl>] [--sprint-yaml <yaml>] [--last-n <N>]
#   history-render.sh --help
#
# Exit codes:
#   0 — rendered (possibly empty-history mode)
#   1 — bad arguments

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="history-render.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
TELEMETRY="$PLUGIN_SCRIPTS_DIR/throughput-telemetry.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
history-render.sh — read-only project-history dashboard for /gaia-history

Usage:
  history-render.sh [--archive-dir <dir>] [--retros-dir <dir>]
                    [--events <jsonl>] [--sprint-yaml <yaml>] [--last-n <N>]

Renders velocity trend, estimate accuracy, and recurring-finding patterns.
READ-ONLY — writes nothing; output on stdout.
USAGE
  exit 0
fi

ARCHIVE_DIR=""
RETROS_DIR=""
EVENTS=""
SPRINT_YAML=""
LAST_N=5

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-dir) ARCHIVE_DIR="${2:-}"; shift 2 ;;
    --retros-dir) RETROS_DIR="${2:-}"; shift 2 ;;
    --events) EVENTS="${2:-}"; shift 2 ;;
    --sprint-yaml) SPRINT_YAML="${2:-}"; shift 2 ;;
    --last-n) LAST_N="${2:-5}"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

printf '# Project History (/gaia-history)\n\n'

# ---------- 1. Velocity trend ----------
printf '## Velocity Trend (last %s closed sprints)\n\n' "$LAST_N"
if [ -n "$ARCHIVE_DIR" ] && [ -d "$ARCHIVE_DIR" ]; then
  # newest-last by filename (sprint-archive names carry the close date), keep last N
  archives="$(ls -1 "$ARCHIVE_DIR"/*.yaml 2>/dev/null | sort | tail -n "$LAST_N" || true)"
  if [ -n "$archives" ]; then
    printf '| Sprint | Total Points |\n|--------|--------------|\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sid="$(awk -F'"' '/^sprint_id:/{print $2; exit}' "$f")"
      [ -n "$sid" ] || sid="$(awk '/^sprint_id:/{print $2; exit}' "$f" | tr -d '"')"
      tp="$(awk '/^total_points:/{print $2; exit}' "$f" | tr -d '"')"
      printf '| %s | %s |\n' "${sid:-?}" "${tp:-?}"
    done <<EOF
$archives
EOF
    printf '\n'
  else
    printf '_(no closed sprints archived yet)_\n\n'
  fi
else
  printf '_(no sprint-archive directory — no history yet)_\n\n'
fi

# ---------- 2. Estimate accuracy ----------
printf '## Estimate Accuracy (estimated vs measured)\n\n'
if [ -n "$EVENTS" ] && [ -r "$EVENTS" ] && [ -x "$TELEMETRY" ]; then
  tele_args=(--events "$EVENTS")
  [ -n "$SPRINT_YAML" ] && tele_args+=(--sprint-yaml "$SPRINT_YAML")
  measured="$(bash "$TELEMETRY" "${tele_args[@]}" 2>/dev/null || true)"
  mps="$(printf '%s\n' "$measured" | awk -F': *' '/median_minutes_per_story:/{print $2; exit}')"
  mpp="$(printf '%s\n' "$measured" | awk -F': *' '/median_minutes_per_point:/{print $2; exit}')"
  printf 'Measured throughput (derived from lifecycle-events):\n'
  printf -- '- median minutes/story: %s\n' "${mps:-(no data)}"
  printf -- '- median minutes/point: %s\n' "${mpp:-(no data)}"
  printf '\nEstimate accuracy compares each sprint'\''s estimated points against this\n'
  printf 'measured minutes/point baseline — a stable minutes/point means estimates\n'
  printf 'track measured agent throughput.\n\n'
else
  printf '_(no lifecycle-events log available — measured throughput unavailable)_\n\n'
fi

# ---------- 3. Recurring-finding patterns ----------
printf '## Recurring Finding Patterns (from retros)\n\n'
if [ -n "$RETROS_DIR" ] && [ -d "$RETROS_DIR" ]; then
  # Extract "What Could Improve" bullet themes across all retros; a theme that
  # appears in >1 retro is flagged as recurring. We key on the bold lead-in
  # (text between the first pair of ** **) or, failing that, the bullet text.
  themes="$(
    for f in "$RETROS_DIR"/*.md; do
      [ -f "$f" ] || continue
      awk '
        /^##[[:space:]]+What Could Improve/ { grab=1; next }
        /^##[[:space:]]/ && grab { grab=0 }
        grab && /^[[:space:]]*-[[:space:]]/ {
          line=$0
          # prefer the bolded lead-in
          if (match(line, /\*\*[^*]+\*\*/)) {
            t=substr(line, RSTART+2, RLENGTH-4)
          } else {
            t=line; sub(/^[[:space:]]*-[[:space:]]*/, "", t)
          }
          # normalize: lowercase, collapse spaces, trim trailing punctuation
          gsub(/[.,:;!?]+$/, "", t)
          print tolower(t)
        }
      ' "$f"
    done
  )"
  if [ -n "$themes" ]; then
    # count distinct themes; flag those appearing more than once as recurring
    recurring="$(printf '%s\n' "$themes" | sort | uniq -c | sort -rn | awk '$1>1{$1=$1; print}')"
    if [ -n "$recurring" ]; then
      printf 'Themes appearing across more than one retro:\n\n'
      printf '%s\n' "$recurring" | while IFS= read -r row; do
        cnt="$(printf '%s' "$row" | awk '{print $1}')"
        theme="$(printf '%s' "$row" | sed 's/^[[:space:]]*[0-9]\{1,\}[[:space:]]*//')"
        printf -- '- **recurring (%sx):** %s\n' "$cnt" "$theme"
      done
      printf '\n'
    else
      printf '_(no theme recurs across multiple retros yet)_\n\n'
    fi
  else
    printf '_(no "What Could Improve" findings parsed)_\n\n'
  fi
else
  printf '_(no retros directory — no recurring patterns yet)_\n\n'
fi

exit 0
