#!/usr/bin/env bash
# phase3a-collect.sh — Phase 3A collector for the gaia-qa-tests skill.
#
# Invokes the AC-coverage analyzer, wraps its output in the
# analysis-results.json envelope, and writes the result to --output-dir.
# Errored conditions (unreadable story, analyzer failure, malformed output)
# produce an errored ac-coverage check so the resolver returns BLOCKED.
#
# Exit codes:
#   0 — success (analysis-results.json written, even if errored)
#   1 — caller error (missing/invalid required argument)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'phase3a-collect.sh: %s\n' "$*" >&2
  exit 1
}

# --- Argument parsing ---
STORY_KEY=""
STORY_FILE=""
OUTPUT_DIR=""
TEST_DIR="."
STACK="ts-dev"
MODEL="claude-opus-4-7"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --story-key)
      [ "$#" -ge 2 ] || die "--story-key requires a value"
      STORY_KEY="$2"; shift 2 ;;
    --story-file)
      [ "$#" -ge 2 ] || die "--story-file requires a value"
      STORY_FILE="$2"; shift 2 ;;
    --output-dir)
      [ "$#" -ge 2 ] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"; shift 2 ;;
    --test-dir)
      [ "$#" -ge 2 ] || die "--test-dir requires a value"
      TEST_DIR="$2"; shift 2 ;;
    --stack)
      [ "$#" -ge 2 ] || die "--stack requires a value"
      STACK="$2"; shift 2 ;;
    --model)
      [ "$#" -ge 2 ] || die "--model requires a value"
      MODEL="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

# --- Required-argument validation (exit 1) ---

[ -n "$STORY_KEY" ] || die "missing required --story-key"

if ! printf '%s' "$STORY_KEY" | grep -qE '^E[0-9]+-S[0-9]+$'; then
  die "malformed story key: $STORY_KEY (expected E<N>-S<N>)"
fi

[ -n "$STORY_FILE" ] || die "missing required --story-file"

[ -n "$OUTPUT_DIR" ] || die "missing required --output-dir"

[ -w "$OUTPUT_DIR" ] || die "--output-dir not writable: $OUTPUT_DIR"

if [ "$TEST_DIR" != "." ] && [ ! -d "$TEST_DIR" ]; then
  die "--test-dir not a directory: $TEST_DIR"
fi

# --- Helper: write an errored envelope and exit 0 ---
# Always exits 0 so the caller can feed analysis-results.json to the resolver,
# which maps an errored check to BLOCKED. Exit 1 is reserved for caller errors
# (missing args) that should never occur once Phase 1 has validated inputs.

write_errored() {
  local reason="$1"
  jq -n \
    --arg sv "1.0" \
    --arg sk "$STORY_KEY" \
    --arg skill "gaia-qa-tests" \
    --arg model "$MODEL" \
    --arg reason "$reason" \
    '{
      schema_version: $sv,
      story_key: $sk,
      skill: $skill,
      model: $model,
      model_temperature: 0,
      checks: [
        {
          name: "ac-coverage",
          status: "errored",
          error_reason: $reason,
          findings: []
        }
      ]
    }' > "$OUTPUT_DIR/analysis-results.json"
  exit 0
}

# --- Story file readability check ---

if [ ! -r "$STORY_FILE" ]; then
  write_errored "story file not readable: $STORY_FILE"
fi

# --- Run the analyzer ---

ANALYZER="$SCRIPT_DIR/ac-coverage-analyzer.sh"

if [ ! -x "$ANALYZER" ]; then
  write_errored "analyzer not executable: $ANALYZER"
fi

# Discard stderr so analyzer diagnostics (stack-defaulting warnings, timeout
# notices) do not leak into the collector's own stderr or corrupt stdout JSON.
analyzer_output=""
analyzer_rc=0
analyzer_output="$("$ANALYZER" \
  --story-file "$STORY_FILE" \
  --story-key "$STORY_KEY" \
  --test-dir "$TEST_DIR" \
  --stack "$STACK" 2>/dev/null)" || analyzer_rc=$?

if [ "$analyzer_rc" -ne 0 ]; then
  write_errored "analyzer exited with code $analyzer_rc"
fi

# Validate the analyzer output is well-formed JSON.
if ! printf '%s' "$analyzer_output" | jq -e . >/dev/null 2>&1; then
  write_errored "analyzer produced malformed JSON"
fi

# --- Build the envelope ---

jq -n \
  --arg sv "1.0" \
  --arg sk "$STORY_KEY" \
  --arg skill "gaia-qa-tests" \
  --arg model "$MODEL" \
  --argjson check "$analyzer_output" \
  '{
    schema_version: $sv,
    story_key: $sk,
    skill: $skill,
    model: $model,
    model_temperature: 0,
    checks: [$check]
  }' > "$OUTPUT_DIR/analysis-results.json"

exit 0
