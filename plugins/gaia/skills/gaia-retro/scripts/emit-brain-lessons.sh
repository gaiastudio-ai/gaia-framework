#!/usr/bin/env bash
# emit-brain-lessons.sh — emit first-class `lesson` brain entries to
# .gaia/knowledge/brain-index.yaml from a completed retrospective.
#
# Each lesson is a schema-conforming brain entry with:
#   source_type: lesson
#   tags: [<category>]       (closed set: strategy | writing-rule |
#                              doc-maintenance-obligation | anti-pattern |
#                              tool-constraint)
#   path:                    (non-empty — points to the retro artifact)
#   trust.confidence: 1.0    (numeric — verified)
#   trust.source_url:        "retro:<sprint-id>" (provenance)
#   trust.fetched_at: null
#   trust.expires_at:        null by default; explicit if --expires-at set
#   edges: []
#
# Two invocation styles:
#   Single lesson:
#     emit-brain-lessons.sh --sprint-id <id> --retro-artifact <path>
#       --project-root <root> --category <cat> --synopsis <text>
#       [--expires-at <date>]
#
#   Batch (YAML file with a list of {category, synopsis} objects):
#     emit-brain-lessons.sh --sprint-id <id> --retro-artifact <path>
#       --project-root <root> --lessons-yaml <file>
#       [--expires-at <date>]
#
# Write path: if scripts/brain/update-brain-index.sh exists and is executable,
# delegate to it. Otherwise, locked (flock where available, best-effort on
# macOS) temp-file + mv append.
#
# Exit codes:
#   0 — all lessons emitted successfully
#   1 — validation failure (unknown category, empty path, bad confidence,
#       missing source_type) — NO partial write
#   2 — usage error
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail.

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Closed category set
# ---------------------------------------------------------------------------
_VALID_CATEGORIES="strategy writing-rule doc-maintenance-obligation anti-pattern tool-constraint"

_ebl_die() {
  printf 'emit-brain-lessons.sh: %s\n' "$1" >&2
  exit "${2:-2}"
}

_ebl_is_valid_category() {
  local cat="$1" c
  for c in $_VALID_CATEGORIES; do
    [ "$c" = "$cat" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# sha256 of a file — dual idiom (Linux sha256sum / macOS shasum).
# ---------------------------------------------------------------------------
_ebl_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Generate a lesson key from category + synopsis.
# Format: lesson-<category>-<first6 hex of sha256(synopsis)>
# ---------------------------------------------------------------------------
_ebl_lesson_key() {
  local category="$1" synopsis="$2"
  local hash
  # Dual idiom: sha256sum (Linux) first, shasum (macOS) fallback — same order
  # as _ebl_sha256_file.
  hash=$(printf '%s' "$synopsis" | sha256sum 2>/dev/null || printf '%s' "$synopsis" | shasum -a 256 2>/dev/null || echo "000000")
  hash=$(printf '%s' "$hash" | awk '{print $1}')
  printf 'lesson-%s-%s' "$category" "${hash:0:6}"
}

# ---------------------------------------------------------------------------
# Assemble one lesson entry as YAML text. Validates before returning.
# Returns the YAML on stdout; exits 1 on validation failure.
# ---------------------------------------------------------------------------
_ebl_assemble_entry() {
  local category="$1" synopsis="$2" retro_path="$3" sprint_id="$4" content_hash="$5" expires_at="$6"

  # Validate category.
  if ! _ebl_is_valid_category "$category"; then
    printf 'emit-brain-lessons.sh: unknown category: %s (closed set: %s)\n' "$category" "$_VALID_CATEGORIES" >&2
    return 1
  fi

  # Validate non-empty path.
  if [ -z "$retro_path" ]; then
    printf 'emit-brain-lessons.sh: path must be non-empty\n' >&2
    return 1
  fi

  # Validate synopsis non-empty.
  if [ -z "$synopsis" ]; then
    printf 'emit-brain-lessons.sh: synopsis must be non-empty\n' >&2
    return 1
  fi

  local key
  key="$(_ebl_lesson_key "$category" "$synopsis")"

  # Format expires_at.
  local expires_val
  if [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
    expires_val="null"
  else
    expires_val="\"$expires_at\""
  fi

  # Escape embedded double-quotes in path and synopsis so the YAML stays valid.
  local safe_path safe_synopsis
  safe_path="${retro_path//\"/\\\"}"
  safe_synopsis="${synopsis//\"/\\\"}"

  # Entry-level keys are exactly the 7 allowed by the schema
  # (additionalProperties: false): key, source_type, path, tags, synopsis,
  # trust, edges. No stray fields (fetched_at lives ONLY inside trust).
  cat <<YAML
- key: "$key"
  source_type: lesson
  path: "$safe_path"
  tags:
  - $category
  synopsis: "$safe_synopsis"
  trust:
    confidence: 1.0
    content_hash: "$content_hash"
    source_url: "retro:$sprint_id"
    fetched_at: null
    expires_at: $expires_val
  edges: []
YAML
}

# ---------------------------------------------------------------------------
# Parse a lessons-yaml file into category/synopsis pairs.
# Each entry is expected to have `category:` and `synopsis:` fields.
# Also checks for override fields: path, confidence, source_type.
# ---------------------------------------------------------------------------
_ebl_parse_lessons_yaml() {
  local file="$1"
  [ -r "$file" ] || { _ebl_die "lessons-yaml not readable: $file"; }

  # Pure awk parser for the simple list format.
  # Uses sentinels: __ABSENT__ for fields not present in the entry, __EMPTY__
  # for fields present with an empty value. This avoids the `read` IFS
  # delimiter-collapsing problem with empty columns.
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      s = trim(s)
      if (substr(s,1,1) == "\"" && substr(s,length(s),1) == "\"")
        s = substr(s, 2, length(s)-2)
      return s
    }
    function val_or_sentinel(v) {
      return (v == "") ? "__EMPTY__" : v
    }
    /^- category:/ {
      if (cat != "") print cat "\t" syn "\t" p "\t" conf "\t" st
      v = $0; sub(/^- category:[[:space:]]*/, "", v); cat = unquote(v)
      syn = ""; p = "__ABSENT__"; conf = "__ABSENT__"; st = "__ABSENT__"
      next
    }
    cat != "" && /^  synopsis:/ {
      v = $0; sub(/^  synopsis:[[:space:]]*/, "", v); syn = unquote(v)
      next
    }
    cat != "" && /^  path:/ {
      v = $0; sub(/^  path:[[:space:]]*/, "", v); p = val_or_sentinel(unquote(v))
      next
    }
    cat != "" && /^  confidence:/ {
      v = $0; sub(/^  confidence:[[:space:]]*/, "", v); conf = val_or_sentinel(unquote(v))
      next
    }
    cat != "" && /^  source_type:/ {
      v = $0; sub(/^  source_type:[[:space:]]*/, "", v); st = val_or_sentinel(unquote(v))
      next
    }
    END {
      if (cat != "") print cat "\t" syn "\t" p "\t" conf "\t" st
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Write assembled entries to the manifest. If update-brain-index.sh exists,
# delegate; otherwise locked temp-file + mv (flock when available, best-effort
# without it on macOS where flock may be absent).
# ---------------------------------------------------------------------------
_ebl_write_entries() {
  local manifest="$1" entries_yaml="$2"
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local updater="$self_dir/../../../scripts/brain/update-brain-index.sh"

  if [ -x "$updater" ]; then
    # Delegate to the partitioned writer.
    printf '%s' "$entries_yaml" | bash "$updater" --manifest "$manifest" --stdin
    return $?
  fi

  local knowledge_dir
  knowledge_dir="$(dirname "$manifest")"
  mkdir -p "$knowledge_dir"

  # Seed the manifest if missing or empty.
  if [ ! -f "$manifest" ] || [ ! -s "$manifest" ]; then
    printf 'schema_version: 1\nentries: []\n' > "$manifest"
  fi

  # Temp file lives in the SAME directory as the manifest so that `mv` is an
  # atomic rename on one filesystem.
  local tmp
  tmp="$(mktemp "${knowledge_dir}/.ebl-tmp-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # _ebl_do_write: the critical section that reads, appends, and renames.
  _ebl_do_write() {
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
    mv "$tmp" "$manifest"
  }

  # Serialize with flock if available; degrade gracefully on hosts without it.
  local lockfile="${knowledge_dir}/.brain-index.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200; _ebl_do_write ) 200>"$lockfile"
  else
    _ebl_do_write
  fi
}

# ---------------------------------------------------------------------------
# Validate an assembled entry via validate-artifact-schema.sh if available.
# Returns 0 on valid/skip, 1 on invalid.
# ---------------------------------------------------------------------------
_ebl_validate_manifest() {
  local manifest="$1" schema="$2"
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local validator="$self_dir/../../../scripts/lib/validate-artifact-schema.sh"

  if [ -r "$validator" ]; then
    # Source the validator to get the function.
    source "$validator"
    validate_artifact_schema "$schema" "$manifest"
    local rc=$?
    # 0 = valid, 3 = skip (no validator backend), else invalid
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
      return 0
    fi
    return 1
  fi
  # Validator not available — structural check skipped.
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local sprint_id="" retro_artifact="" project_root="" category="" synopsis=""
  local lessons_yaml="" expires_at=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sprint-id)       sprint_id="$2"; shift 2 ;;
      --retro-artifact)  retro_artifact="$2"; shift 2 ;;
      --project-root)    project_root="$2"; shift 2 ;;
      --category)        category="$2"; shift 2 ;;
      --synopsis)        synopsis="$2"; shift 2 ;;
      --lessons-yaml)    lessons_yaml="$2"; shift 2 ;;
      --expires-at)      expires_at="$2"; shift 2 ;;
      *) _ebl_die "unknown flag: $1" ;;
    esac
  done

  # Required args.
  [ -n "$sprint_id" ]      || _ebl_die "--sprint-id is required"
  [ -n "$retro_artifact" ] || _ebl_die "--retro-artifact is required"
  [ -n "$project_root" ]   || _ebl_die "--project-root is required"
  [ -f "$retro_artifact" ] || _ebl_die "retro artifact not found: $retro_artifact"

  local manifest="$project_root/.gaia/knowledge/brain-index.yaml"
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local schema="$self_dir/../../../schemas/brain-index.schema.json"

  # Content hash of the retro artifact.
  local content_hash
  content_hash="$(_ebl_sha256_file "$retro_artifact")"

  # Resolve the retro artifact path (relative to project root for the entry).
  local retro_path="$retro_artifact"

  # Collect lessons to emit.
  local all_entries=""
  local validation_failed=0

  if [ -n "$lessons_yaml" ]; then
    # Batch mode: parse the lessons YAML.
    local parsed
    parsed="$(_ebl_parse_lessons_yaml "$lessons_yaml")"
    [ -n "$parsed" ] || _ebl_die "no lessons found in $lessons_yaml"

    while IFS="$(printf '\t')" read -r cat syn p conf st; do
      [ -n "$cat" ] || continue

      # Resolve path: __EMPTY__ = field present but value empty (reject).
      # __ABSENT__ = field not in entry (use retro_path default).
      # Anything else = explicit override value.
      local effective_path="$retro_path"
      if [ "$p" = "__EMPTY__" ]; then
        printf 'emit-brain-lessons.sh: explicit empty path in lessons-yaml\n' >&2
        validation_failed=1
        break
      elif [ "$p" != "__ABSENT__" ]; then
        effective_path="$p"
      fi
      if [ -z "$effective_path" ]; then
        printf 'emit-brain-lessons.sh: path must be non-empty\n' >&2
        validation_failed=1
        break
      fi

      # Validate confidence override if present (not __ABSENT__).
      if [ "$conf" != "__ABSENT__" ]; then
        local check_conf="$conf"
        [ "$check_conf" = "__EMPTY__" ] && check_conf=""
        local conf_valid
        conf_valid=$(awk -v c="$check_conf" 'BEGIN { if (c+0 >= 0.0 && c+0 <= 1.0) print "yes"; else print "no" }')
        if [ "$conf_valid" != "yes" ]; then
          printf 'emit-brain-lessons.sh: confidence %s out of range [0.0, 1.0]\n' "$conf" >&2
          validation_failed=1
          break
        fi
      fi

      # Validate source_type override if present (not __ABSENT__).
      if [ "$st" = "__EMPTY__" ]; then
        printf 'emit-brain-lessons.sh: source_type must not be empty\n' >&2
        validation_failed=1
        break
      elif [ "$st" != "__ABSENT__" ] && [ "$st" != "lesson" ]; then
        printf 'emit-brain-lessons.sh: source_type must be "lesson", got: %s\n' "$st" >&2
        validation_failed=1
        break
      fi

      local entry
      entry="$(_ebl_assemble_entry "$cat" "$syn" "$effective_path" "$sprint_id" "$content_hash" "$expires_at")" || {
        validation_failed=1
        break
      }
      all_entries="${all_entries}${entry}
"
    done <<< "$parsed"

  elif [ -n "$category" ] && [ -n "$synopsis" ]; then
    # Single lesson mode.
    local entry
    entry="$(_ebl_assemble_entry "$category" "$synopsis" "$retro_path" "$sprint_id" "$content_hash" "$expires_at")" || exit 1
    all_entries="$entry"
  else
    _ebl_die "either --category + --synopsis or --lessons-yaml is required"
  fi

  # Abort on validation failure — no partial write.
  if [ "$validation_failed" -ne 0 ]; then
    exit 1
  fi

  [ -n "$all_entries" ] || _ebl_die "no lessons assembled"

  # Save a copy of the manifest for rollback on validation failure.
  local knowledge_dir
  knowledge_dir="$(dirname "$manifest")"
  local manifest_backup=""
  if [ -f "$manifest" ]; then
    manifest_backup="$(mktemp "${knowledge_dir}/.ebl-backup-XXXXXX")"
    cp "$manifest" "$manifest_backup"
  fi

  # Write entries.
  _ebl_write_entries "$manifest" "$all_entries"

  # Validate the resulting manifest.
  if [ -f "$schema" ]; then
    if ! _ebl_validate_manifest "$manifest" "$schema"; then
      printf 'emit-brain-lessons.sh: emitted manifest failed schema validation — rolling back\n' >&2
      if [ -n "$manifest_backup" ] && [ -f "$manifest_backup" ]; then
        mv "$manifest_backup" "$manifest"
      fi
      exit 1
    fi
  fi

  # Clean up backup.
  if [ -n "$manifest_backup" ] && [ -f "$manifest_backup" ]; then
    rm -f "$manifest_backup"
  fi

  printf 'emit-brain-lessons.sh: %d lesson(s) emitted to %s\n' \
    "$(echo "$all_entries" | grep -c '^- key:' || echo 0)" "$manifest"
}

main "$@"
