#!/usr/bin/env bash
# rubric-merger.sh — Deterministic RFC 7396 JSON-merge-patch merger for rubrics
#
# Usage:
#   rubric-merger.sh <layer1.json> [<layer2.json> ... <layerN.json>]
#
# Behavior:
#   1. Reads N JSON files in left-to-right order.
#   2. Folds them via RFC 7396 JSON-merge-patch:
#        - null in a later layer DELETES the corresponding key.
#        - object in both layers — recursive merge.
#        - any other value in a later layer REPLACES the earlier value
#          (arrays replace, not concatenate; scalars replace).
#   3. Emits the merged JSON to stdout with deterministic key ordering
#      (jq --sort-keys) — byte-identical output for identical inputs.
#
# Exit codes:
#   0  success — merged JSON on stdout.
#   1  generic error.
#   2  missing input file.
#   3  invalid JSON in an input file.
#   4  jq missing or merge engine failure.
#
# Requires: jq (>= 1.6).
# =============================================================================

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="rubric-merger.sh"

err() { printf '%s: %s\n' "$prog" "$*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not found in PATH"
  exit 4
fi

if [ "$#" -lt 1 ]; then
  err "usage: $prog <layer1.json> [<layer2.json> ...]"
  exit 1
fi

# Validate inputs up front: every file must exist and be valid JSON.
for f in "$@"; do
  if [ ! -f "$f" ]; then
    err "input file not found: $f"
    exit 2
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    err "input file is not valid JSON: $f"
    exit 3
  fi
done

# RFC 7396 JSON-merge-patch implemented in jq.
#
# Reference: RFC 7396 §2:
#   - If the patch is not an object, the result is the patch itself.
#   - Otherwise, walk the patch keys:
#       * if patch[k] is null, delete target[k].
#       * else recursively merge_patch(target[k] // null, patch[k]) into target[k].
#
# This implementation emulates that algorithm using a `reduce` over the patch
# key set so it is well-defined under jq's lexical scoping (jq does not allow
# free recursion but supports recursive `def` with explicit arguments).
JQ_FILTER='
def merge_patch(patch):
  if (patch | type) != "object" then
    patch
  else
    . as $target
    | (if ($target | type) == "object" then $target else {} end) as $base
    | reduce (patch | to_entries[]) as $kv
        ($base;
         if ($kv.value == null) then
           del(.[$kv.key])
         elif ($kv.value | type) == "object" then
           .[$kv.key] = ((.[$kv.key] // {}) | merge_patch($kv.value))
         else
           .[$kv.key] = $kv.value
         end)
  end;

# Seed with the first input, fold the rest via merge_patch.
input as $seed | reduce inputs as $layer ($seed; merge_patch($layer))
'

# Fold N files: first file is the slurp seed (-n + first input via reduce),
# remaining files via `inputs`. Use `--slurp`-style streaming with `-n` +
# `input` to avoid loading all N files into one giant array.
#
# Implementation note: pass the first file as the seed, then `reduce inputs`
# folds the rest. We use `cat <files…> | jq -n 'reduce inputs as ...'` so that
# `inputs` yields the N parsed JSON values in order.
out=$(jq -n --sort-keys "$JQ_FILTER" "$@" 2>&1) || {
  err "merge engine failed"
  err "$out"
  exit 4
}

printf '%s\n' "$out"
