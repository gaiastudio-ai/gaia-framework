#!/usr/bin/env bash
# write-boundary.sh — gaia-meeting state-free write-boundary asserter
# (E76-S1 + E76-S3, FR-MTG-31, AC10)
#
# The skill orchestrator MUST route every artifact write through this asserter
# so that no path outside the allowed roots is ever written. This is the
# state-free invariant: /gaia-meeting MUST NOT touch sprint state, story files,
# PRD, architecture, test plan, threat model, or traceability.
#
# Allowed write targets (E96-S8 close-out — legacy entries removed; .gaia/ only):
#   - .gaia/artifacts/creative-artifacts/meeting-*.md
#   - .gaia/state/action-items.yaml
#   - .gaia/memory/{any-prefix}-sidecar/decisions/*.md
#   - .gaia/memory/meeting-sessions/*.yaml
#   - .gaia/custom/skills/...
#
# Legacy entries removed by E96-S8 (post-deprecation cleanup, AC5):
#   docs/creative-artifacts/, docs/planning-artifacts/action-items.yaml,
#   _memory/<prefix>-sidecar/decisions/, _memory/meeting-sessions/, custom/skills/.
# These were dual-path during the E96-S2..E96-S4 deprecation window;
# E96-S7 swept all framework consumers to smart-fallback through .gaia/
# (env > .gaia/ > legacy). After E96-S8 removed the legacy directory shells,
# the legacy entries are no longer reachable and are stripped from this
# allowlist to make the boundary contract explicit.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Helper — emit canonical WRITE-BOUNDARY-VIOLATION halt event (E76-S6, AC8 + AC9).
emit_halt() {
  local detail="$1"
  if [[ -x "$SCRIPT_DIR/halt-event.sh" ]]; then
    "$SCRIPT_DIR/halt-event.sh" \
      --condition WRITE-BOUNDARY-VIOLATION \
      --fr FR-MTG-31 \
      --detail "$detail" || true
  else
    # Fallback if halt-event.sh is unavailable — still emit the canonical line.
    printf 'HALT condition=WRITE-BOUNDARY-VIOLATION agent=— fr=FR-MTG-31 detail=%s\n' "$detail"
  fi
}

# Reject path traversal attempts
case "$path" in
  /*|*..*)
    echo "write-boundary.sh: REJECTED — absolute or ..-bearing path: $path" >&2
    emit_halt "absolute or ..-bearing path: $path"
    exit 2
    ;;
esac

# Allowed: .gaia/artifacts/creative-artifacts/meeting-*.md
if [[ "$path" == .gaia/artifacts/creative-artifacts/* ]]; then
  exit 0
fi

# Allowed: .gaia/state/action-items.yaml
if [[ "$path" == ".gaia/state/action-items.yaml" ]]; then
  exit 0
fi

# Allowed: .gaia/memory/<prefix>-sidecar/decisions/...
if [[ "$path" =~ ^\.gaia/memory/[A-Za-z0-9_.-]+-sidecar/decisions/ ]]; then
  exit 0
fi

# Allowed: .gaia/custom/skills/...
if [[ "$path" == .gaia/custom/skills/* ]]; then
  exit 0
fi

# Allowed: .gaia/memory/meeting-sessions/...yaml
if [[ "$path" =~ ^\.gaia/memory/meeting-sessions/.*\.yaml$ ]]; then
  exit 0
fi

echo "write-boundary.sh: REJECTED — '$path' is outside the state-free write boundary (FR-MTG-31)." >&2
echo "write-boundary.sh: allowed targets (.gaia/-only per E96-S8): .gaia/artifacts/creative-artifacts/meeting-*.md, .gaia/state/action-items.yaml, .gaia/memory/{agent}-sidecar/decisions/*.md, .gaia/memory/meeting-sessions/*.yaml, .gaia/custom/skills/*" >&2
emit_halt "$path is outside the state-free write boundary"
exit 2
