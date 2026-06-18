#!/usr/bin/env bash
# extract-findings.sh — gaia-triage-findings per-story Findings extractor
#
# Extracts tech-debt / finding candidates from a SINGLE story file's
#   1. YAML frontmatter (between the first two --- delimiters)
#   2. "## Findings" section
# and NOTHING else. The full story body (User Story, Tasks, Dev Notes, etc.)
# is NEVER read into the output — this is the token-budget-protection mandate
# that /gaia-triage-findings previously lacked (its Step 1 LLM-read whole
# files). Adapts the deterministic frontmatter+Findings scanner pattern (the
# former tech-debt-review directory walker) to operate on ONE file so the
# caller can scope the scan to a sprint's committed stories.
#
# Per finding row, emits one pipe-delimited line:
#   <story_key>|<status>|<sprint_id>|<type>|<severity>|<finding>|<action>
#
# Story-key resolution: from the basename when it matches `E{N}-S{M}-…`, or
# from the parent directory name when the basename is the canonical `story.md`.
#
# Usage:
#   extract-findings.sh --story-file <path>
#
# Exit codes:
#   0 — extraction complete (zero findings is NOT an error)
#   1 — usage error, or the story file does not exist / is unreadable

set -euo pipefail
LC_ALL=C
export LC_ALL

STORY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --story-file) STORY_FILE="${2:-}"; shift 2 ;;
    *) printf 'extract-findings.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$STORY_FILE" ] || { printf 'extract-findings.sh: --story-file is required\n' >&2; exit 1; }
[ -f "$STORY_FILE" ] || { printf 'extract-findings.sh: not a file: %s\n' "$STORY_FILE" >&2; exit 1; }

# ---------- Resolve the story key ----------
base="${STORY_FILE##*/}"
story_key=""
if [[ "$base" =~ ^(E[0-9]+-S[0-9]+) ]]; then
  story_key="${BASH_REMATCH[1]}"
elif [ "$base" = "story.md" ]; then
  parent_dir="$(dirname "$STORY_FILE")"
  parent_base="${parent_dir##*/}"
  if [[ "$parent_base" =~ ^(E[0-9]+-S[0-9]+) ]]; then
    story_key="${BASH_REMATCH[1]}"
  fi
fi
# A story file we cannot key is not an error — emit nothing.
[ -n "$story_key" ] || exit 0

# ---------- Frontmatter (first two --- delimiters) — awk, no yq ----------
fm=$(awk '
  BEGIN { in_fm = 0; seen = 0 }
  /^---[[:space:]]*$/ {
    if (seen == 0) { in_fm = 1; seen = 1; next }
    else if (in_fm == 1) { in_fm = 0; exit }
  }
  in_fm == 1 { print }
' "$STORY_FILE")

status=$(printf '%s\n' "$fm" | awk -F: '/^status[[:space:]]*:/ { sub(/^status[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }')
sprint_id=$(printf '%s\n' "$fm" | awk -F: '/^sprint_id[[:space:]]*:/ { sub(/^sprint_id[[:space:]]*:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }')

# ---------- "## Findings" section — stop at next ## heading or EOF ----------
findings_section=$(awk '
  /^## Findings[[:space:]]*$/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section { print }
' "$STORY_FILE")

# No findings section → nothing to emit (frontmatter-only stories are clean).
[ -n "$findings_section" ] || exit 0

# ---------- Parse the Findings table ----------
while IFS= read -r line; do
  case "$line" in
    *\|*) ;;          # only pipe-delimited rows
    *) continue ;;
  esac
  case "$line" in
    *---*) continue ;; # separator row
  esac
  trimmed="${line## }"; trimmed="${trimmed%% }"
  IFS='|' read -r _blank col1 col2 col3 col4 col5 _rest <<<"$trimmed"
  col1="${col1## }"; col1="${col1%% }"
  col2="${col2## }"; col2="${col2%% }"
  col3="${col3## }"; col3="${col3%% }"
  col4="${col4## }"; col4="${col4%% }"
  col5="${col5## }"; col5="${col5%% }"
  # Skip header / placeholder rows.
  if [ "$col1" = "#" ] || [ "$col1" = "ID" ] || [ "$col2" = "Type" ] || [ "$col2" = "Severity" ] || [ "$col1" = "—" ] || [ -z "$col1$col2" ]; then
    continue
  fi
  type=""; severity=""; finding=""; action=""
  case "$col2" in
    tech-debt|bug|framework-defect|security|test-debt|process-debt|code-debt|doc-debt|design-debt)
      type="$col2"; severity="$col3"; finding="$col4"; action="$col5" ;;
    *)
      case "$col1" in
        BUG-*|B-*|Bug-*) type="bug" ;;
        *) type="tech-debt" ;;
      esac
      severity="$col2"; finding="$col3"; action="$col4" ;;
  esac
  # Universal marker exclusion: skip any finding already processed by a
  # prior triage run, regardless of type. The markers [TRIAGED] and
  # [DISMISSED] are appended to the finding or action text by the triage
  # workflow; re-emitting them would break idempotency.
  if printf '%s' "$finding $action" | grep -qE '\[TRIAGED|\[DISMISSED'; then
    continue
  fi
  include=0
  case "$type" in
    tech-debt|framework-defect|test-debt|process-debt|code-debt|doc-debt|design-debt|security)
      include=1 ;;
    bug)
      if [ "$severity" = "medium" ] || [ "$severity" = "low" ]; then
        include=1; type="bug:$severity"
      fi ;;
  esac
  [ "$include" -eq 1 ] || continue
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$story_key" "$status" "$sprint_id" "$type" "$severity" "$finding" "$action"
done <<<"$findings_section"

exit 0
