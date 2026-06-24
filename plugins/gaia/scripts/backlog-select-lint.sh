#!/usr/bin/env bash
# backlog-select-lint.sh — column-sourced pre-materialization dependency lint
#
# Inverts the sprint-plan contract: select stories directly from the backlog
# (epics-and-stories.md ROSTER columns) WITHOUT requiring pre-materialized
# `ready-for-dev` story files. This is the net-new column-sourced lint —
# `sprint-state.sh lint-dependencies` reads story-file frontmatter + the sprint
# roster, NOT the markdown columns.
#
# It extracts HARD dependency keys from three sources, unioned per candidate:
#   1. Pipe-delimited ROSTER row: | Story | ... | Depends on | Blocks |
#   2. Bold-label detail block:  - **Depends on:** [E1-S2, E3-S4]
#   3. Story-file frontmatter:    depends_on: [E1-S2]
# All three share the same dep-cell grammar: `none`, comma-separated, semicolon
# soft-deps (`E900-S1; soft on E902-S2` -> only E900-S1 is hard), range
# (`E66-S1..S2`), and parenthetical annotations (`E900-S1 (Step 4 hook)` ->
# bare key E900-S1). A candidate HARD-BLOCKS when a hard-dep target is neither
# in --done nor co-selected in --candidates. Soft-deps and parentheticals never
# block.
#
# Pure + READ-ONLY: the caller (gaia-sprint-plan) derives --done (closed-sprint
# archives / epic-block status) and --candidates (the selection set); this lint
# does not scan history itself. Output on stdout; never mutates epics-and-stories.
#
# Invocation:
#   backlog-select-lint.sh --epics <epics-and-stories.md> --candidates "K1,K2,..."
#       [--done "K1,K2,..."] [--json]
#   backlog-select-lint.sh --help
#
# Exit codes:
#   0 — all candidates' hard deps satisfied (no block)
#   1 — bad arguments
#   2 — at least one candidate HARD-BLOCKED (unmet hard dep)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="backlog-select-lint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
backlog-select-lint.sh — column-sourced pre-materialization dependency lint

Usage:
  backlog-select-lint.sh --epics <epics-and-stories.md> --candidates "K1,K2,..."
      [--done "K1,K2,..."] [--json]

Extracts HARD deps from three sources per candidate, unioned together:
  1. Pipe-delimited ROSTER row (| Story | ... | Depends on | ...)
  2. Bold-label detail block (- **Depends on:** [...])
  3. Story-file frontmatter (depends_on: [...])
Soft-deps (; soft on ...) and parenthetical annotations never block.
HARD-BLOCKS when a hard-dep target is neither done nor co-selected. READ-ONLY.
USAGE
  exit 0
fi

EPICS=""
CANDIDATES=""
DONE_SET=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --epics) EPICS="${2:-}"; shift 2 ;;
    --candidates) CANDIDATES="${2:-}"; shift 2 ;;
    --done) DONE_SET="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$EPICS" ] || die "--epics <epics-and-stories.md> is required (try --help)"
[ -r "$EPICS" ] || die "epics file not found/readable: $EPICS"
[ -n "$CANDIDATES" ] || die "--candidates \"K1,K2,...\" is required (try --help)"

# normalize a comma-separated list -> space-separated, trimmed
_norm_list() { printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^E[0-9]+-S[0-9]+$' || true; }

CAND_KEYS="$(_norm_list "$CANDIDATES")"
DONE_KEYS="$(_norm_list "$DONE_SET")"

_in_set() { # $1 = key ; $2 = newline list
  printf '%s\n' "$2" | grep -Fxq "$1"
}

# Shared dep-cell grammar normalizer. Takes a raw dep-cell string as $1
# (e.g. "E900-S1; soft on E902-S2" or "E900-S1 (Step 4 hook), E901-S9").
# Strips soft-dep tail (after ";"), parenthetical annotations, handles
# none/empty, splits on commas, expands E#-S#..S# ranges, and emits one
# bare E#-S# key per line. Used by all three extraction paths.
_normalize_dep_cell() {
  local raw="$1"
  awk -v cell="$raw" '
    BEGIN {
      # Strip enclosing brackets.
      gsub(/[\[\]]/, "", cell)
      # Drop soft-dep tail: everything from the first ";" onward is soft/advisory.
      sub(/;.*$/, "", cell)
      # Drop parenthetical annotations.
      gsub(/\([^)]*\)/, "", cell)
      # Trim whitespace.
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      if (cell == "" || tolower(cell) == "none") exit
      # Split on commas; emit bare story keys.
      n = split(cell, parts, ",")
      for (i = 1; i <= n; i++) {
        t = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        # Range form E#-S#..S# -> emit both endpoint keys.
        if (t ~ /^E[0-9]+-S[0-9]+\.\.S[0-9]+$/) {
          split(t, rp, /\.\./); print rp[1]
          epic = rp[1]; sub(/-S[0-9]+$/, "", epic); print epic "-" rp[2]
          continue
        }
        if (t ~ /^E[0-9]+-S[0-9]+$/) print t
      }
    }
  '
}

# Extract the raw `Depends on` cell for one story key from the pipe-table
# ROSTER row. Returns the raw cell text (before normalization).
_raw_roster_dep_cell() {
  local key="$1"
  awk -F'|' -v k="$key" '
    depcol == 0 && /\|/ && tolower($0) ~ /depends on/ && tolower($0) ~ /story/ {
      for (i = 1; i <= NF; i++) {
        h = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
        if (tolower(h) == "depends on") { depcol = i }
      }
      next
    }
    depcol > 0 {
      c1=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c1)
      if (c1 != k) next
      dep=$depcol; gsub(/^[[:space:]]+|[[:space:]]+$/, "", dep)
      print dep; exit
    }
  ' "$EPICS"
}

# Extract the raw `- **Depends on:** ...` value for one story key from its
# bold-label detail block under `### Story <KEY>:`. Returns raw cell text.
_raw_detail_block_dep_cell() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^### Story " k ":" || $0 ~ "^### Story " k "[[:space:]]*$" {
      found = 1; next
    }
    found && /^##/ { exit }
    found && /^- \*\*Depends on:\*\*/ {
      line = $0
      sub(/^- \*\*Depends on:\*\*[[:space:]]*/, "", line)
      print line; exit
    }
  ' "$EPICS"
}

# Parse hard deps from pipe-table ROSTER row for one story key.
# Sniffs the Depends-on column index from the header row (tolerates column
# reorder). Returns bare hard-dep keys, one per line.
_hard_deps_of() {
  local raw
  raw="$(_raw_roster_dep_cell "$1")"
  [ -n "$raw" ] || return 0
  _normalize_dep_cell "$raw"
}

# Parse hard deps from bold-label detail block for one story key.
_detail_block_deps_of() {
  local raw
  raw="$(_raw_detail_block_dep_cell "$1")"
  [ -n "$raw" ] || return 0
  _normalize_dep_cell "$raw"
}

blocked_json="[]"
blocked_lines=""
overall_blocked=0


# Also read depends_on from the per-story frontmatter as a fallback. The
# pipe-table roster parser misses the dependency when the row's "Depends on"
# column is empty/None but the individual story file declares
# `depends_on: [E3-S6]` in its frontmatter. This block resolves each
# candidate's story file and unions the frontmatter depends_on list into the
# deps already gathered from the roster — never trusts only one source.
_frontmatter_deps_of() {
  local key="$1"
  local impl_root="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"
  local story_file=""
  # Prefer per-story layout.
  story_file=$(find "$impl_root" -type f -path "*/epic-*/${key}-*/story.md" 2>/dev/null | head -1)
  if [ -z "$story_file" ]; then
    # Legacy nested.
    story_file=$(find "$impl_root" -type f -path "*/epic-*/stories/${key}-*.md" 2>/dev/null | head -1)
  fi
  if [ -z "$story_file" ]; then
    # Legacy flat.
    story_file=$(find "$impl_root" -maxdepth 1 -type f -name "${key}-*.md" 2>/dev/null | head -1)
  fi
  [ -n "$story_file" ] && [ -f "$story_file" ] || return 0
  # Extract raw depends_on tokens from YAML frontmatter, then post-filter
  # through _normalize_dep_cell so parenthetical annotations, soft-dep tails,
  # and range expansions are handled identically to roster and detail-block
  # paths. The awk handles YAML structure (frontmatter delimiters, key
  # detection, inline-list vs block-list grammar); _normalize_dep_cell handles
  # the dep-cell grammar shared by all three extraction paths.
  local raw_fm
  raw_fm="$(awk '
    BEGIN { in_fm=0; in_deps=0 }
    /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
    !in_fm { next }
    /^depends_on:[[:space:]]*\[/ {
      # Inline list shape: depends_on: [E1-S1, E2-S3]
      line=$0; sub(/^depends_on:[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
      n=split(line, parts, ",")
      for (i=1;i<=n;i++) { gsub(/[[:space:]"]/, "", parts[i]); if (parts[i] != "") print parts[i] }
      in_deps=0; next
    }
    /^depends_on:[[:space:]]*$/ { in_deps=1; next }
    in_deps && /^[[:space:]]*-[[:space:]]/ {
      t=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", t); gsub(/[[:space:]"]+$/, "", t)
      gsub(/^"/, "", t)
      if (t != "") print t
    }
    in_deps && /^[^[:space:]-]/ { in_deps=0 }
  ' "$story_file")"
  [ -n "$raw_fm" ] || return 0
  # Join tokens with commas and normalise through the shared dep-cell grammar.
  local joined
  joined="$(printf '%s' "$raw_fm" | tr '\n' ',' | sed 's/,$//')"
  _normalize_dep_cell "$joined"
}

for cand in $CAND_KEYS; do
  roster_deps="$(_hard_deps_of "$cand")"
  detail_deps="$(_detail_block_deps_of "$cand")"
  fm_deps="$(_frontmatter_deps_of "$cand")"
  # Union all three sources, dedup.
  deps="$(printf '%s\n%s\n%s\n' "$roster_deps" "$detail_deps" "$fm_deps" | awk 'NF && !seen[$0]++')"
  for d in $deps; do
    [ -n "$d" ] || continue
    if _in_set "$d" "$DONE_KEYS" || _in_set "$d" "$CAND_KEYS"; then
      continue  # satisfied: dep is done OR co-selected
    fi
    # unmet hard dep -> HARD BLOCK
    overall_blocked=1
    blocked_lines="${blocked_lines}${cand}\tunmet hard dependency ${d} (neither done nor co-selected)\n"
    blocked_json="$(printf '%s' "$blocked_json" | jq -c --arg c "$cand" --arg d "$d" '. + [{candidate:$c, unmet_dep:$d}]')"
  done
done

# de-dup the candidate list as JSON array
cand_json="$(printf '%s\n' "$CAND_KEYS" | jq -R . | jq -sc 'map(select(length>0))')"

if [ "$JSON_OUT" -eq 1 ]; then
  jq -nc --argjson candidates "$cand_json" --argjson blocked "$blocked_json" \
    '{candidates: $candidates, blocked: $blocked}'
else
  printf 'backlog dependency lint — %d candidate(s)\n' "$(printf '%s\n' "$CAND_KEYS" | grep -c . || true)"
  if [ "$overall_blocked" -eq 1 ]; then
    printf '\nHARD-BLOCKED (unmet hard dependencies):\n'
    printf '%b' "$blocked_lines" | sed 's/^/  /'
  else
    printf 'capacity: ok — all candidate hard dependencies are done or co-selected\n'
  fi
fi

[ "$overall_blocked" -eq 1 ] && exit 2
exit 0
