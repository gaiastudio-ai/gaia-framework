#!/usr/bin/env bash
# mutation-isolation.sh — throwaway-copy creation and worktree integrity
# verification for the stack-neutral mutation runner.
#
# Provides:
#   mutation_create_copy    Create a throwaway copy of a worktree for mutation
#   mutation_verify_manifest  Compute/compare sha256 manifests of tracked files
#   mutation_register_cleanup  Register trap to remove all copies on exit
#   mutation_cleanup        Remove all registered throwaway copies
#
# Safety contract:
#   - Copies are created under ${TMPDIR:-/tmp} with a gaia-mutation- prefix
#   - realpath containment: refuses if the copy root resolves inside the worktree
#   - .git is excluded from copies (prevents access to real refs/index)
#   - Symlinks are dereferenced (cp -rL) so mutations stay inside the copy
#   - Trap on EXIT/INT/TERM removes every copy; no leftovers on crash
#
# POSIX discipline: bash 3.2, no associative arrays, no mapfile, no local -A.

set -euo pipefail
LC_ALL=C; export LC_ALL

_MI_SCRIPT_NAME="mutation-isolation.sh"
_MI_COPIES=()        # paths registered for cleanup
_MI_TRAP_SET=0       # whether we installed our trap

_mi_err() { printf '%s: %s\n' "$_MI_SCRIPT_NAME" "$*" >&2; }

# ---------- sha256 helper ----------
# Uses sha256sum (Linux) or shasum -a 256 (macOS) — whichever is available.
_mi_sha256_cmd=""
_mi_resolve_sha256() {
  if [ -n "$_mi_sha256_cmd" ]; then return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then
    _mi_sha256_cmd="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    _mi_sha256_cmd="shasum -a 256"
  else
    _mi_err "error: neither sha256sum nor shasum found"
    return 1
  fi
}

# ---------- Manifest computation ----------
# Computes a deterministic sha256 manifest of every tracked and untracked-
# not-ignored file in a directory.  When inside a git work tree, uses
# git ls-files -co --exclude-standard; otherwise uses find (excluding .git).
#
# Output: sorted lines of "sha256  relative-path" on stdout.
# Usage:  mutation_verify_manifest <directory> [<output-file>]
#         When <output-file> is given, writes to it instead of stdout.
mutation_compute_manifest() {
  local dir="$1"
  local outfile="${2:-}"

  _mi_resolve_sha256 || return 1

  local file_list
  file_list=$(mktemp "${TMPDIR:-/tmp}/gaia-mi-files-XXXXXX")

  if (cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    # git work tree: tracked + untracked-not-ignored
    (cd "$dir" && git ls-files -co --exclude-standard) | LC_ALL=C sort > "$file_list"
  else
    # Not a git work tree: find everything except .git
    (cd "$dir" && find . -not -path './.git' -not -path './.git/*' -type f | sed 's|^\./||') | LC_ALL=C sort > "$file_list"
  fi

  local manifest
  manifest=$(mktemp "${TMPDIR:-/tmp}/gaia-mi-manifest-XXXXXX")

  # Hash each file; skip files that disappeared between listing and hashing
  while IFS= read -r f; do
    if [ -f "$dir/$f" ]; then
      $_mi_sha256_cmd "$dir/$f" 2>/dev/null | sed "s|$dir/||" >> "$manifest"
    fi
  done < "$file_list"

  rm -f "$file_list"

  if [ -n "$outfile" ]; then
    mv "$manifest" "$outfile"
  else
    cat "$manifest"
    rm -f "$manifest"
  fi
}

# mutation_verify_manifest <directory> <before-manifest>
# Computes a fresh manifest and compares it to <before-manifest>.
# Returns 0 if identical, 1 if different (prints diff to stderr).
mutation_verify_manifest() {
  local dir="$1"
  local before="$2"

  local after
  after=$(mktemp "${TMPDIR:-/tmp}/gaia-mi-after-XXXXXX")
  mutation_compute_manifest "$dir" "$after"

  if ! diff -q "$before" "$after" >/dev/null 2>&1; then
    _mi_err "error: worktree_mutated — files changed during the mutation run"
    diff "$before" "$after" >&2 || true
    rm -f "$after"
    return 1
  fi
  rm -f "$after"
  return 0
}

# ---------- Containment check ----------
# Refuses to create a copy if the temp root resolves (after realpath) inside
# the worktree, or if the temp root is a symlink pointing into the worktree.
_mi_containment_check() {
  local worktree_real="$1"
  local tmp_root="$2"

  local tmp_real
  tmp_real=$(cd "$tmp_root" 2>/dev/null && pwd -P) || tmp_real="$tmp_root"

  # Check if tmp_root is inside the worktree
  case "$tmp_real" in
    "$worktree_real"|"$worktree_real"/*)
      _mi_err "error: containment violation — temp root '$tmp_root' resolves inside the worktree '$worktree_real'"
      return 1
      ;;
  esac
  return 0
}

# ---------- Copy creation ----------
# mutation_create_copy <worktree-dir>
# Creates a throwaway copy of the worktree under ${TMPDIR:-/tmp}/gaia-mutation-XXXXXX.
# Excludes .git, dereferences symlinks (cp -rL).
# Prints the copy path on stdout.
mutation_create_copy() {
  local worktree="$1"

  local worktree_real
  worktree_real=$(cd "$worktree" && pwd -P)

  local tmp_root="${TMPDIR:-/tmp}"

  # Containment check
  _mi_containment_check "$worktree_real" "$tmp_root" || return 1

  local copy_dir
  copy_dir=$(mktemp -d "${tmp_root}/gaia-mutation-XXXXXX")

  # Verify the created dir does not resolve inside the worktree
  local copy_real
  copy_real=$(cd "$copy_dir" && pwd -P)
  case "$copy_real" in
    "$worktree_real"|"$worktree_real"/*)
      _mi_err "error: containment violation — created copy '$copy_real' is inside the worktree"
      rmdir "$copy_dir" 2>/dev/null || true
      return 1
      ;;
  esac

  # Copy contents, dereferencing symlinks so mutations stay inside the copy.
  # cp -rL dereferences symlinks; .git is removed afterwards.
  cp -rL "$worktree"/. "$copy_dir/"

  # Remove .git so test commands cannot reach the real repository
  rm -rf "$copy_dir/.git"

  # Register for cleanup
  _MI_COPIES+=("$copy_dir")

  printf '%s\n' "$copy_dir"
}

# ---------- Cleanup ----------
# mutation_cleanup — remove all registered throwaway copies.
mutation_cleanup() {
  local copy
  for copy in "${_MI_COPIES[@]+"${_MI_COPIES[@]}"}"; do
    if [ -d "$copy" ]; then
      rm -rf "$copy"
    fi
  done
  _MI_COPIES=()
}

# mutation_register_cleanup — install traps on EXIT, INT and TERM.
# EXIT runs cleanup on normal exit. INT and TERM exit with the conventional
# signal-exit codes (128 + signal number) so callers see a non-zero status.
mutation_register_cleanup() {
  if [ "$_MI_TRAP_SET" -eq 0 ]; then
    trap 'mutation_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _MI_TRAP_SET=1
  fi
}
