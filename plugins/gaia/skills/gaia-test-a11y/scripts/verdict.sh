#!/usr/bin/env bash
# verdict.sh — gaia-test-a11y Phase 4 verdict + Review Gate update.
#
# Reads the Phase 3A analysis-results.json and the Phase 3B llm-findings.json,
# invokes verdict-resolver.sh to compute the verdict (APPROVE | REQUEST_CHANGES
# | BLOCKED), and (when --story-key is provided AND --gate is provided) updates
# the corresponding Review Gate row via review-gate.sh.
#
# Verdict to gate-row mapping:
#   APPROVE          -> PASSED
#   REQUEST_CHANGES  -> FAILED
#   BLOCKED          -> FAILED
#
# Default --gate is "Accessibility Review" (this skill targets the a11y row of
# the canonical Review Gate seeded by init-review-gate.sh).
#
# Contract:
#   verdict.sh --analysis-results <path> --llm-findings <path>
#               [--story-key <key>] [--gate <name>]
#
# Stdout: emits the verdict on the last line. Exit 0 on success, 1 on caller error.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-a11y/verdict.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Prefer the review-common location and fall back to the top-level
# scripts/verdict-resolver.sh for backward compatibility — same probe
# pattern as gaia-test-perf/verdict.sh.
if [ -x "$PLUGIN_ROOT/scripts/review-common/verdict-resolver.sh" ]; then
  RESOLVER="$PLUGIN_ROOT/scripts/review-common/verdict-resolver.sh"
else
  RESOLVER="$PLUGIN_ROOT/scripts/verdict-resolver.sh"
fi
GATE="$PLUGIN_ROOT/scripts/review-gate.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

ANALYSIS=""
LLM=""
STORY_KEY=""
GATE_NAME="Accessibility Review"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --analysis-results) ANALYSIS="$2"; shift 2 ;;
    --llm-findings)     LLM="$2"; shift 2 ;;
    --story-key)        STORY_KEY="$2"; shift 2 ;;
    --gate)             GATE_NAME="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — verdict resolution + Review Gate update for /gaia-test-a11y.
Usage:
  verdict.sh --analysis-results <path> --llm-findings <path>
              [--story-key <key>] [--gate <name>]
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$ANALYSIS" ] || die "--analysis-results required"
[ -n "$LLM" ]      || die "--llm-findings required"
[ -r "$ANALYSIS" ] || die "analysis-results not readable: $ANALYSIS"
[ -r "$LLM" ]      || die "llm-findings not readable: $LLM"
[ -x "$RESOLVER" ] || die "verdict-resolver.sh not found at $RESOLVER"

verdict="$("$RESOLVER" --skill gaia-test-a11y --analysis-results "$ANALYSIS" --llm-findings "$LLM")" \
  || die "verdict-resolver.sh failed"

if [ -n "$STORY_KEY" ] && [ -n "$GATE_NAME" ] && [ -x "$GATE" ]; then
  case "$verdict" in
    APPROVE)         gate_status="PASSED" ;;
    REQUEST_CHANGES) gate_status="FAILED" ;;
    BLOCKED)         gate_status="FAILED" ;;
    *)               gate_status="UNVERIFIED" ;;
  esac
  if "$GATE" update --story "$STORY_KEY" --gate "$GATE_NAME" --verdict "$gate_status" 2>>"$ANALYSIS.gate.log"; then
    log "review-gate updated: story=$STORY_KEY gate=$GATE_NAME verdict=$gate_status"
  else
    log "WARN: review-gate update failed (see $ANALYSIS.gate.log)"
  fi
fi

printf '%s\n' "$verdict"
exit 0
