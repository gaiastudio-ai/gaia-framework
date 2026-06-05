#!/usr/bin/env bash
# gating-flip-guard.sh — GAIA review-common entry point
#
# Two operations that envelope the GATING-flip deployment:
#
#   --check-boundary --sprint-status <yaml>
#       Refuses the flip if any story in the active sprint-status.yaml has
#       status: in-progress. Sprint-boundary semantics.
#
#   --scan --impl-dir <dir>
#       One-time pre-flip review-status scan: enumerates story files at
#       status: review whose Review Gate table contains any non-PASSED row.
#
# Output for --scan: one line per offending story:
#   <story_key>: <Review-Gate-name>=<verdict> [<Review-Gate-name>=<verdict> ...]
# When no offending stories exist, prints:
#   no stories require resolution before flip
#
# Exit codes:
#   0  success (boundary OK; or scan completed — output may be empty enumeration)
#   1  caller error (missing flag, missing file) OR mid-sprint flip rejected
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gating-flip-guard.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — sprint-boundary deployment guard + pre-flip scan

Usage:
  $SCRIPT_NAME --check-boundary --sprint-status <path>
  $SCRIPT_NAME --scan --impl-dir <path>
  $SCRIPT_NAME --help

--check-boundary: refuses if any story is status: in-progress in the supplied
  sprint-status.yaml. Exit 0 = boundary OK; exit 1 = mid-sprint, refuse flip.

--scan: enumerates status: review stories under <impl-dir> whose Review Gate
  has any non-PASSED row. Exit 0 = scan complete; output may be empty.

Exit codes: 0 success; 1 caller error or mid-sprint refusal.
EOF
}

# Parse arguments.
MODE=""
SPRINT_STATUS=""
IMPL_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-boundary) MODE="boundary"; shift ;;
    --scan)           MODE="scan"; shift ;;
    --sprint-status)  [ "$#" -ge 2 ] || die 1 "--sprint-status requires a path"; SPRINT_STATUS="$2"; shift 2 ;;
    --impl-dir)       [ "$#" -ge 2 ] || die 1 "--impl-dir requires a path"; IMPL_DIR="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ] || die 1 "missing required mode (--check-boundary or --scan)"

# ---------- --check-boundary ----------
check_boundary() {
  [ -n "$SPRINT_STATUS" ] || die 1 "--check-boundary requires --sprint-status <path>"
  [ -f "$SPRINT_STATUS" ] || die 1 "sprint-status.yaml not found: $SPRINT_STATUS"

  # Find any in-progress status entries. The yaml stories list uses
  # "status: \"in-progress\"" rows nested under stories:. We grep narrowly
  # for the quoted form to avoid matching the top-level sprint metadata.
  local in_progress_count
  in_progress_count="$(awk '
    /^[[:space:]]+status:[[:space:]]*"in-progress"[[:space:]]*$/ { c++ }
    END { print (c ? c : 0) }
  ' "$SPRINT_STATUS")"

  if [ "$in_progress_count" -gt 0 ]; then
    printf '%s: sprint-boundary check FAILED — %d story(ies) in-progress; flip refused\n' \
      "$SCRIPT_NAME" "$in_progress_count" >&2
    exit 1
  fi
  printf 'sprint-boundary OK — no in-progress stories\n'
}

# ---------- --scan ----------
# Returns 0 always; emits zero or more offender lines on stdout.
scan_impl() {
  [ -n "$IMPL_DIR" ] || die 1 "--scan requires --impl-dir <path>"
  [ -d "$IMPL_DIR" ] || die 1 "impl-dir not found: $IMPL_DIR"

  # Iterate every *.md under IMPL_DIR (depth-1; keeps it simple — story files
  # live flat at impl-dir root in this layout). Recurse one level for projects
  # that nest under epic-*/stories/.
  local found=0
  local file
  # Collect candidate files (sorted for byte-identical determinism).
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find "$IMPL_DIR" -maxdepth 4 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort
  )

  for file in "${files[@]}"; do
    # Read frontmatter status.
    local fm_status
    fm_status="$(awk '
      BEGIN { in_fm=0 }
      /^---[[:space:]]*$/ { in_fm = !in_fm; next }
      in_fm == 1 && /^status:[[:space:]]*/ {
        sub(/^status:[[:space:]]*/, "")
        gsub(/"/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }
    ' "$file")"

    [ "$fm_status" = "review" ] || continue

    # Parse Review Gate table — six canonical rows. We accept any row whose
    # second cell (Status) is not PASSED as an offender.
    local offenders
    offenders="$(awk -F'|' '
      BEGIN { in_table=0 }
      /^## Review Gate[[:space:]]*$/ { in_table=1; next }
      in_table && /^## / && !/^## Review Gate/ { in_table=0 }
      in_table && /^\|/ {
        gate=$2; status=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
        if (gate == "Review" || gate == "" || gate ~ /^-+$/) next
        if (status != "PASSED") printf("%s=%s ", gate, status)
      }
    ' "$file")"

    if [ -n "$offenders" ]; then
      # Extract story key from frontmatter (the `key:` field).
      local key
      key="$(awk '
        BEGIN { in_fm=0 }
        /^---[[:space:]]*$/ { in_fm = !in_fm; next }
        in_fm == 1 && /^key:[[:space:]]*/ {
          sub(/^key:[[:space:]]*/, "")
          gsub(/"/, "")
          sub(/[[:space:]]*$/, "")
          print
          exit
        }
      ' "$file")"
      [ -n "$key" ] || key="$(basename "$file" .md)"
      # Trim trailing space on offenders.
      offenders="${offenders% }"
      printf '%s: %s\n' "$key" "$offenders"
      found=1
    fi
  done

  if [ "$found" -eq 0 ]; then
    printf 'no stories require resolution before flip\n'
  fi
  exit 0
}

case "$MODE" in
  boundary) check_boundary ;;
  scan)     scan_impl ;;
  *)        die 1 "internal: unknown mode '$MODE'" ;;
esac
