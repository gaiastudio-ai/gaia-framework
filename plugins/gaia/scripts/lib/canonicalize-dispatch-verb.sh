#!/usr/bin/env bash
# canonicalize-dispatch-verb.sh — Project a dispatch-verb token onto its
# canonical primitive name (E88-S5, FR-DPD-5).
#
# Refs:  ADR-107 (taxonomy consumed via E88-S1; canonicalization is a
#        derivation, NOT a taxonomy itself per the story Dev Notes),
#        FR-DPD-5, AI-2026-05-13-7.
# Story: E88-S5.
#
# Usage
#   canonicalize-dispatch-verb.sh <verb>
#
# Behaviour
#   - Lowercase the verb; strip trailing inflection (s|ed|ing).
#   - Map to a primitive name via the canonical table:
#       spawn    -> Agent-tool spawn
#       dispatch -> Agent-tool dispatch
#       invoke   -> primitive invocation
#       wire     -> wiring
#       call     -> primitive call
#   - Defensive fallback: unknown stem -> "<verb> invocation".
#
# Exit codes
#   0 — canonical primitive emitted on stdout.
#   1 — usage error (missing arg).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="canonicalize-dispatch-verb.sh"
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "${2:-1}"; }

[[ $# -ge 1 ]] || die "usage: canonicalize-dispatch-verb.sh <verb>"

verb="$1"

# Lowercase + strip trailing inflection. Order: longest first.
# 'ing' covers gerunds. 'ed' covers past tense. Then `s`-suffix variants:
# 'es' applies only when the resulting stem ends in `ch|sh|s|x|z` (English
# orthography rule: `dispatches` -> `dispatch`, but `wires` -> `wire` not
# `wir`). Bare 's' covers the default singular-present.
verb="$(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]')"
case "$verb" in
  *ing)
    verb="${verb%ing}"
    ;;
  *ed)
    verb="${verb%ed}"
    ;;
  *ches|*shes|*ses|*xes|*zes)
    verb="${verb%es}"
    ;;
  *s)
    verb="${verb%s}"
    ;;
esac

case "$verb" in
  spawn)    printf 'Agent-tool spawn\n' ;;
  dispatch) printf 'Agent-tool dispatch\n' ;;
  invoke)   printf 'primitive invocation\n' ;;
  wire)     printf 'wiring\n' ;;
  call)     printf 'primitive call\n' ;;
  *)        printf '%s invocation\n' "$verb" ;;
esac
