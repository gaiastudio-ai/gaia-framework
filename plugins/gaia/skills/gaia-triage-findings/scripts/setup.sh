#!/usr/bin/env bash
# setup.sh — triage-findings skill setup (E28-S63)
#
# Shared setup pattern from the E28-S17/S19/S21 foundation work.
# Resolves config, validates gates, loads checkpoint state.
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-triage-findings/setup.sh"
WORKFLOW_NAME="triage-findings"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
[ -x "$RESOLVE_CONFIG" ] || die "resolve-config.sh not found or not executable at $RESOLVE_CONFIG"
if ! config_output=$("$RESOLVE_CONFIG" 2>&1); then
  log "resolve-config.sh failed:"
  printf '%s\n' "$config_output" >&2
  exit 1
fi
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

# ---------- 2. Validate gate (prereqs) ----------
# triage-findings requires implementation-artifacts directory to exist.
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists >/dev/null 2>&1; then
    die "validate-gate.sh pre-start gate failed for $WORKFLOW_NAME"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate (non-fatal)"
fi

# ---------- 3. Load checkpoint state ----------
if [ -x "$CHECKPOINT" ]; then
  if "$CHECKPOINT" read --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "checkpoint loaded for $WORKFLOW_NAME"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      log "no prior checkpoint for $WORKFLOW_NAME — fresh run"
    else
      die "checkpoint.sh read failed with exit $rc"
    fi
  fi
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint load (non-fatal)"
fi

# ---------- 4. Emit lifecycle event (skill_invocation) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type skill_invocation --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "lifecycle-event.sh emit failed — continuing (non-fatal)"
  fi
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event (non-fatal)"
fi

# ---------- 5. Write run-start sentinel for finalize fail-closed (AF-2026-05-24-12 / Test02 F-21) ----------
# Test02 F-21 (HIGH): finalize.sh's GAIA_FINALIZE_SENTINEL_REQUIRED contract
# (E92-S2) asserts the existence of $CHECKPOINT_PATH/triage-findings.json
# with mtime OLDER than the Val sidecar write. Setup never created the
# sentinel, so the gate was fail-closed-unusable: any invocation with the
# sentinel-required flag set halted at finalize with "Val sidecar write
# missing".
#
# This block writes the sentinel at run-start so finalize can assert
# correctly: setup creates the .json marker NOW; finalize asserts that
# any subsequent sidecar write has mtime > sentinel mtime. The sentinel
# itself is a minimal JSON payload identifying the run.
SENTINEL_DIR=""
if [ -n "${CHECKPOINT_PATH:-}" ]; then
  SENTINEL_DIR="$CHECKPOINT_PATH"
elif [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT/.gaia/memory/checkpoints" ]; then
  SENTINEL_DIR="$PROJECT_ROOT/.gaia/memory/checkpoints"
elif [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT/_memory/checkpoints" ]; then
  SENTINEL_DIR="$PROJECT_ROOT/_memory/checkpoints"
elif [ -d ".gaia/memory/checkpoints" ]; then
  SENTINEL_DIR=".gaia/memory/checkpoints"
fi

if [ -n "$SENTINEL_DIR" ]; then
  mkdir -p "$SENTINEL_DIR" 2>/dev/null || true
  SENTINEL_PATH="$SENTINEL_DIR/triage-findings.json"
  # Write minimal run-start payload via atomic tempfile + mv
  tmp_sentinel="$(mktemp "${SENTINEL_PATH}.XXXXXX" 2>/dev/null || mktemp)"
  cat > "$tmp_sentinel" <<EOF
{"workflow":"$WORKFLOW_NAME","run_started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","source":"gaia-triage-findings/setup.sh","af":"AF-2026-05-24-12"}
EOF
  if mv "$tmp_sentinel" "$SENTINEL_PATH" 2>/dev/null; then
    log "wrote run-start sentinel: $SENTINEL_PATH"
  else
    rm -f "$tmp_sentinel" 2>/dev/null
    log "WARNING: could not write run-start sentinel at $SENTINEL_PATH — finalize fail-closed gate may halt (F-21)"
  fi
else
  log "WARNING: no checkpoint dir resolved — F-21 run-start sentinel skipped"
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
