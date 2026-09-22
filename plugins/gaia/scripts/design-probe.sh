#!/usr/bin/env bash
# design-probe.sh — three-state classifier for the design integration surface.
#
# Reads DESIGN_PROBE_BRIDGE_CMD (an environment-overridable bridge command),
# invokes it under a bounded timeout, and maps the result to one of three
# fixed-string outputs:
#
#   available    — surface present and authorized (exit 0, no message)
#   missing      — surface absent, unreachable, or unknown error (exit 1,
#                  remediation on stderr)
#   unauthorized — surface present, not authorized (exit 1, remediation on
#                  stderr)
#
# The bridge command is honoured ONLY when at least one marker is present:
#   1. BATS_TEST_FILENAME (running under bats)
#   2. DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 (explicit caller opt-in)
# A bare inherited DESIGN_PROBE_BRIDGE_CMD without a marker is refused — the
# probe logs the refusal (naming the would-be command) and classifies as
# missing. Same discipline as GAIA_PPO_DISPATCH_CMD in
# phase-parallel-orchestrator.sh (see its _ppo_log dispatch_hook lines).
#
# Bridge exit-code contract:
#   0   — surface available and authorized
#   3   — surface present, not authorized (primary signal)
#   any other non-zero / absent — surface missing
#
# When the bridge exits 3, stderr confirmation with the literal "unauthorized"
# marker is expected but not required — exit code 3 is the primary signal.
# When the bridge exits non-zero with a code other than 3 AND stderr contains
# the literal "unauthorized" marker, the probe classifies as unauthorized
# (secondary detection for bridges using exit 1 with the marker).
#
# Timeout: sourced from scripts/lib/exec-with-timeout.sh (three-tier cascade).
# A timeout classifies as missing (fail-closed) but is worded as "treated as
# unavailable" rather than a flat "is not available" claim — a slow bridge is
# not proven absent, so the message must not overstate what the probe knows.
#
# DESIGN_PROBE_TIMEOUT_SECONDS — default 5, overridable for testing.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/exec-with-timeout.sh
. "${SCRIPT_DIR}/lib/exec-with-timeout.sh"

# ---- fixed-string messages (never interpolated with response content) --------
#
# The two messages are the deliverable: an operator who has read neither the
# epic nor this script must be able to act on either one immediately. Each
# names what to do; the two must differ in substance, not just wording — one
# says "this session doesn't have the surface at all," the other says "the
# surface is right there, you just haven't signed in."

_MSG_MISSING="The Claude Design integration could not be reached in this environment (absent, or unreachable within the timeout) and is therefore treated as unavailable. To enable it, use a Claude Code session that exposes the DesignSync tool surface. Non-interactive setup performed: none. Could not perform: nothing further can be attempted without a session exposing the tool surface — that is an environment change, not a step the framework can take."

_MSG_UNAUTHORIZED="The Claude Design integration is available but not authorized for this session. Run /design-login to authorize — this is an interactive step that you must run yourself; the framework cannot run it on your behalf. Non-interactive setup performed: none. Could not perform: the /design-login step is interactive and cannot be automated."

# ---- classification decision (underscore-prefixed: not the coverage-gate's
# public-function surface, which keys on column-0 names with no leading
# underscore) ------------------------------------------------------------

# _design_probe_classify <bridge_cmd> <timeout_s>
# Runs the bridge under a bounded timeout and sets two out-vars in the
# CALLER's shell (no command substitution, no subshell — a subshell would
# lose plain variable assignments back to the caller):
#   REPLY       — the classification word ("available"|"missing"|"unauthorized")
#   REPLY_WARN  — diagnostic text to log, or "" (e.g. exit-3-without-
#                 confirmation) — the caller decides WHEN to print this so
#                 it lands after the classification word it emits, never
#                 before (a warning that outruns the verdict it explains
#                 reads as broken output, especially once stdout/stderr
#                 interleave under a test harness).
_design_probe_classify() {
  local bridge_cmd="$1"
  local timeout_s="$2"
  REPLY_WARN=""

  local stderr_file
  stderr_file="$(mktemp -t design-probe-stderr.XXXXXX)"

  local rc=0
  # Bridge stdout is discarded (>/dev/null): the probe never reads it, and
  # letting it through would bleed the bridge's own output onto the
  # probe's stdout ahead of the classification word this function decides
  # below — a hostile or merely chatty bridge could otherwise make a
  # caller who reads the first line of stdout see the WRONG verdict.
  exec_with_timeout "$timeout_s" sh -c "$bridge_cmd" >/dev/null 2>"$stderr_file" || rc=$?

  local bridge_stderr=""
  if [ -f "$stderr_file" ]; then
    bridge_stderr="$(cat "$stderr_file")"
    rm -f "$stderr_file"
  fi

  case "$rc" in
    0)
      REPLY="available"
      ;;
    3)
      # Primary unauthorized signal (exit code 3). Stderr confirmation with
      # the literal "unauthorized" marker is expected but not required —
      # note it if missing, but classify as unauthorized either way; this
      # is diagnostic noise, not a change of verdict.
      if ! printf '%s' "$bridge_stderr" | grep -qi 'unauthorized'; then
        REPLY_WARN="warn: bridge exited 3 without the expected stderr confirmation marker"
      fi
      REPLY="unauthorized"
      ;;
    124|137)
      # Timeout (GNU timeout exit 124, SIGKILL exit 137) — a slow bridge is
      # not proven absent, but it is unusable within the bound either way.
      REPLY="missing"
      ;;
    *)
      # Non-zero, non-3: secondary detection for bridges using exit 1 with
      # the literal "unauthorized" marker on stderr.
      if printf '%s' "$bridge_stderr" | grep -qi 'unauthorized'; then
        REPLY="unauthorized"
      else
        REPLY="missing"
      fi
      ;;
  esac
}

# _sanitize_for_log <value>
# Prints <value> with every non-printable byte (C0 controls 0x00-0x1f, DEL
# 0x7f, and any embedded newline) replaced by '?', on a single line with no
# trailing newline. Used before interpolating an attacker-controlled value
# (e.g. DESIGN_PROBE_BRIDGE_CMD) into a log line: without this, escape
# sequences (color/title-bar rewrites) and embedded newlines pass through
# verbatim and can forge additional log lines. LC_ALL=C (set at top of this
# script) makes `tr`'s [:print:] class byte-for-byte deterministic across
# platforms rather than locale-dependent.
_sanitize_for_log() {
  printf '%s' "$1" | tr -c '[:print:]' '?'
}

# ---- public entry point (coverage gate requires this name in a bats file) ---

design_probe() {
  local bridge_cmd="${DESIGN_PROBE_BRIDGE_CMD:-}"
  local timeout_s="${DESIGN_PROBE_TIMEOUT_SECONDS:-5}"

  # 1. No bridge command → missing, no classification needed.
  if [ -z "$bridge_cmd" ]; then
    printf '%s\n' "missing"
    printf '%s\n' "$_MSG_MISSING" >&2
    return 1
  fi

  # 2. Bridge set but no marker (BATS_TEST_FILENAME / explicit opt-in) →
  #    refused. Logged in the same event=/action=/reason= shape as
  #    phase-parallel-orchestrator.sh's dispatch_hook line, naming the
  #    refused command so the log is useful without re-running anything.
  if [ -z "${BATS_TEST_FILENAME:-}" ] && [ "${DESIGN_PROBE_ALLOW_BRIDGE_CMD:-}" != "1" ]; then
    # cmd= carries an attacker-controlled value (the caller's ambient
    # DESIGN_PROBE_BRIDGE_CMD) — sanitized so control bytes and embedded
    # newlines cannot forge terminal escapes or extra log lines.
    printf 'event=bridge_hook cmd=%s action=refused reason=no-marker — set DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 to honour this bridge outside bats\n' "$(_sanitize_for_log "$bridge_cmd")" >&2
    printf '%s\n' "missing"
    printf '%s\n' "$_MSG_MISSING" >&2
    return 1
  fi

  # 3. Classify by actually running the bridge, then emit the matching
  #    operator-facing message. The classification word is printed first so
  #    it lands as the first line even when stdout/stderr interleave (e.g.
  #    bats' `run`); any diagnostic warning from the classifier prints
  #    afterward, once the verdict it refers to is already on the page.
  _design_probe_classify "$bridge_cmd" "$timeout_s"
  local state="$REPLY"
  local classify_warn="$REPLY_WARN"

  case "$state" in
    available)
      printf '%s\n' "available"
      return 0
      ;;
    unauthorized)
      printf '%s\n' "unauthorized"
      [ -z "$classify_warn" ] || printf '%s\n' "$classify_warn" >&2
      printf '%s\n' "$_MSG_UNAUTHORIZED" >&2
      return 1
      ;;
    *)
      printf '%s\n' "missing"
      printf '%s\n' "$_MSG_MISSING" >&2
      return 1
      ;;
  esac
}

# Main guard — run when executed directly, not when sourced as a library
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  design_probe "$@"
fi
