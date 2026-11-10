#!/usr/bin/env bash
# adapters/osv-scanner/run.sh — adapter contract for OSV-Scanner.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Runs osv-scanner against the project root (derived from the file list) and
# maps its JSON output into a deterministic analysis-results fragment.
#
# Exit codes:
#   0   — scan completed (findings may be present), or not_applicable
#   1   — scanner errored (not "findings found" — that is exit 0)
#   127 — osv-scanner not found on PATH

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
adapters/osv-scanner/run.sh — contract entry for OSV-Scanner.
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

# Known lockfiles that osv-scanner can consume.
_lockfile_names="package-lock.json yarn.lock pnpm-lock.yaml go.sum go.mod Cargo.lock Gemfile.lock composer.lock poetry.lock Pipfile.lock requirements.txt pom.xml build.gradle build.gradle.kts"

# Collect unique parent directories of every listed file, plus the repo root
# (first entry's ancestor). Walk up from each to find a lockfile.
_found_root=""
_seen_dirs=""

_has_lockfile() {
  local dir="$1"
  local lf
  for lf in $_lockfile_names; do
    [ -f "$dir/$lf" ] && return 0
  done
  return 1
}

# Read the file list and search for a directory containing a lockfile.
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  # Get the directory of this file. Handle root-level files (no /).
  local_dir="${_line%/*}"
  [ "$local_dir" = "$_line" ] && local_dir="."

  # Walk up from local_dir to the repo root ("."), checking each directory
  # for lockfiles. The loop must always reach "." even for single-component
  # paths like "src" (where ${d%/*} == d without a slash).
  d="$local_dir"
  while true; do
    if _has_lockfile "$d"; then
      _found_root="$d"
      break
    fi
    # Already at the root — stop.
    if [ "$d" = "." ]; then
      break
    fi
    parent="${d%/*}"
    # Single-component (no slash) or empty → move to root ".".
    if [ "$parent" = "$d" ] || [ -z "$parent" ]; then
      d="."
    else
      d="$parent"
    fi
  done
  [ -n "$_found_root" ] && break
done < "$INPUT"

if [ -z "$_found_root" ]; then
  # No lockfiles found — not applicable. Emit a status fragment.
  fragment="$(jq -nc '{name:"osv-scanner",status:"not_applicable",reason:"no lockfiles found",findings:[]}')"
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$fragment" > "$OUTPUT"; else printf '%s\n' "$fragment"; fi
  exit 0
fi

project_root="$_found_root"

_run_native() {
  if ! command -v osv-scanner >/dev/null 2>&1; then
    echo "run.sh: osv-scanner not found on PATH" >&2
    exit 127
  fi
  local osv_rc=0
  # Capture stderr separately to avoid merging progress output into JSON.
  osv-scanner scan --format json --recursive -- "$project_root" 2>/dev/null || osv_rc=$?
  return "$osv_rc"
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  local osv_rc=0
  docker run --rm --network=none \
    -v "${project_root}:/workspace:ro" \
    "$image" osv-scanner scan --format json --recursive -- /workspace 2>/dev/null || osv_rc=$?
  return "$osv_rc"
}

rc=0
case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" || rc=$? ;;
  *)         raw="$(_run_native)" || rc=$? ;;
esac

# osv-scanner exits 1 when vulnerabilities are found, 0 when clean.
# Exit > 1 is an infrastructure error. Treat 1 as "ran, findings present".
scanner_errored=false
if [ "$rc" -gt 1 ]; then
  scanner_errored=true
elif [ "$rc" -eq 1 ]; then
  # rc 1 = vulnerabilities found (not an error).
  rc=0
fi

# Map osv-scanner JSON into findings[].
findings="$(printf '%s' "$raw" | jq -c '
  [(.results // [])[] | (.packages // [])[] |
   (.vulnerabilities // [])[] |
   {
     id: (.id // "unknown"),
     severity: (if (.database_specific.severity // "MODERATE") == "CRITICAL" then "critical"
                elif (.database_specific.severity // "MODERATE") == "HIGH" then "high"
                elif (.database_specific.severity // "MODERATE") == "MODERATE" then "medium"
                else "low" end),
     message: (.summary // .id // "vulnerability detected"),
     source: "osv-scanner"
   }]
' 2>/dev/null)" || findings="[]"
[ -n "$findings" ] || findings="[]"

if [ "$scanner_errored" = "true" ]; then
  status="errored"
  exit_rc=1
else
  status="passed"
  exit_rc=0
fi

fragment="$(jq -nc \
  --arg name "osv-scanner" \
  --arg status "$status" \
  --argjson findings "$findings" \
  --arg raw "$raw" \
  '{name: $name, status: $status, findings: $findings, raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$exit_rc"
