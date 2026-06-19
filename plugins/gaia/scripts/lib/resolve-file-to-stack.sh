#!/usr/bin/env bash
# lib/resolve-file-to-stack.sh — shared file-path-to-owning-stack resolution.
#
# Source-only library (main-guard prevents execution when sourced).
# Exposes two public functions:
#
#   resolve_file_to_stack <file_path> <stacks_table_file>
#     Resolves a file path to its owning stack name using:
#       1. Longest-prefix-wins matching (prefix-type rows)
#       2. Glob-fallback matching (glob-type rows, with single-level depth guard)
#       3. Root-dot catch-all ("." candidate, lowest priority)
#     Returns the matched stack name on stdout, or empty string on no match.
#
#   locate_repo_script <script_basename>
#     Locates a script by basename under the repository scripts/ directory.
#     Discovery order:
#       1. Sibling scripts/ directory relative to this lib/ directory.
#       2. Walk up from CLAUDE_PLUGIN_ROOT (when set) to find scripts/<basename>.
#       3. Walk up from CWD to find scripts/<basename>.
#     Returns the absolute path on stdout, or empty string if not found.
#
# Stacks table format (TSV, one row per candidate):
#   name<TAB>candidate<TAB>match_type
#
#   match_type values:
#     prefix  — longest-prefix matching (/** glob or scalar path field or ".")
#     glob    — bash glob matching (non-/** patterns like config/*.yaml)
#
# Glob depth semantics — uniform across all consumers:
#   Non-** globs (e.g. config/*.yaml) match a SINGLE directory level only.
#   The wildcard * does NOT span /. So config/*.yaml matches config/foo.yaml
#   but NOT config/sub/deep.yaml. Use ** (e.g. config/**/*.yaml) to match
#   across arbitrary depth.
#
#   This depth guard applies uniformly to every consumer of this library.
#   Before reconcile-cross-stack.sh was migrated to use this shared lib, its
#   inline _glob_matches function used a bare bash case-glob where * spans /.
#   The migration intentionally tightened reconcile to the same single-level
#   semantics that detect-affected.sh already enforced. The tighter behavior
#   is more correct (POSIX-style depth semantics for *, not bash case-glob
#   semantics) and is regression-pinned in reconcile-cross-stack.bats.
#
# This library is consumed by detect-affected.sh and reconcile-cross-stack.sh
# to eliminate duplicated resolution logic. Each consumer maintains its own
# config-parsing (awk / yq) and builds the TSV stacks table; this library
# owns only the resolution algorithm.

set -euo pipefail

# ---------------------------------------------------------------------------
# resolve_file_to_stack — resolve a file path to its owning stack name
#
# Args:
#   $1 — file path to resolve (no leading gaia-public/ — consumers strip it)
#   $2 — path to stacks table file (TSV: name<TAB>candidate<TAB>match_type)
#
# Output: the matched stack name on stdout, or empty string.
#
# Resolution order:
#   1. Longest-prefix-wins across all prefix-type rows (excluding "." catch-all)
#   2. First glob match across all glob-type rows (declaration-order tiebreak)
#   3. Root-dot catch-all ("." prefix) if found and nothing more specific matched
# ---------------------------------------------------------------------------
resolve_file_to_stack() {
  local path="$1"
  local stacks_table="$2"
  local matched=""

  # Pass 1: longest-prefix match (prefix-type rows, excluding "." catch-all)
  matched="$(_fts_find_best_prefix_match "$path" "$stacks_table")"
  if [[ -n "$matched" ]]; then
    printf '%s' "$matched"
    return 0
  fi

  # Pass 2: glob fallback (glob-type rows)
  matched="$(_fts_find_glob_match "$path" "$stacks_table")"
  if [[ -n "$matched" ]]; then
    printf '%s' "$matched"
    return 0
  fi

  # Pass 3: root-dot catch-all ("." prefix)
  matched="$(_fts_find_catchall_match "$stacks_table")"
  if [[ -n "$matched" ]]; then
    printf '%s' "$matched"
    return 0
  fi

  # No match at all
  printf ''
}

# ---------------------------------------------------------------------------
# locate_repo_script — find a script by basename under the repo scripts/ tree
#
# Args:
#   $1 — script basename (e.g. "classify-commits.js")
#
# Output: absolute path on stdout, or empty string if not found.
# ---------------------------------------------------------------------------
locate_repo_script() {
  local basename="$1"
  local _fts_lib_dir

  # Strategy 1: sibling scripts/ directory (lib/ -> scripts/)
  _fts_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local sibling_scripts="${_fts_lib_dir}/../"
  if [[ -f "${sibling_scripts}${basename}" ]]; then
    printf '%s' "$(cd "$sibling_scripts" && pwd)/${basename}"
    return 0
  fi

  # Strategy 2: walk up from CLAUDE_PLUGIN_ROOT
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    local search_dir="$CLAUDE_PLUGIN_ROOT"
    while [[ "$search_dir" != "/" ]]; do
      if [[ -f "${search_dir}/scripts/${basename}" ]]; then
        printf '%s' "$(cd "${search_dir}/scripts" && pwd)/${basename}"
        return 0
      fi
      search_dir="$(dirname "$search_dir")"
    done
  fi

  # Strategy 3: walk up from CWD
  local search_dir
  search_dir="$(pwd)"
  while [[ "$search_dir" != "/" ]]; do
    if [[ -f "${search_dir}/scripts/${basename}" ]]; then
      printf '%s' "$(cd "${search_dir}/scripts" && pwd)/${basename}"
      return 0
    fi
    search_dir="$(dirname "$search_dir")"
  done

  # Not found
  printf ''
}

# ---------------------------------------------------------------------------
# Internal helpers (underscore prefix — exempt from the public-function-coverage gate)
# ---------------------------------------------------------------------------

# _fts_find_best_prefix_match — longest-prefix match across prefix-type rows
#
# Skips the "." catch-all (handled separately in pass 3).
# Requires a path-segment boundary: path must be candidate/... or == candidate.
# Ties break by declaration order (first declared wins among equal-length).
_fts_find_best_prefix_match() {
  local path="$1"
  local stacks_table="$2"
  local best_name=""
  local best_len=0
  local name candidate match_type clen

  while IFS=$'\t' read -r name candidate match_type; do
    [[ "$match_type" == "prefix" ]] || continue
    # Skip the catch-all — it's handled in pass 3
    [[ "$candidate" == "." ]] && continue
    # Require a path-segment boundary: path must be candidate/... or == candidate
    if [[ "$path" == "${candidate}/"* ]] || [[ "$path" == "$candidate" ]]; then
      clen="${#candidate}"
      if (( clen > best_len )); then
        best_len=$clen
        best_name=$name
      fi
    fi
  done < "$stacks_table"

  printf '%s' "$best_name"
}

# _fts_find_glob_match — bash glob match across glob-type rows
#
# Single-level depth guard: when the glob does NOT contain **, a path deeper
# than one level below the glob prefix is rejected. This prevents config/*.yaml
# from matching config/sub/deep.yaml.
# Declaration order is the tiebreaker (first match wins).
_fts_find_glob_match() {
  local path="$1"
  local stacks_table="$2"
  local name candidate match_type

  while IFS=$'\t' read -r name candidate match_type; do
    [[ "$match_type" == "glob" ]] || continue
    # Single-level depth guard for non-** globs
    if [[ "$candidate" != *"**"* ]]; then
      local glob_prefix="${candidate%%\**}"
      local glob_remainder="${path#$glob_prefix}"
      # If the remainder (after the literal prefix) contains a slash, the path
      # goes deeper than a single * can legitimately reach.
      if [[ "$glob_remainder" == */* ]]; then
        continue
      fi
    fi
    # shellcheck disable=SC2053
    if [[ "$path" == $candidate ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < "$stacks_table"

  printf ''
}

# _fts_find_catchall_match — find the "." catch-all entry if present
_fts_find_catchall_match() {
  local stacks_table="$1"
  local name candidate match_type

  while IFS=$'\t' read -r name candidate match_type; do
    [[ "$match_type" == "prefix" ]] || continue
    if [[ "$candidate" == "." ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < "$stacks_table"

  printf ''
}

# ---------------------------------------------------------------------------
# Main-guard: source-only library — do not run when executed directly.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'resolve-file-to-stack.sh: this is a source-only library; source it, do not execute it.\n' >&2
  exit 1
fi
