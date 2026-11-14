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
# so we create a temporary directory with the listed files and scan that.
# This respects the --input contract: only listed files are scanned.
# In container mode, files are copied (symlinks dangle inside the container).
# In native mode, files are symlinked for efficiency.
SCAN_TMP="$(mktemp -d -t gitleaks-scan-XXXXXX)"
REPORT_TMP="$(mktemp -t gitleaks-report-XXXXXX.json)"
_cleanup() { rm -rf "$SCAN_TMP" "$REPORT_TMP" 2>/dev/null || true; }
trap _cleanup EXIT

_use_copy="false"
[ "$RUNTIME_PROFILE" = "container" ] && _use_copy="true"

file_count=0
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  if [ -f "$_line" ]; then
    # Use parameter expansion instead of dirname/basename to avoid
    # treating leading-dash filenames as options.
    case "$_line" in
      */*) _dir_part="${_line%/*}"; _base_part="${_line##*/}" ;;
      *)   _dir_part="."; _base_part="$_line" ;;
    esac
    _parent="$SCAN_TMP/$_dir_part"
    mkdir -p "$_parent" 2>/dev/null || true
    if [ "$_use_copy" = "true" ]; then
      cp -- "$_line" "$SCAN_TMP/$_line" 2>/dev/null || continue
    else
      # Resolve the source to an absolute path for the symlink target.
      _abs_dir="$(cd -- "$_dir_part" 2>/dev/null && pwd)" || continue
      ln -sf "${_abs_dir}/${_base_part}" "$SCAN_TMP/$_line" 2>/dev/null || true
    fi
    file_count=$((file_count + 1))
  fi
done < "$INPUT"

_run_native() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "run.sh: gitleaks not found on PATH" >&2
    exit 127
  fi
  local gl_rc=0
  local args=(detect --no-git --redact --follow-symlinks --report-format json --report-path "$REPORT_TMP" --source "$SCAN_TMP")
  if [ -n "$CONFIG" ]; then
    args+=(--config "$CONFIG")
  fi
  gitleaks "${args[@]}" 2>/dev/null || gl_rc=$?
  # gitleaks exits 1 = leaks found (with a valid report), 0 = clean.
  # Any other exit code is a real infrastructure error.
  if [ "$gl_rc" -eq 0 ] || [ "$gl_rc" -eq 1 ]; then
    if [ -f "$REPORT_TMP" ]; then
      cat "$REPORT_TMP"
    else
      echo "[]"
    fi
    return 0
  else
    echo "run.sh: gitleaks exited $gl_rc" >&2
    return "$gl_rc"
  fi
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  local gl_rc=0
  local args=(gitleaks detect --no-git --redact --follow-symlinks --report-format json --report-path /out/report.json --source /workspace)
  if [ -n "$CONFIG" ]; then
    args+=(--config "$CONFIG")
  fi
  local out_tmp; out_tmp="$(mktemp -d -t gitleaks-docker-out-XXXXXX)"
  docker run --rm --network=none \
    -v "${SCAN_TMP}:/workspace:ro" \
    -v "${out_tmp}:/out" \
    "$image" "${args[@]}" 2>/dev/null || gl_rc=$?
  if [ "$gl_rc" -eq 0 ] || [ "$gl_rc" -eq 1 ]; then
    if [ -f "$out_tmp/report.json" ]; then
      cat "$out_tmp/report.json"
    else
      echo "[]"
    fi
    rm -rf "$out_tmp"
    return 0
  else
    rm -rf "$out_tmp"
    echo "run.sh: gitleaks (docker) exited $gl_rc" >&2
    return "$gl_rc"
  fi
}

rc=0
case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" || rc=$? ;;
  *)         raw="$(_run_native)" || rc=$? ;;
esac

# Map gitleaks JSON into findings[].
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
[ -n "$findings" ] || findings="[]"

fragment="$(jq -nc \
  --arg name "gitleaks" \
  --argjson rc "$rc" \
  --argjson findings "$findings" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: $findings, raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
