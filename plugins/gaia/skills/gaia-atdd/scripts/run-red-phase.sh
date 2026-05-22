#!/usr/bin/env bash
# run-red-phase.sh — /gaia-atdd Step 5b red-phase execution (E46-S3)
#
# Optional red-phase test runner invoked after Step 5 (Validation) when the
# user opts in at the "Run generated tests now to confirm red phase? [y/N]"
# prompt. Detects the configured runner via the Test Execution Bridge
# (ADR-026 / test-environment.yaml). When the bridge is disabled or the
# config is missing, the runner short-circuits with a warning — never fails
# the overall /gaia-atdd invocation (AC-EC4).
#
# Usage:
#   run-red-phase.sh --tests <path> [--timeout <seconds>]
#
# Options:
#   --tests <path>      Path to a generated atdd-{story_key}.md artifact (required)
#   --timeout <sec>     Per-test timeout in seconds (default: 30, AC-EC5)
#   --help, -h          Show this help and exit 0
#
# Behavior:
#   - Reads {GAIA_PROJECT_ROOT}/.gaia/artifacts/test-artifacts/test-environment.yaml (with legacy docs/ fallback).
#   - If absent or bridge_enabled is false: log a "Test runner not configured —
#     skipping red-phase execution" warning and exit 0 (AC-EC4 non-blocking).
#   - Otherwise: invoke the configured runner against --tests, enforce the
#     per-test timeout, and print a single-line "pass/fail counts" summary.
#   - Tests are expected to FAIL (red phase). Unexpected passes are flagged
#     with a warning but do not change the exit status.
#
# Exit codes:
#   0   Always for non-blocking branches (no runner, runner produced output)
#   1   Internal usage error (missing required arg)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-atdd/run-red-phase.sh"

_die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

_TESTS=""
_TIMEOUT=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tests) _TESTS="${2:-}"; shift 2 ;;
    --tests=*) _TESTS="${1#--tests=}"; shift ;;
    --timeout) _TIMEOUT="${2:-30}"; shift 2 ;;
    --timeout=*) _TIMEOUT="${1#--timeout=}"; shift ;;
    --help|-h)
      cat <<EOF
Usage: $SCRIPT_NAME --tests <path> [--timeout <seconds>]

Options:
  --tests <path>     Path to the generated atdd-{story_key}.md artifact
  --timeout <sec>    Per-test timeout in seconds (default: 30)
  --help, -h         Show this help

The script invokes the configured Test Execution Bridge runner against the
provided artifact and reports a pass/fail count summary. When no runner is
configured, the script logs a warning and exits 0 (non-blocking, AC-EC4).
EOF
      exit 0 ;;
    *) _die "unknown argument: $1" ;;
  esac
done

[ -n "$_TESTS" ] || _die "--tests is required"

_PROJECT_ROOT="${GAIA_PROJECT_ROOT:-${PROJECT_ROOT:-.}}"
# AF-2026-05-21-19: canonical-first with positive-evidence legacy fallback.
if [ -f "$_PROJECT_ROOT/docs/test-artifacts/test-environment.yaml" ] && [ ! -d "$_PROJECT_ROOT/.gaia/artifacts/test-artifacts" ]; then
  _BRIDGE_FILE="$_PROJECT_ROOT/docs/test-artifacts/test-environment.yaml"
else
  _BRIDGE_FILE="$_PROJECT_ROOT/.gaia/artifacts/test-artifacts/test-environment.yaml"
fi

# ---------- Test runner detection (AC-EC4) ----------

if [ ! -f "$_BRIDGE_FILE" ]; then
  printf '%s: Test runner not configured — skipping red-phase execution\n' "$SCRIPT_NAME" >&2
  exit 0
fi

# Read bridge_enabled and runner from the YAML. Keep parsing minimal — yq is
# not assumed to be available across every developer machine (the bridge skill
# wraps yq separately).
_bridge_enabled="$(awk -F: '/^bridge_enabled[[:space:]]*:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/"/, "", $2); print $2; exit }' "$_BRIDGE_FILE" 2>/dev/null || true)"
_runner="$(awk -F: '/^runner[[:space:]]*:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/"/, "", $2); print $2; exit }' "$_BRIDGE_FILE" 2>/dev/null || true)"

if [ "$_bridge_enabled" != "true" ] || [ -z "$_runner" ]; then
  printf '%s: Test runner not configured — skipping red-phase execution\n' "$SCRIPT_NAME" >&2
  exit 0
fi

# ---------- Invoke runner with per-test timeout (AC-EC5) ----------

# `timeout(1)` is GNU; macOS users may have `gtimeout` via coreutils. Detect
# whichever is available and fall back to a no-timeout invocation when neither
# is installed. The runner wrap is intentionally cheap: hangs become FAIL
# entries when timeout is available, regular runner output otherwise.

_pass=0
_fail=0
_runner_out=""
if command -v timeout >/dev/null 2>&1; then
  _runner_out="$(timeout "$_TIMEOUT" "$_runner" "$_TESTS" 2>&1 || true)"
elif command -v gtimeout >/dev/null 2>&1; then
  _runner_out="$(gtimeout "$_TIMEOUT" "$_runner" "$_TESTS" 2>&1 || true)"
else
  _runner_out="$("$_runner" "$_TESTS" 2>&1 || true)"
fi

# Parse very loose pass/fail signals from runner output. Real bridges (vitest,
# jest, bats) emit explicit counts; this is a fallback for ad-hoc runners.
_pass="$(printf '%s\n' "$_runner_out" | grep -c -iE '^[[:space:]]*(ok|pass|passed)' || true)"
_fail="$(printf '%s\n' "$_runner_out" | grep -c -iE '^[[:space:]]*(not ok|fail|failed)' || true)"

# Always emit the canonical pass/fail line so callers can parse it.
printf 'red-phase summary: pass=%d fail=%d (red phase — fails expected)\n' "$_pass" "$_fail"

if [ "$_pass" -gt 0 ]; then
  printf '%s: warning — %d test(s) unexpectedly passed during red phase — may not be testing unimplemented behavior\n' \
    "$SCRIPT_NAME" "$_pass" >&2
fi

exit 0
