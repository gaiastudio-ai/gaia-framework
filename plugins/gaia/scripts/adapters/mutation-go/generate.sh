#!/usr/bin/env bash
# generate.sh — Go mutation adapter: mutant generator.
#
# Runs go-mutesting on the listed non-test .go files inside the copy
# with capture-mutant.sh as the exec hook. Each mutant becomes a
# unified-diff patch file applicable with patch -p1. The capture hook
# returns exit 2 (skip) so go-mutesting runs no tests during generation.
#
# Usage:
#   generate.sh --source-dir <dir> --files-from <file> --out-dir <dir>
#
# Output:
#   One .patch file per mutant in --out-dir, plus index.json listing them.
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="generate.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

_gen_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_gen_die() { local rc="$1"; shift; _gen_err "$*"; exit "$rc"; }

# ---------- Tool check ----------
if ! command -v go-mutesting >/dev/null 2>&1; then
  _gen_die 1 "go-mutesting not found on PATH"
fi

# ---------- Arg parsing ----------
_gen_source_dir=""
_gen_files_from=""
_gen_out_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir) shift; _gen_source_dir="${1:-}"; shift ;;
    --files-from) shift; _gen_files_from="${1:-}"; shift ;;
    --out-dir)    shift; _gen_out_dir="${1:-}"; shift ;;
    --help|-h)    printf 'Usage: generate.sh --source-dir <dir> --files-from <list> --out-dir <dir>\n'; exit 0 ;;
    *)            _gen_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$_gen_source_dir" ] || _gen_die 1 "--source-dir is required"
[ -d "$_gen_source_dir" ] || _gen_die 1 "--source-dir is not a directory"
[ -n "$_gen_files_from" ] || _gen_die 1 "--files-from is required"
[ -f "$_gen_files_from" ] || _gen_die 1 "--files-from not found"
[ -n "$_gen_out_dir" ]    || _gen_die 1 "--out-dir is required"
mkdir -p "$_gen_out_dir"

# Resolve absolute paths before changing directory
_gen_source_dir=$(cd "$_gen_source_dir" && pwd -P)
_gen_files_from=$( case "$_gen_files_from" in /*) printf '%s' "$_gen_files_from" ;; *) printf '%s/%s' "$(pwd -P)" "$_gen_files_from" ;; esac )
_gen_out_dir=$( case "$_gen_out_dir" in /*) printf '%s' "$_gen_out_dir" ;; *) printf '%s/%s' "$(pwd -P)" "$_gen_out_dir" ;; esac )

# ---------- Prepare capture environment ----------
_gen_counter_file="$_gen_out_dir/.counter"
printf '0' > "$_gen_counter_file"

export GAIA_CAPTURE_OUTDIR="$_gen_out_dir"
export GAIA_CAPTURE_SRCDIR="$_gen_source_dir"
export GAIA_CAPTURE_COUNTER="$_gen_counter_file"

_gen_capture_hook="$SCRIPT_DIR/capture-mutant.sh"
[ -x "$_gen_capture_hook" ] || _gen_die 1 "capture-mutant.sh not found at $SCRIPT_DIR"

# ---------- Collect non-test Go files ----------
_gen_go_files=""
while IFS= read -r rel_path; do
  [ -n "$rel_path" ] || continue
  # Skip test files
  case "$rel_path" in
    *_test.go) continue ;;
  esac
  [ -f "$_gen_source_dir/$rel_path" ] || continue
  if [ -n "$_gen_go_files" ]; then
    _gen_go_files="$_gen_go_files $_gen_source_dir/$rel_path"
  else
    _gen_go_files="$_gen_source_dir/$rel_path"
  fi
done < "$_gen_files_from"

if [ -z "$_gen_go_files" ]; then
  printf '[]\n' > "$_gen_out_dir/index.json"
  _gen_err "generated 0 mutants (no non-test Go files)"
  exit 0
fi

# ---------- Run go-mutesting ----------
# Capture stdout for operator parsing. go-mutesting outputs one line per
# mutation in the form: SKIP "<path>:<line>: <operator>"
_gen_gm_output=$(mktemp "${TMPDIR:-/tmp}/gaia-gen-gm-XXXXXX")

# Run from inside the source dir so go-mutesting sees the module context
_gen_gm_rc=0
# shellcheck disable=SC2086
( cd "$_gen_source_dir" && go-mutesting --exec "$_gen_capture_hook" $_gen_go_files ) > "$_gen_gm_output" 2>&1 || _gen_gm_rc=$?

# go-mutesting exit 0 = success. Non-zero may be partial (some mutations
# still captured) or total failure. We proceed if any patches were created.

# ---------- Parse operators from go-mutesting output ----------
# Output lines: SKIP|PASS|FAIL "<abs-path>:<line>: <operator>"
# Build an ordered array of operators corresponding to capture order.
_gen_op_idx=0
_gen_op_file="$_gen_out_dir/.operators"
: > "$_gen_op_file"
while IFS= read -r gm_line; do
  case "$gm_line" in
    SKIP\ *|PASS\ *|FAIL\ *)
      _gen_op_idx=$((_gen_op_idx + 1))
      # Extract the operator from inside quotes after the last colon-space
      _gen_op_desc=$(printf '%s' "$gm_line" | sed -n 's/.*: \(.*\)"/\1/p')
      [ -n "$_gen_op_desc" ] || _gen_op_desc="go mutation"
      printf '%d=%s\n' "$_gen_op_idx" "$_gen_op_desc" >> "$_gen_op_file"
      ;;
  esac
done < "$_gen_gm_output"
rm -f "$_gen_gm_output"

# ---------- Build index.json ----------
_gen_mutant_count=$(cat "$_gen_counter_file" 2>/dev/null || echo 0)
_gen_index_entries=""

_gen_idx=0
while [ "$_gen_idx" -lt "$_gen_mutant_count" ]; do
  _gen_idx=$((_gen_idx + 1))

  _gen_patch_name="mutant-${_gen_idx}.patch"
  _gen_patch_file="$_gen_out_dir/$_gen_patch_name"
  [ -f "$_gen_patch_file" ] || continue

  # Read metadata from the .meta file
  _gen_meta_file="$_gen_out_dir/mutant-${_gen_idx}.meta"
  _gen_m_file=""
  _gen_m_line=0
  if [ -f "$_gen_meta_file" ]; then
    _gen_m_file=$(sed -n 's/^file=//p' "$_gen_meta_file")
    _gen_m_line=$(sed -n 's/^line=//p' "$_gen_meta_file")
  fi

  # Fall back to extracting from the patch
  if [ -z "$_gen_m_file" ]; then
    _gen_m_file=$(awk '/^--- a\// { sub(/^--- a\//, ""); sub(/\t.*$/, ""); print; exit }' "$_gen_patch_file")
  fi
  if [ -z "$_gen_m_line" ] || [ "$_gen_m_line" = "0" ]; then
    _gen_m_line=$(awk '/^@@ -/ { sub(/^@@ -/, ""); sub(/[^0-9].*$/, ""); print; exit }' "$_gen_patch_file")
  fi

  # Read operator from the parsed go-mutesting output
  _gen_m_op="go mutation"
  if [ -f "$_gen_op_file" ]; then
    _gen_m_op_match=$(sed -n "s/^${_gen_idx}=//p" "$_gen_op_file")
    [ -n "$_gen_m_op_match" ] && _gen_m_op="$_gen_m_op_match"
  fi

  if [ -n "$_gen_index_entries" ]; then
    _gen_index_entries="${_gen_index_entries},"
  fi
  _gen_index_entries="${_gen_index_entries}$(jq -n \
    --arg mid "mutant-${_gen_idx}" \
    --arg pf "$_gen_patch_name" \
    --arg f "${_gen_m_file:-}" \
    --argjson l "${_gen_m_line:-0}" \
    --arg op "$_gen_m_op" \
    '{"mutant_id":$mid,"patch_file":$pf,"file":$f,"line":$l,"operator":$op}')"
done

# ---------- Write index ----------
printf '[%s]' "$_gen_index_entries" | jq '.' > "$_gen_out_dir/index.json"

# Clean up temp files
rm -f "$_gen_counter_file" "$_gen_op_file"
find "$_gen_out_dir" -name '*.meta' -delete 2>/dev/null || true

_gen_err "generated $_gen_mutant_count mutants"
exit 0
