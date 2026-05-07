#!/usr/bin/env bash
# write-boundary.sh — gaia-meeting state-free write-boundary asserter
# (E76-S1, FR-MTG-31, AC8)
#
# The skill orchestrator MUST route every artifact write through this asserter
# so that no path outside the allowed roots is ever written. This is the
# state-free invariant: /gaia-meeting MUST NOT touch sprint state, story files,
# PRD, architecture, test plan, threat model, or traceability.
#
# Allowed write roots:
#   - docs/creative-artifacts/
#   - _memory/action-items/
#   - _memory/{any-prefix}-sidecar/decisions/
#
# Usage:
#   write-boundary.sh <relative-path-from-project-root>
#
# Exit codes:
#   0 = path is within the allowed boundary
#   2 = path is outside the allowed boundary (REJECTED)
#   3 = malformed args

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "write-boundary.sh: usage: write-boundary.sh <path>" >&2
  exit 3
fi

path="$1"

if [[ -z "$path" ]]; then
  echo "write-boundary.sh: empty path" >&2
  exit 3
fi

# Reject path traversal attempts
case "$path" in
  /*|*..*)
    echo "write-boundary.sh: REJECTED — absolute or ..-bearing path: $path" >&2
    exit 2
    ;;
esac

# Allowed: docs/creative-artifacts/...
if [[ "$path" == docs/creative-artifacts/* ]]; then
  exit 0
fi

# Allowed: _memory/action-items/...
if [[ "$path" == _memory/action-items/* ]]; then
  exit 0
fi

# Allowed: _memory/<prefix>-sidecar/decisions/...
if [[ "$path" =~ ^_memory/[A-Za-z0-9_.-]+-sidecar/decisions/ ]]; then
  exit 0
fi

echo "write-boundary.sh: REJECTED — '$path' is outside the state-free write boundary (FR-MTG-31)." >&2
echo "write-boundary.sh: allowed roots: docs/creative-artifacts/, _memory/action-items/, _memory/{agent}-sidecar/decisions/" >&2
exit 2
