#!/usr/bin/env bash
# verify-cluster-gates.sh — GAIA foundation script (E28-S126)
#
# Pre-start gate verifier for the ADR-048 program-closing deletion.
# Reads the status and Review Gate table from each of the 12 cluster-gate stories
# and asserts each one is `done` with all 6 reviews PASSED. Used by:
#   (1) gaia-cleanup-legacy-engine.sh as its pre-flight gate
#   (2) .github/workflows/adr-048-guard.yml as the CI compensating control
#
# Refs: FR-328, NFR-050, ADR-048 (program-closing CI compensating control)
# Story: E28-S126 Task 1 / AC1 / AC-EC4
#
# Falls back to {gate}-review-summary.md when the main story file does not
# contain the Review Gate table inline (some stories keep reviews in a
# dedicated summary file).
#
# Exit codes:
#   0 — all 12 gates done + 6x PASSED
#   1 — one or more gates not passing
#   2 — parse error / missing story file
#   64 — usage error
#
# Usage: verify-cluster-gates.sh --project-root PATH

set -euo pipefail

PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --project-root PATH"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: $0 --project-root PATH" >&2; exit 64 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Usage: $0 --project-root PATH" >&2
  exit 64
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "project-root does not exist: $PROJECT_ROOT" >&2
  exit 64
fi

# E96-S1 path resolution: prefer .gaia/artifacts/, fall back to legacy docs/
if [[ -d "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" ]]; then
  ARTIFACTS_DIR="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
else
  ARTIFACTS_DIR="$PROJECT_ROOT/docs/implementation-artifacts"
fi

GATES=(
  E28-S76  E28-S81  E28-S95  E28-S99  E28-S118
  E28-S133 E28-S134 E28-S135 E28-S136 E28-S137 E28-S138 E28-S139
)

REQUIRED_REVIEWS=("Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review")

overall_exit=0
printf "=== ADR-048 cluster-gate verification ===\n"
printf "%-10s %-10s %s\n" "Story" "Status" "Reviews"

for gate in "${GATES[@]}"; do
  # Find the canonical story file — prefer files with YAML frontmatter that
  # names this key. Many stories also ship companion review/qa/performance
  # files that share the glob but don't contain the story frontmatter.
  shopt -s nullglob
  matches=( "$ARTIFACTS_DIR/${gate}-"*.md "$ARTIFACTS_DIR/${gate}.md" "$ARTIFACTS_DIR"/epic-*/stories/"${gate}-"*.md "$ARTIFACTS_DIR"/epic-*/stories/"${gate}.md" )
  shopt -u nullglob
  story_file=""
  for m in "${matches[@]}"; do
    [[ -f "$m" ]] || continue
    # Prefer files whose frontmatter contains both `key:` and `status:`.
    if grep -qE "^key:.*${gate}" "$m" 2>/dev/null && grep -q "^status:" "$m" 2>/dev/null; then
      story_file="$m"
      break
    fi
  done
  # Fallback: first file with a status: line.
  if [[ -z "$story_file" ]]; then
    for m in "${matches[@]}"; do
      [[ -f "$m" ]] || continue
      if grep -q "^status:" "$m" 2>/dev/null; then
        story_file="$m"
        break
      fi
    done
  fi
  if [[ -z "$story_file" ]]; then
    printf "%-10s %-10s %s\n" "$gate" "MISSING" "story file not found"
    overall_exit=2
    continue
  fi

  # Extract status from YAML frontmatter.
  status_line=$(awk '/^status:/ {print; exit}' "$story_file")
  status_value=$(printf '%s' "$status_line" | sed -E 's/^status:[[:space:]]*"?//; s/"?[[:space:]]*$//')

  # Extract the six review rows from the Review Gate section in the story file.
  # Fall back to {gate}-review-summary.md (same-directory sibling) when the
  # story file lists the reviews there instead of inline.
  extract_review_rows() {
    awk '
      /^## Review Gate/ { in_gate=1; next }
      in_gate && /^## / { in_gate=0 }
      in_gate { print }
    ' "$1" | grep -E '^\| [A-Za-z]' || true
  }

  review_rows=$(extract_review_rows "$story_file")
  if [[ -z "$review_rows" ]]; then
    summary_file="$ARTIFACTS_DIR/${gate}-review-summary.md"
    if [[ -f "$summary_file" ]]; then
      # review-summary.md typically uses a table without the ## Review Gate header.
      review_rows=$(grep -E '^\| (Code Review|QA Tests|Security Review|Test Automation|Test Review|Performance Review) \|' "$summary_file" || true)
    fi
  fi

  all_passed=1
  missing_reviews=()
  for review in "${REQUIRED_REVIEWS[@]}"; do
    row=$(printf '%s\n' "$review_rows" | grep -F "| $review |" | head -1 || true)
    if [[ -z "$row" ]]; then
      all_passed=0
      missing_reviews+=("$review:MISSING")
      continue
    fi
    verdict=$(printf '%s' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')
    if [[ "$verdict" != "PASSED" ]]; then
      all_passed=0
      missing_reviews+=("$review:$verdict")
    fi
  done

  if [[ "$status_value" == "done" && "$all_passed" -eq 1 ]]; then
    printf "%-10s %-10s %s\n" "$gate" "done" "6/6 PASSED"
  else
    printf "%-10s %-10s %s\n" "$gate" "$status_value" "${missing_reviews[*]:-all PASSED}"
    [[ "$overall_exit" -eq 0 ]] && overall_exit=1
  fi
done

printf "\n"
if [[ "$overall_exit" -eq 0 ]]; then
  echo "All 12 cluster gates PASSED — ADR-048 pre-start gate: OPEN"
else
  echo "Cluster-gate verification FAILED — ADR-048 pre-start gate: BLOCKED"
fi

exit "$overall_exit"
