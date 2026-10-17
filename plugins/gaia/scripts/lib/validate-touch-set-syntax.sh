#!/usr/bin/env bash
# validate-touch-set-syntax.sh — deterministic path-syntax check for the
# predicted touch-set field in story frontmatter.
#
# Call sites:
#   1. validate-frontmatter.sh — local creation-time check
#   2. gaia-validate-story/SKILL.md — runtime validation instruction for Val
#
# Usage:
#   validate-touch-set-syntax.sh --file <story-file> [--project-root <path>]
#
# Exit codes:
#   0 — field absent or valid
#   1 — field present but malformed or contains invalid values
#   2 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-touch-set-syntax.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage: validate-touch-set-syntax.sh --file <story-file> [--project-root <path>]

  --file <path>           Path to a story file. Required.
  --project-root <path>   Project root for containment checks. Optional;
                          defaults to CLAUDE_PROJECT_ROOT / PROJECT_ROOT / walk-up.

Exit codes: 0 valid or absent | 1 malformed | 2 usage error.
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 2; }

# --- CLI parsing ---

file=""
project_root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      file="$2"; shift 2 ;;
    --project-root)
      [ $# -ge 2 ] || die_usage "--project-root requires a value"
      project_root="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$file" ] || die_usage "--file is required"
[ -r "$file" ] || { log "file not readable: $file"; exit 2; }

# --- resolve project root ---

if [ -z "$project_root" ]; then
  project_root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-}}"
fi
if [ -z "$project_root" ]; then
  # Walk up to first directory containing .gaia/
  _d="$(cd "$(dirname "$file")" && pwd)"
  while [ "$_d" != "/" ]; do
    if [ -d "$_d/.gaia" ]; then
      project_root="$_d"
      break
    fi
    _d="$(dirname "$_d")"
  done
fi
# Default to / if nothing found (permissive for single-sprint mode).
project_root="${project_root:-/}"

# --- source sanitizer ---

# shellcheck source=touch-set-sanitizer.sh
. "${SCRIPT_DIR}/touch-set-sanitizer.sh"

# --- extract field ---

_ts_field="predicted_touch_set"

# Check if the field exists in frontmatter.
field_line="$(awk -v field="$_ts_field" '
  BEGIN { state = 0 }
  state == 0 && /^---$/ { state = 1; next }
  state == 1 && /^---$/ { exit }
  state == 1 {
    pat = "^" field ":"
    if (match($0, pat)) { print $0; exit }
  }
' "$file")"

if [ -z "$field_line" ]; then
  # Field absent — valid (single-sprint backward compatibility).
  exit 0
fi

# Extract the raw value after the colon.
raw_val="${field_line#*:}"
# Trim leading whitespace.
raw_val="$(printf '%s' "$raw_val" | sed 's/^[[:space:]]*//')"

# Check it is a YAML list (flow array starting with [ or block style
# starting with empty/newline followed by - items).
case "$raw_val" in
  '['*)
    # Flow array — looks correct at syntax level.
    ;;
  ''|'null')
    # Absent value on the same line — treat as absent field.
    exit 0
    ;;
  *)
    # Not a list (scalar string or other) — malformed.
    log "field is not a YAML list: got '$raw_val'"
    exit 1
    ;;
esac

# Read each entry and validate via the denylist.
rc=0
while IFS= read -r -d '' val; do
  [ -n "$val" ] || continue
  touch_set_denylist_check "$val" || rc=1
  touch_set_check_climb_out "$val" || rc=1
  touch_set_root_containment "$val" "$project_root" >/dev/null || rc=1
done < <(TS_FIELD="$_ts_field" yq --front-matter=extract -r0 \
  '.[strenv(TS_FIELD)] // [] | .[]' "$file" 2>/dev/null || true)

exit "$rc"
