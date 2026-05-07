#!/usr/bin/env bash
# adapters/shellcheck/run.sh — ADR-078 adapter contract for ShellCheck (E77-S11, FR-413).
#
# Contract: run --input <file-list> [--config <adapter-config>] [--output <fragment.json>]
#               [--runtime-profile {subprocess|container|network}] [--timeout {seconds}]
#
# Behavior:
#   1. Filter --input file-list to .sh / .bash files. Auto-skip cleanly when zero match
#      (exit 0, empty findings array, "No .sh files found" stderr log).
#   2. Invoke `shellcheck --format=json1 --shell=bash` against the matching file list.
#      json1 (added in shellcheck 0.7.0) wraps comments[] in a top-level object.
#   3. Severity calibration: the six critical rules
#         SC2086, SC2154, SC2046, SC2068, SC2155, SC2178
#      are emitted with severity=error (blocking=true). All other rules — including
#      the tool's own "error" level findings on advisory rules — are emitted with
#      severity=warning (blocking=false).
#   4. Emit a canonical analysis-results checks[] fragment on stdout (or to --output),
#      shape: {name, status, findings:[{rule, severity, file, line, message, blocking}, ...]}.
#
# Exit codes:
#   0  — adapter ran successfully (regardless of findings).
#   2  — adapter ran successfully but blocking findings present (matches the
#        plugin-frontmatter-validator pattern; verdict resolver may also derive
#        failed from findings[].blocking).
#   1  — adapter execution error (bad input, jq missing, etc.).
#   127 — shellcheck not on PATH (caught by tool-availability-probe before run.sh
#        in normal pipeline; surfaced here when run.sh is invoked directly).

set -euo pipefail
LC_ALL=C
export LC_ALL

# --- Critical-rule allowlist ----------------------------------------------
# The six rules per FR-413 / E77-S11 dev-notes. Anything in this set is emitted
# as severity=error (blocking=true); anything else as severity=warning (advisory).
CRITICAL_RULES_REGEX='^SC(2086|2154|2046|2068|2155|2178)$'

# --- Arg parsing ----------------------------------------------------------

INPUT=""
OUTPUT=""
# CONFIG / RUNTIME_PROFILE / TIMEOUT are accepted per the canonical flag-form
# interface (run-contract.md §1) but not consumed by this adapter; they are
# parsed only so callers can pass them uniformly. The shellcheck disables on
# the parse branches below silence SC2034 unused-variable warnings.

# shellcheck disable=SC2034  # CONFIG/RUNTIME_PROFILE/TIMEOUT parsed but unused (canonical flag-form interface).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/shellcheck/run.sh — ADR-078 contract entry for ShellCheck.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$INPUT" ] || { echo "run.sh: --input required" >&2; exit 1; }
[ -r "$INPUT" ] || { echo "run.sh: input file not readable: $INPUT" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required but not on PATH" >&2; exit 1; }

# --- Filter input to .sh / .bash files ------------------------------------

TARGETS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.sh|*.bash) TARGETS+=("$path") ;;
    *) ;;
  esac
done < "$INPUT"

# --- Auto-skip when no .sh files (AC6) ------------------------------------

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "run.sh: No .sh files found -- skipping shellcheck" >&2
  fragment="$(jq -nc \
    --arg name "shellcheck" \
    '{name: $name, status: "passed", findings: []}')"
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$fragment" > "$OUTPUT"
  else
    printf '%s\n' "$fragment"
  fi
  exit 0
fi

# --- Verify shellcheck on PATH --------------------------------------------

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "run.sh: shellcheck not found on PATH" >&2
  # Exit 127 = unavailable per E70-S2 AC10. The probe catches this before
  # invoking run.sh in the normal pipeline; this surfaces unavailability when
  # run.sh is invoked directly.
  exit 127
fi

# --- Invoke shellcheck ----------------------------------------------------
# --format=json1 (shellcheck 0.7.0+) wraps comments[] in a top-level object so
# the output is robust against empty results (which json mode emits as "[]").
# We capture the rc separately so a non-zero rc does not abort the script
# under `set -e` (shellcheck exits non-zero when findings are present).

raw=""
sc_rc=0
raw="$(shellcheck --format=json1 --shell=bash "${TARGETS[@]}" 2>&1)" || sc_rc=$?

# json1 output shape: {"comments": [{file,line,column,level,code,message,...}, ...]}
# When parse fails, surface as adapter error (not a clean run with findings).
if ! echo "$raw" | jq -e 'has("comments")' >/dev/null 2>&1; then
  # If shellcheck failed to produce parseable json1 (e.g. rc != 0 + non-JSON
  # stderr captured into raw), surface as a 1 exit so the probe maps it to
  # ran_and_errored. raw goes to stderr for the probe's error_detail capture.
  echo "run.sh: shellcheck did not produce parseable json1 output (rc=$sc_rc)" >&2
  printf '%s\n' "$raw" >&2
  exit 1
fi

# --- Severity calibration -------------------------------------------------
# Map raw shellcheck comments into canonical findings. The mapping uses jq with
# the critical-rules regex; rules matching => severity=error/blocking=true,
# else severity=warning/blocking=false.

findings_json="$(printf '%s' "$raw" | jq --arg crit "$CRITICAL_RULES_REGEX" '
  .comments
  | map(
      ("SC" + (.code | tostring)) as $rule
      | (if ($rule | test($crit)) then "error" else "warning" end) as $sev
      | {
          rule:     $rule,
          severity: $sev,
          file:     (.file // ""),
          line:     (.line // 0),
          message:  (.message // ""),
          blocking: ($sev == "error")
        }
    )
')"

blocking_count="$(jq '[.[] | select(.blocking == true)] | length' <<< "$findings_json")"

if [ "$blocking_count" -gt 0 ]; then
  status="failed"
else
  status="passed"
fi

# --- Emit canonical fragment ---------------------------------------------

fragment="$(jq -nc \
  --arg name "shellcheck" \
  --arg status "$status" \
  --argjson findings "$findings_json" \
  '{name: $name, status: $status, findings: $findings}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

# Exit code semantics: 0 on clean run; 2 when blocking findings present.
# Non-zero from shellcheck without parseable output already surfaced as exit 1
# above. shellcheck's normal "rc != 0 with parseable comments[]" case (i.e.
# findings present) collapses into our blocking-based exit logic.
if [ "$blocking_count" -gt 0 ]; then
  exit 2
fi
exit 0
