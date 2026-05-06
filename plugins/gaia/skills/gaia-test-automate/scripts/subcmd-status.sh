#!/usr/bin/env bash
# subcmd-status.sh — /gaia-test-automate --status sub-command (E72-S2)
#
# Reads a story file and emits a coverage map showing each AC mapped to
# its TC ID, tier, and file path (or "(not yet automated)") plus a
# summary line. Renders a "Custom scenarios" block when CS-NNN entries
# exist in the story's Custom Scenarios table.
#
# Usage:
#   subcmd-status.sh --story-file <path>
#   subcmd-status.sh --help
#
# Output (stdout):
#   Coverage map for E99-S99
#   AC1   TC-001  unit         tests/unit/foo.test.ts
#   AC2   TC-002  integration  tests/int/bar.spec.ts
#   AC3   —       —            (not yet automated)
#
#   Summary: 2/3 generated (67%) | 1 pending automation
#
#   Custom scenarios:
#   CS-001  unit  edge case for retry  tests/unit/cs-001.test.ts
#
# Exit codes:
#   0 — output emitted successfully
#   1 — story file missing / unreadable
#   2 — caller error (missing required flag)
#
# Refs: E72-S2 AC1, AC2; FR-RSV2-40; source-report §5.8.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="subcmd-status.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — /gaia-test-automate --status sub-command (E72-S2).

Usage:
  $SCRIPT_NAME --story-file <path>
  $SCRIPT_NAME --help

Output: AC/TC/tier/file coverage map + summary line + optional
"Custom scenarios" block when CS-NNN entries exist.
EOF
}

STORY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --story-file) STORY_FILE="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

[ -n "$STORY_FILE" ] || { err "missing required --story-file"; exit 2; }
[ -r "$STORY_FILE" ] || { err "story file not readable: $STORY_FILE"; exit 1; }

# Extract story key from frontmatter (best-effort; falls back to filename).
story_key="$(awk '
  /^---$/ { fm = !fm; next }
  fm && /^key:/ {
    s = $0; sub(/^key:[[:space:]]*/, "", s); gsub(/"/, "", s); print s; exit
  }
' "$STORY_FILE" || true)"
if [ -z "$story_key" ]; then
  story_key="$(basename "$STORY_FILE" .md | grep -oE '^E[0-9]+-S[0-9]+' || true)"
fi
[ -n "$story_key" ] || story_key="UNKNOWN"

# ---------------------------------------------------------------------------
# Pass 1: enumerate ACs from "## Acceptance Criteria" section.
# ---------------------------------------------------------------------------
ac_list="$(awk '
  /^## Acceptance Criteria/ { in_ac=1; next }
  in_ac && /^## / { in_ac=0 }
  in_ac && /^- \[[ x]\] AC[0-9]+/ {
    s=$0; sub(/^- \[[ x]\] /, "", s)
    n=index(s, ":"); if (n>0) ac=substr(s, 1, n-1); else ac=s
    print ac
  }
' "$STORY_FILE")"

# ---------------------------------------------------------------------------
# Pass 2: build a TC-by-AC map from the "## Test Cases" markdown table.
# Format of each row: | TC-NNN | AC-N | tier | file |
# ---------------------------------------------------------------------------
TMP_TC="$(mktemp -t e72s2-status.XXXXXX)"
trap 'rm -f "$TMP_TC"' EXIT

awk '
  /^## Test Cases/ { in_tc=1; next }
  in_tc && /^## / { in_tc=0 }
  in_tc && /^\|/ {
    # Skip header and separator rows.
    if ($0 ~ /^\|[[:space:]]*TC[[:space:]]*\|/) next
    if ($0 ~ /^\|[-: ]+\|/) next
    # Split the row by | and trim each cell.
    n = split($0, c, "|")
    if (n < 5) next
    tc=c[2]; ac=c[3]; tier=c[4]; file=c[5]
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", tc)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", ac)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", tier)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
    if (tc == "" || ac == "") next
    print ac "\t" tc "\t" tier "\t" file
  }
' "$STORY_FILE" >"$TMP_TC"

# ---------------------------------------------------------------------------
# Render coverage map.
# ---------------------------------------------------------------------------
printf 'Coverage map for %s\n' "$story_key"

total=0
generated=0
while IFS= read -r ac; do
  [ -n "$ac" ] || continue
  total=$((total+1))
  row="$(awk -F '\t' -v ac="$ac" '$1==ac {print; exit}' "$TMP_TC")"
  if [ -n "$row" ]; then
    generated=$((generated+1))
    tc="$(printf '%s' "$row" | awk -F '\t' '{print $2}')"
    tier="$(printf '%s' "$row" | awk -F '\t' '{print $3}')"
    file="$(printf '%s' "$row" | awk -F '\t' '{print $4}')"
    printf '%-6s %-8s %-12s %s\n' "$ac" "$tc" "$tier" "$file"
  else
    printf '%-6s %-8s %-12s %s\n' "$ac" "—" "—" "(not yet automated)"
  fi
done <<<"$ac_list"

pending=$((total - generated))
if [ "$total" -gt 0 ]; then
  pct=$(( generated * 100 / total ))
else
  pct=0
fi
printf '\nSummary: %d/%d generated (%d%%) | %d pending automation\n' \
  "$generated" "$total" "$pct" "$pending"

# ---------------------------------------------------------------------------
# Custom scenarios block (rendered only when CS-NNN entries exist).
# ---------------------------------------------------------------------------
cs_rows="$(awk '
  /^## Custom Scenarios/ { in_cs=1; next }
  in_cs && /^## / { in_cs=0 }
  in_cs && /^\|[[:space:]]*CS-[0-9]+/ {
    n = split($0, c, "|")
    if (n < 5) next
    cs=c[2]; tier=c[3]; desc=c[4]; file=c[5]
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", cs)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", tier)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", desc)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
    print cs "\t" tier "\t" desc "\t" file
  }
' "$STORY_FILE")"

if [ -n "$cs_rows" ]; then
  printf '\nCustom scenarios:\n'
  while IFS=$'\t' read -r cs tier desc file; do
    [ -n "$cs" ] || continue
    [ -z "$file" ] && file="(not yet automated)"
    printf '%-8s %-12s %-30s %s\n' "$cs" "$tier" "$desc" "$file"
  done <<<"$cs_rows"
fi

exit 0
