#!/usr/bin/env bash
# generate.sh — bash mutation adapter: mutant generator.
#
# Generates one unified-diff patch per mutant from a fixed sed operator
# table. Each mutant modifies exactly one line. Discards no-op mutants
# (cmp shows identical files) and mutants that fail bash -n (syntax error).
#
# Usage:
#   generate.sh --source-dir <dir> --files-from <list> --out-dir <dir>
#
# Output:
#   One .patch file per mutant in --out-dir, plus index.json listing them.
#
# Operator table (comparison flips, logical flips, exit/return flips,
# boolean flips, negation removal):
#   -eq  <-> -ne       ==  <-> !=       &&  <-> ||
#   -lt  <-> -ge       -gt <-> -le      exit 0 <-> exit 1
#   return 0 <-> return 1               true <-> false
#   ! removed (negation removal)
#
# POSIX discipline: bash 3.2, no local -A, no mapfile. # lint-pack:allow bash4-constructs — comment documents discipline, not actual usage

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="generate.sh"
_gen_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_gen_die() { local rc="$1"; shift; _gen_err "$*"; exit "$rc"; }

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

# ---------- Operator table ----------
# Each entry: pattern~replacement~description (tilde-delimited because
# patterns include | and - characters that collide with other delimiters).
_GEN_OPERATORS=(
  # Comparison flips
  '-eq~-ne~comparison flip eq/ne'
  '-ne~-eq~comparison flip ne/eq'
  '-lt~-ge~comparison flip lt/ge'
  '-ge~-lt~comparison flip ge/lt'
  '-gt~-le~comparison flip gt/le'
  '-le~-gt~comparison flip le/gt'
  # String comparison flips
  '==~!=~string comparison flip eq/ne'
  '!=~==~string comparison flip ne/eq'
  # Logical flips
  '&&~||~logical flip and/or'
  '||~&&~logical flip or/and'
  # Exit/return flips
  'exit 0~exit 1~exit code flip 0/1'
  'exit 1~exit 0~exit code flip 1/0'
  'return 0~return 1~return code flip 0/1'
  'return 1~return 0~return code flip 1/0'
  # Boolean flips
  'true~false~boolean flip true/false'
  'false~true~boolean flip false/true'
  # Negation removal
  '! ~~negation removal'
)

_gen_mutant_count=0
_gen_index_entries=""

# ---------- Process each file ----------
while IFS= read -r rel_path; do
  [ -n "$rel_path" ] || continue
  src_file="$_gen_source_dir/$rel_path"
  [ -f "$src_file" ] || continue

  [ -s "$src_file" ] || continue

  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))

    # Skip comment lines (leading whitespace + #)
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$stripped" in
      '#'*) continue ;;
      '')   continue ;;
    esac

    # Try each operator
    for op_entry in "${_GEN_OPERATORS[@]}"; do
      IFS='~' read -r pattern replacement desc <<< "$op_entry"

      # Check if pattern appears in this line (literal match).
      # Use -- to prevent patterns like -ne from being read as options.
      if ! printf '%s' "$line" | grep -qF -- "$pattern"; then
        continue
      fi

      # Create mutated copy using sed pipe (no sed -i for portability)
      tmp_mutated=$(mktemp "${TMPDIR:-/tmp}/gaia-gen-mut-XXXXXX")
      tmp_sed_out=$(mktemp "${TMPDIR:-/tmp}/gaia-gen-sed-XXXXXX")

      # Apply sed substitution on the specific line via pipe.
      # Logical operators need special escaping for sed.
      case "$pattern" in
        '&&')
          sed "${line_num}s/&&/||/" "$src_file" > "$tmp_sed_out"
          ;;
        '||')
          sed "${line_num}s/||/\\&\\&/" "$src_file" > "$tmp_sed_out"
          ;;
        '! ')
          sed "${line_num}s/! //" "$src_file" > "$tmp_sed_out"
          ;;
        *)
          sed "${line_num}s/${pattern}/${replacement}/" "$src_file" > "$tmp_sed_out"
          ;;
      esac
      mv "$tmp_sed_out" "$tmp_mutated"

      # Check for no-op (files identical)
      if cmp -s "$src_file" "$tmp_mutated"; then
        rm -f "$tmp_mutated"
        continue
      fi

      # Check syntax
      if ! bash -n "$tmp_mutated" 2>/dev/null; then
        rm -f "$tmp_mutated"
        continue
      fi

      # Generate unified diff
      _gen_mutant_count=$((_gen_mutant_count + 1))
      patch_name="mutant-${_gen_mutant_count}.patch"
      patch_file="$_gen_out_dir/$patch_name"

      # Headers are printed, not substituted with sed: a path may hold `&`, `|`
      # or a space. The tab ends the name, which is what lets patch accept a
      # file name with a space in it.
      tmp_diff=$(mktemp "${TMPDIR:-/tmp}/gaia-gen-diff-XXXXXX")
      diff_rc=0
      diff -u "$src_file" "$tmp_mutated" > "$tmp_diff" || diff_rc=$?
      if [ "$diff_rc" -eq 1 ]; then
        {
          printf -- '--- a/%s\t\n+++ b/%s\t\n' "$rel_path" "$rel_path"
          tail -n +3 "$tmp_diff"
        } > "$patch_file"
      fi

      rm -f "$tmp_mutated" "$tmp_diff"

      # Verify the patch file is non-empty
      if [ ! -s "$patch_file" ]; then
        rm -f "$patch_file"
        _gen_mutant_count=$((_gen_mutant_count - 1))
        continue
      fi

      # Add to index
      if [ -n "$_gen_index_entries" ]; then
        _gen_index_entries="${_gen_index_entries},"
      fi
      _gen_index_entries="${_gen_index_entries}$(jq -n \
        --arg mid "mutant-${_gen_mutant_count}" \
        --arg pf "$patch_name" \
        --arg f "$rel_path" \
        --argjson l "$line_num" \
        --arg op "$desc" \
        '{"mutant_id":$mid,"patch_file":$pf,"file":$f,"line":$l,"operator":$op}')"
    done
  done < "$src_file"
done < "$_gen_files_from"

# ---------- Write index ----------
printf '[%s]' "$_gen_index_entries" | jq '.' > "$_gen_out_dir/index.json"

_gen_err "generated $_gen_mutant_count mutants"
exit 0
