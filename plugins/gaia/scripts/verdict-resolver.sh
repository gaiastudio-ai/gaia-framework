#!/usr/bin/env bash
# verdict-resolver.sh — GAIA shared review-skill script (E65-S1, ADR-075)
#
# Computes the review verdict by strict first-match-wins precedence over the
# deterministic Phase 3A artifact (analysis-results.json) and the LLM Phase 3B
# findings JSON. The LLM CANNOT override a deterministic tool failure — this is
# the ADR-075 LLM-cannot-override invariant (FR-DEJ-6).
#
# Precedence (first match wins):
#   1. Any check.status == "errored"                       -> BLOCKED
#   2. Any check.status == "failed" with blocking finding  -> REQUEST_CHANGES
#   3. Any LLM finding severity == "Critical"              -> REQUEST_CHANGES
#   4. Otherwise                                           -> APPROVE
#
# Malformed analysis-results.json (invalid JSON, missing schema_version,
# unreadable file) -> BLOCKED with stderr error. Verdict is data, not exit code
# (per ADR-042 pattern); the script exits 0 except on caller errors.
#
# Invocation:
#   verdict-resolver.sh [--skill <skill-name>] --analysis-results <path> --llm-findings <path>
#   verdict-resolver.sh --help
#
# The optional --skill <name> flag (added by E66-S1, ADR-077) is the
# generalization hook: it accepts any of the twelve verdict-producing skills'
# `analysis-results.json` inputs (gaia-code-review, gaia-review-qa,
# gaia-review-test, gaia-test-automate, gaia-review-security, gaia-review-perf,
# gaia-review-mobile, gaia-validate-design-a11y, gaia-test-{e2e,perf,dast,a11y},
# gaia-test-mobile-e2e, gaia-test-device-matrix, gaia-deploy). The skill name
# is logged in stderr provenance but does NOT alter the four-rule precedence
# logic — strict first-match-wins is preserved per ADR-075. Omitting --skill
# preserves the legacy gaia-code-review-only behavior (backward compat).
#
# Exit codes:
#   0  — success (verdict on stdout)
#   1  — caller error (missing/unknown flag, missing required arg)
#
# Stdout: exactly one of "APPROVE" | "REQUEST_CHANGES" | "BLOCKED" (no newline
#         trailing variations beyond a single \n).
# Stderr: diagnostic messages only.
#
# Refs: ADR-075, FR-DEJ-6, AC3 of E65-S1, EC-1, EC-2, EC-3, EC-10.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="verdict-resolver.sh"

die() {
  # die <exit_code> <message…>
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — verdict resolver for GAIA review skills (ADR-075, ADR-077)

Usage:
  $SCRIPT_NAME [--skill <name>] --analysis-results <path> --llm-findings <path>
  $SCRIPT_NAME --help

Options:
  --skill <name>             Optional. Identifies the producing skill (any of
                             the twelve verdict-producing skills per ADR-077).
                             Logged in provenance; does not alter precedence.
                             --analysis is accepted as an alias for
                             --analysis-results.
  --analysis-results <path>  Path to Phase 3A analysis-results.json (required)
  --llm-findings <path>      Path to Phase 3B LLM findings JSON (required)
  --help                     Show this help and exit 0

Verdicts (stdout):
  BLOCKED          Any deterministic check errored (or malformed input)
  REQUEST_CHANGES  Any tool-failed-blocking OR any LLM-Critical finding
  APPROVE          Default: no errored/failed-blocking/Critical findings

Precedence is strict first-match-wins. The LLM cannot override a tool failure.
EOF
}

ANALYSIS=""
LLM=""
SKILL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill)
      # Optional, ADR-077 generalization. Accepted but does not alter precedence.
      [ "$#" -ge 2 ] || die 1 "--skill requires a name"
      SKILL="$2"; shift 2 ;;
    --analysis-results|--analysis)
      [ "$#" -ge 2 ] || die 1 "$1 requires a path"
      ANALYSIS="$2"; shift 2 ;;
    --llm-findings)
      [ "$#" -ge 2 ] || die 1 "--llm-findings requires a path"
      LLM="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$ANALYSIS" ] || die 1 "missing required --analysis-results <path>"
[ -n "$LLM" ]      || die 1 "missing required --llm-findings <path>"

# Provenance: log --skill if provided. Stderr is informational; does not alter
# the verdict (ADR-075 precedence is unchanged).
if [ -n "$SKILL" ]; then
  printf '%s: skill=%s\n' "$SCRIPT_NAME" "$SKILL" >&2
fi

command -v jq >/dev/null 2>&1 || die 1 "jq is required but not on PATH"

emit() {
  printf '%s\n' "$1"
  exit 0
}

# --- 0. Malformed-input gate (ADR-075 EC-2) ---
if [ ! -r "$ANALYSIS" ]; then
  printf '%s: malformed analysis-results.json: file not found or unreadable: %s\n' "$SCRIPT_NAME" "$ANALYSIS" >&2
  emit "BLOCKED"
fi

# Parse the analysis JSON; capture jq failure as malformed.
if ! jq -e . "$ANALYSIS" >/dev/null 2>&1; then
  printf '%s: malformed analysis-results.json: invalid JSON\n' "$SCRIPT_NAME" >&2
  emit "BLOCKED"
fi

# Required schema_version field check.
if ! jq -e '(.schema_version // "") | length > 0' "$ANALYSIS" >/dev/null 2>&1; then
  printf '%s: malformed analysis-results.json: missing schema_version\n' "$SCRIPT_NAME" >&2
  emit "BLOCKED"
fi

# LLM findings file: tolerate missing-or-empty by treating as no findings.
if [ -r "$LLM" ] && jq -e . "$LLM" >/dev/null 2>&1; then
  LLM_OK=1
else
  LLM_OK=0
fi

# --- 1. errored check -> BLOCKED ---
if jq -e '[.checks[]? | select(.status == "errored")] | length > 0' "$ANALYSIS" >/dev/null 2>&1; then
  emit "BLOCKED"
fi

# --- 2. tool-failed-blocking -> REQUEST_CHANGES ---
# A check is failed-blocking if status == "failed". A failed check with no
# findings is still treated as blocking (the tool itself signaled failure).
# When findings exist we additionally honor an explicit blocking=true marker.
if jq -e '
  [.checks[]?
    | select(.status == "failed")
    | select(
        (.findings // []) == []                      # no findings at all -> blocking
        or any(.findings[]?; (.blocking // true))    # explicit blocking, default true
      )
  ] | length > 0
' "$ANALYSIS" >/dev/null 2>&1; then
  emit "REQUEST_CHANGES"
fi

# --- 3. LLM-Critical finding -> REQUEST_CHANGES ---
if [ "$LLM_OK" = "1" ]; then
  if jq -e '
    (.findings // []) | map(select((.severity // "") | ascii_downcase == "critical")) | length > 0
  ' "$LLM" >/dev/null 2>&1; then
    emit "REQUEST_CHANGES"
  fi
fi

# --- 4. default -> APPROVE ---
emit "APPROVE"
