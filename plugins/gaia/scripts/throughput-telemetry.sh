#!/usr/bin/env bash
# throughput-telemetry.sh — agent-native throughput derivation layer
#
# Reads `.gaia/memory/lifecycle-events.jsonl` `state_transition` events, groups
# them by `story_key`, and DERIVES per-story wall-clock by differencing the
# first and last transition timestamps (there is NO `duration` field on the
# events — it is derived). Joins story points from a sprint yaml to produce
# per-sprint median minutes/story and minutes/point. Median (not mean) is used
# to resist outliers (one stalled story must not skew throughput).
#
# This is the telemetry-first foundation of the agent-native estimation model:
# dual-track estimation and agent-native SM capacity check consume the medians
# derived here.
#
# READ-ONLY: this script NEVER writes any artifact, config, or state file.
# Output is produced exclusively on stdout.
#
#
# Invocation:
#   throughput-telemetry.sh --events <jsonl> [--sprint-yaml <yaml>] [--json]
#   throughput-telemetry.sh --help
#
# Environment:
#   LIFECYCLE_EVENTS    default events path (overridden by --events)
#   SPRINT_STATUS_YAML  default sprint yaml (overridden by --sprint-yaml)
#   MAX_BYTES           bounded tail read of the events log (default 5242880)
#
# Exit codes:
#   0 — derived successfully (possibly empty)
#   1 — bad args, or events file missing/unreadable

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="throughput-telemetry.sh"
MAX_BYTES="${MAX_BYTES:-5242880}"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
throughput-telemetry.sh — derive agent throughput from lifecycle-events.jsonl

Usage:
  throughput-telemetry.sh --events <jsonl> [--sprint-yaml <yaml>] [--json]

Derives per-story wall-clock by differencing consecutive state_transition
timestamps, then emits median minutes/story and minutes/point per sprint.
Median resists outliers. READ-ONLY — writes nothing; output on stdout.

Options:
  --events <path>       lifecycle-events.jsonl to read (or $LIFECYCLE_EVENTS)
  --sprint-yaml <path>  sprint-status.yaml for the points join (or $SPRINT_STATUS_YAML)
  --archive-dir <dir>   sprint-archive dir of closed-sprint yamls (extra points join)
  --story-dir <dir>     scan story-file frontmatter for points (fallback join)
  --json                emit a JSON object instead of the text report
  --help                this help
USAGE
  exit 0
fi

EVENTS="${LIFECYCLE_EVENTS:-}"
SPRINT_YAML="${SPRINT_STATUS_YAML:-}"
ARCHIVE_DIR=""
STORY_DIR=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --events) EVENTS="${2:-}"; shift 2 ;;
    --sprint-yaml) SPRINT_YAML="${2:-}"; shift 2 ;;
    --archive-dir) ARCHIVE_DIR="${2:-}"; shift 2 ;;
    --story-dir) STORY_DIR="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$EVENTS" ] || die "no events file given (--events or \$LIFECYCLE_EVENTS)"
[ -e "$EVENTS" ] || die "events file not found: $EVENTS"
[ -r "$EVENTS" ] || die "events file not readable: $EVENTS"

# ---------- Points join (story_key -> points) ----------
# Note: the active sprint-status.yaml only carries the CURRENT sprint's stories,
# so closed-sprint medians need points from elsewhere.
# We build the join from (in precedence order, first hit wins per key):
#   1. each --sprint-yaml (active or archived) `stories:` block, and
#   2. an optional --archive-dir of sprint-*.yaml files (closed sprints), and
#   3. an optional --story-dir scanned for story-file frontmatter `points:`.
# The story's T2 explicitly allows "sprint-status.yaml / story frontmatter".

# awk that reads a sprint yaml `stories:` block -> "key<TAB>points" rows.
sprint_points_awk='
  /^stories:[[:space:]]*$/ { in_stories=1; next }
  in_stories && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
    line=$0
    sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", line)
    gsub(/"/, "", line)
    cur=line
    next
  }
  in_stories && /^[[:space:]]+points:[[:space:]]*/ {
    line=$0
    sub(/^[[:space:]]+points:[[:space:]]*/, "", line)
    gsub(/[^0-9].*$/, "", line)
    if (cur != "" && line != "") printf "%s\t%s\n", cur, line
    next
  }
  in_stories && /^[^[:space:]]/ { in_stories=0 }
'

POINTS_TSV=""

# Collect candidate sprint yamls (active first, then any archived sprint yamls),
# emit their `stories:` block points rows inline — no named helper (keeps the
# script free of additional public functions under the coverage gate).
YAML_LIST=""
[ -n "$SPRINT_YAML" ] && [ -r "$SPRINT_YAML" ] && YAML_LIST="$SPRINT_YAML"
if [ -n "$ARCHIVE_DIR" ] && [ -d "$ARCHIVE_DIR" ]; then
  for y in "$ARCHIVE_DIR"/*.yaml; do
    [ -e "$y" ] || continue
    YAML_LIST="${YAML_LIST}
${y}"
  done
fi
if [ -n "$YAML_LIST" ]; then
  while IFS= read -r y; do
    [ -n "$y" ] && [ -r "$y" ] || continue
    rows="$(awk "$sprint_points_awk" "$y")"
    [ -n "$rows" ] && POINTS_TSV="${POINTS_TSV}${rows}
"
  done <<EOF
$YAML_LIST
EOF
fi

if [ -n "$STORY_DIR" ] && [ -d "$STORY_DIR" ]; then
  # scan story-file frontmatter: a file with `key:` and `points:` in its
  # frontmatter contributes one row. Bounded to the first 40 lines per file.
  story_rows="$(
    find "$STORY_DIR" -type f -name '*.md' 2>/dev/null | while IFS= read -r sf; do
      head -40 "$sf" | awk '
        /^key:[[:space:]]*/ { k=$2; gsub(/"/,"",k) }
        /^points:[[:space:]]*/ { p=$2; gsub(/[^0-9].*$/,"",p) }
        END { if (k!="" && p!="") printf "%s\t%s\n", k, p }
      '
    done
  )"
  [ -n "$story_rows" ] && POINTS_TSV="${POINTS_TSV}${story_rows}
"
fi

# de-dup: keep the FIRST points value seen per key (yaml precedence over story-dir)
if [ -n "$POINTS_TSV" ]; then
  POINTS_TSV="$(printf '%s' "$POINTS_TSV" | awk -F'\t' 'NF==2 && !seen[$1]++')"
fi

# ---------- Derivation ----------
# Bounded tail read of the event log. Parse state_transition events into
# `story_key <TAB> epoch` rows (jq when available, awk fallback otherwise),
# then group by key, difference first..last epoch -> wall-clock minutes.
# Stories with < 2 transitions are skipped-with-note; stories with no events
# never appear in the stream and so are excluded from the median.

iso_to_epoch_awk='
  function iso2epoch(ts,    y,mo,d,h,mi,s,days,leap,i,mdays,total) {
    # ts like 2026-05-01T10:00:00.000Z  -> UTC epoch seconds
    y =substr(ts,1,4)+0;  mo=substr(ts,6,2)+0; d=substr(ts,9,2)+0
    h =substr(ts,12,2)+0; mi=substr(ts,15,2)+0; s=substr(ts,18,2)+0
    split("31 28 31 30 31 30 31 31 30 31 30 31", mdays, " ")
    days=0
    for (i=1970; i<y; i++) { leap=((i%4==0&&i%100!=0)||i%400==0); days += leap?366:365 }
    for (i=1; i<mo; i++) { days += mdays[i]; if (i==2 && ((y%4==0&&y%100!=0)||y%400==0)) days++ }
    days += d-1
    total = days*86400 + h*3600 + mi*60 + s
    return total
  }
'

# Produce: story_key <TAB> epoch   (one row per state_transition, time-ordered as read)
if command -v jq >/dev/null 2>&1; then
  ROWS="$(head -c "$MAX_BYTES" "$EVENTS" \
    | jq -r 'select(.event_type=="state_transition") | "\(.story_key)\t\(.timestamp)"' 2>/dev/null \
    | awk -F'\t' "$iso_to_epoch_awk"'{ print $1 "\t" iso2epoch($2) }')"
else
  ROWS="$(head -c "$MAX_BYTES" "$EVENTS" \
    | awk "$iso_to_epoch_awk"'
      /"event_type":"state_transition"/ {
        key=""; ts=""
        if (match($0, /"story_key":"[^"]*"/)) { key=substr($0,RSTART+13,RLENGTH-14) }
        if (match($0, /"timestamp":"[^"]*"/)) { ts=substr($0,RSTART+13,RLENGTH-14) }
        if (key!="" && ts!="") printf "%s\t%s\n", key, iso2epoch(ts)
      }')"
fi

# Group: per story_key, min & max epoch + transition count.
# Wall-clock = max-min (first in-progress .. final done span),
# so a review->in-progress->review loop never double-counts.
group_awk='
  NF==2 {
    k=$1; e=$2+0
    cnt[k]++
    if (!(k in mn) || e<mn[k]) mn[k]=e
    if (!(k in mx) || e>mx[k]) mx[k]=e
  }
  END {
    for (k in cnt) printf "%s\t%d\t%d\t%d\n", k, cnt[k], mn[k], mx[k]
  }
'
GROUPED="$(printf '%s\n' "$ROWS" | awk -F'\t' "$group_awk" | sort)"

# Build per-story wall-clock minutes + skip notes + minutes/point.
STORY_LINES=""
SKIP_LINES=""
STORY_MINUTES=""   # newline list of per-story minutes (counted only)
POINT_MINUTES=""   # newline list of per-story minutes/point (counted only, points>0)

while IFS=$'\t' read -r k cnt mn mx; do
  [ -n "$k" ] || continue
  if [ "$cnt" -lt 2 ]; then
    SKIP_LINES="${SKIP_LINES}${k}\tskip: insufficient transitions (count=${cnt}) — note recorded\n"
    continue
  fi
  minutes=$(( (mx - mn) / 60 ))
  pts=""
  if [ -n "$POINTS_TSV" ]; then
    pts="$(printf '%s\n' "$POINTS_TSV" | awk -F'\t' -v key="$k" '$1==key{print $2; exit}')"
  fi
  if [ -n "$pts" ] && [ "$pts" -gt 0 ] 2>/dev/null; then
    mpp=$(( minutes / pts ))
    STORY_LINES="${STORY_LINES}${k}\t${minutes} min\t${pts} pts\t${mpp} min/pt\n"
    POINT_MINUTES="${POINT_MINUTES}${mpp}\n"
  else
    STORY_LINES="${STORY_LINES}${k}\t${minutes} min\t(no points)\n"
  fi
  STORY_MINUTES="${STORY_MINUTES}${minutes}\n"
done < <(printf '%s\n' "$GROUPED")

# ---------- Median helper ----------
median() {
  # reads newline-separated integers on stdin, prints integer median (avg of
  # two middle values for even N, floored). Empty input -> empty output.
  awk '
    /^[0-9]+$/ { v[n++]=$1 }
    END {
      if (n==0) { exit }
      # sort
      for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (v[j]<v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
      if (n%2==1) print v[(n-1)/2]
      else print int((v[n/2-1]+v[n/2])/2)
    }
  '
}

MED_STORY="$(printf '%b' "$STORY_MINUTES" | median)"
MED_POINT="$(printf '%b' "$POINT_MINUTES" | median)"
COUNTED="$(printf '%b' "$STORY_MINUTES" | grep -cE '^[0-9]+$' || true)"

# ---------- Output ----------
if [ "$JSON_OUT" -eq 1 ]; then
  # Build JSON via jq for safety.
  jq -n \
    --argjson med_story "${MED_STORY:-null}" \
    --argjson med_point "${MED_POINT:-null}" \
    --argjson counted "${COUNTED:-0}" \
    '{median_minutes_per_story: $med_story, median_minutes_per_point: $med_point, stories_counted: $counted}'
  exit 0
fi

printf 'throughput-telemetry — derived from %s\n' "$EVENTS"
[ -n "$SPRINT_YAML" ] && printf 'points joined from: %s\n' "$SPRINT_YAML"
printf '\n'
if [ -n "${MED_STORY}" ]; then
  printf 'median_minutes_per_story: %s\n' "$MED_STORY"
else
  printf 'median_minutes_per_story: (no data)\n'
fi
if [ -n "${MED_POINT}" ]; then
  printf 'median_minutes_per_point: %s\n' "$MED_POINT"
else
  printf 'median_minutes_per_point: (no data)\n'
fi
printf 'stories_counted: %s\n' "${COUNTED:-0}"
printf '\nPer-story wall-clock:\n'
if [ -n "$STORY_LINES" ]; then
  printf '%b' "$STORY_LINES" | sed 's/^/  /'
else
  printf '  (none)\n'
fi
if [ -n "$SKIP_LINES" ]; then
  printf '\nSkipped (recorded notes):\n'
  printf '%b' "$SKIP_LINES" | sed 's/^/  /'
fi
exit 0
