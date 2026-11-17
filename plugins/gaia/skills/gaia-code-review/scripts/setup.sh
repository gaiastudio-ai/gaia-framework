#!/usr/bin/env bash
# setup.sh — gaia-code-review skill setup
#
# Mechanical extension of the gaia-create-story/scripts/setup.sh reference
# implementation. Only WORKFLOW_NAME and SCRIPT_NAME differ — the body
# follows the shared pattern.
#
# Responsibilities:
#   1. Resolve config via the shared resolve-config.sh foundation script
#   2. Run validate-gate.sh for prereqs (story file existence)
#   3. Load the checkpoint state for this workflow
#
# Exit codes:
#   0 — setup succeeded, skill body can run
#   1 — config resolution, gate validation, or checkpoint load failed
#
# POSIX discipline: bash with [[ ]] and indexed arrays only. LC_ALL=C for
# deterministic output. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-code-review/setup.sh"
WORKFLOW_NAME="code-review"

# Resolve the GAIA plugin scripts directory from this script's location:
#   skills/gaia-code-review/scripts/setup.sh → ../../../scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"
VALIDATE_GATE="$PLUGIN_SCRIPTS_DIR/validate-gate.sh"
CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 1. Resolve config ----------
[ -x "$RESOLVE_CONFIG" ] || die "resolve-config.sh not found or not executable at $RESOLVE_CONFIG"
if ! config_output=$("$RESOLVE_CONFIG" 2>&1); then
  log "resolve-config.sh failed:"
  printf '%s\n' "$config_output" >&2
  exit 1
fi
# Export every KEY='VALUE' line the resolver emits so downstream tools
# (validate-gate.sh, checkpoint.sh) pick them up from the environment.
while IFS= read -r line; do
  case "$line" in
    [A-Z_]*=*) eval "export $line" ;;
  esac
done <<<"$config_output"

# ---------- 2. Story resolution fail-fast ----------
# Resolve the story key from $1 (bang-line positional) or $ARGUMENTS
# (dev-story defensive env var). Both may carry trailing flags
# (e.g. "--run-id round-x --packet /tmp/p.md") that belong to the skill
# body, not to setup. Extract only the first whitespace-separated token
# and accept it as a key only when it matches the canonical story-key
# shape. When no key is found, resolution is deferred to the skill body.
RESOLVE_STORY="$PLUGIN_SCRIPTS_DIR/resolve-story-file.sh"
_raw_args="${1:-${ARGUMENTS:-}}"
_first_token="${_raw_args%% *}"
_story_key=""
# Accept as a story key only if it looks like one (E<n>-S<n>).
case "$_first_token" in
  E[0-9]*-S[0-9]*) _story_key="$_first_token" ;;
esac
if [ -n "$_story_key" ] && [ -x "$RESOLVE_STORY" ]; then
  _resolve_errf="${TMPDIR:-/tmp}/gaia-setup-resolve-$$"
  _resolved=""
  _resolved="$("$RESOLVE_STORY" "$_story_key" 2>"$_resolve_errf")" || {
    _rc=$?
    _resolve_msg="$(cat "$_resolve_errf" 2>/dev/null || true)"
    rm -f "$_resolve_errf"
    if [ "$_rc" -eq 1 ]; then
      die "story file not found for key $_story_key"
    elif [ "$_rc" -eq 2 ]; then
      die "multiple story files matched key $_story_key"
    else
      die "resolve-story-file.sh failed with exit $_rc: $_resolve_msg"
    fi
  }
  rm -f "$_resolve_errf"
  # Frontmatter key-mismatch guard: compare the resolved file's key to
  # the argument. Halt before any gate/register write on mismatch.
  # A missing key: line is not a mismatch — warn and continue.
  if [ -f "$_resolved" ]; then
    _file_key="$(grep -m1 '^key:' "$_resolved" 2>/dev/null | sed 's/^key:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'"'" || true)"
    if [ -z "$_file_key" ]; then
      log "WARNING: cannot verify frontmatter key — no key: line in $_resolved"
    elif [ "$_file_key" != "$_story_key" ]; then
      die "story file frontmatter key '${_file_key}' does not match argument '${_story_key}'"
    fi
  fi
  log "story file resolved: $_resolved"
fi

# ---------- 2b. Worktree validation ----------
# Parse --worktree from the args. It must be the LAST option: its value is
# everything after "--worktree " to the end of the string (supports paths
# with spaces). If given, validate the worktree:
#   (1) directory exists
#   (2) is inside a git work tree
#   (3) current branch starts with feat/{story_key}-
# If not given, no validation — the skill body or gate-write block resolves
# the worktree standalone.
_worktree_path=""
case "$_raw_args" in
  *--worktree\ *)
    _worktree_path="${_raw_args#*--worktree }"
    ;;
esac
if [ -n "$_worktree_path" ]; then
  if [ ! -d "$_worktree_path" ]; then
    die "--worktree path does not exist or is not a directory: $_worktree_path"
  fi
  if ! git -C "$_worktree_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "--worktree path is not a git work tree: $_worktree_path"
  fi
  if [ -n "$_story_key" ]; then
    _wt_branch="$(git -C "$_worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    case "$_wt_branch" in
      feat/"${_story_key}"-*) ;;  # matches — OK
      *)
        die "--worktree branch '${_wt_branch}' does not match expected feat/${_story_key}-*"
        ;;
    esac
  fi
  log "worktree validated: $_worktree_path"
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

log "setup complete for $WORKFLOW_NAME"
exit 0
