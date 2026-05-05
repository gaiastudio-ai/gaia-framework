#!/usr/bin/env bash
# composite-verdict-aggregator.sh — GAIA review-common entry point (E66-S3, ADR-082)
#
# Deterministic shell aggregator that consumes per-gate verdicts produced by the
# six-or-seven verdict-producing review skills (see ADR-077) and emits a
# composite verdict plus the canonical Review Gate vocabulary mapping
# (APPROVE -> PASSED, REQUEST_CHANGES -> FAILED, BLOCKED -> FAILED) per ADR-075.
#
# Pure shell. No LLM. No network. No jitter. Byte-identical output for
# byte-identical input (NFR-RSV2-12). Invariant under YOLO_MODE per ADR-067.
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
# First-match-wins precedence (ADR-082):
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
# Refs: ADR-082, ADR-077, ADR-075, ADR-054, ADR-042, ADR-067,
#       NFR-RSV2-6, NFR-RSV2-12, FR-RSV2-43, FR-RSV2-44.

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
$SCRIPT_NAME — composite verdict aggregator (E66-S3, ADR-082)

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

# Map composite -> Review Gate vocabulary (ADR-075).
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
SKIP_A11Y_REASON=""
SKIP_MOBILE_REASON=""
A11Y_SET=0
SKIP_A11Y_SET=0
MOBILE_SET=0
SKIP_MOBILE_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --code)         [ "$#" -ge 2 ] || die 1 "--code requires a verdict"; CODE="$2"; shift 2 ;;
    --qa)           [ "$#" -ge 2 ] || die 1 "--qa requires a verdict"; QA="$2"; shift 2 ;;
    --test)         [ "$#" -ge 2 ] || die 1 "--test requires a verdict"; TEST="$2"; shift 2 ;;
    --security)     [ "$#" -ge 2 ] || die 1 "--security requires a verdict"; SECURITY="$2"; shift 2 ;;
    --perf)         [ "$#" -ge 2 ] || die 1 "--perf requires a verdict"; PERF="$2"; shift 2 ;;
    --a11y)         [ "$#" -ge 2 ] || die 1 "--a11y requires a verdict"; A11Y="$2"; A11Y_SET=1; shift 2 ;;
    --mobile)       [ "$#" -ge 2 ] || die 1 "--mobile requires a verdict"; MOBILE="$2"; MOBILE_SET=1; shift 2 ;;
    --skip-a11y)    [ "$#" -ge 2 ] || die 1 "--skip-a11y requires a reason"; SKIP_A11Y_REASON="$2"; SKIP_A11Y_SET=1; shift 2 ;;
    --skip-mobile)  [ "$#" -ge 2 ] || die 1 "--skip-mobile requires a reason"; SKIP_MOBILE_REASON="$2"; SKIP_MOBILE_SET=1; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die 1 "unknown argument: $1" ;;
  esac
done

# Required gates.
[ -n "$CODE" ]     || die 1 "missing required --code <verdict>"
[ -n "$QA" ]       || die 1 "missing required --qa <verdict>"
[ -n "$TEST" ]     || die 1 "missing required --test <verdict>"
[ -n "$SECURITY" ] || die 1 "missing required --security <verdict>"
[ -n "$PERF" ]     || die 1 "missing required --perf <verdict>"

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

# Validate verdict values.
for v in "$CODE" "$QA" "$TEST" "$SECURITY" "$PERF"; do
  is_canonical_verdict "$v" || die 1 "invalid verdict '$v' (expected APPROVE|REQUEST_CHANGES|BLOCKED)"
done
if [ "$A11Y_SET" -eq 1 ]; then
  is_canonical_verdict "$A11Y" || die 1 "invalid verdict '$A11Y' for --a11y"
fi
if [ "$MOBILE_SET" -eq 1 ]; then
  is_canonical_verdict "$MOBILE" || die 1 "invalid verdict '$MOBILE' for --mobile"
fi

# Build canonical-order arrays of (name, verdict) for included gates.
INCLUDED_NAMES=("code" "qa" "test" "security" "perf")
INCLUDED_VERDICTS=("$CODE" "$QA" "$TEST" "$SECURITY" "$PERF")
SKIPPED_NAMES=()
SKIPPED_REASONS=()

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

if any_verdict_match "BLOCKED" "${INCLUDED_VERDICTS[@]}"; then
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
INCLUDED_CSV="$(join_csv "${INCLUDED_NAMES[@]}")"
if [ "${#SKIPPED_NAMES[@]}" -eq 0 ]; then
  SKIPPED_CSV=""
else
  SKIPPED_CSV="$(join_csv "${SKIPPED_NAMES[@]}")"
fi

# Emit deterministic output. NO timestamps, NO randomness.
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
