#!/usr/bin/env bash
# epic-status-dashboard.sh — deterministic epic completion dashboard formatter
#
# Test10 F-30 — `/gaia-epic-status` had no formatter script, contradicting
# ADR-042 (scripts-over-LLM). This script is the read-only rendering peer to
# sprint-status-dashboard.sh — it NEVER writes any artifact.
#
# Reads:
#   * `.gaia/artifacts/planning-artifacts/epics-and-stories.md` — epic list
#   * `.gaia/state/sprint-status.yaml` — per-story status (primary)
#   * `.gaia/artifacts/implementation-artifacts/` — story-file fallback when
#     sprint-status.yaml is missing
#
# Invocation:
#   epic-status-dashboard.sh [--epic <epic-key>] [--help]
#
# Environment:
#   PROJECT_PATH  — root of the project (defaults to ".")
#
# Exit codes:
#   0 — dashboard rendered successfully
#   1 — epics-and-stories.md not found or unparseable
#
# Heading-form acceptance (Test10 F-30 — epic-header em-dash parse drift):
#   Accepts both `## E{N} — Title` (em-dash U+2014) and `## E{N} - Title`
#   (ASCII hyphen) and `## Epic {N}: Title`. The earlier regex matched only
#   the em-dash form, dropping epics authored with a plain hyphen.
#
# POSIX discipline: bash 3.2 compatible (macOS default). set -euo pipefail.
# READ-ONLY: never writes any artifact.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="epic-status-dashboard.sh"

# ---------- Help ----------
_usage() {
  cat <<'USAGE'
epic-status-dashboard.sh — render epic completion dashboard from epics-and-stories.md + sprint-status.yaml

Usage:
  epic-status-dashboard.sh [--epic <epic-key>] [--help]

Options:
  --epic <key>   Filter to a single epic (e.g., --epic E28)
  --help         Show this message

Environment:
  PROJECT_PATH         Root of the project (default: ".")
  EPICS_FILE           Override epics-and-stories.md path
  SPRINT_STATUS_YAML   Override sprint-status.yaml path

Reads the epic and story sources and renders a markdown dashboard to stdout.
Falls back to scanning story files when sprint-status.yaml is missing.
This script is read-only — it NEVER modifies any artifact.
USAGE
}

epic_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --epic) epic_filter="${2:-}"; shift 2 ;;
    --epic=*) epic_filter="${1#--epic=}"; shift ;;
    -h|--help) _usage; exit 0 ;;
    *) printf '%s: unknown flag: %s\n' "$SCRIPT_NAME" "$1" >&2; _usage >&2; exit 2 ;;
  esac
done

# ---------- Resolve paths ----------
PROJECT_PATH="${PROJECT_PATH:-.}"
EPICS_FILE="${EPICS_FILE:-$PROJECT_PATH/.gaia/artifacts/planning-artifacts/epics-and-stories.md}"
SPRINT_STATUS_YAML="${SPRINT_STATUS_YAML:-$PROJECT_PATH/.gaia/state/sprint-status.yaml}"
IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-$PROJECT_PATH/.gaia/artifacts/implementation-artifacts}"

_log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_die()  { _log "ERROR: $*"; exit 1; }

[ -f "$EPICS_FILE" ] || _die "epics-and-stories.md not found at $EPICS_FILE"

# ---------- Parse epics from epics-and-stories.md ----------
# Accepts both `## E{N} — Title` (em-dash) AND `## E{N} - Title` (ASCII hyphen)
# AND `## Epic {N}: Title`. Stores results in two arrays:
#   epic_keys[i]   — e.g., "E1"
#   epic_titles[i] — e.g., "Foundation"
# Use newline-delimited string buffers (bash 3.2 — no associative arrays).
epic_list=$(awk '
  BEGIN { RS = "\n" }
  # Form (a): canonical em-dash
  /^## E[0-9]+[[:space:]]+\xe2\x80\x94[[:space:]]+/ {
    line = $0
    sub(/^## /, "", line)
    # split key from title on the em-dash
    n = index(line, "\xe2\x80\x94")
    key = substr(line, 1, n - 1)
    title = substr(line, n + 3)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
    print key "\t" title
    next
  }
  # Form (b): ASCII hyphen (Test10 F-30 fix)
  /^## E[0-9]+[[:space:]]+-[[:space:]]+/ {
    line = $0
    sub(/^## /, "", line)
    n = index(line, " - ")
    key = substr(line, 1, n - 1)
    title = substr(line, n + 3)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
    print key "\t" title
    next
  }
  # Form (c): `## Epic N: Title`
  /^## Epic[[:space:]]+[0-9]+:[[:space:]]+/ {
    line = $0
    sub(/^## Epic[[:space:]]+/, "", line)
    n = index(line, ":")
    num = substr(line, 1, n - 1)
    title = substr(line, n + 1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
    print "E" num "\t" title
    next
  }
' "$EPICS_FILE")

[ -n "$epic_list" ] || _die "no epic headings parsed from $EPICS_FILE (expected '## E<N> — Title', '## E<N> - Title', or '## Epic <N>: Title')"

# ---------- Story-status resolver ----------
# Returns one `KEY=STATUS` line per known story.
_resolve_statuses() {
  if [ -f "$SPRINT_STATUS_YAML" ]; then
    awk '
      /^stories:/ { in_stories = 1; next }
      in_stories && /^[a-z_]+:/ { in_stories = 0 }
      in_stories && /^[[:space:]]+- key:/ {
        v = $0
        sub(/^[[:space:]]+- key:[[:space:]]*/, "", v)
        gsub(/["'\''[:space:]]/, "", v)
        key = v
      }
      in_stories && /^[[:space:]]+status:/ {
        v = $0
        sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
        gsub(/["'\''[:space:]]/, "", v)
        if (key) { print key "=" v; key = "" }
      }
    ' "$SPRINT_STATUS_YAML"
  else
    _log "NOTICE: sprint-status.yaml not found — deriving status from individual story files"
    if [ -d "$IMPLEMENTATION_ARTIFACTS" ]; then
      find "$IMPLEMENTATION_ARTIFACTS" -type f -name '*.md' 2>/dev/null | while read -r f; do
        key=$(awk '
          /^---[[:space:]]*$/ { c++; if (c == 2) exit; next }
          c == 1 && /^key:/ { v=$0; sub(/^key:[[:space:]]*/, "", v); gsub(/["'\''[:space:]]/, "", v); print v; exit }
        ' "$f")
        status=$(awk '
          /^---[[:space:]]*$/ { c++; if (c == 2) exit; next }
          c == 1 && /^status:/ { v=$0; sub(/^status:[[:space:]]*/, "", v); gsub(/["'\''[:space:]]/, "", v); print v; exit }
        ' "$f")
        [ -n "$key" ] && [ -n "$status" ] && printf '%s=%s\n' "$key" "$status"
      done
    fi
  fi
}

statuses=$(_resolve_statuses || true)

# ---------- Per-epic metric computation ----------
# For each epic, scan epics-and-stories.md for `{EPIC}-S<N>` keys and look up
# their status in the resolved map. Render one row per epic.
_status_of() {
  printf '%s\n' "$statuses" | awk -v k="$1" -F= '$1 == k { print $2; exit }'
}

_render_header() {
  printf '| Epic | Name | Done | Total | %% | Backlog | Ready | In-Prog | Review | Done | Blocked |\n'
  printf '|------|------|-----:|------:|--:|--------:|------:|--------:|-------:|-----:|--------:|\n'
}

_render_row() {
  local key="$1" title="$2"
  local total=0 done_n=0 backlog=0 ready=0 in_prog=0 review=0 blocked=0
  local skeys
  skeys=$(grep -oE "\\b${key}-S[0-9]+\\b" "$EPICS_FILE" | sort -u || true)
  local sk st
  for sk in $skeys; do
    total=$((total + 1))
    st=$(_status_of "$sk")
    case "$st" in
      done)          done_n=$((done_n + 1)) ;;
      ready-for-dev) ready=$((ready + 1)) ;;
      in-progress)   in_prog=$((in_prog + 1)) ;;
      review)        review=$((review + 1)) ;;
      blocked)       blocked=$((blocked + 1)) ;;
      backlog|"")    backlog=$((backlog + 1)) ;;
      *)             backlog=$((backlog + 1)) ;;
    esac
  done
  local pct
  if [ "$total" -eq 0 ]; then
    pct='---'
  else
    pct=$(( done_n * 100 / total ))
  fi
  printf '| %s | %s | %d | %d | %s | %d | %d | %d | %d | %d | %d |\n' \
    "$key" "$title" "$done_n" "$total" "$pct" "$backlog" "$ready" "$in_prog" "$review" "$done_n" "$blocked"
}

# ---------- Render dashboard ----------
_render_header

# Sort by numeric epic key
sorted_epics=$(printf '%s\n' "$epic_list" | awk -F'\t' '{ n = $1; sub(/^E/, "", n); printf "%05d\t%s\n", n, $0 }' | sort | cut -f2-)

overall_total=0
overall_done=0
rendered_any=0
while IFS=$'\t' read -r ekey etitle; do
  [ -n "$ekey" ] || continue
  if [ -n "$epic_filter" ] && [ "$ekey" != "$epic_filter" ]; then
    continue
  fi
  rendered_any=1
  # tally for the overall line
  skeys=$(grep -oE "\\b${ekey}-S[0-9]+\\b" "$EPICS_FILE" | sort -u || true)
  for sk in $skeys; do
    overall_total=$((overall_total + 1))
    [ "$(_status_of "$sk")" = "done" ] && overall_done=$((overall_done + 1))
  done
  _render_row "$ekey" "$etitle"
done <<EOF
$sorted_epics
EOF

if [ "$rendered_any" -eq 0 ]; then
  if [ -n "$epic_filter" ]; then
    _log "no epic matched filter: $epic_filter"
    _log "available epics:"
    printf '%s\n' "$epic_list" | awk -F'\t' '{ print "  " $1 " — " $2 }' >&2
    exit 1
  fi
fi

# Overall summary
if [ "$overall_total" -gt 0 ]; then
  overall_pct=$(( overall_done * 100 / overall_total ))
else
  overall_pct=0
fi
printf '\nOverall: %d / %d stories done (%d%%)\n' "$overall_done" "$overall_total" "$overall_pct"
