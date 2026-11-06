#!/usr/bin/env bash
# mutation-runner.sh — stack-neutral mutation runner.
#
# Dispatches mutant generation and execution to per-stack adapters under
# scripts/adapters/mutation-*/. Each mutant is applied inside a fresh
# throwaway copy of the worktree (never in the real worktree). The runner
# verifies the worktree is untouched via sha256 manifests before and after.
#
# Public API:
#   mutation-runner.sh --story <key> --worktree <dir> --output <json> [opts...]
#   mutation-runner.sh --worktree <dir> --files-from <list> --tests-from <list> \
#                      --output <json> [opts...]
#   mutation-runner.sh --doctor [--config <yaml>]
#   mutation-runner.sh --help
#
# A run first proves the covering tests are green on an unmutated copy. A red
# baseline, or tests that cannot run at all, refuses to score: the evidence has
# gate errored and no score, because every mutant would look killed otherwise.
#
# Flags:
#   --story <key>       Resolve story file, read priority and File List
#   --worktree <dir>    Path to the story worktree (or project root)
#   --files-from <file> Newline-delimited source files to mutate
#   --tests-from <file> Newline-delimited test files
#   --output <json>     Path to write the evidence JSON
#   --patch-dir <dir>   Directory for generated patches (default: alongside output)
#   --jobs <n>          Max parallel mutant executions (default: min(4, nproc))
#   --priority <P>      Story priority (P0..P3); overrides story-file value
#   --thresholds <json> Inline threshold object (for testing; normally from config)
#   --config <yaml>     Path to project-config.yaml
#   --doctor            Print mutation-testing diagnostic section and exit
#   --help              Show usage
#
# Exit codes:
#   0   Run completed (evidence written; gate may be passed, failed, advisory, errored)
#   1   Usage / caller error
#   2   worktree_mutated — integrity check failed, no evidence written
#   3   Containment violation
#
# POSIX discipline: bash 3.2 (macOS), no local -A, no mapfile, no readarray.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="mutation-runner.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

# shellcheck source=lib/mutation-isolation.sh
. "$SCRIPT_DIR/lib/mutation-isolation.sh"
# shellcheck source=lib/mutation-config.sh
. "$SCRIPT_DIR/lib/mutation-config.sh"

# ---------- Logging ----------
_mr_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_mr_info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_mr_die() { local rc="$1"; shift; _mr_err "$*"; exit "$rc"; }

# ---------- Usage ----------
_mr_usage() {
  cat <<'EOF'
mutation-runner.sh — stack-neutral mutation runner.

Usage:
  mutation-runner.sh --story <key> --worktree <dir> --output <json> [opts...]
  mutation-runner.sh --worktree <dir> --files-from <list> --tests-from <list> \
                     --output <json> [opts...]
  mutation-runner.sh --doctor [--config <yaml>]
  mutation-runner.sh --help

See script header for full flag reference.
EOF
}

# ---------- Defaults ----------
_MR_DEFAULT_P0=80
_MR_DEFAULT_P1=60
_MR_DEFAULT_P2=0
_MR_DEFAULT_P3=0
_MR_MAX_MUTANTS="${GAIA_MUTATION_MAX_MUTANTS:-200}"

# ---------- Arg parsing ----------
_mr_story=""
_mr_worktree=""
_mr_files_from=""
_mr_tests_from=""
_mr_output=""
_mr_patch_dir=""
_mr_jobs=""
_mr_priority=""
_mr_thresholds=""
_mr_config=""
_mr_doctor=0

while [ $# -gt 0 ]; do
  case "$1" in
    --story)      shift; _mr_story="${1:-}"; shift ;;
    --worktree)   shift; _mr_worktree="${1:-}"; shift ;;
    --files-from) shift; _mr_files_from="${1:-}"; shift ;;
    --tests-from) shift; _mr_tests_from="${1:-}"; shift ;;
    --output)     shift; _mr_output="${1:-}"; shift ;;
    --patch-dir)  shift; _mr_patch_dir="${1:-}"; shift ;;
    --jobs)       shift; _mr_jobs="${1:-}"; shift ;;
    --priority)   shift; _mr_priority="${1:-}"; shift ;;
    --thresholds) shift; _mr_thresholds="${1:-}"; shift ;;
    --config)     shift; _mr_config="${1:-}"; shift ;;
    --doctor)     _mr_doctor=1; shift ;;
    --help|-h)    _mr_usage; exit 0 ;;
    *)            _mr_die 1 "unknown argument: $1" ;;
  esac
done

# ---------- Doctor mode ----------
if [ "$_mr_doctor" -eq 1 ]; then
  printf '=== Mutation testing ===\n'

  # Resolve thresholds
  if [ -n "$_mr_thresholds" ]; then
    printf 'Thresholds: %s\n' "$_mr_thresholds"
  elif [ -n "$_mr_config" ] && [ -f "$_mr_config" ]; then
    if ! doctor_thresholds="$(mutation_read_thresholds "$_mr_config" 2>&1)"; then
      printf 'Thresholds: unknown (%s)\n' "$doctor_thresholds"
    elif [ -z "$doctor_thresholds" ]; then
      printf 'Mutation testing is off (no mutation_thresholds configured)\n'
    else
      printf 'Thresholds: %s\n' "$doctor_thresholds"
      printf 'Effective: %s\n' "$(printf '%s' "$doctor_thresholds" | jq -r \
        --argjson p0 "$_MR_DEFAULT_P0" --argjson p1 "$_MR_DEFAULT_P1" \
        --argjson p2 "$_MR_DEFAULT_P2" --argjson p3 "$_MR_DEFAULT_P3" \
        '"P0=\(.P0 // $p0) P1=\(.P1 // $p1) P2=\(.P2 // $p2) P3=\(.P3 // $p3)"')"
    fi
  else
    printf 'Mutation testing is off (no mutation_thresholds configured)\n'
  fi

  # Adapter availability
  printf '\nAdapters:\n'
  for adapter_dir in "$SCRIPT_DIR"/adapters/mutation-*/; do
    [ -d "$adapter_dir" ] || continue
    adapter_name=$(basename "$adapter_dir")
    manifest="$adapter_dir/mutation-adapter.json"
    if [ -f "$manifest" ]; then
      provider=$(jq -r '.provider // "unknown"' "$manifest" 2>/dev/null || echo "unknown")
      if command -v "$provider" >/dev/null 2>&1; then
        printf '  %s: %s (available)\n' "$adapter_name" "$provider"
      else
        printf '  %s: %s (NOT available)\n' "$adapter_name" "$provider"
      fi
    else
      printf '  %s: no manifest\n' "$adapter_name"
    fi
  done

  # Leftover temp dirs
  local_tmpdir="${TMPDIR:-/tmp}"
  leftovers=$(find "$local_tmpdir" -maxdepth 1 -name 'gaia-mutation-*' -type d 2>/dev/null || true)
  if [ -n "$leftovers" ]; then
    printf '\nWARNING: leftover mutation temp directories found:\n'
    printf '%s\n' "$leftovers"
  else
    printf '\nNo leftover mutation temp directories.\n'
  fi

  exit 0
fi

# ---------- Validation ----------
[ -n "$_mr_worktree" ] || _mr_die 1 "--worktree is required"
[ -d "$_mr_worktree" ] || _mr_die 1 "--worktree '$_mr_worktree' is not a directory"
[ -n "$_mr_output" ]   || _mr_die 1 "--output is required"

# Resolve worktree to absolute path
_mr_worktree=$(cd "$_mr_worktree" && pwd -P)

# ---------- Run root ----------
# Everything the run creates lives under one directory, so interrupted workers
# leave nothing behind however far they got.
mutation_register_cleanup
mutation_init_run_root "$_mr_worktree" || exit 3
_mr_root="$_MI_RUN_ROOT"
mkdir -p "$_mr_root/results" "$_mr_root/patches" "$_mr_root/cover" "$_mr_root/tmp" "$_mr_root/records"

# A File List path may be written from a parent of this worktree. Drop leading
# components until it names a file here; print nothing when it never does.
_mr_locate_in_worktree() {
  local candidate="$1"
  while :; do
    if [ -f "$_mr_worktree/$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    case "$candidate" in
      */*) candidate="${candidate#*/}" ;;
      *)   return 0 ;;
    esac
  done
}

# ---------- Resolve story metadata ----------
if [ -n "$_mr_story" ]; then
  _mr_story_file=""
  if [ -x "$SCRIPT_DIR/resolve-story-file.sh" ]; then
    _mr_story_file=$("$SCRIPT_DIR/resolve-story-file.sh" "$_mr_story" 2>/dev/null || true)
  fi
  if [ -n "$_mr_story_file" ] && [ -f "$_mr_story_file" ]; then
    if [ -z "$_mr_priority" ]; then
      _mr_priority=$(mutation_story_priority "$_mr_story_file")
      [ -n "$_mr_priority" ] || _mr_die 1 "story $_mr_story has no priority in its frontmatter"
    fi
    if [ -z "$_mr_files_from" ] && [ -z "$_mr_tests_from" ]; then
      _mr_auto_files="$_mr_root/files.txt"
      _mr_auto_tests="$_mr_root/tests.txt"
      : > "$_mr_auto_files"
      : > "$_mr_auto_tests"
      while IFS= read -r _mr_entry; do
        _mr_found=$(_mr_locate_in_worktree "$_mr_entry")
        [ -n "$_mr_found" ] || continue
        case "$_mr_found" in
          *.bats|*.test.*|*.spec.*|*_test.*|test_*|*/test_*) printf '%s\n' "$_mr_found" >> "$_mr_auto_tests" ;;
          *) printf '%s\n' "$_mr_found" >> "$_mr_auto_files" ;;
        esac
      done < <(mutation_story_file_list "$_mr_story_file")
      [ -s "$_mr_auto_files" ] && _mr_files_from="$_mr_auto_files"
      [ -s "$_mr_auto_tests" ] && _mr_tests_from="$_mr_auto_tests"
    fi
  elif [ -z "$_mr_priority" ] || [ -z "$_mr_files_from" ]; then
    _mr_die 1 "story file not found for $_mr_story"
  fi
fi

[ -n "$_mr_files_from" ] || _mr_die 1 "--files-from is required (or --story with a File List)"
[ -f "$_mr_files_from" ] || _mr_die 1 "--files-from '$_mr_files_from' not found"
[ -n "$_mr_priority" ]   || _mr_priority="P2"

# Default patch dir
if [ -z "$_mr_patch_dir" ]; then
  _mr_patch_dir="$(dirname "$_mr_output")/$(basename "$_mr_output" .json)-mutants"
fi

# Resolve jobs
if [ -z "$_mr_jobs" ]; then
  _mr_jobs="${GAIA_MUTATION_JOBS:-}"
fi
if [ -z "$_mr_jobs" ]; then
  _mr_nproc=4
  if command -v nproc >/dev/null 2>&1; then
    _mr_nproc=$(nproc 2>/dev/null || echo 4)
  elif command -v sysctl >/dev/null 2>&1; then
    _mr_nproc=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  fi
  _mr_jobs=$(( _mr_nproc < 4 ? _mr_nproc : 4 ))
fi
case "$_mr_jobs" in
  ''|*[!0-9]*|0) _mr_die 1 "--jobs must be a positive whole number" ;;
esac

# ---------- Resolve thresholds ----------
# Absent means not configured; an empty object means configured with defaults.
_mr_thresholds_configured=0
_mr_th_p0=""
_mr_th_p1=""
_mr_th_p2=""
_mr_th_p3=""

_mr_resolve_thresholds() {
  if [ -z "$_mr_thresholds" ] && [ -n "$_mr_config" ]; then
    _mr_thresholds="$(mutation_read_thresholds "$_mr_config")" || _mr_die 1 "could not read mutation thresholds (yq)"
  fi
  [ -n "$_mr_thresholds" ] || return 0
  printf '%s' "$_mr_thresholds" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || _mr_die 1 "mutation thresholds are not a JSON object: $_mr_thresholds"
  _mr_thresholds_configured=1
  _mr_th_p0=$(printf '%s' "$_mr_thresholds" | jq -r '.P0 // empty')
  _mr_th_p1=$(printf '%s' "$_mr_thresholds" | jq -r '.P1 // empty')
  _mr_th_p2=$(printf '%s' "$_mr_thresholds" | jq -r '.P2 // empty')
  _mr_th_p3=$(printf '%s' "$_mr_thresholds" | jq -r '.P3 // empty')
}
_mr_resolve_thresholds

# ---------- Adapter discovery ----------
# Find the mutation adapter that covers a given file extension.
_mr_find_adapter() {
  local file="$1"
  local ext="${file##*.}"
  local adapter_dir

  for adapter_dir in "$SCRIPT_DIR"/adapters/mutation-*/; do
    [ -d "$adapter_dir" ] || continue
    local manifest="$adapter_dir/mutation-adapter.json"
    [ -f "$manifest" ] || continue
    if jq -e --arg ext ".$ext" '.["file-extensions"] | map(. == $ext) | any' "$manifest" >/dev/null 2>&1; then
      printf '%s\n' "${adapter_dir%/}"
      return 0
    fi
  done
  return 1
}

# ---------- Covering-test selection ----------
# A test covers a source file when it names that file: the basename as a whole
# token, so foo.sh is not matched by myfoo.sh or foo.sh.bak, and a stem alone
# never counts. When the name carries a literal parent directory it must be the
# source's own; a variable, `.` or `..` in front of it says nothing either way.
# awk reads the name through ENVIRON and matches with index(), so any character
# in a path stays literal.
_mr_test_references() {
  local test_file="$1" source_file="$2" parent
  parent="$(basename "$(dirname "$source_file")")"
  _MR_NAME="$(basename "$source_file")" _MR_PARENT="$parent" awk '
    function wordy(c) { return c ~ /[A-Za-z0-9_-]/ }
    BEGIN { name = ENVIRON["_MR_NAME"]; parent = ENVIRON["_MR_PARENT"]; n = length(name) }
    {
      line = $0
      offset = 0
      while ((at = index(substr(line, offset + 1), name)) > 0) {
        start = offset + at
        before = start > 1 ? substr(line, start - 1, 1) : ""
        after = substr(line, start + n, 1)
        after2 = substr(line, start + n + 1, 1)
        offset = start
        if (before != "" && (wordy(before) || before == ".")) continue
        if (wordy(after) || (after == "." && wordy(after2))) continue
        if (before == "/") {
          dir_end = start - 2
          dir_start = dir_end
          while (dir_start >= 1 && substr(line, dir_start, 1) ~ /[A-Za-z0-9_.-]/) dir_start--
          dir = substr(line, dir_start + 1, dir_end - dir_start)
          sigil = dir_start >= 1 ? substr(line, dir_start, 1) : ""
          if (dir != "" && dir != "." && dir != ".." && dir != parent && sigil != "$") continue
        }
        found = 1
        exit
      }
    }
    END { exit !found }
  ' "$test_file"
}

_mr_find_covering_tests() {
  local source_file="$1"
  local tests_file="$2"
  local test_path
  while IFS= read -r test_path; do
    [ -n "$test_path" ] || continue
    [ -f "$_mr_worktree/$test_path" ] || continue
    if _mr_test_references "$_mr_worktree/$test_path" "$source_file"; then
      printf '%s\n' "$test_path"
    fi
  done < "$tests_file"
}

# Runs every covering file even after one fails, so killed_by is complete and
# a test in a later file is not reported as killing nothing. bats files share
# one invocation; the highest exit code wins, so a command that could not run
# (126, 127, 128+) is never masked by another file's plain failure. Every path
# is quoted with printf %q.
_mr_compose_test_command() {
  local copy="$1" list="$2" tfile quoted bats_args="" others=""
  while IFS= read -r tfile; do
    [ -n "$tfile" ] || continue
    quoted=$(printf '%q' "$copy/$tfile")
    case "$tfile" in
      *.bats) bats_args="$bats_args $quoted" ;;
      *) others="$others bash $quoted || { c=\$?; [ \$c -gt \$rc ] && rc=\$c; };" ;;
    esac
  done < "$list"
  local cmd='rc=0;'
  [ -z "$bats_args" ] || cmd="$cmd bats --tap$bats_args || rc=\$?;"
  # shellcheck disable=SC2016 # $rc belongs to the composed command
  printf '%s%s exit $rc' "$cmd" "$others"
}

# Runs one adapter call. Scratch files of the adapter and of the tests it starts
# stay inside the run root.
_mr_call_adapter() {
  local run_script="$1" copy="$2" patch="$3" cmd="$4" out="$5" limit="$6"
  TMPDIR="$_mr_root/tmp" "$run_script" \
    --source-dir "$copy" \
    --patch-file "$patch" \
    --test-command "$cmd" \
    --output "$out" \
    --timeout "$limit"
}

_mr_error_record() {
  jq -n --arg mid "$1" --arg f "$2" --arg msg "$3" \
    '{"mutant_id":$mid,"file":$f,"status":"error","test_output":$msg}'
}

# ---------- Pre-run manifest ----------
_mr_rel_to_worktree() {
  local parent base
  parent="$(cd "$(dirname "$1")" && pwd -P)"
  base="$(basename "$1")"
  case "$parent/$base" in
    "$_mr_worktree"/*) printf '%s' "${parent#"$_mr_worktree"/}/$base" ;;
    "$_mr_worktree/$base") printf '%s' "$base" ;;
  esac
}

# The run's own evidence and patches may live in the worktree. They are the
# run's output, not a change to the code under test.
mkdir -p "$(dirname "$_mr_output")" "$_mr_patch_dir"
_mr_rel_output="$(_mr_rel_to_worktree "$_mr_output")"
_mr_rel_patches="$(_mr_rel_to_worktree "$_mr_patch_dir")"
_MI_MANIFEST_EXCLUDES="$_mr_rel_output
$_mr_rel_patches"

_mr_info "computing pre-run worktree manifest"
_mr_manifest_before="$_mr_root/manifest-before"
mutation_compute_manifest "$_mr_worktree" "$_mr_manifest_before"

# ---------- Generate mutants ----------
_mr_info "discovering adapters and generating mutants"

_mr_truncated="false"
_mr_unmutated_files=()
_mr_covering_tests=()
_mr_gen_copy=""

# One entry per source file that has an adapter (bash 3.2: parallel arrays).
_mr_src_file=()
_mr_src_run=()
_mr_src_cover=()
_mr_src_timeout=()
_mr_src_format=()
# One entry per mutant to execute.
_mr_plan_id=()
_mr_plan_src=()
_mr_plan_patch=()
_mr_plan_line=()
_mr_plan_operator=()
_mr_extra_records=0

while IFS= read -r source_file; do
  [ -n "$source_file" ] || continue

  adapter_dir=$(_mr_find_adapter "$source_file" || true)
  if [ -z "$adapter_dir" ] || [ ! -x "$adapter_dir/generate.sh" ] || [ ! -x "$adapter_dir/run.sh" ]; then
    _mr_unmutated_files+=("$source_file")
    continue
  fi

  [ -n "$_mr_gen_copy" ] || _mr_gen_copy=$(mutation_create_copy "$_mr_worktree") \
    || _mr_die 3 "could not create a throwaway copy for mutant generation"

  # Ids are unique across files and stable across runs, which is what lets the
  # findings register recognise a mutant it has already seen.
  _mr_file_hash=$(mutation_short_hash "$source_file")
  gen_out="$_mr_root/gen-$_mr_file_hash"
  mkdir -p "$gen_out"
  printf '%s\n' "$source_file" > "$gen_out.files"

  if ! _mr_gen_err=$(TMPDIR="$_mr_root/tmp" "$adapter_dir/generate.sh" --source-dir "$_mr_gen_copy" --files-from "$gen_out.files" --out-dir "$gen_out" 2>&1) \
     || ! jq -e 'type == "array"' "$gen_out/index.json" >/dev/null 2>&1; then
    _mr_info "generator failed for $source_file (adapter: $(basename "$adapter_dir"))"
    _mr_extra_records=$((_mr_extra_records + 1))
    _mr_error_record "mutant-$_mr_file_hash-generator" "$source_file" "generator failed: $_mr_gen_err" \
      > "$_mr_root/records/generator-$_mr_file_hash.json"
    continue
  fi

  cover_list="$_mr_root/cover/$_mr_file_hash"
  : > "$cover_list"
  if [ -n "${_mr_tests_from:-}" ] && [ -f "$_mr_tests_from" ]; then
    _mr_find_covering_tests "$source_file" "$_mr_tests_from" > "$cover_list"
  fi
  while IFS= read -r _ct; do
    [ -n "$_ct" ] || continue
    _ct_found=0
    for _existing_ct in "${_mr_covering_tests[@]+"${_mr_covering_tests[@]}"}"; do
      [ "$_existing_ct" = "$_ct" ] && { _ct_found=1; break; }
    done
    [ "$_ct_found" -eq 0 ] && _mr_covering_tests+=("$_ct")
  done < "$cover_list"

  _mr_src_idx=${#_mr_src_file[@]}
  _mr_src_file+=("$source_file")
  _mr_src_run+=("$adapter_dir/run.sh")
  _mr_src_cover+=("$cover_list")
  _mr_src_timeout+=("$(jq -r '.["default-timeout-seconds"] // 30' "$adapter_dir/mutation-adapter.json")")
  _mr_src_format+=("$(jq -r '.["mutant-format"] // "patch"' "$adapter_dir/mutation-adapter.json")")

  while IFS=$'\t' read -r _m_id _m_file _m_line _m_op; do
    [ -n "$_m_id" ] || continue
    if [ "${#_mr_plan_id[@]}" -ge "$_MR_MAX_MUTANTS" ]; then
      _mr_truncated="true"
      break
    fi
    _mr_mid="mutant-$_mr_file_hash-${_m_id#mutant-}"
    _mr_kept="$_mr_root/patches/$_mr_mid.${_m_file##*.}"
    cp "$gen_out/$_m_file" "$_mr_kept"
    _mr_plan_id+=("$_mr_mid")
    _mr_plan_src+=("$_mr_src_idx")
    _mr_plan_patch+=("$_mr_kept")
    _mr_plan_line+=("$_m_line")
    _mr_plan_operator+=("$_m_op")
  done < <(jq -r '.[] | [.mutant_id, (.patch_file // .batch_file), ((.line // 0) | tostring), (.operator // "")] | @tsv' "$gen_out/index.json")
done < "$_mr_files_from"

if [ -n "$_mr_gen_copy" ]; then
  rm -rf "$_mr_gen_copy"
fi

# ---------- Baseline ----------
# Each distinct set of covering tests must be green on an unmutated copy first;
# a zero-byte patch asks the adapter for exactly that. Tool-native tools run
# their own green check as part of the batch.
_mr_refused=""
_mr_baseline_status=""
_mr_baseline_output=""
_mr_empty_patch="$_mr_root/empty.patch"
: > "$_mr_empty_patch"
_mr_test_names="$_mr_root/test-names"
: > "$_mr_test_names"
_mr_seen_cover=()

if [ "${#_mr_plan_id[@]}" -gt 0 ]; then
  _mr_info "checking the covering tests are green on unmutated code"
  for _b_idx in "${!_mr_src_file[@]}"; do
    [ "${_mr_src_format[$_b_idx]}" = "patch" ] || continue
    _b_cover="${_mr_src_cover[$_b_idx]}"
    [ -s "$_b_cover" ] || continue
    _b_key="${_mr_src_run[$_b_idx]}|$(cat "$_b_cover")"
    _b_dup=0
    for _b_seen in "${_mr_seen_cover[@]+"${_mr_seen_cover[@]}"}"; do
      [ "$_b_seen" = "$_b_key" ] && { _b_dup=1; break; }
    done
    [ "$_b_dup" -eq 0 ] || continue
    _mr_seen_cover+=("$_b_key")

    _b_copy=$(mutation_create_copy "$_mr_worktree") || _mr_die 3 "could not create a throwaway copy for the baseline"
    _b_out="$_mr_root/baseline-$_b_idx.json"
    _b_rc=0
    _mr_call_adapter "${_mr_src_run[$_b_idx]}" "$_b_copy" "$_mr_empty_patch" \
      "$(_mr_compose_test_command "$_b_copy" "$_b_cover")" "$_b_out" "${_mr_src_timeout[$_b_idx]}" 2>/dev/null || _b_rc=$?
    rm -rf "$_b_copy"
    _mr_baseline_status="error"
    if [ "$_b_rc" -eq 0 ] && jq -e 'type == "object"' "$_b_out" >/dev/null 2>&1; then
      _mr_baseline_status=$(jq -r '.status // "error"' "$_b_out")
      jq -r '.tests[]?' "$_b_out" >> "$_mr_test_names"
    fi
    case "$_mr_baseline_status" in
      survived) ;;
      killed|timeout)
        _mr_refused="baseline_red"
        _mr_baseline_output=$(jq -r '.test_output // ""' "$_b_out")
        break
        ;;
      *)
        _mr_refused="baseline_error"
        _mr_baseline_output=$(jq -r '.test_output // "adapter failed"' "$_b_out" 2>/dev/null || echo "adapter failed")
        break
        ;;
    esac
  done
fi

# ---------- Run mutants ----------
# Each mutant gets its own copy and its own background worker, bounded by the
# job limit with oldest-first wait (no `wait -n`: bash 3.2).
_mr_active_pids=()

_mr_run_mutant() {
  local idx="$1" mid="${_mr_plan_id[$1]}" src="${_mr_plan_src[$1]}" result copy rc=0 cmd errfile
  result="$_mr_root/results/$mid.json"
  copy=$(mutation_create_copy "$_mr_worktree") || {
    _mr_error_record "$mid" "${_mr_src_file[$src]}" "containment error" > "$result"
    return 0
  }
  cmd=$(_mr_compose_test_command "$copy" "${_mr_src_cover[$src]}")
  errfile="$result.stderr"
  _mr_call_adapter "${_mr_src_run[$src]}" "$copy" "${_mr_plan_patch[$idx]}" "$cmd" "$result" \
    "${_mr_src_timeout[$src]}" 2>"$errfile" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _mr_error_record "$mid" "${_mr_src_file[$src]}" "adapter exited $rc: $(tail -c 2048 "$errfile")" > "$result"
  fi
  rm -rf "$copy"
}

if [ -z "$_mr_refused" ]; then
  for _r_idx in "${!_mr_plan_id[@]}"; do
    _r_src="${_mr_plan_src[$_r_idx]}"
    if [ ! -s "${_mr_src_cover[$_r_src]}" ]; then
      # No covering test: nothing to run, and never a full-suite fallback.
      jq -n --arg mid "${_mr_plan_id[$_r_idx]}" --arg f "${_mr_src_file[$_r_src]}" \
        '{"mutant_id":$mid,"file":$f,"status":"survived","no_coverage":true,"test_output":""}' \
        > "$_mr_root/results/${_mr_plan_id[$_r_idx]}.json"
      continue
    fi
    while [ "${#_mr_active_pids[@]}" -ge "$_mr_jobs" ]; do
      wait "${_mr_active_pids[0]}" 2>/dev/null || true
      _mr_active_pids=("${_mr_active_pids[@]:1}")
    done
    _mr_run_mutant "$_r_idx" &
    _mr_active_pids+=($!)
  done
  for pid in "${_mr_active_pids[@]+"${_mr_active_pids[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

# ---------- Post-run manifest ----------
_mr_info "verifying post-run worktree integrity"
if ! mutation_verify_manifest "$_mr_worktree" "$_mr_manifest_before"; then
  rm -f "$_mr_output"
  _mr_die 2 "worktree_mutated"
fi

# ---------- Aggregate results ----------
_mr_info "aggregating results"

# Turns one adapter result (a record, or an array from a tool-native adapter)
# into an array of complete records. What the runner planned wins over what a
# patch hunk header suggests; an array's records keep their own details.
_mr_normalise_result() {
  local idx="$1" mid="${_mr_plan_id[$1]}" src="${_mr_plan_src[$1]}" result out
  result="$_mr_root/results/$mid.json"
  out="$_mr_root/records/$(printf '%06d' "$idx").json"
  if [ ! -s "$result" ]; then
    _mr_error_record "$mid" "${_mr_src_file[$src]}" "adapter wrote no result" > "$result"
  elif ! jq -e . "$result" >/dev/null 2>&1; then
    _mr_error_record "$mid" "${_mr_src_file[$src]}" "adapter produced non-JSON output" > "$result"
  fi
  jq --arg mid "$mid" --arg file "${_mr_src_file[$src]}" \
     --argjson line "${_mr_plan_line[$idx]:-0}" --arg operator "${_mr_plan_operator[$idx]}" '
    def known: . as $s | ["killed","survived","timeout","error"] | index($s) != null;
    def checked:
      if type != "object" then {status:"error",test_output:"adapter record is not an object"}
      elif ((.status // "") | known) then .
      else {status:"error",test_output:("adapter reported unknown status: " + ((.status // "none") | tostring))}
      end;
    if type == "array" then
      to_entries | map(
        .key as $i | (.value | checked)
        | .mutant_id = ($mid + "-" + ((.mutant_id // $i) | tostring))
        | .file = (.file // $file)
        | .line = (.line // $line)
        | .operator = (.operator // $operator)
        | .test_output = (.test_output // "")
      )
    else
      [ checked
        | .mutant_id = $mid
        | .file = $file
        | .line = $line
        | .operator = $operator
        | .test_output = (.test_output // "")
      ]
    end
    | map(if .tests then del(.tests) else . end)
  ' "$result" > "$out"
}

for _n_idx in "${!_mr_plan_id[@]}"; do
  [ -z "$_mr_refused" ] || break
  _mr_normalise_result "$_n_idx"
done
# Generator failures were written as single records; give them the array shape.
for _g_rec in "$_mr_root"/records/generator-*.json; do
  [ -f "$_g_rec" ] || continue
  jq '[.]' "$_g_rec" > "$_g_rec.tmp" && mv "$_g_rec.tmp" "$_g_rec"
done

_mr_mutants_file="$_mr_root/mutants.json"
# Glob order (LC_ALL=C over zero-padded names) is the plan order.
for _a_rec in "$_mr_root"/records/*.json; do
  if [ -f "$_a_rec" ]; then cat "$_a_rec"; fi
done | jq -s 'add // []' > "$_mr_mutants_file"

_mr_count() { jq -r --arg s "$1" '[.[] | select(.status == $s)] | length' "$_mr_mutants_file"; }
_mr_mutant_count=$(jq -r 'length' "$_mr_mutants_file")
_mr_killed=$(_mr_count killed)
_mr_survived=$(_mr_count survived)
_mr_timeout=$(_mr_count timeout)
_mr_error=$(_mr_count error)

# Compute score: (killed + timeout) / (killed + timeout + survived)
# Errors excluded. No-coverage mutants count as survived.
_mr_denom=$((_mr_killed + _mr_timeout + _mr_survived))
_mr_score=""
if [ "$_mr_denom" -gt 0 ] && [ -z "$_mr_refused" ]; then
  _mr_score=$(( (_mr_killed + _mr_timeout) * 100 / _mr_denom ))
fi

# ---------- Compute gate ----------
_mr_gate="not_configured"

if [ -n "$_mr_refused" ]; then
  # A run that could not measure anything never reads as a pass, configured or not.
  _mr_gate="errored"
elif [ "$_mr_thresholds_configured" -eq 1 ]; then
  if [ -z "$_mr_score" ]; then
    # All mutants errored or no mutants generated
    _mr_gate="errored"
  else
    case "$_mr_priority" in
      P0|P1)
        if [ "$_mr_priority" = "P0" ]; then
          _mr_threshold="${_mr_th_p0:-$_MR_DEFAULT_P0}"
        else
          _mr_threshold="${_mr_th_p1:-$_MR_DEFAULT_P1}"
        fi
        if [ "$_mr_score" -lt "$_mr_threshold" ]; then
          _mr_gate="failed"
        else
          _mr_gate="passed"
        fi
        ;;
      *)
        _mr_gate="advisory"
        _mr_info "$_mr_priority story: mutation score ${_mr_score}% (advisory, no gate)"
        ;;
    esac
  fi
fi

# ---------- Build evidence JSON ----------
_mr_commit_sha=""
if (cd "$_mr_worktree" && git rev-parse HEAD >/dev/null 2>&1); then
  _mr_commit_sha=$(cd "$_mr_worktree" && git rev-parse HEAD 2>/dev/null || true)
fi

_mr_generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Build thresholds applied
_mr_th_applied="null"
if [ "$_mr_thresholds_configured" -eq 1 ]; then
  _mr_th_applied=$(jq -n \
    --argjson p0 "${_mr_th_p0:-$_MR_DEFAULT_P0}" \
    --argjson p1 "${_mr_th_p1:-$_MR_DEFAULT_P1}" \
    --argjson p2 "${_mr_th_p2:-$_MR_DEFAULT_P2}" \
    --argjson p3 "${_mr_th_p3:-$_MR_DEFAULT_P3}" \
    '{"P0":$p0,"P1":$p1,"P2":$p2,"P3":$p3}')
fi

# Build unmutated files array
_mr_unmutated_json="[]"
for uf in "${_mr_unmutated_files[@]+"${_mr_unmutated_files[@]}"}"; do
  _mr_unmutated_json=$(printf '%s' "$_mr_unmutated_json" | jq --arg f "$uf" '. + [$f]')
done

# Build covering tests array (for zero-kill analysis)
_mr_covering_json="[]"
for ct in "${_mr_covering_tests[@]+"${_mr_covering_tests[@]}"}"; do
  _mr_covering_json=$(printf '%s' "$_mr_covering_json" | jq --arg t "$ct" '. + [$t]')
done

# Score as JSON value
_mr_score_json="null"
if [ -n "$_mr_score" ]; then
  _mr_score_json="$_mr_score"
fi

_mr_baseline_json="null"
if [ -n "$_mr_refused" ]; then
  _mr_baseline_json=$(jq -n --arg s "$_mr_baseline_status" --arg o "$_mr_baseline_output" '{status:$s,test_output:$o}')
fi

# Write evidence
jq -n \
  --arg schema_version "1.0" \
  --arg story_key "${_mr_story:-unknown}" \
  --arg priority "$_mr_priority" \
  --arg commit_sha "$_mr_commit_sha" \
  --arg generated_at "$_mr_generated_at" \
  --argjson thresholds "$_mr_th_applied" \
  --argjson totals "$(jq -n \
    --argjson mutants "$_mr_mutant_count" \
    --argjson killed "$_mr_killed" \
    --argjson survived "$_mr_survived" \
    --argjson timeout "$_mr_timeout" \
    --argjson error "$_mr_error" \
    '{"mutants":$mutants,"killed":$killed,"survived":$survived,"timeout":$timeout,"error":$error}')" \
  --argjson score "$_mr_score_json" \
  --arg gate "$_mr_gate" \
  --arg refused "$_mr_refused" \
  --argjson baseline "$_mr_baseline_json" \
  --argjson truncated "$_mr_truncated" \
  --slurpfile mutants "$_mr_mutants_file" \
  --argjson unmutated_files "$_mr_unmutated_json" \
  --argjson covering_tests "$_mr_covering_json" \
  --argjson test_names "$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$_mr_test_names")" \
  '{
    schema_version: $schema_version,
    story_key: $story_key,
    priority: $priority,
    commit_sha: $commit_sha,
    generated_at: $generated_at,
    thresholds: $thresholds,
    totals: $totals,
    score: $score,
    gate: $gate,
    truncated: $truncated,
    mutants: $mutants[0],
    unmutated_files: $unmutated_files,
    covering_tests: $covering_tests,
    covering_test_names: $test_names
  }
  + (if $refused == "" then {} else {refused: $refused, baseline: $baseline} end)' > "$_mr_output"

# Patches are published only now: during the run they were scratch files.
find "$_mr_patch_dir" -maxdepth 1 -type f -name 'mutant-*' -exec rm -f {} + 2>/dev/null || true
find "$_mr_root/patches" -type f -exec cp {} "$_mr_patch_dir/" \;

_mr_info "evidence written to $_mr_output (gate: $_mr_gate, score: ${_mr_score:-n/a}%)"

# ---------- Register survivors ----------
# Only a story has a register. A write that fails fails the run: a survivor that
# reached nobody must not look like a completed run.
_mr_register_failed=0
if [ -n "$_mr_story" ] && [ "$_mr_survived" -gt 0 ]; then
  _mr_register="$SCRIPT_DIR/review-common/register-write.sh"
  _mr_severity="medium"
  [ "$_mr_priority" != "P0" ] || _mr_severity="critical"
  while IFS=$'\t' read -r _s_id _s_file _s_line _s_op; do
    "$_mr_register" add \
      --story "$_mr_story" \
      --defect "Surviving mutant $_s_id: $_s_file line $_s_line ($_s_op) was not caught by any covering test" \
      --type "test-debt" \
      --severity "$_mr_severity" \
      --gate "test-automate" \
      --dedup-key "mutant:$_s_id" >/dev/null \
      || { _mr_err "could not record survivor $_s_id in the findings register"; _mr_register_failed=1; }
  done < <(jq -r '.[] | select(.status == "survived") | [.mutant_id, .file, (.line | tostring), (.operator // "")] | @tsv' "$_mr_mutants_file")
fi

[ "$_mr_register_failed" -eq 0 ] || exit 1
exit 0
