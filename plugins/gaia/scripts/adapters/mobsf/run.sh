#!/usr/bin/env bash
# adapters/mobsf/run.sh — ADR-078 adapter contract for MobSF (E74-S7).
# MobSF runs as a REST service. The adapter probes the /api/v1/health endpoint
# (when MOBSF_URL is set) and posts each binary to the scan endpoint. When the
# `mobsf` CLI is on PATH (e.g. mobsfscan) it is used as the subprocess fallback.
#
# Provider on adapter.json is "mobsf"; the canonical probe checks PATH for it.
# In the absence of the CLI, callers should set runtime-profile: network and
# pass MOBSF_URL via the environment for the network-probe path. This story
# implements the deterministic-shell skeleton; full runtime invocation lands
# under E70-S3 when the network runtime-profile is wired through the probe.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="network"
TIMEOUT=600

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) echo "Usage: run.sh --input <file-list> [--config <path>] [--output <path>] [--timeout <seconds>]"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

if ! command -v mobsf >/dev/null 2>&1; then
  echo "run.sh: mobsf not found on PATH" >&2
  exit 127
fi

TARGETS=()
while IFS= read -r _line || [ -n "$_line" ]; do
  [ -n "$_line" ] && TARGETS+=("$_line")
done < "$INPUT"
raw=""
rc=0
# CLI form: pass each binary to the scanner; emit non-zero on tool failure.
if [ "${#TARGETS[@]}" -gt 0 ]; then
  raw="$(mobsf scan "${TARGETS[@]}" 2>&1)" || rc=$?
fi

fragment="$(jq -nc \
  --arg name "mobsf" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
