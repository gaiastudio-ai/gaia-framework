#!/usr/bin/env bash
# drift-detect.sh — runtime touch-set drift detection
#
# Computes actual file modifications from git diff against the
# promotion-chain base branch (or origin/HEAD fallback), maps
# repo-relative paths to PROJECT_ROOT-relative entries, and compares
# against the story's predicted_touch_set.
#
# Called after each TDD phase and before commit/push in /gaia-dev-story.
#
# Exit codes:
#   0  no drift (or single-sprint mode — no detection runs)
#   1  drift detected (drifted paths on stdout, diagnostic on stderr)
#   2  fail-closed (non-git workspace in concurrent mode, or
#      unresolvable drift base)
#   3  usage error
#
# Bash 3.2 compatible. No local -A, mapfile, readarray.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="drift-detect.sh"
_DD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source touch-set sanitizer (denylist check for reading predicted values).
_DD_SANITIZER="${_DD_SCRIPT_DIR}/lib/touch-set-sanitizer.sh"
if [ -f "$_DD_SANITIZER" ]; then
  # shellcheck source=lib/touch-set-sanitizer.sh
  . "$_DD_SANITIZER"
fi

# Path constants.
_DD_GAIA_DIR=".gaia"
_DD_CONFIG_REL="${_DD_GAIA_DIR}/config/project-config.yaml"
_DD_STATE_REL="${_DD_GAIA_DIR}/state"

# Project root.
_DD_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"

# Temp files.
_DD_TMPS=""
_dd_cleanup() {
  local f
  for f in $_DD_TMPS; do rm -f "$f" 2>/dev/null || true; done
}
trap '_dd_cleanup' EXIT INT TERM
_dd_add_tmp() { _DD_TMPS="${_DD_TMPS} $1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_dd_die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit "${2:-3}"
}

# ---------------------------------------------------------------------------
# _dd_is_concurrent_mode
# ---------------------------------------------------------------------------
_dd_is_concurrent_mode() {
  local config_f="${_DD_PROJECT_ROOT%/}/${_DD_CONFIG_REL}"
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
  local state_dir="${_DD_PROJECT_ROOT%/}/${_DD_STATE_REL}"
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.lock|*.result) continue ;; esac
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# _dd_chain_key_value <config_file> <key>
#   Read the first value of <key>: under ci_cd.promotion_chain.
#   The key is anchored as a YAML mapping key (after an optional list-item
#   dash and whitespace), so "source_branch:" does not match "branch" and
#   "target_branch:" does not match "branch" or "target".
#   Prints the value on stdout (empty if not found).
# ---------------------------------------------------------------------------
_dd_chain_key_value() {
  local config_f="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_ci=0; in_pc=0
            pat_item = "^[[:space:]]*-[[:space:]]*" k ":"
            pat_cont = "^[[:space:]]+" k ":" }
    /^ci_cd:/ { in_ci=1; next }
    in_ci && /^[^[:space:]]/ { in_ci=0 }
    in_ci && /promotion_chain:/ { in_pc=1; next }
    in_pc && /^[^[:space:]]/ { in_pc=0 }
    in_pc && ($0 ~ pat_item || $0 ~ pat_cont) {
      v=$0; sub(".*" k ":[[:space:]]*", "", v)
      gsub(/["'"'"'[:space:]]/, "", v)
      if (v != "") { print v; exit }
    }
  ' "$config_f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _dd_verify_ref <name>
#   Try origin/<name>, then <name> as a git ref.  Prints the resolved
#   ref spec on stdout and returns 0, or returns 1 if neither resolves.
# ---------------------------------------------------------------------------
_dd_verify_ref() {
  local name="$1"
  if git rev-parse --verify "origin/${name}" >/dev/null 2>&1; then
    printf '%s' "origin/${name}"
    return 0
  fi
  if git rev-parse --verify "$name" >/dev/null 2>&1; then
    printf '%s' "$name"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _dd_resolve_base_branch
#   Priority: promotion_chain branch > promotion_chain target (deprecated)
#             > origin/HEAD > fail-closed.
#   When branch is set but unresolvable, target is NOT consulted.
# ---------------------------------------------------------------------------
_dd_resolve_base_branch() {
  local config_f="${_DD_PROJECT_ROOT%/}/${_DD_CONFIG_REL}"
  local resolved=""

  if [ -f "$config_f" ]; then
    # Canonical key: promotion_chain branch.
    local branch_val=""
    branch_val="$(_dd_chain_key_value "$config_f" "branch")" || true
    if [ -n "$branch_val" ]; then
      resolved="$(_dd_verify_ref "$branch_val")" || true
      if [ -n "$resolved" ]; then
        printf '%s' "$resolved"
        return 0
      fi
      # branch is set but unresolvable — skip target, fall through.
    else
      # Legacy fallback: promotion_chain target (deprecated).
      local target_val=""
      target_val="$(_dd_chain_key_value "$config_f" "target")" || true
      if [ -n "$target_val" ]; then
        printf '%s: DEPRECATION: promotion_chain "target:" is deprecated; use "branch:" instead\n' \
          "$SCRIPT_NAME" >&2
        resolved="$(_dd_verify_ref "$target_val")" || true
        if [ -n "$resolved" ]; then
          printf '%s' "$resolved"
          return 0
        fi
      fi
    fi
  fi

  # Fallback: origin/HEAD.
  if git rev-parse --verify "origin/HEAD" >/dev/null 2>&1; then
    printf '%s' "origin/HEAD"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# _dd_read_touch_set <story_file>
#   Read predicted_touch_set entries, one per line.
# ---------------------------------------------------------------------------
_dd_read_touch_set() {
  local story_file="$1"
  awk '
    BEGIN { in_fm=0; started=0; in_f=0 }
    /^---[[:space:]]*$/ {
      if (!started) { started=1; in_fm=1; next }
      else exit
    }
    !in_fm { next }
    /^predicted_touch_set:[[:space:]]*/ {
      line = $0
      sub(/^predicted_touch_set:[[:space:]]*/, "", line)
      if (match(line, /^\[/)) {
        sub(/^\[/, "", line); sub(/\][[:space:]]*$/, "", line)
        n = split(line, items, /[[:space:]]*,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
          v = items[i]
          gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
          if (v != "") print v
        }
      }
      in_f = 1; next
    }
    in_f && /^[[:space:]]*-[[:space:]]/ {
      v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      gsub(/^["'"'"'[:space:]]+|["'"'"'[:space:]]+$/, "", v)
      if (v != "") print v
      next
    }
    in_f && /^[^[:space:]-]/ { in_f=0 }
    in_f && /^[[:space:]]/ && !/^[[:space:]]*-/ { in_f=0 }
  ' "$story_file"
}

# ---------------------------------------------------------------------------
# _dd_path_covered <path> <touch_set_file>
#   Returns 0 if path is covered by any entry in the touch set.
# ---------------------------------------------------------------------------
_dd_path_covered() {
  local path="$1" ts_file="$2"
  local entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    # Exact match.
    [ "$path" = "$entry" ] && return 0
    # Directory prefix match (entry ends in /).
    case "$entry" in
      */) case "$path" in "${entry}"*) return 0 ;; esac ;;
    esac
    # Glob match.
    # shellcheck disable=SC2254
    case "$path" in $entry) return 0 ;; esac
  done < "$ts_file"
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local story_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story) story_file="${2:-}"; shift 2 ;;
      -h|--help) printf 'Usage: drift-detect.sh --story <file>\n'; exit 0 ;;
      *) _dd_die "unknown option: $1" 3 ;;
    esac
  done

  [ -n "$story_file" ] || _dd_die "--story is required" 3
  [ -f "$story_file" ] || _dd_die "story file not found: $story_file" 3

  # Single-sprint mode: no drift detection.
  if ! _dd_is_concurrent_mode; then
    return 0
  fi

  # Non-git workspace check (concurrent mode only).
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s: drift check unavailable (non-git workspace)\n' \
      "$SCRIPT_NAME" >&2
    exit 2
  fi

  # Resolve base branch.
  local base_branch
  base_branch="$(_dd_resolve_base_branch)" || {
    printf '%s: drift base unresolvable — halting fail-closed\n' \
      "$SCRIPT_NAME" >&2
    exit 2
  }

  # Read predicted touch-set.
  local ts_file
  ts_file="$(mktemp "${TMPDIR:-/tmp}/dd-ts.XXXXXX")"
  _dd_add_tmp "$ts_file"
  _dd_read_touch_set "$story_file" > "$ts_file"

  # Validate through sanitizer denylist.
  if type -t touch_set_denylist_check >/dev/null 2>&1; then
    local entry
    while IFS= read -r entry || [ -n "$entry" ]; do
      [ -n "$entry" ] || continue
      if ! touch_set_denylist_check "$entry" 2>/dev/null; then
        printf '%s: predicted_touch_set contains denied characters — fail-closed\n' \
          "$SCRIPT_NAME" >&2
        exit 2
      fi
    done < "$ts_file"
  fi

  # Determine checkout directory name for path mapping.
  # In a linked worktree the git toplevel is the worktree directory (e.g.
  # the story key), not the main checkout.  Resolve the main checkout via
  # --git-common-dir so path prefixes match predicted_touch_set entries.
  local git_toplevel checkout_dir
  git_toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf '%s: cannot determine git top-level\n' "$SCRIPT_NAME" >&2
    exit 2
  }
  local _dd_common_dir
  _dd_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || _dd_common_dir=""
  if [ -n "$_dd_common_dir" ]; then
    # Resolve relative paths (main worktree returns ".git").
    case "$_dd_common_dir" in
      /*) ;;
      *)  _dd_common_dir="${git_toplevel}/${_dd_common_dir}" ;;
    esac
    # Normalize in a subshell; strip the .git dir to get the main root.
    _dd_common_dir="$( (cd "$_dd_common_dir" && pwd -P) 2>/dev/null )" || _dd_common_dir=""
  fi
  if [ -n "$_dd_common_dir" ]; then
    checkout_dir="$(dirname "$_dd_common_dir")"
    checkout_dir="${checkout_dir##*/}"
  else
    checkout_dir="${git_toplevel##*/}"
  fi

  # Compute merge-base.
  local merge_base
  merge_base="$(git merge-base HEAD "$base_branch" 2>/dev/null)" || {
    printf '%s: cannot compute merge-base against %s\n' \
      "$SCRIPT_NAME" "$base_branch" >&2
    exit 2
  }

  # Compute actual touches: committed + staged + unstaged + untracked.
  local actual_file
  actual_file="$(mktemp "${TMPDIR:-/tmp}/dd-actual.XXXXXX")"
  _dd_add_tmp "$actual_file"
  {
    git diff --name-only "$merge_base" 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sort -u > "$actual_file"

  # Map repo-relative paths to PROJECT_ROOT-relative and compare.
  local drifted_paths="" drifted_count=0
  while IFS= read -r repo_path; do
    [ -n "$repo_path" ] || continue
    local project_path="${checkout_dir}/${repo_path}"
    if ! _dd_path_covered "$project_path" "$ts_file"; then
      drifted_paths="${drifted_paths}${drifted_paths:+, }${project_path}"
      drifted_count=$((drifted_count + 1))
    fi
  done < "$actual_file"

  if [ "$drifted_count" -gt 0 ]; then
    printf '%s\n' "$drifted_paths"
    printf '%s: touch-set drift: files outside predicted_touch_set modified: %s\n' \
      "$SCRIPT_NAME" "$drifted_paths" >&2
    exit 1
  fi

  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0##*/}" ]; then
  main "$@"
fi
