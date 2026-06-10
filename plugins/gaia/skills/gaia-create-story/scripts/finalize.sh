#!/usr/bin/env bash
# finalize.sh — gaia-create-story skill finalize
#
# Mechanical copy of the gaia-brainstorm/scripts/finalize.sh reference
# implementation. Only WORKFLOW_NAME and SCRIPT_NAME differ — the body is
# byte-identical to the reference.
#
# Responsibilities:
#   1. Write a checkpoint via the shared checkpoint.sh foundation script
#   2. Emit a lifecycle event via lifecycle-event.sh for the tailing sync agent
#   3. Run an advisory epic/story-key registry integrity audit
#      (validate-epic-registry.sh) and surface any collisions/orphans to stderr
#
# Exit codes:
#   0 — finalize succeeded
#   1 — checkpoint write or lifecycle event emission failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-create-story/finalize.sh"
WORKFLOW_NAME="create-story"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 2. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

# ---------- 3. Advisory: epic/story-key registry integrity audit ----------
# Read-only scan that surfaces silent corruption introduced when the cascade
# materializes a story whose key collides with an existing one, or whose epic:
# frontmatter references an unregistered epic. Runs in `--severity warn` mode
# so a pre-existing collision in a legacy project does not block create-story
# from finishing; the operator sees the advisory on stderr and decides whether
# to act. Failure of the audit itself (missing inputs, IO error) is non-fatal.
REGISTRY_AUDIT="$PLUGIN_SCRIPTS_DIR/validate-epic-registry.sh"
if [ -x "$REGISTRY_AUDIT" ]; then
  audit_out="$("$REGISTRY_AUDIT" --severity warn --format text 2>&1 || true)"
  case "$audit_out" in
    *'OK (0 collisions, 0 orphans)'*)
      : ;;  # silent on the happy path
    *'issue(s) found'*)
      log "ADVISORY — epic/story-key registry has integrity issues:"
      printf '%s\n' "$audit_out" >&2
      log "run 'validate-epic-registry.sh --severity halt' for an exit-coded check" ;;
    *)
      : ;;  # script unreachable input — stay quiet
  esac
fi

log "finalize complete for $WORKFLOW_NAME"
exit 0
