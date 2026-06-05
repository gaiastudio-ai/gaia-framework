#!/usr/bin/env bash
# emit-plan-file.sh — Phase 1 plan-file emission helper
#
# Produces a schema v1 plan file.
# Writes atomically via temp-file + mv to defend against partial writes
# and concurrent reader races.
#
# Usage:
#   emit-plan-file.sh \
#     --story-key KEY \
#     --output PATH \
#     --sources JSON_ARRAY \
#     --tests JSON_ARRAY \
#     --narrative TEXT
#
# Each invocation generates a fresh plan_id.
# The script is called by Phase 1 (fork-context) after analysis completes.
#
# Exit codes:
#   0 — plan file written successfully
#   1 — argument parsing error or write failure

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="emit-plan-file.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

STORY_KEY=""
OUTPUT_PATH=""
SOURCES_JSON="[]"
TESTS_JSON="[]"
NARRATIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story-key)  STORY_KEY="$2";  shift 2 ;;
    --output)     OUTPUT_PATH="$2"; shift 2 ;;
    --sources)    SOURCES_JSON="$2"; shift 2 ;;
    --tests)      TESTS_JSON="$2";  shift 2 ;;
    --narrative)  NARRATIVE="$2";   shift 2 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$STORY_KEY" ]  || die "missing required --story-key"
[ -n "$OUTPUT_PATH" ] || die "missing required --output"

# ---------------------------------------------------------------------------
# Generate fresh plan_id
#   Prefer uuidgen (macOS/Linux). Fallback to timestamp + RANDOM nonce.
#   Every invocation MUST produce a unique value.
# ---------------------------------------------------------------------------

generate_plan_id() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # Fallback: epoch nanoseconds + RANDOM nonce
    local ts
    ts="$(date +%s%N 2>/dev/null || date +%s)"
    printf '%s-%04x%04x' "$ts" "$RANDOM" "$RANDOM"
  fi
}

PLAN_ID="$(generate_plan_id)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)"

# ---------------------------------------------------------------------------
# Verify output directory exists
# ---------------------------------------------------------------------------

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
if [ ! -d "$OUTPUT_DIR" ]; then
  die "output directory does not exist: $OUTPUT_DIR"
fi

# ---------------------------------------------------------------------------
# Atomic write: temp file + mv
# ---------------------------------------------------------------------------

TEMP_FILE=""
cleanup() {
  [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT

TEMP_FILE="$(mktemp "${OUTPUT_DIR}/.emit-plan-XXXXXX")" || die "failed to create temp file in $OUTPUT_DIR"

cat > "$TEMP_FILE" <<PLAN_EOF
---
schema_version: 1
story_key: "${STORY_KEY}"
plan_id: "${PLAN_ID}"
generated_at: "${GENERATED_AT}"
generator: "gaia-test-automate"
phase: "plan"
approval:
  gate: "test-automate-plan"
  verdict: null
  verdict_plan_id: null
analyzed_sources: ${SOURCES_JSON}
proposed_tests: ${TESTS_JSON}
---

${NARRATIVE}
PLAN_EOF

# Atomic rename — concurrent readers see either old or new file, never partial.
mv -f "$TEMP_FILE" "$OUTPUT_PATH" || die "failed to atomically rename temp file to $OUTPUT_PATH"
TEMP_FILE=""  # Clear so cleanup trap does not try to remove the renamed file

log "plan file written: $OUTPUT_PATH (plan_id: $PLAN_ID)"
exit 0
