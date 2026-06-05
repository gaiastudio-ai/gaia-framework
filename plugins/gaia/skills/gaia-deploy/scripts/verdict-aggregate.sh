#!/usr/bin/env bash
# verdict-aggregate.sh — /gaia-deploy final-verdict aggregation.
#
# Reads every per-suite JSON under <evidence-dir>/smoke/*.json (excluding
# `_skip-smoke.json`) and aggregates the deployment verdict:
#   - any suite verdict ∈ {BLOCKED, REQUEST_CHANGES} → final FAILED
#   - all suite verdicts ∈ {APPROVE} → final PASSED
#   - --skip-smoke → final PASSED with `skip_smoke: true` and a WARNING note
#
# Writes <evidence-dir>/deployment-report.json. Echoes the final verdict on
# stdout (PASSED | FAILED).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/verdict-aggregate.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

EVIDENCE_DIR=""
ENV_NAME=""
VERSION=""
SKIP_SMOKE="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE="true"; shift ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — final verdict aggregation.
Usage:
  $SCRIPT_NAME --evidence-dir <dir> --env <env> --version <ver> [--skip-smoke]
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$EVIDENCE_DIR" ] || [ -z "$ENV_NAME" ] || [ -z "$VERSION" ]; then
  log "usage: --evidence-dir <dir> --env <env> --version <ver> [--skip-smoke]"
  exit 2
fi

REPORT="$EVIDENCE_DIR/deployment-report.json"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

per_suite_json="[]"
final="PASSED"

if [ "$SKIP_SMOKE" = "true" ]; then
  log "WARNING: smoke phase was skipped — final verdict is deploy-only"
  final="PASSED"
else
  # Aggregate per-suite results.
  smoke_dir="$EVIDENCE_DIR/smoke"
  if [ -d "$smoke_dir" ]; then
    # Collect every <suite>.json (skip _skip-smoke.json).
    shopt -s nullglob
    files=()
    for f in "$smoke_dir"/*.json; do
      base="$(basename "$f")"
      [ "$base" = "_skip-smoke.json" ] && continue
      files+=("$f")
    done
    shopt -u nullglob
    if [ "${#files[@]}" -gt 0 ]; then
      per_suite_json="$(jq -s '.' "${files[@]}")"
      # FAILED if ANY suite is BLOCKED or REQUEST_CHANGES.
      bad="$(printf '%s' "$per_suite_json" | jq -r '.[] | select(.verdict == "BLOCKED" or .verdict == "REQUEST_CHANGES") | .name' | head -1)"
      if [ -n "$bad" ]; then
        final="FAILED"
      fi
    fi
  fi
fi

jq -n \
  --arg env "$ENV_NAME" \
  --arg version "$VERSION" \
  --arg timestamp "$TIMESTAMP" \
  --arg final "$final" \
  --argjson skip "$([ "$SKIP_SMOKE" = "true" ] && echo true || echo false)" \
  --argjson suites "$per_suite_json" \
  '{
     environment: $env,
     version: $version,
     timestamp: $timestamp,
     final_verdict: $final,
     skip_smoke: $skip,
     suites: $suites
   }' \
  > "$REPORT"

printf '%s\n' "$final"

if [ "$final" = "PASSED" ]; then
  log "final verdict: PASSED (env=$ENV_NAME version=$VERSION)"
  exit 0
fi
log "final verdict: FAILED — see $REPORT"
exit 1
