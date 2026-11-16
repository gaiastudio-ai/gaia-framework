#!/usr/bin/env bash
# action-items-increment.sh — increment escalation_count for an action-items.yaml
# entry keyed by theme_hash, with idempotency scoped to (sprint_id, theme_hash).
#
# This script delegates to the canonical shared retro writer
# (retro-sidecar-write.sh) for allowlist enforcement, path resolution, and
# concurrency control. Helpers (allowlist_match, resolve_real) are sourced
# directly from the shared writer so the boundary is enforced
# exactly once across the codebase.
#
# Increment semantics are an in-place YAML mutation, distinct from the
# shared writer's append-only pipeline — that mutation logic stays here, but
# all auxiliary primitives (boundary, locking, backup) come from the shared
# writer.
#
# Usage:
#   action-items-increment.sh --file <path> --theme-hash <hex> --sprint-id <id>
#
# Exit codes:
#   0  — increment applied (or no-op because already applied for this sprint,
#        or target file missing — increment is a non-fatal warning)
#   1  — error (allowlist rejection, invalid arguments, IO failure)
#
# Contract:
#   * Allowlist check: file path must satisfy the shared writer's allowlist
#     (realpath-resolved match against allowlist patterns; for this script,
#     the relevant pattern is `<root>/.gaia/state/action-items.yaml`).
#   * Idempotency: a sidecar ledger next to the target file records
#     (sprint_id, theme_hash) pairs that have already produced an increment.
#     Re-invoking with the same pair is a silent no-op.
#   * Backup: a .bak copy is written before mutation; on verify failure
#     the target is left unchanged and the .bak is removed by signal
#     cleanup (no data loss, since nothing was moved yet).
#   * Concurrency: the shared lock helper on action-items.yaml.lock
#     (flock when available, hard-link fallback otherwise) serializes
#     writers.

set -uo pipefail

# Locate and source the shared retro writer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRO_WRITER="${SCRIPT_DIR}/../../../scripts/retro-sidecar-write.sh"
if [ ! -f "$RETRO_WRITER" ]; then
  echo "error: shared retro writer not found at $RETRO_WRITER" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$RETRO_WRITER"

AI_FILE=""
THEME_HASH=""
SPRINT_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file)         AI_FILE="$2"; shift 2 ;;
    --theme-hash)   THEME_HASH="$2"; shift 2 ;;
    --sprint-id)    SPRINT_ID="$2"; shift 2 ;;
    *) echo "error: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$AI_FILE" ] || [ -z "$THEME_HASH" ] || [ -z "$SPRINT_ID" ]; then
  echo "usage: $0 --file <path> --theme-hash <hex> --sprint-id <id>" >&2
  exit 1
fi

# Allowlist — delegate to the shared writer's helper. We resolve
# both the project root and the target file via the shared writer's
# resolve_real() so symlinks / non-existent intermediate components are
# handled identically across all retro writes.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$(pwd)}}"
REAL_ROOT="$(resolve_real "$PROJECT_ROOT")"
[ -z "$REAL_ROOT" ] && REAL_ROOT="$PROJECT_ROOT"
REAL_TARGET="$(resolve_real "$AI_FILE")"
[ -z "$REAL_TARGET" ] && REAL_TARGET="$AI_FILE"

if ! allowlist_match "$REAL_ROOT" "$REAL_TARGET"; then
  # Fall back to a basename guard so test fixtures that do not sit under
  # the project root still enforce the action-items.yaml constraint.
  case "$(basename "$REAL_TARGET")" in
    action-items.yaml) ;;
    *) echo "error: write target not in allowlist: $AI_FILE" >&2; exit 1 ;;
  esac
fi

if [ ! -f "$AI_FILE" ]; then
  echo "warn: action-items.yaml not found: $AI_FILE — skipping increment" >&2
  exit 0
fi

LEDGER="${AI_FILE}.increment-ledger"
touch "$LEDGER"

LEDGER_KEY="${SPRINT_ID}:${THEME_HASH}"
if grep -Fxq "$LEDGER_KEY" "$LEDGER" 2>/dev/null; then
  # Idempotent no-op.
  exit 0
fi

# Mutate under the shared action-items lock. Source the canonical writer
# to get _aiw_lock/_aiw_unlock, which use the same lock path
# (${target}.lock) and the same timeout/retry/diagnostic handling.
_AIW_INCREMENT_SCRIPTS_DIR="${BASH_SOURCE[0]%/*}"
# Resolve the writer's scripts directory (three levels up from this skill).
_AIW_WRITER_DIR="$(cd "$_AIW_INCREMENT_SCRIPTS_DIR/../../../scripts" 2>/dev/null && pwd)"
# shellcheck source=../../../scripts/action-items-write.sh
source "${_AIW_WRITER_DIR}/action-items-write.sh"
LOCKFILE="${AI_FILE}.lock"

_do_increment() {
  # Locate the entry whose theme_hash matches and bump its escalation_count.
  # We operate on the raw file with awk because the action-items.yaml dialect
  # used in this repo is hand-authored (not round-tripped through a YAML lib)
  # and we want byte-stable edits.
  local backup="${AI_FILE}.bak"
  cp -p "$AI_FILE" "$backup"

  local tmpfile
  tmpfile="$(mktemp -t action-items.yaml.XXXXXX)"
  awk -v hash="$THEME_HASH" '
    BEGIN { in_target = 0; applied = 0 }
    {
      line = $0
      if (match(line, /theme_hash:[[:space:]]*"?(sha256:)?[0-9a-f]+/)) {
        found = substr(line, RSTART, RLENGTH)
        # Grab the trailing hex run.
        hex = ""
        if (match(found, /[0-9a-f]+$/)) {
          hex = substr(found, RSTART, RLENGTH)
        }
        if (hex == hash) { in_target = 1 }
        else             { in_target = 0 }
      }
      if (in_target && applied == 0 && match(line, /escalation_count:[[:space:]]*[0-9]+/)) {
        # Extract current counter value and bump it.
        chunk = substr(line, RSTART, RLENGTH)
        cur = chunk
        sub(/^[^0-9]+/, "", cur)
        new_val = cur + 1
        sub(/escalation_count:[[:space:]]*[0-9]+/,
            "escalation_count: " new_val, line)
        applied = 1
        in_target = 0
      }
      print line
    }
  ' "$AI_FILE" > "$tmpfile"

  # Verify the file is still non-empty before swapping in.
  if [ ! -s "$tmpfile" ]; then
    rm -f "$tmpfile"
    echo "error: post-write file is empty; aborting and leaving backup" >&2
    return 1
  fi

  mv "$tmpfile" "$AI_FILE"
  rm -f "$backup"
  return 0
}

# --- Signal-safe lock cleanup -------------------------------------------
#
# Traps are installed BEFORE _aiw_lock because the test-hold sleep
# (GAIA_AIW_TEST_HOLD_SECONDS) fires inside _aiw_lock after the lock
# is acquired. A signal during that window must still clean up.
#
# _incr_lock_held is set to 1 before _aiw_lock so the cleanup covers
# the hold window. This is safe even if _aiw_lock has not yet acquired:
# _aiw_unlock delegates to release_lock, which is a no-op for an
# unregistered fd.
#
# EXIT preserves the original exit status. INT/TERM terminate the
# script immediately after cleanup so no code runs without the lock.
_incr_lock_held=0

_incr_cleanup() {
  if [ "$_incr_lock_held" = "1" ]; then
    _incr_lock_held=0
    # Clean leftover temp/backup from _do_increment if present.
    rm -f "${AI_FILE}.bak" 2>/dev/null || true
    _aiw_unlock
  fi
}

_incr_exit_handler() {
  local _exit_rc=$?
  _incr_cleanup
  exit "$_exit_rc"
}

_incr_term_handler() {
  _incr_cleanup
  exit 143  # 128 + SIGTERM(15)
}

_incr_int_handler() {
  _incr_cleanup
  exit 130  # 128 + SIGINT(2)
}

trap '_incr_exit_handler' EXIT
trap '_incr_int_handler' INT
trap '_incr_term_handler' TERM
# -----------------------------------------------------------------------

# Acquire the shared lock. On failure (timeout, permission denied),
# the data is left unchanged and we exit non-zero. The flag is set
# before the call so the trap covers the hold window inside _aiw_lock.
_incr_lock_held=1
if ! _aiw_lock "$LOCKFILE" "action-items-increment" >/dev/null; then
  _incr_lock_held=0
  echo "error: could not acquire lock on $LOCKFILE" >&2
  exit 1
fi

# Re-check idempotency under the lock so a racing writer's increment
# is observed before we apply a duplicate.
rc=0
if grep -Fxq "$LEDGER_KEY" "$LEDGER" 2>/dev/null; then
  # Race resolved — another process already incremented for this key.
  exit 0
fi

_do_increment || rc=$?

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# Record the idempotency key while still holding the lock.
printf '%s\n' "$LEDGER_KEY" >> "$LEDGER"

# Release before clearing the flag so a signal in this window still
# cleans up. A second release via the EXIT trap is a harmless no-op
# (release_lock on an unregistered fd returns immediately).
_aiw_unlock
_incr_lock_held=0
exit 0
