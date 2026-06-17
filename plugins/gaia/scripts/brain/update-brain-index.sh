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
#   Entry creation/deletion/replacement is lesson-only: this writer NEVER
#   creates, replaces, or deletes project-artifact entries. A guard rejects
#   any --add-lesson call whose --source-type is not "lesson".
#
#   Edge mutations (--add-edge, --batch-edges) span ALL source_types because
#   they modify ONLY the edges list — per the EDGE MUTATION INVARIANT below,
#   no other field changes. This is safe: the partition boundary protects
#   entry ownership, not edge connectivity.
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

  # Idempotency guard: if the (type, target) pair already exists on this entry,
  # skip the write entirely. Prevents duplicate edges on repeated lifecycle or
  # review events.
  local existing_block
  existing_block="$(_ubi_extract_entry "$manifest" "$target_key")"
  if [ -n "$existing_block" ]; then
    local dup_check
    dup_check="$(printf '%s\n' "$existing_block" | awk -v et="$edge_type" -v tgt="$edge_target" '
      /- type:/ { t = $0; sub(/.*- type:[[:space:]]*/, "", t); gsub(/[[:space:]]*$/, "", t) }
      /target:/ { g = $0; sub(/.*target:[[:space:]]*"?/, "", g); gsub(/"?[[:space:]]*$/, "", g)
        if (t == et && g == tgt) { print "DUP"; exit }
      }
    ')"
    if [ "$dup_check" = "DUP" ]; then
      return 0
    fi
  fi

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
  # Under set -e the awk redirect failure exits before reaching this point,
  # and _ubi_die exits (not returns). The prior awk_rc error-handling block
  # was unreachable — removed for clarity.

  # Edge-mutation source_type check: edge appends are safe on ANY source_type
  # because they modify ONLY the edges list (per the EDGE MUTATION INVARIANT).
  # The partition-disjoint boundary protects entry creation/deletion/replacement
  # (--add-lesson), not edge-only mutations. Verify the target entry exists
  # (awk END block already does this) but do NOT restrict by source_type.

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
# batch-edges: read edge_type\tedge_target lines from stdin and add them all
# to a single target key in ONE manifest read-merge-rewrite pass. Idempotent:
# edges already present on the entry are skipped.
# ---------------------------------------------------------------------------
_ubi_batch_edges() {
  local manifest="$1" target_key="$2"

  [ -f "$manifest" ] || _ubi_die "manifest not found: $manifest" 1

  # Collect edges from stdin.
  local edge_lines
  edge_lines="$(cat)"
  [ -n "$edge_lines" ] || return 0

  # Validate all edge types against the closed 7-enum and build the awk
  # edge-data block. Also collect (type,target) pairs for dedup.
  local valid_types="implements traces-to decomposes governed-by verified-by reviewed-in designs"
  local awk_edges="" edge_count=0
  local etype etarget safe_et
  while IFS=$'\t' read -r etype etarget; do
    [ -n "$etype" ] || continue
    [ -n "$etarget" ] || continue
    local found_type=0 t
    for t in $valid_types; do
      [ "$t" = "$etype" ] && { found_type=1; break; }
    done
    [ "$found_type" -eq 1 ] || _ubi_die "invalid edge type '$etype'; valid: $valid_types" 1
    safe_et="$(_ubi_yaml_escape "$etarget")"
    awk_edges="${awk_edges}${etype}	${safe_et}
"
    edge_count=$((edge_count + 1))
  done <<< "$edge_lines"

  [ "$edge_count" -gt 0 ] || return 0

  # Extract existing edges on the target entry for dedup.
  local existing_block
  existing_block="$(_ubi_extract_entry "$manifest" "$target_key")"
  [ -n "$existing_block" ] || {
    printf 'update-brain-index.sh: target key not found: %s\n' "$target_key" >&2
    return 1
  }

  # Filter out edges that already exist.
  local filtered_edges="" new_count=0
  while IFS=$'\t' read -r etype etarget; do
    [ -n "$etype" ] || continue
    local dup_check
    dup_check="$(printf '%s\n' "$existing_block" | awk -v et="$etype" -v tgt="$etarget" '
      /- type:/ { t = $0; sub(/.*- type:[[:space:]]*/, "", t); gsub(/[[:space:]]*$/, "", t) }
      /target:/ { g = $0; sub(/.*target:[[:space:]]*"?/, "", g); gsub(/"?[[:space:]]*$/, "", g)
        if (t == et && g == tgt) { print "DUP"; exit }
      }
    ')"
    if [ "$dup_check" != "DUP" ]; then
      filtered_edges="${filtered_edges}${etype}	${etarget}
"
      new_count=$((new_count + 1))
    fi
  done <<< "$awk_edges"

  [ "$new_count" -gt 0 ] || return 0  # all edges already present

  local manifest_dir
  manifest_dir="$(dirname "$manifest")"
  local tmp
  tmp="$(mktemp "${manifest_dir}/.ubi-tmp-XXXXXX")"

  # Write the new edges to a temp data file for awk to read.
  local edges_data="$manifest_dir/.ubi-edges-XXXXXX"
  edges_data="$(mktemp "$edges_data")"
  printf '%s' "$filtered_edges" > "$edges_data"

  # shellcheck disable=SC2064
  trap "rm -f '$tmp' '$edges_data' 2>/dev/null || true" RETURN

  # Single awk pass: inject all new edges into the target entry.
  awk -v tkey="$target_key" -v edgefile="$edges_data" '
    BEGIN {
      n = 0
      while ((getline line < edgefile) > 0) {
        if (line == "") continue
        split(line, parts, "\t")
        n++
        etypes[n] = parts[1]
        etargets[n] = parts[2]
      }
      close(edgefile)
      in_target = 0; edge_injected = 0; found = 0
    }

    /^- key:/ {
      k = $0; sub(/^- key:[[:space:]]*"?/, "", k); sub(/"?[[:space:]]*$/, "", k)
      if (k == tkey) { in_target = 1; found = 1 }
      else { in_target = 0 }
    }

    in_target && /^  edges: \[\]/ {
      printf "  edges:\n"
      for (i = 1; i <= n; i++) {
        printf "    - type: %s\n", etypes[i]
        printf "      target: \"%s\"\n", etargets[i]
      }
      edge_injected = 1
      next
    }

    in_target && /^  trust:/ && !edge_injected {
      for (i = 1; i <= n; i++) {
        printf "    - type: %s\n", etypes[i]
        printf "      target: \"%s\"\n", etargets[i]
      }
      edge_injected = 1
    }

    { print }

    END {
      if (!found) {
        printf "update-brain-index.sh: target key not found: %s\n", tkey > "/dev/stderr"
        exit 1
      }
      if (found && !edge_injected) {
        printf "update-brain-index.sh: edge injection failed for key %s (no trust: or edges: [] anchor)\n", tkey > "/dev/stderr"
        exit 1
      }
    }
  ' "$manifest" > "$tmp"

  rm -f "$edges_data" 2>/dev/null || true

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
      --batch-edges)   mode="batch-edges"; shift ;;
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
  # When running as CLI (not sourced), honor GAIA_KNOWLEDGE_PATH via the shared
  # paths helper so this script behaves consistently with sibling brain scripts.
  # No silent $PWD fallback in CLI mode — require an explicit source.
  if [ -z "$manifest" ]; then
    if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
      # CLI mode: check for an explicit GAIA_KNOWLEDGE_PATH or
      # CLAUDE_PROJECT_ROOT before falling back. Source gaia-paths.sh to
      # resolve GAIA_KNOWLEDGE_DIR from the env-var override (if exported).
      if [ -n "${GAIA_KNOWLEDGE_PATH:-}" ] || [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
        local _self_dir
        _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local _paths_helper="$_self_dir/../lib/gaia-paths.sh"
        if [ -r "$_paths_helper" ]; then
          # shellcheck source=../lib/gaia-paths.sh
          . "$_paths_helper" || true
        fi
        if [ -n "${GAIA_KNOWLEDGE_DIR:-}" ]; then
          manifest="$GAIA_KNOWLEDGE_DIR/brain-index.yaml"
        else
          manifest="${CLAUDE_PROJECT_ROOT:-.}/.gaia/knowledge/brain-index.yaml"
        fi
      else
        _ubi_die "no --manifest specified and neither GAIA_KNOWLEDGE_PATH nor CLAUDE_PROJECT_ROOT is set" 1
      fi
    else
      # Sourced mode: callers always set CLAUDE_PROJECT_ROOT or pass --manifest.
      # Fall back to $PWD for backward compatibility with direct-source callers.
      local _root="${CLAUDE_PROJECT_ROOT:-$PWD}"
      manifest="$_root/.gaia/knowledge/brain-index.yaml"
    fi
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
    batch-edges)
      [ -n "$target_key" ]  || _ubi_die "--target-key is required for --batch-edges"
      _ubi_batch_edges "$manifest" "$target_key"
      ;;
    stdin)
      _ubi_stdin_mode "$manifest"
      ;;
    *)
      _ubi_die "mode required: --add-lesson, --add-edge, --batch-edges, or --stdin"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
  exit $?
fi
