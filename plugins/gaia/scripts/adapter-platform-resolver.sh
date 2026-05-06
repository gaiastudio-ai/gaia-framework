#!/usr/bin/env bash
# adapter-platform-resolver.sh — E74-S7 platform-gated adapter selection (AC5).
#
# Filters the adapters under plugins/gaia/scripts/adapters/<tool>/ by their
# `platforms` array (declared in adapter.json) versus the `--platforms` flag
# (or the project-config.yaml `platforms:` list). Adapters declaring a
# `platforms` field that intersects the input platform set are selected;
# adapters without a `platforms` field (e.g. existing E66-S2 adapters such as
# semgrep, gitleaks) are platform-agnostic and therefore always selected.
#
# Usage:
#   adapter-platform-resolver.sh --platforms ios,android [--adapters-dir <path>]
#
# Output: one adapter directory name per line on stdout, sorted, deterministic.
# Exit codes:
#   0 — success (zero or more adapters listed)
#   1 — bad arguments
#
# Decisions:
#   - ADR-077 (three-tier review pipeline): platform gating runs in the
#     evidence layer before run.sh dispatch.
#   - ADR-078 (tool adapter framework): adapter.json owns metadata; the
#     resolver is the only consumer of `platforms`.
#   - ADR-081 (mobile-as-platform).
#
# Determinism (NFR-RSV2-3): identical inputs produce byte-identical output.
# LC_ALL=C and `sort` make the output stable across systems.

set -euo pipefail
LC_ALL=C
export LC_ALL

PLATFORMS=""
ADAPTERS_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --adapters-dir) ADAPTERS_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapter-platform-resolver.sh — platform-gated adapter selection.
Usage:
  $(basename "$0") --platforms ios,android [--adapters-dir <path>]

Lists adapter directory names whose adapter.json :: platforms[] intersects the
input platform set. Adapters without a 'platforms' field are emitted unchanged
(treated as platform-agnostic).
EOF
      exit 0 ;;
    *) echo "$(basename "$0"): unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PLATFORMS" ]; then
  echo "$(basename "$0"): --platforms required (e.g. ios,android,web)" >&2
  exit 1
fi

if [ -z "$ADAPTERS_DIR" ]; then
  ADAPTERS_DIR="$(cd "$(dirname "$0")/adapters" && pwd)"
fi

if [ ! -d "$ADAPTERS_DIR" ]; then
  echo "$(basename "$0"): adapters dir not found: $ADAPTERS_DIR" >&2
  exit 1
fi

# Normalize the input platform list: split on commas, trim whitespace.
IFS=',' read -r -a INPUT_PLATFORMS <<< "$PLATFORMS"
declare -a NORMALIZED=()
for p in "${INPUT_PLATFORMS[@]}"; do
  trimmed="${p#"${p%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [ -n "$trimmed" ] && NORMALIZED+=("$trimmed")
done

# Build a JSON array for jq comparison.
input_json="$(printf '%s\n' "${NORMALIZED[@]}" | jq -R . | jq -s .)"

# Walk adapter directories and filter.
matches=()
for d in "$ADAPTERS_DIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  # Skip the schema directory.
  [ "$name" = "_schema" ] && continue
  meta="$d/adapter.json"
  [ -f "$meta" ] || continue

  # If the adapter declares platforms, require intersection. Otherwise, emit
  # (platform-agnostic adapter — e.g. existing E66-S2 adapters).
  decision="$(jq --argjson input "$input_json" '
    if has("platforms") and (.platforms | type == "array")
    then (.platforms | any(. as $p | $input | index($p) != null))
    else true
    end
  ' "$meta")"

  if [ "$decision" = "true" ]; then
    matches+=("$name")
  fi
done

# Emit deterministic, sorted output. AC5 only checks per-line membership, but
# determinism is a framework invariant.
if [ "${#matches[@]}" -gt 0 ]; then
  printf '%s\n' "${matches[@]}" | sort
fi

exit 0
