#!/usr/bin/env bash
# format-candidates.sh — discovery candidate formatter for /gaia-create-ux.
#
# Reads a JSON array of design-system candidates from stdin. Each candidate
# must carry at minimum: id, name, last_modified. Emits a formatted
# presentation on stdout showing all three fields per candidate.
#
# The output is a human-readable presentation, not a binding directive.
# A single candidate is formatted identically to multiple — the framework
# never auto-binds.
#
# Script exposes no reusable public functions — the top-level flow is the
# entire API. Public-function coverage guard is N/A.
#
# Usage:
#   echo '<json>' | format-candidates.sh
#
# Exit codes:
#   0 — formatted successfully
#   1 — malformed input or no candidates

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="format-candidates.sh"

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

# Read stdin and validate once — reuse the parsed output for both the
# count check and the formatted emission.
INPUT="$(cat)"
[ -n "$INPUT" ] || _die "no input on stdin"

PARSED="$(printf '%s' "$INPUT" | jq '.' 2>/dev/null)" || _die "malformed JSON on stdin"

COUNT="$(printf '%s' "$PARSED" | jq 'length')"
[ "$COUNT" -gt 0 ] || _die "no candidates in input"

printf '%s' "$PARSED" | jq -r '.[] | "  id:            \(.id)\n  name:          \(.name)\n  last_modified:  \(.last_modified)\n"'
