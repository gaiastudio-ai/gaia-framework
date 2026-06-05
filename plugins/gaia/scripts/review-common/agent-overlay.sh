#!/usr/bin/env bash
# agent-overlay.sh — GAIA review-common entry point
#
# Resolves the (skill, stack) pair to the canonical (agent-id, sidecar-path)
# fixed wiring table. The resolver runs in the parent context BEFORE fork
# dispatch — the fork tool allowlist `[Read, Grep, Glob, Bash]` stays intact.
#
# Public API (entry point):
#   agent-overlay.sh --skill <skill-name> [--stack <canonical-stack>]
#   agent-overlay.sh --help
#
# Arguments:
#   --skill <name>          Required. One of the supported wiring-table skill
#                           variants (see WIRING TABLE below).
#   --stack <stack>         Required only for --skill gaia-review-code (the
#                           stack-conditional row). One of: ts-dev, java-dev,
#                           python-dev, go-dev, flutter-dev, mobile-dev,
#                           angular-dev. Ignored for non-stack skills.
#   --help                  Print this help and exit 0.
#
# Output (stdout, single line, no jq dependency):
#   {"agent_id":"<id>","sidecar_path":"<path>"}
#
# Exit codes:
#   0  success — JSON emitted on stdout
#   1  caller error — unknown skill, missing required flag, invalid stack,
#                     or missing --stack for gaia-review-code
#
# WIRING TABLE:
#   gaia-review-code               -> stack-specific reviewer (ts-dev, java-dev,
#                                     python-dev, go-dev, flutter-dev,
#                                     mobile-dev, angular-dev)
#   gaia-review-qa                 -> vera
#   gaia-review-test               -> sable
#   gaia-test-automate             -> sable
#   gaia-review-security           -> zara
#   gaia-review-perf               -> juno
#   gaia-review-mobile             -> talia
#   gaia-review-a11y               -> christy  (pre-merge a11y review)
#   gaia-validate-design-a11y      -> christy
#   gaia-test-e2e                  -> sable    (post-deploy)
#   gaia-test-perf                 -> sable    (post-deploy)
#   gaia-test-dast                 -> sable    (post-deploy)
#   gaia-test-a11y                 -> sable    (post-deploy)
#   gaia-test-mobile-e2e           -> talia
#   gaia-test-device-matrix        -> talia
#   gaia-deploy                    -> soren
#
# Sidecar convention: `_memory/<agent-id>-sidecar.md`.
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="agent-overlay.sh"

die() {
  # die <exit_code> <message…>
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — resolve (skill, stack) -> (agent-id, sidecar-path)

Usage:
  $SCRIPT_NAME --skill <skill-name> [--stack <stack>]
  $SCRIPT_NAME --help

Options:
  --skill <name>          Required. Wiring-table skill variant.
  --stack <stack>         Required for gaia-review-code only. One of:
                          ts-dev, java-dev, python-dev, go-dev, flutter-dev,
                          mobile-dev, angular-dev.
  --help                  Show this help and exit 0.

Stdout: {"agent_id":"<id>","sidecar_path":"<path>"}
Exit codes:
  0  success
  1  caller error (unknown skill, missing flag, invalid stack)
EOF
}

emit() {
  # emit <agent_id> <sidecar_path>
  printf '{"agent_id":"%s","sidecar_path":"%s"}\n' "$1" "$2"
  exit 0
}

# is_canonical_stack <stack>
is_canonical_stack() {
  case "$1" in
    ts-dev|java-dev|python-dev|go-dev|flutter-dev|mobile-dev|angular-dev) return 0 ;;
    *) return 1 ;;
  esac
}

SKILL=""
STACK=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill)
      [ "$#" -ge 2 ] || die 1 "--skill requires a name"
      SKILL="$2"; shift 2 ;;
    --stack)
      [ "$#" -ge 2 ] || die 1 "--stack requires a name"
      STACK="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$SKILL" ] || die 1 "missing required --skill <name>"

# --- wiring table ---
case "$SKILL" in
  gaia-review-code)
    # Stack-conditional row: --stack required.
    [ -n "$STACK" ] || die 1 "--stack required for skill 'gaia-review-code' (one of: ts-dev, java-dev, python-dev, go-dev, flutter-dev, mobile-dev, angular-dev)"
    is_canonical_stack "$STACK" || die 1 "invalid stack '$STACK' for gaia-review-code (expected one of: ts-dev, java-dev, python-dev, go-dev, flutter-dev, mobile-dev, angular-dev)"
    emit "$STACK" "_memory/${STACK}-sidecar.md"
    ;;
  gaia-review-qa)
    emit "vera" "_memory/vera-sidecar.md" ;;
  gaia-review-test)
    emit "sable" "_memory/sable-sidecar.md" ;;
  gaia-test-automate)
    emit "sable" "_memory/sable-sidecar.md" ;;
  gaia-review-security)
    emit "zara" "_memory/zara-sidecar.md" ;;
  gaia-review-perf)
    emit "juno" "_memory/juno-sidecar.md" ;;
  gaia-review-mobile)
    emit "talia" "_memory/talia-sidecar.md" ;;
  gaia-review-a11y)
    # Pre-merge a11y review is a UX-design concern.
    # Christy owns design-fidelity a11y review; Sable owns post-deploy a11y testing.
    emit "christy" "_memory/christy-sidecar.md" ;;
  gaia-validate-design-a11y)
    emit "christy" "_memory/christy-sidecar.md" ;;
  gaia-test-e2e|gaia-test-perf|gaia-test-dast|gaia-test-a11y)
    # Post-deploy test family — Sable owns.
    emit "sable" "_memory/sable-sidecar.md" ;;
  gaia-test-mobile-e2e|gaia-test-device-matrix)
    emit "talia" "_memory/talia-sidecar.md" ;;
  gaia-deploy)
    emit "soren" "_memory/soren-sidecar.md" ;;
  *)
    die 1 "unknown skill: '$SKILL' (not in wiring table)"
    ;;
esac
