#!/usr/bin/env bash
# capture-mutant.sh — go-mutesting exec hook for patch capture.
#
# Called by go-mutesting for each mutation. Creates a unified-diff
# patch file from the original and mutated versions, writes a metadata
# file alongside, and returns exit 2 (skip) so go-mutesting runs no tests.
#
# Environment (set by generate.sh before invoking go-mutesting):
#   GAIA_CAPTURE_OUTDIR  — directory to write patches into
#   GAIA_CAPTURE_SRCDIR  — source-dir root for relative path computation
#   GAIA_CAPTURE_COUNTER — path to the counter file (incremented per mutant)
#
# Environment (set by go-mutesting per mutation):
#   MUTATE_ORIGINAL — path to the backup of the original file
#   MUTATE_CHANGED  — path to the mutated file (source modified in place)
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="capture-mutant.sh"
_cap_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- Validate environment ----------
[ -n "${MUTATE_ORIGINAL:-}" ] || { _cap_err "MUTATE_ORIGINAL not set"; exit 2; }
[ -n "${MUTATE_CHANGED:-}" ]  || { _cap_err "MUTATE_CHANGED not set"; exit 2; }
[ -n "${GAIA_CAPTURE_OUTDIR:-}" ]  || { _cap_err "GAIA_CAPTURE_OUTDIR not set"; exit 2; }
[ -n "${GAIA_CAPTURE_SRCDIR:-}" ]  || { _cap_err "GAIA_CAPTURE_SRCDIR not set"; exit 2; }
[ -n "${GAIA_CAPTURE_COUNTER:-}" ] || { _cap_err "GAIA_CAPTURE_COUNTER not set"; exit 2; }

[ -f "$MUTATE_ORIGINAL" ] || { _cap_err "original file not found: $MUTATE_ORIGINAL"; exit 2; }
[ -f "$MUTATE_CHANGED" ]  || { _cap_err "changed file not found: $MUTATE_CHANGED"; exit 2; }

# ---------- Skip no-op mutations ----------
if cmp -s "$MUTATE_ORIGINAL" "$MUTATE_CHANGED"; then
  exit 2
fi

# ---------- Compute relative path ----------
# MUTATE_CHANGED is the file go-mutesting mutated in place. Resolve it
# to a path relative to the source root so the patch headers carry
# portable a/<rel> and b/<rel> paths.
_cap_changed_real=$(cd "$(dirname "$MUTATE_CHANGED")" && pwd -P)/$(basename "$MUTATE_CHANGED")
_cap_srcdir_real=$(cd "$GAIA_CAPTURE_SRCDIR" && pwd -P)

_cap_rel_path="$_cap_changed_real"
case "$_cap_rel_path" in
  "$_cap_srcdir_real"/*) _cap_rel_path="${_cap_rel_path#"$_cap_srcdir_real/"}" ;;
esac

# ---------- Increment counter ----------
_cap_count=$(cat "$GAIA_CAPTURE_COUNTER" 2>/dev/null || echo 0)
_cap_count=$((_cap_count + 1))
printf '%d' "$_cap_count" > "$GAIA_CAPTURE_COUNTER"

# ---------- Generate unified diff ----------
_cap_patch_name="mutant-${_cap_count}.patch"
_cap_patch_file="$GAIA_CAPTURE_OUTDIR/$_cap_patch_name"

_cap_diff_tmp=$(mktemp "${TMPDIR:-/tmp}/gaia-cap-diff-XXXXXX")
_cap_diff_rc=0
diff -u "$MUTATE_ORIGINAL" "$MUTATE_CHANGED" > "$_cap_diff_tmp" || _cap_diff_rc=$?

if [ "$_cap_diff_rc" -eq 1 ]; then
  # Replace the diff header paths with a/<rel> and b/<rel>
  {
    printf -- '--- a/%s\t\n+++ b/%s\t\n' "$_cap_rel_path" "$_cap_rel_path"
    tail -n +3 "$_cap_diff_tmp"
  } > "$_cap_patch_file"
fi
rm -f "$_cap_diff_tmp"

# Verify the patch file is non-empty
if [ ! -s "$_cap_patch_file" ]; then
  rm -f "$_cap_patch_file"
  # Roll back counter
  _cap_count=$((_cap_count - 1))
  printf '%d' "$_cap_count" > "$GAIA_CAPTURE_COUNTER"
  exit 2
fi

# ---------- Extract line number from the hunk header ----------
_cap_line=$(awk '/^@@ -/ { sub(/^@@ -/, ""); sub(/[^0-9].*$/, ""); print; exit }' "$_cap_patch_file")

# ---------- Write metadata alongside the patch ----------
_cap_meta_file="$GAIA_CAPTURE_OUTDIR/mutant-${_cap_count}.meta"
printf 'file=%s\nline=%s\n' "$_cap_rel_path" "${_cap_line:-0}" > "$_cap_meta_file"

exit 2
