#!/usr/bin/env bash
# adapters/owasp-dependency-check/run.sh — adapter contract for OWASP Dependency-Check.
#
# OWASP Dependency-Check adapter as alternative dep-audit under runtime-profile: container.
#
# Contract: run --input <file-list> [--config <adapter-config>] [--output <fragment.json>]
#               [--runtime-profile {subprocess|container|network}] [--timeout <seconds>]
#
# Phase-5 stub-real implementation: invokes the `owasp/dependency-check` container against
# the project root derived from the file list and emits a deterministic analysis-results
# fragment on stdout (or to --output if provided). Cross-stack scanner — supports Java,
# .NET, Node, Python, Ruby, Go via OWASP DC's analyzers; selection happens via
# project-config.yaml -> tools.dep-audit.provider: owasp-dependency-check.
#
# Exit code 0 = ran cleanly, 1 = scanner errored, 124/143 = timeout, 127 = docker not on
# PATH (mirrors the sonarqube precedent — distinct from generic error 1).
#
# Image and configuration are sourced from the environment:
#   ODC_IMAGE          — container image id (default: owasp/dependency-check:latest)
#   ODC_PROJECT_ROOT   — directory to scan (default: parent of the file list)
#   ODC_NVD_API_KEY    — optional NVD API key forwarded to the scanner
#
# Empty file lists short-circuit to an empty-findings success fragment without invoking
# docker. Timeout is enforced by the probe's `timeout(1)` wrapper externally; this script
# also wraps `docker run` in `timeout` defensively so direct invocations honour --timeout.
# On timeout, the docker container is killed via `docker kill` to prevent orphans.

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
adapters/owasp-dependency-check/run.sh — contract entry for OWASP Dependency-Check.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]

Environment:
  ODC_IMAGE         Container image id (default: owasp/dependency-check:latest)
  ODC_PROJECT_ROOT  Directory to scan (default: parent of --input file list)
  ODC_NVD_API_KEY   Optional NVD API key forwarded to the scanner
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

# Empty file list → exit 0 with empty findings (mirrors sonarqube precedent).
NONEMPTY_LINES="$(awk 'NF > 0 { c++ } END { print c+0 }' "$INPUT")"
if [ "$NONEMPTY_LINES" = "0" ]; then
  fragment="$(jq -nc \
    --arg name "owasp-dependency-check" \
    '{name: $name, status: "passed", findings: [], raw: ""}')"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$fragment" > "$OUTPUT"
  else
    printf '%s\n' "$fragment"
  fi
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "run.sh: docker not found on PATH (required for runtime-profile: container)" >&2
  # Exit 127 = unavailable (distinct from generic error 1).
  exit 127
fi

# Resolve scanner properties from environment with conservative defaults.
ODC_IMAGE="${ODC_IMAGE:-owasp/dependency-check:latest}"
# Default project root = directory containing the first non-empty file in the file list.
DEFAULT_ROOT="$(awk 'NF > 0 { print; exit }' "$INPUT")"
DEFAULT_ROOT_DIR="$(dirname "${DEFAULT_ROOT:-.}")"
ODC_PROJECT_ROOT="${ODC_PROJECT_ROOT:-$DEFAULT_ROOT_DIR}"

# Stage an output directory for the JSON report. Use mktemp -d for portability across
# macOS (BSD mktemp) and Linux (GNU mktemp).
ODC_OUTDIR="$(mktemp -d -t odc-XXXXXX)"
trap 'rm -rf "$ODC_OUTDIR" 2>/dev/null || true' EXIT

# Container name lets us issue `docker kill` on timeout to prevent orphans.
ODC_CONTAINER_NAME="gaia-odc-$$-$(date +%s)"

docker_args=(
  "run" "--rm" "--name" "$ODC_CONTAINER_NAME"
  "-v" "${ODC_PROJECT_ROOT}:/src:ro"
  "-v" "${ODC_OUTDIR}:/out"
)
if [ -n "${ODC_NVD_API_KEY:-}" ]; then
  docker_args+=("-e" "ODC_NVD_API_KEY=${ODC_NVD_API_KEY}")
fi
docker_args+=("$ODC_IMAGE" "--scan" "/src" "--format" "JSON" "--out" "/out")
if [ -n "${ODC_NVD_API_KEY:-}" ]; then
  docker_args+=("--nvdApiKey" "${ODC_NVD_API_KEY}")
fi
if [ -n "$CONFIG" ]; then
  # OWASP DC accepts a properties file via --propertyFile.
  docker_args+=("--propertyFile" "$CONFIG")
fi

# Pick the timeout binary: GNU coreutils 'timeout' on Linux; 'gtimeout' on macOS Homebrew.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# Start the scan. On timeout, kill the container by name to prevent orphans.
rc=0
if [ -n "$TIMEOUT_BIN" ]; then
  if "$TIMEOUT_BIN" --kill-after=5 "$TIMEOUT" docker "${docker_args[@]}" >/dev/null 2>"$ODC_OUTDIR/stderr.log"; then
    rc=0
  else
    rc=$?
    # Best-effort: kill the container by name if it's still alive.
    docker kill "$ODC_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
else
  if docker "${docker_args[@]}" >/dev/null 2>"$ODC_OUTDIR/stderr.log"; then
    rc=0
  else
    rc=$?
    docker kill "$ODC_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
fi

raw="$(tr -d '\r' < "$ODC_OUTDIR/stderr.log" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"

# Map timeout exit codes (124 = GNU timeout, 143 = SIGTERM) to errored state with a
# clear timeout message. Honours the run-contract.md §4 timeout enforcement contract.
if [ "$rc" = "124" ] || [ "$rc" = "143" ]; then
  raw="timeout: docker run exceeded ${TIMEOUT}s (container killed)"
fi

# Parse the OWASP DC JSON report into the canonical fragment shape per
# run-contract.md §2.1: {"name": <adapter>, "status": <passed|errored>, "findings": [...]}.
# Findings shape conforms to checks[].findings[] in analysis-results.schema.json.
# Each OWASP DC dependency.vulnerabilities[] entry becomes one finding keyed on the
# CVE identifier; severity maps from CVSS3.baseSeverity (CRITICAL/HIGH -> "error",
# MEDIUM -> "warning", LOW/INFO -> "info"). When the report is missing or unparseable,
# we emit a zero-findings fragment with the appropriate status (passed/errored).
report="$ODC_OUTDIR/dependency-check-report.json"
if [ "$rc" = "0" ] && [ -r "$report" ]; then
  findings_json="$(jq -c '
    [
      (.dependencies // [])[] as $d
      | ($d.vulnerabilities // [])[]
      | {
          file: ($d.fileName // ""),
          line: 0,
          severity: (
            (.cvssv3.baseSeverity // .severity // "")
            | ascii_downcase
            | if . == "critical" or . == "high" then "error"
              elif . == "medium" then "warning"
              else "info" end
          ),
          rule: (.name // .source // "CVE-UNKNOWN"),
          message: (.description // .name // "Unknown vulnerability"),
          blocking: ((.cvssv3.baseSeverity // .severity // "") | ascii_downcase
                     | (. == "critical" or . == "high")),
          cwe: ((.cwes // [])[0] // null)
        }
    ]
  ' "$report" 2>/dev/null || printf '[]')"
  status="passed"
else
  findings_json="[]"
  if [ "$rc" != "0" ]; then
    status="errored"
  else
    # rc=0 but no report file readable — still emit passed with empty findings to match
    # the run-contract: rc=0 means the adapter ran cleanly even if zero findings.
    status="passed"
  fi
fi

fragment="$(jq -nc \
  --arg name "owasp-dependency-check" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  --arg raw "$raw" \
  '{name: $name, status: $status, findings: $findings, raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
