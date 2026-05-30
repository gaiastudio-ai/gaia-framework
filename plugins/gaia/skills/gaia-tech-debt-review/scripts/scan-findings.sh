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
  # OR (AF-2026-05-30-2 / Test10 F-28) at the start of the parent dir name
  # for the E105-S1 per-story layout where files are named `story.md` and
  # the key lives in the parent dir: epic-*/E{N}-S{M}-{slug}/story.md.
  story_key=""
  if [[ "$base" =~ ^(E[0-9]+-S[0-9]+) ]]; then
    story_key="${BASH_REMATCH[1]}"
  elif [ "$base" = "story.md" ]; then
    # Per-story layout — extract key from parent dir name.
    parent_dir="$(dirname "$story_file")"
    parent_base="${parent_dir##*/}"
    if [[ "$parent_base" =~ ^(E[0-9]+-S[0-9]+) ]]; then
      story_key="${BASH_REMATCH[1]}"
    fi
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
    # AF-2026-05-24-10 / Test02 F-22: the scanner originally read `col1`
    # as the Type column, but with the 5-col header `# | Type | Severity
    # | Finding | Action`, `col1` is the row-number `#` not Type. After
    # `_blank col1 col2 col3 col4 col5`, the actual columns are:
    #   _blank=leading-pipe, col1=#, col2=Type, col3=Severity,
    #   col4=Finding, col5=Action.
    # We now correctly map col2 → Type, col3 → Severity, etc.
    #
    # Additionally per F-22: dev-story templates ship a 4-column schema
    # (ID | Severity | Description | Status). Sniff the header to handle
    # both: if col2 is "Type" we use the 5-col schema; if col1 is "ID" we
    # use the 4-col legacy schema; otherwise we apply best-effort
    # heuristic.
    IFS='|' read -r _blank col1 col2 col3 col4 col5 _rest <<<"$trimmed"
    # Trim cell whitespace
    col1="${col1## }"; col1="${col1%% }"
    col2="${col2## }"; col2="${col2%% }"
    col3="${col3## }"; col3="${col3%% }"
    col4="${col4## }"; col4="${col4%% }"
    col5="${col5## }"; col5="${col5%% }"
    # Skip header rows and dash-placeholder rows. Header is recognized by
    # either col1="#" / "ID" or col2="Type" / "Severity".
    if [ "$col1" = "#" ] || [ "$col1" = "ID" ] || [ "$col2" = "Type" ] || [ "$col2" = "Severity" ] || [ "$col1" = "—" ] || [ -z "$col1$col2" ]; then
      continue
    fi
    # Determine schema from cell content. The 5-col schema has col2=Type
    # (one of: tech-debt, bug, framework-defect, security, etc.); the
    # 4-col schema has col1 as an ID (e.g. F-1) and col2 as severity.
    type=""
    severity=""
    finding=""
    action=""
    case "$col2" in
      tech-debt|bug|framework-defect|security|test-debt|process-debt|code-debt|doc-debt|design-debt)
        # 5-col canonical schema: # | Type | Severity | Finding | Action
        type="$col2"
        severity="$col3"
        finding="$col4"
        action="$col5"
        ;;
      *)
        # 4-col legacy dev-story schema: ID | Severity | Description | Status
        # No "Type" column → infer from the ID prefix or default to tech-debt.
        case "$col1" in
          BUG-*|B-*|Bug-*) type="bug" ;;
          *) type="tech-debt" ;;
        esac
        severity="$col2"
        finding="$col3"
        action="$col4"
        ;;
    esac
    # Legacy rule: tech-debt type always included; bug with medium/low severity
    # included UNLESS marked [TRIAGED] or [DISMISSED] in the finding text OR
    # action text (per F-23 below — we don't ship F-23 here but the scan
    # for both columns mirrors that recommended pattern).
    include=0
    case "$type" in
      tech-debt|framework-defect|test-debt|process-debt|code-debt|doc-debt|design-debt|security)
        include=1
        ;;
      bug)
        if [ "$severity" = "medium" ] || [ "$severity" = "low" ]; then
          if ! printf '%s' "$finding $action" | grep -qE '\[TRIAGED|\[DISMISSED'; then
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
