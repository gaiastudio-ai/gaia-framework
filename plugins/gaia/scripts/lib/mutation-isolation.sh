#!/usr/bin/env bash
# mutation-isolation.sh — throwaway-copy creation and worktree integrity
# verification for the stack-neutral mutation runner.
#
# Provides:
#   mutation_short_hash     First 8 hex digits of a string's sha256
#   mutation_init_run_root  Create the one directory every copy of a run lives in
#   mutation_create_copy    Create a throwaway copy of a worktree for mutation
#   mutation_compute_manifest  Write a sha256 manifest of a directory
#   mutation_verify_manifest  Compare a fresh manifest with an earlier one
#   mutation_register_cleanup  Register trap to remove all copies on exit
#   mutation_terminate_children  Stop every descendant process of this shell
#   mutation_cleanup        Remove all registered throwaway copies
#
# Safety contract:
#   - Copies are created under ${TMPDIR:-/tmp} with a gaia-mutation- prefix
#   - realpath containment: refuses if the copy root resolves inside the worktree
#   - .git is excluded from copies (prevents access to real refs/index)
#   - Symlinks are dereferenced (cp -rL) so mutations stay inside the copy
#   - Trap on EXIT/INT/TERM stops the workers, then removes every copy; copies
#     made by background workers sit under the run root so the parent can
#     remove them without having to know their names
#
# POSIX discipline: bash 3.2, no associative arrays, no mapfile, no local -A. # lint-pack:allow bash4-constructs — comment documents discipline, not actual usage

set -euo pipefail
LC_ALL=C; export LC_ALL

_MI_SCRIPT_NAME="mutation-isolation.sh"
_MI_COPIES=()        # paths registered for cleanup
_MI_TRAP_SET=0       # whether we installed our trap
_MI_RUN_ROOT=""      # when set, copies and scratch files are created under it
_MI_SIGNALLED=0      # a signal handler is already running
_MI_MANIFEST_EXCLUDES="" # newline-separated paths, relative to the manifest dir

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

# mutation_short_hash <text> — first 8 hex digits of the text's sha256.
mutation_short_hash() {
  _mi_resolve_sha256 || return 1
  # shellcheck disable=SC2086 # the command is deliberately word-split
  printf '%s' "$1" | $_mi_sha256_cmd | cut -c1-8
}

# ---------- Manifest computation ----------
# Computes a deterministic sha256 manifest of every tracked and untracked-
# not-ignored file in a directory.  When inside a git work tree, uses
# git ls-files -co --exclude-standard; otherwise uses find (excluding .git).
# A path in _MI_MANIFEST_EXCLUDES (or anything below it) is left out, which is
# how a run keeps its own evidence and patches out of the comparison.
#
# Output: sorted lines of "sha256  ./relative-path" on stdout.
# Usage:  mutation_compute_manifest <directory> [<output-file>]
#         When <output-file> is given, writes to it instead of stdout.
_mi_is_excluded() {
  local rel="$1" excl
  [ -n "$_MI_MANIFEST_EXCLUDES" ] || return 1
  while IFS= read -r excl; do
    [ -n "$excl" ] || continue
    case "$rel" in
      "$excl"|"$excl"/*) return 0 ;;
    esac
  done <<< "$_MI_MANIFEST_EXCLUDES"
  return 1
}

_mi_scratch() {
  mktemp "${_MI_RUN_ROOT:-${TMPDIR:-/tmp}}/gaia-mi-$1-XXXXXX"
}

mutation_compute_manifest() {
  local dir="$1"
  local outfile="${2:-}"

  _mi_resolve_sha256 || return 1

  local names hashable manifest f
  names=$(_mi_scratch names)
  hashable=$(_mi_scratch hashable)
  manifest=$(_mi_scratch manifest)

  # NUL-separated listings: with LC_ALL=C a plain ls-files would quote any path
  # holding a non-ASCII byte and that file would drop out of the comparison.
  if (cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    (cd "$dir" && git ls-files -co --exclude-standard -z) > "$names"
  else
    (cd "$dir" && find . -not -path './.git' -not -path './.git/*' -type f -print0) > "$names"
  fi

  while IFS= read -r -d '' f; do
    f="${f#./}"
    _mi_is_excluded "$f" && continue
    # Skip what disappeared since listing, and symlinks to directories.
    [ -f "$dir/$f" ] && printf './%s\0' "$f"
  done < "$names" > "$hashable"

  if [ -s "$hashable" ]; then
    # shellcheck disable=SC2086 # the command is deliberately word-split
    (cd "$dir" && xargs -0 $_mi_sha256_cmd < "$hashable") | LC_ALL=C sort > "$manifest"
  fi

  rm -f "$names" "$hashable"

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
  after=$(_mi_scratch after)
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

# ---------- Run root ----------
# mutation_init_run_root <worktree-dir>
# Creates the directory that holds everything a run makes. Background workers
# cannot report copies back to the parent, so cleanup relies on all of them
# sitting under this one registered path.
mutation_init_run_root() {
  local worktree="$1" worktree_real tmp_root root root_real
  worktree_real=$(cd "$worktree" && pwd -P)
  tmp_root="${TMPDIR:-/tmp}"
  _mi_containment_check "$worktree_real" "$tmp_root" || return 1
  root=$(mktemp -d "${tmp_root%/}/gaia-mutation-XXXXXX")
  root_real=$(cd "$root" && pwd -P)
  _MI_COPIES+=("$root_real")
  _MI_RUN_ROOT="$root_real"
}

# ---------- Copy creation ----------
# mutation_create_copy <worktree-dir>
# Creates a throwaway copy of the worktree in a fresh gaia-mutation-XXXXXX
# directory, under the run root when there is one. Excludes .git, dereferences
# symlinks (cp -rL). Prints the copy path on stdout.
mutation_create_copy() {
  local worktree="$1"

  local worktree_real
  worktree_real=$(cd "$worktree" && pwd -P)

  local tmp_root="${_MI_RUN_ROOT:-${TMPDIR:-/tmp}}"

  # Containment check
  _mi_containment_check "$worktree_real" "$tmp_root" || return 1

  local copy_dir
  copy_dir=$(mktemp -d "${tmp_root%/}/gaia-mutation-XXXXXX")

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
  # .git never enters the copy: a linked worktree's .git file points at the real
  # repository, and a test run could otherwise move real refs or the index.
  # A dangling symlink makes cp complain; that entry is simply absent, and a
  # test that needed it shows up as a red baseline.
  local entry
  for entry in "$worktree"/* "$worktree"/.[!.]* "$worktree"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$(basename "$entry")" in
      .git) continue ;;
    esac
    cp -rL "$entry" "$copy_dir/" 2>/dev/null || true
  done
  # Nested repositories and submodules carry their own .git entries.
  find "$copy_dir" -name .git -prune -exec rm -rf {} + 2>/dev/null || true

  # Register for cleanup
  _MI_COPIES+=("$copy_dir")

  printf '%s\n' "$copy_dir"
}

# ---------- Cleanup ----------
# mutation_terminate_children — stop every descendant of this shell: workers,
# the tests they run, and the watchdogs of those tests. Walks the process table
# because a test run sits in its own process group and a worker blocked on a
# foreground command would not act on a signal until that command returns.
mutation_terminate_children() {
  local table pids pid
  table=$(ps -A -o pid=,ppid= 2>/dev/null) || return 0
  pids=$(printf '%s\n' "$table" | awk -v root="$$" '
    { parent[NR] = $2; child[NR] = $1 }
    END {
      seen[root] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++) {
          if ((parent[i] in seen) && !(child[i] in seen)) {
            seen[child[i]] = 1
            print child[i]
            grew = 1
          }
        }
      } while (grew)
    }')
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.2 2>/dev/null || sleep 1
  for pid in $pids; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

# mutation_cleanup — remove all registered throwaway copies.
mutation_cleanup() {
  local copy
  for copy in "${_MI_COPIES[@]+"${_MI_COPIES[@]}"}"; do
    if [ -d "$copy" ]; then
      rm -rf "$copy" 2>/dev/null || { sleep 1; rm -rf "$copy" 2>/dev/null || true; }
    fi
  done
  _MI_COPIES=()
}

_mi_on_signal() {
  [ "$_MI_SIGNALLED" -eq 0 ] || return 0
  _MI_SIGNALLED=1
  mutation_terminate_children
  exit "$1"
}

# mutation_register_cleanup — install traps on EXIT, INT and TERM.
# EXIT runs cleanup on normal exit. INT and TERM stop the workers first, then
# exit with the conventional signal codes (128 + signal number).
mutation_register_cleanup() {
  if [ "$_MI_TRAP_SET" -eq 0 ]; then
    trap 'mutation_cleanup' EXIT
    trap '_mi_on_signal 130' INT
    trap '_mi_on_signal 143' TERM
    _MI_TRAP_SET=1
  fi
}
