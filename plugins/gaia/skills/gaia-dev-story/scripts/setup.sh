#!/usr/bin/env bash
# setup.sh — gaia-dev-story skill setup
#
# Mechanical extension of the reference implementation.
# Adds dev-story-specific prereq gates:
#   - Story file must exist for the given story_key
#   - Story status must be ready-for-dev or in-progress
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (story file exists)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/setup.sh"
WORKFLOW_NAME="gaia-dev-story"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. YOLO activation ----------
# Scan positional args ($1, $2) and the $ARGUMENTS env var for the literal
# `yolo` keyword or `--yolo` flag. SKILL.md documents "Pass `yolo` as the second
# argument" to auto-advance past confirmation gates, but the `!`-Setup directive
# does not forward the skill's positional args — so $ARGUMENTS (populated by the
# substrate with the full invocation argument string) is the reliable source.
# When YOLO is requested, create the .yolo-active sentinel via `yolo-mode.sh set`
# (NOT a bare env export): env-var exports do not survive across Bash tool-call
# boundaries under Claude Code, whereas the sentinel persists, so the downstream
# `yolo-mode.sh is_yolo` gate at the Step 4 planning gate (and Steps 5/6/7/15)
# reads the requested state. Activation only suppresses interactive prompts; it
# MUST NOT bypass the review-gate, dependency, or transition contracts.
__arg1="${1:-}"
__arg2="${2:-}"
__args_blob=" ${__arg1} ${__arg2} ${ARGUMENTS:-} "
YOLO_MODE_SCRIPT="$PLUGIN_SCRIPTS_DIR/yolo-mode.sh"
if [[ "$__args_blob" == *" yolo "* ]] || [[ "$__args_blob" == *" --yolo "* ]]; then
  if [ -x "$YOLO_MODE_SCRIPT" ] && "$YOLO_MODE_SCRIPT" set 2>/dev/null; then
    log "yolo_mode=true — .yolo-active sentinel set"
  else
    # Fall back to a session export so a single-shell run still honours YOLO.
    export GAIA_YOLO_FLAG=1
    log "yolo_mode=true — GAIA_YOLO_FLAG exported (sentinel write unavailable)"
  fi
else
  log "yolo_mode=false"
fi

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

# ---------- 2. Validate gate (story file required) ----------
if [ -x "$VALIDATE_GATE" ]; then
  if ! "$VALIDATE_GATE" file_exists 2>&1; then
    die "HALT: Story file not found — run /gaia-create-story first"
  fi
else
  log "validate-gate.sh not found at $VALIDATE_GATE — skipping gate validation (non-fatal)"
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

# ---------- 4. Distributed traceability gate ----------
# The framework's mandatory quality gates can collapse silently when
# /gaia-sprint-plan is sidestepped — because /gaia-sprint-plan was the ONLY
# skill enforcing the traceability-matrix gate. /gaia-dev-story now enforces
# the same gate so a story driven straight from backlog to in-progress without
# going through /gaia-sprint-plan still respects the contract. When strict
# mode is OFF, this is an advisory warning. When strict mode is ON (recommended
# default), it's a hard halt with the canonical `--bypass gaia-trace
# --reason "<text>"` escape hatch.
#
# Gate scope: only fires in a real sprint context (SPRINT_ID resolves to
# a non-empty value, either from env or .gaia/state/sprint-status.yaml).
# Fixture invocations and one-off smoke tests skip the gate so existing
# e2e/unit fixtures keep passing without modification — this gate is about
# preventing silent gate collapse DURING SPRINT WORK, not blocking
# isolated setup-smoke calls.
SCRIPT_DIR_F33="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_LIB_F33="$(cd "$SCRIPT_DIR_F33/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
STRICT_HELPER_F33="$(cd "$SCRIPT_DIR_F33/../../.." && pwd)/scripts/lib/lifecycle-strict-mode.sh"

# Resolve SPRINT_ID (env or sprint-status.yaml) — gate only fires when set.
F33_SPRINT_ID="${SPRINT_ID:-}"
if [ -z "$F33_SPRINT_ID" ] && [ -f ".gaia/state/sprint-status.yaml" ] && command -v yq >/dev/null 2>&1; then
  F33_SPRINT_ID="$(yq eval '.sprint_id // ""' .gaia/state/sprint-status.yaml 2>/dev/null || echo "")"
fi

if [ -z "$F33_SPRINT_ID" ]; then
  log "traceability gate skipped (no SPRINT_ID resolved — fixture/setup-smoke context)"
else
  # Route the traceability-matrix lookup through the shared resolver so the
  # canonical .gaia/artifacts/planning-artifacts/ home is rung 1 (where
  # /gaia-trace now writes), with the legacy
  # .gaia/artifacts/test-artifacts/{,strategy/,sharded} placements as
  # read-compat fallbacks. Previously this block initialized TM_ART to the
  # legacy strategy/ path and never looked at planning-artifacts/ — so
  # dev-story HALTed with "traceability-matrix.md not found" on every
  # greenfield project using the newer layout, requiring a manual copy to the
  # legacy path.
  # The legacy probe also covers the flat, strategy/, and sharded index.md placements.
  _ta="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts"
  _resolver_h3="$PLUGIN_SCRIPTS_DIR/lib/resolve-artifact-path.sh"
  TM_ART=""
  if [ -x "$_resolver_h3" ]; then
    TM_ART="$("$_resolver_h3" traceability --project-root "${PROJECT_PATH:-.}" --existing-only 2>/dev/null || true)"
  fi
  if [ -z "$TM_ART" ]; then
    # Resolver returned nothing — fall back to the legacy local probe so the
    # downstream "gate failed" error names the legacy paths it expected.
    TM_ART="$_ta/strategy/traceability-matrix.md"
    if [ ! -f "$TM_ART" ]; then
      if [ -f "$_ta/traceability-matrix.md" ]; then
        TM_ART="$_ta/traceability-matrix.md"
      elif [ -f "$_ta/traceability-matrix/index.md" ]; then
        TM_ART="$_ta/traceability-matrix/index.md"
      fi
    fi
  fi

  if [ -f "$TM_ART" ] && [ -s "$TM_ART" ]; then
    log "traceability-matrix gate satisfied: $TM_ART"
  else
    # Strict-mode resolution
    strict_on_f33=1
    if [ -x "$STRICT_HELPER_F33" ]; then
      if "$STRICT_HELPER_F33" lifecycle_strict_mode_enabled >/dev/null 2>&1; then
        strict_on_f33=1
      else
        strict_on_f33=0
      fi
    fi

    # Check for recorded bypass on the active sprint
    has_trace_bypass=0
    bp_reason_f33=""
    if [ -f "$LIFECYCLE_LIB_F33" ]; then
      bp_json_f33="$(bash "$LIFECYCLE_LIB_F33" read --sprint-id "$F33_SPRINT_ID" 2>/dev/null || echo '{"bypasses":[]}')"
      if printf '%s' "$bp_json_f33" | jq -e '.bypasses | any(.skill == "gaia-trace" or .skill == "/gaia-trace")' >/dev/null 2>&1; then
        has_trace_bypass=1
        bp_reason_f33="$(printf '%s' "$bp_json_f33" | jq -r '[.bypasses[] | select(.skill == "gaia-trace" or .skill == "/gaia-trace")][0].reason')"
      fi
    fi

    if [ "$has_trace_bypass" -eq 1 ]; then
      log "traceability-matrix gate bypassed for sprint ${F33_SPRINT_ID}: ${bp_reason_f33}"
    elif [ "$strict_on_f33" -eq 0 ]; then
      log "WARNING: traceability-matrix.md not found at $TM_ART — would block in strict mode; consider running /gaia-trace OR --bypass gaia-trace --reason \"<text>\""
    else
      die "traceability-matrix.md not found at $TM_ART — run /gaia-trace OR add --bypass gaia-trace --reason \"<text>\""
    fi
  fi
fi

log "setup complete for $WORKFLOW_NAME"
exit 0
