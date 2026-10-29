#!/usr/bin/env bash
# bypass-variable-guard.sh — skill-scoped PreToolUse guard for merge-capable
# skills (dev-story, run-sprint, review-all).
#
# Blocks model Bash calls that set the bypass variable or the tty override,
# and Write/Edit calls whose content carries either. Writes a
# bypass_attempt_blocked record to the sprint audit on each block.
#
# Hook contract:
#   stdin  — tool input (JSON or raw text, depending on harness)
#   env    — CLAUDE_PROJECT_ROOT, PROJECT_ROOT (for audit path)
#   exit 0 — allow the tool call
#   exit 2 — block the tool call (stderr = reason shown to the model)
#
# Guarded variables:
#   GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE  — the bypass token
#   _MERGE_TTY_OVERRIDE                     — tty test seam

set -euo pipefail
LC_ALL=C
export LC_ALL

# Read the full tool input from stdin into a variable.
_bvg_input="$(cat)" || _bvg_input=""

# Fast path: if neither guarded variable appears anywhere in the input,
# the call is safe. This keeps the hot path to a single grep.
if ! printf '%s' "$_bvg_input" \
     | /usr/bin/grep -qE 'GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE|_MERGE_TTY_OVERRIDE'; then
  exit 0
fi

# Detect which variable is present.
_bvg_var=""
for _bvg_candidate in GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE _MERGE_TTY_OVERRIDE; do
  if printf '%s' "$_bvg_input" | /usr/bin/grep -qF "$_bvg_candidate"; then
    _bvg_var="$_bvg_candidate"
    break
  fi
done
[ -n "$_bvg_var" ] || exit 0

# --- Bash call: check for variable-setting patterns -----------------------
# Setting shapes: inline prefix (VAR=val cmd), export, env, declare,
# typeset, set -a with sourced assignment, eval.
# The input is the raw JSON from the harness; patterns must account for
# the command being wrapped in a JSON string (preceded by a `"`).
_bvg_bash_sets_var() {
  local input="$1" var="$2"
  # Pattern 1: VAR= (inline prefix, standalone, or JSON-wrapped)
  printf '%s' "$input" | /usr/bin/grep -qF "${var}=" && return 0
  # Pattern 2: export VAR (without =, pre-export for later assignment)
  printf '%s' "$input" | /usr/bin/grep -qE "export[[:space:]]+.*${var}" && return 0
  # Pattern 3: declare/typeset VAR
  printf '%s' "$input" | /usr/bin/grep -qE "(declare|typeset)[[:space:]]+.*${var}" && return 0
  # Pattern 4: set -a (enables auto-export, any following assignment leaks)
  printf '%s' "$input" | /usr/bin/grep -qE 'set[[:space:]]+-a' && \
    printf '%s' "$input" | /usr/bin/grep -qF "$var" && return 0
  # Pattern 5: eval with the variable name
  printf '%s' "$input" | /usr/bin/grep -qE 'eval ' && \
    printf '%s' "$input" | /usr/bin/grep -qF "$var" && return 0
  return 1
}

# --- Write/Edit call: any mention in content is blocked --------------------
_bvg_content_carries_var() {
  local input="$1" var="$2"
  printf '%s' "$input" | /usr/bin/grep -qF "$var"
}

# Determine the call type. The input may contain a "command" key (Bash),
# "content" key (Write), or "new_string" key (Edit). When the tool name
# is available via environment, use it; otherwise infer from keys.
_bvg_blocked=0
_bvg_tool="${TOOL_USE_NAME:-}"

# Infer tool type from input keys when TOOL_USE_NAME is not set.
if [ -z "$_bvg_tool" ]; then
  if printf '%s' "$_bvg_input" | /usr/bin/grep -qF '"command"'; then
    _bvg_tool="Bash"
  elif printf '%s' "$_bvg_input" | /usr/bin/grep -qF '"new_string"'; then
    _bvg_tool="Edit"
  elif printf '%s' "$_bvg_input" | /usr/bin/grep -qF '"content"'; then
    _bvg_tool="Write"
  fi
fi

case "$_bvg_tool" in
  Bash)
    if _bvg_bash_sets_var "$_bvg_input" "$_bvg_var"; then
      _bvg_blocked=1
    fi
    ;;
  Edit|Write)
    if _bvg_content_carries_var "$_bvg_input" "$_bvg_var"; then
      _bvg_blocked=1
    fi
    ;;
  *)
    # Unknown tool type with a guarded variable — allow (fail open for
    # non-targeted tools, e.g. Read, Grep). The guard is scoped to
    # Bash/Edit/Write by the hook matcher.
    exit 0
    ;;
esac

if [ "$_bvg_blocked" -eq 0 ]; then
  exit 0
fi

# --- Write audit record ---------------------------------------------------
_bvg_audit_dir=""
for _bvg_root in "${CLAUDE_PROJECT_ROOT:-}" "${PROJECT_ROOT:-}"; do
  if [ -n "$_bvg_root" ] && [ -d "$_bvg_root/.gaia/state" ]; then
    _bvg_audit_dir="$_bvg_root/.gaia/state/sprint-audit"
    break
  fi
done
if [ -n "$_bvg_audit_dir" ]; then
  mkdir -p "$_bvg_audit_dir" 2>/dev/null || true
  _bvg_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  _bvg_epoch="$(date +%s 2>/dev/null || echo 0)"
  printf 'type: bypass_attempt_blocked\nvariable: %s\ntool: %s\ntimestamp: "%s"\n' \
    "$_bvg_var" "$_bvg_tool" "$_bvg_ts" \
    > "$_bvg_audit_dir/bypass_attempt_blocked-${_bvg_epoch}.yaml" 2>/dev/null || true
fi

# Block the call.
printf 'BLOCKED: tool call sets the protected variable %s. ' "$_bvg_var" >&2
printf 'This variable is operator-only and cannot be set by model tool calls. ' >&2
printf 'The operator must set it in their own terminal session.\n' >&2
exit 2
