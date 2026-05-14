#!/usr/bin/env bash
# load-taxonomy.sh — Closed-list taxonomy loader per ADR-107.
#
# Refs:  ADR-107 (loading contract + SSOT), ADR-106 (production-callsite rule),
#        AF-2026-05-14-6 (origin assessment).
# Story: E88-S1.
#
# Production callsites (per ADR-106 rule #4):
#   - plugins/gaia/scripts/lib/dispatch-verb-match.sh
#   - plugins/gaia/scripts/lib/deferral-phrase-match.sh
#   - plugins/gaia/tests/taxonomy-ssot-audit.bats (SSOT audit; iterates both names)
#
# Usage
#   load-taxonomy.sh --taxonomy <deferral|dispatch> [--as-grep-file]
#
#   --taxonomy NAME    Required. One of: deferral, dispatch.
#   --as-grep-file     Optional. Emit a tempfile path on stdout containing
#                      the taxonomy entries one-per-line (comments + blanks
#                      stripped, trailing whitespace trimmed), suitable for
#                      `grep -wFf <path>`. Caller is responsible for `rm -f`.
#
# Default mode emits the taxonomy entries one-per-line on stdout.
# Unknown taxonomy -> exit 1 with stderr enumerating valid names.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="load-taxonomy.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

TAXONOMY=""
GREP_FILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --taxonomy)
      [[ $# -ge 2 ]] || die "missing value for --taxonomy"
      TAXONOMY="$2"
      shift 2
      ;;
    --as-grep-file)
      GREP_FILE=1
      shift
      ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$TAXONOMY" ]] || die "missing required flag: --taxonomy <deferral|dispatch>"

# Resolve the directory containing this script via BASH_SOURCE; supports
# both sourced and standalone invocation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAXONOMY_DIR="$SCRIPT_DIR/../../knowledge/taxonomy"

case "$TAXONOMY" in
  deferral)
    FILE="$TAXONOMY_DIR/deferral-phrases.txt"
    ;;
  dispatch)
    FILE="$TAXONOMY_DIR/dispatch-verbs.txt"
    ;;
  *)
    die "unknown taxonomy \"$TAXONOMY\"; valid names: deferral, dispatch"
    ;;
esac

[[ -f "$FILE" ]] || die "taxonomy file not found: $FILE"

# Strip comments (lines starting with '#'), strip blank lines, trim trailing
# whitespace. Output is one canonical entry per line.
emit_entries() {
  grep -vE '^[[:space:]]*(#|$)' "$FILE" | sed 's/[[:space:]]*$//'
}

if [[ "$GREP_FILE" -eq 1 ]]; then
  TMPFILE="$(mktemp "${TMPDIR:-/tmp}/taxonomy.XXXXXX")"
  emit_entries > "$TMPFILE"
  printf '%s\n' "$TMPFILE"
else
  emit_entries
fi
