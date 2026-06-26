#!/usr/bin/env bash
# brownfield-critical-class.sh — deterministic classifier for brownfield
# CRITICAL findings: finding-content vs tooling-error.
#
# The classifier inspects the SHAPE of a JSON finding/envelope and returns
# one of two classes:
#
#   finding-content  — the finding has a valid gap-entry shape (gap_id
#                      matching ^[A-Z]+-[0-9]{3,}$, category from the
#                      canonical enum, evidence.file present). These
#                      describe real defects in the scanned codebase.
#
#   tooling-error    — everything else: error-shaped envelopes, missing
#                      required gap-entry fields, malformed JSON, invalid
#                      gap_id pattern, unknown category. These signal
#                      scanner crashes, tool unavailability, or pipeline
#                      breakage.
#
# Fail-safe: any ambiguity resolves to tooling-error (halt is the safe
# default — never silently downgrade an ambiguous CRITICAL).
#
# The YOLO downgrade decision in the brownfield SKILL.md reads this
# classifier's output. The orchestrator applies the classifier's verdict;
# it does not re-judge each CRITICAL.
#
# Functions:
#   bfcc_classify_critical <json_path>
#     Returns: "finding-content" or "tooling-error" on stdout. Exit 0.
#
#   bfcc_should_downgrade <json_path> <phase>
#     Combines the classifier with the per-phase scope rules.
#     Returns: "downgrade" or "halt" on stdout. Exit 0.
#     Phase values: "3", "6", "8b" → eligible for downgrade if
#     finding-content. All other phases → halt unconditionally.
#
# Contract: source only — direct execution is refused.
# Dependencies: jq (GAIA-wide hard dependency).
# Portability: Bash 3.2, LC_ALL=C. No associative arrays.

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---- Source guard ----
if [ -n "${_BFCC_SH_SOURCED:-}" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
_BFCC_SH_SOURCED=1

# ---- Main guard: refuse direct execution ----
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  printf 'brownfield-critical-class.sh: must be sourced, not executed\n' >&2
  exit 1
fi

# ---- Category enum (mirrors brownfield-gap-entry.schema.json) ----
# Pipe-delimited for grep -E matching. Kept in sync with the schema's
# category.enum array.
_BFCC_CATEGORY_ENUM='doc-code-drift|hardcoded-value|integration-seam|runtime-behavior|security|sbom-completeness|call-graph|stale-claim'

# ---- gap_id pattern (mirrors schema: ^[A-Z]+-[0-9]{3,}$) ----
_BFCC_GAP_ID_PATTERN='^[A-Z]+-[0-9][0-9][0-9][0-9]*$'

# bfcc_classify_critical <json_path>
#
# Inspect the JSON at <json_path> and classify it as finding-content or
# tooling-error based on the gap-entry shape. The check is:
#   1. File exists and parses as valid JSON
#   2. Has gap_id matching the canonical pattern
#   3. Has category from the canonical enum
#   4. Has evidence.file (non-empty string)
# All four → finding-content. Any miss → tooling-error.
bfcc_classify_critical() {
  local json_path="${1:-}"

  # Guard: empty path or missing file → tooling-error
  if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
    printf 'tooling-error\n'
    return 0
  fi

  # Guard: must parse as valid JSON
  if ! jq -e . "$json_path" >/dev/null 2>&1; then
    printf 'tooling-error\n'
    return 0
  fi

  # Extract the four discriminating fields
  local gap_id category evidence_file
  gap_id="$(jq -r '.gap_id // ""' "$json_path" 2>/dev/null)"
  category="$(jq -r '.category // ""' "$json_path" 2>/dev/null)"
  evidence_file="$(jq -r '.evidence.file // ""' "$json_path" 2>/dev/null)"

  # Check 1: gap_id matches the canonical pattern
  if [ -z "$gap_id" ]; then
    printf 'tooling-error\n'
    return 0
  fi
  if ! printf '%s\n' "$gap_id" | grep -qE "$_BFCC_GAP_ID_PATTERN"; then
    printf 'tooling-error\n'
    return 0
  fi

  # Check 2: category is in the canonical enum
  if [ -z "$category" ]; then
    printf 'tooling-error\n'
    return 0
  fi
  if ! printf '%s\n' "$category" | grep -qE "^(${_BFCC_CATEGORY_ENUM})\$"; then
    printf 'tooling-error\n'
    return 0
  fi

  # Check 3: evidence.file is present, non-empty, and not whitespace-only.
  # A whitespace-only path is malformed — fail-safe to tooling-error.
  case "$evidence_file" in
    '')                       printf 'tooling-error\n'; return 0 ;;
    *[![:space:]]*) : ;;      # has at least one non-space char — ok
    *)                        printf 'tooling-error\n'; return 0 ;;  # whitespace-only → halt
  esac

  # All shape checks pass — this is a finding about the scanned codebase
  printf 'finding-content\n'
  return 0
}

# bfcc_should_downgrade <json_path> <phase>
#
# Combines the shape-based classifier with the per-phase scope rules
# documented in the brownfield SKILL.md YOLO mode contract:
#   Phases 3, 6, 8b → downgrade if finding-content; halt if tooling-error
#   Phases 4, 8c, and all others → halt unconditionally
bfcc_should_downgrade() {
  local json_path="${1:-}"
  local phase="${2:-}"

  local critical_class
  critical_class="$(bfcc_classify_critical "$json_path")"

  # Phases that never downgrade — halt unconditionally
  case "$phase" in
    3|6|8b)
      # Eligible for downgrade — but only if finding-content
      if [ "$critical_class" = "finding-content" ]; then
        printf 'downgrade\n'
      else
        printf 'halt\n'
      fi
      ;;
    *)
      # Phase 4, 8c, or any unrecognized phase → always halt
      printf 'halt\n'
      ;;
  esac

  return 0
}
