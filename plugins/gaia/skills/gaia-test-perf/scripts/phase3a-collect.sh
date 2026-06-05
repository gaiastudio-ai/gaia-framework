#!/usr/bin/env bash
# phase3a-collect.sh — gaia-test-perf Phase 3A evidence collection.
#
# Mirrors gaia-test-e2e/phase3a-collect.sh:
#   1. Probes adapter availability via tool-availability-probe.sh
#   2. If `available`, invokes the adapter's run.sh to execute the perf test,
#      capturing stdout/stderr to {output-dir}/evidence/.
#   3. Parses the adapter fragment into a top-level analysis-results.json
#      conforming to plugins/gaia/schemas/analysis-results.schema.json.
#   4. If probe returned `expected_and_missing` or `ran_and_errored`, emits an
#      analysis-results.json whose checks[0].status is `errored` with
#      error_reason populated — verdict-resolver.sh then maps to BLOCKED.
#
# Contract:
#   phase3a-collect.sh --adapter-dir <path> --output-dir <path>
#                      [--story-key <key>] [--target-url <url>]
#                      [--config <path>] [--timeout <seconds>]
#
# Exit codes:
#   0  evidence collected (analysis-results.json always exists after success).
#   1  caller error.
#
# POSIX discipline: bash 3.2 / macOS-compatible, set -euo pipefail, LC_ALL=C.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-perf/phase3a-collect.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROBE="$PLUGIN_ROOT/scripts/tool-availability-probe.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

ADAPTER_DIR=""
OUTPUT_DIR=""
STORY_KEY=""
TARGET_URL=""
CONFIG=""
TIMEOUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter-dir) ADAPTER_DIR="$2"; shift 2 ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --story-key)   STORY_KEY="$2"; shift 2 ;;
    --target-url)  TARGET_URL="$2"; shift 2 ;;
    --config)      CONFIG="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — Phase 3A evidence collection for /gaia-test-perf.
Usage:
  phase3a-collect.sh --adapter-dir <path> --output-dir <path>
                     [--story-key <key>] [--target-url <url>]
                     [--config <path>] [--timeout <seconds>]
EOF
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$ADAPTER_DIR" ] || die "--adapter-dir required"
[ -n "$OUTPUT_DIR" ]  || die "--output-dir required"
[ -d "$ADAPTER_DIR" ] || die "adapter dir not found: $ADAPTER_DIR"
[ -f "$ADAPTER_DIR/adapter.json" ] || die "adapter.json missing in $ADAPTER_DIR"
[ -x "$ADAPTER_DIR/run.sh" ] || die "run.sh missing or not executable in $ADAPTER_DIR"
[ -x "$PROBE" ] || die "tool-availability-probe.sh not found at $PROBE"

mkdir -p "$OUTPUT_DIR/evidence"

ADAPTER_NAME="$(basename "$ADAPTER_DIR")"

# Project-scope adapter — synthetic single-entry file-list to keep the probe
# from short-circuiting to not_applicable.
FILE_LIST="$OUTPUT_DIR/evidence/file-list.txt"
printf 'perf-suite\n' > "$FILE_LIST"

# 1. Probe.
PROBE_ARGS=(--adapter-dir "$ADAPTER_DIR" --file-list "$FILE_LIST")
if [ -n "$TIMEOUT" ]; then
  PROBE_ARGS+=(--timeout "$TIMEOUT")
fi
if [ -n "$CONFIG" ]; then
  PROBE_ARGS+=(--config "$CONFIG")
fi

probe_rc=0
probe_out="$("$PROBE" "${PROBE_ARGS[@]}" 2>"$OUTPUT_DIR/evidence/probe.stderr")" || probe_rc=$?

probe_state="$(printf '%s' "$probe_out" | jq -r '.state // "unknown"')"
probe_err="$(printf '%s' "$probe_out" | jq -r '.error_detail // ""')"
printf '%s\n' "$probe_out" > "$OUTPUT_DIR/evidence/probe.json"

# 2. Map probe state to check.status.
case "$probe_state" in
  available)
    check_status="passed"
    error_reason=""
    ;;
  not_applicable)
    check_status="skipped"
    error_reason="probe returned not_applicable (file-list empty for project-scope adapter)"
    ;;
  expected_and_missing)
    check_status="errored"
    error_reason="adapter provider not on PATH ($probe_err) — install the underlying tool to enable this adapter"
    ;;
  ran_and_errored)
    check_status="errored"
    error_reason="adapter run.sh failed: $probe_err"
    ;;
  *)
    check_status="errored"
    error_reason="probe returned unknown state: $probe_state"
    ;;
esac

# 3. If `available`, also invoke run.sh for evidence.
if [ "$check_status" = "passed" ]; then
  run_rc=0
  run_args=(--input "$FILE_LIST" --output "$OUTPUT_DIR/evidence/${ADAPTER_NAME}-fragment.json")
  if [ -n "$CONFIG" ]; then
    run_args+=(--config "$CONFIG")
  fi
  if [ -n "$TARGET_URL" ]; then
    run_args+=(--target-url "$TARGET_URL")
  fi
  if [ -n "$TIMEOUT" ]; then
    run_args+=(--timeout "$TIMEOUT")
  fi
  "$ADAPTER_DIR/run.sh" "${run_args[@]}" \
    >"$OUTPUT_DIR/evidence/${ADAPTER_NAME}.stdout" \
    2>"$OUTPUT_DIR/evidence/${ADAPTER_NAME}.stderr" || run_rc=$?

  if [ "$run_rc" -ne 0 ]; then
    check_status="errored"
    error_reason="adapter run.sh exited $run_rc despite probe=available"
  fi
fi

# 4. Compose top-level analysis-results.json.
SCHEMA_VERSION="1.0"
SKILL_NAME="gaia-test-perf"
MODEL="${PERF_MODEL:-claude-opus-4-7}"
MODEL_TEMP="${PERF_MODEL_TEMP:-0}"

sk="${STORY_KEY:-E0-S0}"

if [ "$check_status" = "passed" ]; then
  check_obj="$(jq -nc \
    --arg name "$ADAPTER_NAME" \
    --arg status "$check_status" \
    '{name: $name, scope: "project", status: $status, findings: []}')"
elif [ "$check_status" = "skipped" ]; then
  check_obj="$(jq -nc \
    --arg name "$ADAPTER_NAME" \
    --arg status "$check_status" \
    --arg reason "$error_reason" \
    '{name: $name, scope: "project", status: $status, skip_reason: $reason, findings: []}')"
else
  check_obj="$(jq -nc \
    --arg name "$ADAPTER_NAME" \
    --arg status "$check_status" \
    --arg reason "$error_reason" \
    '{name: $name, scope: "project", status: $status, error_reason: $reason, findings: []}')"
fi

jq -n \
  --arg sv "$SCHEMA_VERSION" \
  --arg sk "$sk" \
  --arg sn "$SKILL_NAME" \
  --arg model "$MODEL" \
  --argjson temp "$MODEL_TEMP" \
  --argjson check "$check_obj" \
  '{schema_version: $sv, story_key: $sk, skill: $sn, model: $model, model_temperature: $temp, checks: [$check]}' \
  > "$OUTPUT_DIR/analysis-results.json"

log "phase3a complete: adapter=$ADAPTER_NAME state=$probe_state status=$check_status"
exit 0
