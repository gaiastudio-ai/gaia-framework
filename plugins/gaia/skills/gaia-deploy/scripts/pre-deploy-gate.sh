#!/usr/bin/env bash
# pre-deploy-gate.sh — /gaia-deploy Pattern A pre-deploy gate (E73-S5, AC2).
#
# Reads the composite verdict (ADR-082 aggregator output) from
# `${GAIA_DEPLOY_COMPOSITE_FILE}` if set, otherwise invokes
# `composite-verdict-aggregator.sh --story-key <key>` and treats the JSON
# stdout as the composite verdict. Proceeds (exit 0) only when
# `composite == "APPROVE"`. Otherwise emits a `BLOCKED` diagnostic naming the
# failing reviews and exits non-zero.
#
# Refs: ADR-080, ADR-082, FR-RSV2-31.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/pre-deploy-gate.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

STORY_KEY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --story-key) STORY_KEY="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — pre-deploy composite-verdict gate (E73-S5, AC2).
Usage: $SCRIPT_NAME --story-key <key>
Honours GAIA_DEPLOY_COMPOSITE_FILE for fixture-driven testing.
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$STORY_KEY" ]; then
  log "--story-key is required"
  exit 2
fi

# Path-traversal mitigation on STORY_KEY (used in diagnostic only, but still validate).
case "$STORY_KEY" in
  */*|*..*|*$'\n'*|*' '*)
    log "invalid --story-key value"
    exit 2 ;;
esac

composite_json=""
if [ -n "${GAIA_DEPLOY_COMPOSITE_FILE:-}" ]; then
  if [ ! -f "$GAIA_DEPLOY_COMPOSITE_FILE" ]; then
    log "BLOCKED: composite-verdict file not found: $GAIA_DEPLOY_COMPOSITE_FILE"
    exit 1
  fi
  composite_json="$(cat "$GAIA_DEPLOY_COMPOSITE_FILE")"
else
  # Resolve aggregator path. The skill is at plugins/gaia/skills/gaia-deploy/
  # and the aggregator is at plugins/gaia/scripts/review-common/.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PLUGIN_SCRIPTS="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
  AGGREGATOR="$PLUGIN_SCRIPTS/review-common/composite-verdict-aggregator.sh"
  if [ ! -x "$AGGREGATOR" ]; then
    log "BLOCKED: composite-verdict-aggregator.sh not found at $AGGREGATOR (E66-S3 not deployed)"
    exit 1
  fi
  if ! composite_json="$("$AGGREGATOR" --story-key "$STORY_KEY" 2>&1)"; then
    log "BLOCKED: composite-verdict-aggregator.sh failed: $composite_json"
    exit 1
  fi
fi

# Parse composite verdict.
verdict="$(printf '%s' "$composite_json" | jq -r '.composite // empty' 2>/dev/null || true)"
if [ -z "$verdict" ]; then
  log "BLOCKED: could not parse composite verdict from aggregator output"
  exit 1
fi

if [ "$verdict" = "APPROVE" ]; then
  printf 'APPROVE\n'
  exit 0
fi

# Non-APPROVE: enumerate failing reviews.
failing="$(printf '%s' "$composite_json" | jq -r '.reviews[]? | select(.status != "PASSED" and .status != "APPROVE") | .name' 2>/dev/null || true)"
log "BLOCKED: composite verdict is $verdict (expected APPROVE)"
if [ -n "$failing" ]; then
  while IFS= read -r row; do
    [ -n "$row" ] && log "  failing review: $row"
  done <<<"$failing"
fi
exit 1
