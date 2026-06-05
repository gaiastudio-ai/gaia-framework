#!/usr/bin/env bash
# yolo-mode.sh — YOLO mode detection helper for V2 GAIA skills.
#
# Architecture: .gaia/artifacts/planning-artifacts/architecture.md §10.30.4
#
# Purpose
# -------
# The retired V1 engine expressed YOLO declaratively via per-step branches
# in its workflow definitions; V2 native skills lost that declarative
# contract. This script centralizes YOLO detection so each skill consults
# a single helper instead of re-implementing env parsing. See
# architecture.md §10.30 for the full contract.
#
# Activation signals (architecture §10.30.1):
#   --yolo flag at the command boundary  -> caller exports GAIA_YOLO_FLAG=1
#   GAIA_YOLO_MODE=1 inherited from a YOLO-mode parent process
#   .gaia/state/.yolo-active sentinel file
#
# Precedence order (top wins, architecture §10.30.4):
#   1. GAIA_CONTEXT=memory-save  -> exit 1   (memory-save is always interactive)
#   2. GAIA_YOLO_OVERRIDE=no     -> exit 1   (explicit opt-out, e.g. --no-yolo)
#   3. GAIA_YOLO_FLAG=1          -> exit 0   (direct invocation)
#   4. GAIA_YOLO_MODE=1          -> exit 0   (inheritance)
#   5. .yolo-active sentinel     -> exit 0   (cross-tool-call persistence)
#   6. default                   -> exit 1   (interactive)
#
# Both GAIA_YOLO_FLAG and GAIA_YOLO_MODE accept ONLY the exact string "1".
# Values "0", "false", "no", and the empty string fall through to the
# default exit-1 branch (ECI-500 regression guard).
#
# Sentinel file:
#   Path: $GAIA_STATE_DIR/.yolo-active (defaults to ./.gaia/state/.yolo-active
#   when GAIA_STATE_DIR is unset). The legacy ./_memory/.yolo-active fallback
#   was removed when .gaia/ became canonical. Created by
#   callers via `yolo-mode.sh set` when
#   they detect --yolo in their arguments. Removed via `yolo-mode.sh clear`
#   on session end OR on explicit --no-yolo. Sentinel-file YOLO state
#   SURVIVES across Bash tool calls in environments (Claude Code, CI) that
#   do not preserve env-var exports across invocations.
#
# Usage
# -----
#   # As a sourced library:
#   source plugins/gaia/scripts/yolo-mode.sh
#   if is_yolo; then echo "auto-proceed"; else echo "interactive"; fi
#
#   # As a direct invocation (subcommand form):
#   plugins/gaia/scripts/yolo-mode.sh is_yolo
#   echo "exit: $?"
#
# Shellcheck: clean (no unsupported constructs).

# is_yolo
# -------
# Returns 0 (YOLO active) or 1 (interactive) based on the precedence table
# above. Pure function — reads env, writes nothing, has no side effects.
is_yolo() {
    # Rule 1 — Memory-save context is always interactive. The memory-save
    # prompt MUST remain interactive even when YOLO is active at the session
    # level.
    if [ "${GAIA_CONTEXT:-}" = "memory-save" ]; then
        return 1
    fi

    # Rule 2 — Explicit opt-out wins over both activation signals.
    # Used by --no-yolo flag handlers and by skills that need to break
    # YOLO inheritance for a specific subagent invocation.
    if [ "${GAIA_YOLO_OVERRIDE:-}" = "no" ]; then
        return 1
    fi

    # Rule 3 — Invocation flag (--yolo). Only the exact string "1" activates;
    # any other value (including "0", "true", "false", "") falls through.
    if [ "${GAIA_YOLO_FLAG:-}" = "1" ]; then
        return 0
    fi

    # Rule 4 — Inheritance env. Same exact-"1" semantics as Rule 3.
    if [ "${GAIA_YOLO_MODE:-}" = "1" ]; then
        return 0
    fi

    # Rule 5 — Sentinel file persistence.
    # Env vars don't survive across Bash tool calls in Claude Code; the
    # sentinel file is the cross-call YOLO state contract.
    local sentinel="${GAIA_YOLO_SENTINEL:-}"
    if [ -z "$sentinel" ]; then
        if [ -n "${GAIA_STATE_DIR:-}" ]; then
            sentinel="${GAIA_STATE_DIR}/.yolo-active"
        elif [ -d ".gaia/state" ]; then
            sentinel=".gaia/state/.yolo-active"
        else
            sentinel=".gaia/state/.yolo-active"  # default even if dir absent
        fi
    fi
    if [ -f "$sentinel" ]; then
        return 0
    fi

    # Rule 6 — Default: interactive.
    return 1
}

# yolo_set
# --------
# Create the .yolo-active sentinel file so the YOLO state persists across
# Bash tool calls in environments where env vars do not survive between
# invocations (Claude Code, CI). Idempotent. Returns 0 on write, 1 on error.
yolo_set() {
    local sentinel="${GAIA_YOLO_SENTINEL:-}"
    if [ -z "$sentinel" ]; then
        if [ -n "${GAIA_STATE_DIR:-}" ]; then
            sentinel="${GAIA_STATE_DIR}/.yolo-active"
        elif [ -d ".gaia/state" ] || mkdir -p ".gaia/state" 2>/dev/null; then
            sentinel=".gaia/state/.yolo-active"
        else
            sentinel=".gaia/state/.yolo-active"
        fi
    fi
    local dir
    dir="$(dirname -- "$sentinel")"
    mkdir -p -- "$dir" 2>/dev/null || return 1
    : > "$sentinel" || return 1
    return 0
}

# yolo_clear
# ----------
# Remove the .yolo-active sentinel. Idempotent — absent file is a no-op.
yolo_clear() {
    local sentinel="${GAIA_YOLO_SENTINEL:-}"
    if [ -z "$sentinel" ]; then
        if [ -n "${GAIA_STATE_DIR:-}" ]; then
            sentinel="${GAIA_STATE_DIR}/.yolo-active"
        elif [ -f ".gaia/state/.yolo-active" ]; then
            sentinel=".gaia/state/.yolo-active"
        else
            return 0  # nothing to clear
        fi
    fi
    rm -f -- "$sentinel" 2>/dev/null || true
    return 0
}

# Direct-invocation entry point — only runs when the script is executed
# directly (not sourced). Allows callers to do `yolo-mode.sh is_yolo` and
# read $? without sourcing.
#
# BASH_SOURCE[0] equals $0 only on direct invocation. When sourced, $0 is
# the parent shell's name and BASH_SOURCE[0] is the path to this file.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-is_yolo}" in
        is_yolo)
            is_yolo
            exit $?
            ;;
        set)
            # Create the cross-call sentinel.
            yolo_set
            exit $?
            ;;
        clear)
            # Remove the cross-call sentinel.
            yolo_clear
            exit $?
            ;;
        --help|-h)
            cat <<'EOF'
yolo-mode.sh — YOLO mode detection helper (architecture §10.30.4)

Usage:
  source yolo-mode.sh && is_yolo                 # library form
  yolo-mode.sh is_yolo                           # subcommand form (read state)
  yolo-mode.sh set                               # write sentinel (start YOLO)
  yolo-mode.sh clear                             # remove sentinel (end YOLO)
  yolo-mode.sh --help                            # this message

Environment variables (precedence top-down):
  GAIA_CONTEXT=memory-save     forces exit 1 (always interactive)
  GAIA_YOLO_OVERRIDE=no        explicit opt-out -> exit 1
  GAIA_YOLO_FLAG=1             --yolo flag      -> exit 0
  GAIA_YOLO_MODE=1             inherited YOLO   -> exit 0
  .yolo-active sentinel        cross-call YOLO  -> exit 0
  GAIA_YOLO_SENTINEL=<path>    override sentinel location (tests)
  (none)                       default          -> exit 1
EOF
            exit 0
            ;;
        *)
            echo "yolo-mode.sh: unknown subcommand '$1'. Try '--help'." >&2
            exit 2
            ;;
    esac
fi
