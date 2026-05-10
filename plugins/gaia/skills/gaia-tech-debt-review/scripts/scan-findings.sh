#!/usr/bin/env bash
# scan-findings.sh — deterministic frontmatter+Findings scanner (E28-S108)
#
# Scans story markdown files in the implementation-artifacts directory and
# extracts tech-debt candidates ONLY from:
#   1. YAML frontmatter (between the first two --- delimiters)
#   2. The "## Findings" section
#
# Never reads full story bodies — the legacy rule (token budget protection,
# critical mandate in the tech-debt-review instructions.xml).
#
# For each story, emits one line per tech-debt candidate in pipe-delimited
# form for easy downstream parsing:
#
#   <story_key>|<status>|<sprint_id>|<type>|<severity>|<finding>|<action>
#
# Where:
#   type    — 'tech-debt' always, plus 'bug:medium' / 'bug:low' that are not
#             marked [TRIAGED] or [DISMISSED] (same rule as legacy Step 1).
#
# Usage:
#   scan-findings.sh --artifacts-dir <path>
#
# Exit codes:
#   0 — scan complete (zero findings is NOT an error)
#   1 — usage error, or artifacts dir not readable

set -euo pipefail
LC_ALL=C
export LC_ALL

usage() {
  cat >&2 <<EOF
Usage:
  scan-findings.sh --artifacts-dir <path>

Scans <path>/*.md files' YAML frontmatter + "## Findings" section only.
Emits pipe-delimited tech-debt candidates (one per line):
  <story_key>|<status>|<sprint_id>|<type>|<severity>|<finding>|<action>
EOF
  exit 1
}

ARTIFACTS_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts-dir)
      shift
      [ -n "${1:-}" ] || usage
      ARTIFACTS_DIR="$1"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'scan-findings.sh: unknown arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[ -n "$ARTIFACTS_DIR" ] || usage
[ -d "$ARTIFACTS_DIR" ] || { printf 'scan-findings.sh: not a directory: %s\n' "$ARTIFACTS_DIR" >&2; exit 1; }

# Iterate over *.md files. Use null-delimited find for spaces safety.
while IFS= read -r -d '' story_file; do
  base="${story_file##*/}"
  # Match story-key pattern E{digits}-S{digits} at the start of the filename
  story_key=""
  if [[ "$base" =~ ^(E[0-9]+-S[0-9]+) ]]; then
    story_key="${BASH_REMATCH[1]}"
  fi
  [ -n "$story_key" ] || continue

  # Extract frontmatter block between the first two --- lines (awk — no yq)
  fm=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (seen == 0) { in_fm = 1; seen = 1; next }
      else if (in_fm == 1) { in_fm = 0; exit }
    }
    in_fm == 1 { print }
  ' "$story_file")

  # Extract status and sprint_id from frontmatter
  status=$(printf '%s\n' "$fm" | awk -F: '/^status[[:space:]]*:/ { sub(/^status[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }')
  sprint_id=$(printf '%s\n' "$fm" | awk -F: '/^sprint_id[[:space:]]*:/ { sub(/^sprint_id[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }')

  # Extract "## Findings" section — stop at next ## heading or EOF
  findings_section=$(awk '
    /^## Findings[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section { print }
  ' "$story_file")

  [ -n "$findings_section" ] || continue

  # Parse table rows — skip header / separator lines / placeholder dash rows
  while IFS= read -r line; do
    # Skip non-pipe lines and separator rows
    case "$line" in
      *\|*) ;;
      *) continue ;;
    esac
    case "$line" in
      *---*) continue ;;
    esac
    # Strip leading/trailing pipes, then split by |
    trimmed="${line## }"
    trimmed="${trimmed%% }"
    # Expect at least 6 pipe-separated cells: #, Type, Severity, Finding, Action
    # (header has these; legacy rows may have 5 or 6; be lenient)
    IFS='|' read -r _blank col1 col2 col3 col4 col5 _rest <<<"$trimmed"
    # Trim cell whitespace
    col1="${col1## }"; col1="${col1%% }"
    col2="${col2## }"; col2="${col2%% }"
    col3="${col3## }"; col3="${col3%% }"
    col4="${col4## }"; col4="${col4%% }"
    col5="${col5## }"; col5="${col5%% }"
    # Skip header row ("# Type Severity ...") and dash-placeholder row
    if [ "$col1" = "Type" ] || [ "$col1" = "—" ] || [ -z "$col1" ]; then
      continue
    fi
    type="$col1"
    severity="$col2"
    finding="$col3"
    action="$col4"
    # Legacy rule: tech-debt type always included; bug with medium/low severity
    # included UNLESS marked [TRIAGED] or [DISMISSED] in the finding text
    include=0
    case "$type" in
      tech-debt)
        include=1
        ;;
      bug)
        if [ "$severity" = "medium" ] || [ "$severity" = "low" ]; then
          if ! printf '%s' "$finding" | grep -qE '\[TRIAGED|\[DISMISSED'; then
            include=1
            type="bug:$severity"
          fi
        fi
        ;;
    esac
    [ "$include" -eq 1 ] || continue
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$story_key" "$status" "$sprint_id" "$type" "$severity" "$finding" "$action"
  done <<<"$findings_section"

# E55-S12 — recursive walk picks up the per-epic nested layout introduced by E79
# (`epic-*/stories/{key}-{slug}.md`). Convergence with the E79-S4 reader idiom.
done < <(find "$ARTIFACTS_DIR" -type f -name '*.md' -print0)

exit 0
