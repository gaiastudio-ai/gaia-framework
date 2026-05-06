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
#   3b. coverage_delta <= 0 (E67-S3, --coverage-delta only) -> REQUEST_CHANGES
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
  $SCRIPT_NAME --action-mode --analysis-results <path>
  $SCRIPT_NAME --help

Options:
  --skill <name>             Optional. Identifies the producing skill (any of
                             the twelve verdict-producing skills per ADR-077).
                             Logged in provenance; does not alter precedence.
                             --analysis is accepted as an alias for
                             --analysis-results.
  --action-mode              E67-S2 action-skill semantics for
                             /gaia-test-automate. Reads action-skill outcome
                             flags (placeholders, mocks_sut, breaks_suite,
                             blocking_failure) from the analysis document and
                             emits APPROVE | REQUEST_CHANGES | BLOCKED per the
                             AC7 verdict table. --llm-findings is NOT required
                             in action-mode.
  --analysis-results <path>  Path to Phase 3A analysis-results.json (required)
  --llm-findings <path>      Path to Phase 3B LLM findings JSON (required;
                             ignored under --action-mode)
  --coverage-delta <path>    Optional (E67-S3). Path to coverage-delta.sh JSON
                             output. When present, a coverage_delta <= 0 yields
                             REQUEST_CHANGES — inserted between the LLM-Critical
                             rule and the default APPROVE branch. Omitting this
                             flag preserves the original four-rule behavior.
  --execution-evidence <p>   Optional (E67-S4). Path to execution-evidence.json
                             produced by review-common/qa-test-runner.sh. When
                             present, required-tier timeouts yield BLOCKED and
                             required-tier non-zero exits yield REQUEST_CHANGES,
                             alongside the existing errored / failed-blocking
                             gates. Omitting this flag preserves the pre-S4
                             behavior.
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
ACTION_MODE=0
COVERAGE_DELTA=""
EXECUTION_EVIDENCE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill)
      # Optional, ADR-077 generalization. Accepted but does not alter precedence.
      [ "$#" -ge 2 ] || die 1 "--skill requires a name"
      SKILL="$2"; shift 2 ;;
    --action-mode)
      # E67-S2: action-skill verdict semantics for /gaia-test-automate.
      # Consumes a flat JSON document with action-skill outcome flags
      # (placeholders, mocks_sut, breaks_suite, blocking_failure) and maps
      # them to the canonical APPROVE | REQUEST_CHANGES | BLOCKED verdict.
      ACTION_MODE=1; shift 1 ;;
    --analysis-results|--analysis)
      [ "$#" -ge 2 ] || die 1 "$1 requires a path"
      ANALYSIS="$2"; shift 2 ;;
    --llm-findings)
      [ "$#" -ge 2 ] || die 1 "--llm-findings requires a path"
      LLM="$2"; shift 2 ;;
    --coverage-delta)
      # E67-S3 (optional). Path to coverage-delta.sh JSON output. When
      # present, a coverage_delta <= 0 inserts REQUEST_CHANGES between the
      # LLM-Critical rule and the default APPROVE branch. Backward-compatible
      # when omitted (pre-S3 four-rule behavior preserved).
      [ "$#" -ge 2 ] || die 1 "--coverage-delta requires a path"
      COVERAGE_DELTA="$2"; shift 2 ;;
    --execution-evidence)
      # E67-S4 (optional). Path to execution-evidence.json produced by
      # review-common/qa-test-runner.sh. When present, contributes to
      # precedence per AC9: any required-tier timeout -> BLOCKED (rule 1
      # equivalent); any required-tier failure -> REQUEST_CHANGES (rule 2
      # equivalent). Backward-compatible when omitted (pre-S4 behavior).
      [ "$#" -ge 2 ] || die 1 "--execution-evidence requires a path"
      EXECUTION_EVIDENCE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$ANALYSIS" ] || die 1 "missing required --analysis-results <path>"
# action-mode does not require --llm-findings (action-skill outcome flags
# live in the analysis-results document itself).
if [ "$ACTION_MODE" -eq 0 ]; then
  [ -n "$LLM" ] || die 1 "missing required --llm-findings <path>"
fi

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

# --- Action-skill mode (E67-S2, AC7) ---
#
# /gaia-test-automate is an action skill, not a review skill. Its outcome
# flags live as top-level booleans / strings on the analysis document
# (no schema_version / checks[] envelope is required). Precedence:
#
#   1. blocking_failure ∈ {plan_tamper, target_outside_allowlist,
#      runner_unavailable, plan_drift, malformed_output}     -> BLOCKED
#   2. placeholders == true                                   -> REQUEST_CHANGES
#   3. mocks_sut == true                                      -> REQUEST_CHANGES
#   4. breaks_suite == true                                   -> REQUEST_CHANGES
#   5. plan == "missing" || execution != "success"            -> BLOCKED (no plan / no run)
#   6. otherwise                                              -> APPROVE
#
# Source: AC7 of E67-S2; source-report SS 11.4.
if [ "$ACTION_MODE" -eq 1 ]; then
  blocking_failure="$(jq -r '.blocking_failure // ""' "$ANALYSIS" 2>/dev/null || echo "")"
  case "$blocking_failure" in
    plan_tamper|target_outside_allowlist|runner_unavailable|plan_drift|malformed_output)
      emit "BLOCKED" ;;
  esac

  placeholders="$(jq -r '.placeholders // false' "$ANALYSIS" 2>/dev/null || echo "false")"
  mocks_sut="$(jq -r '.mocks_sut // false' "$ANALYSIS" 2>/dev/null || echo "false")"
  breaks_suite="$(jq -r '.breaks_suite // false' "$ANALYSIS" 2>/dev/null || echo "false")"

  if [ "$placeholders" = "true" ] || [ "$mocks_sut" = "true" ] || [ "$breaks_suite" = "true" ]; then
    emit "REQUEST_CHANGES"
  fi

  plan="$(jq -r '.plan // ""' "$ANALYSIS" 2>/dev/null || echo "")"
  execution="$(jq -r '.execution // ""' "$ANALYSIS" 2>/dev/null || echo "")"
  if [ "$plan" != "present" ] || [ "$execution" != "success" ]; then
    emit "BLOCKED"
  fi

  emit "APPROVE"
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

# --- Execution-evidence pre-check (E67-S4, AC9) ---
# When --execution-evidence is provided, parse the document up front so the
# timeout / required-failure precedence rules can be applied alongside the
# existing errored / failed-blocking rules.
EE_OK=0
if [ -n "$EXECUTION_EVIDENCE" ]; then
  if [ ! -r "$EXECUTION_EVIDENCE" ]; then
    printf '%s: execution-evidence file not readable: %s\n' "$SCRIPT_NAME" "$EXECUTION_EVIDENCE" >&2
    emit "BLOCKED"
  fi
  if ! jq -e . "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
    printf '%s: malformed execution-evidence JSON: %s\n' "$SCRIPT_NAME" "$EXECUTION_EVIDENCE" >&2
    emit "BLOCKED"
  fi
  EE_OK=1
fi

# --- 1. errored check -> BLOCKED ---
if jq -e '[.checks[]? | select(.status == "errored")] | length > 0' "$ANALYSIS" >/dev/null 2>&1; then
  emit "BLOCKED"
fi

# --- 1b. execution-evidence: required-tier timeout -> BLOCKED (E67-S4 AC6/AC9) ---
if [ "$EE_OK" = "1" ]; then
  if jq -e '
    (.skipped // false) | not
  ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
    if jq -e '
      [.suites[]?
        | select((.required // true) == true)
        | select((.timeout // false) == true)
      ] | length > 0
    ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
      printf '%s: required test suite timed out -> BLOCKED\n' "$SCRIPT_NAME" >&2
      emit "BLOCKED"
    fi
  fi
fi

# --- 2a. execution-evidence: required-tier failure -> REQUEST_CHANGES (E67-S4 AC5/AC9) ---
if [ "$EE_OK" = "1" ]; then
  if jq -e '
    (.skipped // false) | not
  ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
    if jq -e '
      [.suites[]?
        | select((.required // true) == true)
        | select((.timeout // false) == false)
        | select((.exit_code // 0) != 0)
      ] | length > 0
    ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
      printf '%s: required test suite failed (non-zero exit) -> REQUEST_CHANGES\n' "$SCRIPT_NAME" >&2
      emit "REQUEST_CHANGES"
    fi
  fi
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

# --- 3b. coverage-delta gate (E67-S3) -> REQUEST_CHANGES on zero/negative ---
# Inserted between LLM-Critical and the default APPROVE branch per AC6.
# Skipped entirely when --coverage-delta is omitted (backward compat).
if [ -n "$COVERAGE_DELTA" ]; then
  if [ ! -r "$COVERAGE_DELTA" ]; then
    printf '%s: coverage-delta file not readable: %s\n' "$SCRIPT_NAME" "$COVERAGE_DELTA" >&2
    emit "BLOCKED"
  fi
  if ! jq -e . "$COVERAGE_DELTA" >/dev/null 2>&1; then
    printf '%s: malformed coverage-delta JSON: %s\n' "$SCRIPT_NAME" "$COVERAGE_DELTA" >&2
    emit "BLOCKED"
  fi
  cd_value="$(jq -r '.coverage_delta // empty' "$COVERAGE_DELTA" 2>/dev/null || echo "")"
  if [ -z "$cd_value" ]; then
    printf '%s: coverage-delta JSON missing coverage_delta field: %s\n' "$SCRIPT_NAME" "$COVERAGE_DELTA" >&2
    emit "BLOCKED"
  fi
  # Numeric comparison via awk: <= 0 -> REQUEST_CHANGES.
  if awk -v d="$cd_value" 'BEGIN{ exit !(d+0 <= 0) }'; then
    if awk -v d="$cd_value" 'BEGIN{ exit !(d+0 == 0) }'; then
      printf '%s: coverage_delta=0 (zero coverage delta) -> REQUEST_CHANGES\n' "$SCRIPT_NAME" >&2
    else
      printf '%s: coverage_delta=%s (coverage regression) -> REQUEST_CHANGES\n' "$SCRIPT_NAME" "$cd_value" >&2
    fi
    emit "REQUEST_CHANGES"
  fi
fi

# --- 4. default -> APPROVE ---
emit "APPROVE"
