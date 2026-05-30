#!/usr/bin/env bash
# backlog-select-lint.sh — column-sourced pre-materialization dependency lint (E107-S2)
#
# Inverts the sprint-plan contract: select stories directly from the backlog
# (epics-and-stories.md ROSTER columns) WITHOUT requiring pre-materialized
# `ready-for-dev` story files (fixes the Test02 F-9 silent-bypass). This is the
# net-new column-sourced lint — `sprint-state.sh lint-dependencies` reads
# story-file frontmatter + the sprint roster, NOT the markdown columns (Val F1).
#
# It parses the pipe-delimited ROSTER row (NOT the bold-label `**Depends on:**`
# detail blocks, Val W1):
#   | Story | Title | Size | Points | Risk | Depends on | Blocks |
# extracts HARD dependency keys from the `Depends on` cell — tolerant of the
# real dep-cell grammar (Val W2): `none`, comma-separated, semicolon soft-deps
# (`E900-S1; soft on E902-S2` → only E900-S1 is hard), range (`E66-S1..S2`),
# and parenthetical annotations (`E900-S1 (Step 4 hook)` → bare key E900-S1).
# A candidate HARD-BLOCKS when a hard-dep target is neither in --done nor
# co-selected in --candidates. Soft-deps and parentheticals never block.
#
# Pure + READ-ONLY: the caller (gaia-sprint-plan) derives --done (closed-sprint
# archives / epic-block status) and --candidates (the selection set); this lint
# does not scan history itself. Output on stdout; never mutates epics-and-stories.
#
# Refs: ADR-128, Test02 F-9, E106-S3, E107-S1, FR-558
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

Parses the epics-and-stories.md ROSTER columns (not story files, not the
bold-label **Depends on:** blocks). For each candidate, extracts HARD deps from
the `Depends on` cell (ignoring `; soft on ...` soft-deps and parenthetical
annotations) and HARD-BLOCKS when a hard-dep target is neither done nor
co-selected. Soft-deps never block. READ-ONLY.
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

# Parse the `Depends on` cell for one story key from the ROSTER row, returning
# the bare HARD-dep keys (one per line). Roster row shape (pipe-delimited):
#   | Story | Title | Size | Points | Risk | Depends on | Blocks |
# The `Depends on` column index is SNIFFED from the header row (Val W1: do not
# hard-code a positional field — tolerate column reorder / extra columns). Within
# the matched candidate row, soft-deps (text after `;`) and parentheticals are
# dropped; only bare E\d+-S\d+ tokens count as hard deps.
_hard_deps_of() {
  local key="$1"
  awk -F'|' -v k="$key" '
    # Sniff the Depends-on column index from the header row (the row whose cells
    # include a "Story" col and a "Depends on" col). depcol stays set thereafter.
    depcol == 0 && /\|/ && tolower($0) ~ /depends on/ && tolower($0) ~ /story/ {
      for (i = 1; i <= NF; i++) {
        h = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
        if (tolower(h) == "depends on") { depcol = i }
      }
      next
    }
    depcol > 0 {
      # a roster data row: field 2 (after leading |) == key
      c1=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c1)
      if (c1 != k) next
      dep=$depcol  # the sniffed "Depends on" column
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", dep)
      # drop soft-dep tail: everything from the first ";" onward is soft/advisory
      sub(/;.*$/, "", dep)
      # drop parenthetical annotations
      gsub(/\([^)]*\)/, "", dep)
      if (dep == "" || tolower(dep) == "none") next
      # split on commas; emit bare E#-S# tokens (expand A..B ranges defensively
      # by emitting both endpoints — the lint only needs the keys to match)
      n = split(dep, parts, ",")
      for (i = 1; i <= n; i++) {
        t = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        # range form E#-S#..S#  -> emit the first endpoint key (and the range end)
        if (t ~ /^E[0-9]+-S[0-9]+\.\.S[0-9]+$/) {
          split(t, rp, /\.\./); print rp[1]
          # synthesize the range-end key from the epic prefix
          epic = rp[1]; sub(/-S[0-9]+$/, "", epic); print epic "-" rp[2]
          continue
        }
        if (t ~ /^E[0-9]+-S[0-9]+$/) print t
      }
      exit
    }
  ' "$EPICS"
}

blocked_json="[]"
blocked_lines=""
overall_blocked=0


# AF-2026-05-30-2 / Test10 F-33: also read depends_on from the per-story
# frontmatter as a fallback. The pipe-table roster parser misses the
# dependency when the row's "Depends on" column is empty/None but the
# individual story file declares `depends_on: [E3-S6]` in its frontmatter.
# Test10 found E5-S4 had `depends_on: [E3-S6]` in its frontmatter but the
# roster row left it blank, so backlog-select-lint reported false-pass.
# This block resolves each candidate's story file and unions the
# frontmatter depends_on list into the deps already gathered from the
# roster — never trusts only one source.
_frontmatter_deps_of() {
  local key="$1"
  local impl_root="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:-.}/.gaia/artifacts/implementation-artifacts}"
  local story_file=""
  # Prefer per-story layout (E105-S1).
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
  # Extract depends_on YAML list values (one E#-S# token per line).
  awk '
    BEGIN { in_fm=0; in_deps=0 }
    /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
    !in_fm { next }
    /^depends_on:[[:space:]]*\[/ {
      # Inline list shape: depends_on: [E1-S1, E2-S3]
      line=$0; sub(/^depends_on:[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
      n=split(line, parts, ",")
      for (i=1;i<=n;i++) { gsub(/[[:space:]"]/, "", parts[i]); if (parts[i] ~ /^E[0-9]+-S[0-9]+$/) print parts[i] }
      in_deps=0; next
    }
    /^depends_on:[[:space:]]*$/ { in_deps=1; next }
    in_deps && /^[[:space:]]*-[[:space:]]*[Ee][0-9]+-[Ss][0-9]+/ {
      t=$0; gsub(/[[:space:]"-]/, "", t); if (t ~ /^E[0-9]+-S[0-9]+$/) print t
    }
    in_deps && /^[^[:space:]-]/ { in_deps=0 }
  ' "$story_file"
}

for cand in $CAND_KEYS; do
  roster_deps="$(_hard_deps_of "$cand")"
  fm_deps="$(_frontmatter_deps_of "$cand")"
  # Union the two sources, dedup.
  deps="$(printf '%s\n%s\n' "$roster_deps" "$fm_deps" | awk 'NF && !seen[$0]++')"
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
