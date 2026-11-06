#!/usr/bin/env bash
# phase3a-test-review.sh — Phase 3A toolkit driver for /gaia-review-test.
#
# Purpose
# -------
# Sequence the four deterministic Phase 3A scanners for the test-review skill —
# `smell-detector`, `flakiness-analyzer`,
# `fixture-analyzer`, `tag-conformance-detector` — and merge their per-script
# `checks[]` fragments into a single canonical `analysis-results.json`
# document validating against `plugins/gaia/schemas/analysis-results.schema.json`
# (`schema_version: "1.0"`).
#
# Output (stdout): a complete `analysis-results.json` document. Exit 0 on
# successful run (regardless of whether findings exist). Exit 1 on caller
# error (missing --story-key, missing --stack, missing input target).
#
# Invocation
# ----------
#   phase3a-test-review.sh --story-key <key> --stack <stack> <path>...
#   phase3a-test-review.sh --story-key <key> --stack <stack> --file-list <listfile>
#   phase3a-test-review.sh --help
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="phase3a-test-review.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A toolkit driver for /gaia-review-test.

Usage:
  $SCRIPT_NAME --story-key <key> --stack <stack> <path>...
  $SCRIPT_NAME --story-key <key> --stack <stack> --file-list <listfile>
  $SCRIPT_NAME --help

Runs smell-detector, flakiness-analyzer, fixture-analyzer, and per-stack
tag-conformance-detector in sequence and emits a canonical
analysis-results.json (schema_version 1.0) on stdout.
EOF
}

# ---------- arg parsing ----------

STORY_KEY=""
STACK=""
PATHS=()
FILE_LIST=""
MODEL="${MODEL:-claude-opus-4-7}"
SKILL_NAME="gaia-review-test"
MAX_LINES="${MAX_LINES:-500}"

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --story-key)
      [ $# -ge 2 ] || die "--story-key requires a value"
      STORY_KEY="$2"; shift 2 ;;
    --stack)
      [ $# -ge 2 ] || die "--stack requires a value"
      STACK="$2"; shift 2 ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --max-lines)
      [ $# -ge 2 ] || die "--max-lines requires a number"
      MAX_LINES="$2"; shift 2 ;;
    --model)
      [ $# -ge 2 ] || die "--model requires a value"
      MODEL="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

[ -n "$STORY_KEY" ] || die "--story-key is required"
[ -n "$STACK" ] || die "--stack is required"
case "$STORY_KEY" in
  E[0-9]*-S[0-9]*) ;;
  *) die "--story-key must match E<N>-S<N> (got: $STORY_KEY)" ;;
esac

if [ -z "$FILE_LIST" ] && [ "${#PATHS[@]}" -eq 0 ]; then
  die "no input target — pass <path>... or --file-list"
fi

# ---------- run sub-scanners ----------

SMELL="$SCRIPT_DIR/smell-detector.sh"
FLAKE="$SCRIPT_DIR/flakiness-analyzer.sh"
FIXTURE="$SCRIPT_DIR/fixture-analyzer.sh"
TAG="$SCRIPT_DIR/tag-conformance-detector.sh"

for s in "$SMELL" "$FLAKE" "$FIXTURE" "$TAG"; do
  [ -x "$s" ] || die "sub-scanner not executable: $s"
done

run_with_args() {
  # Prefix args common to all sub-scanners.
  local script="$1"; shift
  if [ -n "$FILE_LIST" ]; then
    if [ "$#" -gt 0 ]; then
      "$script" "$@" --file-list "$FILE_LIST"
    else
      "$script" --file-list "$FILE_LIST"
    fi
  else
    if [ "$#" -gt 0 ]; then
      "$script" "$@" "${PATHS[@]}"
    else
      "$script" "${PATHS[@]}"
    fi
  fi
}

SMELL_OUT="$(run_with_args "$SMELL")"
FLAKE_OUT="$(run_with_args "$FLAKE")"
FIXTURE_OUT="$(run_with_args "$FIXTURE" --max-lines "$MAX_LINES")"
# Pass --strict through to tag-conformance-detector when project-config opts
# in to strict tagging. The detector itself reads the same key directly, but
# driving it from the orchestrator keeps the contract explicit and CI logs auditable.
case "${GAIA_TEST_TAGGING_STRICT:-}" in
  1|true|TRUE|True|yes|YES|on|ON)
    TAG_OUT="$(run_with_args "$TAG" --stack "$STACK" --strict)" ;;
  *)
    TAG_OUT="$(run_with_args "$TAG" --stack "$STACK")" ;;
esac

# ---------- Mutation evidence check (--zero-kill for test-review) ----------
# Reads the score only; this skill never generates or runs mutants. With the
# thresholds key absent nothing is added, so existing projects see no change.
MUT_CHECK="$SCRIPT_DIR/mutation-evidence-check.sh"
MUT_OUT=""
_tr_err_check() {
  jq -n --arg m "$1" '{"name":"mutation-score","status":"errored","error_reason":$m,"message":$m,"findings":[]}'
}
if [ -x "$MUT_CHECK" ]; then
  # shellcheck source=../lib/mutation-config.sh
  . "$SCRIPT_DIR/../lib/mutation-config.sh"
  _tr_config="$(mutation_config_path)"
  if ! _tr_mut_thresholds="$(mutation_read_thresholds "$_tr_config" 2>&1)"; then
    printf '%s: %s\n' "$SCRIPT_NAME" "$_tr_mut_thresholds" >&2
    MUT_OUT="$(_tr_err_check "$_tr_mut_thresholds")"
  elif [ -n "$_tr_mut_thresholds" ]; then
    _tr_code_tree="${PROJECT_PATH:-$(pwd)}"
    _tr_mut_commit="$(git -C "$_tr_code_tree" rev-parse HEAD 2>/dev/null || echo unknown)"
    _tr_story_file="$("$SCRIPT_DIR/../resolve-story-file.sh" "$STORY_KEY" 2>/dev/null || true)"
    _tr_mut_priority=""
    if [ -n "$_tr_story_file" ] && [ -f "$_tr_story_file" ]; then
      _tr_mut_priority="$(mutation_story_priority "$_tr_story_file")"
    fi
    MUT_OUT="$("$MUT_CHECK" \
      --story-key "$STORY_KEY" \
      --evidence "$(mutation_evidence_path "$STORY_KEY")" \
      --commit "$_tr_mut_commit" \
      --priority "$_tr_mut_priority" \
      --thresholds "$_tr_mut_thresholds" \
      --zero-kill)" || MUT_OUT="$(_tr_err_check "mutation-evidence-check.sh failed")"
  fi
fi

# ---------- emit merged analysis-results.json ----------

# Each sub-scanner emits a complete JSON object that already constitutes a
# checks[] element. We just stitch them into a canonical schema document.

printf '{'
printf '"schema_version":"1.0",'
printf '"story_key":"%s",' "$STORY_KEY"
printf '"skill":"%s",' "$SKILL_NAME"
printf '"model":"%s",' "$MODEL"
printf '"model_temperature":0,'
printf '"checks":['
if [ -n "$MUT_OUT" ]; then
  printf '%s,%s,%s,%s,%s' "$SMELL_OUT" "$FLAKE_OUT" "$FIXTURE_OUT" "$TAG_OUT" "$MUT_OUT"
else
  printf '%s,%s,%s,%s' "$SMELL_OUT" "$FLAKE_OUT" "$FIXTURE_OUT" "$TAG_OUT"
fi
printf ']'
printf '}\n'

exit 0
