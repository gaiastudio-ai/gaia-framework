#!/usr/bin/env bash
# build-manifest-cards.sh — deterministic manifest card builder and
# last-published persistence helper for screen-specification publication.
#
# Two public functions:
#   build_manifest_cards   — merge spec-file cards into the design-system manifest
#   persist_last_published — write the persisted publication manifest from outcomes
#
# Bash 3.2 safe: no associative arrays, no mapfile, no readarray.
# All jq values go through --arg / --argjson.

set -euo pipefail
LC_ALL=C; export LC_ALL

_bmc_die() { printf 'build-manifest-cards.sh: %s\n' "$1" >&2; return 1; }

# ---------------------------------------------------------------------------
# build_manifest_cards
# ---------------------------------------------------------------------------
# Scans *.spec.html files for @dsCard annotations, merges them with the
# existing manifest, preserves non-framework cards, and drops orphan
# framework cards. Outputs the merged manifest JSON to stdout.
#
# Arguments:
#   --local-specs <dir>       Root to scan for screens/*.spec.html and
#                             components/*.spec.html
#   --existing <file>         Current remote _ds_manifest.json
#   --last-published <file>   Prior design-last-published.json (default /dev/null)

build_manifest_cards() {
  local local_specs="" existing="" last_published="/dev/null"

  while [ $# -gt 0 ]; do
    case "$1" in
      --local-specs)    local_specs="$2";    shift 2 ;;
      --existing)       existing="$2";       shift 2 ;;
      --last-published) last_published="$2"; shift 2 ;;
      *) _bmc_die "build_manifest_cards: unknown option: $1" ;;
    esac
  done

  [ -n "$local_specs" ] || _bmc_die "build_manifest_cards: --local-specs required"
  [ -n "$existing" ]    || _bmc_die "build_manifest_cards: --existing required"

  # 1. Scan spec files for @dsCard annotations
  local spec_cards_json="[]"
  local spec_paths_json="[]"
  local subdir file first_line group rel_path
  for subdir in screens components; do
    local scan_dir="${local_specs}/${subdir}"
    [ -d "$scan_dir" ] || continue
    for file in "$scan_dir"/*.spec.html; do
      [ -f "$file" ] || continue
      rel_path="${subdir}/$(basename "$file")"
      first_line="$(head -1 "$file")"
      # Extract group from <!-- @dsCard group="..." -->
      if printf '%s' "$first_line" | grep -qE '^<!-- @dsCard group="[^"]*" -->'; then
        group="$(printf '%s' "$first_line" | sed -n 's/.*@dsCard group="\([^"]*\)".*/\1/p')"
        spec_cards_json="$(printf '%s' "$spec_cards_json" | jq --arg p "$rel_path" --arg g "$group" '. + [{"path": $p, "group": $g}]')"
        spec_paths_json="$(printf '%s' "$spec_paths_json" | jq --arg p "$rel_path" '. + [$p]')"
      else
        printf 'build-manifest-cards.sh: skipping %s — missing or malformed @dsCard annotation\n' "$rel_path" >&2
      fi
    done
  done

  # 2. Build framework-owned set: union of current local specs + prior published paths
  local fw_owned_json="$spec_paths_json"
  if [ "$last_published" != "/dev/null" ] && [ -f "$last_published" ] && [ -s "$last_published" ]; then
    local prior_paths
    prior_paths="$(jq -r '.[].file' "$last_published" 2>/dev/null || true)"
    if [ -n "$prior_paths" ]; then
      while IFS= read -r rel_path; do
        [ -n "$rel_path" ] || continue
        fw_owned_json="$(printf '%s' "$fw_owned_json" | jq --arg p "$rel_path" 'if (. | index($p)) then . else . + [$p] end')"
      done <<< "$prior_paths"
    fi
  fi

  # 3. Parse existing manifest (fail-replace on corruption)
  local existing_json='{"cards":[]}'
  if [ -f "$existing" ] && [ -s "$existing" ]; then
    existing_json="$(jq '.' "$existing" 2>/dev/null)" || {
      printf 'build-manifest-cards.sh: corrupted existing manifest, replacing\n' >&2
      existing_json='{"cards":[]}'
    }
  fi

  # 4. Merge: keep non-framework cards, drop orphan framework cards, add/update specs
  printf '%s' "$existing_json" | jq \
    --argjson spec_cards "$spec_cards_json" \
    --argjson fw_owned "$fw_owned_json" \
    --argjson spec_paths "$spec_paths_json" \
    '
    # Separate existing cards into framework-owned and non-framework
    (.cards // []) as $existing_cards |
    [$existing_cards[] | select(([.path] | inside($fw_owned) | not))] as $non_fw |
    # From spec cards, only include those in the current local set
    [$spec_cards[] | select([.path] | inside($spec_paths))] as $current_specs |
    # Merge: non-framework + current specs
    .cards = ($non_fw + $current_specs)
    '
}

# ---------------------------------------------------------------------------
# persist_last_published
# ---------------------------------------------------------------------------
# Writes .gaia/state/design-last-published.json from executed outcomes.
#
# Persistence rules (binding):
#   written       -> hash from outcomes (= project content)
#   skipped       -> hash from outcomes (= input hash)
#   kept-designer -> framework LOCAL hash from --local-hash-map
#   merged        -> framework LOCAL hash from --local-hash-map
#   failed+prior  -> prior hash
#   failed-no-pri -> omitted
#   deleted       -> removed
#   delete-failed -> prior hash
#
# Arguments:
#   --outcomes <file>       JSON array [{file, outcome, hash}]
#   --prior <file>          Prior design-last-published.json (or /dev/null)
#   --output <file>         Path to write the new manifest
#   --local-hash-map <file> JSON object {file: local_hash}

persist_last_published() {
  local outcomes="" prior="/dev/null" output_file="" local_hash_map=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --outcomes)       outcomes="$2";       shift 2 ;;
      --prior)          prior="$2";          shift 2 ;;
      --output)         output_file="$2";    shift 2 ;;
      --local-hash-map) local_hash_map="$2"; shift 2 ;;
      *) _bmc_die "persist_last_published: unknown option: $1" ;;
    esac
  done

  [ -n "$outcomes" ]       || _bmc_die "persist_last_published: --outcomes required"
  [ -n "$output_file" ]    || _bmc_die "persist_last_published: --output required"
  [ -n "$local_hash_map" ] || _bmc_die "persist_last_published: --local-hash-map required"

  # Read prior manifest
  local prior_json="[]"
  if [ "$prior" != "/dev/null" ] && [ -f "$prior" ] && [ -s "$prior" ]; then
    prior_json="$(jq '.' "$prior" 2>/dev/null || printf '[]')"
  fi

  # Read local hash map
  local hash_map_json='{}'
  if [ -f "$local_hash_map" ] && [ -s "$local_hash_map" ]; then
    hash_map_json="$(jq '.' "$local_hash_map" 2>/dev/null || printf '{}')"
  fi

  # Compute the persisted manifest via jq
  local result
  result="$(jq \
    --argjson prior "$prior_json" \
    --argjson hash_map "$hash_map_json" \
    '
    # Build prior lookup {file: hash}
    ($prior | map({(.file): .hash}) | add // {}) as $prior_map |

    # Apply persistence rules per outcome
    [.[] |
      if .outcome == "written" or .outcome == "skipped" then
        {file: .file, hash: .hash}
      elif .outcome == "kept-designer" or .outcome == "merged" then
        {file: .file, hash: ($hash_map[.file] // .hash)}
      elif .outcome == "failed" or .outcome == "delete-failed" then
        if $prior_map[.file] then
          {file: .file, hash: $prior_map[.file]}
        else
          empty
        end
      elif .outcome == "deleted" then
        empty
      else
        empty
      end
    ]
    ' "$outcomes")"

  # Atomic write: tmp + mv
  local out_dir
  out_dir="$(dirname "$output_file")"
  mkdir -p "$out_dir"
  printf '%s\n' "$result" > "${output_file}.tmp"
  mv "${output_file}.tmp" "$output_file"
}
