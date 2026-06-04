#!/usr/bin/env bash
# resolve-write-path.sh — AF-2026-05-30-2 / Test10 F-16: script-enforced
# same-day adversarial-review filename collision avoidance.
#
# Prior to this helper the SKILL.md prose said "if the file exists for the
# same day, write to a suffix-incremented filename (...-2.md, -3.md, ...)"
# but enforcement was up to the LLM caller — a careless run could overwrite
# the prior review. This helper resolves the next non-colliding path
# deterministically so the caller just consumes stdout.
#
# Usage:
#   resolve-write-path.sh --target <name> --date <YYYY-MM-DD> [--root <dir>] [--paired]
#
#   --target   the adversarial-review target (prd | architecture | ux-design | ...)
#   --date     YYYY-MM-DD stamp
#   --root     planning_artifacts root (default: .gaia/artifacts/planning-artifacts)
#   --paired   emit BOTH the .md and the .json sidecar path for the SAME
#              collision index — atomic pairing (E87-S11 / AF-2026-06-03-3,
#              Val F1). The .md path is printed on line 1, the .json sibling on
#              line 2. Without --paired the legacy .md-only behavior is
#              preserved verbatim (single .md path on stdout).
#
# Exit codes:
#   0 — path(s) printed on stdout (mkdir -p of parent done)
#   1 — bad args
#
# Output path shape (AF-30-1 / Test03 §7.3 adversarial/ subdir):
#   <root>/adversarial/adversarial-review-<target>-<date>.md          (first)
#   <root>/adversarial/adversarial-review-<target>-<date>-2.md        (collision 1)
#   <root>/adversarial/adversarial-review-<target>-<date>-3.md        (collision 2)
#   ...
#
# Paired collision rule (--paired, E87-S11): the .md and .json share one index.
# The next free index is the smallest N for which NEITHER <base>[-N].md NOR
# <base>[-N].json exists, so a consumer that finds <base>-2.md can always
# locate the matching <base>-2.json.

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}}"
TARGET=""
DATE_STAMP=""
ROOT="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts"
PAIRED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --date)   DATE_STAMP="$2"; shift 2 ;;
    --root)   ROOT="$2"; shift 2 ;;
    --paired) PAIRED=1; shift ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "resolve-write-path: unknown arg '$1'" >&2
      exit 1
      ;;
  esac
done

if [ -z "$TARGET" ] || [ -z "$DATE_STAMP" ]; then
  echo "resolve-write-path: --target and --date are required" >&2
  exit 1
fi

DIR="${ROOT}/adversarial"
mkdir -p "$DIR"

BASE="adversarial-review-${TARGET}-${DATE_STAMP}"

if [ "$PAIRED" -eq 1 ]; then
  # Paired mode — the .md and .json share one collision index. The next free
  # index is the smallest N for which NEITHER sibling exists, so the pair is
  # always co-located at the same suffix (atomic pairing, Val F1).
  if [ ! -e "${DIR}/${BASE}.md" ] && [ ! -e "${DIR}/${BASE}.json" ]; then
    printf '%s\n' "${DIR}/${BASE}.md"
    printf '%s\n' "${DIR}/${BASE}.json"
    exit 0
  fi
  n=2
  while [ -e "${DIR}/${BASE}-${n}.md" ] || [ -e "${DIR}/${BASE}-${n}.json" ]; do
    n=$((n + 1))
  done
  printf '%s\n' "${DIR}/${BASE}-${n}.md"
  printf '%s\n' "${DIR}/${BASE}-${n}.json"
  exit 0
fi

# Default (.md-only) mode — preserved verbatim (backward-compatible).
CANDIDATE="${DIR}/${BASE}.md"
if [ ! -e "$CANDIDATE" ]; then
  printf '%s\n' "$CANDIDATE"
  exit 0
fi

# Same-day collision — find next free suffix.
n=2
while [ -e "${DIR}/${BASE}-${n}.md" ]; do
  n=$((n + 1))
done
printf '%s\n' "${DIR}/${BASE}-${n}.md"
