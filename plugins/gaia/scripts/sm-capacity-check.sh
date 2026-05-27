#!/usr/bin/env bash
# sm-capacity-check.sh — agent-native sprint capacity check (E106-S3)
#
# Replaces the human "N points is too much for the duration" heuristic (which
# false-flagged the 73-point sprint-53 sweep) with three agent-native measures
# from ADR-128:
#   (1) dependency critical-path DEPTH  — longest serial chain over Depends-on
#   (2) context-coherence CEILING       — distinct story count in the batch
#   (3) measured agent WALL-CLOCK       — median minutes/story (E106-S1) × N
#                                          vs a configured agent-session budget;
#                                          telemetry-gated (stories_counted>0).
# Cold start (no closed-sprint telemetry) uses ONLY (1)+(2) — no fabricated
# constant (AC4 / NFR-90). There is NO points-per-time / velocity-floor measure.
#
# Reads measured throughput from throughput-telemetry.sh (SSOT; ADR-042).
# READ-ONLY — output on stdout.
#
# Refs: AC1-AC5, AC-INT1, TS1-TS6, ADR-128, ADR-042, NFR-90, FR-552
#
# Invocation:
#   sm-capacity-check.sh --stories-file <file> [--depth-threshold N]
#       [--coherence-ceiling N] [--session-budget-min N]
#       [--events <jsonl>] [--sprint-yaml <yaml>] [--json]
#   sm-capacity-check.sh --help
#
# --stories-file format: one story per line, `KEY|DEP1,DEP2,...|POINTS`
#   (deps and points may be empty; deps are comma-separated story keys).
#
# Exit codes:
#   0 — evaluated (flagged or not — flag state is in the output, not the exit)
#   1 — bad arguments

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="sm-capacity-check.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TELEMETRY="$SCRIPT_DIR/throughput-telemetry.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
sm-capacity-check.sh — agent-native sprint capacity check

Usage:
  sm-capacity-check.sh --stories-file <file> [--depth-threshold N]
      [--coherence-ceiling N] [--session-budget-min N]
      [--events <jsonl>] [--sprint-yaml <yaml>] [--json]

Evaluates three agent-native measures — dependency critical-path depth,
context-coherence ceiling, and (telemetry-gated) measured agent wall-clock vs an
agent-session budget. NO points-per-calendar-time heuristic. Cold start uses
depth + coherence only, with no fabricated constant. READ-ONLY; output on stdout.

--stories-file lines: KEY|DEP1,DEP2,...|POINTS
USAGE
  exit 0
fi

STORIES_FILE=""
DEPTH_THRESHOLD=5
COHERENCE_CEILING=15
SESSION_BUDGET_MIN=480
EVENTS=""
SPRINT_YAML="${SPRINT_STATUS_YAML:-}"
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stories-file) STORIES_FILE="${2:-}"; shift 2 ;;
    --depth-threshold) DEPTH_THRESHOLD="${2:-5}"; shift 2 ;;
    --coherence-ceiling) COHERENCE_CEILING="${2:-15}"; shift 2 ;;
    --session-budget-min) SESSION_BUDGET_MIN="${2:-480}"; shift 2 ;;
    --events) EVENTS="${2:-}"; shift 2 ;;
    --sprint-yaml) SPRINT_YAML="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$STORIES_FILE" ] || die "--stories-file is required (try --help)"
[ -r "$STORIES_FILE" ] || die "stories file not found/readable: $STORIES_FILE"

# ---------- Measure 1: dependency critical-path depth ----------
# Longest serial chain over Depends-on, computed with memoised DFS in awk.
# Cycles are broken defensively (a node on the current stack contributes its
# partial depth, never an infinite loop).
DEPTH_AWK='
  BEGIN { FS="|" }
  {
    key=$1
    gsub(/^[ \t]+|[ \t]+$/, "", key)
    if (key=="") next
    keys[key]=1
    deps[key]=$2   # comma-separated dependency keys
  }
  END {
    for (k in keys) {
      d=depth(k)
      if (d>maxd) maxd=d
    }
    print maxd
  }
  function depth(k,   n,i,arr,best,dd) {
    if (k=="" || !(k in keys)) return 0
    if (k in memo) return memo[k]
    if (k in onstack) return 1          # cycle guard
    onstack[k]=1
    best=0
    n=split(deps[k], arr, ",")
    for (i=1;i<=n;i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", arr[i])
      if (arr[i]=="") continue
      dd=depth(arr[i])
      if (dd>best) best=dd
    }
    delete onstack[k]
    memo[k]=best+1
    return memo[k]
  }
'
CRITICAL_PATH_DEPTH="$(awk "$DEPTH_AWK" "$STORIES_FILE")"
[ -n "$CRITICAL_PATH_DEPTH" ] || CRITICAL_PATH_DEPTH=0

# ---------- Measure 2: context-coherence ceiling (distinct story count) ----------
COHERENCE_COUNT="$(awk -F'|' '{k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k); if (k!="") c[k]=1} END{n=0; for (x in c) n++; print n}' "$STORIES_FILE")"
[ -n "$COHERENCE_COUNT" ] || COHERENCE_COUNT=0

# ---------- Measure 3: measured wall-clock (telemetry-gated) ----------
# Cold start = no closed-sprint telemetry (stories_counted==0 / median null).
# Reuse the E106-S2 lesson: gate on stories_counted>0, never on a 0 median.
WALL_CLOCK_MEASURE="uncalibrated"
WALL_CLOCK_MINUTES="null"
WALL_CLOCK_FLAGGED=false
if [ -n "$EVENTS" ] && [ -r "$EVENTS" ] && [ -x "$TELEMETRY" ]; then
  tele_args=(--events "$EVENTS" --json)
  [ -n "$SPRINT_YAML" ] && tele_args+=(--sprint-yaml "$SPRINT_YAML")
  tele="$(bash "$TELEMETRY" "${tele_args[@]}" 2>/dev/null || true)"
  if [ -n "$tele" ]; then
    mps="$(printf '%s' "$tele" | jq -r '.median_minutes_per_story // "null"' 2>/dev/null || echo null)"
    counted="$(printf '%s' "$tele" | jq -r '.stories_counted // 0' 2>/dev/null || echo 0)"
    if [ "$counted" -gt 0 ] 2>/dev/null && [ "$mps" != "null" ] && [ -n "$mps" ]; then
      WALL_CLOCK_MEASURE="measured"
      WALL_CLOCK_MINUTES=$(( mps * COHERENCE_COUNT ))
      if [ "$WALL_CLOCK_MINUTES" -gt "$SESSION_BUDGET_MIN" ]; then WALL_CLOCK_FLAGGED=true; fi
    fi
  fi
fi

# ---------- Per-measure flags + composite ----------
DEPTH_FLAGGED=false
[ "$CRITICAL_PATH_DEPTH" -gt "$DEPTH_THRESHOLD" ] && DEPTH_FLAGGED=true
COHERENCE_FLAGGED=false
[ "$COHERENCE_COUNT" -gt "$COHERENCE_CEILING" ] && COHERENCE_FLAGGED=true

FLAGGED=false
if [ "$DEPTH_FLAGGED" = true ] || [ "$COHERENCE_FLAGGED" = true ] || [ "$WALL_CLOCK_FLAGGED" = true ]; then
  FLAGGED=true
fi

# ---------- Output ----------
if [ "$JSON_OUT" -eq 1 ]; then
  jq -n \
    --argjson depth "$CRITICAL_PATH_DEPTH" \
    --argjson depth_th "$DEPTH_THRESHOLD" \
    --argjson coh "$COHERENCE_COUNT" \
    --argjson coh_ceil "$COHERENCE_CEILING" \
    --arg wc_measure "$WALL_CLOCK_MEASURE" \
    --argjson wc_min "$WALL_CLOCK_MINUTES" \
    --argjson budget "$SESSION_BUDGET_MIN" \
    --argjson depth_flagged "$DEPTH_FLAGGED" \
    --argjson coh_flagged "$COHERENCE_FLAGGED" \
    --argjson wc_flagged "$WALL_CLOCK_FLAGGED" \
    --argjson flagged "$FLAGGED" \
    '{
      critical_path_depth: $depth, depth_threshold: $depth_th, depth_flagged: $depth_flagged,
      coherence_count: $coh, coherence_ceiling: $coh_ceil, coherence_flagged: $coh_flagged,
      wall_clock_measure: $wc_measure, wall_clock_minutes: $wc_min,
      session_budget_min: $budget, wall_clock_flagged: $wc_flagged,
      flagged: $flagged
    }'
  exit 0
fi

printf 'agent-native sprint capacity check\n\n'
printf 'measure 1 — dependency critical-path depth: %s (threshold %s) %s\n' \
  "$CRITICAL_PATH_DEPTH" "$DEPTH_THRESHOLD" "$([ "$DEPTH_FLAGGED" = true ] && echo '[FLAGGED — chain exceeds threshold]' || echo 'ok')"
printf 'measure 2 — context-coherence count: %s (ceiling %s) %s\n' \
  "$COHERENCE_COUNT" "$COHERENCE_CEILING" "$([ "$COHERENCE_FLAGGED" = true ] && echo '[FLAGGED — batch exceeds ceiling]' || echo 'ok')"
if [ "$WALL_CLOCK_MEASURE" = "measured" ]; then
  printf 'measure 3 — measured wall-clock: %s min (session budget %s) %s\n' \
    "$WALL_CLOCK_MINUTES" "$SESSION_BUDGET_MIN" "$([ "$WALL_CLOCK_FLAGGED" = true ] && echo '[FLAGGED — over session budget]' || echo 'ok')"
else
  printf 'measure 3 — measured wall-clock: uncalibrated (no closed-sprint telemetry — cold start, depth+coherence only)\n'
fi
printf '\ncapacity: %s\n' "$([ "$FLAGGED" = true ] && echo 'FLAGGED (one or more agent-native measures exceeded)' || echo 'ok (within agent-native capacity)')"
exit 0
