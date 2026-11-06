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
# The source-dir MUST be inside a gaia-mutation- temp root.
#
# Interpreters:
#   - Bash 5: from PATH or $GAIA_MUTATION_BASH5
#   - Bash 3.2: /bin/bash when it reports 3.x, or $GAIA_MUTATION_BASH32
#   Both are optional but at least one must be available.
#   A PATH shim directory is created inside the source dir so scripts
#   started via #!/usr/bin/env bash use the selected interpreter.
#
# Exit codes:
#   0  Always (killed, survived, timeout — all are valid outcomes)
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

# Containment: source-dir must be inside a gaia-mutation- temp root
_run_source_real=$(cd "$_run_source_dir" && pwd -P)
_run_source_base=$(basename "$_run_source_real")
_run_source_parent=$(dirname "$_run_source_real")
_run_parent_base=$(basename "$_run_source_parent")

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
if ! patch -p1 -d "$_run_source_dir" < "$_run_patch_file" >/dev/null 2>&1; then
  # Patch failed to apply
  jq -n \
    --arg status "error" \
    --arg test_output "patch failed to apply" \
    '{"status":$status,"test_output":$test_output}' > "$_run_output"
  exit 0
fi

# ---------- Extract mutant metadata from patch ----------
_run_mutant_file=$(sed -n 's|^--- a/||p' "$_run_patch_file" | head -1)
_run_mutant_line=$(sed -n 's/^@@ -\([0-9]*\).*/\1/p' "$_run_patch_file" | head -1)

# ---------- Run tests ----------
_run_status="survived"
_run_test_output=""
_run_killed_by=()
_run_interpreter_versions=()

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

  if [ "$_run_has_bound_exec" -eq 1 ]; then
    test_out=$(PATH="$shim_dir:$PATH" bound_exec "$_run_timeout" -- bash -c "$_run_test_command" 2>&1) || test_exit=$?
  else
    test_out=$(PATH="$shim_dir:$PATH" timeout "$_run_timeout" bash -c "$_run_test_command" 2>&1) || test_exit=$?
  fi

  # Truncate output to last 4KB
  if [ ${#test_out} -gt 4096 ]; then
    test_out="...(truncated)...
$(printf '%s' "$test_out" | tail -c 4096)"
  fi

  _run_test_output="${_run_test_output}${test_out}"

  if [ "$test_exit" -eq 142 ]; then
    _run_status="timeout"
    return 0
  fi

  if [ "$test_exit" -ne 0 ]; then
    _run_status="killed"
    # Parse killed_by from bats TAP output
    while IFS= read -r tapline; do
      case "$tapline" in
        'not ok'*)
          test_name=$(printf '%s' "$tapline" | sed 's/^not ok [0-9]* //')
          _run_killed_by+=("$test_name")
          ;;
      esac
    done <<< "$test_out"
    return 0
  fi

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
# Build killed_by array
_run_kb_json="[]"
for kb in "${_run_killed_by[@]+"${_run_killed_by[@]}"}"; do
  _run_kb_json=$(printf '%s' "$_run_kb_json" | jq --arg t "$kb" '. + [$t]')
done

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
  --argjson killed_by "$_run_kb_json" \
  --argjson interpreters "$_run_interp_json" \
  '{
    "status": $status,
    "test_output": $test_output,
    "file": $file,
    "line": $line,
    "killed_by": $killed_by,
    "interpreters": $interpreters
  }' > "$_run_output"

# Cleanup shim
rm -rf "$_run_source_dir/.mutation-shim"

exit 0
