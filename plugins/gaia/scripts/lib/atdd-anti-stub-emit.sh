#!/usr/bin/env bash
# atdd-anti-stub-emit.sh — Emit anti-stub Then-clauses for AC bodies that
# contain dispatch verbs.
#
# Usage
#   atdd-anti-stub-emit.sh --ac-text "<ac body>"
#
# Behaviour
#   - Sources dispatch-verb-match.sh to detect dispatch verbs.
#   - For each unique canonical primitive (via canonicalize-dispatch-verb.sh),
#     emit one anti-stub Then-clause: 'Then: $*_STUB env vars are unset AND
#     a real <primitive> was logged'.
#   - Duplicates suppressed (case-insensitive, primitive-level dedup).
#   - Empty stdout when no dispatch verbs match.
#
# Exit codes
#   0 — always (helper is additive, never gating).
#   1 — usage error (missing flag).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="atdd-anti-stub-emit.sh"
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "${2:-1}"; }

AC_TEXT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ac-text)
      [[ $# -ge 2 ]] || die "missing value for --ac-text"
      AC_TEXT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$AC_TEXT" ]] || die "missing required flag: --ac-text <body>"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./dispatch-verb-match.sh
. "$SCRIPT_DIR/dispatch-verb-match.sh"

CANON="$SCRIPT_DIR/canonicalize-dispatch-verb.sh"
[[ -x "$CANON" ]] || die "canonicalize-dispatch-verb.sh not found or not executable"

# Match dispatch verbs in the AC body. The matcher emits one matched verb
# per line on stdout (deduped raw-token-level). We then canonicalize each
# match and dedup at the primitive level.
matched="$(match_dispatch_verb_in_text "$AC_TEXT" 2>/dev/null || true)"
[[ -z "$matched" ]] && exit 0

# Walk matched verbs; emit one clause per unique primitive in first-seen order.
declare -a seen=()
while IFS= read -r verb; do
  [[ -z "$verb" ]] && continue
  primitive="$("$CANON" "$verb")"
  # Dedup by primitive (case-insensitive equality is moot since the canon
  # script returns a deterministic literal).
  dup=0
  for prev in "${seen[@]+"${seen[@]}"}"; do
    [[ "$prev" = "$primitive" ]] && { dup=1; break; }
  done
  [[ "$dup" -eq 1 ]] && continue
  seen+=("$primitive")
  printf 'Then: $*_STUB env vars are unset AND a real %s was logged\n' "$primitive"
done <<<"$matched"

exit 0
