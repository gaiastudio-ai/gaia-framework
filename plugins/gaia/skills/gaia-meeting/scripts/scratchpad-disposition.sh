#!/usr/bin/env bash
# scratchpad-disposition.sh — gaia-meeting close-time disposition validator
#
# Validates a single CLOSE-phase disposition value as one of:
#   Extract | Keep | Drop  (case-insensitive; "Keep in notes only" also accepted)
#
# Usage:
#   scratchpad-disposition.sh --check <value>     # echo lower-cased canonical, exit 0
#   scratchpad-disposition.sh --prompt            # render the canonical three-option prompt
#
# Exit codes:
#   0 = accepted (canonical lowercase emitted to stdout, or prompt emitted)
#   2 = rejected (unknown / empty)

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<'USAGE'
Usage:
  scratchpad-disposition.sh --check <value>
  scratchpad-disposition.sh --prompt
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

case "$1" in
  --prompt)
    cat <<'PROMPT'
Choose a disposition for this scratchpad item:
  1) Extract             — write a permanent extracted file
  2) Keep in notes only  — record in meeting notes, no extracted file
  3) Drop                — discard from notes and do not extract
PROMPT
    exit 0
    ;;
  --check)
    if [[ $# -lt 2 ]]; then
      usage
      exit 2
    fi
    val="$2"
    # Normalize to lowercase
    norm="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
    # Strip trailing whitespace
    norm="${norm%"${norm##*[![:space:]]}"}"
    case "$norm" in
      extract) printf 'extract\n'; exit 0 ;;
      keep|"keep in notes only") printf 'keep\n'; exit 0 ;;
      drop) printf 'drop\n'; exit 0 ;;
      *) exit 2 ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac
