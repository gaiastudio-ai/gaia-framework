#!/usr/bin/env bash
# verdict-resolver.sh — GAIA shared review-skill script
#
# Computes the review verdict by strict first-match-wins precedence over the
# deterministic Phase 3A artifact (analysis-results.json) and the LLM Phase 3B
# findings JSON. The LLM CANNOT override a deterministic tool failure — this is
# the LLM-cannot-override invariant.
#
# Precedence (first match wins):
#   1. Any check.status == "errored"                       -> BLOCKED
#   2. Any check.status == "failed" with blocking finding  -> REQUEST_CHANGES
#   3. Any LLM finding severity == "Critical"              -> REQUEST_CHANGES
#   3b. coverage_delta <= 0 (--coverage-delta only)        -> REQUEST_CHANGES
#   4. Otherwise                                           -> APPROVE
#
# Malformed analysis-results.json (invalid JSON, missing schema_version,
# unreadable file) -> BLOCKED with stderr error. Verdict is data, not exit code;
# the script exits 0 except on caller errors.
#
# Invocation:
#   verdict-resolver.sh [--skill <skill-name>] --analysis-results <path> --llm-findings <path>
#   verdict-resolver.sh --help
#
# The optional --skill <name> flag is the generalization hook: it accepts any
# of the twelve verdict-producing skills' `analysis-results.json` inputs
# (gaia-code-review, gaia-review-qa, gaia-review-test, gaia-test-automate,
# gaia-review-security, gaia-review-perf, gaia-review-mobile,
# gaia-validate-design-a11y, gaia-test-{e2e,perf,dast,a11y},
# gaia-test-mobile-e2e, gaia-test-device-matrix, gaia-deploy). The skill name
# is logged in stderr provenance but does NOT alter the four-rule precedence
# logic — strict first-match-wins is preserved. Omitting --skill preserves the
# legacy gaia-code-review-only behavior (backward compat).
#
# Exit codes:
#   0  — success (verdict on stdout)
#   1  — caller error (missing/unknown flag, missing required arg)
#
# Stdout: exactly one of "APPROVE" | "REQUEST_CHANGES" | "BLOCKED" (no newline
#         trailing variations beyond a single \n).
# Stderr: diagnostic messages only.
#

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
$SCRIPT_NAME — verdict resolver for GAIA review skills

Usage:
  $SCRIPT_NAME [--skill <name>] --analysis-results <path> --llm-findings <path>
  $SCRIPT_NAME --action-mode --analysis-results <path>
  $SCRIPT_NAME --help

Options:
  --skill <name>             Optional. Identifies the producing skill (any of
                             the twelve verdict-producing skills).
                             Logged in provenance; does not alter precedence.
                             --analysis is accepted as an alias for
                             --analysis-results.
  --action-mode              Action-skill semantics for /gaia-test-automate.
                             Reads action-skill outcome flags (placeholders,
                             mocks_sut, breaks_suite, blocking_failure) from
                             the analysis document and emits
                             APPROVE | REQUEST_CHANGES | BLOCKED per the
                             action-skill verdict table. --llm-findings is NOT
                             required in action-mode.
  --analysis-results <path>  Path to Phase 3A analysis-results.json (required)
  --llm-findings <path>      Path to Phase 3B LLM findings JSON (required;
                             ignored under --action-mode)
  --coverage-delta <path>    Optional. Path to coverage-delta.sh JSON output.
                             When present, a coverage_delta <= 0 yields
                             REQUEST_CHANGES — inserted between the LLM-Critical
                             rule and the default APPROVE branch. Omitting this
                             flag preserves the original four-rule behavior.
  --execution-evidence <p>   Optional. Path to execution-evidence.json produced
                             by review-common/qa-test-runner.sh. When present,
                             required-tier timeouts yield BLOCKED and
                             required-tier non-zero exits yield REQUEST_CHANGES,
                             alongside the existing errored / failed-blocking
                             gates. Omitting this flag preserves prior behavior.
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
REGISTER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill)
      # Optional generalization hook. Accepted but does not alter precedence.
      [ "$#" -ge 2 ] || die 1 "--skill requires a name"
      SKILL="$2"; shift 2 ;;
    --action-mode)
      # Action-skill verdict semantics for /gaia-test-automate.
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
    --register)
      # Path to the shared findings register YAML file. When present,
      # --llm-findings is forbidden (LLM findings go through the register
      # instead) and --analysis-results becomes optional when not in
      # action-mode. The register rule replaces the LLM-Critical rule.
      [ "$#" -ge 2 ] || die 1 "--register requires a path"
      REGISTER="$2"; shift 2 ;;
    --coverage-delta)
      # Optional. Path to coverage-delta.sh JSON output. When present, a
      # coverage_delta <= 0 inserts REQUEST_CHANGES between the LLM-Critical
      # rule and the default APPROVE branch. Backward-compatible when omitted
      # (four-rule behavior preserved).
      [ "$#" -ge 2 ] || die 1 "--coverage-delta requires a path"
      COVERAGE_DELTA="$2"; shift 2 ;;
    --execution-evidence)
      # Optional. Path to execution-evidence.json produced by
      # review-common/qa-test-runner.sh. When present, contributes to
      # precedence: any required-tier timeout -> BLOCKED (rule 1 equivalent);
      # any required-tier failure -> REQUEST_CHANGES (rule 2 equivalent).
      # Backward-compatible when omitted.
      [ "$#" -ge 2 ] || die 1 "--execution-evidence requires a path"
      EXECUTION_EVIDENCE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die 1 "unknown argument: $1" ;;
  esac
done

# --register and --llm-findings are mutually exclusive.
if [ -n "$REGISTER" ] && [ -n "$LLM" ]; then
  die 1 "--register and --llm-findings are mutually exclusive"
fi

# --analysis-results is required unless --register is given without
# --action-mode (register-only skills have no analysis document).
if [ -n "$REGISTER" ]; then
  # action-mode always needs analysis inputs, even with register.
  if [ "$ACTION_MODE" -eq 1 ] && [ -z "$ANALYSIS" ]; then
    die 1 "missing required --analysis-results <path>"
  fi
else
  [ -n "$ANALYSIS" ] || die 1 "missing required --analysis-results <path>"
  # action-mode does not require --llm-findings (action-skill outcome flags
  # live in the analysis-results document itself).
  if [ "$ACTION_MODE" -eq 0 ]; then
    [ -n "$LLM" ] || die 1 "missing required --llm-findings <path>"
  fi
fi

# Provenance: log --skill if provided. Stderr is informational; does not alter
# the verdict (precedence is unchanged).
if [ -n "$SKILL" ]; then
  printf '%s: skill=%s\n' "$SCRIPT_NAME" "$SKILL" >&2
fi

command -v jq >/dev/null 2>&1 || die 1 "jq is required but not on PATH"

# When --register is given, yq is required for YAML parsing.
if [ -n "$REGISTER" ]; then
  command -v yq >/dev/null 2>&1 || {
    printf '%s: BLOCKED — yq not found on PATH\n' "$SCRIPT_NAME" >&2
    # Cannot emit here because emit() is defined below; inline it.
    printf '%s\n' "BLOCKED"
    exit 0
  }
fi

emit() {
  printf '%s\n' "$1"
  exit 0
}

# --- Register structural pre-parse (before any rule) ---
# When --register is given, parse and validate the register FIRST. A malformed
# register is always BLOCKED regardless of other inputs.
_VR_HAS_BLOCKER=""
if [ -n "$REGISTER" ]; then
  if [ ! -r "$REGISTER" ]; then
    printf '%s: register parse error: file not readable: %s\n' "$SCRIPT_NAME" "$REGISTER" >&2
    emit "BLOCKED"
  fi
  if ! yq '.' "$REGISTER" >/dev/null 2>&1; then
    printf '%s: register parse error: invalid YAML: %s\n' "$SCRIPT_NAME" "$REGISTER" >&2
    emit "BLOCKED"
  fi
  # Structural validation: schema_version, entries/gate_runs sequences,
  # each entry has required fields.
  _vr_valid="$(yq '
    .schema_version == 1
    and ((.entries | type) == "!!seq")
    and ((.gate_runs | type) == "!!seq")
    and ([.entries[] | select(
      ((. | type) != "!!map") or (.id == null) or (.disposition == null)
      or ((.blocking | type) != "!!bool")
      or ((.gate_ratings | type) != "!!seq")
    )] | length == 0)
  ' "$REGISTER" 2>/dev/null)" || _vr_valid="__err"
  case "$_vr_valid" in
    true) ;; # valid
    *)
      printf '%s: register structural validation failed: %s\n' "$SCRIPT_NAME" "$REGISTER" >&2
      emit "BLOCKED" ;;
  esac
  # Compute has-unresolved-blocker. No -e flag (under set -euo pipefail,
  # yq -e returning "false" in a command substitution aborts the script).
  _vr_entry_count="$(yq '.entries | length' "$REGISTER" 2>/dev/null)" || _vr_entry_count="__err"
  case "$_vr_entry_count" in
    0)
      printf '%s: register: empty\n' "$SCRIPT_NAME" >&2
      _VR_HAS_BLOCKER="false" ;;
    *[!0-9]*)
      printf '%s: register query returned unexpected entry count: %s\n' "$SCRIPT_NAME" "$_vr_entry_count" >&2
      emit "BLOCKED" ;;
    *)
      _VR_HAS_BLOCKER="$(yq '
        [.entries[]
          | select(.disposition != "resolved")
          | select(
              (.material == true)
              or (has("severity_resolution") and .severity_resolution.resolved_blocking == true)
              or ((has("severity_resolution") | not) and
                  ([.gate_ratings[] | select(.blocking == true)] | length > 0))
              or ((has("severity_resolution") | not) and
                  ([.gate_ratings[] | select(.blocking == true)] | length == 0) and
                  .blocking == true)
            )
        ] | length > 0
      ' "$REGISTER" 2>/dev/null)" || _VR_HAS_BLOCKER="__err"
      case "$_VR_HAS_BLOCKER" in
        true|false) ;; # valid
        *)
          printf '%s: register query returned unexpected value: %s\n' "$SCRIPT_NAME" "$_VR_HAS_BLOCKER" >&2
          emit "BLOCKED" ;;
      esac
      ;;
  esac
fi

# --- 0. Malformed-input gate ---
# When --register is given and no analysis-results were provided, skip
# the analysis-results checks entirely (the register pre-parse handled it).
if [ -n "$ANALYSIS" ]; then
  if [ ! -r "$ANALYSIS" ]; then
    printf '%s: malformed analysis-results.json: file not found or unreadable: %s\n' "$SCRIPT_NAME" "$ANALYSIS" >&2
    emit "BLOCKED"
  fi

  # Parse the analysis JSON; capture jq failure as malformed.
  if ! jq -e . "$ANALYSIS" >/dev/null 2>&1; then
    printf '%s: malformed analysis-results.json: invalid JSON\n' "$SCRIPT_NAME" >&2
    emit "BLOCKED"
  fi
fi

# --- Action-skill mode ---
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

  # Register rule in action mode: after no-plan/no-run BLOCKED, before APPROVE.
  if [ -n "$REGISTER" ] && [ "$_VR_HAS_BLOCKER" = "true" ]; then
    emit "REQUEST_CHANGES"
  fi

  emit "APPROVE"
fi

# Required schema_version field check — skip when register-only (no analysis).
if [ -n "$ANALYSIS" ]; then
  if ! jq -e '(.schema_version // "") | length > 0' "$ANALYSIS" >/dev/null 2>&1; then
    printf '%s: malformed analysis-results.json: missing schema_version\n' "$SCRIPT_NAME" >&2
    emit "BLOCKED"
  fi
fi

# LLM findings file: validate when provided. A readable file whose JSON is
# malformed (truncated, invalid syntax, zero-byte) is BLOCKED with a
# diagnostic — not silently treated as "no findings".
# Skip when --register is given (LLM findings go through the register).
LLM_OK=0
if [ -z "$REGISTER" ]; then
  if [ -r "$LLM" ]; then
    if jq -e . "$LLM" >/dev/null 2>&1; then
      LLM_OK=1
    else
      printf '%s: malformed LLM-findings JSON: invalid or truncated: %s\n' "$SCRIPT_NAME" "$LLM" >&2
      emit "BLOCKED"
    fi
  fi
fi

# --- Execution-evidence pre-check ---
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
# Rules 1, 2 read from ANALYSIS; skip when register-only (no analysis).
if [ -n "$ANALYSIS" ]; then
if jq -e '[.checks[]? | select(.status == "errored")] | length > 0' "$ANALYSIS" >/dev/null 2>&1; then
  emit "BLOCKED"
fi
fi  # end of [ -n "$ANALYSIS" ] conditional (rule 1)

# --- 1b. execution-evidence: required-tier timeout -> BLOCKED ---
# Runs even without --analysis-results (register-only skills with execution
# evidence must still honour the timed-out-suite rule).
if [ "$EE_OK" = "1" ]; then
  if jq -e '
    (.skipped // false) | not
  ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
    if jq -e '
      [.suites[]?
        | select(.required != false)
        | select((.timeout // false) == true)
      ] | length > 0
    ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
      printf '%s: required test suite timed out -> BLOCKED\n' "$SCRIPT_NAME" >&2
      emit "BLOCKED"
    fi
  fi
fi

# --- 2a. execution-evidence: required-tier failure -> REQUEST_CHANGES ---
if [ "$EE_OK" = "1" ]; then
  if jq -e '
    (.skipped // false) | not
  ' "$EXECUTION_EVIDENCE" >/dev/null 2>&1; then
    if jq -e '
      [.suites[]?
        | select(.required != false)
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
if [ -n "$ANALYSIS" ]; then
# A check is failed-blocking if status == "failed". A failed check with no
# findings is still treated as blocking (the tool itself signaled failure).
# When findings exist we additionally honor an explicit blocking=true marker.
#
# Note: the original idiom `(.blocking // true)` was buggy — jq's `//`
# operator returns the RHS when the LHS is `null` OR `false`. So explicit
# `"blocking": false` findings were being inflated to blocking, and the
# resolver returned REQUEST_CHANGES even for purely advisory results. The
# corrected form distinguishes null (use default true) from false (use
# false): `if .blocking == null then true else .blocking end`.
if jq -e '
  [.checks[]?
    | select(.status == "failed")
    | select(
        (.findings // []) == []                                          # no findings at all -> blocking
        or any(.findings[]?; if .blocking == null then true else .blocking end)  # respect explicit false
      )
  ] | length > 0
' "$ANALYSIS" >/dev/null 2>&1; then
  emit "REQUEST_CHANGES"
fi
fi  # end of [ -n "$ANALYSIS" ] conditional (rule 2)

# --- 3. LLM-Critical / Register rule ---
# When --register is given, the register rule replaces the LLM-Critical rule.
# Without --register, the existing LLM-Critical logic runs unchanged.
if [ -n "$REGISTER" ]; then
  # Register rule: REQUEST_CHANGES iff an unresolved blocker exists.
  if [ "$_VR_HAS_BLOCKER" = "true" ]; then
    emit "REQUEST_CHANGES"
  fi
else
  if [ "$LLM_OK" = "1" ]; then
    if jq -e '
      (.findings // []) | map(select((.severity // "") | ascii_downcase == "critical")) | length > 0
    ' "$LLM" >/dev/null 2>&1; then
      emit "REQUEST_CHANGES"
    fi
  fi
fi

# --- 3b. coverage-delta gate -> REQUEST_CHANGES on zero/negative ---
# Inserted between LLM-Critical and the default APPROVE branch.
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
