#!/usr/bin/env bash
# missing-file-fallback.sh — shared graceful-missing-file helper.
#
# Several GAIA scripts and skills need to handle the same pattern: a legacy
# input file (e.g. lifecycle-sequence.yaml, workflow-manifest.csv, manifest.yaml)
# may be absent under the native plugin model and the
# caller must degrade gracefully — emit a clear notice and exit without error —
# UNLESS a strict-mode env var explicitly opts into the legacy "missing-is-fatal"
# behavior.
#
# Previously, three callers (next-step.sh, gaia-help/SKILL.md,
# gaia-validate-framework/SKILL.md) each implemented their own variant of this
# decision. This file is the single source of truth for the bash idiom.
#
# USAGE (from a bash caller):
#
#   . "$(dirname "$0")/lib/missing-file-fallback.sh"
#
#   if [ ! -f "$manifest" ]; then
#     handle_missing_file "$manifest" GAIA_NEXT_STEP_STRICT \
#       "next-step: legacy manifests not available under native plugin — nothing to suggest" \
#       "lifecycle-sequence.yaml"
#     rc=$?
#     case "$rc" in
#       10) exit 0 ;;  # graceful no-op
#       2)  exit 2 ;;  # strict-mode violation
#     esac
#   fi
#
# FUNCTION: handle_missing_file <path> <strict_env_var> <no_op_message> [label]
#
# Arguments:
#   path              — filesystem path that may or may not exist
#   strict_env_var    — name (not value) of the opt-in strict-mode env var.
#                       When this var is set to "1", missing files are fatal.
#                       When unset, "0", or any other value, missing files are
#                       a graceful no-op.
#   no_op_message     — message to print on stdout when the file is missing
#                       in graceful mode. Callers capture stdout, so this is
#                       the user-visible fallback notice.
#   label             — optional short label (e.g. "workflow-manifest.csv") for
#                       the strict-mode stderr error. Defaults to the path.
#
# Return codes:
#   0   — file exists (no output written)
#   10  — file missing, graceful no-op (message printed on stdout)
#   2   — file missing and strict mode is enabled (error printed on stderr)
#
# Design notes:
# * The function MUST NOT call `exit` — it returns and lets the caller decide
#   how to terminate. This keeps it composable across scripts with different
#   shell options (set -e, set -u, etc.) and lets callers log extra context
#   before quitting.
# * Return code 10 is deliberately chosen so callers can distinguish a
#   graceful no-op from both success (0) and any strict/error code (1, 2).
#   next-step.sh adopted this sentinel originally; the helper preserves it.
# * The strict env var is passed by NAME, not VALUE, so callers advertise a
#   stable name (GAIA_NEXT_STEP_STRICT, GAIA_HELP_STRICT, ...) and the helper
#   reads it via indirection. This keeps each caller's strict var independent.

# Guard against double-sourcing.
if [ "${_GAIA_MISSING_FILE_FALLBACK_SOURCED:-0}" = "1" ]; then
  # shellcheck disable=SC2317  # reachable when this file is sourced a second time
  return 0 2>/dev/null || true
fi
_GAIA_MISSING_FILE_FALLBACK_SOURCED=1

handle_missing_file() {
  local path="${1:-}"
  local strict_var="${2:-}"
  local no_op_message="${3:-}"
  local label="${4:-$path}"

  if [ -z "$path" ] || [ -z "$strict_var" ] || [ -z "$no_op_message" ]; then
    printf "[missing-file-fallback] ERROR: handle_missing_file requires <path> <strict_env_var> <no_op_message> [label]\n" >&2
    return 1
  fi

  # File exists — caller can proceed normally.
  if [ -f "$path" ]; then
    return 0
  fi

  # Indirectly read the strict env var by name (POSIX-safe via eval).
  local strict_value=""
  eval "strict_value=\${$strict_var:-0}"

  if [ "$strict_value" = "1" ]; then
    printf "[missing-file-fallback] ERROR: %s not found (path: %s)\n" "$label" "$path" >&2
    return 2
  fi

  # Graceful no-op — print notice to stdout so callers that capture stdout
  # see a predictable fallback message.
  printf "%s\n" "$no_op_message"
  return 10
}
