#!/usr/bin/env bash
# should-skip-questionnaire.sh — questionnaire skip predicate for /gaia-create-ux.
#
# Checks whether the design record exists and has a non-empty project reference.
# If so, the questionnaire should be skipped (exit 0). Otherwise it should
# run (exit 1).
#
# v2 records: reads design_system_project.reference first (primary).
# Pre-migration records (design_system_project key absent): falls back to
# .project.reference.
# Present-but-null design_system_project: exit 1 (no fallback).
#
# Script exposes no reusable public functions — the top-level flow is the
# entire API. Public-function coverage guard is N/A.
#
# Usage:
#   should-skip-questionnaire.sh --record-path <path>
#
# Exit codes:
#   0 — skip (record exists with non-empty reference)
#   1 — run (no record, or reference is empty/whitespace-only/null)

set -euo pipefail
LC_ALL=C; export LC_ALL

RECORD_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --record-path) RECORD_PATH="$2"; shift 2 ;;
    *) printf 'should-skip-questionnaire.sh: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$RECORD_PATH" ] || { printf 'should-skip-questionnaire.sh: --record-path required\n' >&2; exit 1; }

# No record file — questionnaire should run
if [ ! -f "$RECORD_PATH" ]; then
  exit 1
fi

# Check for v2 field: has("design_system_project") in its own invocation
HAS_DSP="$(yq 'has("design_system_project")' "$RECORD_PATH" 2>/dev/null || true)"

if [ "$HAS_DSP" = "true" ]; then
  # v2 path: check the value (null vs object)
  DSP_VAL="$(yq '.design_system_project' "$RECORD_PATH" 2>/dev/null || true)"
  if [ "$DSP_VAL" = "null" ]; then
    # Present-but-null: no fallback
    exit 1
  fi
  # Read the reference from the v2 field
  REF="$(yq '.design_system_project.reference' "$RECORD_PATH" 2>/dev/null || true)"
else
  # Pre-migration fallback: read legacy project.reference
  REF="$(yq '.project.reference' "$RECORD_PATH" 2>/dev/null || true)"
fi

# Treat null, empty, and whitespace-only as absent
if [ -z "$REF" ] || [ "$REF" = "null" ]; then
  exit 1
fi

# Trim whitespace and check if anything remains
TRIMMED="$(printf '%s' "$REF" | tr -d '[:space:]')"
if [ -z "$TRIMMED" ]; then
  exit 1
fi

# Non-empty reference — skip the questionnaire
exit 0
