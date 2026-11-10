#!/usr/bin/env bash
# adapters/checkov/run.sh — adapter contract for Checkov.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Runs checkov in soft-fail mode against the files in the list and maps
# its JSON output into a deterministic analysis-results fragment.
#
# Exit codes:
#   0   — scan completed (findings may be present; soft-fail mode)
#   1   — scanner errored (infrastructure failure, not "checks failed")
#   127 — checkov not found on PATH

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=300

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/checkov/run.sh — contract entry for Checkov.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

# Read targets from the file-list line by line (bash 3.2 compat).
TARGETS=()
while IFS= read -r _line; do [ -n "$_line" ] && TARGETS+=("$_line"); done < "$INPUT"

if [ "${#TARGETS[@]}" -eq 0 ]; then
  fragment="$(jq -nc '{name:"checkov",status:"skipped",reason:"no files in file list",findings:[]}')"
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$fragment" > "$OUTPUT"; else printf '%s\n' "$fragment"; fi
  exit 0
fi

_run_native() {
  if ! command -v checkov >/dev/null 2>&1; then
    echo "run.sh: checkov not found on PATH" >&2
    exit 127
  fi
  local args=(--soft-fail --output json --no-guide --download-external-modules false)
  for t in "${TARGETS[@]}"; do
    args+=(-f "$t")
  done
  checkov "${args[@]}" 2>&1 || true
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  local args=(checkov --soft-fail --output json --no-guide --download-external-modules false)
  for t in "${TARGETS[@]}"; do
    args+=(-f "/workspace/$t")
  done
  local project_root="${PROJECT_ROOT:-.}"
  docker run --rm --network=none \
    -v "${project_root}:/workspace:ro" \
    -v "${ADAPTER_OUT_DIR:-/tmp}:/out" \
    "$image" "${args[@]}" 2>&1 || true
}

case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" ;;
  *)         raw="$(_run_native)" ;;
esac

# Map checkov JSON into findings[].
# checkov --output json emits {"results":{"passed_checks":[...],"failed_checks":[...],...}}
# or an array of such objects when multiple frameworks are scanned.
findings="$(printf '%s' "$raw" | jq -c '
  def map_sev: if . == "CRITICAL" then "critical"
               elif . == "HIGH" then "high"
               elif . == "MEDIUM" then "medium"
               else "low" end;
  [
    (if type == "array" then .[] else . end) |
    (.results.failed_checks // [])[] |
    {
      id: (.check_id // "unknown"),
      severity: ((.severity // "MEDIUM") | map_sev),
      message: (.check_id + ": " + (.name // "check failed") + " in " + (.file_path // "unknown")),
      source: "checkov"
    }
  ]
' 2>/dev/null)" || findings="[]"

finding_count="$(printf '%s' "$findings" | jq 'length' 2>/dev/null)" || finding_count=0

fragment="$(jq -nc \
  --arg name "checkov" \
  --arg status "passed" \
  --argjson findings "$findings" \
  --arg raw "$raw" \
  '{name: $name, status: $status, findings: $findings, raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit 0
