#!/usr/bin/env bash
# resolve-latest-dated.sh — latest-by-date artifact resolver (E105-S3)
#
# Resolves a dated-artifact family to its newest on-disk instance, with a
# read-side fallback to a legacy undated file. Formalizes the date-suffix
# convention (ADR-127 Pillar 3): periodically-reassessed plans
# (nfr-assessment, performance-test-plan) and per-event reports (adversarial,
# retrospective, anytime security-review) carry a `-{YYYY-MM-DD}` suffix and
# group under a named subdir; living docs carry no date.
#
# Resolution order (highest precedence first):
#   1. Newest `{dir}/{base}-{YYYY-MM-DD}.md` by lexicographic sort — YYYY-MM-DD
#      is fixed-width zero-padded, so string sort == date sort.
#   2. Read-side fallback: a legacy undated `{dir}/{base}.md`.
#   3. Neither present → non-zero exit with an actionable error.
# A dated file ALWAYS wins over an undated sibling for the same base.
#
# READ-ONLY — emits the resolved path on stdout, nothing else.
#
# Refs: ADR-127 Pillar 3, ADR-119, ADR-070, ADR-042, FR-555
#
# Invocation:
#   resolve-latest-dated.sh --dir <dir> --base <base-name-without-date-or-ext>
#   resolve-latest-dated.sh --help
#
# Exit codes:
#   0 — resolved; path on stdout
#   1 — bad arguments, or neither dated nor undated form found

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="resolve-latest-dated.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
resolve-latest-dated.sh — resolve the newest dated artifact (with undated fallback)

Usage:
  resolve-latest-dated.sh --dir <dir> --base <base>

Returns (on stdout) the newest {dir}/{base}-{YYYY-MM-DD}.md by date, or the
legacy undated {dir}/{base}.md when no dated form exists. A dated file always
wins over an undated sibling. READ-ONLY.
USAGE
  exit 0
fi

DIR=""
BASE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$DIR" ] || die "--dir <dir> is required (try --help)"
[ -n "$BASE" ] || die "--base <base> is required (try --help)"
[ -d "$DIR" ] || die "directory not found: $DIR"

# 1. Newest dated instance — glob `{base}-YYYY-MM-DD.md`, sort descending.
latest_dated=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  latest_dated="$f"   # first line of the descending (sort -r) stream is the newest (highest date)
  break
done < <(
  for cand in "$DIR/${BASE}"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
    [ -f "$cand" ] && printf '%s\n' "$cand"
  done | sort -r
)

if [ -n "$latest_dated" ]; then
  printf '%s\n' "$latest_dated"
  exit 0
fi

# 2. Read-side fallback: legacy undated file.
if [ -f "$DIR/${BASE}.md" ]; then
  printf '%s\n' "$DIR/${BASE}.md"
  exit 0
fi

# 3. Neither form exists.
die "artifact not found for base '${BASE}' in ${DIR} — searched ${BASE}-{YYYY-MM-DD}.md and ${BASE}.md"
