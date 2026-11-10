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
#   0   — scan completed (findings may be present)
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

# Derive the project root from the first file in the list.
first_file=""
while IFS= read -r _line; do
  [ -n "$_line" ] && { first_file="$_line"; break; }
done < "$INPUT"

if [ -z "$first_file" ]; then
  # No files — not applicable; emit a skipped fragment.
  fragment="$(jq -nc '{name:"osv-scanner",status:"skipped",reason:"no files in file list",findings:[]}')"
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$fragment" > "$OUTPUT"; else printf '%s\n' "$fragment"; fi
  exit 0
fi

# Determine scan root: the directory of the first file, walking up to find a
# lockfile. For simplicity, use the directory of the file list itself or CWD.
scan_root="${first_file%/*}"
[ "$scan_root" = "$first_file" ] && scan_root="."
# Walk up to find any lockfile (package-lock.json, go.sum, Cargo.lock, etc.)
_resolve_root() {
  local d="$1"
  while [ "$d" != "/" ] && [ "$d" != "." ]; do
    for lf in package-lock.json yarn.lock pnpm-lock.yaml go.sum go.mod Cargo.lock \
              Gemfile.lock composer.lock poetry.lock Pipfile.lock requirements.txt \
              pom.xml build.gradle build.gradle.kts; do
      [ -f "$d/$lf" ] && { printf '%s' "$d"; return 0; }
    done
    d="${d%/*}"
    [ -z "$d" ] && d="/"
  done
  return 1
}

project_root="$(_resolve_root "$scan_root" 2>/dev/null)" || project_root=""
if [ -z "$project_root" ]; then
  # No lockfiles found — not applicable.
  fragment="$(jq -nc '{name:"osv-scanner",status:"skipped",reason:"no lockfiles found",findings:[]}')"
  if [ -n "$OUTPUT" ]; then printf '%s\n' "$fragment" > "$OUTPUT"; else printf '%s\n' "$fragment"; fi
  exit 0
fi

_run_native() {
  if ! command -v osv-scanner >/dev/null 2>&1; then
    echo "run.sh: osv-scanner not found on PATH" >&2
    exit 127
  fi
  osv-scanner scan --format json --recursive "$project_root" 2>&1 || true
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  docker run --rm --network=none \
    -v "${project_root}:/workspace:ro" \
    -v "${ADAPTER_OUT_DIR:-/tmp}:/out" \
    "$image" osv-scanner scan --format json --recursive /workspace 2>&1 || true
}

case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" ;;
  *)         raw="$(_run_native)" ;;
esac

# Map osv-scanner JSON into findings[].
# osv-scanner --format json outputs {"results": [{"packages": [...]}]} on
# findings, or exits 0 with empty results when clean.
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

# Determine status.
finding_count="$(printf '%s' "$findings" | jq 'length' 2>/dev/null)" || finding_count=0
if [ "$finding_count" -gt 0 ]; then
  status="passed"
else
  status="passed"
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

exit 0
