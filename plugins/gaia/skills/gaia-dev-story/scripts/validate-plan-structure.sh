#!/usr/bin/env bash
# validate-plan-structure.sh — gaia-dev-story Step 4 plan-structure gate
#
# Purpose:
#   Reject any /gaia-dev-story Step 4 plan that is missing a required
#   section. The canonical 9-section list is sourced from the PRD
#   (.gaia/artifacts/planning-artifacts/prd.md) and the architecture
#   Decision Log (.gaia/artifacts/planning-artifacts/architecture.md).
#
# Canonical sections (top-to-bottom; first miss wins):
#   1. Context
#   2. Root Cause            (REWORK only — gated on --rework flag)
#   3. Implementation Steps
#   4. Files to Modify
#   5. Architecture Refs
#   6. UX Refs
#   7. Testing Strategy
#   8. Risks
#   9. Verification Plan
#
# Unicode-homoglyph mitigation:
#   The threat is Unicode-homoglyph spoofing of section headers (e.g.,
#   Cyrillic `С` U+0421 vs ASCII `C` U+0043). We use `grep -F` with literal
#   ASCII strings — Cyrillic `Сontext` will NOT match `Context`. No regex
#   anchors, no Unicode normalization.
#
# Usage:
#   validate-plan-structure.sh [--rework] [<plan-file>]
#
#   With no plan-file argument the validator reads the plan from stdin.
#   The --rework flag enables the `Root Cause` section requirement; without
#   it, REWORK-only sections are skipped (new-feature plans are exempt).
#
# Exit codes:
#   0 — all required sections present
#   1 — at least one required section missing (first miss reported on stderr)
#   2 — usage error (e.g., bad flag)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/validate-plan-structure.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

REWORK=0
PLAN_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rework)
      REWORK=1
      shift
      ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown flag: $1" 2
      ;;
    *)
      PLAN_FILE="$1"
      shift
      ;;
  esac
done

# Read the plan content. Default to stdin if no file given.
if [ -z "$PLAN_FILE" ]; then
  CONTENT="$(cat)"
else
  if [ ! -f "$PLAN_FILE" ]; then
    die "plan file not found: $PLAN_FILE" 2
  fi
  CONTENT="$(cat "$PLAN_FILE")"
fi

# Canonical 9-section list. Order is intentional — the validator reports
# the FIRST miss top-to-bottom so the agent fixes them in plan order.
# REWORK-gated entries are flagged; the loop skips them when --rework is
# not passed.
#
# Per-entry format: "<section_name>|<required_in_feature_mode>"
#   required_in_feature_mode = 1 if always required, 0 if REWORK-only.
SECTIONS=(
  "Context|1"
  "Root Cause|0"
  "Implementation Steps|1"
  "Files to Modify|1"
  "Architecture Refs|1"
  "UX Refs|1"
  "Testing Strategy|1"
  "Risks|1"
  "Verification Plan|1"
)

for entry in "${SECTIONS[@]}"; do
  section="${entry%%|*}"
  always_required="${entry##*|}"

  # Skip REWORK-only sections unless --rework was passed.
  if [ "$always_required" = "0" ] && [ "$REWORK" -ne 1 ]; then
    continue
  fi

  # Unicode-homoglyph mitigation: literal ASCII match via grep -F. Cyrillic
  # homoglyphs cannot satisfy this match. We pass the section name with no
  # anchors — the literal substring `Context` (8 chars in this case) will
  # not match `Сontext` because the Cyrillic С is a different byte sequence.
  if ! printf '%s' "$CONTENT" | grep -F -q "$section"; then
    log "MISSING section '$section'"
    exit 1
  fi
done

log "all required sections present (rework=$REWORK)"
exit 0
