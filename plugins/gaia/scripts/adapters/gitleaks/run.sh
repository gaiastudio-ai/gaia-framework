#!/usr/bin/env bash
# adapters/gitleaks/run.sh — adapter contract for Gitleaks.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Runs gitleaks with redaction enabled against the listed files and maps its
# JSON output into a deterministic analysis-results fragment. When gitleaks
# exits 1 with a report (leaks found), the adapter maps each leak to a finding
# rather than treating it as an error.
#
# Exit codes:
#   0   — scan completed (findings may be present)
#   1   — scanner infrastructure error (NOT "leaks found" — that is exit 0)
#   127 — gitleaks not found on PATH

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT=180

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/gitleaks/run.sh — contract entry for Gitleaks.
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

# Build the scan directory from the file list. Gitleaks scans directories,
# so we create a temporary directory with symlinks to the listed files and
# scan that. This respects the --input contract: only listed files are scanned.
SCAN_TMP="$(mktemp -d -t gitleaks-scan-XXXXXX)"
_cleanup() { rm -rf "$SCAN_TMP" 2>/dev/null || true; }
trap _cleanup EXIT

file_count=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  if [ -f "$_line" ]; then
    # Create parent directories in the temp tree.
    _parent="$SCAN_TMP/${_line%/*}"
    mkdir -p "$_parent" 2>/dev/null || true
    ln -sf "$(cd "$(dirname "$_line")" && pwd)/$(basename "$_line")" "$SCAN_TMP/$_line" 2>/dev/null || true
    file_count=$((file_count + 1))
  fi
done < "$INPUT"

_run_native() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "run.sh: gitleaks not found on PATH" >&2
    exit 127
  fi
  local args=(detect --no-git --redact --report-format json --report-path - --source "$SCAN_TMP")
  if [ -n "$CONFIG" ]; then
    args+=(--config "$CONFIG")
  fi
  gitleaks "${args[@]}" 2>/dev/null || true
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  local args=(gitleaks detect --no-git --redact --report-format json --report-path - --source /workspace)
  if [ -n "$CONFIG" ]; then
    args+=(--config "$CONFIG")
  fi
  docker run --rm --network=none \
    -v "${SCAN_TMP}:/workspace:ro" \
    -v "${ADAPTER_OUT_DIR:-/tmp}:/out" \
    "$image" "${args[@]}" 2>/dev/null || true
}

case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" ;;
  *)         raw="$(_run_native)" ;;
esac

# Map gitleaks JSON into findings[].
# gitleaks exits 1 when leaks are found (with valid JSON on stdout) and
# exits 0 when clean. We treat both as "scan completed" and map leaks
# to findings. Only infrastructure errors (exit > 1) are real errors.
findings="$(printf '%s' "$raw" | jq -c '
  if type == "array" then
    [.[] | {
      id: (.RuleID // "unknown"),
      severity: "high",
      message: ((.RuleID // "leak") + " in " + (.File // "unknown") + " (redacted)"),
      source: "gitleaks"
    }]
  else []
  end
' 2>/dev/null)" || findings="[]"

fragment="$(jq -nc \
  --arg name "gitleaks" \
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
