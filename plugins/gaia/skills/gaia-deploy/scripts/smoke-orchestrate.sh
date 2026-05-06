#!/usr/bin/env bash
# smoke-orchestrate.sh — /gaia-deploy Pattern A post-deploy smoke phase (E73-S5, AC5, AC14).
#
# Reads the deployment-phase smoke suites from a newline-delimited file
# (--suites-file). For each suite, invokes a runner that returns the suite's
# verdict on stdout. The default runner is the Skill tool (via the
# orchestrator); test seam: GAIA_DEPLOY_SMOKE_RUNNER points to an executable
# that takes <suite-name> <target-url> <output-dir> and prints
# APPROVE / REQUEST_CHANGES / BLOCKED.
#
# --skip-smoke shortcut: emit a WARNING line and exit 0 (AC14).
#
# Per-suite result is written to <output-dir>/<suite>.json.
# Aggregate is left to verdict-aggregate.sh.
#
# Refs: ADR-080, AC5, AC14.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-deploy/smoke-orchestrate.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

SUITES_FILE=""
TARGET_URL=""
OUTPUT_DIR=""
SKIP_SMOKE="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --suites-file) SUITES_FILE="$2"; shift 2 ;;
    --target-url) TARGET_URL="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE="true"; shift ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME — post-deploy smoke orchestration (E73-S5, AC5, AC14).
Usage:
  $SCRIPT_NAME --suites-file <path> --target-url <url> --output-dir <dir>
  $SCRIPT_NAME --skip-smoke --output-dir <dir>
EOF
      exit 0 ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$OUTPUT_DIR" ]; then
  log "usage: --output-dir is required"
  exit 2
fi
mkdir -p "$OUTPUT_DIR"

if [ "$SKIP_SMOKE" = "true" ]; then
  log "WARNING: post-deploy smoke skipped per --skip-smoke (operator request)"
  printf '%s\n' "WARNING: smoke tests skipped"
  jq -n '{skipped: true, reason: "operator --skip-smoke"}' > "$OUTPUT_DIR/_skip-smoke.json"
  exit 0
fi

if [ -z "$SUITES_FILE" ] || [ ! -f "$SUITES_FILE" ]; then
  log "BLOCKED: --suites-file required and must exist"
  exit 2
fi
if [ -z "$TARGET_URL" ]; then
  log "BLOCKED: --target-url required when running smoke suites"
  exit 2
fi

RUNNER="${GAIA_DEPLOY_SMOKE_RUNNER:-}"
overall_rc=0

# Read suites and execute sequentially in declared order (AC7).
while IFS= read -r suite; do
  [ -z "$suite" ] && continue
  case "$suite" in \#*) continue ;; esac

  if [ -z "$RUNNER" ]; then
    log "BLOCKED: GAIA_DEPLOY_SMOKE_RUNNER not configured"
    overall_rc=1
    break
  fi

  log "smoke suite: $suite (target=$TARGET_URL)"
  rc=0
  verdict_text="$("$RUNNER" "$suite" "$TARGET_URL" "$OUTPUT_DIR" 2>&1)" || rc=$?
  verdict="$(printf '%s' "$verdict_text" | tr -d '[:space:]' | head -c 32)"
  case "$verdict" in
    APPROVE) ;;
    REQUEST_CHANGES|BLOCKED) overall_rc=1 ;;
    *)
      log "  unknown verdict from $suite: $verdict_text"
      verdict="BLOCKED"
      overall_rc=1 ;;
  esac

  jq -n \
    --arg name "$suite" \
    --arg verdict "$verdict" \
    --argjson rc "$rc" \
    '{name: $name, verdict: $verdict, exit_code: $rc}' \
    > "$OUTPUT_DIR/${suite}.json"
done < "$SUITES_FILE"

if [ "$overall_rc" -ne 0 ]; then
  log "smoke phase: at least one suite failed"
  exit 1
fi

log "smoke phase: all suites APPROVE"
exit 0
