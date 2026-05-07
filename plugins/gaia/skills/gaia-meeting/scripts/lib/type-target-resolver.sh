#!/usr/bin/env bash
# type-target-resolver.sh — eleven-type action-item type → target_command resolver (E76-S3)
#
# AC3 / FR-MTG-20 / ADR-086 / TC-MTG-AI-2
#
# Single source of truth for the eleven canonical action-item types and their
# target_command mapping. Reject anything else with a non-zero exit code — never
# silently coerce to a default (per Dev Notes "Eleven action-item types are
# exhaustive").
#
# Usage:
#   type-target-resolver.sh <type>
#
# Exit codes:
#   0 = known type; target_command emitted on stdout
#   2 = unknown / empty type
#   3 = malformed args

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "type-target-resolver.sh: usage: type-target-resolver.sh <type>" >&2
  exit 3
fi

t="$1"

case "$t" in
  feature)              echo "/gaia-add-feature" ;;
  prd-edit)             echo "/gaia-edit-prd" ;;
  ux-edit)              echo "/gaia-edit-ux" ;;
  arch-edit)            echo "/gaia-edit-arch" ;;
  test-edit)            echo "/gaia-edit-test-plan" ;;
  new-story)            echo "/gaia-create-story" ;;
  sprint-correction)    echo "/gaia-correct-course" ;;
  sprint-plan)          echo "/gaia-sprint-plan" ;;
  brainstorm-followup)  echo "/gaia-brainstorm" ;;
  adr-draft)            echo "no target — manual" ;;
  discussion-only)      echo "no target — discussion-only" ;;
  "")
    echo "type-target-resolver.sh: REJECTED — empty type" >&2
    exit 2
    ;;
  *)
    echo "type-target-resolver.sh: REJECTED — unknown action-item type '$t'" >&2
    echo "type-target-resolver.sh: known types: feature, prd-edit, ux-edit, arch-edit, test-edit, new-story, sprint-correction, sprint-plan, brainstorm-followup, adr-draft, discussion-only" >&2
    exit 2
    ;;
esac
