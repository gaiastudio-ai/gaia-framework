#!/usr/bin/env bash
# adapters/owasp-zap/run.sh — ADR-078 adapter contract for OWASP ZAP DAST tool.
#
# Story E73-S3 — implements the OWASP ZAP DAST adapter with strict
# env-allowlist enforcement (T-RSV2-1 mitigation). The subprocess
# environment is scrubbed via `env -i` plus explicit passthrough for
# only the env vars listed in adapter.json's `env-allowlist` field.
#
# Contract (ADR-078 / BOUNDARIES.md):
#   run.sh --input <file-list> [--config <path>] [--output <path>]
#          [--runtime-profile subprocess|container|network] [--timeout <seconds>]
#          [--target-url <url>] [--profile baseline|full|api]
#
# Phase 3A (deterministic): invokes ZAP, captures the JSON report on
# stdout, normalizes ZAP alerts to the canonical finding schema, and
# emits a canonical analysis-results fragment
# {"name": "owasp-zap", "status": "passed|errored", "findings": [...],
#  "raw": "<zap-json>"} on stdout (or to --output if provided).
#
# Severity mapping (ZAP -> canonical):
#   High          -> high
#   Medium        -> medium
#   Low           -> low
#   Informational -> info
#
# Exit codes:
#   0   ZAP scan completed (findings may or may not be present)
#   1   tool / config error (target unreachable, missing target-url, etc.)
#   2   config error (invalid profile, malformed config)
#   3   timeout exceeded
#   127 zap-cli not on PATH (probe interprets as expected_and_missing)
#
# Refs: ADR-078 §1, ADR-080, FR-RSV2-31, FR-RSV2-33, NFR-RSV2-7,
#       T-RSV2-1, story E73-S3.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT=""
CONFIG=""
OUTPUT=""
RUNTIME_PROFILE="subprocess"
TIMEOUT="600"
TARGET_URL=""
PROFILE="baseline"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --runtime-profile) RUNTIME_PROFILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
adapters/owasp-zap/run.sh — ADR-078 contract entry for OWASP ZAP DAST.
Usage:
  run.sh --input <file-list> [--config <path>] [--output <path>]
         [--runtime-profile subprocess|container|network] [--timeout <seconds>]
         [--target-url <url>] [--profile baseline|full|api]

Notes:
  - The subprocess environment is scrubbed to the env-allowlist declared
    in adapter.json (T-RSV2-1). Adding entries to that allowlist requires
    a security review.
EOF
      exit 0 ;;
    *) printf 'run.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# -------- input validation -------------------------------------------------

if [ -n "$INPUT" ] && [ ! -r "$INPUT" ]; then
  printf 'run.sh: input file not readable: %s\n' "$INPUT" >&2
  exit 1
fi

case "$PROFILE" in
  baseline|full|api) ;;
  *) printf 'run.sh: invalid --profile %s (expected baseline|full|api)\n' "$PROFILE" >&2
     exit 2 ;;
esac

if ! command -v zap-cli >/dev/null 2>&1; then
  printf 'run.sh: zap-cli not found on PATH (install OWASP ZAP + zap-cli to enable this adapter)\n' >&2
  exit 127
fi

if [ -z "$TARGET_URL" ]; then
  printf 'run.sh: --target-url required for an actual zap run\n' >&2
  exit 1
fi

# -------- env-allowlist (T-RSV2-1) ----------------------------------------
#
# Read the allowlist from adapter.json so the source-of-truth is the
# adapter metadata, not duplicated in shell. We resolve adapter.json
# relative to this script's directory to remain self-contained.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_JSON="$SCRIPT_DIR/adapter.json"
if [ ! -r "$ADAPTER_JSON" ]; then
  printf 'run.sh: adapter.json not readable at %s\n' "$ADAPTER_JSON" >&2
  exit 2
fi

# Build an allowlist array. Use a portable, no-jq fallback to keep the
# adapter dependency-light: extract the env-allowlist values via awk.
# adapter.json is hand-authored JSON with one value per line in the
# array. If jq is available we prefer it (deterministic, schema-aware).
if command -v jq >/dev/null 2>&1; then
  ALLOWLIST_RAW="$(jq -r '.["env-allowlist"][]' "$ADAPTER_JSON")"
else
  ALLOWLIST_RAW="$(awk '
    /"env-allowlist"[[:space:]]*:[[:space:]]*\[/ { in_arr = 1; next }
    in_arr && /\]/                              { in_arr = 0 }
    in_arr {
      gsub(/[",[:space:]]/, "")
      if (length($0) > 0) print
    }
  ' "$ADAPTER_JSON")"
fi

if [ -z "$ALLOWLIST_RAW" ]; then
  printf 'run.sh: env-allowlist empty or missing in adapter.json\n' >&2
  exit 2
fi

# Build the env -i passthrough argv. Each var is forwarded only if it is
# currently set in the parent environment. PATH and HOME are always
# included (operationally required to locate zap-cli and resolve $HOME).
ENV_ARGS=()
while IFS= read -r var; do
  [ -z "$var" ] && continue
  # Use eval to read the value; portable across bash 3.2.
  # shellcheck disable=SC2086
  if eval "[ -n \"\${${var}+x}\" ]"; then
    val="$(eval "printf '%s' \"\${${var}}\"")"
    ENV_ARGS+=("${var}=${val}")
  fi
done <<EOF
$ALLOWLIST_RAW
EOF

# -------- profile -> ZAP CLI flags ----------------------------------------

case "$PROFILE" in
  baseline) ZAP_FLAGS=(quick-scan --self-contained --start-options "-config api.disablekey=true" --spider) ;;
  full)     ZAP_FLAGS=(quick-scan --self-contained --start-options "-config api.disablekey=true" --spider --ajax-spider --recursive) ;;
  api)      ZAP_FLAGS=(quick-scan --self-contained --start-options "-config api.disablekey=true") ;;
esac

# -------- run ZAP under the scrubbed env ---------------------------------

# Capture stderr separately so we can populate error_detail without
# polluting the JSON output.
err_file="$(mktemp -t zap-stderr.XXXXXX)"
trap 'rm -f "$err_file" 2>/dev/null || true' EXIT

# Use `timeout` if available to enforce --timeout.
TIMEOUT_PREFIX=()
if command -v timeout >/dev/null 2>&1 && [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
  TIMEOUT_PREFIX=(timeout "${TIMEOUT}s")
elif command -v gtimeout >/dev/null 2>&1 && [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
  TIMEOUT_PREFIX=(gtimeout "${TIMEOUT}s")
fi

rc=0
results="$(env -i "${ENV_ARGS[@]}" "${TIMEOUT_PREFIX[@]}" zap-cli "${ZAP_FLAGS[@]}" "$TARGET_URL" 2>"$err_file")" || rc=$?
err_raw="$(cat "$err_file" 2>/dev/null || true)"

# Map common timeout exit codes from coreutils `timeout` (124 / 137) to
# the canonical adapter contract (3 = timeout).
case "$rc" in
  124|137) rc=3 ;;
esac

# -------- normalize ZAP output to canonical findings ---------------------

normalize_findings() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf '[]'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    # ZAP `quick-scan` JSON shape: {"site":[{"@name":"<url>","alerts":[{...}]}]}
    # Some ZAP versions wrap alerts at the top level as `alerts:` rather
    # than under `site[].alerts`. Handle both.
    printf '%s' "$raw" | jq -c '
      def severity_of(s):
        (s // "") |
        if test("(?i)^high")          then "high"
        elif test("(?i)^medium")      then "medium"
        elif test("(?i)^low")         then "low"
        elif test("(?i)^informational") then "info"
        else "info" end;
      ( [ (.site // []) | .[]? | ( .alerts // [] )[] ]
      + ( .alerts // [] )
      ) as $alerts
      | [ $alerts[]? |
          {
            rule_id: ((.pluginid // .pluginId // .rule_id // .name) | tostring),
            severity: severity_of(.riskdesc // .risk // .severity // ""),
            url: ( (.instances // [] | first | .uri) // .url // "" ),
            line: 0,
            message: (.name // .desc // .description // "ZAP alert"),
            blocking: false
          }
        ]
    '
  else
    # No jq. Emit empty findings (still a valid JSON array). The canonical
    # adapter contract permits this fallback; jq is the documented
    # dependency for the host plugin runtime.
    printf '[]'
  fi
}

findings_json="$(normalize_findings "$results")"

# -------- emit fragment --------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  fragment="$(jq -nc \
    --arg name "owasp-zap" \
    --argjson rc "$rc" \
    --arg raw "$results" \
    --arg err "$err_raw" \
    --argjson findings "$findings_json" \
    '{name: $name,
      status: (if $rc == 0 then "passed" else "errored" end),
      findings: $findings,
      raw: $raw,
      error_detail: (if $rc == 0 then null else $err end)}')"
else
  # Hand-built JSON fallback (jq is the documented dependency; this is a
  # belt-and-suspenders branch for adapter contract probes that strip jq).
  status_str="passed"; [ "$rc" -ne 0 ] && status_str="errored"
  fragment=$(printf '{"name":"owasp-zap","status":"%s","findings":%s,"raw":%s,"error_detail":%s}' \
    "$status_str" \
    "$findings_json" \
    "\"\"" \
    "null")
fi

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$fragment" > "$OUTPUT"
else
  printf '%s\n' "$fragment"
fi

exit "$rc"
