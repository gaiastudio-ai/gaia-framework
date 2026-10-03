#!/usr/bin/env bash
# build-manifest-cards.sh — deterministic manifest card builder and
# last-published persistence helper for screen-specification publication
# (create-ux) and republication on stale (edit-ux, add-feature).
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

# ---- source shared libs -----------------------------------------------------
_BMC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BMC_SAFE_FN="${_BMC_DIR}/lib/safe-filename.sh"
if [ ! -f "$_BMC_SAFE_FN" ]; then
  _bmc_die "missing lib: $_BMC_SAFE_FN"; return 1
fi
# shellcheck source=lib/safe-filename.sh
. "$_BMC_SAFE_FN"

_BMC_LOCK_LIB="${_BMC_DIR}/lib/acquire-lock.sh"
_BMC_HAS_LOCK=0
if [ -f "$_BMC_LOCK_LIB" ]; then
  # shellcheck source=lib/acquire-lock.sh
  . "$_BMC_LOCK_LIB"
  _BMC_HAS_LOCK=1
fi

# ---------------------------------------------------------------------------
# build_manifest_cards
# ---------------------------------------------------------------------------
# Scans *.spec.html and token *.html files for @dsCard annotations, merges
# them with the existing manifest, preserves non-framework cards, and drops
# orphan framework cards. Outputs the merged manifest JSON to stdout.
#
# Routing allow-list:
#   components/, templates/, tokens/ → design_system
#   screens/, flows/                 → product_design
#   Unknown or root-level or depth>1 → rejected with diagnostic
#
# Arguments:
#   --local-specs <dir>       Root to scan for spec files
#   --existing <file>         Current remote _ds_manifest.json
#   --last-published <file>   Prior design-last-published.json (default /dev/null)
#   --project <key>           Target project key (design_system | product_design;
#                             default: design_system)

build_manifest_cards() {
  local local_specs="" existing="" last_published="/dev/null" project="design_system"

  while [ $# -gt 0 ]; do
    case "$1" in
      --local-specs)    local_specs="$2";    shift 2 ;;
      --existing)       existing="$2";       shift 2 ;;
      --last-published) last_published="$2"; shift 2 ;;
      --project)        project="$2";        shift 2 ;;
      *) _bmc_die "build_manifest_cards: unknown option: $1"; return 1 ;;
    esac
  done

  [ -n "$local_specs" ] || { _bmc_die "build_manifest_cards: --local-specs required"; return 1; }
  [ -n "$existing" ]    || { _bmc_die "build_manifest_cards: --existing required"; return 1; }

  case "$project" in
    design_system|product_design) ;;
    *) _bmc_die "build_manifest_cards: invalid --project value: $project (must be design_system or product_design)"; return 1 ;;
  esac

  # 1. Discover spec files using find from inside the spec folder.
  # This avoids ERE metacharacter issues with path-glob matching.
  local discovered_paths=""
  if [ -d "$local_specs" ]; then
    # Read NUL-delimited paths safely (no tr '\0' '\n' — that turns
    # embedded newlines into separate records and defeats the control-
    # character check).
    local _disc_tmp
    _disc_tmp="$(mktemp "${TMPDIR:-/tmp}/bmc_disc.XXXXXX")"
    ( cd "$local_specs" && {
      # spec files at depth 1–3 (catches root-level and deeper for rejection)
      find . -mindepth 1 -maxdepth 3 -name '*.spec.html' -print0 2>/dev/null
      # token pages: ./tokens/*.html at depth 2 only
      find . -maxdepth 2 -path './tokens/*.html' -print0 2>/dev/null
    } | LC_ALL=C sort -z > "$_disc_tmp" ) || true

    # Strip leading ./, deduplicate, validate
    local seen_paths=""
    local line
    while IFS= read -r -d '' line; do
      [ -n "$line" ] || continue
      # Strip leading ./
      line="${line#./}"
      # Deduplicate (tokens/x.spec.html may match both patterns)
      case "$seen_paths" in
        *"|${line}|"*) continue ;;
      esac
      seen_paths="${seen_paths}|${line}|"
      # Shell-side safety check before awk
      if ! safe_filename_check "$line" 2>/dev/null; then
        printf 'build-manifest-cards.sh: rejecting discovered path: %q\n' "$line" >&2
        continue
      fi
      # Route: extract first segment
      local first_seg="${line%%/*}"
      local rest="${line#*/}"
      # Must be exactly <allowed>/<file> (one segment deep) — reject root-level
      # and deeper nesting
      if [ "$first_seg" = "$line" ]; then
        printf 'build-manifest-cards.sh: rejecting root-level spec: %s (allowed: components/ templates/ tokens/ screens/ flows/)\n' "$line" >&2
        continue
      fi
      if [ "$rest" != "${rest##*/}" ]; then
        printf 'build-manifest-cards.sh: rejecting nested spec: %s (only <subdir>/<file> allowed; subdirs: components/ templates/ tokens/ screens/ flows/)\n' "$line" >&2
        continue
      fi
      case "$first_seg" in
        components|templates|tokens|screens|flows) ;;
        *)
          printf 'build-manifest-cards.sh: rejecting unknown subdirectory: %s (allowed: components/ templates/ tokens/ screens/ flows/)\n' "$line" >&2
          continue
          ;;
      esac
      discovered_paths="${discovered_paths}${line}"$'\n'
    done < "$_disc_tmp"
    rm -f "$_disc_tmp"
  fi

  # 2. Scan for @dsCard annotations using awk on discovered files
  local spec_files=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local full="${local_specs}/${p}"
    [ -f "$full" ] || continue
    spec_files=("${spec_files[@]+"${spec_files[@]}"}" "$full")
  done <<< "$discovered_paths"

  local scan_tsv="" diag_file=""
  if [ "${#spec_files[@]}" -gt 0 ]; then
    diag_file="$(mktemp "${TMPDIR:-/tmp}/bmc_diag.XXXXXX")"

    scan_tsv="$(awk -v spec_root="$local_specs/" -v diag="$diag_file" '
      FNR == 1 {
        path = FILENAME
        if (index(path, spec_root) == 1)
          path = substr(path, length(spec_root) + 1)
        if (index(path, "\t") > 0) {
          print "DIAG\t" path > diag
          next
        }
        if (match($0, /@dsCard group="/)) {
          rest = substr($0, RSTART + 15)
          qpos = index(rest, "\"")
          if (qpos > 1) {
            grp = substr(rest, 1, qpos - 1)
            print path "\t" grp
          } else {
            print "SKIP\t" path > diag
          }
        } else {
          print "SKIP\t" path > diag
        }
      }
    ' "${spec_files[@]}")" || true

    if [ -s "$diag_file" ]; then
      while IFS='	' read -r dtype dpath; do
        [ -n "$dtype" ] || continue
        if [ "$dtype" = "DIAG" ]; then
          printf 'build-manifest-cards.sh: rejecting %s — tab in filename\n' "$dpath" >&2
        elif [ "$dtype" = "SKIP" ]; then
          printf 'build-manifest-cards.sh: skipping %s — missing or malformed @dsCard annotation\n' "$dpath" >&2
        fi
      done < "$diag_file"
    fi
    rm -f "$diag_file"
  fi

  # 3. Build spec_cards and spec_paths, then partition by project
  local all_spec_cards_json all_spec_paths_json
  if [ -n "$scan_tsv" ]; then
    all_spec_cards_json="$(printf '%s' "$scan_tsv" | jq -R '
      split("\t") | select(length == 2) | {path: .[0], group: .[1]}
    ' | jq -s '.')"
    all_spec_paths_json="$(printf '%s' "$all_spec_cards_json" | jq '[.[].path]')"
  else
    all_spec_cards_json="[]"
    all_spec_paths_json="[]"
  fi

  # Partition cards by routing rules
  local spec_cards_json spec_paths_json
  if [ "$project" = "design_system" ]; then
    spec_cards_json="$(printf '%s' "$all_spec_cards_json" | jq '[.[] | select(.path | test("^(components|templates|tokens)/"))]')"
  else
    spec_cards_json="$(printf '%s' "$all_spec_cards_json" | jq '[.[] | select(.path | test("^(screens|flows)/"))]')"
  fi
  spec_paths_json="$(printf '%s' "$spec_cards_json" | jq '[.[].path]')"

  # 4. Build framework-owned set from ALL scanned paths (both partitions)
  # so a legacy screen card left in a design-system manifest is recognised
  # as framework-owned and dropped.
  local prior_paths_json="[]"
  if [ "$last_published" != "/dev/null" ] && [ -f "$last_published" ] && [ -s "$last_published" ]; then
    # Normalise: legacy flat array → per-project object → slice to target key
    prior_paths_json="$(jq --arg proj "$project" "
      $SAFE_FILENAME_JQ_DEF
      if type == \"array\" then
        {\"design_system\": {\"files\": .}, \"product_design\": {\"files\": []}}
      else . end
      | .[\$proj].files // []
      | map(.file | safe_filename)
    " "$last_published" 2>/dev/null)" || {
      _bmc_die "build_manifest_cards: corrupt or unsafe --last-published: $last_published"
      return 1
    }
  fi
  local fw_owned_json
  fw_owned_json="$(jq -n --argjson specs "$all_spec_paths_json" --argjson prior "$prior_paths_json" \
    '$specs + $prior | unique')"

  # 5. Parse existing manifest (fail-replace on corruption).
  # Filter carried-over cards by partition prefix.
  local existing_json='{"cards":[]}'
  if [ -f "$existing" ] && [ -s "$existing" ]; then
    existing_json="$(jq '.' "$existing" 2>/dev/null)" || {
      printf 'build-manifest-cards.sh: corrupted existing manifest, replacing\n' >&2
      existing_json='{"cards":[]}'
    }
  fi

  # 6. Merge: keep non-framework cards (filtered by partition), drop orphans, add specs
  local partition_prefix_filter
  if [ "$project" = "design_system" ]; then
    partition_prefix_filter='select((.path | test("^(screens|flows)/")) | not)'
  else
    partition_prefix_filter='select(.path | test("^(screens|flows)/"))'
  fi

  printf '%s' "$existing_json" | jq \
    --argjson spec_cards "$spec_cards_json" \
    --argjson fw_owned "$fw_owned_json" \
    --argjson spec_paths "$spec_paths_json" \
    "
    (.cards // []) as \$existing_cards |
    [\$existing_cards[] | select(.path as \$p | any(\$fw_owned[]; . == \$p) | not) | ${partition_prefix_filter}] as \$non_fw |
    [\$spec_cards[] | select(.path as \$p | any(\$spec_paths[]; . == \$p))] as \$current_specs |
    .cards = (\$non_fw + \$current_specs)
    "
}

# ---------------------------------------------------------------------------
# persist_last_published
# ---------------------------------------------------------------------------
# Writes .gaia/state/design-last-published.json from executed outcomes.
# Output is a per-project object:
#   {
#     "design_system": {"reference": <ref>, "last_published_at": <ts>, "files": [...]},
#     "product_design": {"reference": <ref>, "last_published_at": <ts>, "files": [...]}
#   }
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
# Hash validation: outcomes .file/.hash and hash-map values are validated
# BEFORE the writer computes or writes anything. deleted/failed outcomes
# may carry hash: null — those are not persisted, so null hashes are not
# checked.
#
# Arguments:
#   --outcomes <file>       JSON array [{file, outcome, hash}]
#   --prior <file>          Prior design-last-published.json (or /dev/null)
#   --output <file>         Path to write the new manifest
#   --local-hash-map <file> JSON object {file: local_hash}
#   --project <key>         Target project key (design_system | product_design;
#                           default: design_system)
#   --design-record PATH    Path to design-record.yaml (required)
#   --published-at <ts>     ISO-8601 UTC timestamp (default: current UTC)

persist_last_published() {
  local outcomes="" prior="/dev/null" output_file="" local_hash_map=""
  local project="design_system" design_record="" published_at=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --outcomes)       outcomes="$2";       shift 2 ;;
      --prior)          prior="$2";          shift 2 ;;
      --output)         output_file="$2";    shift 2 ;;
      --local-hash-map) local_hash_map="$2"; shift 2 ;;
      --project)        project="$2";        shift 2 ;;
      --design-record)  design_record="$2";  shift 2 ;;
      --published-at)   published_at="$2";   shift 2 ;;
      *) _bmc_die "persist_last_published: unknown option: $1"; return 1 ;;
    esac
  done

  [ -n "$outcomes" ]       || { _bmc_die "persist_last_published: --outcomes required"; return 1; }
  [ -n "$output_file" ]    || { _bmc_die "persist_last_published: --output required"; return 1; }
  [ -n "$local_hash_map" ] || { _bmc_die "persist_last_published: --local-hash-map required"; return 1; }
  [ -n "$design_record" ]  || { _bmc_die "persist_last_published: --design-record required"; return 1; }

  case "$project" in
    design_system|product_design) ;;
    *) _bmc_die "persist_last_published: invalid --project value: $project (must be design_system or product_design)"; return 1 ;;
  esac

  # ---- Validate --published-at (jq-only) ----
  if [ -z "$published_at" ]; then
    published_at="$(jq -rn 'now | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  fi
  # Round-trip strictness: (ts | fromdateiso8601 | todate) == ts
  local ts_valid
  ts_valid="$(jq -rn --arg ts "$published_at" '
    ($ts | fromdateiso8601 | todate) as $rt |
    if $rt != $ts then "malformed" else "ok" end
  ' 2>/dev/null)" || ts_valid="malformed"
  if [ "$ts_valid" = "malformed" ]; then
    _bmc_die "persist_last_published: malformed --published-at: $published_at (must be strict ISO-8601 UTC)"
    return 1
  fi
  # Future check (>60s ahead of now)
  local ts_future
  ts_future="$(jq -rn --arg ts "$published_at" '
    (($ts | fromdateiso8601) - now) as $diff |
    if $diff > 60 then "future" else "ok" end
  ')" || ts_future="ok"
  if [ "$ts_future" = "future" ]; then
    _bmc_die "persist_last_published: --published-at is >60s in the future: $published_at"
    return 1
  fi

  # ---- Resolve reference from design record ----
  local reference=""
  if [ ! -f "$design_record" ]; then
    _bmc_die "persist_last_published: design record not found: $design_record"
    return 1
  fi
  local dr_json
  dr_json="$(yq -o=json '.' "$design_record" 2>/dev/null)" || {
    _bmc_die "persist_last_published: failed to parse design record: $design_record"
    return 1
  }
  local schema_version
  schema_version="$(printf '%s' "$dr_json" | jq -r '.schema_version | tostring')"
  case "$schema_version" in
    1.0|1)
      if [ "$project" = "product_design" ]; then
        _bmc_die "persist_last_published: v1.0 design record does not support product_design — run /gaia-create-ux to upgrade"
        return 1
      fi
      reference="$(printf '%s' "$dr_json" | jq -r '.project.reference // empty')" || reference=""
      if [ -z "$reference" ] || [ "$reference" = "not-applicable" ]; then
        _bmc_die "persist_last_published: design_system_project.reference is not set (v1.0 design record)"
        return 1
      fi
      ;;
    *)
      # v2+: read from the project-specific key
      local proj_key
      case "$project" in
        design_system) proj_key="design_system_project" ;;
        product_design) proj_key="product_design_project" ;;
      esac
      # Check if the key exists and is an object
      local proj_obj
      proj_obj="$(printf '%s' "$dr_json" | jq --arg k "$proj_key" '.[$k] // null')"
      if [ "$proj_obj" = "null" ]; then
        _bmc_die "persist_last_published: $proj_key is not set in design record"
        return 1
      fi
      reference="$(printf '%s' "$proj_obj" | jq -r '.reference // empty')" || reference=""
      if [ -z "$reference" ] || [ "$reference" = "null" ]; then
        _bmc_die "persist_last_published: ${proj_key}.reference is not set"
        return 1
      fi
      ;;
  esac

  # ---- Validate ALL inputs (safety check BEFORE compute) ----
  # Outcomes: validate every filename
  jq "$SAFE_FILENAME_JQ_DEF"'
    .[] | .file | safe_filename
  ' "$outcomes" >/dev/null 2>&1 || {
    local diag
    diag="$(jq "$SAFE_FILENAME_JQ_DEF"'
      .[] | .file | safe_filename
    ' "$outcomes" 2>&1 >/dev/null || true)"
    _bmc_die "persist_last_published: unsafe filename in outcomes: $diag"
    return 1
  }
  # Outcomes: validate hashes on persisted outcomes (written/skipped/kept-designer/merged must have non-null hash)
  jq "$SAFE_HASH_JQ_DEF"'
    .[] |
    if (.outcome == "written" or .outcome == "skipped" or .outcome == "kept-designer" or .outcome == "merged") then
      if .hash == null then error("null hash on persisted outcome: " + .file)
      else .hash | safe_hash
      end
    elif .hash != null then
      .hash | safe_hash
    else . end
  ' "$outcomes" >/dev/null 2>&1 || {
    local diag
    diag="$(jq "$SAFE_HASH_JQ_DEF"'
      .[] |
      if (.outcome == "written" or .outcome == "skipped" or .outcome == "kept-designer" or .outcome == "merged") then
        if .hash == null then error("null hash on persisted outcome: " + .file)
        else .hash | safe_hash
        end
      elif .hash != null then
        .hash | safe_hash
      else . end
    ' "$outcomes" 2>&1 >/dev/null || true)"
    _bmc_die "persist_last_published: unsafe or null hash in outcomes: $diag"
    return 1
  }

  # --prior: validate every filename and hash in ALL keys (not just target)
  local prior_json='{"design_system":{"reference":null,"last_published_at":null,"files":[]},"product_design":{"reference":null,"last_published_at":null,"files":[]}}'
  if [ "$prior" != "/dev/null" ] && [ -f "$prior" ] && [ -s "$prior" ]; then
    if ! jq '.' "$prior" >/dev/null 2>&1; then
      _bmc_die "persist_last_published: corrupt JSON in --prior: $prior"
      return 1
    fi
    # Validate filenames and hashes in ALL keys of prior
    jq "$SAFE_FILENAME_JQ_DEF $SAFE_HASH_JQ_DEF"'
      (if type == "array" then [.[] | (.file | safe_filename), (.hash | safe_hash)]
       else [.design_system.files // [], .product_design.files // []] | add | .[] | (.file | safe_filename), (.hash | safe_hash)
       end) | empty
    ' "$prior" >/dev/null 2>&1 || {
      local diag
      diag="$(jq "$SAFE_FILENAME_JQ_DEF $SAFE_HASH_JQ_DEF"'
        (if type == "array" then [.[] | (.file | safe_filename), (.hash | safe_hash)]
         else [.design_system.files // [], .product_design.files // []] | add | .[] | (.file | safe_filename), (.hash | safe_hash)
         end) | empty
      ' "$prior" 2>&1 >/dev/null || true)"
      _bmc_die "persist_last_published: unsafe filename or hash in --prior: $diag"
      return 1
    }
    prior_json="$(jq '
      if type == "array" then
        {"design_system": {"reference": null, "last_published_at": null, "files": .},
         "product_design": {"reference": null, "last_published_at": null, "files": []}}
      else . end
    ' "$prior")"
  fi

  # --local-hash-map: validate every hash value
  local hash_map_json='{}'
  if [ -f "$local_hash_map" ] && [ -s "$local_hash_map" ]; then
    if ! jq '.' "$local_hash_map" >/dev/null 2>&1; then
      _bmc_die "persist_last_published: corrupt JSON in --local-hash-map: $local_hash_map"
      return 1
    fi
    jq "$SAFE_HASH_JQ_DEF"'
      to_entries[] | .value | safe_hash
    ' "$local_hash_map" >/dev/null 2>&1 || {
      local diag
      diag="$(jq "$SAFE_HASH_JQ_DEF"'
        to_entries[] | .value | safe_hash
      ' "$local_hash_map" 2>&1 >/dev/null || true)"
      _bmc_die "persist_last_published: unsafe hash in --local-hash-map: $diag"
      return 1
    }
    hash_map_json="$(jq '.' "$local_hash_map")"
  fi

  # ---- Compute the persisted file list for the target key ----
  local target_files
  target_files="$(jq --arg proj "$project" --argjson hash_map "$hash_map_json" '
    ($input | .[$proj].files // [] | map({(.file): .hash}) | add // {}) as $prior_map |
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
  ' --argjson input "$prior_json" "$outcomes")" || {
    _bmc_die "persist_last_published: jq compute failed"
    return 1
  }

  # ---- Locked write (read-modify-write with re-read inside lock) ----
  local out_dir
  out_dir="$(dirname "$output_file")"
  mkdir -p "$out_dir" || { _bmc_die "persist_last_published: failed to create $out_dir"; return 1; }

  # Lock lib sourced at load time (_BMC_HAS_LOCK)
  local use_lock="$_BMC_HAS_LOCK"

  local _PERSIST_LOCK_FD=200
  local lock_file="${output_file}.lock"

  if [ "$use_lock" -eq 1 ]; then
    acquire_lock "$lock_file" 10 "$_PERSIST_LOCK_FD" || {
      _bmc_die "persist_last_published: failed to acquire lock on $lock_file"
      return 1
    }
  fi

  # Re-read the on-disk --output inside the lock to pick up the OTHER key's data
  local on_disk_json='{"design_system":{"reference":null,"last_published_at":null,"files":[]},"product_design":{"reference":null,"last_published_at":null,"files":[]}}'
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    if ! jq '.' "$output_file" >/dev/null 2>&1; then
      if [ "$use_lock" -eq 1 ]; then
        release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
      fi
      _bmc_die "persist_last_published: corrupt on-disk --output: $output_file"
      return 1
    fi
    on_disk_json="$(jq '
      if type == "array" then
        {"design_system": {"reference": null, "last_published_at": null, "files": .},
         "product_design": {"reference": null, "last_published_at": null, "files": []}}
      else . end
    ' "$output_file")"
    # Validate filenames and hashes in the OTHER key (the one we won't overwrite).
    # Use the normalised $on_disk_json, NOT the raw file — a legacy flat array
    # has no named keys and jq would die with "Cannot index array".
    local other_key
    if [ "$project" = "design_system" ]; then other_key="product_design"; else other_key="design_system"; fi
    printf '%s' "$on_disk_json" | jq "$SAFE_FILENAME_JQ_DEF $SAFE_HASH_JQ_DEF"'
      .["'"$other_key"'"].files // [] | .[] | (.file | safe_filename), (.hash | safe_hash)
    ' >/dev/null 2>&1 || {
      if [ "$use_lock" -eq 1 ]; then
        release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
      fi
      local diag
      diag="$(printf '%s' "$on_disk_json" | jq "$SAFE_FILENAME_JQ_DEF $SAFE_HASH_JQ_DEF"'
        .["'"$other_key"'"].files // [] | .[] | (.file | safe_filename), (.hash | safe_hash)
      ' 2>&1 >/dev/null || true)"
      _bmc_die "persist_last_published: unsafe data in on-disk other key ($other_key): $diag"
      return 1
    }
  fi

  # Earlier-than-current timestamp warning
  local on_disk_ts
  on_disk_ts="$(printf '%s' "$on_disk_json" | jq -r --arg proj "$project" '.[$proj].last_published_at // empty')" || on_disk_ts=""
  if [ -n "$on_disk_ts" ]; then
    local ts_cmp
    ts_cmp="$(jq -rn --arg ts "$published_at" --arg prev "$on_disk_ts" '
      (($ts | fromdateiso8601) - ($prev | fromdateiso8601)) as $diff |
      if $diff < 0 then "earlier" else "ok" end
    ' 2>/dev/null)" || ts_cmp="ok"
    if [ "$ts_cmp" = "earlier" ]; then
      printf 'build-manifest-cards.sh: warning: --published-at %s is earlier than current %s\n' \
        "$published_at" "$on_disk_ts" >&2
    fi
  fi

  # Merge: update only the target key, preserve the other key
  local merged
  merged="$(printf '%s' "$on_disk_json" | jq \
    --arg proj "$project" \
    --argjson files "$target_files" \
    --arg ref "$reference" \
    --arg ts "$published_at" \
    '.[$proj] = {"reference": $ref, "last_published_at": $ts, "files": $files}'
  )"

  # Fill the other key's reference from the design record ONLY when creating
  # a new key (legacy migration: flat array wraps under DS, PD key is born
  # with null reference). An existing key with null reference stays as-is.
  local other_key
  if [ "$project" = "design_system" ]; then other_key="product_design"; else other_key="design_system"; fi
  local other_ref
  other_ref="$(printf '%s' "$merged" | jq -r --arg k "$other_key" '.[$k].reference // empty')" || other_ref=""
  # Only fill when the on-disk file did NOT already have this key at all
  # (newly created during legacy migration). An existing key with null
  # reference stays as-is — the user may have cleared it deliberately.
  local on_disk_has_other
  on_disk_has_other="$(printf '%s' "$on_disk_json" | jq --arg k "$other_key" 'has($k)')" || on_disk_has_other="true"
  if [ -z "$other_ref" ] && [ "$on_disk_has_other" != "true" ]; then
    local other_dr_ref=""
    case "$schema_version" in
      1.0|1)
        if [ "$other_key" = "design_system" ]; then
          other_dr_ref="$(printf '%s' "$dr_json" | jq -r '.project.reference // empty')" || other_dr_ref=""
        fi
        ;;
      *)
        local other_proj_key
        case "$other_key" in
          design_system) other_proj_key="design_system_project" ;;
          product_design) other_proj_key="product_design_project" ;;
        esac
        other_dr_ref="$(printf '%s' "$dr_json" | jq -r --arg k "$other_proj_key" '.[$k].reference // empty')" || other_dr_ref=""
        ;;
    esac
    if [ -n "$other_dr_ref" ] && [ "$other_dr_ref" != "not-applicable" ]; then
      merged="$(printf '%s' "$merged" | jq --arg k "$other_key" --arg r "$other_dr_ref" \
        '.[$k].reference = $r')"
    fi
  fi

  [ -n "$merged" ] || {
    if [ "$use_lock" -eq 1 ]; then
      release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
    fi
    _bmc_die "persist_last_published: failed to merge state"
    return 1
  }

  # Atomic write: mktemp + mv
  local tmp_file
  tmp_file="$(mktemp "${output_file}.XXXXXX")" || {
    if [ "$use_lock" -eq 1 ]; then
      release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
    fi
    _bmc_die "persist_last_published: failed to create temp file"
    return 1
  }
  if ! printf '%s\n' "$merged" > "$tmp_file" || ! mv "$tmp_file" "$output_file"; then
    rm -f "$tmp_file"
    if [ "$use_lock" -eq 1 ]; then
      release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
    fi
    _bmc_die "persist_last_published: failed to write $output_file"
    return 1
  fi

  if [ "$use_lock" -eq 1 ]; then
    release_lock "$_PERSIST_LOCK_FD" 2>/dev/null || true
  fi
}
