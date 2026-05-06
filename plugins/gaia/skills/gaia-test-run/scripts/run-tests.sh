#!/usr/bin/env bash
# run-tests.sh — gaia-test-run main runner (E72-S1)
#
# Resolves test_execution.{tier}.placement, dispatches to the configured
# runner (local) or emits a dry-run line (any non-local placement), and
# emits a structured verdict.
#
# Story: E72-S1 (FR-RSV2-39, FR-RSV2-40, ADR-077)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-run/run-tests.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---- Locate resolve-config.sh -------------------------------------------
RESOLVE_CONFIG=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh" ]; then
  RESOLVE_CONFIG="${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh"
elif command -v resolve-config.sh >/dev/null 2>&1; then
  RESOLVE_CONFIG="$(command -v resolve-config.sh)"
elif [ -x "${SCRIPT_DIR}/../../../scripts/resolve-config.sh" ]; then
  RESOLVE_CONFIG="${SCRIPT_DIR}/../../../scripts/resolve-config.sh"
fi

resolve_field() {
  local key="$1"
  if [ -z "$RESOLVE_CONFIG" ]; then
    echo ""
    return 0
  fi
  bash "$RESOLVE_CONFIG" --field "$key" 2>/dev/null || true
}

# ---- Parse flags --------------------------------------------------------
TIER=1
TAG=""
STORY=""
FILE=""
JSON_OUT=0
NO_EXECUTE=0   # internal flag for AC6 default-tier check without invoking a runner

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2;;
    --tier=*) TIER="${1#--tier=}"; shift;;
    --tag) TAG="$2"; shift 2;;
    --tag=*) TAG="${1#--tag=}"; shift;;
    --story) STORY="$2"; shift 2;;
    --story=*) STORY="${1#--story=}"; shift;;
    --file) FILE="$2"; shift 2;;
    --file=*) FILE="${1#--file=}"; shift;;
    --json) JSON_OUT=1; shift;;
    --no-execute) NO_EXECUTE=1; shift;;
    -h|--help) sed -n '1,20p' "$0"; exit 0;;
    *) log "unknown flag: $1"; shift;;
  esac
done

case "$TIER" in
  1|2|3) ;;
  *) log "invalid tier '$TIER' (must be 1, 2, or 3)"; exit 64;;
esac

# ---- Resolve placement (AC9) --------------------------------------------
PLACEMENT="$(resolve_field "test_execution.tier_${TIER}.placement")"
PLACEMENT="${PLACEMENT//\"/}"   # strip quotes if any
PLACEMENT="${PLACEMENT## }"
PLACEMENT="${PLACEMENT%% }"

if [ -z "$PLACEMENT" ]; then
  echo "ERROR: test_execution section not configured in project-config.yaml. Run /gaia-config-ci or add the section manually." >&2
  exit 2
fi

# ---- AC6: short-circuit no-execute path for default-tier verification ---
if [ "$NO_EXECUTE" -eq 1 ]; then
  echo "tier=${TIER}"
  echo "environment=${PLACEMENT}"
  exit 0
fi

# ---- Resolve runner provider --------------------------------------------
PROVIDER="$(resolve_field "tools.test_runner.provider")"
PROVIDER="${PROVIDER//\"/}"
PROVIDER="${PROVIDER## }"
PROVIDER="${PROVIDER%% }"

# ---- Compose targeting args (forwarded verbatim — generic v1) -----------
TARGET_ARGS=()
if [ -n "$TAG" ]; then
  TARGET_ARGS+=("--tag" "$TAG")
fi
if [ -n "$STORY" ]; then
  TARGET_ARGS+=("--story" "$STORY")
fi
if [ -n "$FILE" ]; then
  TARGET_ARGS+=("$FILE")
fi

emit_verdict() {
  local status="$1" duration_ms="$2" test_count="$3" pass_count="$4" \
        fail_count="$5" skip_count="$6" flake_line="$7" raw_output="$8"
  local flake_suspected="false"
  local flake_reason=""
  if printf '%s' "$flake_line" | grep -q 'flake_suspected=true'; then
    flake_suspected="true"
    flake_reason="$(printf '%s' "$flake_line" | sed -n 's/.*reason=//p')"
  fi
  if [ "$JSON_OUT" -eq 1 ]; then
    printf '{"status":"%s","tier":%s,"environment":"%s","duration_ms":%s,"test_count":%s,"pass_count":%s,"fail_count":%s,"skip_count":%s,"flake_suspected":%s' \
      "$status" "$TIER" "$PLACEMENT" "$duration_ms" "$test_count" "$pass_count" "$fail_count" "$skip_count" "$flake_suspected"
    if [ -n "$flake_reason" ]; then
      printf ',"flake_reason":"%s"' "$flake_reason"
    fi
    printf '}\n'
  else
    echo "Tier:        ${TIER}"
    echo "Environment: ${PLACEMENT}"
    echo "Status:      ${status}"
    echo "Tests:       ${pass_count} passed | ${fail_count} failed | ${skip_count} skipped (${test_count} total)"
    echo "Duration:    ${duration_ms} ms"
    if [ "$flake_suspected" = "true" ]; then
      echo "Flake:       suspected (${flake_reason})"
    fi
    echo ""
    echo "Verdict: {\"status\":\"${status}\",\"tier\":${TIER},\"environment\":\"${PLACEMENT}\",\"duration_ms\":${duration_ms},\"test_count\":${test_count},\"pass_count\":${pass_count},\"fail_count\":${fail_count},\"skip_count\":${skip_count},\"flake_suspected\":${flake_suspected}}"
  fi
}

# ---- Dry-run path (any non-local placement) -----------------------------
if [ "$PLACEMENT" != "local" ]; then
  CMD="${PROVIDER:-<configured-runner>}"
  if [ "${#TARGET_ARGS[@]}" -gt 0 ]; then
    for arg in "${TARGET_ARGS[@]}"; do CMD="$CMD $arg"; done
  fi
  echo "dry-run: tier ${TIER} maps to environment '${PLACEMENT}' — would execute: ${CMD}"
  echo "(remote execution for non-local placements lands in E73 deployment-phase skills)"
  emit_verdict "DRY_RUN" 0 0 0 0 0 "flake_suspected=false" ""
  exit 0
fi

# ---- Local execution ----------------------------------------------------
if [ -z "$PROVIDER" ]; then
  # Fall back: detect by file presence in CWD.
  if [ -f vitest.config.ts ] || [ -f vitest.config.js ]; then
    PROVIDER="vitest"
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then
    PROVIDER="pytest"
  elif compgen -G "*.bats" >/dev/null; then
    PROVIDER="bats"
  elif [ -f go.mod ]; then
    PROVIDER="go"
  else
    log "no test runner configured and no detection match in CWD"
    emit_verdict "FAILED" 0 0 0 0 0 "flake_suspected=false" ""
    exit 3
  fi
fi

START_NS="$(date +%s%N 2>/dev/null || echo 0)"
if [ "${#TARGET_ARGS[@]}" -gt 0 ]; then
  RAW_OUTPUT="$( "$PROVIDER" "${TARGET_ARGS[@]}" 2>&1 )" || RUNNER_EXIT=$?
else
  RAW_OUTPUT="$( "$PROVIDER" 2>&1 )" || RUNNER_EXIT=$?
fi
RUNNER_EXIT="${RUNNER_EXIT:-0}"
END_NS="$(date +%s%N 2>/dev/null || echo 0)"

if [ "$START_NS" -eq 0 ] || [ "$END_NS" -eq 0 ]; then
  DURATION_MS=0
else
  DURATION_MS=$(( (END_NS - START_NS) / 1000000 ))
fi

# Parse counts via parse-output.sh.
PARSED="$(printf '%s\n' "$RAW_OUTPUT" | "${SCRIPT_DIR}/parse-output.sh")"
TEST_COUNT="$(printf '%s' "$PARSED" | sed -n 's/.*test_count=\([0-9]*\).*/\1/p' | head -1)"
PASS_COUNT="$(printf '%s' "$PARSED" | sed -n 's/.*pass_count=\([0-9]*\).*/\1/p' | head -1)"
FAIL_COUNT="$(printf '%s' "$PARSED" | sed -n 's/.*fail_count=\([0-9]*\).*/\1/p' | head -1)"
SKIP_COUNT="$(printf '%s' "$PARSED" | sed -n 's/.*skip_count=\([0-9]*\).*/\1/p' | head -1)"
TEST_COUNT="${TEST_COUNT:-0}"
PASS_COUNT="${PASS_COUNT:-0}"
FAIL_COUNT="${FAIL_COUNT:-0}"
SKIP_COUNT="${SKIP_COUNT:-0}"

# Phase 3B — flake detection.
FLAKE_LINE="$(printf '%s\n' "$RAW_OUTPUT" | "${SCRIPT_DIR}/flake-detect.sh")"

# Verdict status.
if [ "$RUNNER_EXIT" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  STATUS="PASSED"
else
  STATUS="FAILED"
fi

# For human-readable output, always echo the captured runner output FIRST so
# bats tests that match against runner-side strings (story key, file path,
# tag name) can still hit them.
if [ "$JSON_OUT" -eq 0 ]; then
  printf '%s\n' "$RAW_OUTPUT"
fi

emit_verdict "$STATUS" "$DURATION_MS" "$TEST_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$FLAKE_LINE" "$RAW_OUTPUT"

if [ "$STATUS" = "PASSED" ]; then
  exit 0
else
  exit "$RUNNER_EXIT"
fi
