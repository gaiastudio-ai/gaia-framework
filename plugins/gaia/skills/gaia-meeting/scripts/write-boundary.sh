#!/usr/bin/env bash
# write-boundary.sh — gaia-meeting state-free write-boundary asserter
# (E76-S1 + E76-S3, FR-MTG-31, AC10)
#
# The skill orchestrator MUST route every artifact write through this asserter
# so that no path outside the allowed roots is ever written. This is the
# state-free invariant: /gaia-meeting MUST NOT touch sprint state, story files,
# PRD, architecture, test plan, threat model, or traceability.
#
# Allowed write targets (E76-S3 / ADR-086 reconciliation, E76-S7 / FR-MTG-31 amendment):
#   - docs/creative-artifacts/meeting-*.md
#   - docs/planning-artifacts/action-items.yaml
#   - _memory/{any-prefix}-sidecar/decisions/*.md
#   - _memory/meeting-sessions/*.yaml      (E76-S7, FR-MTG-31 amended)
#
# Note: the legacy E76-S1 path `_memory/action-items/` is RETIRED by ADR-086 —
# the canonical action-items registry is the single-file YAML at
# `docs/planning-artifacts/action-items.yaml` (per architecture §10.28.6 /
# ADR-052 addendum E36-S4). New writes MUST target the canonical location.
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

# Allowed: docs/creative-artifacts/meeting-*.md (legacy) OR
# .gaia/artifacts/creative-artifacts/meeting-*.md (new, E96-S2 / ADR-111).
# Dual-path during the 1-sprint deprecation window; E96-S5 removes the legacy form.
if [[ "$path" == docs/creative-artifacts/* ]]; then
  exit 0
fi
if [[ "$path" == .gaia/artifacts/creative-artifacts/* ]]; then
  exit 0
fi

# Allowed: docs/planning-artifacts/action-items.yaml (legacy, ADR-086) OR
# .gaia/state/action-items.yaml (new, E96-S2 / ADR-111).
if [[ "$path" == "docs/planning-artifacts/action-items.yaml" ]]; then
  exit 0
fi
if [[ "$path" == ".gaia/state/action-items.yaml" ]]; then
  exit 0
fi

# Allowed: _memory/<prefix>-sidecar/decisions/...
if [[ "$path" =~ ^_memory/[A-Za-z0-9_.-]+-sidecar/decisions/ ]]; then
  exit 0
fi

# Allowed: custom/skills/... (legacy, ADR-020) OR .gaia/custom/skills/...
# (new, E96-S3 / ADR-111). Dual-path during the 1-sprint deprecation window.
if [[ "$path" == custom/skills/* ]]; then
  exit 0
fi
if [[ "$path" == .gaia/custom/skills/* ]]; then
  exit 0
fi

# Allowed: _memory/meeting-sessions/...yaml (E76-S7, FR-MTG-31 amended)
if [[ "$path" =~ ^_memory/meeting-sessions/.*\.yaml$ ]]; then
  exit 0
fi

echo "write-boundary.sh: REJECTED — '$path' is outside the state-free write boundary (FR-MTG-31)." >&2
echo "write-boundary.sh: allowed targets: {docs|.gaia/artifacts}/creative-artifacts/meeting-*.md, docs/planning-artifacts/action-items.yaml | .gaia/state/action-items.yaml, _memory/{agent}-sidecar/decisions/*.md, _memory/meeting-sessions/*.yaml" >&2
emit_halt "$path is outside the state-free write boundary"
exit 2
