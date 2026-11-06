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
    if ! command -v yq >/dev/null 2>&1; then
      printf 'Thresholds: unknown (yq not installed)\n'
    else
      local_thresholds=$(yq -o=json '.test_execution.mutation_thresholds // empty' "$_mr_config" 2>/dev/null || true)
      if [ -z "$local_thresholds" ] || [ "$local_thresholds" = "null" ]; then
        printf 'Mutation testing is off (no mutation_thresholds configured)\n'
      else
        printf 'Thresholds: %s\n' "$local_thresholds"
        # Show defaults
        _p0=$(printf '%s' "$local_thresholds" | jq -r '.P0 // empty' 2>/dev/null || true)
        _p1=$(printf '%s' "$local_thresholds" | jq -r '.P1 // empty' 2>/dev/null || true)
        _p2=$(printf '%s' "$local_thresholds" | jq -r '.P2 // empty' 2>/dev/null || true)
        _p3=$(printf '%s' "$local_thresholds" | jq -r '.P3 // empty' 2>/dev/null || true)
        printf 'Effective: P0=%s P1=%s P2=%s P3=%s\n' \
          "${_p0:-$_MR_DEFAULT_P0}" "${_p1:-$_MR_DEFAULT_P1}" \
          "${_p2:-$_MR_DEFAULT_P2}" "${_p3:-$_MR_DEFAULT_P3}"
      fi
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

# ---------- Resolve story metadata ----------
if [ -n "$_mr_story" ]; then
  # Use resolve-story-file.sh if available
  if [ -x "$SCRIPT_DIR/resolve-story-file.sh" ]; then
    _mr_story_file=$("$SCRIPT_DIR/resolve-story-file.sh" "$_mr_story" 2>/dev/null || true)
  fi
  if [ -z "${_mr_story_file:-}" ]; then
    # Fallback: search for story file
    _mr_story_file=$(find "$_mr_worktree" -path "*/${_mr_story}-*/story.md" -o -path "*/${_mr_story}*/story.md" 2>/dev/null | head -1 || true)
  fi
  if [ -n "${_mr_story_file:-}" ] && [ -f "$_mr_story_file" ]; then
    # Read priority from frontmatter
    if [ -z "$_mr_priority" ]; then
      _mr_priority=$(sed -n 's/^priority: *"\{0,1\}\(P[0-3]\)"\{0,1\} *$/\1/p' "$_mr_story_file" | head -1)
    fi
    # Read File List section for source and test files
    if [ -z "$_mr_files_from" ] && [ -z "$_mr_tests_from" ]; then
      _mr_auto_files=$(mktemp "${TMPDIR:-/tmp}/gaia-mr-files-XXXXXX")
      _mr_auto_tests=$(mktemp "${TMPDIR:-/tmp}/gaia-mr-tests-XXXXXX")
      _mr_in_filelist=0
      while IFS= read -r line; do
        if printf '%s' "$line" | grep -q '^## File List'; then
          _mr_in_filelist=1
          continue
        fi
        if [ "$_mr_in_filelist" -eq 1 ] && printf '%s' "$line" | grep -q '^## '; then
          break
        fi
        if [ "$_mr_in_filelist" -eq 1 ]; then
          # Extract path from markdown table or list
          fpath=$(printf '%s' "$line" | sed -n 's/.*`\([^`]*\)`.*/\1/p')
          if [ -n "$fpath" ]; then
            if printf '%s' "$fpath" | grep -qE '\.(bats|test\.|spec\.)'; then
              printf '%s\n' "$fpath" >> "$_mr_auto_tests"
            else
              printf '%s\n' "$fpath" >> "$_mr_auto_files"
            fi
          fi
        fi
      done < "$_mr_story_file"
      if [ -s "$_mr_auto_files" ]; then
        _mr_files_from="$_mr_auto_files"
      else
        rm -f "$_mr_auto_files"
      fi
      if [ -s "$_mr_auto_tests" ]; then
        _mr_tests_from="$_mr_auto_tests"
      else
        rm -f "$_mr_auto_tests"
      fi
    fi
  fi
fi

[ -n "$_mr_files_from" ] || _mr_die 1 "--files-from is required (or --story with a File List)"
[ -f "$_mr_files_from" ] || _mr_die 1 "--files-from '$_mr_files_from' not found"
[ -n "$_mr_priority" ]   || _mr_priority="P2"

# Default patch dir
if [ -z "$_mr_patch_dir" ]; then
  _mr_patch_dir="$(dirname "$_mr_output")/$(basename "$_mr_output" .json)-mutants"
fi
mkdir -p "$_mr_patch_dir"

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

# ---------- Resolve thresholds ----------
_mr_thresholds_configured=0
_mr_th_p0=""
_mr_th_p1=""
_mr_th_p2=""
_mr_th_p3=""

_mr_resolve_thresholds() {
  if [ -n "$_mr_thresholds" ]; then
    _mr_thresholds_configured=1
    _mr_th_p0=$(printf '%s' "$_mr_thresholds" | jq -r '.P0 // empty' 2>/dev/null || true)
    _mr_th_p1=$(printf '%s' "$_mr_thresholds" | jq -r '.P1 // empty' 2>/dev/null || true)
    _mr_th_p2=$(printf '%s' "$_mr_thresholds" | jq -r '.P2 // empty' 2>/dev/null || true)
    _mr_th_p3=$(printf '%s' "$_mr_thresholds" | jq -r '.P3 // empty' 2>/dev/null || true)
  elif [ -n "$_mr_config" ] && [ -f "$_mr_config" ]; then
    # Check if mutation_thresholds key is present in the config file
    local _mt_key_present=0
    if grep -q 'mutation_thresholds' "$_mr_config" 2>/dev/null; then
      _mt_key_present=1
    fi

    if ! command -v yq >/dev/null 2>&1; then
      if [ "$_mt_key_present" -eq 1 ]; then
        _mr_die 1 "yq is required to read mutation_thresholds from project config but is not installed"
      fi
      # Key not present and yq missing: mutation testing is off — no error
    else
      local raw
      raw=$(yq -o=json '.test_execution.mutation_thresholds // empty' "$_mr_config" 2>/dev/null) || {
        if [ "$_mt_key_present" -eq 1 ]; then
          _mr_die 1 "yq failed to read mutation_thresholds — is yq installed and functional?"
        fi
        raw=""
      }
      if [ -n "$raw" ] && [ "$raw" != "null" ]; then
        _mr_thresholds_configured=1
        _mr_thresholds="$raw"
        _mr_th_p0=$(printf '%s' "$raw" | jq -r '.P0 // empty' 2>/dev/null || true)
        _mr_th_p1=$(printf '%s' "$raw" | jq -r '.P1 // empty' 2>/dev/null || true)
        _mr_th_p2=$(printf '%s' "$raw" | jq -r '.P2 // empty' 2>/dev/null || true)
        _mr_th_p3=$(printf '%s' "$raw" | jq -r '.P3 // empty' 2>/dev/null || true)
      elif [ "$_mt_key_present" -eq 1 ]; then
        # Key is present but yq returned empty — yq may be broken
        _mr_die 1 "yq could not read mutation_thresholds from the config — verify yq is functional"
      fi
    fi
  fi
}
_mr_resolve_thresholds

# ---------- Adapter discovery ----------
# Find the mutation adapter that covers a given file extension.
_mr_find_adapter() {
  local file="$1"
  local ext="${file##*.}"

  for adapter_dir in "$SCRIPT_DIR"/adapters/mutation-*/; do
    [ -d "$adapter_dir" ] || continue
    local manifest="$adapter_dir/mutation-adapter.json"
    [ -f "$manifest" ] || continue
    if jq -e --arg ext ".$ext" '.["file-extensions"] | map(. == $ext) | any' "$manifest" >/dev/null 2>&1; then
      printf '%s\n' "$adapter_dir"
      return 0
    fi
  done
  return 1
}

# ---------- Covering-test selection ----------
# For a given source file, find tests that reference it.
_mr_find_covering_tests() {
  local source_file="$1"
  local tests_file="$2"
  local source_basename
  source_basename=$(basename "$source_file")
  # Strip extension for matching
  local source_stem="${source_basename%.*}"

  local covering=()
  while IFS= read -r test_path; do
    [ -n "$test_path" ] || continue
    local full_test="$_mr_worktree/$test_path"
    [ -f "$full_test" ] || continue
    # Check if the test file references the source file (by basename or stem)
    if grep -qF "$source_basename" "$full_test" 2>/dev/null || \
       grep -qF "$source_stem" "$full_test" 2>/dev/null; then
      covering+=("$test_path")
    fi
  done < "$tests_file"

  if [ ${#covering[@]} -eq 0 ]; then
    return 1
  fi

  printf '%s\n' "${covering[@]}"
  return 0
}

# ---------- Register cleanup ----------
mutation_register_cleanup

# ---------- Pre-run manifest ----------
_mr_info "computing pre-run worktree manifest"
_mr_manifest_before=$(mktemp "${TMPDIR:-/tmp}/gaia-mr-manifest-XXXXXX")
mutation_compute_manifest "$_mr_worktree" "$_mr_manifest_before"

# ---------- Generate mutants ----------
_mr_info "discovering adapters and generating mutants"

_mr_all_records=()
_mr_mutant_count=0
_mr_killed=0
_mr_survived=0
_mr_timeout=0
_mr_error=0
_mr_truncated="false"
_mr_unmutated_files=()

# Temporary results directory
_mr_results_dir=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mr-results-XXXXXX")
_MI_COPIES+=("$_mr_results_dir")

while IFS= read -r source_file; do
  [ -n "$source_file" ] || continue

  # Find adapter
  adapter_dir=$(_mr_find_adapter "$source_file" 2>/dev/null || true)
  if [ -z "$adapter_dir" ]; then
    _mr_unmutated_files+=("$source_file")
    continue
  fi

  # Generate mutants
  generate_script="$adapter_dir/generate.sh"
  [ -x "$generate_script" ] || { _mr_unmutated_files+=("$source_file"); continue; }

  gen_out=$(mktemp -d "${TMPDIR:-/tmp}/gaia-mutation-gen-XXXXXX")
  _MI_COPIES+=("$gen_out")

  # Create a single-file list for the generator
  gen_files=$(mktemp "${TMPDIR:-/tmp}/gaia-mr-genfiles-XXXXXX")
  printf '%s\n' "$source_file" > "$gen_files"

  "$generate_script" --source-dir "$_mr_worktree" --files-from "$gen_files" --out-dir "$gen_out" 2>/dev/null || {
    _mr_info "generator failed for $source_file (adapter: $(basename "$adapter_dir"))"
    rm -f "$gen_files"
    continue
  }
  rm -f "$gen_files"

  # Read generated mutants (patch files or index.json)
  mutant_files=()
  if [ -f "$gen_out/index.json" ]; then
    # Read mutant list from index
    while IFS= read -r mfile; do
      [ -n "$mfile" ] && mutant_files+=("$gen_out/$mfile")
    done < <(jq -r '.[].patch_file // empty' "$gen_out/index.json" 2>/dev/null || true)
  fi
  # Also pick up loose .patch files
  while IFS= read -r pfile; do
    [ -n "$pfile" ] || continue
    # Skip if already in list
    local_skip=0
    for existing in "${mutant_files[@]+"${mutant_files[@]}"}"; do
      [ "$existing" = "$pfile" ] && { local_skip=1; break; }
    done
    [ "$local_skip" -eq 0 ] && mutant_files+=("$pfile")
  done < <(find "$gen_out" -name '*.patch' -type f 2>/dev/null | LC_ALL=C sort)

  # Copy patches to patch-dir
  for pf in "${mutant_files[@]+"${mutant_files[@]}"}"; do
    cp "$pf" "$_mr_patch_dir/" 2>/dev/null || true
  done

  # Find covering tests
  if [ -n "${_mr_tests_from:-}" ] && [ -f "$_mr_tests_from" ]; then
    covering_tests=$(_mr_find_covering_tests "$source_file" "$_mr_tests_from" || true)
  else
    covering_tests=""
  fi

  # Run each mutant
  run_script="$adapter_dir/run.sh"
  [ -x "$run_script" ] || { _mr_info "run.sh not executable in $(basename "$adapter_dir")"; continue; }

  manifest_file="$adapter_dir/mutation-adapter.json"
  default_timeout=30
  if [ -f "$manifest_file" ]; then
    default_timeout=$(jq -r '.["default-timeout-seconds"] // 30' "$manifest_file" 2>/dev/null || echo 30)
  fi

  # Process mutants (with parallelism)
  _mr_active_pids=()
  for patch_file in "${mutant_files[@]+"${mutant_files[@]}"}"; do
    [ -f "$patch_file" ] || continue

    # Check mutant cap
    if [ "$_mr_mutant_count" -ge "$_MR_MAX_MUTANTS" ]; then
      _mr_truncated="true"
      break
    fi

    _mr_mutant_count=$((_mr_mutant_count + 1))
    mutant_id="mutant-${_mr_mutant_count}"

    # Wait if at job limit
    while [ ${#_mr_active_pids[@]} -ge "$_mr_jobs" ]; do
      # Wait for the oldest pid
      local_oldest="${_mr_active_pids[0]}"
      wait "$local_oldest" 2>/dev/null || true
      _mr_active_pids=("${_mr_active_pids[@]:1}")
    done

    # Result file for this mutant
    result_file="$_mr_results_dir/${mutant_id}.json"

    # Run in background
    (
      # Create throwaway copy
      copy_dir=$(mutation_create_copy "$_mr_worktree") || {
        # Containment error — record as error
        jq -n --arg mid "$mutant_id" --arg f "$source_file" \
          '{"mutant_id":$mid,"file":$f,"status":"error","test_output":"containment error"}' > "$result_file"
        exit 0
      }

      # Compose test command
      test_cmd=""
      if [ -n "$covering_tests" ]; then
        # Build a command that runs each covering test in sequence.
        # Use bash to execute each test file (works for both plain
        # shell tests and bats files when bats is the interpreter).
        test_args=""
        while IFS= read -r tfile; do
          [ -n "$tfile" ] || continue
          quoted=$(printf '%q' "$copy_dir/$tfile")
          if [ -n "$test_args" ]; then
            test_args="$test_args && bash $quoted"
          else
            test_args="bash $quoted"
          fi
        done <<< "$covering_tests"
        test_cmd="$test_args"
      fi

      # Run adapter
      "$run_script" \
        --source-dir "$copy_dir" \
        --patch-file "$patch_file" \
        --test-command "${test_cmd:-true}" \
        --output "$result_file" \
        --timeout "$default_timeout" 2>/dev/null || {
          # Adapter error
          if [ ! -f "$result_file" ]; then
            jq -n --arg mid "$mutant_id" --arg f "$source_file" \
              '{"mutant_id":$mid,"file":$f,"status":"error","test_output":"adapter crashed"}' > "$result_file"
          fi
        }

      # Ensure mutant_id is set in result
      if [ -f "$result_file" ]; then
        local_content=$(cat "$result_file")
        local_has_id=$(printf '%s' "$local_content" | jq -r '.mutant_id // empty' 2>/dev/null || true)
        if [ -z "$local_has_id" ]; then
          printf '%s' "$local_content" | jq --arg mid "$mutant_id" '. + {"mutant_id":$mid}' > "${result_file}.tmp" && mv "${result_file}.tmp" "$result_file"
        fi
      fi

      # Cleanup copy
      rm -rf "$copy_dir"
    ) &
    _mr_active_pids+=($!)

    # Handle no-coverage case
    if [ -z "$covering_tests" ]; then
      # Wait for the last PID (bash 3.2 compatible — no negative indexing)
      _mr_last_idx=$(( ${#_mr_active_pids[@]} - 1 ))
      wait "${_mr_active_pids[$_mr_last_idx]}" 2>/dev/null || true
      unset "_mr_active_pids[$_mr_last_idx]"
      # Overwrite result with no-coverage
      jq -n --arg mid "$mutant_id" --arg f "$source_file" \
        '{"mutant_id":$mid,"file":$f,"status":"survived","no_coverage":true,"test_output":""}' > "$_mr_results_dir/${mutant_id}.json"
    fi
  done

  # Wait for remaining pids
  for pid in "${_mr_active_pids[@]+"${_mr_active_pids[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done
done < "$_mr_files_from"

# ---------- Post-run manifest ----------
_mr_info "verifying post-run worktree integrity"
if ! mutation_verify_manifest "$_mr_worktree" "$_mr_manifest_before"; then
  rm -f "$_mr_manifest_before"
  _mr_die 2 "worktree_mutated"
fi
rm -f "$_mr_manifest_before"

# ---------- Aggregate results ----------
_mr_info "aggregating results"

# Count outcomes
for rfile in "$_mr_results_dir"/mutant-*.json; do
  [ -f "$rfile" ] || continue
  status=$(jq -r '.status // "error"' "$rfile" 2>/dev/null || echo "error")
  case "$status" in
    killed)   _mr_killed=$((_mr_killed + 1)) ;;
    survived) _mr_survived=$((_mr_survived + 1)) ;;
    timeout)  _mr_timeout=$((_mr_timeout + 1)) ;;
    error)    _mr_error=$((_mr_error + 1)) ;;
  esac
done

# Compute score: (killed + timeout) / (killed + timeout + survived)
# Errors excluded. No-coverage mutants count as survived.
_mr_denom=$((_mr_killed + _mr_timeout + _mr_survived))
if [ "$_mr_denom" -gt 0 ]; then
  _mr_score=$(( (_mr_killed + _mr_timeout) * 100 / _mr_denom ))
else
  _mr_score=""
fi

# ---------- Compute gate ----------
_mr_gate="not_configured"

if [ "$_mr_thresholds_configured" -eq 1 ]; then
  if [ "$_mr_mutant_count" -eq 0 ] || { [ "$_mr_mutant_count" -gt 0 ] && [ "$_mr_denom" -eq 0 ]; }; then
    # All mutants errored or no mutants generated
    _mr_gate="errored"
  else
    case "$_mr_priority" in
      P0)
        _mr_threshold="${_mr_th_p0:-$_MR_DEFAULT_P0}"
        if [ "$_mr_score" -lt "$_mr_threshold" ]; then
          _mr_gate="failed"
        else
          _mr_gate="passed"
        fi
        ;;
      P1)
        _mr_threshold="${_mr_th_p1:-$_MR_DEFAULT_P1}"
        if [ "$_mr_score" -lt "$_mr_threshold" ]; then
          _mr_gate="failed"
        else
          _mr_gate="passed"
        fi
        ;;
      P2)
        _mr_gate="advisory"
        _mr_info "P2 story: mutation score ${_mr_score}% (advisory, no gate)"
        ;;
      P3)
        _mr_gate="advisory"
        _mr_info "P3 story: mutation score ${_mr_score}% (advisory, no gate)"
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

# Build mutants array
_mr_mutants_json="[]"
for rfile in "$_mr_results_dir"/mutant-*.json; do
  [ -f "$rfile" ] || continue
  _mr_mutants_json=$(printf '%s' "$_mr_mutants_json" | jq --slurpfile rec "$rfile" '. + $rec')
done

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

# Score as JSON value
_mr_score_json="null"
if [ -n "$_mr_score" ]; then
  _mr_score_json="$_mr_score"
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
  --argjson truncated "$_mr_truncated" \
  --argjson mutants "$_mr_mutants_json" \
  --argjson unmutated_files "$_mr_unmutated_json" \
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
    mutants: $mutants,
    unmutated_files: $unmutated_files
  }' > "$_mr_output"

_mr_info "evidence written to $_mr_output (gate: $_mr_gate, score: ${_mr_score:-n/a}%)"

# ---------- Register survivors ----------
if [ "$_mr_survived" -gt 0 ] && command -v "$SCRIPT_DIR/review-common/register-write.sh" >/dev/null 2>&1; then
  _mr_register="$SCRIPT_DIR/review-common/register-write.sh"
  for rfile in "$_mr_results_dir"/mutant-*.json; do
    [ -f "$rfile" ] || continue
    local_status=$(jq -r '.status // ""' "$rfile" 2>/dev/null || true)
    [ "$local_status" = "survived" ] || continue

    local_mid=$(jq -r '.mutant_id // ""' "$rfile" 2>/dev/null || true)
    [ -n "$local_mid" ] || continue

    # Severity based on priority
    local_severity="medium"
    if [ "$_mr_priority" = "P0" ]; then
      local_severity="critical"
    fi

    # Register via register-write.sh add with dedup key
    "$_mr_register" add \
      --gate "test-automate" \
      --type "test-debt" \
      --severity "$local_severity" \
      --dedup-key "mutant:${local_mid}" \
      --message "Surviving mutant: $local_mid" \
      --story-key "${_mr_story:-unknown}" \
      2>/dev/null || _mr_info "register-write.sh failed for $local_mid"
  done
fi

# Exit based on gate
case "$_mr_gate" in
  failed)  exit 0 ;;   # Evidence written; gate failed but run completed
  errored) exit 0 ;;   # Evidence written; errors recorded
  *)       exit 0 ;;   # passed, advisory, not_configured
esac
