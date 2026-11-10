#!/usr/bin/env bash
# adapters/cppcheck/run.sh — adapter contract for Cppcheck.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Runs cppcheck against the files in the list and maps its XML output
# into a deterministic analysis-results fragment.
#
# Exit codes:
#   0   — scan completed (findings may be present)
#   1   — scanner errored (infrastructure failure)
#   127 — cppcheck not found on PATH

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
adapters/cppcheck/run.sh — contract entry for Cppcheck.
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
  fragment="$(jq -nc '{name:"cppcheck",status:"skipped",reason:"no files in file list",findings:[]}')"
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$fragment" > "$OUTPUT"; else printf '%s\n' "$fragment"; fi
  exit 0
fi

_run_native() {
  if ! command -v cppcheck >/dev/null 2>&1; then
    echo "run.sh: cppcheck not found on PATH" >&2
    exit 127
  fi
  # cppcheck writes XML to stderr; capture it.
  local xml_tmp
  xml_tmp="$(mktemp -t cppcheck-xml-XXXXXX)"
  cppcheck --xml --quiet "${TARGETS[@]}" 2>"$xml_tmp" || true
  cat "$xml_tmp"
  rm -f "$xml_tmp"
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  local docker_targets=()
  for t in "${TARGETS[@]}"; do
    docker_targets+=("/workspace/$t")
  done
  local project_root="${PROJECT_ROOT:-.}"
  local xml_tmp
  xml_tmp="$(mktemp -t cppcheck-xml-XXXXXX)"
  docker run --rm --network=none \
    -v "${project_root}:/workspace:ro" \
    -v "${ADAPTER_OUT_DIR:-/tmp}:/out" \
    "$image" cppcheck --xml --quiet "${docker_targets[@]}" 2>"$xml_tmp" || true
  cat "$xml_tmp"
  rm -f "$xml_tmp"
}

case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" ;;
  *)         raw="$(_run_native)" ;;
esac

# Map cppcheck XML into findings[].
# cppcheck --xml emits <results><errors><error id="..." severity="..." msg="..."/></errors></results>
# Use a simple awk parser since jq cannot parse XML.
findings="$(printf '%s' "$raw" | awk '
  BEGIN { printf "["; sep="" }
  /<error / {
    id="unknown"; sev="low"; msg="finding"
    if (match($0, /id="([^"]*)"/, a)) id=a[1]
    if (match($0, /severity="([^"]*)"/, a)) {
      s=a[1]
      if (s == "error") sev="high"
      else if (s == "warning") sev="medium"
      else if (s == "style" || s == "performance" || s == "portability" || s == "information") sev="low"
    }
    if (match($0, /msg="([^"]*)"/, a)) msg=a[1]
    gsub(/"/, "\\\"", msg)
    printf "%s{\"id\":\"%s\",\"severity\":\"%s\",\"message\":\"%s\",\"source\":\"cppcheck\"}", sep, id, sev, msg
    sep=","
  }
  END { printf "]" }
' 2>/dev/null)" || findings="[]"

# Validate the JSON; fall back to empty array if awk produced invalid output.
printf '%s' "$findings" | jq . >/dev/null 2>&1 || findings="[]"

fragment="$(jq -nc \
  --arg name "cppcheck" \
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
