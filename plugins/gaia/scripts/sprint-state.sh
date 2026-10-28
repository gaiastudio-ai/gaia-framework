#!/usr/bin/env bash
# sprint-state.sh — GAIA foundation script
#
# Validates sprint state machine transitions, updates the story file
# frontmatter + body `**Status:**` line and `sprint-status.yaml` atomically,
# and emits a lifecycle event on every successful transition. Replaces the
# LLM-interpreted status-sync protocol with a deterministic, race-safe
# script.
#
# Invocation contract:
#
#   sprint-state.sh transition                 --story <key> --to <state>
#   sprint-state.sh get                        --story <key>
#   sprint-state.sh validate                   --story <key>
#   sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
#   sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
#   sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
#   sprint-state.sh --help
#
# Reconcile:
#   Scans story files under IMPLEMENTATION_ARTIFACTS to detect and correct
#   drift between authoritative story frontmatter (source of truth) and
#   the derivative sprint-status.yaml cache. Write boundary:
#   reconcile NEVER modifies story-file frontmatter — yaml only, routed
#   through the same allowlisted writer the transition path uses.
#   Exit codes: 0 = no drift or drift corrected; 2 = drift detected in
#   --dry-run; 1 = error (missing file / parse error / write failure).
#
# Canonical state set:
#   backlog | validating | ready-for-dev | in-progress | blocked | review | done
#
# Allowed story-level adjacency is defined by the shared SSOT at
# scripts/lib/story-state-machine.sh (STORY_ALLOWED_EDGES). This script
# sources that lib and delegates edge validation to validate_story_transition().
#
# Sprint-Status Write Safety (CRITICAL, per CLAUDE.md):
#   The story file is the source of truth — sprint-status.yaml is a derived
#   cached view. This script ALWAYS re-reads sprint-status.yaml under flock
#   immediately before writing. It updates both locations inside the same
#   critical section so no concurrent reader sees a drifted pair.
#
# Review Gate check on -> done:
#   Transitions to 'done' shell out to review-gate.sh status and require all
#   six canonical rows to report PASSED. Any other verdict (UNVERIFIED or
#   FAILED) blocks the transition with the offending row names enumerated.
#
# Config:
#   PROJECT_ROOT                — defaults to "${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}".
#                                 This is the directory containing `.gaia/` (and
#                                 `docs/` in legacy projects) per CLAUDE.md.
#                                 The runtime tree is resolved relative to it.
#   PROJECT_PATH                — defaults to ".". Application code paths only —
#                                 never the `.gaia/` tree. In a split-repo layout
#                                 (application code in a subdir, `.gaia/` at the
#                                 repo root) PROJECT_PATH and PROJECT_ROOT are
#                                 deliberately different; set PROJECT_ROOT
#                                 explicitly to point at the repo root.
#   IMPLEMENTATION_ARTIFACTS    — defaults to "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts".
#   SPRINT_STATE_SCRIPT_DIR     — internal. Directory of this script, used to
#                                 locate sibling scripts (lifecycle-event.sh,
#                                 review-gate.sh). Override only in tests.
#
# Atomicity & concurrency:
#   All sprint-status.yaml writes are serialized by `flock -x -w 5` on a
#   sibling `sprint-status.yaml.lock` file. Every write (story file AND
#   sprint-status.yaml) is tempfile + atomic `mv`. The same critical section
#   covers:
#     1. read current status from story file
#     2. validate adjacency
#     3. re-read sprint-status.yaml
#     4. rewrite story file via tempfile + mv
#     5. rewrite sprint-status.yaml via tempfile + mv
#     6. emit lifecycle event
#   If step 6 fails the file writes are not rolled back, but the script exits
#   1 and surfaces the failure ("event failure surfaced with exit 1").
#   Subsequent `validate` will detect drift if any downstream consumer cares.
#
# POSIX discipline: the only non-POSIX constructs are [[ ]] and bash indexed
# arrays. macOS /bin/bash 3.2 compatible. Uses `awk`, `sed`, `grep`, `mktemp`,
# and optionally `flock` (graceful mv-based fallback when absent, same
# pattern as checkpoint.sh / lifecycle-event.sh / review-gate.sh).

set -euo pipefail
LC_ALL=C
export LC_ALL

# Reset the rollover-inject suppression flag so it cannot be inherited
# from the caller's environment and bypass the inject independence gate.
# Phase B sets it explicitly in its own subshell when needed.
unset _GAIA_ROLLOVER_INJECT 2>/dev/null || true

SCRIPT_NAME="sprint-state.sh"

# Script-level EXIT/INT/TERM trap for atomic-write tmp cleanup.
# Every tempfile-creating call site appends the resulting path to
# _GAIA_TMP_PATHS and captures its index. After a successful rename the slot
# is cleared so the cleanup is idempotent. Covers SIGINT, SIGTERM, OOM, and
# signal-during-awk paths the function-scoped RETURN traps and inline rm
# paths miss. bash 3.2 compatible.
_GAIA_TMP_PATHS=()
_cleanup_tmps() {
  # Guard against bash 3.2 / `set -u` "unbound variable" on empty arrays.
  if [ "${#_GAIA_TMP_PATHS[@]}" -eq 0 ]; then return 0; fi
  local p
  for p in "${_GAIA_TMP_PATHS[@]}"; do
    if [ -n "$p" ] && [ -e "$p" ]; then
      rm -f "$p" 2>/dev/null || true
    fi
  done
}
trap '_cleanup_tmps' EXIT INT TERM

# ---------- Canonical state machine ----------

# Canonical states. Kept as a self-contained local array (NOT delegated to the
# SSOT's STORY_CANONICAL_STATES) so the reconcile-family helpers can be
# function-extracted and sourced standalone by callers/tests without also
# pulling in the SSOT lib. The two lists are pinned identical by the SSOT
# parity test; the SSOT remains the single source of truth for the edge table.
CANONICAL_STATES=(
  "backlog"
  "validating"
  "ready-for-dev"
  "in-progress"
  "blocked"
  "review"
  "done"
)

# Source the shared story-state-machine SSOT for the allowed-edge table.
# Provides STORY_ALLOWED_EDGES and validate_story_transition().
# The double-source guard (__STORY_STATE_MACHINE_SH) makes this idempotent.
# SPRINT_STATE_SCRIPT_DIR may not be resolved yet (it is set in main()), so
# derive the lib path relative to this file's location.
_SSM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/story-state-machine.sh
. "${_SSM_DIR}/lib/story-state-machine.sh"
# shellcheck source=lib/acquire-lock.sh
. "${_SSM_DIR}/lib/acquire-lock.sh"
# shellcheck source=lib/migrate-items-to-stories.sh
. "${_SSM_DIR}/lib/migrate-items-to-stories.sh"
# Source the concurrent-sprint guard when available (created by the concurrent
# sprints feature). Conditional so the script loads cleanly in test harnesses
# that copy only the essential libs.
if [ -f "${_SSM_DIR}/lib/concurrent-sprint-guard.sh" ]; then
  # shellcheck source=lib/concurrent-sprint-guard.sh
  . "${_SSM_DIR}/lib/concurrent-sprint-guard.sh"
fi
# Persist the script directory for runtime sourcing (resolve-config.sh etc.).
_SPRINT_STATE_SH_DIR="$_SSM_DIR"
unset _SSM_DIR

# ---------- Helpers ----------

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# yaml_single_quote — render a free-text value as a complete single-quoted YAML
# scalar (issue-1403). Doubles inner single-quotes per the YAML single-quote
# escape, so an embedded double-quote OR apostrophe round-trips and never
# breaks the file. Used for title (and any other frontmatter-sourced free text)
# before it is emitted into sprint-status.yaml — a raw double-quoted scalar
# would close early on an inner " and corrupt the YAML, blocking yq readers
# (the /gaia-sprint-close symptom).
yaml_single_quote() {
  local s="$1"
  # Double inner single-quotes per the YAML single-quote escape rule.
  # Uses sed instead of ${s//\'/\'\'} because bash 3.2 interprets the
  # backslash-escape in // substitution differently (treats \' as a
  # literal two-char sequence rather than an escaped quote).
  s="$(printf '%s' "$s" | sed "s/'/''/g")"
  printf "'%s'" "$s"
}

usage() {
  cat <<'USAGE'
Usage:
  sprint-state.sh transition                 --story <key> --to <state>
  sprint-state.sh transition                 --sprint <id> --to <state>
  sprint-state.sh inject                     --story <key> [--phase <n>] [--sprint-id <id>]
  sprint-state.sh get                        --story <key>
  sprint-state.sh validate                   --story <key>
  sprint-state.sh get-goals                  --sprint <id>
  sprint-state.sh set-goals                  --sprint <id> --goals "<g1|g2|..>"
  sprint-state.sh update-goals               --sprint <id> --goals "<g1|g2|..>"
  sprint-state.sh set-review-justification   --sprint <id> --file <path>
  sprint-state.sh set-shape                  --sprint <id> --shape <thrust|completion-pass>
  sprint-state.sh set-story-sprint           --story <key> --sprint <id>
  sprint-state.sh set-phase                  --story <key> --phase <n>
  sprint-state.sh reconcile                  [--sprint-id <id>] [--dry-run]
  sprint-state.sh lint-dependencies          [--sprint-id <id>] [--format json|text]
  sprint-state.sh record-escalation-override --item-ids <ids> --user <name> --reason <text>
  sprint-state.sh advance                    --sprint-id <next-id> [--start-date ...] [--end-date ...]
  sprint-state.sh detect-auto-close
  sprint-state.sh --help

Subcommands:
  init              Bootstrap a fresh sprint-status.yaml when none exists yet.
                    Seeds the canonical shape (sprint_id / status=planned /
                    total_points=0 / goals=[] / stories=[]) under flock — a fresh
                    sprint starts in the `planned` state (planned → active →
                    review → closed). Idempotent — refuses to overwrite
                    an existing yaml. Required before the first `inject` in a
                    new project. Usage: sprint-state.sh init --sprint-id <id>.
                    After /gaia-sprint-close, the live yaml persists with
                    status=closed — init (and advance) re-seed over it.
  advance           Advance to the next sprint after closing the current one.
                    A thin, discoverable alias for `init` that makes the
                    close-to-next-sprint intent explicit. Requires the
                    predecessor sprint to be closed — refuses with a clear
                    message if the current sprint is not closed (directing the
                    operator to close it first). Delegates to the existing
                    init re-seed path (no duplicated seeding logic). Accepts
                    the same optional flags as init (--start-date, --end-date,
                    --sprint-length-days).
                    Usage: sprint-state.sh advance --sprint-id <next-id>.
  transition        Atomically transition a story to <state>. Validates
                    adjacency, re-reads sprint-status.yaml under flock,
                    rewrites story file frontmatter + body Status line +
                    sprint-status.yaml, and emits one lifecycle event.
                    Transitions to 'done' require all six Review Gate rows
                    to report PASSED (via review-gate.sh status).
  inject            Append a backlog story to the active sprint's
                    sprint-status.yaml. Requires the story file's
                    frontmatter sprint_id to match the yaml sprint_id
                    (drift guard). Idempotent — re-running on an already-
                    injected key is a no-op.
                    total_points: accumulated from the injected story's
                    frontmatter `points:` field — no --points CLI flag
                    is needed or accepted. Recomputes capacity_utilization
                    and emits one story_injected lifecycle event.
                    Boundary-write seed rule: when boundary-writing a
                    fresh sprint, seed total_points=0 — inject accumulates
                    onto the existing total; a non-zero seed produces
                    double-counted totals.
                    Used by /gaia-correct-course story-injection.
                    Optional --phase <n> records the story's execution
                    phase; omit it and no phase field is written.
  set-phase         Set or clear the optional execution phase on an existing
                    story row in the active sprint. `--phase <n>` sets a
                    positive integer (no leading zeros); `--phase ""` clears
                    the field. Idempotent — setting the value already
                    present, or clearing an absent field, is a no-op that
                    exits 0 without writing. Refuses a story key not present
                    in the yaml. The phase is a scheduling attribute of ONE
                    sprint, so `rollover` deliberately clears it when moving
                    a story between sprints; the next sprint plan re-derives.
  get               Print the story's current status (from the story file)
                    to stdout and exit 0.
  validate          Compare story file status to sprint-status.yaml. Exit 0
                    if they agree, exit 1 with a drift description on stderr
                    if not.
  reconcile         Scan the target sprint's story files and reconcile
                    sprint-status.yaml to match authoritative frontmatter.
                    NEVER modifies story files. Exit 0 on no-drift or
                    drift-corrected, 2 on dry-run drift, 1 on error.
  lint-dependencies Read-only analysis of the selected sprint's dependency
                    graph. Detects forward-references (dependency inversions)
                    where a story depends on a resource created by a later
                    story in the sprint order.
                    Exit 0 = clean, 2 = inversions detected (advisory),
                    1 = error.
  detect-auto-close Read-only advisory probe. Emits a single-line JSON
                    payload on stdout when the active sprint has every story
                    at status=done with total_count>0 and top-level
                    status=active. Empty stdout when the auto-close
                    condition is not met. ALWAYS exits 0. NEVER mutates
                    sprint-status.yaml — the boundary write
                    (status=closed + next-sprint seed) remains a manual
                    operator action.

  transition --sprint  Sprint-level state-machine transitions. Edges:
                    active→review (gated on all-stories-done), review→closed,
                    review→correction, correction→active.
                    Refuses any other edge with `illegal sprint-level
                    transition: <from>→<to>`. Uses atomic mktemp + mv so
                    YAML comments and formatting are preserved.

  get-goals         Print the sprint's `goals[]` list (one per line) to
                    stdout. Empty output + exit 0 when no goals set.

  set-goals         REPLACE the sprint's `goals[]` list with the
                    pipe-delimited string passed via --goals "<g1|g2|...>".
                    Each goal is capped at 280 chars. Lossless round-trip
                    with get-goals.

  update-goals      Alias for set-goals (REPLACES; does not append).

  set-review-justification
                    Write the `review_justification:` block from a YAML
                    payload file (--file <path>) into sprint-status.yaml.
                    Required payload fields: primary_criterion ∈ {C1, C2, C3},
                    qualifying_story_points (int), total_story_points (int),
                    qualifying_ratio ≥ 0.80, explanation (200-1000 chars block
                    scalar). Existing block is replaced atomically.

Canonical states (CLAUDE.md):
  backlog | validating | ready-for-dev | in-progress | blocked | review | done

Config:
  PROJECT_ROOT                defaults to "${CLAUDE_PROJECT_ROOT:-.}". Anchors
                              the `.gaia/` tree (and legacy `docs/`) per CLAUDE.md.
  PROJECT_PATH                defaults to "${PROJECT_ROOT}". Application code only.
                              Differs from PROJECT_ROOT in split-repo layouts.
  IMPLEMENTATION_ARTIFACTS    defaults to "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts"
                              (falls back to "${PROJECT_ROOT}/docs/implementation-artifacts").
  SPRINT_STATUS_YAML          overrides the default yaml path (tests).

Exit codes:
  0  success
  1  usage error, invalid state, illegal transition, missing file, lock
     failure, review gate failure, glob mismatch, drift (validate), or
     reconcile/lint-dependencies error (missing story file, parse failure)
  2  reconcile --dry-run detected drift but wrote nothing, or
     lint-dependencies detected inversions (advisory, non-blocking), or
     sprint-id mismatch on transition --sprint
USAGE
}

# Self-contained canonical-state helpers (no SSOT dependency) so the
# reconcile-family functions remain function-extractable in isolation.
is_canonical_state() {
  local candidate="$1" s
  for s in "${CANONICAL_STATES[@]}"; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}
canonical_states_hint() {
  local IFS=' '
  printf '%s' "${CANONICAL_STATES[*]}"
}

# Fail-fast guard for any value about to be written into a lifecycle
# `status:` field. Any non-canonical value (e.g. the review-gate display
# strings 'PASSED' / 'FAILED' / 'UNVERIFIED') MUST be rejected before any
# tempfile rewrite touches disk — yaml and story file are left byte-identical.
# The error names BOTH the offending value and the allowed enum so the caller
# can correct the invocation without reading source.
assert_canonical_state() {
  local candidate="$1" context="${2:-write}"
  if ! is_canonical_state "$candidate"; then
    die "refusing to ${context} non-canonical lifecycle status: '${candidate}' — allowed values: $(canonical_states_hint)"
  fi
}

# Exit 1 (via die) unless "from -> to" is a legal story-level edge.
# Delegates to validate_story_transition() from the shared SSOT; wraps the
# return code in die() to preserve sprint-state.sh's error-path contract
# (callers depend on exit 1 + the message shape).
validate_transition() {
  local from="$1" to="$2"
  if ! validate_story_transition "$from" "$to" 2>/dev/null; then
    die "illegal transition: '${from}' -> '${to}' is not in the allowed adjacency list"
  fi
}

# ---------- Sprint ID validation ----------

# Validate a sprint ID against the safe-character regex. IDs must start with
# an alphanumeric character and contain only [A-Za-z0-9._-]. Rejects path
# separators, NUL, whitespace, leading dots, leading dashes and colons.
_validate_sprint_id() {
  local id="$1"
  if [ -z "$id" ]; then
    printf '%s: error: sprint-id is required\n' "$SCRIPT_NAME" >&2
    return 1
  fi
  # Reject IDs containing characters outside the safe set.
  # The grep-based check is portable across bash 3.2+ and handles all
  # filesystem-unsafe characters (/, NUL, whitespace, colon, etc.).
  if printf '%s' "$id" | /usr/bin/grep -q '[^A-Za-z0-9._-]'; then
    printf '%s: error: sprint-id contains invalid characters: %s (must match ^[A-Za-z0-9][A-Za-z0-9._-]*$)\n' \
      "$SCRIPT_NAME" "$id" >&2
    return 1
  fi
  # First character must be alphanumeric (rejects leading dot, leading dash).
  case "${id:0:1}" in
    [A-Za-z0-9]) : ;;
    *)
      printf '%s: error: sprint-id must start with an alphanumeric character: %s\n' \
        "$SCRIPT_NAME" "$id" >&2
      return 1 ;;
  esac
  return 0
}

# ---------- Concurrent-mode helpers ----------

# Read max_concurrent_active from project config. Defaults to 1 when absent.
# Caches the result in _GAIA_MAX_CONCURRENT for the lifetime of the process.
# Uses direct yq query (lightweight, no resolve-config.sh dependencies).
_read_max_concurrent_active() {
  if [ -n "${_GAIA_MAX_CONCURRENT:-}" ]; then
    printf '%s' "$_GAIA_MAX_CONCURRENT"
    return 0
  fi
  local val=""
  # Resolve the config file path. Use the PROJECT_CONFIG env var if set;
  # otherwise derive from PROJECT_ROOT (which resolve_paths() has already
  # resolved). An unset PROJECT_ROOT makes the path relative to CWD, which
  # is correct when CWD is the project root.
  local cfg="${PROJECT_CONFIG:-}"
  if [ -z "$cfg" ]; then
    if [ -n "${PROJECT_ROOT:-}" ]; then
      cfg="${PROJECT_ROOT%/}/.gaia/config/project-config.yaml"
    fi
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    # Fast path: grep for the key before spawning yq (avoids ~40ms fork).
    if /usr/bin/grep -q 'max_concurrent_active' "$cfg" 2>/dev/null; then
      if command -v yq >/dev/null 2>&1; then
        val="$(yq '.sprint.max_concurrent_active' "$cfg" 2>/dev/null)" || val=""
      fi
    fi
  fi
  # Fall back to 1 when absent, null, or non-numeric.
  case "$val" in
    ''|null|*[!0-9]*) val="1" ;;
  esac
  _GAIA_MAX_CONCURRENT="$val"
  printf '%s' "$val"
}
_GAIA_MAX_CONCURRENT=""

# Check whether per-sprint state files exist in the state directory.
_per_sprint_files_exist() {
  local state_dir="$1"
  [ -d "$state_dir" ] || return 1
  local found=""
  found="$(find "$state_dir" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || found=""
  [ -n "$found" ]
}

# Determine whether the system is in concurrent mode:
#   max_concurrent_active > 1 OR per-sprint files exist (transitional state).
# The result is computed once per process and cached in _GAIA_CONCURRENT_MODE.
# Call _invalidate_concurrent_mode_cache after reverse migration removes
# per-sprint files to force a re-check.
_GAIA_CONCURRENT_MODE=""

_is_concurrent_mode() {
  # Return cached result when available (hot path — no subprocess, no I/O).
  case "${_GAIA_CONCURRENT_MODE:-}" in
    1) return 0 ;; 0) return 1 ;;
  esac
  # Cold path: compute and cache.
  local max
  max="$(_read_max_concurrent_active)"
  if [ "$max" -gt 1 ] 2>/dev/null; then
    _GAIA_CONCURRENT_MODE=1
    return 0
  fi
  local state_dir
  state_dir="$(dirname "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml}")"
  if _per_sprint_files_exist "$state_dir"; then
    _GAIA_CONCURRENT_MODE=1
    return 0
  fi
  _GAIA_CONCURRENT_MODE=0
  return 1
}

_invalidate_concurrent_mode_cache() {
  _GAIA_CONCURRENT_MODE=""
  _GAIA_MAX_CONCURRENT=""
}

# ---------- Per-sprint file resolver ----------

# Build the per-sprint state file path from a sprint ID.
_sprint_file_path() {
  local state_dir="$1" sprint_id="$2"
  printf '%s/sprint-status-%s.yaml' "$state_dir" "$sprint_id"
}

# Path length check — reject if combined path exceeds OS limits.
_check_path_length() {
  local path="$1"
  local max_path="${GAIA_PATH_MAX:-1024}"
  if [ "${#path}" -gt "$max_path" ]; then
    printf '%s: error: per-sprint file path exceeds length limit (%d > %d): %s\n' \
      "$SCRIPT_NAME" "${#path}" "$max_path" "$path" >&2
    return 1
  fi
  return 0
}

# _resolve_sprint_file — the central resolver for sprint state files.
#
# Resolution order (per R19):
#   1. --sprint argument (when non-empty)
#   2. Session binding file at $GAIA_BINDING_DIR/bound_sprint_id
#   3. Single-file default (sprint-status.yaml as resolve_paths computed it)
#
# In single-sprint mode (max_concurrent_active absent or 1 AND no per-sprint
# files exist), short-circuits to the path resolve_paths() already computed.
#
# Globals read: SPRINT_STATUS_YAML, GAIA_BINDING_DIR, GAIA_BOUND_SPRINT_ID
# Outputs the resolved file path on stdout.
_resolve_sprint_file() {
  local sprint_arg="${1:-}"
  local state_dir
  state_dir="$(dirname "$SPRINT_STATUS_YAML")"

  # Short-circuit: single-sprint mode — no per-sprint files, limit absent or 1.
  if ! _is_concurrent_mode; then
    printf '%s' "$SPRINT_STATUS_YAML"
    return 0
  fi

  # Priority 1: explicit --sprint argument.
  if [ -n "$sprint_arg" ]; then
    _validate_sprint_id "$sprint_arg" || return 1
    local p
    p="$(_sprint_file_path "$state_dir" "$sprint_arg")"
    _check_path_length "$p" || return 1
    printf '%s' "$p"
    return 0
  fi

  # Priority 2: session binding file.
  if [ -n "${GAIA_BINDING_DIR:-}" ] && [ -f "${GAIA_BINDING_DIR}/bound_sprint_id" ]; then
    local bound_id=""
    # Read the binding file (re-read every time; env var is only a cache).
    bound_id="$(cat "${GAIA_BINDING_DIR}/bound_sprint_id" 2>/dev/null | tr -d '\n')" || bound_id=""
    if [ -n "$bound_id" ]; then
      _validate_sprint_id "$bound_id" || return 1
      local bp
      bp="$(_sprint_file_path "$state_dir" "$bound_id")"
      _check_path_length "$bp" || return 1
      printf '%s' "$bp"
      return 0
    fi
  fi

  # Priority 3: single-file default (the proxy or the only file).
  printf '%s' "$SPRINT_STATUS_YAML"
  return 0
}

# ---------- Completed-migration marker ----------

_MIGRATION_MARKER_NAME=".sprint-migration-complete"

_migration_marker_path() {
  local state_dir="$1"
  printf '%s/%s' "$state_dir" "$_MIGRATION_MARKER_NAME"
}

_migration_is_complete() {
  local state_dir="$1"
  local p
  p="$(_migration_marker_path "$state_dir")"
  [ -f "$p" ] || return 1
  # Validate marker content: must contain a sprint ID and a timestamp.
  # A 0-byte or truncated marker is not complete.
  local content=""
  content="$(cat "$p" 2>/dev/null)" || return 1
  [ -n "$content" ] || return 1
  # First word must be a valid sprint ID.
  local marker_id=""
  marker_id="${content%% *}"
  _validate_sprint_id "$marker_id" 2>/dev/null || return 1
  return 0
}

# Write the migration marker atomically (temp + mv).
_write_migration_marker() {
  local state_dir="$1" sprint_id="$2"
  local p
  p="$(_migration_marker_path "$state_dir")"
  local tmp
  tmp="$(mktemp "${p}.XXXXXX")"
  printf '%s %s\n' "$sprint_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  mv "$tmp" "$p"
}

# ---------- Last-activated record ----------

_LAST_ACTIVATED_NAME=".last-activated-sprint"

_last_activated_path() {
  local state_dir="$1"
  printf '%s/%s' "$state_dir" "$_LAST_ACTIVATED_NAME"
}

_read_last_activated() {
  local state_dir="$1"
  local p
  p="$(_last_activated_path "$state_dir")"
  [ -f "$p" ] || return 0
  local val=""
  val="$(cat "$p" 2>/dev/null | tr -d '\n')" || return 0
  # Reject empty or invalid IDs (truncated marker, 0-byte file).
  if [ -z "$val" ] || ! _validate_sprint_id "$val" 2>/dev/null; then
    return 0
  fi
  printf '%s' "$val"
}

_write_last_activated() {
  local state_dir="$1" sprint_id="$2"
  local p
  p="$(_last_activated_path "$state_dir")"
  local tmp
  tmp="$(mktemp "${p}.XXXXXX")"
  printf '%s' "$sprint_id" > "$tmp"
  mv "$tmp" "$p"
}

# ---------- Forward migration ----------

# Migrate from single-file layout to per-sprint files. Called under L4 (strict).
# Idempotent: skips when the completed-migration marker is present.
_forward_migration() {
  local state_dir="$1" existing_id="$2" new_id="$3"

  # Validate IDs before constructing any paths.
  _validate_sprint_id "$existing_id" || return 1
  _validate_sprint_id "$new_id" || return 1

  local marker
  marker="$(_migration_marker_path "$state_dir")"
  local original="${state_dir}/sprint-status.yaml"

  # Idempotent: already migrated — but only if the per-sprint file also exists.
  # A marker without the per-sprint file means the marker was written before
  # the copy completed (a crash or the "marker before copy" ordering bug).
  local existing_per_sprint
  existing_per_sprint="$(_sprint_file_path "$state_dir" "$existing_id")"
  if _migration_is_complete "$state_dir" && [ -f "$existing_per_sprint" ]; then
    return 0
  fi

  # Incomplete migration detection: per-sprint files exist but marker absent
  # (or marker present but per-sprint file missing). Re-run verification.
  if [ -f "$existing_per_sprint" ]; then
    # Verify byte-equality and valid YAML.
    if ! diff -q "$existing_per_sprint" "$original" >/dev/null 2>&1; then
      # Not byte-equal — re-copy.
      cp "$original" "$existing_per_sprint"
      sync "$existing_per_sprint" 2>/dev/null || true
    fi
    # Verify YAML validity.
    if ! python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$existing_per_sprint" 2>/dev/null; then
      if ! awk '/^[^#]/' "$existing_per_sprint" | head -1 | grep -q ':' 2>/dev/null; then
        printf '%s: error: forward migration — per-sprint file is not valid YAML: %s\n' \
          "$SCRIPT_NAME" "$existing_per_sprint" >&2
        return 1
      fi
    fi
    # Write the completed-migration marker atomically.
    _write_migration_marker "$state_dir" "$existing_id"
    # Seed the last-activated record with the already-active sprint.
    _write_last_activated "$state_dir" "$existing_id"
    # Update the proxy to mirror the existing (already-active) sprint.
    _write_proxy_from_file "$state_dir" "$existing_per_sprint"
    return 0
  fi

  # Fresh migration: copy original to per-sprint file for the existing sprint.
  local created_files=()
  _migration_cleanup() {
    local f
    for f in "${created_files[@]}"; do
      rm -f "$f" 2>/dev/null || true
    done
  }

  cp "$original" "$existing_per_sprint" || { _migration_cleanup; return 1; }
  sync "$existing_per_sprint" 2>/dev/null || true
  created_files+=("$existing_per_sprint")

  # Post-migration verification: byte-equality and valid YAML.
  if ! diff -q "$existing_per_sprint" "$original" >/dev/null 2>&1; then
    printf '%s: error: forward migration — per-sprint file not byte-equal to original\n' \
      "$SCRIPT_NAME" >&2
    _migration_cleanup
    return 1
  fi

  # Verify the per-sprint file parses as valid YAML.
  if ! python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$existing_per_sprint" 2>/dev/null; then
    # Fallback: check with awk if python3 or PyYAML is unavailable.
    if ! awk '/^[^#]/' "$existing_per_sprint" | head -1 | grep -q ':' 2>/dev/null; then
      printf '%s: error: forward migration — per-sprint file is not valid YAML\n' "$SCRIPT_NAME" >&2
      _migration_cleanup
      return 1
    fi
  fi

  # Seed the last-activated record with the already-active sprint under L4.
  _write_last_activated "$state_dir" "$existing_id"
  created_files+=("$(_last_activated_path "$state_dir")")

  # Write the proxy (mirrors the already-active sprint).
  _write_proxy_from_file "$state_dir" "$existing_per_sprint"

  # Verify the proxy parses as valid YAML.
  if ! python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "${state_dir}/sprint-status.yaml" 2>/dev/null; then
    if ! awk '/^[^#]/' "${state_dir}/sprint-status.yaml" | head -1 | grep -q ':' 2>/dev/null; then
      printf '%s: error: forward migration — proxy is not valid YAML\n' "$SCRIPT_NAME" >&2
      _migration_cleanup
      return 1
    fi
  fi

  # Write the completed-migration marker ONLY after all verification passes.
  _write_migration_marker "$state_dir" "$existing_id"

  return 0
}

# ---------- Reverse migration ----------

# Migrate from per-sprint files back to single-file layout. Called under L4.
# Precondition: max_concurrent_active = 1, only one sprint remains active.
_reverse_migration() {
  local state_dir="$1" active_id="$2"

  # Validate the sprint ID before constructing any paths.
  _validate_sprint_id "$active_id" || return 1

  local per_sprint
  per_sprint="$(_sprint_file_path "$state_dir" "$active_id")"

  # Verify the sprint ID from the file — validate before any comparison.
  local file_sid=""
  file_sid="$(read_yaml_sprint_id "$per_sprint" 2>/dev/null || true)"
  if [ -n "$file_sid" ]; then
    _validate_sprint_id "$file_sid" || return 1
  fi
  if [ -n "$file_sid" ] && [ "$file_sid" != "$active_id" ]; then
    printf '%s: error: reverse migration — sprint ID mismatch: file says %s, expected %s\n' \
      "$SCRIPT_NAME" "$file_sid" "$active_id" >&2
    return 1
  fi

  # Atomically copy the active sprint's per-sprint file back to sprint-status.yaml.
  local proxy="${state_dir}/sprint-status.yaml"
  local tmp
  tmp="$(mktemp "${proxy}.XXXXXX")"
  cp "$per_sprint" "$tmp" || { rm -f "$tmp"; return 1; }
  sync "$tmp" 2>/dev/null || true
  mv "$tmp" "$proxy" || { rm -f "$tmp"; return 1; }

  # Remove the active sprint's per-sprint file.
  rm -f "$per_sprint" 2>/dev/null || true

  # Remove per-sprint files of closed sprints (already archived).
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    # Skip lock files and result files.
    case "$f" in *.lock|*.result) continue ;; esac
    rm -f "$f" 2>/dev/null || true
  done

  # Remove the last-activated record.
  rm -f "$(_last_activated_path "$state_dir")" 2>/dev/null || true

  # Remove the completed-migration marker.
  rm -f "$(_migration_marker_path "$state_dir")" 2>/dev/null || true

  return 0
}

# Check if reverse migration should run and execute it under L4.
# Preconditions: max_concurrent_active = 1, per-sprint files exist,
# only one active sprint remains.
_maybe_reverse_migration() {
  local state_dir="$1"
  local max
  max="$(_read_max_concurrent_active)"

  # Only trigger when limit is 1.
  [ "$max" -le 1 ] 2>/dev/null || return 0

  # Per-sprint files must exist (transitional state).
  _per_sprint_files_exist "$state_dir" || return 0

  # Count active sprints across per-sprint files.
  local active_count=0 active_id=""
  local f
  for f in "${state_dir}"/sprint-status-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.lock|*.result) continue ;; esac
    local st=""
    st="$(_yaml_sprint_status "$f" 2>/dev/null || true)"
    case "$st" in
      active|planned|review|correction)
        active_count=$((active_count + 1))
        active_id="$(read_yaml_sprint_id "$f" 2>/dev/null || true)"
        ;;
    esac
  done

  # Reverse migration only when exactly one non-closed sprint remains.
  [ "$active_count" -eq 1 ] || return 0
  [ -n "$active_id" ] || return 0
  # Validate the ID from the file before building paths.
  _validate_sprint_id "$active_id" 2>/dev/null || return 0

  # Run under L4 (strict mode).
  local l4_path="${state_dir}/${GAIA_LOCK_L4_PATH}"
  (
    if ! acquire_lock "$l4_path" "$GAIA_LOCK_L4_TIMEOUT" 8 --strict; then
      printf '%s: error: reverse migration — lifecycle lock timeout\n' "$SCRIPT_NAME" >&2
      return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
    fi
    trap 'release_lock 8 2>/dev/null || true' EXIT
    trap 'release_lock 8 2>/dev/null || true; exit 130' INT
    trap 'release_lock 8 2>/dev/null || true; exit 143' TERM
    _reverse_migration "$state_dir" "$active_id"
  )
}

# ---------- Compatibility proxy writer ----------

# Write the proxy file atomically from a source per-sprint file.
_write_proxy_from_file() {
  local state_dir="$1" source_file="$2"
  local proxy="${state_dir}/sprint-status.yaml"
  local tmp
  tmp="$(mktemp "${proxy}.XXXXXX")" || return 1
  cp "$source_file" "$tmp" || { rm -f "$tmp"; return 1; }
  sync "$tmp" 2>/dev/null || true
  mv "$tmp" "$proxy" || { rm -f "$tmp"; return 1; }
  return 0
}

# Post-write hook: update the compatibility proxy when the write targets the
# last-activated sprint. In concurrent mode only.
# Args: $1 = state_dir, $2 = sprint_id that was just written, $3 = per-sprint file
_GAIA_PROXY_HOOK_SUPPRESSED=0

_update_compatibility_proxy() {
  local state_dir="$1" written_sprint_id="$2" per_sprint_file="$3"

  # Skip in single-sprint mode.
  _is_concurrent_mode || return 0

  # Skip when suppressed (inside rollover).
  [ "$_GAIA_PROXY_HOOK_SUPPRESSED" -eq 0 ] || return 0

  # Only update when the write targets the last-activated sprint.
  local last_activated=""
  last_activated="$(_read_last_activated "$state_dir")"
  [ -n "$last_activated" ] || return 0
  [ "$written_sprint_id" = "$last_activated" ] || return 0

  # Acquire the proxy lock (L5, non-strict, 2s timeout).
  local l5_path="${state_dir}/${GAIA_LOCK_L5_PATH}"
  (
    if ! acquire_lock "$l5_path" "$GAIA_LOCK_L5_TIMEOUT" 7; then
      printf '%s: warning: proxy lock timeout — proxy may be stale\n' "$SCRIPT_NAME" >&2
      return 0
    fi
    trap 'release_lock 7 2>/dev/null || true' EXIT
    trap 'release_lock 7 2>/dev/null || true; exit 130' INT
    trap 'release_lock 7 2>/dev/null || true; exit 143' TERM
    _write_proxy_from_file "$state_dir" "$per_sprint_file"
  ) || true  # Proxy failure is non-fatal (per-sprint file is authoritative).
}

# _migrate_items_to_stories is now in lib/migrate-items-to-stories.sh (sourced
# above). The shared library provides migrate_items_to_stories() (locked) and
# read_stories_or_items() (read-only). Sprint-state.sh calls the locked form
# at pre-dispatch after the concurrent-mode SPRINT_STATUS_YAML repointing.

# Resolve configuration — PROJECT_PATH, IMPLEMENTATION_ARTIFACTS, and yaml path.
# Honor pre-exported SPRINT_STATUS_YAML so tests can point the script at a
# temp-dir yaml that does not live under IMPLEMENTATION_ARTIFACTS.
# When SPRINT_STATUS_YAML is unset, resolve to the canonical .gaia/state/
# location, then fall back through legacy docs/ and project-root paths
# for bats fixtures and in-deprecation-window consumers.
resolve_paths() {
  # PROJECT_ROOT is the directory containing `.gaia/` (per CLAUDE.md).
  # PROJECT_PATH is application-code only; in a split-repo layout (app in a
  # subdir, `.gaia/` at the repo root) the two differ deliberately. The `.gaia/`
  # tree and the legacy `docs/` tree resolve from PROJECT_ROOT.
  #
  # Backward-compat default: when PROJECT_ROOT is unset, fall back to
  # PROJECT_PATH (then to CLAUDE_PROJECT_ROOT, then to "."). This preserves the
  # historic behavior for callers that set only PROJECT_PATH while letting
  # split-repo callers set PROJECT_ROOT explicitly to override.
  PROJECT_PATH="${PROJECT_PATH:-.}"
  PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH}}}"
  # Smart-fallback for IMPLEMENTATION_ARTIFACTS — prefer
  # .gaia/artifacts/implementation-artifacts/ when present on disk, fall back
  # to legacy docs/implementation-artifacts/ for in-deprecation-window
  # consumers and bats fixtures. Env-var override still wins.
  if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    if [ -d "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts" ]; then
      IMPLEMENTATION_ARTIFACTS="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts"
    else
      IMPLEMENTATION_ARTIFACTS="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}docs/implementation-artifacts"
    fi
  fi
  # `.gaia/state/sprint-status.yaml` is the sole canonical home for
  # sprint-status.yaml.  The .gaia/artifacts/implementation-artifacts/
  # mirror has been retired (Issue #1109 deprecation).  The legacy
  # docs/implementation-artifacts/ path is still a read-compat fallback for
  # projects seeded before the state-tier migration.  Resolution order:
  #   1. existing .gaia/state/ yaml — canonical
  #   2. existing docs/implementation-artifacts/ yaml — legacy read-compat
  #   3. existing project-root fallback (bats fixtures)
  #   4. fresh write → canonical .gaia/state/ default
  if [ -z "${SPRINT_STATUS_YAML:-}" ]; then
    local gaia_state="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml"
    local legacy_docs="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}docs/implementation-artifacts/sprint-status.yaml"
    local fallback="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}sprint-status.yaml"
    if [ -e "$gaia_state" ]; then
      SPRINT_STATUS_YAML="$gaia_state"
    elif [ -e "$legacy_docs" ]; then
      SPRINT_STATUS_YAML="$legacy_docs"
    elif [ -e "$fallback" ]; then
      SPRINT_STATUS_YAML="$fallback"
    else
      SPRINT_STATUS_YAML="$gaia_state"
    fi
  fi
  SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
}

# Check whether a file's YAML frontmatter contains `template: 'story'`.
# Reads only the frontmatter block (between the first two `---` lines).
# Returns 0 if the file is a canonical story file, 1 otherwise.
# Portable: bash 3.2+ compatible, uses awk only.
_is_story_file() {
  local f="$1"
  awk '
    /^---[[:space:]]*$/ { n++; if (n == 2) exit }
    n == 1 && /^template:[[:space:]]*["\x27]?story["\x27]?[[:space:]]*$/ { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$f"
}

# Locate the story file under IMPLEMENTATION_ARTIFACTS across all three layout
# tiers, then filter candidates by frontmatter `template: 'story'` to exclude
# review sibling files (-review.md, -qa-tests.md, -security-review.md, etc.).
# Returns via the STORY_FILE global. Exits 1 on zero or multiple canonical
# matches.
#
# Layout tiers globbed (precedence handled downstream by the template filter +
# realpath dedup, mirroring resolve-story-file.sh):
#   0. NEW per-story nested:  epic-{slug}/{key}-{slug}/story.md
#   1. Legacy nested:         epic-{slug}/stories/{key}-{slug}.md
#   2. Legacy flat:           {key}-{slug}.md
STORY_FILE=""
locate_story_file() {
  local key="$1"
  local pattern="${IMPLEMENTATION_ARTIFACTS}/${key}-*.md"
  local epic_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/stories/${key}-*.md"
  # NEW per-story layout: the story's own directory carries the key; basename is
  # literally story.md. The `/stories/` segment (legacy tier-1) is excluded below
  # so a bare-glob `epic-*/${key}-*/story.md` cannot also pick up the tier-1 tree.
  local perstory_pattern="${IMPLEMENTATION_ARTIFACTS}/epic-*/${key}-*/story.md"

  local matches=()
  shopt -s nullglob
  # shellcheck disable=SC2206
  matches=( $pattern $epic_pattern $perstory_pattern )
  shopt -u nullglob

  # Drop any perstory_pattern hit that actually lives under a legacy `stories/`
  # segment — that path belongs to the tier-1 epic_pattern, not tier-0, and the
  # `*` in the glob would otherwise let `epic-*/stories/{key}-*/story.md`
  # (per-story evidence dirs) leak in (mirrors resolve-story-file.sh guard).
  if [ "${#matches[@]}" -gt 0 ]; then
    local _filtered=()
    local _mm
    for _mm in "${matches[@]}"; do
      case "$_mm" in
        */stories/*/story.md) continue ;;
      esac
      _filtered+=( "$_mm" )
    done
    matches=( "${_filtered[@]}" )
  fi

  if [ "${#matches[@]}" -eq 0 ]; then
    die "no story file found for key '$key' (globs: $pattern | $epic_pattern | $perstory_pattern)"
  fi

  # Filter glob matches: keep only files whose frontmatter declares template: 'story'
  local canonical=()
  local m
  for m in "${matches[@]}"; do
    if _is_story_file "$m"; then
      canonical+=( "$m" )
    fi
  done

  if [ "${#canonical[@]}" -eq 0 ]; then
    die "no story file found for key '$key' (checked ${#matches[@]} candidates, none have template: 'story' frontmatter)"
  fi

  # Deduplicate by realpath. Symlinks at the flat layer pointing at the
  # epic-grouped real file (transition shims) produce two canonical matches
  # that are the same physical file. Prefer non-symlinks.
  if [ "${#canonical[@]}" -gt 1 ]; then
    local dedup=()
    local seen_realpaths=""
    local rp
    for m in "${canonical[@]}"; do
      [ -L "$m" ] && continue
      if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath "$m")
      else
        rp=$(cd "$(dirname "$m")" && /bin/pwd -P)/$(basename "$m")
      fi
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    for m in "${canonical[@]}"; do
      [ -L "$m" ] || continue
      if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath "$m")
      else
        rp=$(cd "$(dirname "$(readlink "$m")")" 2>/dev/null && /bin/pwd -P)/$(basename "$(readlink "$m")")
      fi
      case "$seen_realpaths" in
        *"|$rp|"*) ;;
        *) dedup+=( "$m" ); seen_realpaths="${seen_realpaths}|$rp|" ;;
      esac
    done
    canonical=( "${dedup[@]}" )
  fi

  if [ "${#canonical[@]}" -gt 1 ]; then
    {
      printf '%s: error: ambiguous canonical story files for key %s:\n' \
        "$SCRIPT_NAME" "$key"
      printf '  %s\n' "${canonical[@]}"
    } >&2
    exit 1
  fi

  STORY_FILE="${canonical[0]}"
}

# Extract the current status from a story file's frontmatter. The story
# template uses `status: <value>` (unquoted or quoted). Returns via stdout.
# Exits 1 if the field is missing.
read_story_status() {
  local file="$1"
  # Only scan the frontmatter block (between the first two `---` lines).
  local status
  status=$(awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/, "", $0)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$file")

  if [ -z "$status" ]; then
    die "story file '$file' is missing 'status:' in frontmatter"
  fi
  printf '%s' "$status"
}

# Rewrite a story file so that (a) the frontmatter `status:` field and
# (b) the body `**Status:**` line both show $new_status. Preserves all
# other bytes. Tempfile + atomic mv.
rewrite_story_status() {
  local file="$1" new_status="$2"
  # Defense-in-depth: even if a future caller bypasses cmd_transition's
  # fail-fast guard, this writer refuses to stamp a non-canonical value into
  # the story file. Belt-and-braces against non-canonical status writes.
  assert_canonical_state "$new_status" "write story status"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v new_status="$new_status" '
    BEGIN { in_fm = 0; seen = 0; fm_done = 0; rewrote_fm = 0; rewrote_body = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    !fm_done && line ~ /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; print raw; next }
      if (in_fm) { in_fm = 0; fm_done = 1; print raw; next }
    }
    in_fm && !rewrote_fm && line ~ /^status:[[:space:]]*/ {
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "status: %s%s\n", new_status, crlf
      rewrote_fm = 1
      next
    }
    fm_done && !rewrote_body && line ~ /^>[[:space:]]*\*\*Status:\*\*/ {
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "> **Status:** %s%s\n", new_status, crlf
      rewrote_body = 1
      next
    }
    { print raw }
    END {
      if (!rewrote_fm)   { exit 2 }
      if (!rewrote_body) { exit 3 }
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      die "failed to locate frontmatter 'status:' field in '$file'"
    elif [ $rc -eq 3 ]; then
      die "failed to locate body '> **Status:**' line in '$file'"
    else
      die "awk rewrite of '$file' failed (rc=$rc)"
    fi
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Rewrite the matching story entry in sprint-status.yaml so its `status:`
# field reads $new_status. Preserves all other bytes. Tempfile + atomic mv.
# Exits 1 if the story entry is not found (so drift is loud, never silent).
rewrite_sprint_status_yaml() {
  local story_key="$1" new_status="$2"
  local file="$SPRINT_STATUS_YAML"

  # Defense-in-depth: refuse to stamp a non-canonical value into
  # sprint-status.yaml even if the caller bypassed the higher-level guard.
  # This is the same chokepoint that reconcile and the transition path both
  # flow through, so guarding here closes every write path.
  assert_canonical_state "$new_status" "write sprint-status.yaml status"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$story_key" -v new_status="$new_status" '
    BEGIN { in_entry = 0; rewrote = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # A new list entry starts with `  - key:` at two-space indent.
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      # Extract the key value and strip quotes.
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1 } else { in_entry = 0 }
      print raw
      next
    }
    # Any subsequent list entry or top-level key closes the current entry.
    in_entry && line ~ /^[^[:space:]]/ {
      in_entry = 0
    }
    in_entry && !rewrote && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      # Preserve the original indentation.
      match(raw, /^[[:space:]]+/)
      indent = substr(raw, RSTART, RLENGTH)
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
      printf "%sstatus: \"%s\"%s\n", indent, new_status, crlf
      rewrote = 1
      next
    }
    { print raw }
    END {
      if (!rewrote) { exit 2 }
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      die "story '$story_key' not found in $file"
    fi
    die "awk rewrite of '$file' failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Extract the status for $story_key from sprint-status.yaml. Stdout.
read_sprint_status_yaml_status() {
  local story_key="$1"
  local file="$SPRINT_STATUS_YAML"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  awk -v target="$story_key" '
    BEGIN { in_entry = 0; found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1 } else { in_entry = 0 }
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry && line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      found = 1
      exit
    }
    END {
      if (!found) { exit 2 }
    }
  ' "$file" || die "story '$story_key' not found in sprint-status.yaml"
}

# Check the Review Gate for the story. Returns 0 if all six canonical rows
# report PASSED; otherwise exits 1 with the non-PASSED rows listed.
check_review_gate_all_passed() {
  local story_key="$1"
  local review_gate_sh="${SPRINT_STATE_SCRIPT_DIR}/review-gate.sh"
  if [ ! -x "$review_gate_sh" ]; then
    die "review-gate.sh not found or not executable at $review_gate_sh (required for ' -> done' transitions)"
  fi
  # Call with an isolated PROJECT_PATH if review-gate.sh lays out story files
  # under .gaia/artifacts/implementation-artifacts/stories/ — our layout is flat, so we
  # instead call `check` directly and rely on its own locator. review-gate.sh
  # uses `${PROJECT_PATH}/.gaia/artifacts/implementation-artifacts/stories/<key>-*.md`;
  # fall back to a thin parser that reads the Review Gate table from the
  # story file we already resolved. This keeps this function independent of any
  # later refactor to review-gate.sh's layout assumptions.
  local missing
  missing=$(awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }
    { sub(/\r$/, "", $0) }
    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0; next }
      next
    }
    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 2) next
      gate = cells[1]; status = cells[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (status != "PASSED") {
        printf "%s=%s\n", gate, status
      }
    }
  ' "$STORY_FILE")

  if [ -n "$missing" ]; then
    {
      printf '%s: error: Review Gate not fully PASSED for story %s — transition to done rejected:\n' \
        "$SCRIPT_NAME" "$story_key"
      printf '%s\n' "$missing" | sed 's/^/  /'
    } >&2
    exit 1
  fi
}

# Emit one state_transition lifecycle event. Shells out to lifecycle-event.sh
# as a separate process per Technical Notes. If the script is missing or
# exits non-zero, we surface the failure (AC-EC4).
emit_lifecycle_event() {
  local story_key="$1" from="$2" to="$3"
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ ! -x "$lifecycle_sh" ]; then
    die "lifecycle-event.sh not found or not executable at $lifecycle_sh (required by AC3)"
  fi
  local data
  data=$(printf '{"from":"%s","to":"%s"}' "$from" "$to")
  if ! "$lifecycle_sh" \
        --type state_transition \
        --workflow sprint-state \
        --story "$story_key" \
        --data "$data"; then
    die "lifecycle-event.sh failed for $story_key ($from -> $to) — story file and sprint-status.yaml updates completed but event log write failed; run sprint-state.sh validate --story $story_key to check for drift"
  fi
}

# ---------- Subcommand: get ----------

cmd_get() {
  local story_key="$1"
  locate_story_file "$story_key"
  read_story_status "$STORY_FILE"
  printf '\n'
}

# ---------- Subcommand: validate ----------

cmd_validate() {
  local story_key="$1"
  locate_story_file "$story_key"
  local story_status yaml_status
  story_status=$(read_story_status "$STORY_FILE")
  yaml_status=$(read_sprint_status_yaml_status "$story_key")
  if [ "$story_status" != "$yaml_status" ]; then
    printf '%s: drift detected for %s: story file says %q, sprint-status.yaml says %q\n' \
      "$SCRIPT_NAME" "$story_key" "$story_status" "$yaml_status" >&2
    exit 1
  fi
  return 0
}

# ---------- Subcommand: transition ----------

# The core of the transition logic — runs inside the locked critical section.
do_transition_locked() {
  local story_key="$1" to_state="$2"

  # (a) Re-read sprint-status.yaml immediately before writing (Sprint-Status
  # Write Safety). If the file is missing/empty, fail before touching the
  # story file.
  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  # --- Closing-marker check ---
  # In concurrent mode, refuse story-level transitions while a sprint close
  # is in progress. The closing marker was written by the close writer in
  # Phase A while L4 was held.
  if _is_concurrent_mode; then
    local _trans_state_dir
    _trans_state_dir="$(dirname "$SPRINT_STATUS_YAML")"
    local _trans_sprint_id
    _trans_sprint_id="$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)"
    if [ -n "$_trans_sprint_id" ]; then
      local _trans_marker
      _trans_marker="$(_closing_marker_path "$_trans_state_dir" "$_trans_sprint_id")"
      if [ -f "$_trans_marker" ]; then
        die "sprint close in progress -- injection refused"
      fi
    fi
  fi

  # Locate the story file now that we hold the lock.
  locate_story_file "$story_key"

  # Read current status from the story file (source of truth).
  local from_state
  from_state=$(read_story_status "$STORY_FILE")

  # No-op guard: identical transitions are not legal adjacency edges and
  # would be caught below, but surface a clearer message.
  if [ "$from_state" = "$to_state" ]; then
    die "story $story_key is already in state '$to_state'"
  fi

  # Validate adjacency.
  validate_transition "$from_state" "$to_state"

  # Review Gate enforcement for -> done.
  if [ "$to_state" = "done" ]; then
    check_review_gate_all_passed "$story_key"

    # DoD completeness gate. Prior behavior allowed `review -> done` when the
    # Review Gate was all-PASSED even if the story's Definition of Done section
    # was 0/N checked. Block the transition when any DoD checkbox is unchecked.
    if [ -n "${STORY_FILE:-}" ] && [ -f "$STORY_FILE" ]; then
      _dod_unchecked=$(awk '
        BEGIN { in_section=0; unchecked=0 }
        /^## Definition of Done[[:space:]]*$/ { in_section=1; next }
        in_section && /^## / { in_section=0 }
        in_section && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]/ { unchecked++ }
        END { print unchecked }
      ' "$STORY_FILE")
      if [ -n "$_dod_unchecked" ] && [ "$_dod_unchecked" -gt 0 ]; then
        die "story $story_key: refuse review -> done — $_dod_unchecked DoD item(s) unchecked (run /gaia-check-dod and tick each box before transitioning to done)"
      fi

      # Dependency gate on done. Prior behavior: backlog-select-lint
      # enforced deps at sprint selection time, but the done transition
      # ignored deps entirely. Block done when any depends_on key is non-done.
      _fm_deps=$(awk '
        BEGIN { in_fm=0; in_deps=0 }
        /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
        !in_fm { next }
        /^depends_on:[[:space:]]*\[/ {
          line=$0; sub(/^depends_on:[[:space:]]*\[/, "", line); sub(/\].*$/, "", line)
          n=split(line, parts, ",")
          for (i=1;i<=n;i++) { gsub(/[[:space:]"]/, "", parts[i]); if (parts[i] ~ /^E[0-9]+-S[0-9]+$/) print parts[i] }
          next
        }
        /^depends_on:[[:space:]]*$/ { in_deps=1; next }
        in_deps && /^[[:space:]]*-[[:space:]]*[Ee][0-9]+-[Ss][0-9]+/ {
          t=$0; gsub(/[[:space:]"-]/, "", t); if (t ~ /^E[0-9]+-S[0-9]+$/) print t
        }
        in_deps && /^[^[:space:]-]/ { in_deps=0 }
      ' "$STORY_FILE")
      if [ -n "$_fm_deps" ]; then
        _unmet=""
        for _dep in $_fm_deps; do
          # Cross-sprint dep resolution. The dep status is consulted in three
          # sources in order — (1) live yaml, (2) the depended story's file
          # frontmatter, (3) the most-recent sprint-archive entry — and the
          # first non-empty answer wins. This handles predecessor stories from
          # closed sprints that have dropped out of the live yaml.
          # Try BOTH yaml shapes — init/inject seeds a top-level `.stories[]`
          # shape (no `.sprints[]` wrapper). Try the canonical top-level shape
          # first, then fall back to the legacy `.sprints[].stories[]` shape
          # for any vestigial multi-sprint roll-ups.
          _dep_status=$(yq -r "(.stories // .items // [])[] | select(.key == \"${_dep}\") | .status" "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml}" 2>/dev/null | head -1 || true)
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            _dep_status=$(yq -r ".sprints[].stories[] | select(.key == \"${_dep}\") | .status" "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml}" 2>/dev/null | head -1 || true)
          fi
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            # Tier 2: the depended story's file frontmatter (source of truth).
            # Try BOTH layouts (canonical first, legacy as fallback). The
            # canonical layout is `epic-*/{key}-*/story.md` (per-story
            # directory); legacy layout was `epic-*/stories/{key}-*.md`
            # (per-story file under stories/).
            for _dep_sf in "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}"/epic-*/"${_dep}-"*/story.md "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}"/epic-*/stories/"${_dep}-"*.md "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}"/epic-*/"${_dep}-"*.md; do
              if [ -f "$_dep_sf" ]; then
                _dep_status=$(awk '
                  BEGIN { in_fm=0 }
                  /^---[[:space:]]*$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
                  !in_fm { next }
                  /^status:[[:space:]]*/ { sub(/^status:[[:space:]]*/, ""); gsub(/[[:space:]"]/, ""); print; exit }
                ' "$_dep_sf")
                [ -n "$_dep_status" ] && break
              fi
            done
          fi
          if [ -z "$_dep_status" ] || [ "$_dep_status" = "null" ]; then
            # Tier 3: scan sprint-archive/. Pick the most-recent archive that
            # mentions the dep key. Archives are named sprint-N-closed-<ts>.yaml.
            for _archive in $(ls -1t "${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}"/sprint-archive/sprint-*-closed-*.yaml 2>/dev/null); do
              # Try both yaml shapes — sprint archives may be either top-level
              # `.stories[]` (canonical) or rolled-up `.sprints[].stories[]` (legacy).
              _arch_status=$(yq -r ".stories[]? | select(.key == \"${_dep}\") | .status" "$_archive" 2>/dev/null | head -1 || true)
              if [ -z "$_arch_status" ] || [ "$_arch_status" = "null" ]; then
                _arch_status=$(yq -r ".sprints[].stories[]? | select(.key == \"${_dep}\") | .status" "$_archive" 2>/dev/null | head -1 || true)
              fi
              if [ -n "$_arch_status" ] && [ "$_arch_status" != "null" ]; then
                _dep_status="$_arch_status"
                break
              fi
            done
          fi
          if [ "$_dep_status" != "done" ]; then
            _unmet="${_unmet} ${_dep}(${_dep_status:-unknown})"
          fi
        done
        if [ -n "$_unmet" ]; then
          die "story $story_key: refuse review -> done — unmet hard dependencies:${_unmet} (complete those stories first, or remove the depends_on entry if the dependency no longer applies)"
        fi
      fi
    fi
  fi

  # (b, c) Atomic updates: story file first (source of truth), then yaml.
  rewrite_story_status "$STORY_FILE" "$to_state"
  rewrite_sprint_status_yaml "$story_key" "$to_state"

  # (d) Emit exactly one lifecycle event. Any failure exits 1; file writes
  # are NOT rolled back — callers MUST treat a non-zero exit from transition
  # as "run validate and fix drift". "event failure surfaced with exit 1" is
  # an explicitly permitted outcome.
  emit_lifecycle_event "$story_key" "$from_state" "$to_state"

  printf '%s: %s transitioned %s -> %s\n' "$SCRIPT_NAME" "$story_key" "$from_state" "$to_state"
}

cmd_transition() {
  local story_key="$1" to_state="$2"

  # Fail-fast: refuse any --to value that is not in the canonical lifecycle
  # enum. The rejection happens BEFORE the flock and BEFORE any tempfile is
  # created, so sprint-status.yaml and the story file are guaranteed
  # byte-identical on a non-canonical input. The error names both the
  # offending value and the allowed enum so the caller can correct the
  # invocation without reading source.
  assert_canonical_state "$to_state" "transition --to"

  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" 5 9; then
      die "lock timeout acquiring $SPRINT_STATUS_LOCK"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    do_transition_locked "$story_key" "$to_state"
  )
}

# ---------- Subcommand: inject ----------
#
# Append a backlog story's metadata to the active sprint's sprint-status.yaml
# entry list. Until this subcommand landed, /gaia-correct-course
# story-injection had no canonical write path and operators had to hand-edit
# sprint-status.yaml (a hard-rule violation).
#
# Contract (mirrors cmd_transition's invariants):
#   * Acquires the same flock used by cmd_transition (no new lock primitive).
#   * Story file frontmatter is the source of truth — yaml is the cache.
#   * Validates four required frontmatter fields BEFORE the lock.
#   * Idempotent: re-running on an already-injected key is a no-op.
#   * Drift guard: refuses if frontmatter.sprint_id != yaml.sprint_id.
#   * Bumps total_points and recomputes capacity_utilization.
#   * Emits exactly one story_injected lifecycle event on success.
#
# Exit codes:
#   0 — success OR no-op (idempotent re-run)
#   1 — usage error, missing required field, sprint-id drift, lock failure,
#       yaml parse failure, lifecycle event write failure

# Read a single scalar frontmatter field from a story file. Stdout = value
# (quotes stripped). Exit 1 if the field is missing.
read_story_frontmatter_field() {
  local file="$1" field="$2"
  awk -v target="$field" '
    BEGIN { in_fm = 0; seen = 0; found = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm {
      line = $0
      sub(/\r$/, "", line)
      pat = "^" target ":[[:space:]]*"
      if (line ~ pat) {
        v = line
        sub(pat, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Read the top-level sprint_id field from sprint-status.yaml. Stdout = value.
# Exit 1 if absent.
read_yaml_sprint_id() {
  local file="$1"
  awk '
    BEGIN { found = 0 }
    /^sprint_id:[[:space:]]*/ {
      v = $0
      sub(/^sprint_id:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# _assert_sprint_id_matches — guard that the caller's sprint id matches the
# yaml's sprint_id field. Dies with a descriptive message when the yaml has no
# sprint_id or when the ids disagree. Uses the shared phrase "does not match
# active sprint-status.yaml sprint_id" for pattern-anchored callers.
_assert_sprint_id_matches() {
  local verb="$1" flag_label="$2" caller_sid="$3" yaml="$4"
  local exit_code="${5:-1}"
  local yaml_sid
  yaml_sid=$(read_yaml_sprint_id "$yaml" 2>/dev/null || true)
  if [ -z "$yaml_sid" ]; then
    printf '%s: error: %s: sprint-status.yaml has no sprint_id field\n' \
      "$SCRIPT_NAME" "$verb" >&2
    exit "$exit_code"
  fi
  if [ "$yaml_sid" != "$caller_sid" ]; then
    printf '%s: error: %s: %s '\''%s'\'' does not match active sprint-status.yaml sprint_id '\''%s'\''\n' \
      "$SCRIPT_NAME" "$verb" "$flag_label" "$caller_sid" "$yaml_sid" >&2
    exit "$exit_code"
  fi
}

# Read top-level scalar field <name> from sprint-status.yaml. Stdout = value.
# Exit 1 if absent.
read_yaml_scalar_field() {
  local file="$1" field="$2"
  awk -v target="$field" '
    BEGIN { found = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      pat = "^" target ":[[:space:]]*"
      if (line ~ pat) {
        v = line
        sub(pat, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Check whether a story key already appears in sprint-status.yaml's stories[]
# block. Returns 0 if present, 1 otherwise. No stdout.
yaml_has_story_key() {
  local file="$1" target="$2"
  awk -v target="$target" '
    BEGIN { found = 0 }
    /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = $0
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Validate an execution-phase value. A phase is a 1-based partition index
# over ONE sprint's candidate set, so it is a small positive integer.
# Fail-closed: non-digit, empty, zero, negative, leading-zero and
# out-of-range forms are all rejected with a diagnostic naming the flag
# and the offending value. Leading zeros are refused because `phase: 07`
# round-trips as the literal string "07", which would break the
# unquoted-integer serialisation guarantee and byte-stability.
#
# The LENGTH check must precede the numeric comparison and is not
# redundant with it: `[ "$value" -gt "$max" ]` cannot parse a literal
# wider than a machine integer, and the shell's reaction to that is to
# emit its own diagnostic and evaluate the condition as FALSE. Because
# that happens inside an `if` condition, `set -e` does not fire either —
# so an over-wide value would fall straight through to ACCEPTED with raw
# shell noise on stderr. Comparing digit counts first keeps every
# comparison inside the representable range, and keeps the diagnostic
# identical across shells.
_GAIA_PHASE_MAX=999
_validate_phase_value() {
  local ctx="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "${ctx}: --phase must be a positive integer, got: '${value}'" ;;
  esac
  case "$value" in
    0*) die "${ctx}: --phase must not have a leading zero, got: '${value}'" ;;
  esac
  if [ "${#value}" -gt "${#_GAIA_PHASE_MAX}" ]; then
    die "${ctx}: --phase must be between 1 and ${_GAIA_PHASE_MAX}, got: '${value}'"
  fi
  if [ "$value" -gt "$_GAIA_PHASE_MAX" ]; then
    die "${ctx}: --phase must be between 1 and ${_GAIA_PHASE_MAX}, got: '${value}'"
  fi
}

# Remove a story entry from sprint-status.yaml's stories: block by key.
# Updates total_points accordingly. Tempfile + atomic mv. Idempotent:
# removing a key that does not exist is a no-op.
_remove_story_from_yaml() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0

  # Check if the key is actually present.
  if ! /usr/bin/grep -q "key:[[:space:]]*[\"']\\{0,1\\}${key}[\"']\\{0,1\\}" "$file" 2>/dev/null; then
    return 0  # Idempotent: key not present.
  fi

  # Read the story's points to adjust total_points.
  local pts=0
  pts="$(GAIA_KEY="$key" yq -r \
    '(.stories // [])[] | select(.key == strenv(GAIA_KEY)) | .points // 0' \
    "$file" 2>/dev/null)" || pts=0
  case "$pts" in ''|*[!0-9]*) pts=0 ;; esac

  # Remove the story entry and adjust total_points via yq + mktemp + mv.
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1

  if ! GAIA_KEY="$key" yq \
    'del((.stories // [])[] | select(.key == strenv(GAIA_KEY)))' \
    "$file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # Adjust total_points.
  if [ "$pts" -gt 0 ] 2>/dev/null; then
    local cur_total new_total
    cur_total="$(yq -r '.total_points // 0' "$tmp" 2>/dev/null)" || cur_total=0
    case "$cur_total" in ''|*[!0-9]*) cur_total=0 ;; esac
    new_total=$((cur_total - pts))
    [ "$new_total" -ge 0 ] || new_total=0
    GAIA_VAL="$new_total" yq -i '.total_points = (strenv(GAIA_VAL) | tonumber)' "$tmp" 2>/dev/null || true
  fi

  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# Append a story entry to sprint-status.yaml's stories: block. Updates
# total_points by $points_delta and recomputes capacity_utilization using
# velocity_capacity (when present). Tempfile + atomic mv. Exit 1 on failure.
append_story_to_yaml() {
  local file="$1" key="$2" title="$3" status="$4" points="$5" risk="$6" phase="${7:-}"
  local today
  today=$(date -u +%Y-%m-%d)

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  # Read current scalars to compute new totals.
  local cur_total cur_velocity new_total new_capacity_pct
  cur_total=$(read_yaml_scalar_field "$file" total_points 2>/dev/null || printf '0')
  cur_velocity=$(read_yaml_scalar_field "$file" velocity_capacity 2>/dev/null || printf '')

  # Validate numeric inputs — guard non-numeric strings.
  case "$cur_total" in
    ''|*[!0-9]*) cur_total=0 ;;
  esac
  case "$points" in
    ''|*[!0-9]*) die "inject: story 'points' must be a non-negative integer, got: '$points'" ;;
  esac
  # Defense-in-depth: cmd_inject validates before taking the lock, but this
  # emitter is the chokepoint every write path flows through, so guarding
  # here closes internal callers too.
  if [ -n "$phase" ]; then
    _validate_phase_value "inject" "$phase"
  fi
  new_total=$((cur_total + points))

  if [ -n "$cur_velocity" ] && printf '%s' "$cur_velocity" | grep -Eq '^[0-9]+$' && [ "$cur_velocity" -gt 0 ]; then
    # Round half-up: (a*100 + v/2) / v.
    new_capacity_pct=$(( (new_total * 100 + cur_velocity / 2) / cur_velocity ))
  else
    new_capacity_pct=""
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # issue-1403: pre-escape the free-text title into a complete single-quoted
  # YAML scalar so the awk emitter can embed it verbatim without a raw " or '
  # corrupting the file.
  local title_yaml
  title_yaml="$(yaml_single_quote "$title")"

  awk -v key="$key" -v title="$title_yaml" -v status="$status" -v points="$points" \
      -v risk="$risk" -v today="$today" -v new_total="$new_total" \
      -v new_capacity_pct="$new_capacity_pct" -v phase="$phase" '
    # issue-1403: `title` arrives PRE-ESCAPED as a complete single-quoted YAML
    # scalar (inner single-quotes already doubled by the shell, see the
    # `title_yaml` computation in the caller). Embedding it verbatim keeps any
    # double-quote or apostrophe in the title from breaking the YAML, so the
    # file stays parseable by yq (the /gaia-sprint-close blocker).
    function emit_entry() {
      printf "  - key: \"%s\"\n", key
      printf "    title: %s\n", title
      printf "    status: \"%s\"\n", status
      printf "    points: %s\n", points
      printf "    risk_level: \"%s\"\n", risk
      printf "    assignee: null\n"
      printf "    blocked_by: null\n"
      printf "    updated: \"%s\"\n", today
      # Optional execution phase, emitted LAST and ONLY when set — a
      # phase-less sprint must stay byte-identical to the pre-phase output,
      # so there is deliberately no `phase: null` branch. Unquoted integer,
      # matching the `points` field above.
      if (phase != "") { printf "    phase: %s\n", phase }
    }
    BEGIN { in_stories = 0; appended = 0; saw_stories_key = 0 }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # Top-level total_points: rewrite.
    !in_stories && line ~ /^total_points:[[:space:]]*/ {
      printf "total_points: %s\n", new_total
      next
    }
    # Top-level capacity_utilization: rewrite (only when we computed one).
    !in_stories && line ~ /^capacity_utilization:[[:space:]]*/ {
      if (new_capacity_pct != "") {
        printf "capacity_utilization: \"%s%%\"\n", new_capacity_pct
        next
      }
      print raw
      next
    }
    # Detect empty stories: [] marker — convert to a populated list.
    line ~ /^stories:[[:space:]]*\[\][[:space:]]*$/ {
      print "stories:"
      emit_entry()
      appended = 1
      saw_stories_key = 1
      next
    }
    # Detect entering the stories: block.
    line ~ /^stories:[[:space:]]*$/ {
      in_stories = 1
      saw_stories_key = 1
      print raw
      next
    }
    # Inside stories — append our entry just before the first top-level
    # non-indented key that closes the block.
    in_stories && line ~ /^[^[:space:]-]/ {
      if (!appended) { emit_entry(); appended = 1 }
      in_stories = 0
      print raw
      next
    }
    { print raw }
    END {
      # stories: block ran to EOF — append at the bottom.
      if (saw_stories_key && !appended) { emit_entry(); appended = 1 }
      # No stories: block at all — emit one with our entry.
      if (!saw_stories_key) {
        printf "stories:\n"
        emit_entry()
        appended = 1
      }
      if (!appended) exit 2
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    die "awk rewrite of '$file' failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

# Emit a story_injected lifecycle event. Failure surfaces as exit 1.
emit_inject_event() {
  local story_key="$1" total_points="$2"
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ ! -x "$lifecycle_sh" ]; then
    die "lifecycle-event.sh not found or not executable at $lifecycle_sh (required for inject lifecycle event)"
  fi
  local data
  data=$(printf '{"key":"%s","source":"sprint-state.sh inject","total_points":%s}' \
    "$story_key" "$total_points")
  if ! "$lifecycle_sh" \
        --type story_injected \
        --workflow sprint-state \
        --story "$story_key" \
        --data "$data"; then
    die "lifecycle-event.sh failed for $story_key inject — sprint-status.yaml updated but event log write failed; run sprint-state.sh validate --story $story_key to check for drift"
  fi
}

# Inject locked critical section. Mirrors do_transition_locked structure.
do_inject_locked() {
  local story_key="$1" phase="${2:-}"

  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  # Idempotency check (under lock so concurrent injects of the same key
  # serialize correctly — second one sees the first one's append).
  if yaml_has_story_key "$SPRINT_STATUS_YAML" "$story_key"; then
    printf '%s: %s already injected — no-op\n' "$SCRIPT_NAME" "$story_key"
    return 0
  fi

  # --- Closing-marker check (runs before independence gate) ---
  # In concurrent mode, refuse injection while a sprint close is in progress.
  # The closing marker was written by the close writer in Phase A while L4
  # was held; we check it here under L1 to prevent TOCTOU injection.
  if _is_concurrent_mode; then
    local _inject_state_dir
    _inject_state_dir="$(dirname "$SPRINT_STATUS_YAML")"
    local _inject_sprint_id
    _inject_sprint_id="$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)"
    if [ -n "$_inject_sprint_id" ]; then
      local _inject_marker
      _inject_marker="$(_closing_marker_path "$_inject_state_dir" "$_inject_sprint_id")"
      if [ -f "$_inject_marker" ]; then
        die "sprint close in progress -- injection refused"
      fi
    fi
  fi

  # --- Independence re-check gate ---
  # In concurrent mode, verify the story does not violate independence
  # rules before writing it into the sprint. The gate only reads (no lock
  # acquisition), so no lock nesting occurs.
  # Suppressed during rollover Phase B: the rollover's Phase A already ran
  # the independence check for the carried-over keys specifically.
  if _is_concurrent_mode && [ "${_GAIA_ROLLOVER_INJECT:-0}" != "1" ]; then
    # Locate the story file using the same glob patterns as locate_story_file
    # but without calling die on failure. Runs in a subshell to avoid
    # clobbering STORY_FILE in the outer scope.
    # Locate the story file. The glob + filter runs in a subshell; the
    # legacy-path skip uses string ops instead of case to stay bash 3.2
    # safe (case patterns with ) inside $() break the 3.2 parser).
    local _gate_story_file=""
    _gate_story_file="$(
      shopt -s nullglob
      local _matches=()
      _matches=( "${IMPLEMENTATION_ARTIFACTS}/${story_key}-"*.md \
                 "${IMPLEMENTATION_ARTIFACTS}"/epic-*/"${story_key}-"*/story.md )
      shopt -u nullglob
      local _f
      for _f in ${_matches[@]+"${_matches[@]}"}; do
        # Skip legacy stories/ paths — bash 3.2 safe string test.
        if [ "${_f%/stories/*/story.md}" != "$_f" ]; then continue; fi
        if awk 'NR==1 && /^---/ { in_fm=1; next } in_fm && /template:/ && /story/ { found=1; exit } in_fm && /^---/ { exit } END { exit (found ? 0 : 1) }' "$_f" 2>/dev/null; then
          printf '%s' "$_f"; break
        fi
      done
    )" || true
    if [ -z "$_gate_story_file" ] || [ ! -f "$_gate_story_file" ]; then
      die "inject: independence re-check refused — story file for $story_key not found (fail-closed in concurrent mode)"
    fi
    # Refuse injection when predicted_touch_set is absent (R33: fail closed).
    if ! /usr/bin/grep -q 'predicted_touch_set:' "$_gate_story_file" 2>/dev/null; then
      die "inject: independence re-check refused — $story_key has no predicted_touch_set (fail-closed in concurrent mode; add the field before injection)"
    fi
    local _gate_script="${SPRINT_STATE_SCRIPT_DIR}/independence-gate.sh"
    if [ ! -x "$_gate_script" ]; then
      die "inject: independence re-check refused — gate script not found: ${_gate_script} (fail-closed in concurrent mode)"
    fi
    local _gate_sprint_id=""
    _gate_sprint_id="$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null)" || true
    if [ -z "$_gate_sprint_id" ]; then
      die "inject: independence re-check refused — sprint_id unresolvable (fail-closed in concurrent mode)"
    fi
    local _gate_rc=0
    bash "$_gate_script" "$_gate_story_file" \
      --candidate "$_gate_sprint_id" 2>&1 || _gate_rc=$?
    if [ "$_gate_rc" -ne 0 ]; then
      die "inject: independence re-check failed for $story_key — mutation blocked"
    fi
  fi

  # Re-locate story file under lock.
  locate_story_file "$story_key"

  # Validate four required frontmatter fields. Collect every missing field
  # for a single error message (AC4).
  local missing=""
  local fm_sprint_id fm_status fm_points fm_risk fm_title
  fm_sprint_id=$(read_story_frontmatter_field "$STORY_FILE" sprint_id 2>/dev/null || true)
  fm_status=$(read_story_frontmatter_field "$STORY_FILE" status 2>/dev/null || true)
  fm_points=$(read_story_frontmatter_field "$STORY_FILE" points 2>/dev/null || true)
  fm_risk=$(read_story_frontmatter_field "$STORY_FILE" risk 2>/dev/null || true)
  fm_title=$(read_story_frontmatter_field "$STORY_FILE" title 2>/dev/null || true)

  [ -n "$fm_sprint_id" ] || missing="${missing} sprint_id"
  [ -n "$fm_status" ]    || missing="${missing} status"
  [ -n "$fm_points" ]    || missing="${missing} points"
  [ -n "$fm_risk" ]      || missing="${missing} risk"

  if [ -n "$missing" ]; then
    die "inject: story file '$STORY_FILE' is missing required frontmatter field(s):${missing}"
  fi

  # Defense-in-depth: status from frontmatter must be canonical.
  assert_canonical_state "$fm_status" "inject story status"

  # Drift guard: frontmatter sprint_id MUST match yaml sprint_id.
  local yaml_sprint_id
  yaml_sprint_id=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML") \
    || die "inject: sprint-status.yaml at $SPRINT_STATUS_YAML missing top-level sprint_id"

  # During rollover Phase B the story file still carries the source sprint's
  # id (the rewrite happens in Phase C after inject succeeds). Skip the
  # mismatch check when the rollover suppression flag is set.
  if [ "${_GAIA_ROLLOVER_INJECT:-0}" != "1" ] && [ "$fm_sprint_id" != "$yaml_sprint_id" ]; then
    die "inject: sprint-id mismatch — story file frontmatter sprint_id='$fm_sprint_id' but sprint-status.yaml sprint_id='$yaml_sprint_id'; refusing to write"
  fi

  # Title is optional for the validation step but required for a useful yaml
  # entry — fall back to the story key when frontmatter omits it.
  if [ -z "$fm_title" ]; then
    fm_title="$story_key"
  fi

  # Append to yaml (also rewrites total_points and capacity_utilization).
  append_story_to_yaml "$SPRINT_STATUS_YAML" "$story_key" "$fm_title" "$fm_status" "$fm_points" "$fm_risk" "$phase"

  # Re-read total_points for the lifecycle event payload.
  local new_total
  new_total=$(read_yaml_scalar_field "$SPRINT_STATUS_YAML" total_points 2>/dev/null || printf '0')

  emit_inject_event "$story_key" "$new_total"

  printf '%s: %s injected into sprint %s — total_points=%s\n' \
    "$SCRIPT_NAME" "$story_key" "$yaml_sprint_id" "$new_total"
}

cmd_inject() {
  local story_key="$1" sprint_id_override="${2:-}" phase="${3:-}"
  # Fail fast BEFORE taking the lock, mirroring cmd_transition's posture.
  # An empty phase means "not supplied" at THIS layer: the rollover path
  # re-injects with no phase, so an empty value must stay legal here. The
  # dispatch arm is what distinguishes an omitted flag from an explicitly
  # empty one and rejects the latter, using the same validator.
  if [ -n "$phase" ]; then
    _validate_phase_value "inject" "$phase"
  fi
  # sprint_id_override is checked via the shared helper when the yaml has a
  # sprint_id field. When the yaml lacks a sprint_id (e.g. a fresh seed that
  # has not been initialised yet), the check is skipped and inject proceeds —
  # this preserves the tolerant behaviour for legacy and test fixtures.
  if [ -n "$sprint_id_override" ]; then
    local yaml_sid
    yaml_sid=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)
    if [ -n "$yaml_sid" ]; then
      _assert_sprint_id_matches "inject" "--sprint-id" "$sprint_id_override" "$SPRINT_STATUS_YAML"
    fi
  fi

  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" 5 9; then
      die "lock timeout acquiring $SPRINT_STATUS_LOCK"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    do_inject_locked "$story_key" "$phase"
  )
}

# ---------- Subcommand: reconcile ----------

# Locate a story file for reconcile.
#
# Filter the {key}-*.md glob to canonical story files (those whose YAML
# frontmatter declares `template: 'story'`). This eliminates the prior
# behaviour where co-located review / qa-tests / security / performance
# reports could be picked up as the "story" file and trigger spurious
# parse errors during reconcile.
#
# For each glob candidate that is rejected (missing or non-'story' template),
# emit a structured warning to stderr that names the candidate file:
#
#   RECONCILE: {key} candidate {file} skipped — no `template: 'story'` frontmatter
#
# Skips are observable, not silent.
#
# Case-insensitive glob via nocaseglob so {slug}-story.md fixtures match
# upper-cased keys on Linux. Returns the first canonical match via stdout.
# Returns non-zero (return 1) if no canonical story file is found — caller
# handles the missing-file error.
reconcile_locate_story_file() {
  local key="$1"
  local matches=()
  shopt -s nullglob nocaseglob
  # Tiers globbed: flat, legacy-nested, and the per-story layout
  # epic-{slug}/{key}-{slug}/story.md (basename story.md).
  # shellcheck disable=SC2206
  matches=( "${IMPLEMENTATION_ARTIFACTS}/${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/stories/"${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/"${key}-"*/story.md )
  shopt -u nullglob nocaseglob

  if [ "${#matches[@]}" -eq 0 ]; then
    return 1
  fi

  local m
  for m in "${matches[@]}"; do
    # Exclude per-story evidence dirs that live under a legacy `stories/`
    # segment — those belong to the tier-1 layer, not the new tier-0 layout.
    case "$m" in
      */stories/*/story.md) continue ;;
    esac
    if _is_story_file "$m"; then
      printf '%s' "$m"
      return 0
    fi
    # Per-candidate structured warning naming the skipped file (Val WARNING #1).
    printf "RECONCILE: %s candidate %s skipped — no \`template: 'story'\` frontmatter\n" \
      "$key" "$m" >&2
  done

  return 1
}

# Read story-file frontmatter status; prints to stdout. Reuses the stricter
# read_story_status() when the file has a canonical frontmatter block; falls
# back to exit 2 (via awk END) when the field is missing or the frontmatter
# is unparseable. Return codes: 0 = ok, 2 = parse error / missing status.
reconcile_read_story_status() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0; found = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^[[:space:]]*status:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      # Reject malformed values containing colons (e.g. "status: : : malformed").
      if (v ~ /:/) { exit 2 }
      print v
      found = 1
      exit
    }
    END { if (!found) exit 2 }
  ' "$file"
}

# Read all (key, status) pairs from sprint-status.yaml for the active sprint.
# Emits `<key>\t<status>` lines to stdout. Uses pure awk — no yq dependency.
# If the yaml is absent or unreadable, returns 1 so callers can HALT.
reconcile_list_yaml_stories() {
  local file="$1"
  if [ ! -r "$file" ]; then
    return 1
  fi
  awk '
    BEGIN { in_stories = 0; key = ""; status = "" }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^stories:[[:space:]]*$/ { in_stories = 1; saw_stories = 1; next }
    line ~ /^items:[[:space:]]*$/ && !saw_stories { in_stories = 1; next }
    # Stories section ends at an empty list marker or a new top-level key.
    line ~ /^stories:[[:space:]]*\[\][[:space:]]*$/ { in_stories = 0; saw_stories = 1; next }
    line ~ /^items:[[:space:]]*\[\][[:space:]]*$/ { next }
    in_stories && line ~ /^[^[:space:]-]/ { in_stories = 0; next }
    !in_stories { next }
    # A new entry starts with "  - key: ...".
    line ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      # Flush any previous entry.
      if (key != "") { printf "%s\t%s\n", key, status; }
      key = line
      sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", key)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", key)
      status = ""
      next
    }
    # Subsequent lines of the same entry.
    line ~ /^[[:space:]]+status:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      status = v
      next
    }
    END {
      if (key != "") { printf "%s\t%s\n", key, status; }
    }
  ' "$file"
}

# Allowlisted yaml writer — the single chokepoint for every reconcile write.
# Story files are OFF-LIMITS; this helper only accepts SPRINT_STATUS_YAML as
# the target. Runs the inner rewrite in a subshell so that die() inside
# rewrite_sprint_status_yaml (e.g., on read-only yaml) is caught as a
# non-zero return code instead of killing the whole reconcile.
write_sprint_status_yaml() {
  local target="$1" story_key="$2" new_status="$3"
  # Allowlist check — write boundary.
  case "$target" in
    "$SPRINT_STATUS_YAML") ;;
    *)
      printf '%s: error: write_sprint_status_yaml refused non-allowlisted path: %s\n' \
        "$SCRIPT_NAME" "$target" >&2
      return 1
      ;;
  esac
  # Pre-check writability to catch read-only / full-disk before awk rewrite.
  if [ ! -w "$target" ]; then
    printf '%s: error: sprint-status.yaml is not writable: %s\n' \
      "$SCRIPT_NAME" "$target" >&2
    return 1
  fi
  ( rewrite_sprint_status_yaml "$story_key" "$new_status" ) || return 1
}

# Core reconcile algorithm — runs inside the lock critical section.
# Sets RECONCILE_CHECKED, RECONCILE_DIVERGENCES, RECONCILE_ERRORS globals.
RECONCILE_CHECKED=0
RECONCILE_DIVERGENCES=0
RECONCILE_ERRORS=0
do_reconcile_locked() {
  local dry_run="$1"
  local yaml="$SPRINT_STATUS_YAML"

  if [ ! -r "$yaml" ]; then
    printf '%s: error: sprint-status.yaml not readable: %s\n' "$SCRIPT_NAME" "$yaml" >&2
    RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
    return
  fi

  local pairs
  pairs="$(reconcile_list_yaml_stories "$yaml")" || {
    printf '%s: error: could not parse %s\n' "$SCRIPT_NAME" "$yaml" >&2
    RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
    return
  }

  # No stories → fast path (AC-EC1).
  if [ -z "$pairs" ]; then
    return
  fi

  local key yaml_status story_file story_status tag
  while IFS=$'\t' read -r key yaml_status; do
    [ -n "$key" ] || continue
    RECONCILE_CHECKED=$((RECONCILE_CHECKED + 1))

    story_file="$(reconcile_locate_story_file "$key")" || {
      printf 'RECONCILE: %s missing story file — skipped\n' "$key"
      printf '%s: error: story file not found for %s under %s\n' \
        "$SCRIPT_NAME" "$key" "$IMPLEMENTATION_ARTIFACTS" >&2
      RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
      continue
    }

    story_status="$(reconcile_read_story_status "$story_file")" || {
      printf 'RECONCILE: %s parse error — skipped (%s)\n' "$key" "$story_file"
      printf '%s: error: malformed frontmatter in %s (key=%s)\n' \
        "$SCRIPT_NAME" "$story_file" "$key" >&2
      RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
      continue
    }

    if [ "$story_status" = "$yaml_status" ]; then
      continue
    fi

    RECONCILE_DIVERGENCES=$((RECONCILE_DIVERGENCES + 1))
    if [ "$dry_run" = "1" ]; then
      tag="DRY-RUN"
      printf 'RECONCILE: %s %s -> %s [%s]\n' "$key" "$yaml_status" "$story_status" "$tag"
    else
      tag="UPDATED"
      if ! write_sprint_status_yaml "$SPRINT_STATUS_YAML" "$key" "$story_status" 2>/tmp/.reconcile-werr.$$; then
        local werr=""
        werr="$(cat /tmp/.reconcile-werr.$$ 2>/dev/null || true)"
        rm -f /tmp/.reconcile-werr.$$ 2>/dev/null || true
        printf 'RECONCILE: %s %s -> %s [WRITE-FAILED]\n' "$key" "$yaml_status" "$story_status"
        printf '%s: error: write failed for %s: %s\n' "$SCRIPT_NAME" "$SPRINT_STATUS_YAML" "$werr" >&2
        RECONCILE_ERRORS=$((RECONCILE_ERRORS + 1))
        continue
      fi
      rm -f /tmp/.reconcile-werr.$$ 2>/dev/null || true
      printf 'RECONCILE: %s %s -> %s [%s]\n' "$key" "$yaml_status" "$story_status" "$tag"
    fi
  done <<EOF
$pairs
EOF
}

cmd_reconcile() {
  local dry_run="$1"

  # Guard: when there is no GAIA project (no sprint-status.yaml), skip the
  # mkdir and emit the summary line only.  Running reconcile in an arbitrary
  # non-project directory must not create any files on disk.
  if [ ! -f "$SPRINT_STATUS_YAML" ]; then
    printf '%s: error: sprint-status.yaml not readable: %s\n' "$SCRIPT_NAME" "$SPRINT_STATUS_YAML" >&2
    printf 'RECONCILE SUMMARY: 0 stories checked, 0 divergences CORRECTED\n'
    return 1
  fi

  mkdir -p "$(dirname "$SPRINT_STATUS_LOCK")" 2>/dev/null || true

  # Counters persisted across the subshell via a side-channel file.
  # The subshell writes counters on successful run; the outer shell reads
  # them back tolerantly (a missing or partial file yields zero counters
  # rather than a `set -e` abort). The `|| true` on `read` is load-bearing:
  # printf without a trailing newline makes `read` return non-zero at EOF,
  # which under `set -e` would kill the whole reconcile on Linux/bash 5.
  set +e
  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" 5 9; then
      exit 1
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    do_reconcile_locked "$dry_run"
    printf '%s %s %s\n' "$RECONCILE_CHECKED" "$RECONCILE_DIVERGENCES" "$RECONCILE_ERRORS" \
      > "${SPRINT_STATUS_LOCK}.result"
  )
  local sub_rc=$?
  set -e
  if [ "$sub_rc" -ne 0 ] && [ ! -f "${SPRINT_STATUS_LOCK}.result" ]; then
    die "reconcile failed inside the locked critical section (rc=$sub_rc)"
  fi
  if [ -f "${SPRINT_STATUS_LOCK}.result" ]; then
    # shellcheck disable=SC2034
    read -r RECONCILE_CHECKED RECONCILE_DIVERGENCES RECONCILE_ERRORS \
      < "${SPRINT_STATUS_LOCK}.result" || true
    rm -f "${SPRINT_STATUS_LOCK}.result"
  fi

  # Summary line.
  local verb="CORRECTED"
  if [ "$dry_run" = "1" ]; then
    verb="DETECTED"
  fi
  if [ "$RECONCILE_DIVERGENCES" -eq 0 ] && [ "$RECONCILE_ERRORS" -eq 0 ]; then
    printf 'RECONCILE SUMMARY: %s stories checked, 0 divergences — no drift\n' "$RECONCILE_CHECKED"
  else
    printf 'RECONCILE SUMMARY: %s stories checked, %s divergences %s\n' \
      "$RECONCILE_CHECKED" "$RECONCILE_DIVERGENCES" "$verb"
  fi

  # Exit-code contract:
  #   1 = any error (missing file, parse failure, write failure)
  #   2 = dry-run drift detected but nothing written
  #   0 = no drift, or drift corrected successfully
  if [ "$RECONCILE_ERRORS" -gt 0 ]; then
    exit 1
  fi
  if [ "$dry_run" = "1" ] && [ "$RECONCILE_DIVERGENCES" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

# ---------- Subcommand: lint-dependencies ----------
#
# Read-only analysis of the selected sprint's story dependency graph.
# Detects forward-references (dependency inversions) where a story depends
# on a resource created by a later story in the sprint order.
#
# The AC text regex uses an 80-char co-occurrence window for trigger verb +
# target resource name matching. This bounds false positives from long-range
# coincidental matches while still catching same-sentence references.
#
# Read-only guarantee: lint-dependencies MUST NOT write to any file.
# It reads story files and sprint-status.yaml only. Safe for parallel CI
# pipelines and subagent invocation.
#
# Exit codes: 0 = clean, 2 = inversions detected (advisory), 1 = error.

# Extract the depends_on list from a story file's YAML frontmatter.
# Outputs one dependency key per line. Returns empty for missing or empty
# depends_on. Does not error on missing field.
lint_read_depends_on() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^depends_on:/ {
      line = $0
      sub(/^depends_on:[[:space:]]*/, "", line)
      # Remove brackets
      gsub(/[\[\]]/, "", line)
      # Split on comma
      n = split(line, items, /,/)
      for (i = 1; i <= n; i++) {
        v = items[i]
        # Strip quotes and whitespace
        gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", v)
        if (v != "") print v
      }
      exit
    }
  ' "$file"
}

# Scan AC text in a story file for heuristic dependency references.
# Looks for trigger verbs (uses|consumes|reads from) co-occurring with
# a sprint story key within an 80-char window. Outputs pipe-delimited
# records: target_key|match_text
#
# Parameters:
#   $1 — story file path
#   $2 — space-separated list of sprint story keys to check against
#
# Returns empty if no heuristic matches found. Does not match bare key
# mentions without a trigger verb.
lint_scan_ac_text() {
  local file="$1"
  local sprint_keys="$2"

  # Build a pipe-delimited alternation of sprint story keys for awk.
  local key_pattern=""
  local k
  for k in $sprint_keys; do
    key_pattern="${key_pattern:+${key_pattern}|}${k}"
  done
  [ -n "$key_pattern" ] || return 0

  # Scan AC section for trigger verbs co-occurring with a sprint story key
  # inside an 80-char window. The window size bounds false positives from
  # long-range coincidental matches.
  awk -v keys="$key_pattern" '
    BEGIN { in_ac = 0 }
    /^## Acceptance Criteria/ { in_ac = 1; next }
    /^## / && in_ac { exit }
    !in_ac { next }
    {
      line = $0
      # Use match() to find trigger verbs; iterate via substring slicing.
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (match(rest, /(uses|consumes|reads from)/)) {
          start = pos + RSTART - 1
          window = substr(line, start, 80)
          nk = split(keys, karr, /\|/)
          for (j = 1; j <= nk; j++) {
            if (index(window, karr[j]) > 0) {
              snippet = substr(line, start, 60)
              gsub(/["\\\n\r\t]/, " ", snippet)
              printf "%s|%s\n", karr[j], snippet
            }
          }
          pos = start + RLENGTH
        } else {
          break
        }
      }
    }
  ' "$file"
}

# Build an order map from sprint-status.yaml: outputs key\tindex lines
# where index is the 0-based position in the sprint story order.
lint_build_order_map() {
  reconcile_list_yaml_stories "$SPRINT_STATUS_YAML" | awk -F'\t' '
    { printf "%s\t%d\n", $1, NR-1 }
  '
}

# Look up a story key's 0-based sprint order index from the order map.
# Outputs the index if found, empty if the key is not in the sprint.
# Parameters:
#   $1 — order_map (key\tindex lines)
#   $2 — story key to look up
lint_lookup_order() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'
}

# Emit a single inversion record. Centralises the forward-ref vs external
# classification so both the explicit and heuristic paths share the logic.
# Parameters:
#   $1 — story_key (dependent)
#   $2 — dep_key (dependency)
#   $3 — source (depends_on | ac_text_scan)
#   $4 — story_idx (dependent's sprint position)
#   $5 — order_map
#   $6 — match_text (optional, for heuristic hits)
_lint_emit_if_inversion() {
  local story_key="$1" dep_key="$2" source="$3"
  local story_idx="$4" order_map="$5" match_text="${6:-}"
  local dep_idx confidence

  dep_idx="$(lint_lookup_order "$order_map" "$dep_key")"
  if [ -z "$dep_idx" ]; then
    # External dependency — not in sprint (AC-EC3)
    confidence="heuristic"
    printf '%s|%s|%s|%s|%s|External dependency — %s not in current sprint\n' \
      "$story_key" "$dep_key" "$source" "$confidence" "$match_text" "$dep_key"
  elif [ "$dep_idx" -gt "$story_idx" ]; then
    # Forward reference — inversion detected
    if [ "$source" = "depends_on" ]; then
      confidence="explicit"
    else
      confidence="heuristic"
    fi
    printf '%s|%s|%s|%s|%s|Move %s before %s\n' \
      "$story_key" "$dep_key" "$source" "$confidence" "$match_text" "$dep_key" "$story_key"
  fi
}

# Detect dependency inversions. Reads sprint-status.yaml and story files.
# Outputs pipe-delimited inversion records:
#   dependent|dependency|source|confidence|match_text|suggested_reorder
# Returns empty if no inversions found.
lint_detect_inversions() {
  local order_map
  order_map="$(lint_build_order_map)" || return 1
  [ -n "$order_map" ] || return 0

  # Collect all sprint keys for the AC text scanner.
  local sprint_keys=""
  local key idx
  while IFS=$'\t' read -r key idx; do
    [ -n "$key" ] || continue
    sprint_keys="${sprint_keys:+${sprint_keys} }${key}"
  done <<EOF
$order_map
EOF

  # For each story, check depends_on and AC text.
  local story_key story_idx dep_key story_file
  while IFS=$'\t' read -r story_key story_idx; do
    [ -n "$story_key" ] || continue

    story_file="$(reconcile_locate_story_file "$story_key")" || {
      printf '%s: error: story file not found: %s\n' "$SCRIPT_NAME" "$story_key" >&2
      return 1
    }

    # Explicit depends_on edges.
    local deps
    deps="$(lint_read_depends_on "$story_file")"
    if [ -n "$deps" ]; then
      while IFS= read -r dep_key; do
        [ -n "$dep_key" ] || continue
        _lint_emit_if_inversion "$story_key" "$dep_key" "depends_on" \
          "$story_idx" "$order_map"
      done <<DEPS
$deps
DEPS
    fi

    # Heuristic AC text scan edges.
    local ac_matches match_text
    ac_matches="$(lint_scan_ac_text "$story_file" "$sprint_keys")"
    if [ -n "$ac_matches" ]; then
      while IFS='|' read -r dep_key match_text; do
        [ -n "$dep_key" ] || continue
        [ "$dep_key" != "$story_key" ] || continue
        _lint_emit_if_inversion "$story_key" "$dep_key" "ac_text_scan" \
          "$story_idx" "$order_map" "$match_text"
      done <<AC_MATCHES
$ac_matches
AC_MATCHES
    fi
  done <<ORDER
$order_map
ORDER
}

# Format inversions as JSON. Parameters:
#   $1 — sprint_id
#   $2 — stories_analyzed count
#   $3 — pipe-delimited inversions string (may be empty)
lint_format_json() {
  local sprint_id="$1" count="$2" inversions="$3"

  if [ -z "$inversions" ]; then
    printf '{\n'
    printf '  "sprint_id": "%s",\n' "$sprint_id"
    printf '  "stories_analyzed": %s,\n' "$count"
    printf '  "inversions": [],\n'
    printf '  "status": "clean"\n'
    printf '}\n'
    return 0
  fi

  printf '{\n'
  printf '  "sprint_id": "%s",\n' "$sprint_id"
  printf '  "stories_analyzed": %s,\n' "$count"
  printf '  "inversions": [\n'

  local first=1
  local dependent dependency source confidence match_text suggested_reorder
  while IFS='|' read -r dependent dependency source confidence match_text suggested_reorder; do
    [ -n "$dependent" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    {\n'
    printf '      "dependent": "%s",\n' "$dependent"
    printf '      "dependency": "%s",\n' "$dependency"
    printf '      "source": "%s",\n' "$source"
    printf '      "confidence": "%s",\n' "$confidence"
    if [ -n "$match_text" ]; then
      printf '      "match_text": "%s",\n' "$match_text"
    fi
    printf '      "suggested_reorder": "%s"\n' "$suggested_reorder"
    printf '    }'
  done <<INV
$inversions
INV
  printf '\n  ],\n'
  printf '  "status": "inversions_detected"\n'
  printf '}\n'
}

# Format inversions as human-readable text. Parameters:
#   $1 — sprint_id
#   $2 — stories_analyzed count
#   $3 — pipe-delimited inversions string (may be empty)
lint_format_text() {
  local sprint_id="$1" count="$2" inversions="$3"

  printf 'Dependency Inversion Lint — %s\n' "$sprint_id"
  printf 'Stories analyzed: %s\n\n' "$count"

  if [ -z "$inversions" ]; then
    printf 'Result: CLEAN — no dependency inversions detected.\n'
    return 0
  fi

  printf 'INVERSIONS DETECTED:\n\n'
  printf '%-12s %-12s %-15s %-12s %s\n' "Dependent" "Dependency" "Source" "Confidence" "Suggested Reorder"
  printf '%-12s %-12s %-15s %-12s %s\n' "----------" "----------" "-------------" "----------" "-----------------"

  local dependent dependency source confidence match_text suggested_reorder
  while IFS='|' read -r dependent dependency source confidence match_text suggested_reorder; do
    [ -n "$dependent" ] || continue
    printf '%-12s %-12s %-15s %-12s %s\n' "$dependent" "$dependency" "$source" "$confidence" "$suggested_reorder"
  done <<INV
$inversions
INV
}

# Main entry point for lint-dependencies subcommand.
# Parameters:
#   $1 — output format (json|text), defaults to json
#   $2 — sprint_id filter (currently unused; accepted for forward-compat)
cmd_lint_dependencies() {
  local format="${1:-json}"
  local sprint_id_filter="${2:-}"

  # Validate format
  case "$format" in
    json|text) ;;
    *) die "invalid --format value: '$format'. Allowed: json, text" ;;
  esac

  # Read sprint-status.yaml
  if [ ! -r "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml not readable: $SPRINT_STATUS_YAML"
  fi

  # Validate basic yaml structure: must contain sprint_id or stories section.
  # A file with neither is treated as malformed (AC-EC8).
  if ! grep -qE '^(sprint_id:|stories:|items:)' "$SPRINT_STATUS_YAML" 2>/dev/null; then
    die "malformed sprint-status.yaml: no sprint_id or stories section found in $SPRINT_STATUS_YAML"
  fi

  # Extract sprint_id from yaml
  local sprint_id
  sprint_id="$(awk '
    /^sprint_id:/ {
      v = $0
      sub(/^sprint_id:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$SPRINT_STATUS_YAML")"
  sprint_id="${sprint_id:-unknown}"

  # Count stories
  local pairs
  pairs="$(reconcile_list_yaml_stories "$SPRINT_STATUS_YAML")" || {
    die "could not parse sprint-status.yaml: $SPRINT_STATUS_YAML"
  }

  local story_count=0
  if [ -n "$pairs" ]; then
    story_count="$(printf '%s\n' "$pairs" | grep -c . || true)"
  fi

  # Fast path: zero stories
  if [ "$story_count" -eq 0 ]; then
    if [ "$format" = "json" ]; then
      lint_format_json "$sprint_id" 0 ""
    else
      lint_format_text "$sprint_id" 0 ""
    fi
    exit 0
  fi

  # Detect inversions. Capture stderr separately so error messages
  # (e.g., "story file not found") surface to the caller even when
  # stdout is being captured by a command substitution.
  local inversions lint_err_file
  lint_err_file="$(mktemp "${SPRINT_STATUS_YAML}.lint-err.XXXXXX" 2>/dev/null || mktemp)"
  # Register lint_err_file for script-level EXIT/INT/TERM cleanup.
  # Without this, interrupting lint-dependencies between mktemp and the
  # inline rm -f leaks an orphan *.lint-err.?????? file. Mirrors the
  # register-then-clear pattern used at all atomic-write mktemp call sites.
  local _lint_err_idx
  _GAIA_TMP_PATHS+=("$lint_err_file")
  _lint_err_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  inversions="$(lint_detect_inversions 2>"$lint_err_file")" || {
    local lint_err
    lint_err="$(cat "$lint_err_file" 2>/dev/null)"
    rm -f "$lint_err_file"
    _GAIA_TMP_PATHS[$_lint_err_idx]=""
    if [ -n "$lint_err" ]; then
      printf '%s\n' "$lint_err" >&2
    fi
    die "lint-dependencies analysis failed"
  }
  rm -f "$lint_err_file"
  _GAIA_TMP_PATHS[$_lint_err_idx]=""

  # Output
  if [ "$format" = "json" ]; then
    lint_format_json "$sprint_id" "$story_count" "$inversions"
  else
    lint_format_text "$sprint_id" "$story_count" "$inversions"
  fi

  # Exit code contract: 0 clean, 2 inversions, 1 error (already handled above)
  if [ -n "$inversions" ]; then
    exit 2
  fi
  exit 0
}

# ---------- Subcommand: record-escalation-override ----------
#
# Append an escalation-halt override entry to sprint-status.yaml under the
# `overrides:` block. Atomic under flock (same critical section discipline as
# transition). Idempotent on (sprint_id, sorted-unique(ids), override_type) —
# if an entry with the same override_type and the same sorted id set already
# exists, the call is a no-op (zero bytes written, exit 0).
#
# This is the ONLY path the sprint-plan skill uses to record
# escalation-halt overrides. The skill MUST NOT write overrides inline via
# yq or sed.
#
# Usage:
#   sprint-state.sh record-escalation-override \
#     --item-ids "AI-42,AI-77" --user alice --reason "Acknowledged by lead"

# Sort and deduplicate a comma-or-space-separated id list. Echoes a single
# comma-joined sorted-unique line.
_override_normalize_ids() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr ',' '\n' \
    | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }' \
    | sort -u \
    | awk 'BEGIN{first=1} { if (!first) printf ","; printf "%s", $0; first=0 } END { printf "\n" }'
}

# Source escalation-halt.sh to get esch_check_override_recorded for idempotency.
# Library-only script — no side effects on source.
_override_load_esch() {
  local esch="${SPRINT_STATE_SCRIPT_DIR}/escalation-halt.sh"
  if [ ! -r "$esch" ]; then
    die "escalation-halt.sh not found at $esch (required for record-escalation-override)"
  fi
  # shellcheck disable=SC1090
  source "$esch"
}

# Append one override entry under the `overrides:` top-level key. If the key
# does not exist, append it at EOF with the entry as its first child.
# Assumes caller holds the flock.
_override_append_entry() {
  local ids_sorted="$1" user="$2" reason="$3"
  local file="$SPRINT_STATUS_YAML"
  local today
  today="$(date -u +%Y-%m-%d)"

  # Escape reason for YAML double-quoted string
  local reason_escaped
  reason_escaped=$(printf '%s' "$reason" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }')

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  # First pass: does the file contain an `overrides:` key at column 0?
  local has_overrides=0
  if grep -qE '^overrides:[[:space:]]*$' "$file" 2>/dev/null; then
    has_overrides=1
  fi

  if [ "$has_overrides" = "1" ]; then
    # Append the new entry at the END of the overrides section (before any
    # subsequent top-level key). Use awk to find the section boundary.
    awk -v ids="$ids_sorted" -v user="$user" -v reason="$reason_escaped" -v today="$today" '
      BEGIN { in_over = 0; inserted = 0 }
      {
        raw = $0
        sub(/\r$/, "", raw)
      }
      function emit_entry() {
        printf "  - date: \"%s\"\n", today
        printf "    user: \"%s\"\n", user
        printf "    override_type: escalation_halt\n"
        printf "    overridden_item_ids:\n"
        n = split(ids, arr, /,/)
        for (i = 1; i <= n; i++) {
          if (arr[i] != "") printf "      - \"%s\"\n", arr[i]
        }
        printf "    reason: \"%s\"\n", reason
        inserted = 1
      }
      raw ~ /^overrides:[[:space:]]*$/ { in_over = 1; print raw; next }
      # Another top-level key closes the section
      in_over && raw ~ /^[^[:space:]]/ {
        emit_entry()
        in_over = 0
        print raw
        next
      }
      { print raw }
      END {
        if (in_over && !inserted) emit_entry()
      }
    ' "$file" > "$tmp"
  else
    # No overrides section exists — append one at EOF with this entry.
    cat "$file" > "$tmp"
    # Ensure file ends with a newline before appending
    if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | wc -l | awk '{print $1}')" = "0" ]; then
      printf '\n' >> "$tmp"
    fi
    {
      printf 'overrides:\n'
      printf '  - date: "%s"\n' "$today"
      printf '    user: "%s"\n' "$user"
      printf '    override_type: escalation_halt\n'
      printf '    overridden_item_ids:\n'
      # shellcheck disable=SC2001
      local id
      # Split on comma
      local IFS=','
      for id in $ids_sorted; do
        [ -n "$id" ] || continue
        printf '      - "%s"\n' "$id"
      done
      printf '    reason: "%s"\n' "$reason_escaped"
    } >> "$tmp"
  fi

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[$_tmp_idx]=""
  trap - RETURN
}

do_record_override_locked() {
  local ids_raw="$1" user="$2" reason="$3"

  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  local ids_sorted
  ids_sorted="$(_override_normalize_ids "$ids_raw")"
  if [ -z "$ids_sorted" ]; then
    die "record-escalation-override: --item-ids resolved to an empty list after normalization"
  fi

  # Idempotency check via the escalation-halt sibling library.
  _override_load_esch
  if esch_check_override_recorded "$SPRINT_STATUS_YAML" "$ids_sorted"; then
    printf '%s: override already recorded for ids=[%s] — no-op\n' \
      "$SCRIPT_NAME" "$ids_sorted"
    return 0
  fi

  _override_append_entry "$ids_sorted" "$user" "$reason"
  printf '%s: recorded escalation_halt override for ids=[%s] user=%s\n' \
    "$SCRIPT_NAME" "$ids_sorted" "$user"
}

cmd_record_escalation_override() {
  local ids_raw="$1" user="$2" reason="$3"

  [ -n "$ids_raw" ] || die "record-escalation-override requires --item-ids <ids>"
  [ -n "$user" ]    || die "record-escalation-override requires --user <name>"
  [ -n "$reason" ]  || die "record-escalation-override requires --reason <text>"

  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" 5 9; then
      die "lock timeout acquiring $SPRINT_STATUS_LOCK"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    do_record_override_locked "$ids_raw" "$user" "$reason"
  )
}

# ---------- Subcommand: detect-auto-close ----------
#
# Advisory detection — emits a single line of JSON on stdout when the active
# sprint has reached the auto-close-eligible condition:
#
#   top-level `status: active`
#   AND every story has `status: done`
#   AND total story count > 0   (vacuous "all done" guard)
#
# When the condition is met, stdout is exactly one line:
#
#   {"sprint_id":"<id>","done":<N>,"total":<N>,"status":"active","end_date":"<iso>"}
#
# Otherwise stdout is empty. Exit code is always 0 (advisory only, never
# blocking). end_date is rendered as "(unset)" if the field is missing.
#
# READ-ONLY: This subcommand NEVER opens sprint-status.yaml for write. The
# boundary write (flipping `status: closed` and seeding the next sprint)
# remains an operator-driven manual action — auto-flipping would create
# false confidence that the next sprint was scaffolded too.
cmd_detect_auto_close() {
  # SPRINT_STATUS_YAML is set by resolve_paths() — canonical home is
  # .gaia/state/sprint-status.yaml. resolve_paths() runs unconditionally
  # before any subcommand dispatch, so the variable is always populated.
  local yaml_path="${SPRINT_STATUS_YAML:-}"
  [ -n "$yaml_path" ] && [ -f "$yaml_path" ] || return 0

  # Helper: extract top-level YAML scalar (same convention as dashboard).
  # `|| true` swallows the grep-no-match-exit-1 + pipefail combination so a
  # missing top-level `status:` (or `end_date:`) reads as empty string rather
  # than tripping `set -e` and exiting non-zero from the whole script.
  local sprint_id end_date status
  sprint_id=$(grep '^sprint_id:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^sprint_id:[[:space:]]*//' | tr -d '"' || true)
  end_date=$(grep '^end_date:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^end_date:[[:space:]]*//' | tr -d '"' || true)
  status=$(grep '^status:' "$yaml_path" 2>/dev/null | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)

  # Fast-fail: not active → suppress output.
  [ "$status" = "active" ] || return 0

  # Walk stories[] using the same bash-regex parser pattern the dashboard
  # uses (lines 230-261). No yq / awk dependency. Counts story keys + their
  # status field; classifies done vs. non-done.
  local in_stories=false
  local total_count=0 done_count=0
  local s_key="" s_status=""

  # Inline story flush — accumulates one story's counters.
  # Named with _dac_ prefix so it never collides with the dashboard's
  # global flush_story() (different signature, same logical purpose).
  _dac_flush() {
    if [ -n "$s_key" ]; then
      total_count=$((total_count + 1))
      [ "$s_status" = "done" ] && done_count=$((done_count + 1))
    fi
    s_key=""; s_status=""
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^stories: ]]; then
      in_stories=true
      _dac_saw_stories=true
      continue
    fi
    if [[ "$line" =~ ^items: ]] && [ "${_dac_saw_stories:-}" != true ]; then
      in_stories=true
      continue
    fi
    if [ "$in_stories" = true ]; then
      # A new top-level key (not indented) ends the stories block.
      if [[ "$line" =~ ^[a-z_] ]]; then
        in_stories=false
        _dac_flush
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*key:[[:space:]]* ]]; then
        _dac_flush
        s_key=$(printf '%s' "$line" | sed 's/.*key:[[:space:]]*//' | tr -d '"')
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]+status:[[:space:]]* ]]; then
        s_status=$(printf '%s' "$line" | sed 's/.*status:[[:space:]]*//' | tr -d '"')
      fi
    fi
  done < "$yaml_path"
  # Flush final story
  if [ "$in_stories" = true ]; then
    _dac_flush
  fi

  # Vacuous "all done" guard — empty sprint MUST NOT trigger detection.
  [ "$total_count" -gt 0 ] || return 0
  # All stories must be done.
  [ "$done_count" -eq "$total_count" ] || return 0

  # Render end_date field — preserve "(unset)" when missing.
  local end_field="${end_date:-(unset)}"
  # Emit single-line JSON payload.
  printf '{"sprint_id":"%s","done":%d,"total":%d,"status":"active","end_date":"%s"}\n' \
    "$sprint_id" "$done_count" "$total_count" "$end_field"
  return 0
}

# ---------- Subcommand: rollover ----------
#
# Migrate one or more stories from sprint-N to sprint-M. Per-story atomic
# (story-file flock); whole-batch best-effort with partial-failure semantics
# (some keys committed + some rolled back, non-zero exit + summary).
#
# Per-key flow:
#   1. Locate story file via the canonical shared resolver (all layout tiers)
#   2. Read frontmatter `sprint_id` field
#   3. Verify it matches --from value OR is `null`. Otherwise refuse this key.
#   4. Rewrite `sprint_id:` line to the --to value.
#   5. Call cmd_inject to register the story in the target sprint yaml.
#   6. On any step failure within steps 4-5, roll back the story-file
#      `sprint_id` to its original value before releasing the lock.
# ---------- Subcommand: set-phase ----------

# Extract the phase for $story_key from sprint-status.yaml. Stdout is the
# bare value, or empty when the row carries no phase field. Entry-scoped
# exactly like read_sprint_status_yaml_status, so a sibling row's phase can
# never be misreported as this story's.
read_yaml_story_phase() {
  local story_key="$1"
  local file="$SPRINT_STATUS_YAML"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  awk -v target="$story_key" '
    BEGIN { in_entry = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1 } else { in_entry = 0 }
      next
    }
    in_entry && line ~ /^[^[:space:]]/ { in_entry = 0 }
    in_entry && line ~ /^[[:space:]]+phase:[[:space:]]*/ {
      v = line
      sub(/^[[:space:]]+phase:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      printf "%s", v
      exit 0
    }
  ' "$file"
}

# Set (or clear) the optional `phase` field on one story row. Tempfile +
# atomic mv, exit 2 = row not found — a structural twin of
# rewrite_sprint_status_yaml, which only ever REPLACES a line.
#
# This rewriter must sometimes ADD one, and an append faces three asymmetric
# boundaries plus a load-bearing END. flush_append() is therefore called at
# every point that can close the target entry:
#   1. the next `- key:` entry header — flushed BEFORE its `print raw`, or
#      the new line lands under the following entry and attaches the phase
#      to the WRONG story;
#   2. a top-level key — flushed before falling through to `{ print raw }`;
#   3. an existing `phase:` line inside the entry — replaced in place (or
#      dropped, when clearing), which is the non-append path;
#   4. END — a sprint-status.yaml conventionally ends with its stories list,
#      so a target entry that is the file's last block reaches neither 1 nor
#      2. This is the COMMON case, not a fallback.
_rewrite_yaml_story_phase() {
  local story_key="$1" new_phase="$2"
  local file="$SPRINT_STATUS_YAML"

  if [ ! -s "$file" ]; then
    die "sprint-status.yaml is missing or empty: $file"
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  # Register tmp for script-level EXIT/INT/TERM cleanup.
  local _tmp_idx
  _GAIA_TMP_PATHS+=("$tmp")
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v target="$story_key" -v new_phase="$new_phase" '
    BEGIN {
      in_entry = 0; found_entry = 0; saw_phase = 0; done_append = 0
      indent = "    "; crlf = ""
    }
    function flush_append(   ) {
      if (in_entry && !done_append && new_phase != "" && !saw_phase) {
        printf "%sphase: %s%s\n", indent, new_phase, crlf
        done_append = 1
      }
    }
    {
      raw = $0
      line = $0
      sub(/\r$/, "", line)
    }
    # (1) A new list entry closes the current one.
    line ~ /^[[:space:]]*-[[:space:]]*key:[[:space:]]*/ {
      flush_append()
      k = line
      sub(/^[[:space:]]*-[[:space:]]*key:[[:space:]]*/, "", k)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", k)
      if (k == target) { in_entry = 1; found_entry = 1 } else { in_entry = 0 }
      print raw
      next
    }
    # (2) A top-level key closes the current entry.
    in_entry && line ~ /^[^[:space:]]/ { flush_append(); in_entry = 0 }
    # Track the entry body indentation and line ending so an appended line
    # matches the surrounding rows byte-for-byte.
    in_entry {
      match(raw, /^[[:space:]]+/)
      if (RSTART > 0) { indent = substr(raw, RSTART, RLENGTH) }
      crlf = ""
      if (raw ~ /\r$/) { crlf = "\r" }
    }
    # (3) An existing phase line in the target entry: replace, or drop when
    #     clearing.
    in_entry && line ~ /^[[:space:]]+phase:[[:space:]]*/ {
      saw_phase = 1; done_append = 1
      if (new_phase != "") { printf "%sphase: %s%s\n", indent, new_phase, crlf }
      next
    }
    { print raw }
    # (4) Last block in the file — the common case.
    END {
      flush_append()
      if (!found_entry) { exit 2 }
    }
  ' "$file" > "$tmp" || {
    local rc=$?
    rm -f "$tmp"
    trap - RETURN
    if [ $rc -eq 2 ]; then
      die "set-phase: story '$story_key' not found in $file"
    fi
    die "awk rewrite of '$file' failed (rc=$rc)"
  }

  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    trap - RETURN
    die "failed to mv tempfile over '$file'"
  fi
  # mv succeeded — clear the slot.
  _GAIA_TMP_PATHS[_tmp_idx]=""
  trap - RETURN
}

# set-phase locked critical section. Mirrors do_inject_locked's structure.
do_set_phase_locked() {
  local story_key="$1" new_phase="$2"

  if [ ! -s "$SPRINT_STATUS_YAML" ]; then
    die "sprint-status.yaml is missing or empty: $SPRINT_STATUS_YAML"
  fi

  # An unknown key is a hard error, never a silent success.
  if ! yaml_has_story_key "$SPRINT_STATUS_YAML" "$story_key"; then
    die "set-phase: story '$story_key' not found in $SPRINT_STATUS_YAML"
  fi

  # Idempotency: setting the value already present, or clearing a row that
  # has no phase, is a no-op that exits 0 WITHOUT opening the file for write.
  local current
  current=$(read_yaml_story_phase "$story_key" 2>/dev/null || printf '')
  if [ "$current" = "$new_phase" ]; then
    if [ -n "$new_phase" ]; then
      printf '%s: %s phase already %s — no-op\n' "$SCRIPT_NAME" "$story_key" "$new_phase"
    else
      printf '%s: %s phase already unset — no-op\n' "$SCRIPT_NAME" "$story_key"
    fi
    return 0
  fi

  _rewrite_yaml_story_phase "$story_key" "$new_phase"

  if [ -n "$new_phase" ]; then
    printf '%s: %s phase set to %s\n' "$SCRIPT_NAME" "$story_key" "$new_phase"
  else
    printf '%s: %s phase cleared\n' "$SCRIPT_NAME" "$story_key"
  fi
}

# Set or clear the execution phase on an existing story row.
#
# No lifecycle event: emit_inject_event exists because inject changes sprint
# composition and total_points; set-phase changes neither, exactly as
# set-shape emits none. A new event type would be write-only surface that no
# consumer reads.
#
# This is a LEAF lock site — it calls nothing that takes another lock — so it
# neither joins nor perturbs the audited nested-lock exception in rollover.
cmd_set_phase() {
  local story_key="$1" new_phase="$2"
  [ -n "$story_key" ] || die "set-phase: --story is required"
  # Fail fast before the lock. An empty value is the deliberate clear form.
  if [ -n "$new_phase" ]; then
    _validate_phase_value "set-phase" "$new_phase"
  fi

  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" 5 9; then
      die "lock timeout acquiring $SPRINT_STATUS_LOCK"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    do_set_phase_locked "$story_key" "$new_phase"
  )
}

cmd_rollover() {
  local from_sprint="$1" to_sprint="$2" keys_raw="$3"
  [ -n "$from_sprint" ] || die "rollover requires --from <sprint-id>"
  [ -n "$to_sprint" ] || die "rollover requires --to <sprint-id>"
  [ -n "$keys_raw" ] || die "rollover requires --keys <key1,key2,...>"

  # Suppress proxy hooks during rollover — the hook fires once after the
  # rollover subshell exits (wired in the post-dispatch proxy hook).
  _GAIA_PROXY_HOOK_SUPPRESSED=1
  trap '_GAIA_PROXY_HOOK_SUPPRESSED=0' RETURN 2>/dev/null || true

  # Split comma-separated keys.
  local OLDIFS="$IFS"
  IFS=','
  set -f
  # shellcheck disable=SC2206
  local keys=( $keys_raw )
  set +f
  IFS="$OLDIFS"

  # Route: concurrent mode uses the three-phase protocol; single-sprint
  # mode keeps the existing _rollover_one path byte-identical.
  if _is_concurrent_mode; then
    _cmd_rollover_concurrent "$from_sprint" "$to_sprint" "${keys[@]}"
    return $?
  fi

  # --- Single-sprint mode (byte-identical to pre-concurrent) ---
  local succeeded=() failed=()
  local key
  for key in "${keys[@]}"; do
    key="${key# }"; key="${key% }"  # trim
    [ -n "$key" ] || continue
    if _rollover_one "$key" "$from_sprint" "$to_sprint"; then
      succeeded+=("$key")
    else
      failed+=("$key")
    fi
  done

  printf 'sprint-state.sh rollover: from=%s to=%s\n' "$from_sprint" "$to_sprint" >&2
  printf 'sprint-state.sh rollover: succeeded: %s\n' "${succeeded[*]:-(none)}" >&2
  printf 'sprint-state.sh rollover: failed:    %s\n' "${failed[*]:-(none)}" >&2

  if [ "${#failed[@]}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Concurrent-mode rollover: three-phase protocol.
# Phase A: lifecycle lock (strict) — closing-marker check + independence check (read-only).
# Phase B: per-sprint lock on target — inject + phase reset (per passing key).
# Phase C: per-sprint lock on source — remove key + sprint_id rewrite (per passing key).
# No two locks are ever held at once.
_cmd_rollover_concurrent() {
  local from_sprint="$1" to_sprint="$2"
  shift 2
  local keys=("$@")

  local state_dir
  state_dir="$(dirname "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml}")"
  local l4_path="${state_dir}/${GAIA_LOCK_L4_PATH}"
  local ic_script="${SPRINT_STATE_SCRIPT_DIR}/independence-check.sh"

  # Pre-check: resolve story files and validate touch-set presence.
  local passed_keys=() failed_keys=() touchset_missing_keys=()
  local key story_file
  for key in "${keys[@]}"; do
    key="${key# }"; key="${key% }"
    [ -n "$key" ] || continue

    # Resolve story file.
    # shellcheck source=resolve-story-file.sh
    . "${SPRINT_STATE_SCRIPT_DIR}/resolve-story-file.sh"
    story_file="$(resolve_story_file "$key" 2>/dev/null)" || true
    if [ -z "$story_file" ] || [ ! -f "$story_file" ]; then
      printf 'sprint-state.sh rollover: story file not found for %s\n' "$key" >&2
      failed_keys+=("$key")
      continue
    fi

    # Stories entering concurrent mode must have a touch-set; refuse if absent.
    local has_touchset
    has_touchset="$(awk '
      BEGIN { in_fm=0; found=0 }
      /^---[[:space:]]*$/ { if (!in_fm) { in_fm=1; next } else exit }
      in_fm && /^predicted_touch_set:/ { found=1; exit }
      END { print found }
    ' "$story_file")"
    if [ "$has_touchset" != "1" ]; then
      printf 'touch-set missing for %s\n' "$key" >&2
      touchset_missing_keys+=("$key")
      continue
    fi

    passed_keys+=("$key")
  done

  # If any keys lack a touch-set, they cannot proceed (exit code 2).
  # Other keys continue through the independence check.
  if [ "${#passed_keys[@]}" -eq 0 ]; then
    printf 'sprint-state.sh rollover: from=%s to=%s\n' "$from_sprint" "$to_sprint" >&2
    printf 'sprint-state.sh rollover: succeeded: (none)\n' >&2
    printf 'sprint-state.sh rollover: failed:    %s\n' "${failed_keys[*]:-(none)}" >&2
    printf 'sprint-state.sh rollover: touch-set-missing: %s\n' "${touchset_missing_keys[*]:-(none)}" >&2
    # Exit precedence: exit 2 if any touch-set missing.
    if [ "${#touchset_missing_keys[@]}" -gt 0 ]; then
      return 2
    fi
    return 1
  fi

  # ---- Phase A: L4 strict + closing-marker check + independence check ----
  local phase_a_passed_keys=()
  local phase_a_failed_keys=()
  local phase_a_rc=0
  local _phase_a_out
  _phase_a_out="$(mktemp "${state_dir}/.rollover-phaseA.XXXXXX")" || die "rollover: mktemp failed"

  (
    if ! acquire_lock "$l4_path" "${GAIA_LOCK_L4_TIMEOUT:-10}" 8 --strict; then
      die "rollover: lock timeout acquiring lifecycle lock $l4_path"
    fi
    trap 'release_lock 8 2>/dev/null || true' EXIT
    trap 'release_lock 8 2>/dev/null || true; exit 130' INT
    trap 'release_lock 8 2>/dev/null || true; exit 143' TERM

    # Check closing markers on source and target.
    local src_marker tgt_marker
    src_marker="$(_closing_marker_path "$state_dir" "$from_sprint")"
    tgt_marker="$(_closing_marker_path "$state_dir" "$to_sprint")"
    if [ -f "$src_marker" ] && _closing_marker_owner_alive "$src_marker"; then
      printf 'sprint close in progress -- rollover refused\n' >&2
      exit 1
    fi
    if [ -f "$tgt_marker" ] && _closing_marker_owner_alive "$tgt_marker"; then
      printf 'sprint close in progress -- rollover refused\n' >&2
      exit 1
    fi

    # Per-key independence check: each key is checked individually so
    # independent keys can carry over while failing keys stay. The check
    # is read-only (no writes). Fail closed when the script is missing.
    if [ ! -x "$ic_script" ]; then
      printf 'rollover: independence-check.sh missing or not executable at %s — refusing (fail closed)\n' "$ic_script" >&2
      exit 1
    fi
    local _any_fail=0
    for key in "${passed_keys[@]}"; do
      local _key_rc=0
      PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-.}}" \
      CLAUDE_PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-.}}" \
        "$ic_script" \
          --candidate "$to_sprint" \
          --candidate-stories "$key" \
          --from-sprint "$from_sprint" 2>&1 || _key_rc=$?

      if [ "$_key_rc" -ne 0 ]; then
        printf 'FAIL independence: %s\n' "$key"
        _any_fail=1
      else
        printf 'PASS independence: %s\n' "$key"
      fi
    done
    # Exit non-zero when any key failed (caller parses per-key lines).
    if [ "$_any_fail" -ne 0 ]; then
      exit 1
    fi
    exit 0
  ) > "$_phase_a_out" 2>&1 || phase_a_rc=$?

  # Parse per-key results from Phase A output.
  local _pk
  for _pk in "${passed_keys[@]}"; do
    if /usr/bin/grep -q "^PASS independence: ${_pk}\$" "$_phase_a_out" 2>/dev/null; then
      phase_a_passed_keys+=("$_pk")
    else
      phase_a_failed_keys+=("$_pk")
    fi
  done
  # Echo Phase A output to stderr for diagnostics.
  cat "$_phase_a_out" >&2 2>/dev/null || true
  rm -f "$_phase_a_out"

  # ---- Phase B: L1 of target — inject + phase reset (per passing key) ----
  local phase_b_passed=() phase_b_failed=()
  if [ "${#phase_a_passed_keys[@]}" -gt 0 ]; then
    local to_yaml
    to_yaml="$(_sprint_file_path "$state_dir" "$to_sprint")"
    local to_lock="${to_yaml}.lock"

    for key in "${phase_a_passed_keys[@]}"; do
      local inject_rc=0

      # Phase B: inject the story into the target sprint + reset phase.
      # The sprint_id rewrite happens in Phase C (after inject succeeds)
      # so we never leave the story file pointing at a sprint that lacks
      # the key. cmd_inject and cmd_set_phase acquire L1 in their own
      # subshells; we do NOT hold L1 ourselves (no two locks at once).
      # The inject's sprint-id mismatch check is suppressed because the
      # story file still carries the source sprint_id at this point.
      (
        # Point SPRINT_STATUS_YAML at the target's per-sprint file.
        SPRINT_STATUS_YAML="$to_yaml"
        SPRINT_STATUS_LOCK="${to_yaml}.lock"
        _GAIA_SPRINT_ARG="$to_sprint"

        # Suppress the inject independence gate and sprint-id mismatch
        # check — Phase A already verified independence.
        _GAIA_ROLLOVER_INJECT=1
        cmd_inject "$key" "" >/dev/null 2>&1 || exit 1

        # Reset execution phase (stale from source sprint).
        cmd_set_phase "$key" "" >/dev/null 2>&1 || exit 1
      ) || inject_rc=$?

      if [ "$inject_rc" -eq 0 ]; then
        phase_b_passed+=("$key")
      else
        printf 'sprint-state.sh rollover Phase B: inject failed for %s\n' "$key" >&2
        phase_b_failed+=("$key")
      fi
    done
  fi

  # ---- Phase C: L1 of source — remove + sprint_id rewrite (per passing key) ----
  local final_succeeded=() final_failed=()
  if [ "${#phase_b_passed[@]}" -gt 0 ]; then
    local from_yaml
    from_yaml="$(_sprint_file_path "$state_dir" "$from_sprint")"
    local from_lock="${from_yaml}.lock"

    for key in "${phase_b_passed[@]}"; do
      local remove_rc=0

      # Phase C: take L1 of source, remove key from source yaml, rewrite
      # the story file's sprint_id to the target. The sprint_id rewrite
      # happens here (after inject succeeded in Phase B) so we never
      # leave a state where sprint_id names a sprint that lacks the key.
      # Accepts either source or target as current sprint_id value so a
      # re-run after a crash between phases completes idempotently.
      (
        if ! acquire_lock "$from_lock" 5 9; then
          die "rollover Phase C: lock timeout acquiring $from_lock"
        fi
        trap 'release_lock 9 2>/dev/null || true' EXIT
        trap 'release_lock 9 2>/dev/null || true; exit 130' INT
        trap 'release_lock 9 2>/dev/null || true; exit 143' TERM

        # Rewrite sprint_id in the story file BEFORE removing from
        # source, so a crash never leaves the key only in the target
        # with the old sprint_id.
        . "${SPRINT_STATE_SCRIPT_DIR}/resolve-story-file.sh"
        local sf
        sf="$(resolve_story_file "$key" 2>/dev/null)" || exit 1
        [ -f "$sf" ] || exit 1
        local tmp
        tmp="$(mktemp "${sf}.XXXXXX")" || exit 1
        awk -v from="$from_sprint" -v to="$to_sprint" '
          /^sprint_id:/ {
            # Accept both quoted and unquoted forms of sprint_id so
            # the rewrite handles the 201 real story files that use
            # unquoted sprint_id: sprint-NNN.
            if ($0 ~ ("^sprint_id:[[:space:]]*\"?" from "\"?[[:space:]]*$") || \
                $0 ~ ("^sprint_id:[[:space:]]*\"?" to "\"?[[:space:]]*$")   || \
                $0 ~ /^sprint_id:[[:space:]]*null[[:space:]]*$/) {
              print "sprint_id: \"" to "\""
              next
            }
          }
          { print }
        ' "$sf" > "$tmp" || { rm -f "$tmp"; exit 1; }
        if ! grep -q "^sprint_id:[[:space:]]*\"$to_sprint\"" "$tmp"; then
          rm -f "$tmp"; exit 1
        fi
        mv -f "$tmp" "$sf" || { rm -f "$tmp"; exit 1; }

        # Remove the key from the source sprint yaml (idempotent).
        # Done after the sprint_id rewrite so a crash between the two
        # leaves the key in both sprints with the correct sprint_id,
        # which a re-run can complete.
        _remove_story_from_yaml "$from_yaml" "$key"
      ) || remove_rc=$?

      if [ "$remove_rc" -eq 0 ]; then
        final_succeeded+=("$key")
      else
        printf 'sprint-state.sh rollover Phase C: remove/rewrite failed for %s\n' "$key" >&2
        final_failed+=("$key")
      fi
    done
  fi

  # Combine all failure categories (bash 3.2-safe: guard empty arrays).
  local all_failed=()
  [ "${#failed_keys[@]}" -gt 0 ] 2>/dev/null && all_failed+=("${failed_keys[@]}")
  [ "${#phase_a_failed_keys[@]}" -gt 0 ] 2>/dev/null && all_failed+=("${phase_a_failed_keys[@]}")
  [ "${#phase_b_failed[@]}" -gt 0 ] 2>/dev/null && all_failed+=("${phase_b_failed[@]}")
  [ "${#final_failed[@]}" -gt 0 ] 2>/dev/null && all_failed+=("${final_failed[@]}")

  printf 'sprint-state.sh rollover: from=%s to=%s\n' "$from_sprint" "$to_sprint" >&2
  printf 'sprint-state.sh rollover: succeeded: %s\n' "${final_succeeded[*]:-(none)}" >&2
  printf 'sprint-state.sh rollover: failed:    %s\n' "${all_failed[*]:-(none)}" >&2
  if [ "${#touchset_missing_keys[@]}" -gt 0 ] 2>/dev/null; then
    printf 'sprint-state.sh rollover: touch-set-missing: %s\n' "${touchset_missing_keys[*]}" >&2
  fi

  # Exit precedence: exit 2 if any touch-set missing, else exit 1 if any
  # key failed, else exit 0.
  if [ "${#touchset_missing_keys[@]}" -gt 0 ] 2>/dev/null; then
    return 2
  fi
  if [ "${#all_failed[@]}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Internal: process one story key. Returns 0 on success, non-zero on refusal
# or write failure (caller logs failure and continues to next key).
_rollover_one() {
  local key="$1" from_sprint="$2" to_sprint="$3"

  # Locate the story file via the canonical shared resolver (handles all three
  # layout tiers: per-story-nested, legacy-nested, legacy-flat).
  # shellcheck source=resolve-story-file.sh
  . "${SPRINT_STATE_SCRIPT_DIR}/resolve-story-file.sh"
  local story_file resolver_stderr resolver_rc
  resolver_stderr=$(resolve_story_file "$key" 2>&1 1>/dev/null) || true
  # Re-run to capture stdout (Bash 3.2: no process substitution trick that
  # reliably captures both stdout and the exit code in separate variables).
  story_file=$(resolve_story_file "$key" 2>/dev/null); resolver_rc=$?
  # On any failure the first run already captured stderr; use rc from second.
  if [ "$resolver_rc" -eq 2 ]; then
    printf 'sprint-state.sh rollover: ambiguous match for %s — multiple story files found; resolve manually\n' "$key" >&2
    if [ -n "$resolver_stderr" ]; then
      printf '%s\n' "$resolver_stderr" >&2
    fi
    return 1
  fi
  if [ -z "$story_file" ] || [ ! -f "$story_file" ]; then
    printf 'sprint-state.sh rollover: story file not found for %s\n' "$key" >&2
    return 1
  fi

  # Read current sprint_id from frontmatter.
  local current_sid
  current_sid=$(grep '^sprint_id:' "$story_file" | head -1 | sed 's/^sprint_id:[[:space:]]*//' | tr -d '"')
  # Empty after stripping quotes -> empty literal. `null` -> the YAML null.
  local accept=0
  if [ "$current_sid" = "$from_sprint" ]; then
    accept=1
  elif [ "$current_sid" = "null" ] || [ -z "$current_sid" ]; then
    accept=1
  fi
  if [ "$accept" -eq 0 ]; then
    printf 'sprint-state.sh rollover: %s sprint_id=%s does not match --from %s and is not null; refusing\n' \
      "$key" "$current_sid" "$from_sprint" >&2
    return 1
  fi

  # Per-story lock. Reuse the same .lock suffix pattern as transition.
  local lock_file="${story_file}.rollover.lock"

  _rollover_with_lock() {
    # Rewrite sprint_id in-place. Two cases:
    #   1. sprint_id: "<from>"  -> sprint_id: "<to>"
    #   2. sprint_id: null      -> sprint_id: "<to>"
    # Use a sibling tempfile + mv for atomicity.
    local tmp
    tmp=$(mktemp "${story_file}.XXXXXX") || return 1
    # Match either quoted "from" or null literal.
    awk -v from="$from_sprint" -v to="$to_sprint" '
      /^sprint_id:/ {
        # Normalize all matching forms to: sprint_id: "<to>"
        if ($0 ~ ("^sprint_id:[[:space:]]*\"" from "\"") || $0 ~ /^sprint_id:[[:space:]]*null[[:space:]]*$/) {
          print "sprint_id: \"" to "\""
          next
        }
      }
      { print }
    ' "$story_file" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Sanity: confirm the rewrite happened (we should see the to value now).
    if ! grep -q "^sprint_id:[[:space:]]*\"$to_sprint\"" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi

    # Snapshot the original for rollback.
    local backup
    backup=$(mktemp "${story_file}.rollback-XXXXXX") || { rm -f "$tmp"; return 1; }
    cp "$story_file" "$backup"

    # Commit the rewrite.
    if ! mv -f "$tmp" "$story_file"; then
      rm -f "$tmp" "$backup"
      return 1
    fi

    # Now inject the story into the target sprint yaml. Two branches, and the
    # phase reset below must hold on BOTH:
    #   * key ABSENT  -> the append runs; passing no phase omits the field.
    #   * key PRESENT -> the idempotency guard in do_inject_locked
    #                    short-circuits, append_story_to_yaml is never
    #                    reached, and the pre-existing row survives INTACT.
    if ! cmd_inject "$key" "" >/dev/null 2>&1; then
      # Rollback the story file.
      mv -f "$backup" "$story_file" 2>/dev/null || true
      rm -f "$backup"
      return 1
    fi

    # Reset the execution phase EXPLICITLY rather than relying on the append
    # path being taken. A phase is a position in ONE sprint's dependency
    # partition, derived from that sprint's candidate set, so a carried value
    # is a stale and actively misleading ordering hint in the target sprint —
    # omission is the fail-safe, and the next sprint plan re-derives it.
    # Idempotent, so this is a no-op on an already phase-less row.
    if ! cmd_set_phase "$key" "" >/dev/null 2>&1; then
      mv -f "$backup" "$story_file" 2>/dev/null || true
      rm -f "$backup"
      return 1
    fi

    rm -f "$backup"
    return 0
  }

  local rc=0
  (
    if ! acquire_lock "$lock_file" 5 9; then
      die "lock timeout acquiring $lock_file"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    # AUDITED NESTED-LOCK EXCEPTION: _rollover_with_lock calls cmd_inject and
    # then cmd_set_phase (the explicit phase reset). Each acquires
    # $SPRINT_STATUS_LOCK on fd 9 in its own subshell — two SEQUENTIAL nested
    # acquisitions in the same order, never overlapping. No fd
    # aliasing: cmd_inject runs its critical section in a nested subshell,
    # which gets its own copy of the shell variables backing the per-fd
    # registry (_AL_PATH_9 / _AL_MODE_9) and its own copy of the fd table.
    # Its rebinding of fd 9 and of the registry is therefore invisible to
    # this subshell, whose fd 9 still refers to .rollover.lock when the
    # nested call returns. (Note this is subshell variable scoping, not
    # process separation: a bash subshell shares $$ with its parent, and
    # cmd_inject is an ordinary in-process function call.) The same reasoning
    # holds verbatim for cmd_set_phase, which is a leaf site: it takes only
    # the sprint-status lock and calls nothing that locks. Lock ordering:
    # per-story .rollover.lock first, then sprint-status second. Reverse
    # ordering cannot occur — the other callers of both functions (the
    # dispatch at main) hold no per-story lock. Any future nested-lock site
    # must verify ordering to prevent deadlock.
    _rollover_with_lock
  )
  rc=$?
  return $rc
}

# ============================================================
# Sprint goals + sprint-level state machine
# ============================================================

# Resolve the path of the active sprint yaml. Caller has already called
# resolve_paths(). Routes through _resolve_sprint_file() in concurrent mode
# so every subcommand resolves the same way.
_resolve_active_yaml() {
  local sprint_arg="${_GAIA_SPRINT_ARG:-}"
  if _is_concurrent_mode; then
    _resolve_sprint_file "$sprint_arg"
    return $?
  fi
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    # resolve_paths() is the single source of truth for this value — it applies
    # the canonical-state-tier resolution order (.gaia/state/ first,
    # legacy docs/ read-compat, fresh writes → .gaia/state/).
    printf '%s' "$SPRINT_STATUS_YAML"
  else
    # Safety net for callers that invoke this without resolve_paths() first.
    # `.gaia/` is anchored at PROJECT_ROOT, not PROJECT_PATH (per CLAUDE.md
    # ). Backward-compat fallback chain mirrors resolve_paths():
    # PROJECT_ROOT → CLAUDE_PROJECT_ROOT → PROJECT_PATH → ".".
    printf '%s' "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml"
  fi
}

# cmd_init — bootstrap a sprint-status.yaml when none exists yet.
# Seeds the canonical shape (sprint id/state/total_points=0/stories=[]/goals=[]),
# under flock to remain consistent with all other writers, and is
# idempotent: re-init against an existing yaml is rejected.
cmd_init() {
  local sprint_id="$1"
  # _INIT_VERB is set by the dispatch layer to the invoking subcommand name
  # ("init" or "advance") so user-facing messages reflect the actual command.
  # Defaults to "init" for backward-compat when cmd_init is called directly.
  local init_verb="${_INIT_VERB:-init}"
  [ -n "$sprint_id" ] || die "${init_verb}: --sprint-id is required"
  # Optional `--start-date`, `--end-date`, `--sprint-length-days` flags.
  # When a date flag is provided, the seed includes the field. When the date
  # flags are absent the seed carries only the minimal shape (sprint_id /
  # status / total_points / goals / stories). The end-date can also be derived
  # from start + length.
  #
  # `--capacity-points` is accepted-but-inert: capacity judgement is now made
  # by the agent-native check (dependency-depth + coherence + measured
  # wall-clock), not by a human-team calendar-capacity proxy. The flag is
  # still parsed so existing callers do not break, but its value is dropped
  # and no capacity_points line is ever seeded.
  local start_date="" end_date="" sprint_length=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --start-date)      start_date="${2:-}"; shift 2 ;;
      --end-date)        end_date="${2:-}"; shift 2 ;;
      --capacity-points) shift 2 ;;  # accepted-but-inert (legacy proxy retired)
      --sprint-length-days) sprint_length="${2:-}"; shift 2 ;;
      *) die "${init_verb}: unknown flag: $1" ;;
    esac
  done
  # Validate sprint ID before constructing any file paths.
  _validate_sprint_id "$sprint_id" || exit 1

  local state_dir="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state"
  local max_conc
  max_conc="$(_read_max_concurrent_active)"

  # --- Transitional state: limit 1 but per-sprint files still exist ---
  # New activations are refused until only one sprint remains (reverse migration).
  if [ "$max_conc" -le 1 ] 2>/dev/null && _per_sprint_files_exist "$state_dir"; then
    local yaml="${state_dir}/sprint-status.yaml"
    local existing_status=""
    if [ -e "$yaml" ]; then
      existing_status="$(_yaml_sprint_status "$yaml" 2>/dev/null || true)"
    fi
    if [ -n "$existing_status" ] && [ "$existing_status" != "closed" ]; then
      die "${init_verb}: concurrent sprints still active (limit lowered to $max_conc) — new activations refused until only one sprint remains"
    fi
  fi

  # --- Concurrent-mode init (max_concurrent_active > 1) ---
  if [ "$max_conc" -gt 1 ] 2>/dev/null; then
    local yaml="${state_dir}/sprint-status.yaml"
    local existing_status=""
    if [ -e "$yaml" ]; then
      existing_status="$(_yaml_sprint_status "$yaml" 2>/dev/null || true)"
    fi

    # If there is a live (non-closed) sprint, enter concurrent path.
    if [ -n "$existing_status" ] && [ "$existing_status" != "closed" ] && [ "$existing_status" != "" ]; then
      # Run the activation guard — counts ACTIVE sprints only.
      local active_ids="" active_count=0
      if _per_sprint_files_exist "$state_dir"; then
        # Already in per-sprint layout; count active sprints from per-sprint files.
        local _f
        for _f in "${state_dir}"/sprint-status-*.yaml; do
          [ -f "$_f" ] || continue
          case "$_f" in *.lock|*.result) continue ;; esac
          local _st=""
          _st="$(_yaml_sprint_status "$_f" 2>/dev/null || true)"
          if [ "$_st" = "active" ]; then
            local _sid=""
            _sid="$(read_yaml_sprint_id "$_f" 2>/dev/null || true)"
            active_ids="${active_ids}${active_ids:+$'\n'}${_sid}"
            active_count=$((active_count + 1))
          fi
        done
      else
        # Single-file mode; check existing sprint status.
        if [ "$existing_status" = "active" ]; then
          local _sid=""
          _sid="$(read_yaml_sprint_id "$yaml" 2>/dev/null || true)"
          active_ids="$_sid"
          active_count=1
        fi
      fi

      # Guard: refuse if limit reached.
      if ! printf '%s\n' "$active_ids" | concurrent_sprint_guard "$max_conc" 2>&1; then
        return 1
      fi

      # Forward migration under L4 if still in single-file mode.
      local l4_path="${state_dir}/${GAIA_LOCK_L4_PATH}"
      if ! _per_sprint_files_exist "$state_dir"; then
        local existing_id
        existing_id="$(read_yaml_sprint_id "$yaml" 2>/dev/null || true)"
        [ -n "$existing_id" ] || die "${init_verb}: cannot read sprint_id from existing $yaml"
        (
          if ! acquire_lock "$l4_path" "$GAIA_LOCK_L4_TIMEOUT" 8 --strict; then
            printf '%s: error: lifecycle lock timeout during forward migration\n' "$SCRIPT_NAME" >&2
            exit "$ACQUIRE_LOCK_EXIT_TIMEOUT"
          fi
          trap 'release_lock 8 2>/dev/null || true' EXIT
          trap 'release_lock 8 2>/dev/null || true; exit 130' INT
          trap 'release_lock 8 2>/dev/null || true; exit 143' TERM
          _forward_migration "$state_dir" "$existing_id" "$sprint_id"
        ) || return $?
      elif ! _migration_is_complete "$state_dir"; then
        # Per-sprint files exist but marker absent — incomplete migration.
        local existing_id
        existing_id="$(read_yaml_sprint_id "$yaml" 2>/dev/null || true)"
        (
          if ! acquire_lock "$l4_path" "$GAIA_LOCK_L4_TIMEOUT" 8 --strict; then
            exit "$ACQUIRE_LOCK_EXIT_TIMEOUT"
          fi
          trap 'release_lock 8 2>/dev/null || true' EXIT
          trap 'release_lock 8 2>/dev/null || true; exit 130' INT
          trap 'release_lock 8 2>/dev/null || true; exit 143' TERM
          _forward_migration "$state_dir" "$existing_id" "$sprint_id"
        ) || return $?
      fi

      # Seed the new per-sprint file as planned.
      local new_per_sprint
      new_per_sprint="$(_sprint_file_path "$state_dir" "$sprint_id")"
      _check_path_length "$new_per_sprint" || exit 1
      if [ -e "$new_per_sprint" ]; then
        local new_st=""
        new_st="$(_yaml_sprint_status "$new_per_sprint" 2>/dev/null || true)"
        if [ "$new_st" = "closed" ]; then
          printf '%s: %s: re-seeding over closed predecessor sprint (%s)\n' \
            "$SCRIPT_NAME" "$init_verb" "$new_per_sprint" >&2
        else
          die "${init_verb}: per-sprint file already exists (status=${new_st:-unknown}) for $sprint_id"
        fi
      fi
      mkdir -p "$state_dir"
      local tmp
      tmp="$(mktemp "${new_per_sprint}.XXXXXX")"
      # Derive end_date from start + length.
      if [ -n "$start_date" ] && [ -z "$end_date" ] && [ -n "$sprint_length" ]; then
        end_date="$(date -u -d "$start_date + $sprint_length days" +%Y-%m-%d 2>/dev/null || \
                    date -u -j -f '%Y-%m-%d' -v +"${sprint_length}d" "$start_date" +%Y-%m-%d 2>/dev/null || \
                    printf '')"
      fi
      {
        printf 'sprint_id: "%s"\n' "$sprint_id"
        printf 'status: planned\n'
        [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
        [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
        printf 'total_points: 0\n'
        printf 'goals: []\n'
        printf 'stories: []\n'
      } > "$tmp"
      mv "$tmp" "$new_per_sprint"
      printf '%s: seeded %s for sprint %s (concurrent mode)\n' "$init_verb" "$new_per_sprint" "$sprint_id"

      # Emit sprint-plan stub (same as single-sprint path).
      _plan_dir="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}/sprint-plan"
      _plan_file="${_plan_dir}/${sprint_id}-plan.md"
      if [ ! -e "$_plan_file" ]; then
        mkdir -p "$_plan_dir" 2>/dev/null || true
        {
          printf -- '---\n'
          printf 'artifact_type: sprint-plan\n'
          printf 'sprint_id: "%s"\n' "$sprint_id"
          printf 'generated_by: sprint-state.sh %s\n' "$init_verb"
          printf 'generated_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
          [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
          printf -- '---\n\n'
          printf '# Sprint plan: %s\n\n' "$sprint_id"
          printf 'This stub was emitted by `sprint-state.sh %s`.\n\n' "$init_verb"
          printf '## Goals\n\n_(populated by /gaia-sprint-plan Step 4)_\n\n'
          printf '## Selected stories\n\n_(populated by /gaia-sprint-plan Step 5)_\n\n'
          printf '## Notes\n\n_(populated by /gaia-sprint-plan Step 6)_\n'
        } > "$_plan_file" 2>/dev/null || true
      fi
      return 0
    fi
    # Fall through to single-sprint init when existing is closed or absent.
  fi

  # --- Single-sprint init (legacy path, byte-identical when max_concurrent_active absent or 1) ---
  local yaml
  yaml="$(_resolve_active_yaml)"
  if [ -e "$yaml" ]; then
    # After /gaia-sprint-close the live yaml persists with `status: closed`
    # (the close ceremony archives a COPY, it does not remove the live file).
    # The next sprint's `init` previously hard-refused on that residual,
    # forcing a manual `rm sprint-status.yaml` between sprints. A CLOSED
    # predecessor is a sanctioned hand-off point: re-seed over it (the closed
    # state is already preserved in sprint-archive/). Any OTHER existing status
    # (planned/active/review) is still refused — overwriting a live sprint
    # would lose in-flight state.
    local existing_status
    existing_status="$(_yaml_sprint_status "$yaml" 2>/dev/null || true)"
    if [ "$existing_status" = "closed" ]; then
      printf '%s: %s: re-seeding over closed predecessor sprint (%s, status=closed) — prior state preserved in sprint-archive/\n' \
        "$SCRIPT_NAME" "$init_verb" "$yaml" >&2
    else
      die "${init_verb}: $yaml already exists (status=${existing_status:-unknown}) — refusing to overwrite a non-closed sprint (close it first via /gaia-sprint-close)"
    fi
  fi
  mkdir -p "$(dirname "$yaml")"
  # No flock here: the init path is the FIRST writer (it refuses to overwrite
  # an existing yaml), so there is no concurrent reader/writer to coordinate
  # with. Subsequent writes route through transition/inject/set-goals which
  # already acquire the canonical sprint-status.yaml.lock under flock.
  local tmp
  tmp="$(mktemp "${yaml}.XXXXXX")"
  # Derive end_date from start + length when end-date wasn't passed but length was.
  if [ -n "$start_date" ] && [ -z "$end_date" ] && [ -n "$sprint_length" ]; then
    # Try gnu-date first (Linux), fall back to BSD-date (macOS).
    end_date="$(date -u -d "$start_date + $sprint_length days" +%Y-%m-%d 2>/dev/null || \
                date -u -j -f '%Y-%m-%d' -v +"${sprint_length}d" "$start_date" +%Y-%m-%d 2>/dev/null || \
                printf '')"
  fi
  # Seed the canonical top-level `status:` field. A fresh sprint starts in the
  # `planned` state (planned → active → review → closed). The `status: planned`
  # seed is what makes the sprint transitionable (a status:-less seed could not
  # be transitioned at all).
  {
    printf 'sprint_id: "%s"\n' "$sprint_id"
    printf 'status: planned\n'
    [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
    [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
    printf 'total_points: 0\n'
    printf 'goals: []\n'
    printf 'stories: []\n'
  } > "$tmp"
  mv "$tmp" "$yaml"
  printf '%s: seeded %s for sprint %s\n' "$init_verb" "$yaml" "$sprint_id"

  # Emit a sprint-plan/{id}-plan.md stub so the documented sprint-plan layout
  # is non-empty even when the operator drove sprint commit via direct
  # `sprint-state.sh init`/`inject` rather than the /gaia-sprint-plan SKILL
  # Step 7 LLM-write path. The stub carries the canonical frontmatter + a
  # planning-intent body the LLM authoring path can overwrite with the richer
  # narrative on the next /gaia-sprint-plan invocation. Idempotent: skip when
  # the file already exists (preserves any LLM-enrichment work done already).
  _plan_dir="${IMPLEMENTATION_ARTIFACTS:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts}/sprint-plan"
  _plan_file="${_plan_dir}/${sprint_id}-plan.md"
  if [ ! -e "$_plan_file" ]; then
    mkdir -p "$_plan_dir" 2>/dev/null || true
    {
      printf -- '---\n'
      printf 'artifact_type: sprint-plan\n'
      printf 'sprint_id: "%s"\n' "$sprint_id"
      printf 'generated_by: sprint-state.sh %s\n' "$init_verb"
      printf 'generated_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ -n "$start_date" ]      && printf 'start_date: "%s"\n' "$start_date"
      [ -n "$end_date" ]        && printf 'end_date: "%s"\n' "$end_date"
      printf -- '---\n\n'
      printf '# Sprint plan: %s\n\n' "$sprint_id"
      printf 'This stub was emitted by `sprint-state.sh %s` so the sprint-plan/\n' "$init_verb"
      printf 'directory has a non-empty entry per the canonical layout. The\n'
      printf '`/gaia-sprint-plan` SKILL.md Step 7 LLM-write path enriches this\n'
      printf 'file with the goals, selected stories, dependency notes, and\n'
      printf 'capacity calculation on the next invocation.\n\n'
      printf '## Goals\n\n_(populated by /gaia-sprint-plan Step 4)_\n\n'
      printf '## Selected stories\n\n_(populated by /gaia-sprint-plan Step 5)_\n\n'
      printf '## Notes\n\n_(populated by /gaia-sprint-plan Step 6)_\n'
    } > "$_plan_file" 2>/dev/null || true
    printf '%s: emitted sprint-plan stub at %s\n' "$init_verb" "$_plan_file" >&2
  fi
}

# cmd_get_goals — read goals[] from sprint-status.yaml and emit verbatim.
# Backward-compatible: missing goals: key → empty stdout, exit 0.
cmd_get_goals() {
  local sprint_id="$1"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "get-goals: yaml not readable: $yaml"
  # Parse the top-level goals: list. Line-based extraction (no yaml lib).
  awk '
    /^goals:[[:space:]]*$/ { in_goals=1; next }
    in_goals && /^[[:space:]]*-[[:space:]]/ {
      # Strip leading "  - ", optional surrounding quotes
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      sub(/^"/, "", $0); sub(/"$/, "", $0)
      sub(/^'\''/, "", $0); sub(/'\''$/, "", $0)
      print
      next
    }
    in_goals && /^[^[:space:]]/ { in_goals=0 }
  ' "$yaml"
}

# cmd_set_goals — REPLACE the goals: list with pipe-delimited goals.
# Each goal is capped at 280 chars.
cmd_set_goals() {
  local sprint_id="$1" goals_str="$2"
  local verb="${3:-set-goals}"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "${verb}: yaml not readable: $yaml"
  _assert_sprint_id_matches "$verb" "--sprint" "$sprint_id" "$yaml"
  [ -n "$goals_str" ] || die "${verb}: --goals must be non-empty (pipe-delimited)"
  # Validate each goal: 1..280 chars
  local IFS='|'
  local g
  for g in $goals_str; do
    local len="${#g}"
    if [ "$len" -lt 1 ] || [ "$len" -gt 280 ]; then
      die "set-goals: goal length $len exceeds 280-char limit: $g"
    fi
  done
  IFS=$' \t\n'
  # Build the new goals: block
  local new_block
  new_block="goals:"$'\n'
  IFS='|'
  for g in $goals_str; do
    # Escape internal double quotes by switching to single-quoted literal
    new_block+="  - \"${g//\"/\\\"}\""$'\n'
  done
  IFS=$' \t\n'
  # Replace or insert goals: block. Use python for surgical line-based edit
  # (preserves comments + non-goals fields byte-for-byte).
  python3 - "$yaml" "$new_block" <<'PY'
import sys, re
yaml_path = sys.argv[1]
new_block = sys.argv[2]
text = open(yaml_path).read()
# Find existing goals: block (lines starting with `goals:` followed by
# `  - ...` items, until next top-level key)
lines = text.splitlines(keepends=True)
out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    # Also match the empty-list seed form `goals: []`. The match accepts
    # either an empty-list inline form OR an end-of-line form followed by
    # indented `- ...` items.
    if not replaced and re.match(r'^goals:\s*(\[\s*\]\s*)?$', line):
        # Skip the existing block: the goals: line + every following `  - ...` line
        i += 1
        while i < len(lines) and re.match(r'^\s*-\s', lines[i]):
            i += 1
        # Insert new block
        out.append(new_block)
        replaced = True
        continue
    out.append(line)
    i += 1
if not replaced:
    # No existing goals: key. Insert before stories: if present, else append.
    new_out = []
    inserted = False
    for line in out:
        if not inserted and re.match(r'^stories:\s*$', line):
            new_out.append(new_block)
            inserted = True
        new_out.append(line)
    if not inserted:
        new_out.append(new_block)
    out = new_out
import os, stat, tempfile
orig_mode = stat.S_IMODE(os.stat(yaml_path).st_mode)
fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(yaml_path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(''.join(out))
os.chmod(tmp_path, orig_mode)
os.replace(tmp_path, yaml_path)
PY
}

# cmd_update_goals — alias for set-goals (REPLACES, does not append).
cmd_update_goals() {
  cmd_set_goals "$1" "$2" "update-goals"
}

# cmd_set_shape — Set the optional `sprint_shape:` field on sprint-status.yaml.
# Enum values: `thrust` (default; not normally written — absence implies thrust)
# or `completion-pass`. Used by the rubric evaluator to scale the
# incidental-goal floor.
cmd_set_shape() {
  local sprint_id="$1" shape="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "set-shape: yaml not readable: $yaml"
  _assert_sprint_id_matches "set-shape" "--sprint" "$sprint_id" "$yaml"
  case "$shape" in
    thrust|completion-pass) ;;
    *) die "sprint_shape must be one of: thrust, completion-pass — got: $shape" ;;
  esac
  # Boundary-write pattern: write to a sibling tempfile, then mv into place
  # atomically. Closes the crash-safety gap on direct truncate+write.
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX")
  python3 - "$yaml" "$tmp" "$shape" <<'PY'
import sys, re
yaml_path = sys.argv[1]
tmp_path = sys.argv[2]
shape = sys.argv[3]
text = open(yaml_path).read()
new_line = f"sprint_shape: {shape}\n"
lines = text.splitlines(keepends=True)
out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    if not replaced and re.match(r'^sprint_shape:\s', line):
        out.append(new_line)
        replaced = True
        i += 1
        continue
    out.append(line)
    i += 1
if not replaced:
    new_out = []
    inserted = False
    for line in out:
        if not inserted and re.match(r'^stories:\s*$', line):
            new_out.append(new_line)
            inserted = True
        new_out.append(line)
    if not inserted:
        new_out.append(new_line)
    out = new_out
with open(tmp_path, 'w') as f:
    f.write(''.join(out))
PY
  mv -f "$tmp" "$yaml"
}

# Helper: read top-level `status:` from the active-sprint yaml.
_yaml_sprint_status() {
  local yaml="$1"
  # Strip leading `status:` prefix, trailing whitespace, AND surrounding
  # double/single quotes — quoted YAML values like `status: "active"` must
  # return `active`, not `"active"`, to avoid silent case-match failures.
  awk '/^status:[[:space:]]*/ {
    sub(/^status:[[:space:]]*/, "");
    sub(/[[:space:]]+$/, "");
    gsub(/^["'\'']|["'\'']$/, "");
    print; exit
  }' "$yaml"
}

# Helper: check whether ALL stories in the yaml have status: done.
_yaml_all_stories_done() {
  local yaml="$1"
  # List all story statuses under stories:; non-done ones short-circuit.
  awk '
    /^stories:[[:space:]]*$/ { in_stories=1; saw_stories=1; next }
    /^items:[[:space:]]*$/ && !saw_stories { in_stories=1; next }
    in_stories && /^[[:space:]]+status:[[:space:]]*/ {
      sub(/^[[:space:]]+status:[[:space:]]*/, "")
      gsub(/"/, ""); gsub(/[[:space:]]+$/, "")
      print
    }
    in_stories && /^[^[:space:]]/ { in_stories=0 }
  ' "$yaml"
}

# cmd_transition_sprint — sprint-level state-machine transitions. Edges:
#   active → review        (gated on all-stories-done)
#   review → closed
#   review → correction
#   correction → active
# Any other edge refuses.
cmd_transition_sprint() {
  local sprint_id="$1" target="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "transition --sprint: yaml not readable: $yaml"
  _assert_sprint_id_matches "transition" "--sprint" "$sprint_id" "$yaml" 2
  local current
  current="$(_yaml_sprint_status "$yaml")"
  [ -n "$current" ] || die "transition --sprint: cannot read current status from $yaml"

  # Validate edge. Edges: planned → active → review → closed; the
  # planned → active edge is unconditional here.
  local legal=0
  case "${current}→${target}" in
    "planned→active"|"active→review"|"review→closed"|"review→correction"|"correction→active")
      legal=1 ;;
  esac
  if [ "$legal" -ne 1 ]; then
    printf '%s: illegal sprint-level transition: %s→%s\n' "$SCRIPT_NAME" "$current" "$target" >&2
    return 1
  fi

  # Activation guard: planned → active (a new activation).
  # correction → active is NOT a new activation — skip guard and last-activated.
  if [ "$current" = "planned" ] && [ "$target" = "active" ] && _is_concurrent_mode; then
    local state_dir
    state_dir="$(dirname "$yaml")"
    local max_conc
    max_conc="$(_read_max_concurrent_active)"

    # Count active sprints from per-sprint files.
    local _guard_ids=""
    local _gf
    for _gf in "${state_dir}"/sprint-status-*.yaml; do
      [ -f "$_gf" ] || continue
      case "$_gf" in *.lock|*.result) continue ;; esac
      local _gst=""
      _gst="$(_yaml_sprint_status "$_gf" 2>/dev/null || true)"
      if [ "$_gst" = "active" ]; then
        local _gsid=""
        _gsid="$(read_yaml_sprint_id "$_gf" 2>/dev/null || true)"
        _guard_ids="${_guard_ids}${_guard_ids:+$'\n'}${_gsid}"
      fi
    done

    if ! printf '%s\n' "$_guard_ids" | concurrent_sprint_guard "$max_conc" 2>&1; then
      return 1
    fi
  fi

  # Gate: review → closed requires a Val sentinel proving /gaia-sprint-review ran.
  # Closing a `review`-status sprint MUST verify the sprint-review Val sentinel
  # (either the dispatch sentinel `sprint-review-{id}-val-dispatched.json` OR
  # the envelope sentinel `val-envelope-<sha>.json` keyed off the sprint id),
  # and REFUSE with "run /gaia-sprint-review first" on a missing sentinel.
  # This check is folded into the transition primitive so any caller is refused
  # uniformly. Escape hatch: `GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1`
  # for the documented /gaia-correct-course bypass.
  if [ "$current" = "review" ] && [ "$target" = "closed" ] \
     && [ "${GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL:-0}" != "1" ]; then
    local _ckpt_dir="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory/checkpoints"
    local _dispatch_sentinel="${_ckpt_dir}/sprint-review-${sprint_id}-val-dispatched.json"
    local _envelope_glob="${_ckpt_dir}/val-envelope-*.json"
    local _found=0
    if [ -f "$_dispatch_sentinel" ]; then
      _found=1
    else
      # E87 envelope sentinel: any val-envelope-<hash>.json whose
      # artifact_path matches the sprint id satisfies the gate.
      for _env in $_envelope_glob; do
        [ -f "$_env" ] || continue
        if grep -F "\"artifact_path\":\"${sprint_id}\"" "$_env" >/dev/null 2>&1; then
          _found=1
          break
        fi
      done
    fi
    if [ "$_found" -ne 1 ]; then
      printf '%s: refuse review→closed for sprint %s: no Val sentinel at %s (run /gaia-sprint-review first, OR set GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1 for the documented bypass)\n' \
        "$SCRIPT_NAME" "$sprint_id" "$_dispatch_sentinel" >&2
      return 1
    fi
  fi

  # Gate: active → review requires ALL stories done
  if [ "$current" = "active" ] && [ "$target" = "review" ]; then
    local non_done_keys=""
    local non_done_count=0
    # Read story keys + statuses
    while IFS='|' read -r k s; do
      [ -n "$k" ] || continue
      if [ "$s" != "done" ]; then
        non_done_keys+="${non_done_keys:+, }${k}"
        non_done_count=$((non_done_count + 1))
      fi
    done < <(awk '
      /^stories:[[:space:]]*$/ { in_stories=1; saw_stories=1; next }
      /^items:[[:space:]]*$/ && !saw_stories { in_stories=1; next }
      in_stories && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
        sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "")
        gsub(/"/, "")
        cur_key=$0
        next
      }
      in_stories && /^[[:space:]]+status:[[:space:]]*/ {
        sub(/^[[:space:]]+status:[[:space:]]*/, "")
        gsub(/"/, "")
        printf "%s|%s\n", cur_key, $0
        next
      }
      in_stories && /^[^[:space:]]/ { in_stories=0 }
    ' "$yaml")
    if [ "$non_done_count" -gt 0 ]; then
      printf '%s: refuse active→review: %d sprint stories are non-done (%s)\n' \
        "$SCRIPT_NAME" "$non_done_count" "$non_done_keys" >&2
      return 1
    fi
  fi

  # Write new status — atomic rewrite via mktemp → awk → mv. Register in
  # _GAIA_TMP_PATHS for trap-based cleanup; fallback to mktemp -t when the
  # sibling template is rejected on stricter GNU mktemp implementations.
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX" 2>/dev/null || mktemp -t sprint-state-yaml.XXXXXX)
  _GAIA_TMP_PATHS+=("$tmp")
  local _tmp_idx
  _tmp_idx=$((${#_GAIA_TMP_PATHS[@]} - 1))
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk -v new="$target" '
    !done_replace && /^status:[[:space:]]*/ {
      print "status: " new
      done_replace=1
      next
    }
    { print }
  ' "$yaml" > "$tmp"
  mv "$tmp" "$yaml"
  _GAIA_TMP_PATHS[$_tmp_idx]=""

  # Concurrent-mode hooks after a successful write.
  if _is_concurrent_mode; then
    local _t_state_dir
    _t_state_dir="$(dirname "$yaml")"

    # planned → active: update last-activated and rewrite proxy.
    # correction → active: NOT a new activation — skip both.
    if [ "$current" = "planned" ] && [ "$target" = "active" ]; then
      _write_last_activated "$_t_state_dir" "$sprint_id"
      _update_compatibility_proxy "$_t_state_dir" "$sprint_id" "$yaml"
    fi

    # Check for reverse migration on any mutating call.
    _maybe_reverse_migration "$_t_state_dir" || true
  fi

  # Emit a sprint-level lifecycle event directly via lifecycle-event.sh.
  # The emit_lifecycle_event() helper is story-scoped — sprint-level
  # transitions need a different payload shape so we call the helper directly.
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  if [ -x "$lifecycle_sh" ]; then
    local data
    data=$(printf '{"sprint_id":"%s","from":"%s","to":"%s"}' "$sprint_id" "$current" "$target")
    "$lifecycle_sh" \
      --type sprint_transitioned \
      --workflow sprint-state \
      --story "$sprint_id" \
      --data "$data" >/dev/null 2>&1 || true
  fi
}

# ---------- Close writer ----------
#
# cmd_close — close a sprint via the two-phase protocol (concurrent mode)
# or the single-file atomic write (single-sprint mode).
#
# Arguments (passed from close.sh):
#   --sprint <sprint_id>        target sprint
#   --closed-at <iso>           timestamp for closed_at
#   --force                     sentinel bypass flag
#   --rollover-keys <csv>       comma-separated rollover keys (may be empty)
#   --pre-close-status <state>  the sprint's status before close (review|active)
#   --resume                    resume a closed-but-no-archive sprint
#
# Exit codes:
#   0 — success (or already closed)
#   1 — internal error
#   2 — sprint-id mismatch or transition refusal
#   3 — lifecycle lock timeout / close in progress
#   4 — symlink detected (strict mode)
#   5 — identity mismatch (strict mode)

# Helper: check if a closing marker's owner pid is alive.
_closing_marker_owner_alive() {
  local marker_file="$1"
  [ -f "$marker_file" ] || return 1
  local owner_pid=""
  owner_pid="$(awk -F= '/^owner_pid=/ { print $2 }' "$marker_file" 2>/dev/null)" || return 1
  [ -n "$owner_pid" ] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

# Helper: read the sprint id from a closing marker.
_closing_marker_sprint_id() {
  local marker_file="$1"
  awk -F= '/^sprint_id=/ { print $2 }' "$marker_file" 2>/dev/null
}

# Helper: write a closing marker atomically.
_write_closing_marker() {
  local marker_file="$1" sprint_id="$2"
  local tmp
  tmp="$(mktemp "${marker_file}.XXXXXX")"
  printf 'sprint_id=%s\nowner_pid=%d\nstart_time=%s\n' \
    "$sprint_id" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  mv "$tmp" "$marker_file"
}

# Helper: closing marker path for a sprint.
_closing_marker_path() {
  local state_dir="$1" sprint_id="$2"
  printf '%s/.sprint-closing-%s' "$state_dir" "$sprint_id"
}

# Helper: holder sidecar path.
_holder_sidecar_path() {
  local state_dir="$1"
  printf '%s/.sprint-lifecycle.holder' "$state_dir"
}

# Helper: read stories from a yaml file and report non-done ones.
# Outputs key=status for non-done stories, one per line.
_close_non_done_stories() {
  local yaml="$1"
  awk '
    /^stories:[[:space:]]*$/ { in_stories=1; saw_stories=1; next }
    /^items:[[:space:]]*$/ && !saw_stories { in_stories=1; next }
    in_stories && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "")
      gsub(/"/, ""); gsub(/'\''/, "")
      cur_key=$0
      next
    }
    in_stories && /^[[:space:]]+status:[[:space:]]*/ {
      sub(/^[[:space:]]+status:[[:space:]]*/, "")
      gsub(/"/, ""); gsub(/'\''/, ""); gsub(/[[:space:]]+$/, "")
      if ($0 != "done") printf "%s=%s\n", cur_key, $0
      next
    }
    in_stories && /^[^[:space:]]/ { in_stories=0 }
  ' "$yaml"
}

# Helper: emit a sprint_transitioned lifecycle event (same shape as
# cmd_transition_sprint). Only called for review-to-closed with a sentinel.
_close_emit_sprint_transitioned() {
  local sprint_id="$1" from_status="$2"
  local lifecycle_sh="${SPRINT_STATE_SCRIPT_DIR}/lifecycle-event.sh"
  [ -x "$lifecycle_sh" ] || return 0
  local data
  data=$(printf '{"sprint_id":"%s","from":"%s","to":"closed"}' "$sprint_id" "$from_status")
  "$lifecycle_sh" \
    --type sprint_transitioned \
    --workflow sprint-state \
    --story "$sprint_id" \
    --data "$data" >/dev/null 2>&1 || true
}

# The close writer entry point.
cmd_close() {
  local sprint_id="" closed_at="" force_bypass=0 rollover_keys_csv=""
  local pre_close_status="" resume_mode=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint)     [ $# -ge 2 ] || die "close: --sprint requires a value"; sprint_id="$2"; shift 2 ;;
      --sprint=*)   sprint_id="${1#--sprint=}"; shift ;;
      --closed-at)  [ $# -ge 2 ] || die "close: --closed-at requires a value"; closed_at="$2"; shift 2 ;;
      --closed-at=*) closed_at="${1#--closed-at=}"; shift ;;
      --force)      force_bypass=1; shift ;;
      --rollover-keys) [ $# -ge 2 ] || die "close: --rollover-keys requires a value"; rollover_keys_csv="$2"; shift 2 ;;
      --rollover-keys=*) rollover_keys_csv="${1#--rollover-keys=}"; shift ;;
      --pre-close-status) [ $# -ge 2 ] || die "close: --pre-close-status requires a value"; pre_close_status="$2"; shift 2 ;;
      --pre-close-status=*) pre_close_status="${1#--pre-close-status=}"; shift ;;
      --resume)     resume_mode=1; shift ;;
      *) die "close: unknown flag: $1" ;;
    esac
  done
  [ -n "$sprint_id" ] || die "close: --sprint is required"
  [ -n "$closed_at" ] || die "close: --closed-at is required"

  local state_dir
  state_dir="$(dirname "$SPRINT_STATUS_YAML")"
  local max_conc
  max_conc="$(_read_max_concurrent_active)"

  # Determine mode: concurrent or single-sprint.
  local _close_rc=0
  if acquire_lock_is_concurrent_mode "$max_conc" "$state_dir"; then
    _cmd_close_concurrent "$sprint_id" "$closed_at" "$force_bypass" \
      "$rollover_keys_csv" "$pre_close_status" "$resume_mode" "$state_dir" || _close_rc=$?
  else
    _cmd_close_single "$sprint_id" "$closed_at" "$force_bypass" \
      "$rollover_keys_csv" "$pre_close_status" "$state_dir" || _close_rc=$?
  fi
  return "$_close_rc"
}

# Single-sprint close writer. Output- and state-byte-identical to today.
_cmd_close_single() {
  local sprint_id="$1" closed_at="$2" force_bypass="$3"
  local rollover_keys_csv="$4" pre_close_status="$5" state_dir="$6"

  local yaml="$SPRINT_STATUS_YAML"
  [ -f "$yaml" ] || die "close: state file not found: $yaml"

  # Already-closed short-circuit — exit 0 regardless of archive presence.
  local current
  current="$(_yaml_sprint_status "$yaml")"
  if [ "$current" = "closed" ]; then
    printf '%s: sprint %s already closed\n' "$SCRIPT_NAME" "$sprint_id"
    return 0
  fi

  # Validate the sprint id matches.
  _assert_sprint_id_matches "close" "--sprint" "$sprint_id" "$yaml" 2

  # Lifecycle event (four edges per R52): same logic as the concurrent path.
  local should_emit_event=0
  if [ "$current" = "review" ]; then
    if [ "$force_bypass" -eq 0 ]; then
      should_emit_event=1
    elif [ "${GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL:-0}" = "1" ]; then
      should_emit_event=1
    fi
  fi

  # Take L1 (per-sprint state lock) and write atomically.
  (
    if ! acquire_lock "$SPRINT_STATUS_LOCK" "$GAIA_LOCK_L1_TIMEOUT" 9; then
      die "close: lock timeout acquiring $SPRINT_STATUS_LOCK"
    fi
    trap 'release_lock 9 2>/dev/null || true' EXIT
    trap 'release_lock 9 2>/dev/null || true; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; exit 143' TERM

    # Re-read status under lock.
    local locked_status
    locked_status="$(_yaml_sprint_status "$yaml")"
    if [ "$locked_status" = "closed" ]; then
      printf '%s: sprint %s already closed\n' "$SCRIPT_NAME" "$sprint_id"
      return 0
    fi

    # Atomic status + closed_at write via mktemp + awk + mv.
    local tmp
    tmp=$(mktemp "${yaml}.tmp.XXXXXX" 2>/dev/null || mktemp -t sprint-close-yaml.XXXXXX)
    _GAIA_TMP_PATHS+=("$tmp")
    trap "rm -f '$tmp'" RETURN

    awk -v closed_at="$closed_at" '
      !done_status && /^status:[[:space:]]*/ {
        print "status: closed"
        done_status=1
        next
      }
      /^closed_at:[[:space:]]*/ { next }
      { print }
      END {
        if (!done_status) printf "status: closed\n"
        printf "closed_at: \"%s\"\n", closed_at
      }
    ' "$yaml" > "$tmp"
    mv "$tmp" "$yaml"
    _GAIA_TMP_PATHS[${#_GAIA_TMP_PATHS[@]}-1]=""
    trap - RETURN

    # Post-close audit (same in both modes).
    _close_post_audit "$yaml" "$sprint_id" "$pre_close_status" "$rollover_keys_csv"
  ) || return $?

  # Emit lifecycle event after lock release.
  if [ "$should_emit_event" -eq 1 ]; then
    _close_emit_sprint_transitioned "$sprint_id" "$current"
  fi

  printf '%s: sprint %s closed at %s\n' "$SCRIPT_NAME" "$sprint_id" "$closed_at"
}

# Concurrent close writer — two-phase protocol.
_cmd_close_concurrent() {
  local sprint_id="$1" closed_at="$2" force_bypass="$3"
  local rollover_keys_csv="$4" pre_close_status="$5"
  local resume_mode="$6" state_dir="$7"

  # Validate sprint id format.
  _validate_sprint_id "$sprint_id" || die "close: invalid sprint id: $sprint_id"

  local per_sprint_yaml
  per_sprint_yaml="$(_sprint_file_path "$state_dir" "$sprint_id")"
  [ -f "$per_sprint_yaml" ] || die "close: per-sprint state file not found: $per_sprint_yaml"

  # Validate the sprint id matches the file contents.
  _assert_sprint_id_matches "close" "--sprint" "$sprint_id" "$per_sprint_yaml" 2

  local marker_file
  marker_file="$(_closing_marker_path "$state_dir" "$sprint_id")"
  local sidecar_file
  sidecar_file="$(_holder_sidecar_path "$state_dir")"
  local l4_path="${state_dir}/${GAIA_LOCK_L4_PATH}"
  local l1_path="${per_sprint_yaml}.lock"

  # Resume path: sprint already closed but archive missing.
  if [ "$resume_mode" -eq 1 ]; then
    _cmd_close_resume "$sprint_id" "$per_sprint_yaml" "$marker_file" \
      "$state_dir" "$l1_path"
    return $?
  fi

  # Already-closed check (before locking).
  local current
  current="$(_yaml_sprint_status "$per_sprint_yaml")"
  if [ "$current" = "closed" ]; then
    printf '%s: sprint %s already closed\n' "$SCRIPT_NAME" "$sprint_id"
    return 0
  fi

  # Lifecycle event decision (four edges per R52):
  # 1. review-to-closed with sentinel => emit (close.sh verified it)
  # 2. review-to-closed with bypass env => emit
  # 3. --force without sentinel and bypass unset => no event
  # 4. active-to-closed => no event
  # close.sh's --force flag means sentinel was missing; emit only if
  # the bypass env is also set.
  local should_emit_event=0
  if [ "$current" = "review" ]; then
    if [ "$force_bypass" -eq 0 ]; then
      # Sentinel was present (close.sh verified it in Step 3a).
      should_emit_event=1
    elif [ "${GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL:-0}" = "1" ]; then
      # --force with bypass env set (edge 2).
      should_emit_event=1
    fi
    # --force with bypass unset (edge 3): no event.
  fi

  # --- Phase A: acquire L4, write closing marker and holder sidecar ---
  local phase_a_rc=0
  (
    printf '%s: waiting for lifecycle lock\n' "$SCRIPT_NAME" >&2
    local _lock_rc=0
    acquire_lock "$l4_path" "$GAIA_LOCK_L4_TIMEOUT" 8 --strict || _lock_rc=$?
    if [ "$_lock_rc" -ne 0 ]; then
      # Read holder sidecar or marker for the diagnostic.
      local _blocking_id="another sprint"
      if [ -f "$sidecar_file" ]; then
        _blocking_id="$(cat "$sidecar_file" 2>/dev/null | tr -d '\n')" || _blocking_id="another sprint"
      else
        # Try closing markers.
        local _m
        for _m in "${state_dir}"/.sprint-closing-*; do
          [ -f "$_m" ] || continue
          _blocking_id="$(_closing_marker_sprint_id "$_m")" || _blocking_id="another sprint"
          break
        done
      fi
      [ -n "$_blocking_id" ] || _blocking_id="another sprint"
      printf 'sprint close in progress (sprint %s) -- retry\n' "$_blocking_id" >&2
      exit "$_lock_rc"
    fi
    printf '%s: acquired lifecycle lock\n' "$SCRIPT_NAME" >&2
    trap 'rm -f "$sidecar_file" 2>/dev/null; release_lock 8 2>/dev/null || true' EXIT
    trap 'rm -f "$sidecar_file" 2>/dev/null; release_lock 8 2>/dev/null || true; exit 130' INT
    trap 'rm -f "$sidecar_file" 2>/dev/null; release_lock 8 2>/dev/null || true; exit 143' TERM

    # Check for existing closing marker for the same sprint.
    if [ -f "$marker_file" ]; then
      if _closing_marker_owner_alive "$marker_file"; then
        # Live-owner marker — another close is in flight.
        printf 'sprint close in progress (sprint %s) -- retry\n' "$sprint_id" >&2
        exit "$ACQUIRE_LOCK_EXIT_TIMEOUT"
      fi
      # Dead-owner (stale) marker — replace it.
    fi

    # Write holder sidecar (visible to waiters while L4 is held).
    printf '%s' "$sprint_id" > "$sidecar_file"

    # Write closing marker.
    _write_closing_marker "$marker_file" "$sprint_id"

    # Test-only pause seam: when set, touch the named file as a ready
    # signal and wait for the file to be removed (poll). Inert when unset.
    if [ -n "${_GAIA_CLOSE_PAUSE_PHASE_A:-}" ]; then
      touch "$_GAIA_CLOSE_PAUSE_PHASE_A"
      while [ -f "$_GAIA_CLOSE_PAUSE_PHASE_A" ]; do sleep 1; done
    fi

    # Remove holder sidecar before releasing L4.
    rm -f "$sidecar_file"
  ) || phase_a_rc=$?

  if [ "$phase_a_rc" -ne 0 ]; then
    return "$phase_a_rc"
  fi

  # --- Phase B: acquire L1, write status + closed_at ---
  local phase_b_rc=0
  (
    if ! acquire_lock "$l1_path" "$GAIA_LOCK_L1_TIMEOUT" 9; then
      die "close: lock timeout acquiring per-sprint lock $l1_path"
    fi
    trap 'release_lock 9 2>/dev/null || true' EXIT
    trap 'release_lock 9 2>/dev/null || true; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; exit 143' TERM

    # Re-read status under L1.
    local locked_status
    locked_status="$(_yaml_sprint_status "$per_sprint_yaml")"
    if [ "$locked_status" = "closed" ]; then
      printf '%s: sprint %s already closed\n' "$SCRIPT_NAME" "$sprint_id"
      return 0
    fi

    # Re-run all-done check with rollover exemption.
    local non_done
    non_done="$(_close_non_done_stories "$per_sprint_yaml")"
    if [ -n "$non_done" ]; then
      # Filter out rollover keys.
      local filtered=""
      local line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        local k="${line%%=*}"
        local is_rollover=0
        if [ -n "$rollover_keys_csv" ]; then
          local rk
          IFS=',' read -r -a _rk_arr <<< "$rollover_keys_csv"
          for rk in "${_rk_arr[@]}"; do
            if [ "$k" = "$rk" ]; then
              is_rollover=1
              break
            fi
          done
        fi
        if [ "$is_rollover" -eq 0 ]; then
          filtered="${filtered}${filtered:+$'\n'}${line}"
        fi
      done <<< "$non_done"

      if [ -n "$filtered" ]; then
        printf '%s: close aborted — non-done stories found after marker: %s\n' \
          "$SCRIPT_NAME" "$filtered" >&2
        return 1
      fi
    fi

    # Atomic write: status + closed_at + close inputs.
    local tmp
    tmp=$(mktemp "${per_sprint_yaml}.tmp.XXXXXX" 2>/dev/null || mktemp -t sprint-close-yaml.XXXXXX)
    _GAIA_TMP_PATHS+=("$tmp")
    trap "rm -f '$tmp'" RETURN

    awk -v closed_at="$closed_at" -v force_bypass="$force_bypass" \
        -v rollover_keys="$rollover_keys_csv" '
      !done_status && /^status:[[:space:]]*/ {
        print "status: closed"
        done_status=1
        next
      }
      /^closed_at:[[:space:]]*/ { next }
      /^close_inputs:/ { in_ci=1; next }
      in_ci && /^[[:space:]]/ { next }
      in_ci && /^[^[:space:]]/ { in_ci=0 }
      { print }
      END {
        printf "closed_at: \"%s\"\n", closed_at
        printf "close_inputs:\n"
        printf "  force_bypass: %s\n", force_bypass
        printf "  rollover_keys: \"%s\"\n", rollover_keys
        printf "  closed_at: \"%s\"\n", closed_at
      }
    ' "$per_sprint_yaml" > "$tmp"
    mv "$tmp" "$per_sprint_yaml"
    _GAIA_TMP_PATHS[${#_GAIA_TMP_PATHS[@]}-1]=""
    trap - RETURN

    # Test-only pause seam: when set, touch the named file as a ready
    # signal and wait for the file to be removed (poll). Inert when unset.
    if [ -n "${_GAIA_CLOSE_PAUSE_PHASE_B:-}" ]; then
      touch "$_GAIA_CLOSE_PAUSE_PHASE_B"
      while [ -f "$_GAIA_CLOSE_PAUSE_PHASE_B" ]; do sleep 1; done
    fi

    # Test-only injection seam: when set, source the named script after the
    # status write but before the audit. Used to inject a non-done story so
    # the post-close audit exercises its rollback path. Inert when unset.
    if [ -n "${_GAIA_CLOSE_INJECT_AFTER_WRITE:-}" ] && [ -f "${_GAIA_CLOSE_INJECT_AFTER_WRITE}" ]; then
      bash "${_GAIA_CLOSE_INJECT_AFTER_WRITE}" "$per_sprint_yaml"
    fi

    # Post-close audit.
    _close_post_audit "$per_sprint_yaml" "$sprint_id" "$pre_close_status" "$rollover_keys_csv"
  ) || phase_b_rc=$?

  # Remove closing marker (owning process only).
  rm -f "$marker_file"

  if [ "$phase_b_rc" -ne 0 ]; then
    return "$phase_b_rc"
  fi

  # Emit lifecycle event after both L4 and L1 are released.
  if [ "$should_emit_event" -eq 1 ]; then
    _close_emit_sprint_transitioned "$sprint_id" "$current"
  fi

  # Proxy post-write hook: update proxy when the closed sprint is last-activated.
  local last_activated=""
  last_activated="$(_read_last_activated "$state_dir")"
  if [ -n "$last_activated" ] && [ "$last_activated" = "$sprint_id" ]; then
    _update_compatibility_proxy "$state_dir" "$sprint_id" "$per_sprint_yaml"
  fi

  # Snapshot refresh: remove per-sprint cache.
  _close_run_snapshot "$sprint_id"

  printf '%s: sprint %s closed at %s\n' "$SCRIPT_NAME" "$sprint_id" "$closed_at"
}

# Resume path for concurrent mode: sprint is closed but archive is missing.
_cmd_close_resume() {
  local sprint_id="$1" per_sprint_yaml="$2" marker_file="$3"
  local state_dir="$4" l1_path="$5"

  # Verify sprint is actually closed.
  local current
  current="$(_yaml_sprint_status "$per_sprint_yaml")"
  if [ "$current" != "closed" ]; then
    die "close: resume requested but sprint $sprint_id has status $current, not closed"
  fi

  # Check that no live-owner marker exists for this sprint.
  if [ -f "$marker_file" ] && _closing_marker_owner_alive "$marker_file"; then
    printf 'sprint close in progress (sprint %s) -- retry\n' "$sprint_id" >&2
    return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
  fi

  # Clean up stale marker left by a killed close (dead-owner).
  if [ -f "$marker_file" ] && ! _closing_marker_owner_alive "$marker_file"; then
    rm -f "$marker_file"
  fi

  # Read recorded close inputs from the per-sprint state.
  local recorded_closed_at="" recorded_force="" recorded_rollover=""
  recorded_closed_at="$(awk '/^  closed_at:/ { sub(/^  closed_at:[[:space:]]*/, ""); gsub(/"/, ""); print }' "$per_sprint_yaml" 2>/dev/null)" || true
  recorded_force="$(awk '/^  force_bypass:/ { sub(/^  force_bypass:[[:space:]]*/, ""); print }' "$per_sprint_yaml" 2>/dev/null)" || true
  recorded_rollover="$(awk '/^  rollover_keys:/ { sub(/^  rollover_keys:[[:space:]]*/, ""); gsub(/"/, ""); print }' "$per_sprint_yaml" 2>/dev/null)" || true

  # Use recorded values (no sentinel or all-done re-check on resume).
  printf '%s: resuming close for sprint %s (closed_at=%s)\n' \
    "$SCRIPT_NAME" "$sprint_id" "${recorded_closed_at:-$closed_at}" >&2

  # Proxy post-write hook when last-activated.
  local last_activated=""
  last_activated="$(_read_last_activated "$state_dir")"
  if [ -n "$last_activated" ] && [ "$last_activated" = "$sprint_id" ]; then
    _update_compatibility_proxy "$state_dir" "$sprint_id" "$per_sprint_yaml"
  fi

  # Snapshot refresh.
  _close_run_snapshot "$sprint_id"

  printf '%s: sprint %s resume complete\n' "$SCRIPT_NAME" "$sprint_id"
}

# Post-close audit: verify all stories are done (with rollover exemption).
# If a non-exempt non-done story is found, roll back the sprint to its
# pre-close status.
_close_post_audit() {
  local yaml="$1" sprint_id="$2" pre_close_status="$3" rollover_keys_csv="$4"

  local non_done
  non_done="$(_close_non_done_stories "$yaml")"
  [ -n "$non_done" ] || return 0

  # Filter out rollover-exempt stories.
  local filtered=""
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local k="${line%%=*}"
    local is_rollover=0
    if [ -n "$rollover_keys_csv" ]; then
      local rk
      IFS=',' read -r -a _rk_arr <<< "$rollover_keys_csv"
      for rk in "${_rk_arr[@]}"; do
        if [ "$k" = "$rk" ]; then
          is_rollover=1
          break
        fi
      done
    fi
    if [ "$is_rollover" -eq 0 ]; then
      filtered="${filtered}${filtered:+$'\n'}${line}"
    fi
  done <<< "$non_done"

  [ -n "$filtered" ] || return 0

  # Rollback: restore pre-close status.
  local rollback_status="${pre_close_status:-active}"
  local tmp
  tmp=$(mktemp "${yaml}.tmp.XXXXXX" 2>/dev/null || mktemp -t sprint-rollback-yaml.XXXXXX)
  awk -v new_status="$rollback_status" '
    !done_status && /^status:[[:space:]]*/ {
      print "status: " new_status
      done_status=1
      next
    }
    /^closed_at:[[:space:]]*/ { next }
    /^close_inputs:/ { in_ci=1; next }
    in_ci && /^[[:space:]]/ { next }
    in_ci && /^[^[:space:]]/ { in_ci=0 }
    { print }
  ' "$yaml" > "$tmp"
  mv "$tmp" "$yaml"

  printf '%s: post-close audit failed — non-done stories: %s; rolled back to %s\n' \
    "$SCRIPT_NAME" "$filtered" "$rollback_status" >&2
  return 1
}

# Run the snapshot refresh for a closed sprint.
_close_run_snapshot() {
  local sprint_id="$1"
  local snapshot_sh=""
  snapshot_sh="${SPRINT_STATE_SCRIPT_DIR}/sprint-progress-snapshot.sh"
  if [ -x "$snapshot_sh" ]; then
    "$snapshot_sh" --sprint "$sprint_id" >/dev/null 2>&1 || true
  fi
}

# cmd_set_review_justification — write review_justification: block from
# a yaml payload file.
cmd_set_review_justification() {
  local sprint_id="$1" file="$2"
  local yaml
  yaml="$(_resolve_active_yaml)"
  [ -r "$yaml" ] || die "set-review-justification: yaml not readable: $yaml"
  _assert_sprint_id_matches "set-review-justification" "--sprint" "$sprint_id" "$yaml"
  [ -r "$file" ] || die "set-review-justification: payload file not readable: $file"

  # Schema validation via python (single deterministic pass).
  python3 - "$file" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
required = {
    'primary_criterion': r'^primary_criterion:\s*(C1|C2|C3)\s*$',
    'qualifying_story_points': r'^qualifying_story_points:\s*\d+\s*$',
    'total_story_points': r'^total_story_points:\s*\d+\s*$',
    'qualifying_ratio': r'^qualifying_ratio:\s*0\.[8-9]\d*|^qualifying_ratio:\s*1(\.0+)?\s*$',
    'explanation': r'^explanation:\s*',
}
for k, pat in required.items():
    if not re.search(pat, text, re.MULTILINE):
        sys.stderr.write(f'set-review-justification: schema violation — missing or invalid {k}\n')
        sys.exit(1)
# Explanation length 200-1000 chars (heuristic: block-scalar body)
m = re.search(r'explanation:\s*\|?\s*\n((?:\s+.+\n)+)', text)
if m:
    body = ''.join(l.lstrip() for l in m.group(1).splitlines() if l.strip())
    if len(body) < 200 or len(body) > 1000:
        sys.stderr.write(f'set-review-justification: schema violation — explanation length {len(body)} not in [200, 1000]\n')
        sys.exit(1)
sys.exit(0)
PY
  [ $? -eq 0 ] || return 1

  # Append the review_justification block to the yaml (line-based)
  python3 - "$yaml" "$file" <<'PY'
import sys, re
yaml_path, payload_path = sys.argv[1], sys.argv[2]
payload = open(payload_path).read().rstrip() + '\n'
text = open(yaml_path).read()
# Strip any existing review_justification: block
lines = text.splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    if re.match(r'^review_justification:', lines[i]):
        i += 1
        while i < len(lines) and re.match(r'^\s', lines[i]):
            i += 1
        continue
    out.append(lines[i])
    i += 1
# Append new block, ensure trailing newline
if out and not out[-1].endswith('\n'):
    out.append('\n')
out.append('review_justification:\n')
for line in payload.splitlines(keepends=True):
    out.append('  ' + line if line.strip() else line)
import os, stat, tempfile
orig_mode = stat.S_IMODE(os.stat(yaml_path).st_mode)
fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(yaml_path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(''.join(out))
os.chmod(tmp_path, orig_mode)
os.replace(tmp_path, yaml_path)
PY
}

# ============================================================
# set-story-sprint
# ============================================================
#
# Bind a pre-materialized backlog story's `sprint_id:` to a target sprint
# when the story file frontmatter currently carries `sprint_id: null`.
#
# A story materialized via plain `/gaia-create-story` (not `--for-sprint`)
# lands with `sprint_id: null`. The subsequent `sprint-state.sh inject` then
# refuses with `sprint-id mismatch ... refusing to write` because no listed
# verb binds sprint_id without going through the `--for-sprint` path. This
# verb is the sanctioned binder: it rewrites ONLY the `sprint_id:` line in
# the story file's frontmatter (null → "<sprint>"), atomically (mktemp + mv),
# under a per-story flock.
#
# Refuses (exit 1):
#   - story file's current sprint_id is already a non-null value that
#     disagrees with the requested target (operator must explicitly
#     `sprint-state.sh rollover` between sprints).
#   - target sprint does not match the active sprint-status.yaml
#     sprint_id (we will not bind a story to an inactive sprint).
#
# Idempotent — re-running with a story already bound to the target sprint
# is a no-op (exit 0).
#
# Leading-underscore name marks this as an internal helper.
_cmd_set_story_sprint() {
  local story_key="$1" target_sprint="$2"
  [ -n "$story_key" ] || die "set-story-sprint: --story is required"
  [ -n "$target_sprint" ] || die "set-story-sprint: --sprint is required"

  # Resolve the story file via the standard locator.
  locate_story_file "$story_key"
  [ -n "$STORY_FILE" ] && [ -f "$STORY_FILE" ] \
    || die "set-story-sprint: no story file found for key '$story_key'"

  # Verify target sprint matches the active sprint-status.yaml sprint_id.
  # We will not bind to an inactive or absent sprint.
  local yaml_sid
  yaml_sid=$(read_yaml_sprint_id "$SPRINT_STATUS_YAML" 2>/dev/null || true)
  if [ -z "$yaml_sid" ]; then
    die "set-story-sprint: sprint-status.yaml at $SPRINT_STATUS_YAML missing top-level sprint_id — run 'sprint-state.sh init --sprint-id $target_sprint' first"
  fi
  if [ "$yaml_sid" != "$target_sprint" ]; then
    die "set-story-sprint: target sprint '$target_sprint' does not match active sprint-status.yaml sprint_id '$yaml_sid'; refusing to bind"
  fi

  # Read current frontmatter sprint_id.
  local current_sid
  current_sid=$(read_story_frontmatter_field "$STORY_FILE" sprint_id 2>/dev/null || true)

  # Idempotency: already bound to the right sprint.
  if [ "$current_sid" = "$target_sprint" ]; then
    printf '%s: %s already bound to sprint %s — no-op\n' \
      "$SCRIPT_NAME" "$story_key" "$target_sprint"
    return 0
  fi

  # Safety: refuse to silently retarget a story bound to a different sprint.
  # The `rollover` verb is the sanctioned cross-sprint mover.
  case "$current_sid" in
    ""|"null")
      : ;; # bindable
    *)
      die "set-story-sprint: $story_key already bound to sprint '$current_sid'; use 'sprint-state.sh rollover --from $current_sid --keys $story_key' to move between sprints"
      ;;
  esac

  # Acquire a per-story lock and rewrite ONLY the sprint_id: line.
  local lock_file="${STORY_FILE}.set-sprint.lock"

  _rewrite_sprint_id() {
    local tmp
    tmp=$(mktemp "${STORY_FILE}.XXXXXX") || return 1
    awk -v to="$target_sprint" '
      BEGIN { in_fm = 0; rewritten = 0 }
      /^---[[:space:]]*$/ {
        if (in_fm == 0) { in_fm = 1; print; next }
        else { in_fm = 2; print; next }
      }
      {
        if (in_fm == 1 && rewritten == 0 && $0 ~ /^sprint_id:[[:space:]]*(null|"")?[[:space:]]*$/) {
          print "sprint_id: \"" to "\""
          rewritten = 1
          next
        }
        print
      }
    ' "$STORY_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Sanity check: confirm rewrite landed.
    if ! grep -q "^sprint_id:[[:space:]]*\"$target_sprint\"" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi

    mv -f "$tmp" "$STORY_FILE" || { rm -f "$tmp"; return 1; }
    return 0
  }

  local rc=0
  set +e
  (
    if ! acquire_lock "$lock_file" 5 9; then
      die "lock timeout acquiring $lock_file"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM
    _rewrite_sprint_id
  )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    die "set-story-sprint: failed to rewrite sprint_id in $STORY_FILE"
  fi

  printf '%s: %s sprint_id bound to %s\n' \
    "$SCRIPT_NAME" "$story_key" "$target_sprint"
}

# _cmd_set_story_sprint_clear — clear a story's sprint_id to null.
# Used when returning a story to the backlog (no sprint can accept it).
# Bypasses the sprint-mismatch guard, already-bound guard, and dispatch
# --sprint required check. In concurrent mode, takes L1 of the story's
# current sprint to remove it from the per-sprint state file.
_cmd_set_story_sprint_clear() {
  local story_key="$1"
  [ -n "$story_key" ] || die "set-story-sprint --clear: --story is required"

  # Resolve the story file.
  locate_story_file "$story_key"
  [ -n "$STORY_FILE" ] && [ -f "$STORY_FILE" ] \
    || die "set-story-sprint --clear: no story file found for key '$story_key'"

  # Read current frontmatter sprint_id.
  local current_sid
  current_sid=$(read_story_frontmatter_field "$STORY_FILE" sprint_id 2>/dev/null || true)

  # Idempotency: already null.
  case "$current_sid" in
    ""|"null")
      printf '%s: %s sprint_id already null — no-op\n' "$SCRIPT_NAME" "$story_key"
      return 0
      ;;
  esac

  # In concurrent mode, remove the story from its current sprint's state file.
  if _is_concurrent_mode && [ -n "$current_sid" ]; then
    local state_dir
    state_dir="$(dirname "${SPRINT_STATUS_YAML:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml}")"
    local cur_yaml
    cur_yaml="$(_sprint_file_path "$state_dir" "$current_sid")"
    if [ -f "$cur_yaml" ]; then
      local cur_lock="${cur_yaml}.lock"
      (
        if ! acquire_lock "$cur_lock" 5 9; then
          die "set-story-sprint --clear: lock timeout acquiring $cur_lock"
        fi
        trap 'release_lock 9 2>/dev/null || true' EXIT
        trap 'release_lock 9 2>/dev/null || true; exit 130' INT
        trap 'release_lock 9 2>/dev/null || true; exit 143' TERM
        _remove_story_from_yaml "$cur_yaml" "$story_key"
      ) || die "set-story-sprint --clear: failed to remove $story_key from $cur_yaml"
    fi
  fi

  # Rewrite sprint_id to null in the story file.
  local lock_file="${STORY_FILE}.set-sprint.lock"
  local rc=0
  set +e
  (
    if ! acquire_lock "$lock_file" 5 9; then
      die "set-story-sprint --clear: lock timeout acquiring $lock_file"
    fi
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps' EXIT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 130' INT
    trap 'release_lock 9 2>/dev/null || true; _cleanup_tmps; exit 143' TERM

    local tmp
    tmp=$(mktemp "${STORY_FILE}.XXXXXX") || exit 1
    awk '
      BEGIN { in_fm = 0; rewritten = 0 }
      /^---[[:space:]]*$/ {
        if (in_fm == 0) { in_fm = 1; print; next }
        else { in_fm = 2; print; next }
      }
      {
        if (in_fm == 1 && rewritten == 0 && $0 ~ /^sprint_id:/) {
          print "sprint_id: null"
          rewritten = 1
          next
        }
        print
      }
    ' "$STORY_FILE" > "$tmp" || { rm -f "$tmp"; exit 1; }

    if ! grep -q '^sprint_id:[[:space:]]*null' "$tmp"; then
      rm -f "$tmp"; exit 1
    fi

    mv -f "$tmp" "$STORY_FILE" || { rm -f "$tmp"; exit 1; }
  )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    die "set-story-sprint --clear: failed to rewrite sprint_id in $STORY_FILE"
  fi

  printf '%s: %s sprint_id cleared to null\n' "$SCRIPT_NAME" "$story_key"
}

# ---------- Argument parsing ----------

main() {
  local subcmd="${1:-}"
  if [ -z "$subcmd" ]; then
    usage >&2
    exit 1
  fi
  shift || true

  case "$subcmd" in
    --help|-h)
      usage
      exit 0
      ;;
    init|advance|transition|inject|get|validate|reconcile|lint-dependencies|record-escalation-override|detect-auto-close|rollover|get-goals|set-goals|update-goals|set-review-justification|set-shape|set-story-sprint|set-phase|resolve-file|close)
      ;;
    *)
      printf '%s: error: unknown subcommand: %s\n' "$SCRIPT_NAME" "$subcmd" >&2
      usage >&2
      exit 1
      ;;
  esac

  local story_key="" to_state=""
  local reconcile_sprint_id="" reconcile_dry_run=0
  local lint_format="json" lint_sprint_id=""
  local override_item_ids="" override_user="" override_reason=""
  local rollover_from="" rollover_keys=""
  # Sprint-level subcommands (get-goals / set-goals / update-goals /
  # set-review-justification + transition --sprint).
  # set-shape subcommand for sprint_shape modifier (thrust | completion-pass).
  local goals_arg="" justification_file="" shape_arg=""
  # Optional execution phase. _GAIA_PHASE_FLAG_SEEN discriminates "--phase
  # omitted" from "--phase given an empty value" (the deliberate clear form)
  # — the two are indistinguishable by value alone. MUST be initialised here:
  # under `set -u` an undeclared reference in the set-phase dispatch arm
  # would abort with an unbound-variable crash instead of the intended usage
  # diagnostic.
  local phase_arg="" _GAIA_PHASE_FLAG_SEEN=0 _GAIA_SPRINT_FLAG_LABEL=""
  # Close-specific flags.
  local _GAIA_CLOSE_CLOSED_AT="" _GAIA_CLOSE_FORCE=0 _GAIA_CLOSE_ROLLOVER_KEYS=""
  local _GAIA_CLOSE_PRE_STATUS="" _GAIA_CLOSE_RESUME=0
  # set-story-sprint --clear flag: clear sprint_id to null (backlog return).
  local _GAIA_SET_SPRINT_CLEAR=0
  # Optional init-only fields.
  local init_start_date="" init_end_date="" init_capacity_points="" init_sprint_length=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || die "--story requires a value"
        story_key="$2"; shift 2 ;;
      --story=*)
        story_key="${1#--story=}"; shift ;;
      --to)
        [ $# -ge 2 ] || die "--to requires a value"
        to_state="$2"; shift 2 ;;
      --to=*)
        to_state="${1#--to=}"; shift ;;
      --sprint-id)
        [ $# -ge 2 ] || die "--sprint-id requires a value"
        reconcile_sprint_id="$2"; _GAIA_SPRINT_FLAG_LABEL="--sprint-id"; shift 2 ;;
      --sprint-id=*)
        reconcile_sprint_id="${1#--sprint-id=}"; _GAIA_SPRINT_FLAG_LABEL="--sprint-id"; shift ;;
      --dry-run)
        reconcile_dry_run=1; shift ;;
      --format)
        [ $# -ge 2 ] || die "--format requires a value"
        lint_format="$2"; shift 2 ;;
      --format=*)
        lint_format="${1#--format=}"; shift ;;
      --item-ids)
        [ $# -ge 2 ] || die "--item-ids requires a value"
        override_item_ids="$2"; shift 2 ;;
      --item-ids=*)
        override_item_ids="${1#--item-ids=}"; shift ;;
      --user)
        [ $# -ge 2 ] || die "--user requires a value"
        override_user="$2"; shift 2 ;;
      --user=*)
        override_user="${1#--user=}"; shift ;;
      --reason)
        [ $# -ge 2 ] || die "--reason requires a value"
        override_reason="$2"; shift 2 ;;
      --reason=*)
        override_reason="${1#--reason=}"; shift ;;
      --from)
        [ $# -ge 2 ] || die "--from requires a value"
        rollover_from="$2"; shift 2 ;;
      --from=*)
        rollover_from="${1#--from=}"; shift ;;
      --keys)
        [ $# -ge 2 ] || die "--keys requires a value"
        rollover_keys="$2"; shift 2 ;;
      --keys=*)
        rollover_keys="${1#--keys=}"; shift ;;
      --sprint)
        # --sprint is an alias for --sprint-id on sprint-level subcommands
        # (get-goals / set-goals / update-goals / set-shape /
        # set-review-justification / transition --sprint).
        [ $# -ge 2 ] || die "--sprint requires a value"
        reconcile_sprint_id="$2"; _GAIA_SPRINT_FLAG_LABEL="--sprint"; shift 2 ;;
      --sprint=*)
        reconcile_sprint_id="${1#--sprint=}"; _GAIA_SPRINT_FLAG_LABEL="--sprint"; shift ;;
      --goals)
        # Pipe-delimited goal list for set-goals / update-goals.
        [ $# -ge 2 ] || die "--goals requires a value"
        goals_arg="$2"; shift 2 ;;
      --goals=*)
        goals_arg="${1#--goals=}"; shift ;;
      --file)
        # Review-justification yaml payload path for set-review-justification.
        [ $# -ge 2 ] || die "--file requires a value"
        justification_file="$2"; shift 2 ;;
      --file=*)
        justification_file="${1#--file=}"; shift ;;
      --shape)
        # sprint_shape enum value for set-shape (thrust | completion-pass).
        [ $# -ge 2 ] || die "--shape requires a value"
        shape_arg="$2"; shift 2 ;;
      --shape=*)
        shape_arg="${1#--shape=}"; shift ;;
      --phase)
        # Execution phase for inject / set-phase. Like --goals, --shape and
        # --sprint-id, the parser loop is shared across subcommands, so the
        # flag is syntactically accepted everywhere and semantically consumed
        # only by the two subcommands that document it.
        [ $# -ge 2 ] || die "--phase requires a value"
        phase_arg="$2"; _GAIA_PHASE_FLAG_SEEN=1; shift 2 ;;
      --phase=*)
        phase_arg="${1#--phase=}"; _GAIA_PHASE_FLAG_SEEN=1; shift ;;
      --start-date)
        # Optional sprint metadata.
        [ $# -ge 2 ] || die "--start-date requires a value"
        init_start_date="$2"; shift 2 ;;
      --start-date=*)
        init_start_date="${1#--start-date=}"; shift ;;
      --end-date)
        [ $# -ge 2 ] || die "--end-date requires a value"
        init_end_date="$2"; shift 2 ;;
      --end-date=*)
        init_end_date="${1#--end-date=}"; shift ;;
      --capacity-points)
        [ $# -ge 2 ] || die "--capacity-points requires a value"
        init_capacity_points="$2"; shift 2 ;;
      --capacity-points=*)
        init_capacity_points="${1#--capacity-points=}"; shift ;;
      --sprint-length-days)
        [ $# -ge 2 ] || die "--sprint-length-days requires a value"
        init_sprint_length="$2"; shift 2 ;;
      --sprint-length-days=*)
        init_sprint_length="${1#--sprint-length-days=}"; shift ;;
      --help|-h)
        usage
        exit 0 ;;
      --points|--points=*)
        # --points is a common-but-wrong attempt. Emit a helpful redirect
        # instead of the bare "unknown flag" rejection. total_points is
        # accumulated from the injected story's frontmatter `points:` field.
        die "--points is not a valid flag for inject. total_points is accumulated from the injected story's frontmatter points: field. See --help for the inject contract." ;;
      --closed-at)
        [ $# -ge 2 ] || die "--closed-at requires a value"
        _GAIA_CLOSE_CLOSED_AT="$2"; shift 2 ;;
      --closed-at=*)
        _GAIA_CLOSE_CLOSED_AT="${1#--closed-at=}"; shift ;;
      --force)
        _GAIA_CLOSE_FORCE=1; shift ;;
      --rollover-keys)
        [ $# -ge 2 ] || die "--rollover-keys requires a value"
        _GAIA_CLOSE_ROLLOVER_KEYS="$2"; shift 2 ;;
      --rollover-keys=*)
        _GAIA_CLOSE_ROLLOVER_KEYS="${1#--rollover-keys=}"; shift ;;
      --pre-close-status)
        [ $# -ge 2 ] || die "--pre-close-status requires a value"
        _GAIA_CLOSE_PRE_STATUS="$2"; shift 2 ;;
      --pre-close-status=*)
        _GAIA_CLOSE_PRE_STATUS="${1#--pre-close-status=}"; shift ;;
      --resume)
        _GAIA_CLOSE_RESUME=1; shift ;;
      --clear)
        _GAIA_SET_SPRINT_CLEAR=1; shift ;;
      *)
        die "unknown flag: $1" ;;
    esac
  done

  # Resolve SPRINT_STATE_SCRIPT_DIR (directory containing this script) for
  # sibling script lookups. Respect a pre-exported override for tests.
  if [ -z "${SPRINT_STATE_SCRIPT_DIR:-}" ]; then
    SPRINT_STATE_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  fi
  resolve_paths

  # Wire the sprint argument for the resolver. In concurrent mode,
  # override SPRINT_STATUS_YAML to point at the per-sprint file so all
  # existing writers use it automatically.
  _GAIA_SPRINT_ARG="${reconcile_sprint_id:-}"
  if _is_concurrent_mode; then
    local _resolved_yaml=""
    _resolved_yaml="$(_resolve_sprint_file "${reconcile_sprint_id:-}" 2>/dev/null)" || true
    if [ -n "$_resolved_yaml" ] && [ -f "$_resolved_yaml" ]; then
      SPRINT_STATUS_YAML="$_resolved_yaml"
      SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
    fi
  fi

  # Migrate legacy `items:` key to `stories:` AFTER the concurrent-mode
  # repointing so per-sprint files are also migrated. Skip for init/advance
  # (they create the file). Fail closed on lock timeout or awk error.
  case "$subcmd" in
    init|advance) ;;
    *)
      if [ -f "$SPRINT_STATUS_YAML" ]; then
        migrate_items_to_stories "$SPRINT_STATUS_YAML" --lock "$SPRINT_STATUS_LOCK"
      fi
      ;;
  esac

  # ---------- Session binding cross-validation ----------
  #
  # On state-mutating subcommands in concurrent mode, cross-validate the
  # GAIA_BOUND_SPRINT_ID env var against the binding file. The env var is
  # a performance cache; the binding file is the sole authority.
  # Read-only subcommands (get, validate, get-goals, lint-dependencies,
  # detect-auto-close, resolve-file) skip this check intentionally.
  if _is_concurrent_mode; then
    case "$subcmd" in
      transition|inject|set-goals|update-goals|set-shape|set-phase|\
      set-review-justification|set-story-sprint|reconcile|\
      record-escalation-override|init|advance|rollover)

        # Source the binding library for validate_binding / read_binding.
        local _sb_lib="${SPRINT_STATE_SCRIPT_DIR}/lib/session-binding.sh"
        if [ -f "$_sb_lib" ]; then
          # shellcheck source=lib/session-binding.sh
          source "$_sb_lib"

          # Provision binding dir (derives from session ID, validates
          # inherited GAIA_BINDING_DIR). If no session ID is available,
          # skip binding validation (non-interactive context like CI).
          if provision_binding_dir 2>/dev/null; then

            # Cross-validate env var vs binding file.
            if ! validate_binding; then
              exit 1
            fi

            # Read binding state once for the guards below.
            local _bound_id="" _rb_exit=0
            _bound_id="$(read_binding 2>/dev/null)" || _rb_exit=$?

            # Closed-sprint guard for planning subcommands. Runs BEFORE the
            # override check because closed-bound refusal takes precedence
            # over any explicit --sprint override on these subcommands.
            # Only init/advance/rollover/set-story-sprint are refused;
            # other mutating subcommands proceed normally.
            case "$subcmd" in
              init|advance|rollover|set-story-sprint)
                if [ "$_rb_exit" -eq 2 ]; then
                  printf '%s: error: your bound sprint is closed -- start a new session to plan or run the next sprint\n' \
                    "$SCRIPT_NAME" >&2
                  exit 1
                fi
                ;;
            esac

            # Per-subcommand --sprint override semantics.
            if [ -n "$_bound_id" ] && [ -n "${reconcile_sprint_id:-}" ]; then
              # Check for explicit --sprint override vs binding.
              if [ "${reconcile_sprint_id}" != "$_bound_id" ]; then
                case "$subcmd" in
                  init|advance)
                    # In a bound session, init/advance with --sprint-id naming no
                    # existing sprint are refused.
                    local _override_file=""
                    _override_file="$(dirname "$SPRINT_STATUS_YAML")/sprint-status-${reconcile_sprint_id}.yaml"
                    if [ ! -f "$_override_file" ]; then
                      printf '%s: error: start a new session to plan the next sprint\n' "$SCRIPT_NAME" >&2
                      exit 1
                    fi
                    ;;
                  set-story-sprint)
                    # --sprint names the destination sprint, not an override.
                    # No override log emitted.
                    ;;
                  *)
                    # Verify the target sprint exists and is not closed.
                    local _override_file=""
                    _override_file="$(dirname "$SPRINT_STATUS_YAML")/sprint-status-${reconcile_sprint_id}.yaml"
                    if [ -f "$_override_file" ]; then
                      local _override_status=""
                      _override_status="$(yq '.status' "$_override_file" 2>/dev/null)" || _override_status=""
                      case "$_override_status" in
                        active|review|correction)
                          printf 'sprint override: bound=%s target=%s command=%s\n' \
                            "$_bound_id" "$reconcile_sprint_id" "$subcmd" >&2
                          ;;
                        closed)
                          printf '%s: error: target sprint %s is closed\n' "$SCRIPT_NAME" "$reconcile_sprint_id" >&2
                          exit 1 ;;
                        *)
                          printf '%s: error: target sprint %s has invalid status: %s\n' \
                            "$SCRIPT_NAME" "$reconcile_sprint_id" "$_override_status" >&2
                          exit 1 ;;
                      esac
                    else
                      printf '%s: error: target sprint %s does not exist\n' \
                        "$SCRIPT_NAME" "$reconcile_sprint_id" >&2
                      exit 1
                    fi
                    ;;
                esac
              fi
            fi
          fi
        fi
        ;;
    esac
  fi

  # Check for reverse migration on mutating subcommands in concurrent mode.
  # Only runs when concurrent mode is active (per-sprint files exist or limit > 1).
  if _is_concurrent_mode; then
    case "$subcmd" in
      transition|inject|set-goals|update-goals|set-shape|set-phase|\
      set-review-justification|reconcile|record-escalation-override|rollover)
        local _rm_state_dir
        _rm_state_dir="$(dirname "$SPRINT_STATUS_YAML")"
        _maybe_reverse_migration "$_rm_state_dir" || true
        # Re-resolve after reverse migration may have removed per-sprint files.
        _invalidate_concurrent_mode_cache
        if ! _is_concurrent_mode; then
          # Reverse migration completed — fall back to single file.
          # Clear SPRINT_STATUS_YAML so resolve_paths re-resolves it.
          unset SPRINT_STATUS_YAML
          resolve_paths
          SPRINT_STATUS_LOCK="${SPRINT_STATUS_YAML}.lock"
        fi
        ;;
    esac
  fi

  # Fail-closed parallel policy: refuse when flock is unavailable and
  # parallel execution is requested.
  if [ "${GAIA_PARALLEL_EXECUTION:-}" = "1" ]; then
    require_flock_for_parallel || die "parallel execution aborted: flock unavailable"
  fi

  # ---------- Startup orphan-tmp sweep ----------
  #
  # Garbage-collect *.tmp.?????? files older than 60 minutes under
  # ${IMPLEMENTATION_ARTIFACTS}. Catches orphans left by kill -9 / OOM /
  # power loss (which bypass the EXIT/INT/TERM trap). Bounded to the
  # allowlist (sprint-status.yaml directory). Never /tmp, never $HOME, never
  # ${PROJECT_PATH} root. Set GAIA_SKIP_ORPHAN_SWEEP=1 to disable.
  # Errors swallowed; zero stdout (silent GC).
  if [ "${GAIA_SKIP_ORPHAN_SWEEP:-0}" != "1" ]; then
    find "${IMPLEMENTATION_ARTIFACTS}" \
      -maxdepth 2 -name '*.tmp.??????' -mmin +60 -delete 2>/dev/null || true
  fi

  local _dispatch_rc=0
  set +e
  ( set -e
  # A subshell does not inherit the parent's traps: re-arm the temp-file
  # cleanup so writers registered during dispatch are still reclaimed on
  # exit or on INT/TERM.
  trap '_cleanup_tmps' EXIT INT TERM
  case "$subcmd" in
    init|advance)
      # Bootstrap a fresh sprint-status.yaml (init) or advance to the next
      # sprint after closing (advance). The advance subcommand is a thin,
      # discoverable alias that delegates to cmd_init — the underlying
      # cmd_init already handles closed-predecessor re-seeding and refuses
      # non-closed sprints with a clear message.
      [ -n "$reconcile_sprint_id" ] || die "${subcmd} requires --sprint-id <id>"
      # Pass the invoking subcommand name into cmd_init so user-facing
      # messages say "advance:" when invoked as advance, "init:" when init.
      _INIT_VERB="$subcmd"
      # Forward optional date / capacity / length flags only when non-empty,
      # so the minimal seed shape is preserved on zero-flag invocations.
      # Branch on array length: bash 3.2 + `set -u` rejects an empty-array
      # expansion, so the empty case calls cmd_init without trailing args.
      _init_args=()
      [ -n "$init_start_date" ]      && _init_args+=(--start-date "$init_start_date")
      [ -n "$init_end_date" ]        && _init_args+=(--end-date "$init_end_date")
      [ -n "$init_capacity_points" ] && _init_args+=(--capacity-points "$init_capacity_points")
      [ -n "$init_sprint_length" ]   && _init_args+=(--sprint-length-days "$init_sprint_length")
      if [ "${#_init_args[@]}" -gt 0 ]; then
        cmd_init "$reconcile_sprint_id" "${_init_args[@]}"
      else
        cmd_init "$reconcile_sprint_id"
      fi ;;
    get)
      [ -n "$story_key" ] || die "get requires --story <key>"
      cmd_get "$story_key" ;;
    validate)
      [ -n "$story_key" ] || die "validate requires --story <key>"
      cmd_validate "$story_key" ;;
    transition)
      # Supports both story-level (--story) and sprint-level (--sprint) edges.
      # Sprint-level edges: active↔correction, active→review, review→closed,
      # review→correction.
      if [ -n "$reconcile_sprint_id" ] && [ -z "$story_key" ]; then
        [ -n "$to_state" ] || die "transition --sprint requires --to <state>"
        cmd_transition_sprint "$reconcile_sprint_id" "$to_state"
      else
        [ -n "$story_key" ] || die "transition requires --story <key> or --sprint <id>"
        [ -n "$to_state" ] || die "transition requires --to <state>"
        cmd_transition "$story_key" "$to_state"
      fi ;;
    get-goals)
      [ -n "$reconcile_sprint_id" ] || die "get-goals requires --sprint <id>"
      cmd_get_goals "$reconcile_sprint_id" ;;
    set-goals)
      [ -n "$reconcile_sprint_id" ] || die "set-goals requires --sprint <id>"
      cmd_set_goals "$reconcile_sprint_id" "$goals_arg" ;;
    update-goals)
      [ -n "$reconcile_sprint_id" ] || die "update-goals requires --sprint <id>"
      cmd_update_goals "$reconcile_sprint_id" "$goals_arg" ;;
    set-review-justification)
      [ -n "$reconcile_sprint_id" ] || die "set-review-justification requires --sprint <id>"
      [ -n "$justification_file" ] || die "set-review-justification requires --file <path>"
      cmd_set_review_justification "$reconcile_sprint_id" "$justification_file" ;;
    set-shape)
      [ -n "$reconcile_sprint_id" ] || die "set-shape requires --sprint <id>"
      [ -n "$shape_arg" ] || die "set-shape requires --shape <thrust|completion-pass>"
      cmd_set_shape "$reconcile_sprint_id" "$shape_arg" ;;
    inject)
      [ -n "$story_key" ] || die "inject requires --story <key>"
      # An explicitly-given empty --phase is a usage error on inject: there
      # is nothing to clear on a row that does not exist yet, and silently
      # treating it as "omitted" would mask a caller passing an unset
      # variable. Clearing is set-phase's job. Routed through the validator
      # rather than repeating its wording, so the diagnostic cannot drift.
      if [ "$_GAIA_PHASE_FLAG_SEEN" = "1" ]; then
        _validate_phase_value "inject" "$phase_arg"
      fi
      cmd_inject "$story_key" "${reconcile_sprint_id:-}" "${phase_arg:-}" ;;
    set-phase)
      [ -n "$story_key" ] || die "set-phase requires --story <key>"
      if [ -n "$_GAIA_SPRINT_FLAG_LABEL" ]; then
        printf '%s: error: unknown flag for set-phase: %s\n' \
          "$SCRIPT_NAME" "$_GAIA_SPRINT_FLAG_LABEL" >&2
        exit 1
      fi
      # Clearing must be deliberate, never the residue of a forgotten flag.
      [ "$_GAIA_PHASE_FLAG_SEEN" = "1" ] \
        || die "set-phase requires --phase <n> (use --phase \"\" to clear)"
      cmd_set_phase "$story_key" "$phase_arg" ;;
    set-story-sprint)
      # Bind a pre-materialized backlog story's sprint_id (currently null)
      # to the active sprint without going through `--for-sprint`
      # materialization.
      [ -n "$story_key" ] || die "set-story-sprint requires --story <key>"
      if [ "$_GAIA_SET_SPRINT_CLEAR" -eq 1 ]; then
        _cmd_set_story_sprint_clear "$story_key"
      else
        [ -n "$reconcile_sprint_id" ] || die "set-story-sprint requires --sprint <id>"
        _cmd_set_story_sprint "$story_key" "$reconcile_sprint_id"
      fi
      ;;
    reconcile)
      # When --sprint-id is supplied, check it against the yaml before
      # reconciliation. Without it, behaviour is unchanged.
      if [ -n "${reconcile_sprint_id:-}" ]; then
        local _recon_yaml
        _recon_yaml="$(_resolve_active_yaml)"
        _assert_sprint_id_matches "reconcile" "--sprint-id" "$reconcile_sprint_id" "$_recon_yaml"
      fi
      cmd_reconcile "$reconcile_dry_run" ;;
    lint-dependencies)
      # lint_sprint_id reuses reconcile_sprint_id from shared --sprint-id flag.
      cmd_lint_dependencies "$lint_format" "${reconcile_sprint_id:-}" ;;
    record-escalation-override)
      cmd_record_escalation_override "$override_item_ids" "$override_user" "$override_reason" ;;
    detect-auto-close)
      cmd_detect_auto_close ;;
    rollover)
      cmd_rollover "$rollover_from" "$to_state" "$rollover_keys" ;;
    resolve-file)
      # Read-only subcommand: print the resolved per-sprint state file path.
      [ -n "$reconcile_sprint_id" ] || die "resolve-file requires --sprint <id>"
      _validate_sprint_id "$reconcile_sprint_id" || exit 1
      local _rf_path=""
      if _is_concurrent_mode; then
        _rf_path="$(_resolve_sprint_file "$reconcile_sprint_id")" || exit 1
        # Verify the file exists or is discoverable.
        if [ ! -f "$_rf_path" ]; then
          printf '%s: error: resolve-file — no state file for sprint %s at %s\n' \
            "$SCRIPT_NAME" "$reconcile_sprint_id" "$_rf_path" >&2
          exit 1
        fi
      else
        _rf_path="$SPRINT_STATUS_YAML"
      fi
      printf '%s\n' "$_rf_path"
      ;;
    close)
      # close uses its own arg parser; pass remaining args collected
      # by the main arg loop via the close-specific variables.
      [ -n "$reconcile_sprint_id" ] || die "close requires --sprint-id <id>"
      [ -n "${_GAIA_CLOSE_CLOSED_AT:-}" ] || die "close requires --closed-at <iso>"
      local -a _close_args=(--sprint "$reconcile_sprint_id" --closed-at "$_GAIA_CLOSE_CLOSED_AT")
      [ "${_GAIA_CLOSE_FORCE:-0}" = "1" ] && _close_args+=(--force)
      [ -n "${_GAIA_CLOSE_ROLLOVER_KEYS:-}" ] && _close_args+=(--rollover-keys "$_GAIA_CLOSE_ROLLOVER_KEYS")
      [ -n "${_GAIA_CLOSE_PRE_STATUS:-}" ] && _close_args+=(--pre-close-status "$_GAIA_CLOSE_PRE_STATUS")
      [ "${_GAIA_CLOSE_RESUME:-0}" = "1" ] && _close_args+=(--resume)
      cmd_close "${_close_args[@]}"
      ;;
  esac
  )
  _dispatch_rc=$?
  set -e
  [ "$_dispatch_rc" -eq 0 ] || exit "$_dispatch_rc"

  # --- Post-dispatch compatibility proxy hook ---
  # In concurrent mode, update the compatibility proxy after any successful
  # state-file write. The proxy hook runs AFTER the per-sprint lock is released
  # (the subshell above has exited), so L5 is never held together with L1/L4.
  # Rollover suppression: proxy hooks are suppressed inside _rollover_one;
  # the hook fires once after the rollover subshell exits.
  if _is_concurrent_mode && [ "$_dispatch_rc" -eq 0 ]; then
    local _proxy_state_dir
    _proxy_state_dir="$(dirname "$SPRINT_STATUS_YAML")"
    case "$subcmd" in
      transition|inject|set-goals|update-goals|set-shape|set-phase|\
      set-review-justification|reconcile|record-escalation-override)
        # Determine which sprint was written. In concurrent mode, _resolve_active_yaml
        # already resolved to the per-sprint file.
        local _written_yaml=""
        _written_yaml="$(_resolve_active_yaml 2>/dev/null)" || true
        if [ -n "$_written_yaml" ] && [ -f "$_written_yaml" ]; then
          local _written_sid=""
          _written_sid="$(read_yaml_sprint_id "$_written_yaml" 2>/dev/null || true)"
          if [ -n "$_written_sid" ]; then
            _update_compatibility_proxy "$_proxy_state_dir" "$_written_sid" "$_written_yaml"
          fi
        fi
        ;;
      rollover)
        # After rollover completes, fire the proxy hook once.
        local _last_act=""
        _last_act="$(_read_last_activated "$_proxy_state_dir")"
        if [ -n "$_last_act" ]; then
          local _last_file
          _last_file="$(_sprint_file_path "$_proxy_state_dir" "$_last_act")"
          if [ -f "$_last_file" ]; then
            _update_compatibility_proxy "$_proxy_state_dir" "$_last_act" "$_last_file"
          fi
        fi
        ;;
    esac
  fi

  # --- Post-mutation snapshot hook ---
  # Best-effort, background, detached. Never fails the parent.
  local _run_snapshot_hook=0
  case "$subcmd" in
    init|advance|transition|inject|set-phase|set-story-sprint|\
    set-goals|update-goals|set-shape|set-review-justification|\
    rollover|record-escalation-override)
      _run_snapshot_hook=1 ;;
    reconcile)
      [ "${reconcile_dry_run:-0}" != "1" ] && _run_snapshot_hook=1 || _run_snapshot_hook=0 ;;
    *) _run_snapshot_hook=0 ;;
  esac
  if [ "${_run_snapshot_hook:-0}" = "1" ] \
     && [ "${GAIA_SNAPSHOT_HOOK_DISABLE:-}" != "1" ] \
     && [ "${GAIA_SNAPSHOT_HOOK_ACTIVE:-}" != "1" ]; then
    local _hook_dir
    _hook_dir="$(cd "$(dirname "$0")" && pwd)"
    local _hook_script=""
    local _hook_plugin_root=""
    # Probe: sibling (scripts/ copy) then three levels up (dev-story copy).
    # Reference only basenames after the directory variable so the firewall
    # guard's regex extractor does not see a spurious relative path.
    local _hook_scripts_dir="$_hook_dir"
    if [ -x "${_hook_scripts_dir}/sprint-progress-snapshot.sh" ]; then
      _hook_script="${_hook_scripts_dir}/sprint-progress-snapshot.sh"
    else
      _hook_plugin_root="$(cd "${_hook_dir}/../../.." 2>/dev/null && pwd)" || true
      if [ -n "${_hook_plugin_root:-}" ]; then
        _hook_scripts_dir="${_hook_plugin_root}/scripts"
        if [ -x "${_hook_scripts_dir}/sprint-progress-snapshot.sh" ]; then
          _hook_script="${_hook_scripts_dir}/sprint-progress-snapshot.sh"
        fi
      fi
    fi
    if [ -n "$_hook_script" ]; then
      # Source exec-with-timeout from the resolved scripts directory
      local _hook_lib_dir="${_hook_scripts_dir}/lib"
      if [ -f "${_hook_lib_dir}/exec-with-timeout.sh" ]; then
        # shellcheck source=lib/exec-with-timeout.sh
        . "${_hook_lib_dir}/exec-with-timeout.sh"
      fi
      if command -v exec_with_timeout >/dev/null 2>&1; then
        # In concurrent mode, pass the written sprint ID so the snapshot
        # targets the correct per-sprint cache. The override --sprint takes
        # precedence (the caller knows which sprint it wrote). For
        # planned-to-active activation, the newly activated sprint ID is
        # passed. Single-sprint mode keeps the original contract: existing
        # PROJECT_ROOT/SPRINT_STATUS_YAML env, no --sprint argument.
        local -a _hook_args=()
        if _is_concurrent_mode; then
          local _hook_sid=""
          # Prefer the explicit --sprint override (reconcile_sprint_id)
          # since that is the sprint the subcommand actually wrote.
          if [ -n "${reconcile_sprint_id:-}" ]; then
            _hook_sid="$reconcile_sprint_id"
          else
            # Resolve the written sprint from the yaml file.
            local _hook_yaml=""
            _hook_yaml="$(_resolve_active_yaml 2>/dev/null)" || true
            if [ -n "$_hook_yaml" ] && [ -f "$_hook_yaml" ]; then
              _hook_sid="$(read_yaml_sprint_id "$_hook_yaml" 2>/dev/null || true)"
            fi
          fi
          if [ -n "$_hook_sid" ]; then
            _hook_args=(--sprint "$_hook_sid")
            # Export per-sprint state file path for downstream consumers.
            local _hook_per_file=""
            _hook_per_file="$(_sprint_file_path "$(dirname "$SPRINT_STATUS_YAML")" "$_hook_sid")"
            if [ -f "$_hook_per_file" ]; then
              export GAIA_SNAPSHOT_PER_SPRINT_FILE="$_hook_per_file"
              export GAIA_SNAPSHOT_SPRINT_ID="$_hook_sid"
            fi
          fi
        fi
        (
          export GAIA_SNAPSHOT_HOOK_ACTIVE=1
          export PROJECT_ROOT SPRINT_STATUS_YAML IMPLEMENTATION_ARTIFACTS
          exec_with_timeout 10 "$_hook_script" "${_hook_args[@]+"${_hook_args[@]}"}"
        ) </dev/null >/dev/null 2>&1 &
      fi
    fi
  fi || true

}

main "$@"
