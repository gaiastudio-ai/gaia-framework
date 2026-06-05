#!/usr/bin/env bash
# composite-verdict-aggregator.sh — GAIA review-common entry point
#
# Deterministic shell aggregator that consumes per-gate verdicts produced by the
# six-or-seven verdict-producing review skills and emits a
# composite verdict plus the canonical Review Gate vocabulary mapping
# (APPROVE -> PASSED, REQUEST_CHANGES -> FAILED, BLOCKED -> FAILED).
#
# Pure shell. No LLM. No network. No jitter. Byte-identical output for
# byte-identical input. Invariant under YOLO_MODE.
#
# Public API (entry point):
#   composite-verdict-aggregator.sh \
#     --code     <APPROVE|REQUEST_CHANGES|BLOCKED> \
#     --qa       <APPROVE|REQUEST_CHANGES|BLOCKED> \
#     --test     <APPROVE|REQUEST_CHANGES|BLOCKED> \
#     --security <APPROVE|REQUEST_CHANGES|BLOCKED> \
#     --perf     <APPROVE|REQUEST_CHANGES|BLOCKED> \
#     ( --a11y <verdict> | --skip-a11y "<reason>" ) \
#     ( --mobile <verdict> | --skip-mobile "<reason>" )
#
#   composite-verdict-aggregator.sh --help
#
# Output (stdout, multi-line):
#   composite=<APPROVE|REQUEST_CHANGES|BLOCKED>
#   review_gate=<PASSED|FAILED>
#   included=<comma-separated gate short-names>
#   skipped=<comma-separated gate short-names | "" when none>
#   <one line per gate>: gate=<name> verdict=<verdict>
#   <one line per skipped gate>: <name> skipped — <reason>
#
# Exit codes:
#   0  success — output written to stdout
#   1  caller error — missing required flag, unknown flag, invalid verdict,
#                     mutually exclusive flag combination
#
# First-match-wins precedence:
#   1) any included gate BLOCKED         -> composite BLOCKED
#   2) any included gate REQUEST_CHANGES -> composite REQUEST_CHANGES
#   3) otherwise                          -> composite APPROVE
#
# The order in which the input flags appear has no effect on the output: the
# precedence sweep is deterministic (canonical gate order: code, qa, test,
# security, perf, a11y, mobile).
#
# Conditional gates (a11y, mobile) MUST receive exactly one of:
#   --<gate> <verdict>        : included; participates in precedence
#   --skip-<gate> "<reason>"  : skipped; contributes neutrally; reason enumerated
#
set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="composite-verdict-aggregator.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<EOF
$SCRIPT_NAME — composite verdict aggregator

Usage:
  $SCRIPT_NAME \\
    --code <verdict> --qa <verdict> --test <verdict> \\
    --security <verdict> --perf <verdict> \\
    ( --a11y <verdict> | --skip-a11y "<reason>" ) \\
    ( --mobile <verdict> | --skip-mobile "<reason>" )

Verdict vocabulary: APPROVE | REQUEST_CHANGES | BLOCKED.

Stdout: composite=...; review_gate=...; included=...; skipped=...; per-gate lines.
Exit codes: 0 success; 1 caller error.
EOF
}

is_canonical_verdict() {
  case "$1" in
    APPROVE|REQUEST_CHANGES|BLOCKED) return 0 ;;
    *) return 1 ;;
  esac
}

# Map composite -> Review Gate vocabulary.
map_review_gate() {
  case "$1" in
    APPROVE)         printf 'PASSED' ;;
    REQUEST_CHANGES) printf 'FAILED' ;;
    BLOCKED)         printf 'FAILED' ;;
    *) die 1 "internal: unknown composite verdict '$1'" ;;
  esac
}

# Per-gate inputs.
CODE=""
QA=""
TEST=""
SECURITY=""
PERF=""
A11Y=""
MOBILE=""
SKIP_CODE_REASON=""
SKIP_QA_REASON=""
SKIP_TEST_REASON=""
SKIP_SECURITY_REASON=""
SKIP_PERF_REASON=""
SKIP_A11Y_REASON=""
SKIP_MOBILE_REASON=""
SKIP_CODE_SET=0
SKIP_QA_SET=0
SKIP_TEST_SET=0
SKIP_SECURITY_SET=0
SKIP_PERF_SET=0
A11Y_SET=0
SKIP_A11Y_SET=0
MOBILE_SET=0
SKIP_MOBILE_SET=0
ALLOW_ZERO_INCLUDED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --code)         [ "$#" -ge 2 ] || die 1 "--code requires a verdict"; CODE="$2"; shift 2 ;;
    --qa)           [ "$#" -ge 2 ] || die 1 "--qa requires a verdict"; QA="$2"; shift 2 ;;
    --test)         [ "$#" -ge 2 ] || die 1 "--test requires a verdict"; TEST="$2"; shift 2 ;;
    --security)     [ "$#" -ge 2 ] || die 1 "--security requires a verdict"; SECURITY="$2"; shift 2 ;;
    --perf)         [ "$#" -ge 2 ] || die 1 "--perf requires a verdict"; PERF="$2"; shift 2 ;;
    --a11y)         [ "$#" -ge 2 ] || die 1 "--a11y requires a verdict"; A11Y="$2"; A11Y_SET=1; shift 2 ;;
    --mobile)       [ "$#" -ge 2 ] || die 1 "--mobile requires a verdict"; MOBILE="$2"; MOBILE_SET=1; shift 2 ;;
    --skip-code)     [ "$#" -ge 2 ] || die 1 "--skip-code requires a reason"; SKIP_CODE_REASON="$2"; SKIP_CODE_SET=1; shift 2 ;;
    --skip-qa)       [ "$#" -ge 2 ] || die 1 "--skip-qa requires a reason"; SKIP_QA_REASON="$2"; SKIP_QA_SET=1; shift 2 ;;
    --skip-test)     [ "$#" -ge 2 ] || die 1 "--skip-test requires a reason"; SKIP_TEST_REASON="$2"; SKIP_TEST_SET=1; shift 2 ;;
    --skip-security) [ "$#" -ge 2 ] || die 1 "--skip-security requires a reason"; SKIP_SECURITY_REASON="$2"; SKIP_SECURITY_SET=1; shift 2 ;;
    --skip-perf)     [ "$#" -ge 2 ] || die 1 "--skip-perf requires a reason"; SKIP_PERF_REASON="$2"; SKIP_PERF_SET=1; shift 2 ;;
    --skip-a11y)    [ "$#" -ge 2 ] || die 1 "--skip-a11y requires a reason"; SKIP_A11Y_REASON="$2"; SKIP_A11Y_SET=1; shift 2 ;;
    --skip-mobile)  [ "$#" -ge 2 ] || die 1 "--skip-mobile requires a reason"; SKIP_MOBILE_REASON="$2"; SKIP_MOBILE_SET=1; shift 2 ;;
    --allow-zero-included) ALLOW_ZERO_INCLUDED=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die 1 "unknown argument: $1" ;;
  esac
done

# Opt-in degenerate-case path. The five always-on gates are
# REQUIRED by default; --allow-zero-included unlocks --skip-<always-on-gate>
# usage and accepts the case where every gate is skipped (configuration-error
# safety net). When --allow-zero-included is NOT set, callers
# using --skip-code / --skip-qa / --skip-test / --skip-security / --skip-perf
# are rejected so the always-on contract is preserved by default.
if [ "$ALLOW_ZERO_INCLUDED" -eq 0 ]; then
  for kv in "code:$SKIP_CODE_SET" "qa:$SKIP_QA_SET" "test:$SKIP_TEST_SET" "security:$SKIP_SECURITY_SET" "perf:$SKIP_PERF_SET"; do
    name="${kv%%:*}"
    set_flag="${kv##*:}"
    if [ "$set_flag" -eq 1 ]; then
      die 1 "--skip-$name requires --allow-zero-included (always-on gates are required by default)"
    fi
  done
fi

# Required-gate validation: a gate is satisfied if it has a verdict OR (under
# --allow-zero-included) it is explicitly skipped with a reason. Otherwise the
# caller must provide one or the other.
require_gate() {
  local name="$1" verdict="$2" skip_set="$3"
  if [ -n "$verdict" ]; then return 0; fi
  if [ "$ALLOW_ZERO_INCLUDED" -eq 1 ] && [ "$skip_set" -eq 1 ]; then return 0; fi
  die 1 "missing required --$name <verdict>"
}
require_gate code     "$CODE"     "$SKIP_CODE_SET"
require_gate qa       "$QA"       "$SKIP_QA_SET"
require_gate test     "$TEST"     "$SKIP_TEST_SET"
require_gate security "$SECURITY" "$SKIP_SECURITY_SET"
require_gate perf     "$PERF"     "$SKIP_PERF_SET"

# Mutually exclusive: --<gate> XOR --skip-<gate> for always-on gates when
# --allow-zero-included is in play.
if [ "$ALLOW_ZERO_INCLUDED" -eq 1 ]; then
  for kv in "code:$CODE:$SKIP_CODE_SET" "qa:$QA:$SKIP_QA_SET" "test:$TEST:$SKIP_TEST_SET" "security:$SECURITY:$SKIP_SECURITY_SET" "perf:$PERF:$SKIP_PERF_SET"; do
    n="${kv%%:*}"
    rest="${kv#*:}"
    v="${rest%%:*}"
    s="${rest##*:}"
    if [ -n "$v" ] && [ "$s" -eq 1 ]; then
      die 1 "--$n and --skip-$n are mutually exclusive"
    fi
  done
fi

# Mutually exclusive: --a11y XOR --skip-a11y, --mobile XOR --skip-mobile.
if [ "$A11Y_SET" -eq 1 ] && [ "$SKIP_A11Y_SET" -eq 1 ]; then
  die 1 "--a11y and --skip-a11y are mutually exclusive"
fi
if [ "$A11Y_SET" -eq 0 ] && [ "$SKIP_A11Y_SET" -eq 0 ]; then
  die 1 "must provide either --a11y <verdict> or --skip-a11y <reason>"
fi
if [ "$MOBILE_SET" -eq 1 ] && [ "$SKIP_MOBILE_SET" -eq 1 ]; then
  die 1 "--mobile and --skip-mobile are mutually exclusive"
fi
if [ "$MOBILE_SET" -eq 0 ] && [ "$SKIP_MOBILE_SET" -eq 0 ]; then
  die 1 "must provide either --mobile <verdict> or --skip-mobile <reason>"
fi

# Validate verdict values for included always-on gates only (skipped gates
# pass-through their reason and contribute neutrally).
[ -n "$CODE" ]     && { is_canonical_verdict "$CODE"     || die 1 "invalid verdict '$CODE' for --code"; }
[ -n "$QA" ]       && { is_canonical_verdict "$QA"       || die 1 "invalid verdict '$QA' for --qa"; }
[ -n "$TEST" ]     && { is_canonical_verdict "$TEST"     || die 1 "invalid verdict '$TEST' for --test"; }
[ -n "$SECURITY" ] && { is_canonical_verdict "$SECURITY" || die 1 "invalid verdict '$SECURITY' for --security"; }
[ -n "$PERF" ]     && { is_canonical_verdict "$PERF"     || die 1 "invalid verdict '$PERF' for --perf"; }
if [ "$A11Y_SET" -eq 1 ]; then
  is_canonical_verdict "$A11Y" || die 1 "invalid verdict '$A11Y' for --a11y"
fi
if [ "$MOBILE_SET" -eq 1 ]; then
  is_canonical_verdict "$MOBILE" || die 1 "invalid verdict '$MOBILE' for --mobile"
fi

# Build canonical-order arrays of (name, verdict) for included gates. Always-on
# gates may be skipped under --allow-zero-included; conditional gates use the
# existing XOR contract.
INCLUDED_NAMES=()
INCLUDED_VERDICTS=()
SKIPPED_NAMES=()
SKIPPED_REASONS=()

append_gate() {
  # append_gate <name> <verdict> <skip_set> <skip_reason>
  local name="$1" verdict="$2" skip_set="$3" reason="$4"
  if [ "$skip_set" -eq 1 ]; then
    SKIPPED_NAMES+=("$name"); SKIPPED_REASONS+=("$reason")
  else
    INCLUDED_NAMES+=("$name"); INCLUDED_VERDICTS+=("$verdict")
  fi
}

append_gate code     "$CODE"     "$SKIP_CODE_SET"     "$SKIP_CODE_REASON"
append_gate qa       "$QA"       "$SKIP_QA_SET"       "$SKIP_QA_REASON"
append_gate test     "$TEST"     "$SKIP_TEST_SET"     "$SKIP_TEST_REASON"
append_gate security "$SECURITY" "$SKIP_SECURITY_SET" "$SKIP_SECURITY_REASON"
append_gate perf     "$PERF"     "$SKIP_PERF_SET"     "$SKIP_PERF_REASON"

if [ "$A11Y_SET" -eq 1 ]; then
  INCLUDED_NAMES+=("a11y"); INCLUDED_VERDICTS+=("$A11Y")
else
  SKIPPED_NAMES+=("a11y"); SKIPPED_REASONS+=("$SKIP_A11Y_REASON")
fi
if [ "$MOBILE_SET" -eq 1 ]; then
  INCLUDED_NAMES+=("mobile"); INCLUDED_VERDICTS+=("$MOBILE")
else
  SKIPPED_NAMES+=("mobile"); SKIPPED_REASONS+=("$SKIP_MOBILE_REASON")
fi

# First-match-wins precedence: BLOCKED > REQUEST_CHANGES > APPROVE.
# `any_verdict_match <target> <verdict-list...>` — returns 0 if any list element
# equals <target>; non-zero otherwise. Pure helper, no side effects.
any_verdict_match() {
  local target="$1"; shift
  local v
  for v in "$@"; do
    if [ "$v" = "$target" ]; then return 0; fi
  done
  return 1
}

# Degenerate-case safety net. Zero included gates is a configuration
# error: we WARN once on stdout and emit composite APPROVE so the
# orchestrator does not silently mark a story BLOCKED when nothing was
# actually evaluated. The WARNING is always emitted FIRST so log scrapers
# pick it up before the composite line.
ZERO_INCLUDED=0
if [ "${#INCLUDED_VERDICTS[@]}" -eq 0 ]; then
  ZERO_INCLUDED=1
  COMPOSITE="APPROVE"
elif any_verdict_match "BLOCKED" "${INCLUDED_VERDICTS[@]}"; then
  COMPOSITE="BLOCKED"
elif any_verdict_match "REQUEST_CHANGES" "${INCLUDED_VERDICTS[@]}"; then
  COMPOSITE="REQUEST_CHANGES"
else
  COMPOSITE="APPROVE"
fi

REVIEW_GATE="$(map_review_gate "$COMPOSITE")"

# Format included / skipped name lists (canonical order, comma-separated).
join_csv() {
  local IFS=,
  printf '%s' "$*"
}
if [ "${#INCLUDED_NAMES[@]}" -eq 0 ]; then
  INCLUDED_CSV=""
else
  INCLUDED_CSV="$(join_csv "${INCLUDED_NAMES[@]}")"
fi
if [ "${#SKIPPED_NAMES[@]}" -eq 0 ]; then
  SKIPPED_CSV=""
else
  SKIPPED_CSV="$(join_csv "${SKIPPED_NAMES[@]}")"
fi

# Emit deterministic output. NO timestamps, NO randomness.
if [ "$ZERO_INCLUDED" -eq 1 ]; then
  printf 'WARNING: No review gates included -- check project configuration\n'
fi
printf 'composite=%s\n' "$COMPOSITE"
printf 'review_gate=%s\n' "$REVIEW_GATE"
printf 'included=%s\n' "$INCLUDED_CSV"
printf 'skipped=%s\n' "$SKIPPED_CSV"
i=0
while [ "$i" -lt "${#INCLUDED_NAMES[@]}" ]; do
  printf 'gate=%s verdict=%s\n' "${INCLUDED_NAMES[$i]}" "${INCLUDED_VERDICTS[$i]}"
  i=$((i + 1))
done
i=0
while [ "$i" -lt "${#SKIPPED_NAMES[@]}" ]; do
  printf '%s skipped — %s\n' "${SKIPPED_NAMES[$i]}" "${SKIPPED_REASONS[$i]}"
  i=$((i + 1))
done
exit 0
