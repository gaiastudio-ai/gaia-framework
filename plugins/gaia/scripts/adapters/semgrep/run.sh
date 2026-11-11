#!/usr/bin/env bash
# adapters/semgrep/run.sh — adapter contract for Semgrep.
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Invokes semgrep --json against the file list (natively or through the
# docker runner) and emits a deterministic analysis-results fragment.
# Exit code 0 = ran cleanly, 1 = scanner errored. The probe interprets
# exit-code semantics.

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
adapters/semgrep/run.sh — contract entry for Semgrep.
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

# Read targets from the file-list line by line (bash 3.2-compat).
TARGETS=()
while IFS= read -r _line; do [ -n "$_line" ] && TARGETS+=("$_line"); done < "$INPUT"

_run_native() {
  if ! command -v semgrep >/dev/null 2>&1; then
    echo "run.sh: semgrep not found on PATH" >&2
    exit 127
  fi
  local args=(--json --quiet --metrics=off)
  if [ -n "$CONFIG" ]; then
    args+=(--config "$CONFIG")
  else
    args+=(--config "p/default")
  fi
  semgrep "${args[@]}" -- "${TARGETS[@]}" 2>/dev/null
}

_run_docker() {
  local image="${GAIA_TOOLS_IMAGE:-ghcr.io/gaiastudio-ai/gaia-tools:latest}"
  if [ -z "$CONFIG" ]; then
    # Semgrep rules are not baked into the image (moved to a separate story).
    # Without baked rules, docker mode with --network=none cannot fetch from
    # the registry and must not do an empty pass. Fail explicitly.
    echo "run.sh: semgrep rules are not baked into the image; docker mode requires baked rules or an explicit --config path" >&2
    exit 1
  fi
  local args=(semgrep --json --quiet --metrics=off --config "$CONFIG")
  local docker_targets=()
  for t in "${TARGETS[@]}"; do
    docker_targets+=("/workspace/$t")
  done
  local code_root; code_root="$(pwd)"
  docker run --rm --network=none \
    -v "${code_root}:/workspace:ro" \
    "$image" "${args[@]}" -- "${docker_targets[@]}" 2>/dev/null
}

rc=0
case "$RUNTIME_PROFILE" in
  container) raw="$(_run_docker)" || rc=$? ;;
  *)         raw="$(_run_native)" || rc=$? ;;
esac

# Map semgrep JSON into findings[].
# semgrep --json exits 0 with findings present; the results object is
# {"results": [...], "errors": [...]}.
findings="$(printf '%s' "$raw" | jq -c '
  [(.results // [])[] | {
    id: (.check_id // "unknown"),
    severity: (if (.extra.severity // "WARNING") == "ERROR" then "high"
               elif (.extra.severity // "WARNING") == "WARNING" then "medium"
               else "low" end),
    message: ((.check_id // "finding") + ": " + (.extra.message // "issue detected") +
              " at " + (.path // "unknown") + ":" + ((.start.line // 0) | tostring)),
    source: "semgrep"
  }]
' 2>/dev/null)" || findings="[]"
[ -n "$findings" ] || findings="[]"

# Emit canonical analysis-results fragment.
fragment="$(jq -nc \
  --arg name "semgrep" \
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
