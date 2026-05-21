#!/usr/bin/env bash
# auto-save-memory.sh — Auto-save session summary at finalize (E45-S3 / ADR-061)
#
# Story: E45-S3 (Auto-save session memory at finalize for 24 Phase 1-3 skills)
# ADRs:  ADR-061 (scope-bounded auto-save), ADR-057 (Phase 4 stays interactive),
#        ADR-046 (hybrid memory write-path counterpart), ADR-016 (decision-log fmt)
# Architecture: §10.31.5 (Auto-Save Session Memory at Finalize)
#
# Purpose
# -------
# Compose a session summary for a Phase 1-3 skill and append it atomically
# to the agent's memory sidecar. Auto-save fires unconditionally for the
# 24 Phase 1-3 skills enumerated in `phase-classification.sh`; for Phase 4
# skills the function returns early so the existing interactive prompt
# (FR-YOLO-2(f)) is preserved.
#
# Public entry point:
#   _auto_save_memory <skill-name> [artifact-path...]
#
# Behaviour matrix:
#   - Phase 1-3 skill → resolve agent → compose summary → redact secrets →
#                       atomic append to {sidecar}/decision-log.md
#   - Phase 4 skill   → return 0 immediately (no-op; defer to skill logic)
#   - Unknown skill   → log "auto-save aborted: cannot resolve agent sidecar
#                       for skill {name}" → return 64 (post_complete failure)
#   - Save > 3s       → background async writer, status line emitted, parent
#                       returns within 3s
#   - Sidecar dir absent → mkdir -p, seed canonical decision-log.md header
#   - Write failure   → warning logged, return 0 (non-blocking, AC-EC4)
#
# All paths use `LC_ALL=C` and POSIX-portable shell. macOS BSD-coreutils +
# Linux GNU-coreutils both supported.

# Resolve helper script paths relative to this file's location.
# This block must run when sourced — BASH_SOURCE[0] is the path to *this*
# file even when sourced.
_AUTOSAVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_AUTOSAVE_PHASE_LIB="${_AUTOSAVE_LIB_DIR}/phase-classification.sh"
_AUTOSAVE_PLUGIN_SCRIPTS_DIR="$(cd "${_AUTOSAVE_LIB_DIR}/.." && pwd)"
_AUTOSAVE_MEMORY_WRITER="${_AUTOSAVE_PLUGIN_SCRIPTS_DIR}/memory-writer.sh"

# Source the phase-classification library so callers get _is_phase_1_3 and
# _skill_agent_for as a side effect of sourcing this file.
# shellcheck disable=SC1090
[ -f "$_AUTOSAVE_PHASE_LIB" ] && . "$_AUTOSAVE_PHASE_LIB"

# Public latency threshold (seconds). Crossing this triggers async fallback.
# Override via AUTO_SAVE_LATENCY_THRESHOLD for testing.
: "${AUTO_SAVE_LATENCY_THRESHOLD:=3}"

# --- Logging helpers -------------------------------------------------------
_autosave_log() {
    printf 'auto-save: %s\n' "$*" >&2
}

# --- Secret redaction (AC-EC8) ---------------------------------------------
#
# Conservative allow-list. We log only the redaction count, never the
# matched content. Patterns are anchored loosely so we catch common API
# key, bearer-token, and shell-style env-var assignments.
_autosave_redact_secrets() {
    local input="$1"
    local count=0
    local redacted="$input"

    # OpenAI-style sk-* keys.
    if printf '%s' "$redacted" | grep -Eq 'sk-[a-zA-Z0-9]{20,}'; then
        local before
        before="$(printf '%s' "$redacted" | grep -oE 'sk-[a-zA-Z0-9]{20,}' | wc -l | tr -d ' ')"
        count=$(( count + before ))
        redacted="$(printf '%s' "$redacted" | sed -E 's/sk-[a-zA-Z0-9]{20,}/[REDACTED]/g')"
    fi

    # AWS access-key id.
    if printf '%s' "$redacted" | grep -Eq 'AKIA[0-9A-Z]{16}'; then
        local before
        before="$(printf '%s' "$redacted" | grep -oE 'AKIA[0-9A-Z]{16}' | wc -l | tr -d ' ')"
        count=$(( count + before ))
        redacted="$(printf '%s' "$redacted" | sed -E 's/AKIA[0-9A-Z]{16}/[REDACTED]/g')"
    fi

    # GitHub personal-access tokens (ghp_).
    if printf '%s' "$redacted" | grep -Eq 'ghp_[A-Za-z0-9]{36}'; then
        local before
        before="$(printf '%s' "$redacted" | grep -oE 'ghp_[A-Za-z0-9]{36}' | wc -l | tr -d ' ')"
        count=$(( count + before ))
        redacted="$(printf '%s' "$redacted" | sed -E 's/ghp_[A-Za-z0-9]{36}/[REDACTED]/g')"
    fi

    # Bearer tokens (Authorization headers, etc.).
    if printf '%s' "$redacted" | grep -Eq 'Bearer[[:space:]]+[A-Za-z0-9._-]{16,}'; then
        local before
        before="$(printf '%s' "$redacted" | grep -oE 'Bearer[[:space:]]+[A-Za-z0-9._-]{16,}' | wc -l | tr -d ' ')"
        count=$(( count + before ))
        redacted="$(printf '%s' "$redacted" | sed -E 's/Bearer[[:space:]]+[A-Za-z0-9._-]{16,}/Bearer [REDACTED]/g')"
    fi

    # Export the redaction count via a shared global; callers may log it.
    AUTO_SAVE_REDACTION_COUNT="$count"
    printf '%s' "$redacted"
}

# --- Session summary composition -------------------------------------------
#
# Body shape (architecture §10.31.5, ADR-016 decision-log format):
#
#   ### [YYYY-MM-DD] {skill-name} Session Summary
#
#   **Inputs:** [list of consumed artifacts]
#   **Outputs:** [list of produced/modified artifacts]
#   **Key decisions:** [extracted from session context]
#   **Open questions:** [TBD/TODO items detected in outputs]
#
# memory-writer.sh wraps this body with its own decision-log envelope
# (timestamped header, agent / workflow / status lines), so the summary we
# build here is the inner content only.
_autosave_compose_summary() {
    local skill="$1"
    shift
    local artifacts=("$@")

    local date_iso
    date_iso="$(date -u +%Y-%m-%d 2>/dev/null || echo '')"

    # Outputs section — list each artifact (only those that exist on disk).
    local outputs=""
    if [ "${#artifacts[@]}" -gt 0 ]; then
        local a
        for a in "${artifacts[@]}"; do
            [ -n "$a" ] || continue
            if [ -f "$a" ]; then
                outputs="${outputs}- ${a}"$'\n'
            fi
        done
    fi
    [ -n "$outputs" ] || outputs="- (no artifacts produced this session)"$'\n'

    # Open-questions detection — scan the artifacts for unchecked checkboxes
    # and TBD/TODO markers. Bounded scan to avoid pathological costs.
    local oq=""
    if [ "${#artifacts[@]}" -gt 0 ]; then
        local a
        for a in "${artifacts[@]}"; do
            [ -f "$a" ] || continue
            # Count unchecked checkboxes and TBD/TODO occurrences (case-insensitive).
            local n_check n_tbd
            n_check="$(grep -cE '^- \[ \]' "$a" 2>/dev/null || echo 0)"
            n_tbd="$(grep -ciE '\b(TBD|TODO)\b' "$a" 2>/dev/null || echo 0)"
            if [ "${n_check:-0}" -gt 0 ] 2>/dev/null || [ "${n_tbd:-0}" -gt 0 ] 2>/dev/null; then
                oq="${oq}- ${a}: ${n_check} unchecked, ${n_tbd} TBD/TODO"$'\n'
            fi
        done
    fi
    [ -n "$oq" ] || oq="- (none detected)"$'\n'

    # Compose the summary body.
    local body
    body="### [${date_iso}] ${skill} Session Summary"$'\n\n'"**Inputs:** (skill-driven; see workflow checkpoints)"$'\n\n'"**Outputs:**"$'\n'"${outputs}"$'\n'"**Key decisions:** (auto-saved at finalize; user may amend via /gaia-memory-hygiene)"$'\n\n'"**Open questions:**"$'\n'"${oq}"

    # Empty-session sentinel (AC-EC5): if there were no artifacts AND no
    # open questions detected, mark as "no persistable decisions" so the
    # entry still records the invocation date — never a silent skip.
    if [ "${#artifacts[@]}" -eq 0 ]; then
        body="### [${date_iso}] ${skill} Session Summary"$'\n\n'"No persistable decisions this session. (auto-save record only)"$'\n'
    fi

    printf '%s' "$body"
}

# --- Atomic append via memory-writer.sh ------------------------------------
#
# memory-writer.sh handles flock + atomic rename + canonical header seeding,
# so we delegate to it. We supply --type decision so a new timestamped
# entry is appended to {sidecar}/decision-log.md.
_autosave_append() {
    local agent="$1"
    local skill="$2"
    local content="$3"

    if [ ! -x "$_AUTOSAVE_MEMORY_WRITER" ]; then
        _autosave_log "memory-writer.sh not executable at $_AUTOSAVE_MEMORY_WRITER — auto-save skipped (non-fatal)"
        return 0
    fi

    # Workflow source name mirrors the skill name minus the gaia- prefix.
    local source_workflow="${skill#gaia-}"

    if "$_AUTOSAVE_MEMORY_WRITER" \
        --agent "$agent" \
        --type decision \
        --content "$content" \
        --source "$source_workflow" \
        --lock-timeout 5 >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# --- Async writer fallback (AC-EC2) ----------------------------------------
#
# Spawn the append in a backgrounded subshell. The parent returns within
# the latency budget and emits a status line. The subshell handles its own
# errors and never affects the parent's exit code.
_autosave_append_async() {
    local agent="$1" skill="$2" content="$3"
    (
        _autosave_append "$agent" "$skill" "$content" >/dev/null 2>&1 || true
    ) &
    # Detach from the controlling shell.
    disown 2>/dev/null || true
}

# --- Public entry point ----------------------------------------------------
#
# _auto_save_memory <skill-name> [artifact-path...]
#
# Returns:
#   0   auto-save succeeded, was deferred (Phase 4), or failed non-blockingly
#   64  agent mapping unresolvable (AC-EC7) — caller should fail post_complete
_auto_save_memory() {
    local skill="${1:-}"
    if [ -z "$skill" ]; then
        _autosave_log "auto-save aborted: skill name not supplied"
        return 64
    fi
    shift

    # Phase 4 short-circuit (ADR-057 boundary). Defer to interactive logic.
    if ! _is_phase_1_3 "$skill"; then
        # Distinguish Phase 4 (known but excluded) from unknown.
        local s found_p4=0
        for s in $_PHASE_4_SKILLS; do
            if [ "$s" = "$skill" ]; then
                found_p4=1
                break
            fi
        done
        if [ "$found_p4" -eq 1 ]; then
            # Phase 4 — interactive path owns memory-save. No-op here.
            return 0
        fi

        # Skill is unknown to the classifier. Fail closed (AC-EC7).
        _autosave_log "auto-save aborted: cannot resolve agent sidecar for skill ${skill}"
        return 64
    fi

    # Resolve agent sidecar from skill mapping.
    local agent
    agent="$(_skill_agent_for "$skill" 2>/dev/null || true)"
    if [ -z "$agent" ]; then
        _autosave_log "auto-save aborted: cannot resolve agent sidecar for skill ${skill}"
        return 64
    fi

    # Fast-path no-op: if the memory infrastructure is not available
    # (no MEMORY_PATH/config.yaml on disk and no fallback to the cwd's
    # _memory tree, or memory-writer.sh missing), skip silently. This
    # keeps test harnesses that exercise finalize.sh in isolation
    # cheap — they pay no fork/exec/sleep cost. The fast path runs
    # BEFORE we spawn the background writer.
    # AF-2026-05-21-7: canonical-first lookup with legacy fallback only on
    # positive pre-ADR-111 evidence. Read-only path — no mkdir, so the bug
    # was lower-priority, but pattern-aligned with the rest of the sweep.
    local memdir
    if [ -n "${MEMORY_PATH:-}" ]; then
        memdir="$MEMORY_PATH"
    elif [ -d "_memory" ] && [ ! -d ".gaia/memory" ]; then
        memdir="_memory"
    else
        memdir=".gaia/memory"
    fi
    if [ ! -f "${memdir}/config.yaml" ] || [ ! -x "$_AUTOSAVE_MEMORY_WRITER" ]; then
        return 0
    fi

    # Compose summary body.
    local body
    body="$(_autosave_compose_summary "$skill" "$@")"

    # Redact secrets (AC-EC8).
    AUTO_SAVE_REDACTION_COUNT=0
    body="$(_autosave_redact_secrets "$body")"
    if [ "${AUTO_SAVE_REDACTION_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        _autosave_log "redacted ${AUTO_SAVE_REDACTION_COUNT} secret pattern match(es) before write"
    fi

    # Latency-budgeted write (AC-EC2). We spawn the append in the background
    # and wait up to AUTO_SAVE_LATENCY_THRESHOLD seconds for it to complete.
    # If it does not finish in time, we leave it running and emit the async
    # status line — the parent shell returns immediately.
    (
        _autosave_append "$agent" "$skill" "$body" >/dev/null 2>&1 || true
        # Touch a sentinel inside the sidecar dir to confirm completion.
    ) &
    local writer_pid=$!

    # Poll every 100ms (10× per second) so a fast write returns quickly.
    # AUTO_SAVE_LATENCY_THRESHOLD is the wall-clock budget in seconds, so we
    # multiply by 10 to derive the iteration count.
    local threshold="${AUTO_SAVE_LATENCY_THRESHOLD:-3}"
    local max_iters=$(( threshold * 10 ))
    local i=0
    while [ "$i" -lt "$max_iters" ]; do
        if ! kill -0 "$writer_pid" 2>/dev/null; then
            wait "$writer_pid" 2>/dev/null || true
            _autosave_log "session summary saved synchronously to ${agent}-sidecar (skill: ${skill})"
            return 0
        fi
        sleep 0.1
        i=$(( i + 1 ))
    done

    # Threshold exceeded — leave writer running, return control.
    disown "$writer_pid" 2>/dev/null || true
    _autosave_log "saving asynchronously to ${agent}-sidecar (skill: ${skill}; pid ${writer_pid})"
    return 0
}

# --- Direct invocation -----------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
        save)
            shift
            _auto_save_memory "$@"
            exit $?
            ;;
        --help|-h|"")
            cat <<'EOF'
auto-save-memory.sh — Auto-save session summary at finalize (ADR-061)

Usage:
  source auto-save-memory.sh && _auto_save_memory <skill> [artifact...]
  auto-save-memory.sh save <skill> [artifact...]
  auto-save-memory.sh --help

Returns:
  0   saved, deferred (Phase 4), or non-blocking failure
  64  agent mapping unresolvable
EOF
            exit 0
            ;;
        *)
            echo "auto-save-memory.sh: unknown subcommand '$1'. Try '--help'." >&2
            exit 2
            ;;
    esac
fi
