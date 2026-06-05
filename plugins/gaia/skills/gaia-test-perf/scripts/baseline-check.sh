#!/usr/bin/env bash
# baseline-check.sh — gaia-test-perf baseline regression detection.
#
# Compares the current scenario p95 latency against the stored baseline at
# {baseline-dir}/{scenario}.json. If the degradation exceeds --threshold
# (percent, default 20), reports regression: true. When no baseline exists,
# the current run establishes the baseline and reports regression: false.
#
# Inputs:
#   --scenario <name>          scenario id matching the key in --results
#   --results <path>            JSON {"<scenario>": {<metric>: <num>}}
#   --baseline-dir <path>       directory storing per-scenario baselines
#                               (default: .gaia/perf-baselines/)
#   --threshold <pct>           percent degradation triggering regression
#                               (default: 20)
#   --update-on-pass            when set, write current metrics as new baseline
#                               (used post-verdict by the skill body)
#
# Output (stdout, single JSON):
#   {
#     "scenario": "<name>",
#     "regression": true|false,
#     "baseline_established": true|false,
#     "degradation_pct": <num>,
#     "baseline": {<metric>: <num>}|null,
#     "current": {<metric>: <num>}|null
#   }
#
# Exit codes:
#   0   computed successfully (regression status on stdout)
#   1   caller error
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-perf/baseline-check.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

SCENARIO=""
RESULTS=""
BASELINE_DIR=".gaia/perf-baselines"
THRESHOLD=20
UPDATE_ON_PASS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --results) RESULTS="$2"; shift 2 ;;
    --baseline-dir) BASELINE_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --update-on-pass) UPDATE_ON_PASS=1; shift ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — detect p95 regression vs stored baseline.
Usage:
  baseline-check.sh --scenario <name> --results <path>
                    [--baseline-dir <path>] [--threshold <pct>] [--update-on-pass]
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$SCENARIO" ] || die "--scenario required"
[ -n "$RESULTS" ] || die "--results required"
[ -r "$RESULTS" ] || die "results not readable: $RESULTS"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

jq -e . "$RESULTS" >/dev/null 2>&1 || die "results is not valid JSON"

# Extract current metrics for the scenario.
current="$(jq -c --arg s "$SCENARIO" '.[$s] // null' "$RESULTS")"
if [ "$current" = "null" ]; then
  die "scenario '$SCENARIO' not present in results"
fi

baseline_file="$BASELINE_DIR/$SCENARIO.json"

if [ ! -r "$baseline_file" ]; then
  # First run — establish baseline.
  mkdir -p "$BASELINE_DIR"
  printf '%s\n' "$current" > "$baseline_file"
  jq -n \
    --arg s "$SCENARIO" \
    --argjson cur "$current" \
    '{scenario: $s, regression: false, baseline_established: true, degradation_pct: 0, baseline: null, current: $cur}'
  exit 0
fi

jq -e . "$baseline_file" >/dev/null 2>&1 || die "baseline file is not valid JSON: $baseline_file"

baseline="$(jq -c '.' "$baseline_file")"

# Compute p95 degradation pct using jq for portable arithmetic.
result_json="$(jq -n \
  --arg s "$SCENARIO" \
  --argjson base "$baseline" \
  --argjson cur "$current" \
  --argjson thr "$THRESHOLD" \
  '
    ($base.p95_latency_ms // 0) as $bp |
    ($cur.p95_latency_ms // 0) as $cp |
    (if $bp > 0 then (($cp - $bp) / $bp) * 100 else 0 end) as $deg |
    {
      scenario: $s,
      regression: ($deg >= $thr),
      baseline_established: false,
      degradation_pct: $deg,
      baseline: $base,
      current: $cur
    }
  ')"

printf '%s\n' "$result_json"

# Optionally write new baseline when run passed.
if [ "$UPDATE_ON_PASS" = "1" ]; then
  reg="$(printf '%s' "$result_json" | jq -r '.regression')"
  if [ "$reg" = "false" ]; then
    printf '%s\n' "$current" > "$baseline_file"
    log "baseline updated for scenario=$SCENARIO"
  fi
fi

exit 0
