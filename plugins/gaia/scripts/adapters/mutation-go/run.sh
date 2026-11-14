#!/usr/bin/env bash
# run.sh — Go mutation adapter: single-mutant executor.
#
# Applies one patch inside the source dir, runs the test command, and
# reports the outcome as a JSON record.
#
# Usage:
#   run.sh --source-dir <dir> --patch-file <patch> --test-command <cmd> \
#          --output <json> --timeout <seconds>
#
# The source-dir MUST be inside a gaia-mutation- temp root. The test
# command runs with that directory as its working directory and as
# PROJECT_PATH, so it never touches the real worktree. A zero-byte
# patch file means "no mutation": the runner uses it to prove the
# covering tests are green before scoring.
#
# Outcome of a test command, by exit code:
#   0                     survived
#   1..125                killed (the tests failed)
#   142 (bound exceeded)  timeout
#   126, 127, 128+signal  error (the tests could not run)
#
# Test output is scrubbed before anything reads it. The adapter extracts
# Go test result lines (--- PASS: and --- FAIL:) into the contract
# output format.
#
# Exit codes:
#   0  Always (killed, survived, timeout — all valid outcomes)
#   1  Adapter error (invalid args, source-dir not in gaia-mutation- root)
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="run.sh"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"

_run_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_run_die() { local rc="$1"; shift; _run_err "$*"; exit "$rc"; }

# Source bound-exec for timeout handling
_run_bound_exec_path="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." >/dev/null && pwd)/lib/bound-exec.sh"
if [ -f "$_run_bound_exec_path" ]; then
  # shellcheck source=../../scripts/lib/bound-exec.sh
  . "$_run_bound_exec_path"
  _run_has_bound_exec=1
else
  _run_has_bound_exec=0
fi

# ---------- Arg parsing ----------
_run_source_dir=""
_run_patch_file=""
_run_test_command=""
_run_output=""
_run_timeout=60

while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir)    shift; _run_source_dir="${1:-}"; shift ;;
    --patch-file)    shift; _run_patch_file="${1:-}"; shift ;;
    --test-command)  shift; _run_test_command="${1:-}"; shift ;;
    --output)        shift; _run_output="${1:-}"; shift ;;
    --timeout)       shift; _run_timeout="${1:-}"; shift ;;
    --help|-h)       printf 'Usage: run.sh --source-dir <dir> --patch-file <patch> --test-command <cmd> --output <json> --timeout <secs>\n'; exit 0 ;;
    *)               _run_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$_run_source_dir" ]   || _run_die 1 "--source-dir is required"
[ -d "$_run_source_dir" ]   || _run_die 1 "--source-dir is not a directory"
[ -n "$_run_patch_file" ]   || _run_die 1 "--patch-file is required"
[ -f "$_run_patch_file" ]   || _run_die 1 "--patch-file not found"
[ -n "$_run_test_command" ] || _run_die 1 "--test-command is required"
[ -n "$_run_output" ]       || _run_die 1 "--output is required"
case "$_run_timeout" in
  ''|*[!0-9]*) _run_die 1 "--timeout must be a whole number of seconds" ;;
esac

# Absolute before the test command changes directory.
_run_absolute() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$(pwd -P)" "$1" ;;
  esac
}
_run_patch_file=$(_run_absolute "$_run_patch_file")
_run_output=$(_run_absolute "$_run_output")

# Containment: source-dir must be inside a gaia-mutation- temp root
_run_source_real=$(cd "$_run_source_dir" && pwd -P)
_run_source_dir="$_run_source_real"

_run_in_mutation_root=0
_run_check_dir="$_run_source_real"
while [ "$_run_check_dir" != "/" ]; do
  _run_check_base=$(basename "$_run_check_dir")
  case "$_run_check_base" in
    gaia-mutation-*) _run_in_mutation_root=1; break ;;
  esac
  _run_check_dir=$(dirname "$_run_check_dir")
done

if [ "$_run_in_mutation_root" -eq 0 ]; then
  _run_die 1 "source-dir must be inside a gaia-mutation- temp root"
fi

# ---------- Apply patch ----------
_run_mutant_file=""
_run_mutant_line=0
if [ -s "$_run_patch_file" ]; then
  if ! _run_patch_err=$(patch -p1 -f -N -d "$_run_source_dir" -i "$_run_patch_file" </dev/null 2>&1); then
    _run_err "patch failed to apply: $_run_patch_err"
    jq -n '{"status":"error","test_output":"patch failed to apply"}' > "$_run_output"
    exit 0
  fi

  # Extract mutant metadata from patch headers
  _run_mutant_file=$(awk '/^--- a\// { sub(/^--- a\//, ""); sub(/\t.*$/, ""); print; exit }' "$_run_patch_file")
  _run_mutant_line=$(awk '/^@@ -/ { sub(/^@@ -/, ""); sub(/[^0-9].*$/, ""); print; exit }' "$_run_patch_file")
fi

# ---------- Run tests ----------
_run_status="survived"

_run_work=$(mktemp -d "${TMPDIR:-/tmp}/mutation-go-run-XXXXXX")
trap 'rm -rf "$_run_work"' EXIT
_run_killers_file="$_run_work/killers"
_run_seen_file="$_run_work/seen"
_run_results_file="$_run_work/results"
_run_withheld=""
: > "$_run_killers_file"
: > "$_run_seen_file"
: > "$_run_results_file"

_run_scrubber="$SCRIPT_DIR/../../../skills/gaia-meeting/scripts/secret-scrubber.sh"
_RUN_SECRET_NAME='SECRET|TOKEN|PASSW(OR)?D|PASSPHRASE|CREDENTIAL|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY'

# Replaces the value of every secret-named environment variable.
_run_redact_env_values() {
  _RUN_NAMES="(${_RUN_SECRET_NAME}|_KEY\$)" awk '
    BEGIN {
      for (k in ENVIRON) {
        if (k == "_RUN_NAMES" || toupper(k) !~ ENVIRON["_RUN_NAMES"] || length(ENVIRON[k]) < 6) continue
        v = ENVIRON[k]
        for (i = ++n; i > 1 && length(vals[i - 1]) < length(v); i--) vals[i] = vals[i - 1]
        vals[i] = v
      }
    }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        done = ""
        while ((at = index(line, vals[i])) > 0) {
          done = done substr(line, 1, at - 1) "REDACTED-ENV-VALUE"
          line = substr(line, at + length(vals[i]))
        }
        line = done line
      }
      print line
    }
  ' "$1"
}

_run_scrub_output() {
  local raw="$1" clean="$2"
  if _run_redact_env_values "$raw" > "$clean.values" \
    && sed -E "s/([A-Za-z0-9_]*(${_RUN_SECRET_NAME})[A-Za-z0-9_]*=)[^[:space:]]+/\\1REDACTED-ENV-VALUE/Ig" "$clean.values" > "$clean.names" \
    && bash "$_run_scrubber" --in "$clean.names" --out "$clean"; then
    return 0
  fi
  rm -f "$clean"
  return 1
}

# Parse Go test -v output for test results.
# Go result lines: "--- PASS: TestName (0.00s)" and "--- FAIL: TestName (0.00s)"
_run_collect_go_results() {
  local src="$1"
  # Failing tests for killed_by
  sed -nE 's/^--- FAIL: ([^ ]+).*/\1/p' "$src" >> "$_run_killers_file"
  # All test results for seen
  sed -nE 's/^--- (PASS|FAIL): ([^ ]+).*/\2/p' "$src" >> "$_run_seen_file"
  # Full result lines
  sed -nE '/^--- (PASS|FAIL): /p' "$src" >> "$_run_results_file"
}

# Execute the test command inside the source dir
_run_exec_test() {
  local test_exit=0
  local test_out=""

  test_out=$(
    cd "$_run_source_dir" || exit 126
    PROJECT_PATH="$_run_source_dir"
    PROJECT_ROOT="$_run_source_dir"
    CLAUDE_PROJECT_ROOT="$_run_source_dir"
    export PROJECT_PATH PROJECT_ROOT CLAUDE_PROJECT_ROOT
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    if [ "$_run_has_bound_exec" -eq 1 ]; then
      bound_exec "$_run_timeout" -- bash -c "$_run_test_command" 2>&1
    else
      timeout "$_run_timeout" bash -c "$_run_test_command" 2>&1
    fi
  ) || test_exit=$?

  # Scrub first, so nothing below can see or cut through a secret.
  local raw_file="$_run_work/raw" clean_file="$_run_work/clean"
  printf '%s\n' "$test_out" > "$raw_file"
  if _run_scrub_output "$raw_file" "$clean_file"; then
    _run_collect_go_results "$clean_file"
  else
    _run_err "could not scrub the test output; withholding it"
    _run_withheld="(test output withheld: it could not be scrubbed)"
  fi

  case "$test_exit" in
    0)       ;;
    142|124) _run_status="timeout" ;;
    126|127) _run_status="error" ;;
    *)
      if [ "$test_exit" -gt 128 ]; then
        _run_status="error"
      else
        _run_status="killed"
      fi
      ;;
  esac
  return 0
}

_run_exec_test

# ---------- Build output record ----------
if [ -n "$_run_withheld" ]; then
  _run_test_output="$_run_withheld"
elif [ "$(wc -c < "$_run_results_file")" -gt 4096 ]; then
  _run_test_output=$(tail -c 4096 "$_run_results_file" | sed 1d)
else
  _run_test_output=$(cat "$_run_results_file")
fi

_run_kb_json="$_run_work/killed_by.json"
jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$_run_killers_file" > "$_run_kb_json"
_run_tests_json="$_run_work/tests.json"
jq -R -s 'split("\n") | map(select(length > 0)) | reduce .[] as $t ([]; if index($t) then . else . + [$t] end)' "$_run_seen_file" > "$_run_tests_json"

jq -n \
  --arg status "$_run_status" \
  --arg test_output "$_run_test_output" \
  --arg file "${_run_mutant_file:-}" \
  --argjson line "${_run_mutant_line:-0}" \
  --slurpfile killed_by "$_run_kb_json" \
  --slurpfile tests "$_run_tests_json" \
  '{
    "status": $status,
    "test_output": $test_output,
    "file": $file,
    "line": $line,
    "killed_by": $killed_by[0],
    "tests": $tests[0]
  }' > "$_run_output"

exit 0
