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
#   resolve-write-path.sh --target <name> --date <YYYY-MM-DD> [--root <dir>]
#
#   --target   the adversarial-review target (prd | architecture | ux-design | ...)
#   --date     YYYY-MM-DD stamp
#   --root     planning_artifacts root (default: .gaia/artifacts/planning-artifacts)
#
# Exit codes:
#   0 — path printed on stdout (mkdir -p of parent done)
#   1 — bad args
#
# Output path shape (AF-30-1 / Test03 §7.3 adversarial/ subdir):
#   <root>/adversarial/adversarial-review-<target>-<date>.md          (first)
#   <root>/adversarial/adversarial-review-<target>-<date>-2.md        (collision 1)
#   <root>/adversarial/adversarial-review-<target>-<date>-3.md        (collision 2)
#   ...

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}}"
TARGET=""
DATE_STAMP=""
ROOT="${PROJECT_ROOT}/.gaia/artifacts/planning-artifacts"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --date)   DATE_STAMP="$2"; shift 2 ;;
    --root)   ROOT="$2"; shift 2 ;;
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
