#!/usr/bin/env bash
# planned-active-gate.sh — planned→active readiness gate
#
# A HARD GATE layered on the `planned → active` edge (which sprint-state.sh
# leaves unconditional — this is the skill-side pre-transition guard an
# operator/skill MUST run BEFORE `sprint-state.sh transition --to active`).
# It REFUSES activation unless EVERY sprint story:
#   (1) has a materialized file (resolve-story-file.sh) AND is `ready-for-dev`
#       (status read from the story FILE — the source of truth, not the yaml roster);
#   (2) if ATDD-required (risk: high per the /gaia-atdd predicate), has an ATDD
#       artifact under --test-artifacts (atdd-{epic}*.md OR atdd-{key}*.md);
#   (3) the elaborated batch passes the agent-native capacity check
#       (sm-capacity-check.sh) — read via --json `.flagged` (the script exits 0
#       whether flagged or not; exit 1 is bad-args only).
# The refusal message names EXACTLY which stories fail which check.
#
# Invocation:
#   planned-active-gate.sh --sprint-yaml <sprint-status.yaml> --impl-root <dir>
#       --test-artifacts <dir> [--events <jsonl>] [--depth-threshold N]
#       [--coherence-ceiling N] [--session-budget-min N]
#   planned-active-gate.sh --help
#
# Exit codes:
#   0 — gate PASSES (sprint is activatable)
#   1 — bad arguments
#   2 — gate REFUSES (one or more prerequisites unmet; message names the stories)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="planned-active-gate.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_STORY="$SCRIPT_DIR/resolve-story-file.sh"
CAPACITY="$SCRIPT_DIR/sm-capacity-check.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
planned-active-gate.sh — planned→active readiness gate

Usage:
  planned-active-gate.sh --sprint-yaml <sprint-status.yaml> --impl-root <dir>
      --test-artifacts <dir> [--events <jsonl>] [--depth-threshold N]
      [--coherence-ceiling N] [--session-budget-min N]

Run BEFORE `sprint-state.sh transition --sprint <id> --to active`. REFUSES
(exit 2) unless every sprint story is materialized + ready-for-dev, every
high-risk story has an ATDD artifact, and the batch passes the agent-native
capacity check. The refusal names exactly which stories fail. READ-ONLY.
USAGE
  exit 0
fi

SPRINT_YAML=""
IMPL_ROOT=""
TEST_ARTIFACTS=""
EVENTS=""
DEPTH_THRESHOLD=""
COHERENCE_CEILING=""
SESSION_BUDGET_MIN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sprint-yaml) SPRINT_YAML="${2:-}"; shift 2 ;;
    --impl-root) IMPL_ROOT="${2:-}"; shift 2 ;;
    --test-artifacts) TEST_ARTIFACTS="${2:-}"; shift 2 ;;
    --events) EVENTS="${2:-}"; shift 2 ;;
    --depth-threshold) DEPTH_THRESHOLD="${2:-}"; shift 2 ;;
    --coherence-ceiling) COHERENCE_CEILING="${2:-}"; shift 2 ;;
    --session-budget-min) SESSION_BUDGET_MIN="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$SPRINT_YAML" ] || die "--sprint-yaml <sprint-status.yaml> is required (try --help)"
[ -r "$SPRINT_YAML" ] || die "sprint yaml not found/readable: $SPRINT_YAML"
[ -n "$IMPL_ROOT" ] || die "--impl-root <dir> is required (try --help)"
[ -n "$TEST_ARTIFACTS" ] || die "--test-artifacts <dir> is required (try --help)"

# Roster keys from the sprint yaml stories[] block (the membership list).
roster_keys="$(awk '
  /^stories:[[:space:]]*$/ { in_s=1; next }
  in_s && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
    line=$0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", line); gsub(/"/, "", line); print line
  }
  in_s && /^[^[:space:]]/ { in_s=0 }
' "$SPRINT_YAML")"
[ -n "$roster_keys" ] || die "no stories[] roster found in $SPRINT_YAML"

unmaterialized=""
not_ready=""
missing_atdd=""

while IFS= read -r key; do
  [ -n "$key" ] || continue

  # (1) materialized? resolve the story file (UNMATERIALIZED if none)
  sf=""
  [ -x "$RESOLVE_STORY" ] && sf="$(IMPLEMENTATION_ARTIFACTS="$IMPL_ROOT" bash "$RESOLVE_STORY" "$key" 2>/dev/null || true)"
  if [ -z "$sf" ] || [ ! -f "$sf" ]; then
    unmaterialized="${unmaterialized}${unmaterialized:+ }${key}"
    continue   # can't check status/atdd without a file
  fi

  # (1) ready-for-dev? status from the story FILE (source of truth)
  st="$(awk '/^status:[[:space:]]*/{sub(/^status:[[:space:]]*/,""); gsub(/["\x27]/,""); sub(/[[:space:]]+$/,""); print; exit}' "$sf" 2>/dev/null)"
  if [ "$st" != "ready-for-dev" ]; then
    not_ready="${not_ready}${not_ready:+ }${key}(${st:-unknown})"
  fi

  # (2) ATDD-required (high-risk)? Apply the /gaia-atdd predicate+glob inline
  # against the story file we already resolved and the explicit --test-artifacts
  # dir (the atdd-gate.sh idiom — risk: high requires atdd-{epic}*.md OR
  # atdd-{key}*.md). We do NOT shell out to atdd-gate.sh here because it
  # re-resolves the story file via its own legacy path logic, which does not
  # honor an arbitrary --impl-root / the new per-story layout.
  risk="$(awk '/^risk:[[:space:]]*/{sub(/^risk:[[:space:]]*/,""); gsub(/["\x27]/,""); sub(/[[:space:]]+$/,""); print; exit}' "$sf" 2>/dev/null)"
  if [ "$risk" = "high" ]; then
    epic_key="${key%%-*}"
    atdd_found=0
    for cand in "$TEST_ARTIFACTS/atdd-${key}"*.md "$TEST_ARTIFACTS/atdd-${epic_key}"-*.md "$TEST_ARTIFACTS/atdd-${epic_key}".md; do
      [ -f "$cand" ] && { atdd_found=1; break; }
    done
    [ "$atdd_found" -eq 0 ] && missing_atdd="${missing_atdd}${missing_atdd:+ }${key}"
  fi
done <<EOF
$roster_keys
EOF

# (3) agent-native capacity — build a KEY|DEPS|POINTS stories-file from
# the roster (DEPS/POINTS unused by the three measures; KEY is what matters), run
# sm-capacity-check.sh and parse --json `.flagged` (exit 0 either way).
capacity_flagged=0
capacity_detail=""
if [ -x "$CAPACITY" ]; then
  cap_stories="$(mktemp "${TMPDIR:-/tmp}/pag-stories.XXXXXX")"
  while IFS= read -r key; do [ -n "$key" ] && printf '%s||\n' "$key" >> "$cap_stories"; done <<EOF
$roster_keys
EOF
  cap_args=(--stories-file "$cap_stories" --json)
  [ -n "$DEPTH_THRESHOLD" ] && cap_args+=(--depth-threshold "$DEPTH_THRESHOLD")
  [ -n "$COHERENCE_CEILING" ] && cap_args+=(--coherence-ceiling "$COHERENCE_CEILING")
  [ -n "$SESSION_BUDGET_MIN" ] && cap_args+=(--session-budget-min "$SESSION_BUDGET_MIN")
  [ -n "$EVENTS" ] && cap_args+=(--events "$EVENTS")
  cap_json="$(bash "$CAPACITY" "${cap_args[@]}" 2>/dev/null || true)"
  rm -f "$cap_stories"
  if [ -n "$cap_json" ] && printf '%s' "$cap_json" | jq -e '.flagged == true' >/dev/null 2>&1; then
    capacity_flagged=1
    capacity_detail="$(printf '%s' "$cap_json" | jq -rc '{depth:.critical_path_depth, coherence:.coherence_count, wall_clock:.wall_clock_minutes}' 2>/dev/null || echo flagged)"
  fi
fi

# ---------- Verdict ----------
refused=0
if [ -n "$unmaterialized" ] || [ -n "$not_ready" ] || [ -n "$missing_atdd" ] || [ "$capacity_flagged" -eq 1 ]; then
  refused=1
fi

if [ "$refused" -eq 1 ]; then
  printf 'planned→active REFUSED — sprint is not ready to activate:\n'
  [ -n "$unmaterialized" ] && printf '  unmaterialized (no story file): %s\n' "$unmaterialized"
  [ -n "$not_ready" ]      && printf '  not ready-for-dev: %s\n' "$not_ready"
  [ -n "$missing_atdd" ]   && printf '  missing ATDD (high-risk): %s — run /gaia-atdd for each\n' "$missing_atdd"
  [ "$capacity_flagged" -eq 1 ] && printf '  agent-native capacity overflow: %s — drop/swap via /gaia-correct-course\n' "$capacity_detail"
  printf 'fix the prerequisites (/gaia-create-story --for-sprint, /gaia-atdd), then re-run the gate before transition --to active.\n'
  exit 2
fi

printf 'planned→active gate PASSED — every story materialized + ready-for-dev, ATDD present for high-risk, capacity within agent-native budget. Sprint is activatable.\n'
exit 0
