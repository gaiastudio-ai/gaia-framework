#!/usr/bin/env bash
# spawn-guard.sh — pre-spawn validation and post-spawn verification for
# /gaia-correct-course and /gaia-triage-findings subagent delegation to
# /gaia-create-story.
#
# Implements the Skill-to-Skill Delegation Pattern guard functions:
#   - sg_validate_origin_ref  — sanitize origin_ref before spawn
#   - sg_check_collision      — detect existing story at canonical path
#   - sg_cleanup_partial      — remove partial story file on failure
#   - sg_verify_frontmatter   — post-spawn verify origin/origin_ref
#
# CLI contract:
#   spawn-guard.sh validate-ref <origin_ref>
#       exit 0 — origin_ref is valid (alnum + -_:.)
#       exit 1 — invalid origin_ref (empty, null, shell-unsafe chars)
#
#   spawn-guard.sh check-collision <artifacts_dir> <story_key>
#       exit 0 — no collision, safe to spawn
#       exit 1 — collision detected or missing arguments
#
#   spawn-guard.sh verify <story_file> <expected_origin> <expected_origin_ref>
#       exit 0 — frontmatter origin/origin_ref match expected values
#       exit 1 — mismatch, missing fields, or file not found
#
#   spawn-guard.sh cleanup <story_file>
#       exit 0 — partial file removed (or already absent)
#       exit 1 — error (empty path)
#
# Follows the scripts-over-LLM principle: deterministic guard logic lives in a
# testable shell script rather than SKILL.md prose. Modeled on triage-guard.sh.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="spawn-guard.sh"

# ---------- logging helpers ----------
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------------------------------------------------------------------------
# _sg_fm_field — extract a single frontmatter scalar value
#
# Usage: _sg_fm_field <file> <field>
# Reads YAML frontmatter (the block between the first two --- markers)
# and prints the value of <field>. Trims surrounding whitespace and
# quotes. Returns non-zero if file missing. Prints empty if field absent.
#
# NOTE: Intentionally duplicated from triage-guard.sh (_tg_fm_field) rather
# than sourcing a shared library. Each guard script is self-contained per the
# scripts-over-LLM principle — no cross-script runtime dependencies.
# ---------------------------------------------------------------------------
_sg_fm_field() {
  local file="$1" field="$2"
  [ -f "$file" ] || return 1
  awk -v f="$field" '
    BEGIN { in_fm = 0; seen_open = 0 }
    /^---[[:space:]]*$/ {
      if (!seen_open) { in_fm = 1; seen_open = 1; next }
      else if (in_fm) { in_fm = 0; exit }
    }
    in_fm {
      # Match "<field>:" at the start of the line.
      if (match($0, "^" f "[[:space:]]*:[[:space:]]*")) {
        val = substr($0, RSTART + RLENGTH)
        # Strip trailing comment.
        sub(/[[:space:]]+#.*$/, "", val)
        # Strip surrounding whitespace.
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        # Strip matching surrounding single or double quotes.
        if (match(val, /^".*"$/) || match(val, /^'"'"'.*'"'"'$/)) {
          val = substr(val, 2, length(val) - 2)
        }
        print val
        exit
      }
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# _sg_resolve_story_file — locate an on-disk story file by key, recursively
#
# Usage: _sg_resolve_story_file <artifacts_dir> <story_key>
# Searches <artifacts_dir> RECURSIVELY for the canonical story file(s) of
# <story_key>, tolerating BOTH the epic-grouped layout
#   <artifacts_dir>/epic-<EPIC>-<slug>/stories/<story_key>-<slug>.md
# and the legacy flat layout
#   <artifacts_dir>/<story_key>-<slug>.md
# (and the dir-style <story_key>-<slug>/story.md variant).
# Prints every matching path (newline-separated); prints nothing when none
# match. Anchors on "<story_key>-" so a short key never matches a longer key
# that shares its prefix (e.g. E1-S1 must not match E1-S10). Mirrors the
# resolution logic in gaia-triage-findings/scripts/resolve-sprint-stories.sh.
# ---------------------------------------------------------------------------
_sg_resolve_story_file() {
  local artifacts_dir="${1:-}" story_key="${2:-}"
  [ -n "$artifacts_dir" ] && [ -n "$story_key" ] || return 0
  [ -d "$artifacts_dir" ] || return 0

  # Collect all find results first, THEN filter. Reading into a variable (not
  # piping into `head`) keeps this safe under `set -euo pipefail`: a downstream
  # caller that reads only the first line cannot deliver SIGPIPE to a live
  # `find`, which would otherwise surface as exit 141.
  local raw
  raw="$(find "$artifacts_dir" -type f \
    \( -path "*/${story_key}-*/story.md" -o -name "${story_key}-*.md" \) \
    2>/dev/null)" || raw=""
  [ -n "$raw" ] || return 0

  local match base parent_base
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    # Re-anchor: the file basename (or its parent dir for the story.md form)
    # MUST start with the exact key followed by a hyphen. `find -name` already
    # enforces this for the flat form; the parent-dir check covers the
    # <key>-<slug>/story.md form.
    base="${match##*/}"
    if [ "$base" = "story.md" ]; then
      parent_base="${match%/story.md}"
      parent_base="${parent_base##*/}"
      case "$parent_base" in
        "${story_key}-"*) printf '%s\n' "$match" ;;
      esac
    else
      case "$base" in
        "${story_key}-"*) printf '%s\n' "$match" ;;
      esac
    fi
  done <<EOF
$raw
EOF
  return 0
}

# ---------------------------------------------------------------------------
# _sg_resolve_from_pathspec — resolve a caller-supplied story-file argument
#
# Usage: _sg_resolve_from_pathspec <pathspec>
# Callers of `verify` / `cleanup` historically pass an UNEXPANDED glob of the
# form "<artifacts_dir>/<story_key>-*.md" (a single-level glob that the shell
# does not expand into the epic-grouped subtree). This helper accepts either:
#   1. a real file path (printed verbatim if it exists), OR
#   2. a "<dir>/<story_key>-*.md" glob whose "<story_key>" segment is
#      extracted and resolved recursively under "<dir>" via
#      _sg_resolve_story_file.
# Prints the first resolved path, or nothing when none match.
# ---------------------------------------------------------------------------
_sg_resolve_from_pathspec() {
  local spec="${1:-}"
  [ -n "$spec" ] || return 0
  # Direct hit: the argument is already a real file.
  if [ -f "$spec" ]; then
    printf '%s\n' "$spec"
    return 0
  fi
  # Glob form "<dir>/<key>-*.md": split into dir + trailing basename glob.
  local dir base key
  dir="${spec%/*}"
  base="${spec##*/}"
  case "$base" in
    *-\*.md)
      key="${base%-\*.md}"
      local matches
      matches="$(_sg_resolve_story_file "$dir" "$key")"
      # First line only — read without `head` so no SIGPIPE reaches the
      # producer. Emit nothing (not a blank line) when there is no match.
      [ -n "$matches" ] && printf '%s\n' "${matches%%$'\n'*}"
      ;;
    *)
      # Not a recognized glob and not a real file — nothing to resolve.
      :
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# sg_validate_origin_ref — validate origin_ref before passing to subagent
#
# Usage: sg_validate_origin_ref <origin_ref>
# Allow-list: alphanumeric characters plus - _ : .
# Rejects: empty string, "null" literal, shell-unsafe characters (;`$|/\),
#          newlines, path separators.
# Returns 0 on valid, 1 on invalid.
# ---------------------------------------------------------------------------
sg_validate_origin_ref() {
  local ref="${1:-}"

  # Reject empty
  if [ -z "$ref" ]; then
    log "sg_validate_origin_ref: origin_ref is empty — required argument"
    return 1
  fi

  # Reject "null" literal
  if [ "$ref" = "null" ]; then
    log "sg_validate_origin_ref: origin_ref is literal 'null' — not a valid reference"
    return 1
  fi

  # Reject multi-line input (newlines). grep matches line-by-line so each
  # line might pass individually. Count lines: if more than 1, reject.
  local line_count
  line_count="$(printf '%s\n' "$ref" | wc -l | tr -d ' ')"
  if [ "$line_count" -gt 1 ]; then
    log "sg_validate_origin_ref: origin_ref contains newline — not allowed"
    return 1
  fi

  # Allow-list: alnum + hyphen + underscore + colon + dot (single line)
  # Reject anything not matching the pattern
  if ! printf '%s' "$ref" | grep -qE '^[A-Za-z0-9._:_-]+$'; then
    log "sg_validate_origin_ref: origin_ref contains invalid characters — allowed: alnum, -, _, :, ."
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# sg_check_collision — detect existing story file at canonical path
#
# Usage: sg_check_collision <artifacts_dir> <story_key>
# Checks for files matching <story_key>-*.md in <artifacts_dir>.
# Uses a glob pattern anchored to the exact story key to avoid
# false positives (e.g., a short key must not match a longer key sharing the same prefix).
# Returns 0 if no collision (safe to spawn), 1 if collision detected.
# ---------------------------------------------------------------------------
sg_check_collision() {
  local artifacts_dir="${1:-}"
  local story_key="${2:-}"

  if [ -z "$artifacts_dir" ]; then
    log "sg_check_collision: missing required argument: artifacts_dir"
    return 1
  fi
  if [ -z "$story_key" ]; then
    log "sg_check_collision: missing required argument: story_key"
    return 1
  fi

  # Resolve RECURSIVELY under artifacts_dir so the guard sees story files in
  # the epic-grouped layout (epic-<EPIC>-<slug>/stories/<key>-*.md) as well as
  # the legacy flat layout. The resolver anchors on "<story_key>-" so a short
  # key never matches a longer key sharing the same prefix (E1-S1 vs E1-S10).
  local matches match
  matches="$(_sg_resolve_story_file "$artifacts_dir" "$story_key")"
  # First line only — read without `head` so no SIGPIPE reaches the producer.
  match="${matches%%$'\n'*}"
  if [ -n "$match" ]; then
    log "sg_check_collision: story file already exists at $match — collision detected for ${story_key}"
    printf 'Collision: %s already exists at %s. Delete or rename before retry.\n' "$story_key" "$match"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# sg_cleanup_partial — remove partial story file on spawn failure
#
# Usage: sg_cleanup_partial <story_file_path>
# Removes the file if it exists. Idempotent: returns 0 if file is already
# absent. Returns 1 only on empty path argument.
# ---------------------------------------------------------------------------
sg_cleanup_partial() {
  local arg="${1:-}"

  if [ -z "$arg" ]; then
    log "sg_cleanup_partial: missing required argument: story_file_path"
    return 1
  fi

  # Resolve a caller-supplied "<dir>/<key>-*.md" glob (or a real path) to the
  # actual on-disk file, tolerating the epic-grouped layout. A partial stub
  # left in epic-<EPIC>-<slug>/stories/ must still be removable.
  local file
  file="$(_sg_resolve_from_pathspec "$arg")"

  if [ -n "$file" ] && [ -f "$file" ]; then
    rm -f "$file"
    log "sg_cleanup_partial: removed partial file $(basename "$file")"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# sg_verify_frontmatter — post-spawn verify origin/origin_ref in frontmatter
#
# Usage: sg_verify_frontmatter <story_file> <expected_origin> <expected_origin_ref>
# Reads the story file's YAML frontmatter and verifies that:
#   1. The `origin` field exists and matches expected_origin
#   2. The `origin_ref` field exists and matches expected_origin_ref
# Returns 0 if both match, 1 on any mismatch or missing field.
# On mismatch, emits a schema-drift error.
# ---------------------------------------------------------------------------
sg_verify_frontmatter() {
  local arg="${1:-}"
  local expected_origin="${2:-}"
  local expected_origin_ref="${3:-}"

  if [ -z "$arg" ]; then
    log "sg_verify_frontmatter: missing required argument: story_file"
    return 1
  fi
  if [ -z "$expected_origin" ]; then
    log "sg_verify_frontmatter: missing required argument: expected_origin"
    return 1
  fi
  if [ -z "$expected_origin_ref" ]; then
    log "sg_verify_frontmatter: missing required argument: expected_origin_ref"
    return 1
  fi

  # Resolve a caller-supplied "<dir>/<key>-*.md" glob (or a real path) to the
  # actual on-disk file, tolerating the epic-grouped layout.
  local file
  file="$(_sg_resolve_from_pathspec "$arg")"

  if [ -z "$file" ] || [ ! -f "$file" ]; then
    log "sg_verify_frontmatter: story file not found: $arg"
    return 1
  fi

  local actual_origin actual_origin_ref
  actual_origin="$(_sg_fm_field "$file" "origin")" || {
    log "sg_verify_frontmatter: failed to read frontmatter from $file"
    return 1
  }
  actual_origin_ref="$(_sg_fm_field "$file" "origin_ref")" || {
    log "sg_verify_frontmatter: failed to read frontmatter from $file"
    return 1
  }

  local errors=0

  if [ -z "$actual_origin" ]; then
    log "sg_verify_frontmatter: origin field missing from frontmatter"
    printf 'Schema drift: origin field missing from story frontmatter\n'
    errors=$((errors + 1))
  elif [ "$actual_origin" != "$expected_origin" ]; then
    log "sg_verify_frontmatter: origin mismatch — expected=$expected_origin actual=$actual_origin"
    printf 'Schema drift: origin mismatch — expected "%s", got "%s"\n' "$expected_origin" "$actual_origin"
    errors=$((errors + 1))
  fi

  if [ -z "$actual_origin_ref" ]; then
    log "sg_verify_frontmatter: origin_ref field missing from frontmatter"
    printf 'Schema drift: origin_ref field missing from story frontmatter\n'
    errors=$((errors + 1))
  elif [ "$actual_origin_ref" != "$expected_origin_ref" ]; then
    log "sg_verify_frontmatter: origin_ref mismatch — expected=$expected_origin_ref actual=$actual_origin_ref"
    printf 'Schema drift: origin_ref mismatch — expected "%s", got "%s"\n' "$expected_origin_ref" "$actual_origin_ref"
    errors=$((errors + 1))
  fi

  if [ "$errors" -gt 0 ]; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  spawn-guard.sh validate-ref <origin_ref>
  spawn-guard.sh check-collision <artifacts_dir> <story_key>
  spawn-guard.sh verify <story_file> <expected_origin> <expected_origin_ref>
  spawn-guard.sh cleanup <story_file>

Exit codes:
  0   success (valid ref, no collision, match verified, cleanup done)
  1   error (invalid ref, collision found, mismatch, missing args)
EOF
}

main() {
  if [ $# -lt 1 ]; then
    usage >&2
    return 1
  fi
  local subcmd="$1"; shift
  case "$subcmd" in
    validate-ref)    sg_validate_origin_ref "$@" ;;
    check-collision) sg_check_collision "$@" ;;
    verify)          sg_verify_frontmatter "$@" ;;
    cleanup)         sg_cleanup_partial "$@" ;;
    -h|--help)       usage ;;
    *)               log "unknown subcommand: $subcmd"; usage >&2; return 1 ;;
  esac
}

# Execute main only when invoked directly (allow library-style sourcing in tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
