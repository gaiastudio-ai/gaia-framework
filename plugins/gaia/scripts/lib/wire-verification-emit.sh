#!/usr/bin/env bash
# wire-verification-emit.sh — /gaia-trace enforcement of integration coverage
# for FR/NFR rows with surface_type != none.
#
# Purpose
#   For a single story file + traceability matrix, walk the matrix for FR/NFR
#   rows with surface_type != none and verify each has at least one linked
#   row with integration coverage.
#
# Usage
#   wire-verification-emit.sh --story-file <path> --matrix-file <path>
#
# Behaviour (pathway-i — zero review-gate.sh changes)
#   - exits 0 if all surface_type != none rows have integration coverage,
#     OR if matrix contains no surface_type != none rows.
#   - exits 1 on violation:
#       (a) emit ONE HALT to stderr listing ALL violating FR/NFR ids;
#       (b) invoke review-gate.sh update --story <key> --gate "Test Review"
#           --verdict FAILED exactly once per story (NOT per FR/NFR);
#       (c) review-gate dominance handles composite BLOCKED automatically.
#
# Fail-closed on misspelled surface_type values (EC-1): any value other than
# `none` is treated as user-visible surface — surfaces taxonomy errors at
# gate time.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="wire-verification-emit.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-1}"; }

STORY_FILE=""
MATRIX_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --story-file)
      [[ $# -ge 2 ]] || die "missing value for --story-file"
      STORY_FILE="$2"
      shift 2
      ;;
    --matrix-file)
      [[ $# -ge 2 ]] || die "missing value for --matrix-file"
      MATRIX_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

[[ -n "$STORY_FILE" ]] || die "missing required flag: --story-file <path>"
[[ -n "$MATRIX_FILE" ]] || die "missing required flag: --matrix-file <path>"
[[ -f "$STORY_FILE" ]] || die "story file not found: $STORY_FILE"
[[ -f "$MATRIX_FILE" ]] || die "matrix file not found: $MATRIX_FILE"

extract_key() {
  awk '
    BEGIN { in_fm = 0; depth = 0 }
    /^---[[:space:]]*$/ {
      depth++
      if (depth == 1) { in_fm = 1; next }
      if (depth == 2) { exit }
    }
    in_fm && /^key:/ {
      sub("^key:[[:space:]]*", "", $0)
      gsub(/"/, "", $0)
      print
      exit
    }
  ' "$STORY_FILE"
}

STORY_KEY="$(extract_key)"
[[ -n "$STORY_KEY" ]] || die "story key not found in frontmatter of $STORY_FILE"

VIOLATIONS=()
while IFS= read -r row; do
  [[ "$row" =~ ^\| ]] || continue
  id="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')"
  surface_type="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); print $4}')"
  [[ "$id" =~ ^(FR|NFR)- ]] || continue
  [[ -n "$surface_type" ]] || continue
  [[ "$surface_type" == "none" ]] && continue

  has_integration=0
  # Inspect the SAME row's Integration column (column 6 for FR rows)
  integ_col="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$6); print $6}')"
  if [[ -n "$integ_col" && "$integ_col" != "—" && "$integ_col" != "-" ]]; then
    has_integration=1
  fi

  # Also check other rows that reference this id AND contain 'integration'
  if [[ $has_integration -eq 0 ]]; then
    while IFS= read -r check_row; do
      [[ "$check_row" =~ ^\| ]] || continue
      check_id="$(printf '%s' "$check_row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')"
      # Skip header rows (FR/NFR ids) — only count TC-style or test-link rows
      [[ "$check_id" =~ ^(FR|NFR)- ]] && continue
      if printf '%s' "$check_row" | grep -q "$id" && \
         printf '%s' "$check_row" | grep -q 'integration'; then
        has_integration=1
        break
      fi
    done < "$MATRIX_FILE"
  fi

  if [[ $has_integration -eq 0 ]]; then
    VIOLATIONS+=("$id (surface_type: $surface_type)")
  fi
done < "$MATRIX_FILE"

if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  exit 0
fi

violation_list="$(printf '%s; ' "${VIOLATIONS[@]}" | sed 's/; $//')"
log "HALT: wire-verification gap — $STORY_KEY: $violation_list has no integration-test row. Add a test_type=integration row to the traceability matrix, OR reclassify surface_type to 'none' with documented rationale."

if command -v review-gate.sh >/dev/null 2>&1; then
  review-gate.sh update --story "$STORY_KEY" --gate "Test Review" --verdict FAILED >&2 \
    || log "WARNING: review-gate.sh update failed (story=$STORY_KEY); finding still emitted"
else
  log "WARNING: review-gate.sh not found on PATH; FAILED-to-Test-Review write skipped"
fi

exit 1
