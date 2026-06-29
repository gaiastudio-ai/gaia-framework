#!/usr/bin/env bash
# adapters/gosec/run.sh — adapter contract for gosec (Go SAST).
#
# Contract: run --input <file-list> --config <adapter-config> --output <fragment.json>
#               --runtime-profile {subprocess|container|network} --timeout {seconds}
#
# Invokes `gosec -fmt=json` against the Go packages covering the file list and
# emits a deterministic analysis-results fragment on stdout (or to --output if
# provided). Exit code 0 = ran cleanly, 1 = scanner errored, 127 = tool absent.
# The probe interprets exit-code semantics. Mirrors the sibling semgrep adapter.

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
adapters/gosec/run.sh — contract entry for gosec.
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

# Read targets (.go files) from the file-list line by line.
# bash 3.2-compat replacement for mapfile.
TARGETS=()
while IFS= read -r _line; do [ -n "$_line" ] && TARGETS+=("$_line"); done < "$INPUT"

if ! command -v gosec >/dev/null 2>&1; then
  echo "run.sh: gosec not found on PATH — install via 'go install github.com/securego/gosec/v2/cmd/gosec@latest'" >&2
  # Exit 127 = unavailable (distinct from generic error 1), matching the
  # sibling semgrep/sonarqube tool-unavailable contract.
  exit 127
fi

# gosec scans Go *packages* (directories), not bare files. Derive the unique
# set of directories from the .go targets so gosec receives valid package args.
GOSEC_DIRS=()
_seen_dirs=$'\n'
for _t in "${TARGETS[@]}"; do
  _d="$(dirname "$_t")"
  case "$_seen_dirs" in
    *$'\n'"$_d"$'\n'*) : ;;
    *) _seen_dirs="${_seen_dirs}${_d}"$'\n'; GOSEC_DIRS+=("$_d") ;;
  esac
done
# Fallback: if no targets resolved a directory, scan the current tree.
[ "${#GOSEC_DIRS[@]}" -gt 0 ] || GOSEC_DIRS=("./...")

gosec_args=(-quiet -fmt=json)
[ -n "$CONFIG" ] && gosec_args+=(-conf "$CONFIG")

raw="$(gosec "${gosec_args[@]}" "${GOSEC_DIRS[@]}" 2>&1)" || rc=$? || true
rc="${rc:-0}"

# Emit canonical analysis-results fragment shape per run-contract.md §2.1:
# {"name": <adapter>, "status": <passed|errored>, "findings": [...]}.
fragment="$(jq -nc \
  --arg name "gosec" \
  --argjson rc "$rc" \
  --arg raw "$raw" \
  '{name: $name, status: (if $rc == 0 then "passed" else "errored" end), findings: [], raw: $raw}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
