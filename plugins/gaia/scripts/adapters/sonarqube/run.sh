#!/usr/bin/env bash
# adapters/sonarqube/run.sh — adapter contract for SonarQube.
#
# SonarQube adapter as alternative SAST under runtime-profile: container.
#
# Contract: run --input <file-list> [--config <adapter-config>] [--output <fragment.json>]
#               [--runtime-profile {subprocess|container|network}] [--timeout <seconds>]
#
# Phase-5 stub-real implementation: invokes `sonar-scanner` against the file list and
# emits a deterministic analysis-results fragment on stdout (or to --output if provided).
# Exit code 0 = ran cleanly, 1 = scanner errored, 127 = sonar-scanner not on PATH
# (distinct from generic error 1).
#
# Server URL, project key, and authentication token are sourced from the environment:
#   SONAR_HOST_URL    — defaults to http://localhost:9000
#   SONAR_PROJECT_KEY — defaults to "gaia-review"
#   SONAR_TOKEN       — required for authenticated scans (optional for anonymous)
# These env vars map to sonar-scanner's -Dsonar.host.url / -Dsonar.projectKey /
# -Dsonar.token properties. Empty file lists short-circuit to an empty-findings
# success fragment without invoking the scanner.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="container"
TIMEOUT=600

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/sonarqube/run.sh — contract entry for SonarQube.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]

Environment:
  SONAR_HOST_URL     SonarQube server URL (default: http://localhost:9000)
  SONAR_PROJECT_KEY  Project key registered with the server (default: gaia-review)
  SONAR_TOKEN        Authentication token (optional)
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

# Empty file list → exit 0 with empty findings (edge case).
NONEMPTY_LINES="$(awk 'NF > 0 { c++ } END { print c+0 }' "$INPUT")"
if [ "$NONEMPTY_LINES" = "0" ]; then
  fragment="$(jq -nc \
    --arg name "sonarqube" \
    '{name: $name, status: "passed", findings: [], raw: ""}')"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$fragment" > "$OUTPUT"
  else
    printf '%s\n' "$fragment"
  fi
  exit 0
fi

if ! command -v sonar-scanner >/dev/null 2>&1; then
  echo "run.sh: sonar-scanner not found on PATH" >&2
  # Exit 127 = unavailable (distinct from generic error 1).
  exit 127
fi

# Resolve scanner properties from environment with conservative defaults.
SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-gaia-review}"

# Derive sources arg from the file-list — sonar-scanner accepts a comma-separated
# list of source paths via -Dsonar.sources.
sources_csv="$(awk 'NF > 0 { printf "%s%s", sep, $0; sep="," }' "$INPUT")"

scanner_args=(
  "-Dsonar.host.url=${SONAR_HOST_URL}"
  "-Dsonar.projectKey=${SONAR_PROJECT_KEY}"
  "-Dsonar.sources=${sources_csv}"
)
if [ -n "${SONAR_TOKEN:-}" ]; then
  scanner_args+=("-Dsonar.token=${SONAR_TOKEN}")
fi
if [ -n "$CONFIG" ]; then
  scanner_args+=("-Dproject.settings=${CONFIG}")
fi

raw="$(sonar-scanner "${scanner_args[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Emit canonical analysis-results fragment shape per run-contract.md §2.1:
# {"name": <adapter>, "status": <passed|errored>, "findings": [...]}.
# Findings shape conforms to checks[].findings[] in analysis-results.schema.json.
# This stub-real implementation does not yet parse SonarQube's report JSON into
# canonical findings — that's a future enhancement; the raw output is preserved
# in the `raw` field so callers can introspect the scanner output.
fragment="$(jq -nc \
  --arg name "sonarqube" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
