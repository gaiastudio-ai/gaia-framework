#!/usr/bin/env bash
# slo-check.sh — gaia-test-perf SLO evaluation (E73-S2, AC4 / AC7).
#
# Reads a perf-test scenarios spec and a normalized result document, evaluates
# each scenario's measured metrics against its declared SLOs, and emits a
# composite verdict (PASSED | REQUEST_CHANGES) on stdout.
#
# Inputs:
#   --config <path>   JSON file with shape {"scenarios": [
#                       {"name": "<id>", "adapter": "k6"|"lighthouse",
#                        "slos": { ...metric thresholds... }}, ...]}
#   --results <path>  JSON file with shape {"<scenario-name>": {<metric>: <num>}, ...}
#
# k6 SLOs:
#   p95_latency_ms (max), error_rate_max (max), min_rps (min)
# Lighthouse SLOs:
#   performance_score_min (min), lcp_ms_max (max), cls_max (max)
#
# Output (stdout, single JSON):
#   {
#     "composite": "PASSED" | "REQUEST_CHANGES",
#     "scenarios": [
#       {"name": "<id>", "verdict": "PASSED" | "REQUEST_CHANGES",
#        "breaches": [{"metric": "<name>", "actual": <num>, "threshold": <num>, "direction": "max"|"min"}]}
#       , ...]
#   }
#
# Exit codes:
#   0  evaluated successfully (verdict on stdout)
#   1  caller error (missing file/flag, malformed JSON)
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-perf/slo-check.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

CONFIG=""
RESULTS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --results) RESULTS="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — evaluate per-scenario SLOs and emit composite verdict.
Usage:
  slo-check.sh --config <scenarios.json> --results <metrics.json>
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$CONFIG" ] || die "--config required"
[ -n "$RESULTS" ] || die "--results required"
[ -r "$CONFIG" ] || die "config not readable: $CONFIG"
[ -r "$RESULTS" ] || die "results not readable: $RESULTS"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

jq -e . "$CONFIG" >/dev/null 2>&1 || die "config is not valid JSON"
jq -e . "$RESULTS" >/dev/null 2>&1 || die "results is not valid JSON"

# Per-scenario SLO check is implemented in jq for portability and determinism.
# The jq program below loads the scenarios array, joins each scenario with
# its measured metrics from $results, and emits the structured verdict.
output="$(jq -n \
  --slurpfile cfg "$CONFIG" \
  --slurpfile res "$RESULTS" \
  '
    def measured(name): ($res[0][name] // {});

    def check_max(actual; threshold; metric):
      if actual == null or threshold == null then empty
      elif actual > threshold then {metric: metric, actual: actual, threshold: threshold, direction: "max"}
      else empty
      end;

    def check_min(actual; threshold; metric):
      if actual == null or threshold == null then empty
      elif actual < threshold then {metric: metric, actual: actual, threshold: threshold, direction: "min"}
      else empty
      end;

    ($cfg[0].scenarios // []) as $scenarios |
    [
      $scenarios[] |
      . as $s |
      measured($s.name) as $m |
      ($s.slos // {}) as $slos |
      [
        check_max($m.p95_latency_ms; $slos.p95_latency_ms; "p95_latency_ms"),
        check_max($m.error_rate; $slos.error_rate_max; "error_rate"),
        check_min($m.rps; $slos.min_rps; "rps"),
        check_min($m.performance_score; $slos.performance_score_min; "performance_score"),
        check_max($m.lcp_ms; $slos.lcp_ms_max; "lcp_ms"),
        check_max($m.cls; $slos.cls_max; "cls")
      ] as $breaches |
      {
        name: $s.name,
        verdict: (if ($breaches | length) > 0 then "REQUEST_CHANGES" else "PASSED" end),
        breaches: $breaches
      }
    ] as $per_scenario |
    {
      composite: (if any($per_scenario[]; .verdict == "REQUEST_CHANGES") then "REQUEST_CHANGES" else "PASSED" end),
      scenarios: $per_scenario
    }
  '
)" || die "jq evaluation failed"

printf '%s\n' "$output"
exit 0
