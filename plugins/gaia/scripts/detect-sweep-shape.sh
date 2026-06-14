#!/usr/bin/env bash
# detect-sweep-shape.sh — sweep/facet sprint-shape predicate (plan-time).
#
# A sweep-shaped sprint maps its goals 1:1 to single stories; a facet-shaped
# sprint decomposes one epic into serial facets. Both trip the sprint-review
# incidental-goal / velocity-distribution floor, which was built for multi-story
# outcome goals. /gaia-sprint-plan calls this predicate at commit time to decide
# whether to stamp the completion-pass shape (via the sanctioned sprint-state
# writer) so the review-time floor relaxes for the shape.
#
# PURE + READ-ONLY + COLD-START SAFE. The verdict is computed from the committed
# story selection and the final goal count ALONE — epic membership is derived
# from the E<n>-S<n> key, never from sprint history or velocity telemetry. A
# project with no closed-sprint telemetry resolves the shape identically.
#
# Conservative by design: a false negative (not stamping) is safer than a false
# positive (suppressing a genuine multi-outcome sprint's floor). The predicate
# fires ONLY for the two unambiguous shapes below; everything else is no-stamp.
#
# Predicate — stamp completion-pass when EITHER:
#   (a) 1:1 sweep        — goal count == story count AND story count >= 2
#                          (every goal maps to exactly one story); OR
#   (b) facet decomposition — every selected story belongs to the SAME epic
#                          (same E<n> prefix) AND story count >= 3
#                          (one epic split into >= 3 serial facets).
# Otherwise: no stamp.
#
# Invocation:
#   detect-sweep-shape.sh --stories "K1,K2,..." --goals <N>
#   detect-sweep-shape.sh --help
#
# Output / exit codes:
#   0  — sweep/facet detected; prints "completion-pass" on stdout.
#   10 — no-stamp verdict (multi-outcome / too small); prints nothing.
#   1  — bad arguments.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="detect-sweep-shape.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
detect-sweep-shape.sh — sweep/facet sprint-shape predicate (plan-time)

Usage:
  detect-sweep-shape.sh --stories "K1,K2,..." --goals <N>

Pure, read-only, cold-start-safe. Prints "completion-pass" and exits 0 when the
committed selection is a 1:1 sweep (goal count == story count, >= 2 stories) or
a single-epic facet decomposition (all stories share one epic, >= 3 stories).
Otherwise prints nothing and exits 10. The verdict uses only the story keys
(epic via the E<n>-S<n> prefix) and the goal count — no sprint telemetry.
USAGE
  exit 0
fi

STORIES=""
GOALS=""
have_stories=0
have_goals=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stories) STORIES="${2:-}"; have_stories=1; shift 2 ;;
    --goals)   GOALS="${2:-}";   have_goals=1;   shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$have_stories" -eq 1 ] || die "missing required --stories \"K1,K2,...\""
[ "$have_goals" -eq 1 ]   || die "missing required --goals <N>"
[ -n "$STORIES" ]         || die "--stories must not be empty"

case "$GOALS" in
  ''|*[!0-9]*) die "--goals must be a non-negative integer, got: $GOALS" ;;
esac

# Split the comma-separated key list into a count and a unique-epic count.
# Epic = the leading E<n> token of an E<n>-S<n> key. Keys are trimmed of
# surrounding whitespace so callers may pass "K1, K2, K3".
n_stories=0
epics=""
IFS=','
for raw in $STORIES; do
  # Trim leading/trailing whitespace (bash 3.2 safe).
  key="${raw#"${raw%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  [ -n "$key" ] || continue
  n_stories=$((n_stories + 1))
  epic="${key%%-*}"
  case " $epics " in
    *" $epic "*) ;;            # already counted
    *) epics="$epics $epic" ;;
  esac
done
unset IFS

# Count distinct epics.
n_epics=0
for _e in $epics; do
  n_epics=$((n_epics + 1))
done

# (a) 1:1 sweep — one goal per story, at least two stories.
if [ "$n_stories" -ge 2 ] && [ "$GOALS" -eq "$n_stories" ]; then
  printf 'completion-pass\n'
  exit 0
fi

# (b) facet decomposition — all stories share one epic, at least three facets.
if [ "$n_stories" -ge 3 ] && [ "$n_epics" -eq 1 ]; then
  printf 'completion-pass\n'
  exit 0
fi

# No-stamp: multi-outcome or too small to classify. Conservative default.
exit 10
