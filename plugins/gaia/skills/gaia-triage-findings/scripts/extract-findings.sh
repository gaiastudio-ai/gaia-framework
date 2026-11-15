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
#   2 — high/critical finding-count invariant violated

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

# ---------- Helpers (no subshell for common tokens) ----------

# Strip all leading and trailing whitespace (spaces, tabs, CR) from a value.
# Preserves internal whitespace.  No subshell.  Bash 3.2 / POSIX safe.
# Sets the global _result.
_trim() {
  _result="${1#"${1%%[![:space:]]*}"}"
  _result="${_result%"${_result##*[![:space:]]}"}"
}

# Lowercase a short ASCII token.  Most Findings values are already lowercase;
# the case-guard skips the tr subshell when no uppercase letter is present.
# Sets the global _result.
_lc_token() {
  case "$1" in
    *[A-Z]*) _result="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ;;
    *)       _result="$1" ;;
  esac
}

# Walk the cells of a pipe-delimited row in one pass.  Determines both
# placeholder status (all cells are em-dash / hyphen / empty) and whether any
# cell is an exact case-insensitive match for "high" or "critical".
# Sets globals: _is_placeholder, _found_high, _found_critical.
_scan_row_cells() {
  _is_placeholder=1
  _found_high=0
  _found_critical=0
  local _rem="$1" _cell
  _rem="${_rem#|}"
  _rem="${_rem%|}"
  while [ -n "$_rem" ]; do
    _cell="${_rem%%|*}"
    if [ "$_rem" = "$_cell" ]; then _rem=""; else _rem="${_rem#*|}"; fi
    _trim "$_cell"; _cell="$_result"
    # Placeholder: any non-dash, non-empty cell disqualifies.
    if [ -n "$_cell" ] && [ "$_cell" != "—" ] && [ "$_cell" != "-" ]; then
      _is_placeholder=0
    fi
    # Severity: case-insensitive exact match, at most once per row.
    case "$_cell" in
      [Hh][Ii][Gg][Hh])                          _found_high=1 ;;
      [Cc][Rr][Ii][Tt][Ii][Cc][Aa][Ll])          _found_critical=1 ;;
    esac
  done
}

# ---------- Parse the Findings table ----------
NL=$'\n'
output_buf=""
emitted_high=0
emitted_critical=0
five_col=0

while IFS= read -r line; do
  case "$line" in
    *\|*) ;;          # only pipe-delimited rows
    *) continue ;;
  esac
  case "$line" in
    *---*) continue ;; # separator row
  esac
  _trim "$line"; trimmed="$_result"
  IFS='|' read -r _blank col1 col2 col3 col4 col5 _rest <<<"$trimmed"
  _trim "$col1"; col1="$_result"
  _trim "$col2"; col2="$_result"
  _trim "$col3"; col3="$_result"
  _trim "$col4"; col4="$_result"
  _trim "$col5"; col5="$_result"
  _lc_token "$col2"; col2_lc="$_result"
  _lc_token "$col3"; col3_lc="$_result"
  # Detect five-column header (Type in col2, case-insensitive).
  if [ "$col2_lc" = "type" ]; then
    five_col=1
  fi
  # Skip header / placeholder rows.
  if [ "$col1" = "#" ] || [ "$col1" = "ID" ] || [ "$col2_lc" = "type" ] || [ "$col2_lc" = "severity" ] || [ "$col1" = "—" ] || [ -z "$col1$col2" ]; then
    continue
  fi
  type=""; severity=""; finding=""; action=""
  if [ "$five_col" -eq 1 ]; then
    # Five-column table: col2=type, col3=severity, col4=finding, col5=action.
    type="$col2_lc"
    severity="$col3_lc"
    finding="$col4"
    action="$col5"
  else
    # Legacy four-column table: col1=ID, col2=severity, col3=finding, col4=action.
    case "$col1" in
      BUG-*|B-*|Bug-*) type="bug" ;;
      *) type="tech-debt" ;;
    esac
    severity="$col2_lc"
    finding="$col3"
    action="$col4"
  fi
  # Universal marker exclusion: skip any finding already processed by a
  # prior triage run, regardless of type. The markers [TRIAGED] and
  # [DISMISSED] are appended to the finding or action text by the triage
  # workflow; re-emitting them would break idempotency.
  if printf '%s' "$finding $action" | grep -qE '\[TRIAGED|\[DISMISSED'; then
    continue
  fi
  include=0
  case "$type" in
    bug)
      include=1
      type="bug:$severity"
      ;;
    tech-debt|framework-defect|test-debt|process-debt|code-debt|doc-debt|design-debt|security)
      include=1
      ;;
    documentation|enhancement|missing-setup)
      include=1
      ;;
    *)
      # Non-standard types from five-column tables: include them.
      if [ "$five_col" -eq 1 ]; then
        include=1
      fi
      ;;
  esac
  [ "$include" -eq 1 ] || continue
  output_buf="${output_buf}${story_key}|${status}|${sprint_id}|${type}|${severity}|${finding}|${action}${NL}"
  case "$severity" in
    high)     emitted_high=$((emitted_high + 1)) ;;
    critical) emitted_critical=$((emitted_critical + 1)) ;;
  esac
done <<<"$findings_section"

# ---------- Independent high/critical finding-count invariant ----------
# Derive the source count with a fully separate scan of the raw Findings
# section.  This scan uses its OWN separator, header, and placeholder logic
# — it must NOT share the parser's *---* glob, col1/col2 header check, or
# em-dash-only placeholder rule so that rows the parser wrongly skips still
# trip the invariant.

source_high=0
source_critical=0
prev_line=""
header_line=""
while IFS= read -r raw_line; do
  # Only pipe-delimited rows.
  case "$raw_line" in
    *\|*) ;;
    *) prev_line="$raw_line"; continue ;;
  esac

  # TRUE separator: a row whose characters are all in { |, :, -, space }.
  # Tested with a case-glob instead of a tr subshell.
  case "$raw_line" in
    *[!\ \|:-]*)
      ;; # contains a non-separator character — not a separator
    *)
      # Pure separator row; the previous pipe-delimited row is the header.
      header_line="$prev_line"
      prev_line="$raw_line"
      continue
      ;;
  esac

  # Skip the header row itself (identified structurally above).
  if [ "$raw_line" = "$header_line" ]; then
    prev_line="$raw_line"
    continue
  fi

  # Skip TRIAGED/DISMISSED rows.
  case "$raw_line" in
    *'[TRIAGED'*|*'[DISMISSED'*) prev_line="$raw_line"; continue ;;
  esac

  # Single-pass cell scan: placeholder status + severity matches.
  _scan_row_cells "$raw_line"
  if [ "$_is_placeholder" -eq 1 ]; then
    prev_line="$raw_line"
    continue
  fi
  source_high=$((source_high + _found_high))
  source_critical=$((source_critical + _found_critical))

  prev_line="$raw_line"
done <<<"$findings_section"

# Check invariant: emitted counts must meet or exceed source counts.
missing=""
if [ "$emitted_critical" -lt "$source_critical" ]; then
  missing="critical"
fi
if [ "$emitted_high" -lt "$source_high" ]; then
  if [ -n "$missing" ]; then
    missing="${missing}, high"
  else
    missing="high"
  fi
fi

if [ -n "$missing" ]; then
  printf 'extract-findings.sh: %s: high/critical shortfall on %s (critical: source=%d emitted=%d; high: source=%d emitted=%d)\n' \
    "$story_key" "$missing" "$source_critical" "$emitted_critical" "$source_high" "$emitted_high" >&2
  exit 2
fi

# Flush the buffered output.
printf '%s' "$output_buf"
exit 0
