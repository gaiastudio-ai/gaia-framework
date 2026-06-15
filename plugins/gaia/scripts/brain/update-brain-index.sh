#!/usr/bin/env bash
# update-brain-index.sh — partitioned lesson/edge writer for the brain
# knowledge layer's manifest at .gaia/knowledge/brain-index.yaml.
#
# WHAT IT DOES
#   Incrementally updates the `lesson` partition of the brain-index manifest.
#   Two operations are supported:
#
#     --add-lesson  Merge/append a lesson entry (replace if key already exists).
#                   Accepts entry fields via CLI flags or bulk YAML via --stdin.
#
#     --add-edge    Append a typed edge to an existing entry (lesson only).
#                   Does NOT alter any other field on the target entry.
#
# PARTITION-DISJOINT BOUNDARY (enforced BY CONSTRUCTION)
#   This writer NEVER creates, updates, or deletes project-artifact entries.
#   Every write path reads the full manifest, passes project-artifact entries
#   through byte-untouched, and only mutates the lesson partition. A guard
#   rejects any --add-lesson call whose --source-type is not "lesson".
#
# ATOMIC WRITE
#   Sibling tempfile in the manifest's own directory + mv (matches the reindex
#   contract). No flock needed — GAIA skills run sequentially; partitioning is
#   by key ownership.
#
# EDGE MUTATION INVARIANT
#   Appending an edge to an entry MUST NOT change the entry's source_type or
#   any field other than the edges list.
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# YAML-string escape for a single-line double-quoted scalar.
# ---------------------------------------------------------------------------
_ubi_yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Die with a message and exit code.
# ---------------------------------------------------------------------------
_ubi_die() {
  printf 'update-brain-index.sh: %s\n' "$1" >&2
  exit "${2:-2}"
}

# ---------------------------------------------------------------------------
# Seed an empty manifest if missing or empty.
# ---------------------------------------------------------------------------
_ubi_seed_manifest() {
  local manifest="$1"
  local dir
  dir="$(dirname "$manifest")"
  mkdir -p "$dir"
  if [ ! -f "$manifest" ] || [ ! -s "$manifest" ]; then
    printf 'schema_version: 1\nentries:\n' > "$manifest"
  fi
}

# ---------------------------------------------------------------------------
# Extract a complete entry block (all lines from `- key:` to the next
# `- key:` or EOF) from a manifest, identified by key.
# ---------------------------------------------------------------------------
_ubi_extract_entry() {
  local manifest="$1" target_key="$2"
  awk -v key="$target_key" '
    /^- key:/ {
      k = $0; sub(/^- key:[[:space:]]*"?/, "", k); sub(/"?[[:space:]]*$/, "", k)
      if (k == key) { found = 1 }
      else if (found) { exit }
    }
    found { print }
  ' "$manifest"
}

# ---------------------------------------------------------------------------
# Emit a full lesson entry as YAML text (7 schema keys + trust block).
# ---------------------------------------------------------------------------
_ubi_render_lesson() {
  local key="$1" path="$2" tags="$3" synopsis="$4"
  local content_hash="$5" source_url="$6" expires_at="$7"
  local confidence="${8:-1.0}"

  local safe_key safe_path safe_synopsis safe_hash
  safe_key="$(_ubi_yaml_escape "$key")"
  safe_path="$(_ubi_yaml_escape "$path")"
  safe_synopsis="$(_ubi_yaml_escape "$synopsis")"
  safe_hash="$(_ubi_yaml_escape "$content_hash")"

  local source_url_val
  if [ -z "$source_url" ] || [ "$source_url" = "null" ]; then
    source_url_val="null"
  else
    source_url_val="\"$(_ubi_yaml_escape "$source_url")\""
  fi

  local expires_val
  if [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
    expires_val="null"
  else
    expires_val="\"$(_ubi_yaml_escape "$expires_at")\""
  fi

  printf -- '- key: "%s"\n' "$safe_key"
  printf '  source_type: lesson\n'
  printf '  path: "%s"\n' "$safe_path"
  printf '  tags: ["%s"]\n' "$(_ubi_yaml_escape "$tags")"
  printf '  synopsis: "%s"\n' "$safe_synopsis"
  printf '  edges: []\n'
  printf '  trust:\n'
  printf '    confidence: %s\n' "$confidence"
  printf '    content_hash: "%s"\n' "$safe_hash"
  printf '    source_url: %s\n' "$source_url_val"
  printf '    fetched_at: null\n'
  printf '    expires_at: %s\n' "$expires_val"
}

# ---------------------------------------------------------------------------
# add-lesson: merge a lesson entry into the manifest.
#   - If the key already exists AND is a lesson, replace it.
#   - If the key already exists but is NOT a lesson, refuse (partition guard).
#   - If the key is new, append it.
#   - project-artifact entries pass through byte-untouched.
# ---------------------------------------------------------------------------
_ubi_add_lesson() {
  local manifest="$1" key="$2" source_type="$3" path="$4" tags="$5"
  local synopsis="$6" content_hash="$7" source_url="$8" expires_at="$9"

  # Partition guard: refuse non-lesson source_type.
  if [ "$source_type" != "lesson" ]; then
    _ubi_die "partition guard: source_type must be 'lesson', got '$source_type'" 1
  fi

  _ubi_seed_manifest "$manifest"

  local manifest_dir
  manifest_dir="$(dirname "$manifest")"
  local tmp
  tmp="$(mktemp "${manifest_dir}/.ubi-tmp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null || true" RETURN

  # Build the new manifest: copy header, pass through non-matching entries
  # byte-for-byte, replace or append the target lesson entry.
  local new_entry
  new_entry="$(_ubi_render_lesson "$key" "$path" "$tags" "$synopsis" \
    "$content_hash" "$source_url" "$expires_at")"

  # Strategy: parse the manifest entry-by-entry using awk. For each entry:
  #   - If it matches the target key and is a lesson -> replace with new_entry
  #   - Otherwise -> pass through verbatim
  # If the target key was not found -> append new_entry at the end.

  local found_and_replaced=0
  {
    # Emit the header (everything before the first `- key:` line).
    awk '/^- key:/ { exit } { print }' "$manifest"

    # Process entries. Each entry block = `- key:` line through the line
    # before the next `- key:` (or EOF).
    local in_target=0 current_block="" current_key="" current_st=""
    while IFS= read -r line; do
      case "$line" in
        '- key: '*)
          # Flush the previous block.
          if [ -n "$current_block" ]; then
            if [ "$in_target" -eq 1 ]; then
              # Replace this entry with the new one.
              printf '%s\n' "$new_entry"
              found_and_replaced=1
            else
              printf '%s\n' "$current_block"
            fi
          fi
          in_target=0
          current_block="$line"
          current_key="${line#'- key: '}"
          current_key="${current_key#\"}"
          current_key="${current_key%\"}"
          current_st=""
          # Check if this is the target key.
          if [ "$current_key" = "$key" ]; then
            in_target=1
          fi
          ;;
        '  source_type: '*)
          current_block="${current_block}
${line}"
          current_st="${line#'  source_type: '}"
          # If the target key exists but is NOT a lesson, refuse.
          if [ "$in_target" -eq 1 ] && [ "$current_st" != "lesson" ]; then
            rm -f "$tmp" 2>/dev/null || true
            _ubi_die "partition guard: cannot overwrite source_type '$current_st' entry with key '$key'" 1
          fi
          ;;
        *)
          current_block="${current_block}
${line}"
          ;;
      esac
    done < <(awk '/^- key:/ { started=1 } started { print }' "$manifest")

    # Flush the last block.
    if [ -n "$current_block" ]; then
      if [ "$in_target" -eq 1 ]; then
        printf '%s\n' "$new_entry"
        found_and_replaced=1
      else
        printf '%s\n' "$current_block"
      fi
    fi

    # If the key was not found, append.
    if [ "$found_and_replaced" -eq 0 ]; then
      printf '%s\n' "$new_entry"
    fi
  } > "$tmp"

  # Atomic rename.
  mv "$tmp" "$manifest" || {
    rm -f "$tmp" 2>/dev/null || true
    _ubi_die "atomic rename failed" 1
  }
}

# ---------------------------------------------------------------------------
# add-edge: append a typed edge to an existing entry.
#   - Only lesson entries may be mutated.
#   - The entry's source_type (and all other fields) are preserved verbatim.
#   - Only the edges list is modified.
# ---------------------------------------------------------------------------
_ubi_add_edge() {
  local manifest="$1" target_key="$2" edge_type="$3" edge_target="$4"

  # Validate edge type against the closed 7-enum.
  local valid_types="implements traces-to decomposes governed-by verified-by reviewed-in designs"
  local found_type=0
  local t
  for t in $valid_types; do
    if [ "$t" = "$edge_type" ]; then
      found_type=1
      break
    fi
  done
  if [ "$found_type" -eq 0 ]; then
    _ubi_die "invalid edge type '$edge_type'; valid: $valid_types" 1
  fi

  [ -f "$manifest" ] || _ubi_die "manifest not found: $manifest" 1

  local manifest_dir
  manifest_dir="$(dirname "$manifest")"
  local tmp
  tmp="$(mktemp "${manifest_dir}/.ubi-tmp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null || true" RETURN

  # Build the new manifest using awk. For the target key's entry, append the
  # new edge to the edges list. All other fields (including source_type) are
  # emitted byte-verbatim.
  #
  # The awk approach: accumulate lines per entry. When we reach the target
  # entry, insert the new edge just before the `  trust:` line (which follows
  # the edges block). If edges was `edges: []`, replace it with the expanded
  # form.

  local safe_edge_target
  safe_edge_target="$(_ubi_yaml_escape "$edge_target")"

  awk -v tkey="$target_key" -v etype="$edge_type" -v etarget="$safe_edge_target" '
    BEGIN { in_target = 0; edge_injected = 0; found = 0 }

    /^- key:/ {
      k = $0; sub(/^- key:[[:space:]]*"?/, "", k); sub(/"?[[:space:]]*$/, "", k)
      if (k == tkey) { in_target = 1; found = 1 }
      else { in_target = 0 }
    }

    # In the target entry, handle the edges line.
    in_target && /^  edges: \[\]/ {
      # Replace empty edges with the new edge.
      printf "  edges:\n"
      printf "    - type: %s\n", etype
      printf "      target: \"%s\"\n", etarget
      edge_injected = 1
      next
    }

    # In the target entry with existing edges, append before trust:.
    in_target && /^  trust:/ && !edge_injected {
      # Append the new edge just before trust.
      printf "    - type: %s\n", etype
      printf "      target: \"%s\"\n", etarget
      edge_injected = 1
    }

    { print }

    END {
      if (!found) {
        printf "update-brain-index.sh: target key not found: %s\n", tkey > "/dev/stderr"
        exit 1
      }
    }
  ' "$manifest" > "$tmp"
  local awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  # Verify the target entry's source_type is lesson (partition guard).
  local target_st
  target_st="$(_ubi_extract_entry "$tmp" "$target_key" | awk '/^  source_type:/ { print $2; exit }')"
  if [ "$target_st" != "lesson" ]; then
    rm -f "$tmp" 2>/dev/null || true
    _ubi_die "partition guard: --add-edge target '$target_key' has source_type '$target_st', not 'lesson'" 1
  fi

  # Atomic rename.
  mv "$tmp" "$manifest" || {
    rm -f "$tmp" 2>/dev/null || true
    _ubi_die "atomic rename failed" 1
  }
}

# ---------------------------------------------------------------------------
# stdin mode: read bulk lesson YAML from stdin and append entries.
# Each entry must be a valid `- key:` block with source_type: lesson.
# ---------------------------------------------------------------------------
_ubi_stdin_mode() {
  local manifest="$1"
  _ubi_seed_manifest "$manifest"

  local entries_yaml
  entries_yaml="$(cat)"

  # Validate: every source_type in the input must be "lesson".
  local bad_st
  bad_st="$(printf '%s\n' "$entries_yaml" | awk '/source_type:/ { st=$2; if (st != "lesson") print st }')"
  if [ -n "$bad_st" ]; then
    _ubi_die "partition guard: stdin contains non-lesson source_type: $bad_st" 1
  fi

  local manifest_dir
  manifest_dir="$(dirname "$manifest")"
  local tmp
  tmp="$(mktemp "${manifest_dir}/.ubi-tmp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null || true" RETURN

  # Copy existing manifest, append the new entries.
  if grep -q '^entries: \[\]' "$manifest"; then
    sed 's/^entries: \[\]/entries:/' "$manifest" > "$tmp"
    printf '%s\n' "$entries_yaml" >> "$tmp"
  elif grep -q '^entries:' "$manifest"; then
    cat "$manifest" > "$tmp"
    printf '%s\n' "$entries_yaml" >> "$tmp"
  else
    cat "$manifest" > "$tmp"
    printf 'entries:\n' >> "$tmp"
    printf '%s\n' "$entries_yaml" >> "$tmp"
  fi

  mv "$tmp" "$manifest" || {
    rm -f "$tmp" 2>/dev/null || true
    _ubi_die "atomic rename failed" 1
  }
}

# ---------------------------------------------------------------------------
# CLI dispatcher.
# ---------------------------------------------------------------------------
main() {
  local manifest="" mode="" key="" source_type="lesson" path="" tags=""
  local synopsis="" content_hash="" source_url="" expires_at=""
  local target_key="" edge_type="" edge_target=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest)      manifest="$2"; shift 2 ;;
      --add-lesson)    mode="add-lesson"; shift ;;
      --add-edge)      mode="add-edge"; shift ;;
      --stdin)         mode="stdin"; shift ;;
      --key)           key="$2"; shift 2 ;;
      --source-type)   source_type="$2"; shift 2 ;;
      --path)          path="$2"; shift 2 ;;
      --tags)          tags="$2"; shift 2 ;;
      --synopsis)      synopsis="$2"; shift 2 ;;
      --content-hash)  content_hash="$2"; shift 2 ;;
      --source-url)    source_url="$2"; shift 2 ;;
      --expires-at)    expires_at="$2"; shift 2 ;;
      --target-key)    target_key="$2"; shift 2 ;;
      --edge-type)     edge_type="$2"; shift 2 ;;
      --edge-target)   edge_target="$2"; shift 2 ;;
      *) _ubi_die "unknown flag: $1" ;;
    esac
  done

  # Resolve manifest path — default to the canonical brain-index.yaml location.
  if [ -z "$manifest" ]; then
    local _root="${CLAUDE_PROJECT_ROOT:-$PWD}"
    manifest="$_root/.gaia/knowledge/brain-index.yaml"
  fi

  case "$mode" in
    add-lesson)
      [ -n "$key" ]          || _ubi_die "--key is required for --add-lesson"
      [ -n "$path" ]         || _ubi_die "--path is required for --add-lesson"
      [ -n "$synopsis" ]     || _ubi_die "--synopsis is required for --add-lesson"
      [ -n "$content_hash" ] || _ubi_die "--content-hash is required for --add-lesson"
      _ubi_add_lesson "$manifest" "$key" "$source_type" "$path" "$tags" \
        "$synopsis" "$content_hash" "${source_url:-}" "${expires_at:-}"
      ;;
    add-edge)
      [ -n "$target_key" ]  || _ubi_die "--target-key is required for --add-edge"
      [ -n "$edge_type" ]   || _ubi_die "--edge-type is required for --add-edge"
      [ -n "$edge_target" ] || _ubi_die "--edge-target is required for --add-edge"
      _ubi_add_edge "$manifest" "$target_key" "$edge_type" "$edge_target"
      ;;
    stdin)
      _ubi_stdin_mode "$manifest"
      ;;
    *)
      _ubi_die "mode required: --add-lesson, --add-edge, or --stdin"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
  exit $?
fi
