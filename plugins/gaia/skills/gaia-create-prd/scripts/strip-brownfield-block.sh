#!/usr/bin/env bash
# strip-brownfield-block.sh — remove the BROWNFIELD-ONLY block from a PRD.
#
# Test05 F-007. The PRD template carries a
#   <!-- BROWNFIELD-ONLY-START --> ... <!-- BROWNFIELD-ONLY-END -->
# block that is only relevant when the PRD documents an EXISTING codebase. On a
# greenfield PRD it is dead boilerplate that authors had to remember to delete by
# hand. This helper strips the block (and its fence comments) deterministically
# and idempotently, atomically (tmp + mv).
#
# It is OPT-IN: nothing auto-invokes it for every PRD (auto-stripping on a
# brownfield PRD would delete needed content, and there is no reliable
# greenfield/brownfield config signal at finalize time). The /gaia-create-prd
# greenfield flow calls it explicitly; brownfield flows leave the block.
#
# Usage:
#   strip-brownfield-block.sh <prd-file>
#   strip-brownfield-block.sh --help
#
# Exit codes:
#   0 — block stripped, OR no block present (idempotent no-op)
#   1 — usage / file error
#   2 — malformed block (START without matching END)

set -euo pipefail
SCRIPT_NAME="strip-brownfield-block.sh"
err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { err "$*"; exit "${2:-1}"; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
strip-brownfield-block.sh — remove the BROWNFIELD-ONLY block from a greenfield PRD

Usage: strip-brownfield-block.sh <prd-file>

Removes everything from "<!-- BROWNFIELD-ONLY-START -->" through
"<!-- BROWNFIELD-ONLY-END -->" (inclusive). Idempotent: a no-op when the block
is absent. Opt-in — call only on greenfield PRDs.
USAGE
  exit 0
fi

PRD="${1:-}"
[ -n "$PRD" ] || die "usage: strip-brownfield-block.sh <prd-file>"
[ -f "$PRD" ] || die "PRD file not found: $PRD"

START='<!-- BROWNFIELD-ONLY-START -->'
END='<!-- BROWNFIELD-ONLY-END -->'

has_start=$(grep -cF "$START" "$PRD" || true)
has_end=$(grep -cF "$END" "$PRD" || true)

if [ "$has_start" -eq 0 ] && [ "$has_end" -eq 0 ]; then
  printf '%s: no brownfield block in %s — nothing to strip (no-op)\n' "$SCRIPT_NAME" "$PRD" >&2
  exit 0
fi
if [ "$has_start" -eq 0 ] || [ "$has_end" -eq 0 ]; then
  die "malformed brownfield block in $PRD (START=$has_start END=$has_end) — leaving file untouched" 2
fi

tmp="$(mktemp "${PRD}.XXXXXX")"
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
# Drop everything between the fences inclusive. awk range; skip-state toggled on
# the fence lines themselves so both comments are removed too.
awk -v s="$START" -v e="$END" '
  index($0, s) { skip = 1; next }
  skip && index($0, e) { skip = 0; next }
  !skip { print }
' "$PRD" > "$tmp"

mv "$tmp" "$PRD"
trap - EXIT
printf '%s: stripped BROWNFIELD-ONLY block from %s\n' "$SCRIPT_NAME" "$PRD" >&2
