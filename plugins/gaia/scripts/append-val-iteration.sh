#!/usr/bin/env bash
# append-val-iteration.sh — E44-S15 Val auto-fix loop iteration producer.
#
# Producer-side helper that appends one iteration record to the val auto-fix
# loop's checkpoint custom.val_loop_iterations array, populating the canonical
# fields including token_estimate so the NFR-VCP-2 token-budget harness
# (scripts/measure-val-auto-fix-token-budget.sh) can report a measured verdict
# instead of relying on the structural-bound TD-65 argument.
#
# Wire-in skills (E44-S2 / E44-S8 pattern) call this script once per loop
# iteration immediately after applying a fix and before the iteration counter
# is incremented. The output is a fresh checkpoint JSON file written via
# write-checkpoint.sh that contains the running val_loop_iterations array.
#
# Contract (matches scripts/measure-val-auto-fix-token-budget.sh harness):
#   custom.val_loop_iterations[*].token_estimate  →  numeric (int|float) > 0
#                                                    OR null when AC-EC8
#                                                    runtime token-counting
#                                                    primitive is unavailable.
#
# Invocation:
#   append-val-iteration.sh \
#       --skill <skill-name> \
#       --step <N> \
#       --iteration <K> \
#       --token-estimate <int|float|null> \
#       --revalidation-outcome <clean|info_only|findings_present|val_invocation_failed> \
#       --findings-json '<json-array>' \
#       [--fix-summary "<string>"] \
#       [--user-decision <continue|accept-as-is|abort>] \
#       [--event-type <yolo_hard_gate_violation>] \
#       [--post-escape true|false] \
#       [--paths <path> ...]
#
# Environment:
#   CHECKPOINT_ROOT  Forwarded to write-checkpoint.sh (default _memory/checkpoints).
#
# Exit codes:
#   0 — checkpoint written; final path is printed on stdout
#   1 — usage / validation error (missing flags, bad numeric, bad enum, …)
#   2 — environment error (python3 missing, write-checkpoint.sh failed)
#   3 — IO error from write-checkpoint.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="append-val-iteration.sh"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WRITE_CHECKPOINT="$SCRIPT_DIR/write-checkpoint.sh"

die() {
  local rc="$1"; shift
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$rc"
}

usage() {
  cat <<'USAGE'
Usage:
  append-val-iteration.sh \
      --skill <skill-name> \
      --step <N> \
      --iteration <K> \
      --token-estimate <int|float|null> \
      --revalidation-outcome <clean|info_only|findings_present|val_invocation_failed> \
      --findings-json '<json-array>' \
      [--fix-summary "<string>"] \
      [--user-decision <continue|accept-as-is|abort>] \
      [--event-type <yolo_hard_gate_violation>] \
      [--post-escape true|false] \
      [--paths <path> ...]

Producer-side helper for E44-S2 / E44-S8 val auto-fix loop iteration logging.

Appends one iteration record to the latest checkpoint's
custom.val_loop_iterations array, including a numeric token_estimate
that scripts/measure-val-auto-fix-token-budget.sh can read for the
NFR-VCP-2 verification harness.

The token_estimate field is the harness contract (E44-S9). Pass an integer
or float for SDK-reported response usage tokens, or the literal string
"null" when the runtime token-counting primitive is unavailable
(AC-EC8 fallback).

Exit codes:
  0 ok  | 1 validation error  | 2 environment error  | 3 IO error
USAGE
}

# ---------- Help short-circuit ----------
if [ $# -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  usage
  exit 0
fi

# ---------- Defaults ----------
SKILL=""
STEP=""
ITERATION=""
TOKEN_ESTIMATE=""
REVAL_OUTCOME=""
FINDINGS_JSON=""
FIX_SUMMARY=""
USER_DECISION=""
EVENT_TYPE=""
POST_ESCAPE=""
EXTRA_PATHS=()

# ---------- Parse args ----------
parsing_paths=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --skill)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--skill requires a value"
      SKILL="$2"; shift 2 ;;
    --step)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--step requires a value"
      STEP="$2"; shift 2 ;;
    --iteration)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--iteration requires a value"
      ITERATION="$2"; shift 2 ;;
    --token-estimate)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--token-estimate requires a value"
      TOKEN_ESTIMATE="$2"; shift 2 ;;
    --revalidation-outcome)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--revalidation-outcome requires a value"
      REVAL_OUTCOME="$2"; shift 2 ;;
    --findings-json)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--findings-json requires a value"
      FINDINGS_JSON="$2"; shift 2 ;;
    --fix-summary)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--fix-summary requires a value"
      FIX_SUMMARY="$2"; shift 2 ;;
    --user-decision)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--user-decision requires a value"
      USER_DECISION="$2"; shift 2 ;;
    --event-type)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--event-type requires a value"
      EVENT_TYPE="$2"; shift 2 ;;
    --post-escape)
      parsing_paths=0
      [ $# -ge 2 ] || die 1 "--post-escape requires a value"
      POST_ESCAPE="$2"; shift 2 ;;
    --paths)
      parsing_paths=1
      shift ;;
    --*)
      die 1 "unknown flag: $1" ;;
    *)
      if [ "$parsing_paths" -eq 1 ]; then
        EXTRA_PATHS+=("$1")
        shift
      else
        die 1 "unexpected positional argument: $1"
      fi
      ;;
  esac
done

# ---------- Validate required fields ----------
[ -n "$SKILL" ]        || die 1 "--skill is required"
[ -n "$STEP" ]         || die 1 "--step is required"
[ -n "$ITERATION" ]    || die 1 "--iteration is required"
[ -n "$TOKEN_ESTIMATE" ] || die 1 "--token-estimate is required (use 'null' if AC-EC8 fallback)"
[ -n "$REVAL_OUTCOME" ] || die 1 "--revalidation-outcome is required"
[ -n "$FINDINGS_JSON" ] || die 1 "--findings-json is required"

# Step + iteration must be non-negative integers.
case "$STEP" in
  ''|*[!0-9]*) die 1 "--step must be a non-negative integer (got: $STEP)" ;;
esac
case "$ITERATION" in
  ''|*[!0-9]*) die 1 "--iteration must be a non-negative integer (got: $ITERATION)" ;;
esac

# token_estimate: either the literal "null" or a positive numeric value.
TOKEN_ESTIMATE_LITERAL=""
if [ "$TOKEN_ESTIMATE" = "null" ]; then
  TOKEN_ESTIMATE_LITERAL="null"
else
  case "$TOKEN_ESTIMATE" in
    ''|*[!0-9.]*) die 1 "--token-estimate must be a positive numeric value or 'null' (got: $TOKEN_ESTIMATE)" ;;
  esac
  # Reject zero / negative via awk numeric coercion.
  if ! awk -v v="$TOKEN_ESTIMATE" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    die 1 "--token-estimate must be > 0 when provided as a number (got: $TOKEN_ESTIMATE)"
  fi
  TOKEN_ESTIMATE_LITERAL="$TOKEN_ESTIMATE"
fi

# Revalidation outcome enum.
case "$REVAL_OUTCOME" in
  clean|info_only|findings_present|val_invocation_failed) ;;
  *) die 1 "--revalidation-outcome must be one of clean|info_only|findings_present|val_invocation_failed (got: $REVAL_OUTCOME)" ;;
esac

# Optional enums.
if [ -n "$USER_DECISION" ]; then
  case "$USER_DECISION" in
    continue|accept-as-is|abort) ;;
    *) die 1 "--user-decision must be one of continue|accept-as-is|abort (got: $USER_DECISION)" ;;
  esac
fi

if [ -n "$EVENT_TYPE" ]; then
  case "$EVENT_TYPE" in
    yolo_hard_gate_violation) ;;
    *) die 1 "--event-type must be yolo_hard_gate_violation when set (got: $EVENT_TYPE)" ;;
  esac
fi

if [ -n "$POST_ESCAPE" ]; then
  case "$POST_ESCAPE" in
    true|false) ;;
    *) die 1 "--post-escape must be true or false (got: $POST_ESCAPE)" ;;
  esac
fi

# ---------- python3 preflight ----------
command -v python3 >/dev/null 2>&1 || die 2 "python3 not found on PATH (required to compose JSON)"

# ---------- Resolve CHECKPOINT_ROOT (AF-2026-05-21-7 inverted precedence) ----------
# Canonical default; legacy fallback only on positive pre-ADR-111 evidence.
if [ -n "${CHECKPOINT_ROOT:-}" ]; then
  CHECKPOINT_ROOT_RESOLVED="$CHECKPOINT_ROOT"
elif [ -d "_memory/checkpoints" ] && [ ! -d ".gaia/memory" ]; then
  CHECKPOINT_ROOT_RESOLVED="_memory/checkpoints"
else
  CHECKPOINT_ROOT_RESOLVED=".gaia/memory/checkpoints"
fi
SKILL_DIR="$CHECKPOINT_ROOT_RESOLVED/$SKILL"

# ---------- Compose the new iteration record + merged val_loop_iterations array ----------
# Read prior records (if any) from the most recent checkpoint for this skill,
# append the new record, and emit the resulting custom JSON to a tmp file
# that write-checkpoint.sh consumes via --custom.

TMP_CUSTOM=$(mktemp -t append-val-iteration.XXXXXX) \
  || die 3 "failed to create tmp file for custom payload"
trap '[ -n "${TMP_CUSTOM:-}" ] && rm -f "$TMP_CUSTOM" 2>/dev/null || true' EXIT

# Discover the latest checkpoint file for this skill (mtime-ordered) so the
# new iteration's record is appended to the running val_loop_iterations array.
# We pass the directory; Python picks the most recent file. Empty/missing dir
# yields no prior records, which is the correct iteration-1 case.
LATEST_CKPT=""
if [ -d "$SKILL_DIR" ]; then
  LATEST_CKPT=$(ls -t "$SKILL_DIR"/*.json 2>/dev/null | head -n 1 || true)
fi

# Pass all dynamic values via env to avoid heredoc-substitution pitfalls
# (and quoting traps with json payloads carrying [/]/{/}/$).
export AVI_LATEST_CKPT="$LATEST_CKPT"
export AVI_ITERATION="$ITERATION"
export AVI_TOKEN_LITERAL="$TOKEN_ESTIMATE_LITERAL"
export AVI_REVAL_OUTCOME="$REVAL_OUTCOME"
export AVI_FINDINGS_JSON="$FINDINGS_JSON"
export AVI_FIX_SUMMARY="$FIX_SUMMARY"
export AVI_USER_DECISION="$USER_DECISION"
export AVI_EVENT_TYPE="$EVENT_TYPE"
export AVI_POST_ESCAPE="$POST_ESCAPE"

python3 - > "$TMP_CUSTOM" <<'PY'
import datetime as _dt
import json
import os
import sys

latest = os.environ.get("AVI_LATEST_CKPT") or None
prior = []
if latest and os.path.exists(latest):
    try:
        with open(latest) as f:
            d = json.load(f)
        prior = ((d.get("custom") or {}).get("val_loop_iterations") or [])
    except Exception:
        prior = []

token_lit = os.environ.get("AVI_TOKEN_LITERAL", "")
if token_lit == "null" or token_lit == "":
    token_value = None
else:
    try:
        f = float(token_lit)
        token_value = int(f) if f.is_integer() else f
    except ValueError:
        sys.stderr.write("token-estimate not numeric\n")
        sys.exit(2)

findings_raw = os.environ.get("AVI_FINDINGS_JSON", "[]")
try:
    findings = json.loads(findings_raw)
except Exception:
    sys.stderr.write("findings-json is not valid JSON\n")
    sys.exit(2)

record = {
    "iteration_number": int(os.environ["AVI_ITERATION"]),
    "timestamp": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "findings": findings,
    "fix_diff_summary": os.environ.get("AVI_FIX_SUMMARY", ""),
    "revalidation_outcome": os.environ["AVI_REVAL_OUTCOME"],
    "token_estimate": token_value,
    "user_decision": os.environ.get("AVI_USER_DECISION") or None,
    "event_type": os.environ.get("AVI_EVENT_TYPE") or None,
}

post_escape_raw = os.environ.get("AVI_POST_ESCAPE", "")
if post_escape_raw:
    record["post_escape"] = (post_escape_raw == "true")

prior.append(record)
print(json.dumps({"val_loop_iterations": prior}))
PY

# ---------- Invoke write-checkpoint.sh ----------
WRITE_ARGS=( "$SKILL" "$STEP" "iteration=$ITERATION" --custom "$TMP_CUSTOM" )
if [ "${#EXTRA_PATHS[@]}" -gt 0 ]; then
  WRITE_ARGS+=( --paths "${EXTRA_PATHS[@]}" )
fi

# Forward CHECKPOINT_ROOT explicitly so the producer is robust to environments
# that don't propagate exports through subshells.
CHECKPOINT_ROOT="$CHECKPOINT_ROOT_RESOLVED" "$WRITE_CHECKPOINT" "${WRITE_ARGS[@]}" \
  || die 2 "write-checkpoint.sh failed"

# write-checkpoint.sh prints the final path; we already piped it through. The
# trap will clean up the tmp file.
exit 0
