#!/usr/bin/env bash
# independence-gate.sh — scriptable pre-mutation independence gate
#
# Two modes:
#   DEFAULT  Runs independence-check.sh with --overlay for a proposed
#            story mutation. Called by inject, add-stories, add-feature.
#   EDIT     Stages field edits on a story file, validates (pre-write
#            hook for touch-set values), runs the check with the staged
#            copy as an overlay, and moves the copy into place on pass.
#            On failure the original file is byte-unchanged (rollback =
#            no move).
#
# CLI:
#   independence-gate.sh <story_file> --candidate <sprint_id> [--overlay <file>]...
#   independence-gate.sh edit --story <file> --set <field>=<value> ...
#
# Exit codes:
#   0  PASS (mutation may proceed)
#   1  FAIL (mutation blocked; diagnostic on stderr)
#   2  usage error
#
# Bash 3.2 compatible. No local -A, mapfile, readarray.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="independence-gate.sh"
_IG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source touch-set sanitizer for edit mode pre-write validation.
# shellcheck source=lib/touch-set-sanitizer.sh
. "${_IG_SCRIPT_DIR}/lib/touch-set-sanitizer.sh"

# Path constants — no bare .gaia/ literal in executable code.
_IG_GAIA_DIR=".gaia"
_IG_STATE_REL="${_IG_GAIA_DIR}/state"
_IG_CONFIG_REL="${_IG_GAIA_DIR}/config/project-config.yaml"

# Project root.
_IG_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

# Temp files cleaned on exit.
_IG_TMPS=""
_ig_cleanup() {
  local f
  for f in $_IG_TMPS; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap '_ig_cleanup' EXIT INT TERM

_ig_add_tmp() { _IG_TMPS="${_IG_TMPS} $1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ig_die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit "${2:-1}"
}

_ig_usage() {
  cat <<'USAGE'
Usage:
  independence-gate.sh <story_file> --candidate <sprint_id> [--overlay <file>]...
  independence-gate.sh edit --story <file> --set <field>=<value> ...

Default mode:
  Runs the independence check with the story file as an overlay and returns
  the verdict. Additional overlays may be specified.

Edit mode:
  Stages field edits on a story file, runs the check with the staged copy
  as an overlay, and applies on pass (rollback = no move on failure).
  Supported fields: depends_on, blocks, predicted_touch_set.

Exit codes:
  0  PASS    1  FAIL    2  usage error
USAGE
  exit 0
}

# ---------------------------------------------------------------------------
# _ig_is_concurrent_mode
#   Returns 0 when concurrent sprints are active (max_concurrent_active > 1
#   OR per-sprint state files exist). Mirrors sprint-state.sh's check.
# ---------------------------------------------------------------------------
_ig_is_concurrent_mode() {
  local config_f="${_IG_PROJECT_ROOT%/}/${_IG_CONFIG_REL}"
  local max_concurrent=""
  if [ -f "$config_f" ]; then
    max_concurrent="$(awk '/^[[:space:]]*max_concurrent_active:/ {
      v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
      gsub(/["'"'"'[:space:]]/, "", v); print v; exit
    }' "$config_f" 2>/dev/null)" || true
  fi
  if [ -n "$max_concurrent" ] && [ "$max_concurrent" -gt 1 ] 2>/dev/null; then
    return 0
  fi
  # Check for per-sprint state files.
  local state_dir="${_IG_PROJECT_ROOT%/}/${_IG_STATE_REL}"
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.lock|*.result) continue ;; esac
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# _ig_read_fm_field <file> <field>
#   Read a scalar YAML frontmatter field value.
# ---------------------------------------------------------------------------
_ig_read_fm_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    BEGIN { in_fm=0; started=0 }
    /^---[[:space:]]*$/ {
      if (!started) { started=1; in_fm=1; next }
      else exit
    }
    !in_fm { next }
    {
      pat = "^" f ":[[:space:]]*"
      if ($0 ~ pat) {
        v = $0; sub(pat, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# _ig_find_key_in_other_sprints <key> <candidate_sprint>
#   Check if key appears in another active sprint's state file (carry-over
#   in flight, R77). Returns 0 and prints the sprint id if found, 1 if not.
# ---------------------------------------------------------------------------
_ig_find_key_in_other_sprints() {
  local key="$1" candidate="$2"
  local state_dir="${_IG_PROJECT_ROOT%/}/${_IG_STATE_REL}"
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.lock|*.result) continue ;; esac
    local sid="" st=""
    sid="$(awk '/^sprint_id:[[:space:]]*/ {
        v = $0; sub(/^sprint_id:[[:space:]]*/, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v; exit
      }' "$f" 2>/dev/null)" || continue
    [ "$sid" != "$candidate" ] || continue
    st="$(awk '/^status:[[:space:]]*/ {
        v = $0; sub(/^status:[[:space:]]*/, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        print v; exit
      }' "$f" 2>/dev/null)" || continue
    [ "$st" = "active" ] || continue
    # Check if key appears in stories list.
    if awk -v k="$key" '
      /^stories:/ { in_s=1; saw_s=1; next }
      /^items:/ && !saw_s { in_s=1; next }
      in_s && /^[^[:space:]-]/ { in_s=0 }
      in_s && /key:/ {
        v=$0; sub(/.*key:[[:space:]]*/, "", v)
        gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
        if (v == k) { found=1; exit }
      }
      END { exit (found ? 0 : 1) }
    ' "$f" 2>/dev/null; then
      printf '%s' "$sid"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Default mode
# ---------------------------------------------------------------------------
_ig_default_mode() {
  local story_file="$1"; shift
  local candidate=""
  local overlay_files=""  # newline-separated paths

  while [ $# -gt 0 ]; do
    case "$1" in
      --candidate) candidate="${2:-}"; shift 2 ;;
      --overlay)
        overlay_files="${overlay_files}${overlay_files:+
}${2:-}"
        shift 2 ;;
      -h|--help) _ig_usage ;;
      *) _ig_die "unknown option: $1" 2 ;;
    esac
  done

  [ -n "$candidate" ] || _ig_die "--candidate is required" 2
  [ -f "$story_file" ] || _ig_die "story file not found: $story_file"

  # Single-sprint mode: skip.
  if ! _ig_is_concurrent_mode; then
    return 0
  fi

  # Read the key from the story file.
  local key=""
  key="$(_ig_read_fm_field "$story_file" "key")" || true

  # Build the command as an array — no eval, no injection risk.
  local ic_script="${_IG_SCRIPT_DIR}/independence-check.sh"
  [ -x "$ic_script" ] || _ig_die "independence-check.sh not found: $ic_script"

  local cmd_args=()
  cmd_args+=( bash "$ic_script" --candidate "$candidate" )
  cmd_args+=( --overlay "$story_file" )
  if [ -n "$overlay_files" ]; then
    local ov
    while IFS= read -r ov; do
      [ -n "$ov" ] || continue
      cmd_args+=( --overlay "$ov" )
    done <<< "$overlay_files"
  fi

  # Build skip args for carry-over keys (R77).
  # Validate key format to prevent injection via crafted story keys.
  if [ -n "$key" ]; then
    if ! printf '%s' "$key" | /usr/bin/grep -qE '^E[0-9]+-S[0-9]+$'; then
      _ig_die "invalid story key format: $key"
    fi
    local other_sprint=""
    other_sprint="$(_ig_find_key_in_other_sprints "$key" "$candidate" 2>/dev/null)" || true
    if [ -n "$other_sprint" ]; then
      cmd_args+=( --skip-key-in-sprint "${key}:${other_sprint}" )
    fi
  fi

  local rc=0
  "${cmd_args[@]}" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _ig_apply_field_edit <file> <field> <value>
#   Write a YAML array field to a story file's frontmatter.
# ---------------------------------------------------------------------------
_ig_apply_field_edit() {
  local file="$1" field="$2" value="$3"

  # Build a JSON array from comma-separated values.
  local json_array
  json_array="$(printf '%s\n' "$value" | tr ',' '\n' | awk '
    BEGIN { printf "[" }
    /^[[:space:]]*$/ { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 == "") next
      gsub(/\\/, "\\\\", $0); gsub(/"/, "\\\"", $0)
      if (n++ > 0) printf ", "
      printf "\"%s\"", $0
    }
    END { printf "]\n" }
  ')"

  IG_FIELD="$field" IG_VAL="$json_array" \
    yq --front-matter=process -i \
      '.[strenv(IG_FIELD)] = (strenv(IG_VAL) | from_yaml)' \
      "$file" || return 1
}

# ---------------------------------------------------------------------------
# Edit mode
# ---------------------------------------------------------------------------
_ig_edit_mode() {
  shift  # consume "edit"
  local story_file=""
  local set_args=""  # newline-separated field=value pairs

  while [ $# -gt 0 ]; do
    case "$1" in
      --story) story_file="${2:-}"; shift 2 ;;
      --set)
        set_args="${set_args}${set_args:+
}${2:-}"
        shift 2 ;;
      -h|--help) _ig_usage ;;
      *) _ig_die "unknown option: $1" 2 ;;
    esac
  done

  [ -n "$story_file" ] || _ig_die "--story is required" 2
  [ -f "$story_file" ] || _ig_die "story file not found: $story_file"
  [ -n "$set_args" ] || _ig_die "at least one --set is required" 2

  # Single-sprint mode: apply edits directly (no gate).
  if ! _ig_is_concurrent_mode; then
    local sa field value
    while IFS= read -r sa; do
      [ -n "$sa" ] || continue
      field="${sa%%=*}"
      value="${sa#*=}"
      case "$field" in
        depends_on|blocks|predicted_touch_set) ;;
        *) _ig_die "unsupported field for edit: $field" 2 ;;
      esac
      _ig_apply_field_edit "$story_file" "$field" "$value" || return 1
    done <<< "$set_args"
    return 0
  fi

  # Read the story's sprint_id.
  local sprint_id=""
  sprint_id="$(_ig_read_fm_field "$story_file" "sprint_id")" || true
  [ -n "$sprint_id" ] || _ig_die "story file has no sprint_id"

  # Create temp copy.
  local tmp_copy
  tmp_copy="$(mktemp "${TMPDIR:-/tmp}/ig-edit.XXXXXX")"
  _ig_add_tmp "$tmp_copy"
  cp "$story_file" "$tmp_copy"

  # Apply edits to temp copy and validate touch-set fields.
  local sa field value
  while IFS= read -r sa; do
    [ -n "$sa" ] || continue
    field="${sa%%=*}"
    value="${sa#*=}"
    case "$field" in
      depends_on|blocks|predicted_touch_set) ;;
      *) _ig_die "unsupported field for edit: $field" 2 ;;
    esac

    _ig_apply_field_edit "$tmp_copy" "$field" "$value" || {
      printf '%s: field edit failed for %s\n' "$SCRIPT_NAME" "$field" >&2
      return 1
    }

    # Run touch_set_prewrite_check for touch-set values.
    if [ "$field" = "predicted_touch_set" ]; then
      local vals_file
      vals_file="$(mktemp "${TMPDIR:-/tmp}/ig-vals.XXXXXX")"
      _ig_add_tmp "$vals_file"
      printf '%s\n' "$value" | tr ',' '\n' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        /usr/bin/grep -v '^$' > "$vals_file" || true
      if ! touch_set_prewrite_check "$tmp_copy" "$vals_file" "$_IG_PROJECT_ROOT"; then
        printf '%s: touch-set prewrite check failed\n' "$SCRIPT_NAME" >&2
        return 1
      fi
    fi
  done <<< "$set_args"

  # Run independence check with temp copy as overlay.
  local ic_script="${_IG_SCRIPT_DIR}/independence-check.sh"
  [ -x "$ic_script" ] || _ig_die "independence-check.sh not found"

  local check_rc=0
  bash "$ic_script" --candidate "$sprint_id" --overlay "$tmp_copy" 2>&1 || check_rc=$?

  if [ "$check_rc" -ne 0 ]; then
    printf '%s: independence check failed — edit rolled back\n' "$SCRIPT_NAME" >&2
    return 1
  fi

  # Move temp copy into place (atomic on same filesystem).
  mv -f "$tmp_copy" "$story_file"
  return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
  [ $# -gt 0 ] || _ig_usage

  case "$1" in
    edit)    _ig_edit_mode "$@" ;;
    -h|--help) _ig_usage ;;
    *)       _ig_default_mode "$@" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0##*/}" ]; then
  main "$@"
fi
