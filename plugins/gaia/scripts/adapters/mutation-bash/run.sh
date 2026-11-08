#!/usr/bin/env bash
# run.sh — bash mutation adapter: single-mutant executor.
#
# Applies one patch inside the source dir, runs the test command under
# each available bash interpreter (5.x and optionally 3.2), and reports
# the outcome as a JSON record.
#
# Usage:
#   run.sh --source-dir <dir> --patch-file <patch> --test-command <cmd> \
#          --output <json> --timeout <seconds>
#
# The source-dir MUST be inside a gaia-mutation- temp root. The test command
# runs with that directory as its working directory and as PROJECT_PATH, so it
# never touches the real worktree. A zero-byte patch file means "no mutation":
# the runner uses it to prove the covering tests are green before scoring.
#
# Outcome of a test command, by exit code:
#   0                     survived
#   1..125                killed (the tests failed)
#   142 (bound exceeded)  timeout
#   126, 127, 128+signal  error (the tests could not run, so nothing was proved)
#
# Interpreters:
#   - Bash 5: from PATH or $GAIA_MUTATION_BASH5
#   - Bash 3.2: /bin/bash when it reports 3.x, or $GAIA_MUTATION_BASH32
#   Both are optional but at least one must be available.
#   A PATH shim directory is created inside the source dir so scripts
#   started via #!/usr/bin/env bash use the selected interpreter.
#
# Test output is scrubbed before anything reads it: values of secret-named
# environment variables, NAME=value pairs with a secret-looking name, then the
# shared secret-pattern scrubber. If scrubbing fails the output is withheld.
# test_output keeps only test result lines (`ok` / `not ok`, the number and the
# test name) from that scrubbed text; nothing else a test prints is stored.
#
# Exit codes:
#   0  Always (killed, survived, timeout — all are valid outcomes)
#   1  Adapter error (invalid args, source-dir not in gaia-mutation- root)
#
# POSIX discipline: bash 3.2, no local -A, no mapfile. # lint-pack:allow bash4-constructs — comment documents discipline, not actual usage

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
_run_timeout=30

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
# Walk up to check if we're in a gaia-mutation- directory
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

# ---------- Discover interpreters ----------
_run_interpreters=()
_run_bash5=""
_run_bash32=""

# Bash 5
if [ -n "${GAIA_MUTATION_BASH5:-}" ] && [ -x "${GAIA_MUTATION_BASH5:-}" ]; then
  _run_bash5="$GAIA_MUTATION_BASH5"
else
  # Find bash 5 on PATH
  candidate_path=$(command -v bash 2>/dev/null || true)
  if [ -n "$candidate_path" ]; then
    ver=$("$candidate_path" --version 2>/dev/null | head -1 | sed -n 's/.*version \([0-9]*\).*/\1/p')
    if [ "${ver:-0}" -ge 5 ]; then
      _run_bash5="$candidate_path"
    fi
  fi
fi

# Bash 3.2
if [ -n "${GAIA_MUTATION_BASH32:-}" ] && [ -x "${GAIA_MUTATION_BASH32:-}" ]; then
  _run_bash32="$GAIA_MUTATION_BASH32"
elif [ -x /bin/bash ]; then
  ver=$(/bin/bash --version 2>/dev/null | head -1 | sed -n 's/.*version \([0-9]*\).*/\1/p')
  if [ "${ver:-0}" -eq 3 ]; then
    _run_bash32="/bin/bash"
  fi
fi

if [ -z "$_run_bash5" ] && [ -z "$_run_bash32" ]; then
  _run_die 1 "no bash interpreter found (need bash 5 or bash 3.2)"
fi

# ---------- Apply patch ----------
_run_mutant_file=""
_run_mutant_line=0
if [ -s "$_run_patch_file" ]; then
  # -f and -N keep patch from prompting; stdin is closed for the same reason.
  if ! _run_patch_err=$(patch -p1 -f -N -d "$_run_source_dir" -i "$_run_patch_file" </dev/null 2>&1); then
    _run_err "patch failed to apply: $_run_patch_err"
    jq -n '{"status":"error","test_output":"patch failed to apply"}' > "$_run_output"
    exit 0
  fi

  # ---------- Extract mutant metadata from patch ----------
  _run_mutant_file=$(awk '/^--- a\// { sub(/^--- a\//, ""); sub(/\t.*$/, ""); print; exit }' "$_run_patch_file")
  _run_mutant_line=$(awk '/^@@ -/ { sub(/^@@ -/, ""); sub(/[^0-9].*$/, ""); print; exit }' "$_run_patch_file")
fi

# ---------- Run tests ----------
_run_status="survived"
_run_interpreter_versions=()

_run_work=$(mktemp -d "${TMPDIR:-/tmp}/mutation-run-XXXXXX")
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

# Replaces the value of every secret-named environment variable, longest first
# so a value inside another cannot leave part of the longer one behind. Values
# under six characters are too likely to be ordinary words in the output.
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

# Reads the whole output: a test's name must not depend on where it ran. A result
# line is `ok` or `not ok`, a test number and a name; other text is not one.
_RUN_DIRECTIVE='s/ # ([Ss][Kk][Ii][Pp]|[Tt][Oo][Dd][Oo]|in [0-9]+ms).*$//'
_run_collect_tap() {
  local names="s/^(not ok|ok) [0-9]+ //; $_RUN_DIRECTIVE; p;"
  sed -nE "/^not ok [0-9]+ /{$names}" "$1" >> "$_run_killers_file"
  sed -nE "/^(not ok|ok) [0-9]+ /{$names}" "$1" >> "$_run_seen_file"
  sed -nE "/^(not ok|ok) [0-9]+( |\$)/{$_RUN_DIRECTIVE; p;}" "$1" >> "$_run_results_file"
}

_run_exec_test() {
  local interpreter="$1"
  local interp_version
  interp_version=$("$interpreter" --version 2>/dev/null | head -1 | sed -n 's/.*version \([^ ]*\).*/\1/p' || echo "unknown")
  _run_interpreter_versions+=("$interp_version")

  # Create a PATH shim so #!/usr/bin/env bash resolves to our interpreter
  local shim_dir="$_run_source_dir/.mutation-shim"
  mkdir -p "$shim_dir"
  ln -sf "$interpreter" "$shim_dir/bash"

  local test_exit=0
  local test_out=""

  # The subshell scopes the directory and the environment to the test command:
  # it must see the copy as its project, and git must not be pointed anywhere.
  test_out=$(
    cd "$_run_source_dir" || exit 126
    PATH="$shim_dir:$PATH"
    PROJECT_PATH="$_run_source_dir"
    PROJECT_ROOT="$_run_source_dir"
    CLAUDE_PROJECT_ROOT="$_run_source_dir"
    export PATH PROJECT_PATH PROJECT_ROOT CLAUDE_PROJECT_ROOT
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
    _run_collect_tap "$clean_file"
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

# Run under bash 5
if [ -n "$_run_bash5" ]; then
  _run_exec_test "$_run_bash5"
fi

# Run under bash 3.2 (only if not already killed or timed out, and available)
if [ "$_run_status" = "survived" ] && [ -n "$_run_bash32" ]; then
  _run_exec_test "$_run_bash32"
fi

# ---------- Build output record ----------
# Stored result lines are capped at the newest whole lines that fit 4 KB; names
# in killed_by and tests are complete regardless. The cut may land inside a line,
# so the first line of a cut tail is dropped.
if [ -n "$_run_withheld" ]; then
  _run_test_output="$_run_withheld"
elif [ "$(wc -c < "$_run_results_file")" -gt 4096 ]; then
  _run_test_output=$(tail -c 4096 "$_run_results_file" | sed 1d)
else
  _run_test_output=$(cat "$_run_results_file")
fi

# Every test name, de-duplicated across interpreters. These go through files:
# one argument has a length limit on Linux.
_run_kb_json="$_run_work/killed_by.json"
jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$_run_killers_file" > "$_run_kb_json"
_run_tests_json="$_run_work/tests.json"
jq -R -s 'split("\n") | map(select(length > 0)) | reduce .[] as $t ([]; if index($t) then . else . + [$t] end)' "$_run_seen_file" > "$_run_tests_json"

# Build interpreters array
_run_interp_json="[]"
for iv in "${_run_interpreter_versions[@]+"${_run_interpreter_versions[@]}"}"; do
  _run_interp_json=$(printf '%s' "$_run_interp_json" | jq --arg v "$iv" '. + [$v]')
done

jq -n \
  --arg status "$_run_status" \
  --arg test_output "$_run_test_output" \
  --arg file "${_run_mutant_file:-}" \
  --argjson line "${_run_mutant_line:-0}" \
  --slurpfile killed_by "$_run_kb_json" \
  --slurpfile tests "$_run_tests_json" \
  --argjson interpreters "$_run_interp_json" \
  '{
    "status": $status,
    "test_output": $test_output,
    "file": $file,
    "line": $line,
    "killed_by": $killed_by[0],
    "tests": $tests[0],
    "interpreters": $interpreters
  }' > "$_run_output"

# Cleanup shim
rm -rf "$_run_source_dir/.mutation-shim"

exit 0
