#!/usr/bin/env bash
# gaia-paths.sh — canonical-path-constants helper for the .gaia/ consolidation.
# Sourceable, NOT executable.
#
# Exports the six canonical GAIA path constants:
#   GAIA_CONFIG_DIR     = ${project_root}/.gaia/config
#   GAIA_ARTIFACTS_DIR  = ${project_root}/.gaia/artifacts
#   GAIA_STATE_DIR      = ${project_root}/.gaia/state
#   GAIA_MEMORY_DIR     = ${project_root}/.gaia/memory
#   GAIA_CUSTOM_DIR     = ${project_root}/.gaia/custom
#   GAIA_KNOWLEDGE_DIR  = ${project_root}/.gaia/knowledge
#
# Plus one derived constant + two backward-compat env-var aliases:
#   GAIA_CHECKPOINT_DIR = ${GAIA_MEMORY_DIR}/checkpoints
#   MEMORY_PATH         = ${GAIA_MEMORY_DIR}      (alias for scripts that default to ./_memory)
#   CHECKPOINT_PATH     = ${GAIA_CHECKPOINT_DIR}  (alias for scripts that default to ./_memory/checkpoints)
#
# Project root resolution:
#   1. ${CLAUDE_PROJECT_ROOT} if set
#   2. ${PWD} as fallback
#
# Env-var overrides (allowlist + shell-metachar rejection):
#   GAIA_CONFIG_PATH, GAIA_ARTIFACTS_PATH, GAIA_STATE_PATH,
#   GAIA_MEMORY_PATH, GAIA_CUSTOM_PATH, GAIA_KNOWLEDGE_PATH
#
#   Overrides MUST resolve under project root via realpath. Shell
#   metacharacters (`;` `&` `|` `` ` `` `$(`) cause non-zero exit with
#   `gaia-paths.sh: shell-metacharacter rejected in <var>`.
#
# Source guard:
#   _GAIA_PATHS_LOADED=1 after first source; subsequent sources are no-ops.
#   This is what lets multiple downstream scripts re-source the helper without
#   the override allowlist firing twice on the same env.
#

# Idempotent source guard. If already loaded, do not re-evaluate overrides.
if [ "${_GAIA_PATHS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ---------- Helpers ----------

_gaia_paths_die() {
  printf 'gaia-paths.sh: %s\n' "$1" >&2
  # Return non-zero from a sourced context; the caller's `source` returns the
  # value of the last command.
  return 1 2>/dev/null || exit 1
}

# _gaia_paths_check_metachars — reject overrides containing shell metacharacters
# (defense in depth even though all overrides are read into shell vars; the
# raw value gets logged and may end up in error messages).
_gaia_paths_check_metachars() {
  local var_name="$1"
  local val="$2"
  case "$val" in
    *';'*|*'&'*|*'|'*|*'`'*|*'$('*)
      _gaia_paths_die "shell-metacharacter rejected in ${var_name}"
      return $?
      ;;
  esac
  return 0
}

# _gaia_paths_canonicalize — produce a canonical absolute path.
#
# Portability: macOS BSD realpath does NOT support `-m` (resolve non-existent
# tails) and errors out on missing paths. GNU realpath does. We sidestep the
# divergence by always using the `cd ... && pwd -P` shell trick for the
# directory portion + literal basename concatenation. This works for both
# existing and non-existing leaf paths as long as the parent directory exists.
_gaia_paths_canonicalize() {
  local raw="$1"
  if [ -z "$raw" ]; then
    return 1
  fi
  if [ -d "$raw" ]; then
    ( cd "$raw" 2>/dev/null && pwd -P )
    return 0
  fi
  local d b
  d="$(dirname -- "$raw")"
  b="$(basename -- "$raw")"
  if [ -d "$d" ]; then
    printf '%s/%s\n' "$( cd "$d" && pwd -P )" "$b"
    return 0
  fi
  # Parent doesn't exist either — emit the raw path as last-resort.
  printf '%s\n' "$raw"
  return 0
}

# _gaia_paths_under_root — return 0 if $1 (canonical) is under $2 (canonical).
_gaia_paths_under_root() {
  local cand="$1"
  local root="$2"
  case "$cand" in
    "$root"|"$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _gaia_paths_resolve_override — apply override allowlist to one var.
# Args: override_var_name  default_path  project_root_canonical  out_var_name
# Sets $out_var_name in the caller's scope (or returns non-zero on rejection).
_gaia_paths_resolve_override() {
  local ov_name="$1"
  local default_path="$2"
  local root_canon="$3"
  local out_name="$4"
  local raw cand

  eval "raw=\${${ov_name}:-}"

  if [ -z "$raw" ]; then
    eval "${out_name}=\"\$default_path\""
    return 0
  fi

  _gaia_paths_check_metachars "$ov_name" "$raw" || return 1

  cand="$(_gaia_paths_canonicalize "$raw")"
  if [ -z "$cand" ]; then
    _gaia_paths_die "CRITICAL: could not canonicalize ${ov_name}=${raw}"
    return 1
  fi

  if ! _gaia_paths_under_root "$cand" "$root_canon"; then
    _gaia_paths_die "CRITICAL: ${ov_name} resolves to ${cand}, outside project root ${root_canon}"
    return 1
  fi

  eval "${out_name}=\"\$cand\""
  return 0
}

# ---------- Resolve project root ----------
#
# Precedence: CLAUDE_PROJECT_ROOT (explicit) wins. Otherwise, walk UP from $PWD
# to find the nearest ancestor containing a .gaia/ directory, so callers (skill
# preludes, deterministic scripts) resolve the project root regardless of the
# CWD they were invoked from. Without this walk-up the resolution fell straight
# to $PWD, so a script run from a subdirectory (or an unrelated CWD) silently
# failed to find .gaia/config — e.g. detect-orchestration-mode.sh returned Mode
# A even with orchestration.mode:team set. The bounded walk-up mirrors the
# pattern in scripts/resolve-config.sh and scripts/load-stack-persona.sh: it
# stops at / and $HOME, and is skipped when CLAUDE_SKILL_DIR or
# GAIA_NO_PROJECT_WALKUP is set (test-isolation escape hatches).

_gaia_paths_walk_up_root() {
  # Echo the nearest ancestor of $PWD (inclusive) that is the project root, or
  # nothing if none is found within the $HOME / root bound.
  #
  # Two-tier match (config-bearing preferred). A bare `.gaia/` directory is NOT
  # sufficient on its own: an in-tree sub-repo can carry its own `.gaia/` that
  # holds only runtime state or a tracked CI slice — NOT project-config.yaml —
  # and the old single-tier "first ancestor with any .gaia/" rule stopped there,
  # shadowing the real project root one level up. That silently down-shifted
  # callers to defaults (e.g. detect-orchestration-mode.sh returned Mode A even
  # with orchestration.mode:team set in the real project-root config).
  #
  # Pass 1 finds the nearest ancestor whose `.gaia/config/project-config.yaml`
  # actually exists — the authoritative project root. Pass 2 falls back to the
  # original "nearest ancestor with any .gaia/" rule, so a greenfield / partial
  # setup that has a `.gaia/` but not yet a config still resolves as before.
  local d

  # Pass 1: nearest ancestor with a real project-config.yaml under .gaia/config.
  d="$PWD"
  if [ -f "${d}/.gaia/config/project-config.yaml" ]; then printf '%s' "$d"; return 0; fi
  while [ "$d" != "/" ] && [ "$d" != "${HOME:-/nonexistent}" ]; do
    d="$(dirname "$d")"
    if [ -f "${d}/.gaia/config/project-config.yaml" ]; then printf '%s' "$d"; return 0; fi
  done

  # Pass 2 (fallback): nearest ancestor with any .gaia/ directory.
  d="$PWD"
  if [ -d "${d}/.gaia" ]; then printf '%s' "$d"; return 0; fi
  while [ "$d" != "/" ] && [ "$d" != "${HOME:-/nonexistent}" ]; do
    d="$(dirname "$d")"
    if [ -d "${d}/.gaia" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

if [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
  _GAIA_ROOT_RAW="$CLAUDE_PROJECT_ROOT"
elif [ -z "${CLAUDE_SKILL_DIR:-}" ] && [ -z "${GAIA_NO_PROJECT_WALKUP:-}" ] \
     && _GAIA_WALKED_ROOT="$(_gaia_paths_walk_up_root)" && [ -n "$_GAIA_WALKED_ROOT" ]; then
  _GAIA_ROOT_RAW="$_GAIA_WALKED_ROOT"
else
  _GAIA_ROOT_RAW="${PWD}"
fi
_GAIA_ROOT_CANON="$(_gaia_paths_canonicalize "$_GAIA_ROOT_RAW")"
if [ -z "$_GAIA_ROOT_CANON" ]; then
  _gaia_paths_die "CRITICAL: could not canonicalize project root: $_GAIA_ROOT_RAW"
  return 1 2>/dev/null || exit 1
fi

# ---------- Resolve each of the 6 canonical constants ----------

_gaia_paths_resolve_override \
  GAIA_CONFIG_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/config" \
  "$_GAIA_ROOT_CANON" \
  GAIA_CONFIG_DIR || return 1

_gaia_paths_resolve_override \
  GAIA_ARTIFACTS_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/artifacts" \
  "$_GAIA_ROOT_CANON" \
  GAIA_ARTIFACTS_DIR || return 1

_gaia_paths_resolve_override \
  GAIA_STATE_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/state" \
  "$_GAIA_ROOT_CANON" \
  GAIA_STATE_DIR || return 1

_gaia_paths_resolve_override \
  GAIA_MEMORY_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/memory" \
  "$_GAIA_ROOT_CANON" \
  GAIA_MEMORY_DIR || return 1

_gaia_paths_resolve_override \
  GAIA_CUSTOM_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/custom" \
  "$_GAIA_ROOT_CANON" \
  GAIA_CUSTOM_DIR || return 1

_gaia_paths_resolve_override \
  GAIA_KNOWLEDGE_PATH \
  "${_GAIA_ROOT_CANON}/.gaia/knowledge" \
  "$_GAIA_ROOT_CANON" \
  GAIA_KNOWLEDGE_DIR || return 1

# Derived checkpoint-dir constant + backward-compat env-var aliases.
# The checkpoint dir nests under the memory dir; downstream scripts that
# currently consume `${CHECKPOINT_PATH:-./_memory/checkpoints}` defaults pick
# up the canonical `.gaia/memory/checkpoints/` path automatically when this
# helper is sourced. The MEMORY_PATH alias does the same for scripts that
# default to `./_memory`.
GAIA_CHECKPOINT_DIR="${GAIA_MEMORY_DIR}/checkpoints"

# Export the env-var aliases — they are READ-ONLY mirrors for backward compat;
# the canonical writeable constants remain GAIA_*_DIR.
MEMORY_PATH="$GAIA_MEMORY_DIR"
CHECKPOINT_PATH="$GAIA_CHECKPOINT_DIR"

export GAIA_CONFIG_DIR GAIA_ARTIFACTS_DIR GAIA_STATE_DIR GAIA_MEMORY_DIR GAIA_CUSTOM_DIR GAIA_KNOWLEDGE_DIR
export GAIA_CHECKPOINT_DIR MEMORY_PATH CHECKPOINT_PATH

_GAIA_PATHS_LOADED=1
export _GAIA_PATHS_LOADED

return 0 2>/dev/null || true
