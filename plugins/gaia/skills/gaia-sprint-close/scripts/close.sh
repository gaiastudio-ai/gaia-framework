#!/usr/bin/env bash
# close.sh — /gaia-sprint-close skill main orchestrator.
#
# Closes the active sprint:
#   1. Pre-conditions — retro doc present, idempotency check, all-done-or-force.
#   2. Status write — delegates to sprint-state.sh close writer.
#   3. Archive — copy yaml to .gaia/artifacts/implementation-artifacts/sprint-archive/.
#   4. Lifecycle event — append `sprint_closed` via lifecycle-event.sh.
#
# All state-file writes are performed by the sprint-state.sh close writer;
# close.sh takes no lock and performs no direct yq writes to the state file.
#
# The skill's separate `finalize.sh` is the generic plugin lifecycle hook
# (write checkpoint, emit `workflow_complete`); this script is the action.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-close/close.sh"

# ---------- Path resolution ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
LIFECYCLE_EVENT_SH="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"
# shellcheck source=../../../scripts/lib/migrate-items-to-stories.sh
if [ -f "$PLUGIN_SCRIPTS_DIR/lib/migrate-items-to-stories.sh" ]; then
  . "$PLUGIN_SCRIPTS_DIR/lib/migrate-items-to-stories.sh"
fi

# Fail-closed guard: if the shared lib did not load, define an inline
# fallback that implements the same union-by-key semantics. Without this,
# parse_stories would silently see 0 stories and the precheck would pass.
if ! type read_stories_or_items >/dev/null 2>&1; then
  read_stories_or_items() {
    local yaml="$1"; [ -f "$yaml" ] || return 0
    awk '
      /^stories[[:space:]]*:[[:space:]]*$/ { in_s=1; in_i=0; next }
      /^items[[:space:]]*:[[:space:]]*$/ { in_i=1; in_s=0; next }
      /^stories[[:space:]]*:[[:space:]]*\[\]/ { in_s=0; next }
      /^items[[:space:]]*:[[:space:]]*\[\]/ { in_i=0; next }
      (in_s||in_i) && /^[A-Za-z_]/ { in_s=0; in_i=0 }
      in_s && /^[[:space:]]+-[[:space:]]+key:/ {
        k=$0; sub(/.*key:[[:space:]]*/,"",k); gsub(/["'"'"'[:space:]]/,"",k)
        s_key[k]=1; s_order[s_n++]=k; next
      }
      in_s && /^[[:space:]]+status:/ {
        v=$0; sub(/.*status:[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v)
        s_st[s_order[s_n-1]]=v; next
      }
      in_i && /^[[:space:]]+-[[:space:]]+key:/ {
        k=$0; sub(/.*key:[[:space:]]*/,"",k); gsub(/["'"'"'[:space:]]/,"",k)
        i_order[i_n++]=k; next
      }
      in_i && /^[[:space:]]+status:/ {
        v=$0; sub(/.*status:[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v)
        i_st[i_order[i_n-1]]=v; next
      }
      END {
        for(j=0;j<s_n;j++){printf "%s\t%s\n",s_order[j],s_st[s_order[j]];seen[s_order[j]]=1}
        for(j=0;j<i_n;j++){if(!(i_order[j] in seen))printf "%s\t%s\n",i_order[j],i_st[i_order[j]]}
      }
    ' "$yaml"
  }
fi

# PROJECT_PATH defaults to CWD; honor a pre-exported value (used by bats).
PROJECT_PATH="${PROJECT_PATH:-$PWD}"
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

# .gaia/memory is the only memory tree; legacy _memory fallback removed.
# Env override wins.
if [ -z "${MEMORY_PATH:-}" ]; then
  MEMORY_PATH="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory"
fi
export PROJECT_PATH MEMORY_PATH

# Resolve sprint-status.yaml path.
# Resolution order (env override > .gaia/state/ > legacy docs/ > project-root fallback).
resolve_yaml_path() {
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    printf '%s\n' "$SPRINT_STATUS_YAML"
    return 0
  fi
  local gaia_state="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status.yaml"
  local legacy_docs="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}docs/implementation-artifacts/sprint-status.yaml"
  local fallback="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}sprint-status.yaml"
  if [ -f "$gaia_state" ]; then
    printf '%s\n' "$gaia_state"
  elif [ -f "$legacy_docs" ]; then
    printf '%s\n' "$legacy_docs"
  elif [ -f "$fallback" ]; then
    printf '%s\n' "$fallback"
  else
    # Default to .gaia/state/ — the sole canonical write target.
    printf '%s\n' "$gaia_state"
  fi
}

# Smart-fallback for ART_DIR (implementation-artifacts root used for
# retro-glob + sprint-archive subdir).
if [ -d "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts" ]; then
  ART_DIR="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts"
else
  ART_DIR="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}docs/implementation-artifacts"
fi
ARCHIVE_DIR="$ART_DIR/sprint-archive"

# ---------- Helpers ----------

log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { log "$*"; exit 1; }
warn() { log "$*"; }

# Read a top-level scalar YAML field from a file. Returns empty string if absent.
# Disables pipefail locally so a missing key produces an empty string cleanly
# under set -euo pipefail, not a propagated exit-1 from grep-no-match.
yaml_top_scalar() {
  local key="$1" path="$2"
  local line value
  set +o pipefail
  line=$(grep "^${key}:" "$path" 2>/dev/null | head -1)
  set -o pipefail
  [ -z "$line" ] && { printf ''; return 0; }
  value=$(printf '%s' "$line" | sed "s/^${key}:[[:space:]]*//" | tr -d "\"'")
  # Strip inline YAML comments (# ...) and trailing whitespace/CR.
  value=$(printf '%s' "$value" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//' | tr -d '\r')
  printf '%s' "$value"
}

# Enumerate stories[] from sprint-status.yaml as "key=status" pairs on stdout.
# Union of stories: and items: (stories wins on duplicate key).
# Uses the shared lib's read_stories_or_items for consistent semantics.
parse_stories() {
  local path="$1"
  read_stories_or_items "$path" | while IFS=$'\t' read -r k s; do
    [ -n "$k" ] && printf '%s=%s\n' "$k" "$s"
  done
}

# ISO 8601 UTC timestamp with seconds precision.
iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Date stamp for archive filename (YYYY-MM-DD). Override-able for tests.
close_date_stamp() {
  if [ -n "${GAIA_SPRINT_CLOSE_DATE:-}" ]; then
    printf '%s\n' "$GAIA_SPRINT_CLOSE_DATE"
  else
    date -u +"%Y-%m-%d"
  fi
}

# Render a bash array as a JSON array literal of double-quoted strings.
# Usage: json_string_array key1 key2 ...
# Empty input yields "[]".
json_string_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  printf '['
  local i first=1
  for i in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s"' "$i"
  done
  printf ']'
}

usage() {
  cat <<'USAGE' >&2
Usage:
  close.sh [--sprint <sprint-id>] [<sprint-id>] [--force] [--force-with-rollover <key1,key2,...>] [--help]

Closes the target sprint: writes status:closed + closed_at to sprint-status.yaml,
archives the yaml under .gaia/artifacts/implementation-artifacts/sprint-archive/,
and emits a sprint_closed lifecycle event to .gaia/memory/lifecycle-events.jsonl.

Sprint resolution (via the shared resolver):
  1. Explicit --sprint <id> (highest priority).
  2. Session binding (the sprint bound to the current session).
  3. Single-sprint default (one active sprint, no ambiguity).

Pre-conditions:
  - A retro doc must exist at .gaia/artifacts/implementation-artifacts/retrospective/retrospective-{sprint_id}-*.md
  - A sprint-review sentinel must exist proving /gaia-sprint-review ran, OR --force must be passed.
  - All stories must be `done`, OR --force-with-rollover must list exactly the non-done keys.
  - Sprint must not already be closed (idempotent re-close exits 0 with warning).

Flags:
  --sprint <id>           Target a specific sprint (concurrent mode).
  --force                 Bypass the sprint-review sentinel check (audited; recorded in close-summary).
  --force-with-rollover   Close with non-done stories (must list exactly the non-done keys).

USAGE
}

# ---------- Argument parsing ----------

FORCE_ROLLOVER_RAW=""
FORCE_BYPASS_SENTINEL=0
_RESUME_MODE=0
_SPRINT_FLAG=""
_POSITIONAL_SPRINT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --force)
      FORCE_BYPASS_SENTINEL=1
      shift
      ;;
    --sprint)
      [ "$#" -ge 2 ] || die "--sprint requires a sprint ID"
      [ -n "$2" ] || die "--sprint requires a non-empty sprint ID"
      if [ -n "$_SPRINT_FLAG" ] && [ "$_SPRINT_FLAG" != "$2" ]; then
        die "repeated --sprint: '$_SPRINT_FLAG' and '$2'"
      fi
      _SPRINT_FLAG="$2"
      shift 2
      ;;
    --sprint=*)
      _SPRINT_FLAG_NEW="${1#--sprint=}"
      [ -n "$_SPRINT_FLAG_NEW" ] || die "--sprint requires a non-empty sprint ID"
      if [ -n "$_SPRINT_FLAG" ] && [ "$_SPRINT_FLAG" != "$_SPRINT_FLAG_NEW" ]; then
        die "repeated --sprint: '$_SPRINT_FLAG' and '$_SPRINT_FLAG_NEW'"
      fi
      _SPRINT_FLAG="$_SPRINT_FLAG_NEW"
      shift
      ;;
    --force-with-rollover)
      [ "$#" -ge 2 ] || die "--force-with-rollover requires a comma-separated key list"
      FORCE_ROLLOVER_RAW="$2"
      shift 2
      ;;
    --force-with-rollover=*)
      FORCE_ROLLOVER_RAW="${1#--force-with-rollover=}"
      shift
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      # Positional argument: treat as sprint ID.
      if [ -n "$_POSITIONAL_SPRINT" ]; then
        die "unexpected positional argument: $1 (already have $_POSITIONAL_SPRINT)"
      fi
      _POSITIONAL_SPRINT="$1"
      shift
      ;;
  esac
done

# ---------- Sprint resolution via shared resolver ----------

SESSION_BINDING_SH="$PLUGIN_SCRIPTS_DIR/lib/session-binding.sh"
_close_session_dir_created=""
if [ -f "$SESSION_BINDING_SH" ]; then
  # shellcheck source=../../../scripts/lib/session-binding.sh
  . "$SESSION_BINDING_SH"

  # Detect whether provision_binding_dir will create a NEW directory so we
  # can clean it up if close.sh fails before the binding is consumed.
  _pre_provision_sid=""
  _pre_provision_sid="$(_sb_derive_session_id 2>/dev/null)" || _pre_provision_sid=""
  if [ -n "$_pre_provision_sid" ]; then
    _pre_provision_root="$(_sb_resolve_project_root 2>/dev/null)" || _pre_provision_root=""
    if [ -n "$_pre_provision_root" ]; then
      _pre_provision_dir="${_pre_provision_root%/}/.gaia/state/${_SB_SESSION_DIR_NAME:-sessions}/${_pre_provision_sid}"
      if [ ! -d "$_pre_provision_dir" ]; then
        _close_session_dir_created="$_pre_provision_dir"
      fi
    fi
  fi

  # Provision the binding directory from the session ID so the resolver
  # can read the binding file written by bind.sh. Without this call,
  # GAIA_BINDING_DIR is unset and the resolver never sees the binding.
  # Exit 1 (no session ID) is non-fatal — non-interactive context.
  # Exit 3 (spoofing detected) is fatal — fail closed.
  _provision_rc=0
  provision_binding_dir 2>/dev/null || _provision_rc=$?
  if [ "$_provision_rc" -eq 3 ]; then
    # Clean up newly created dir before dying.
    if [ -n "$_close_session_dir_created" ] && [ -d "$_close_session_dir_created" ]; then
      rmdir "$_close_session_dir_created" 2>/dev/null || true
    fi
    die "binding directory validation failed (spoofing detected)"
  fi
fi

# Cleanup trap: remove newly created session dir if close.sh exits non-zero
# before the close operation succeeds.
_close_succeeded=0
_close_cleanup() {
  if [ "$_close_succeeded" -eq 0 ] && [ -n "$_close_session_dir_created" ] && [ -d "$_close_session_dir_created" ]; then
    # Only remove if the dir is empty (no binding file was written by us).
    if [ ! -f "$_close_session_dir_created/${_SB_BINDING_FILENAME:-bound_sprint_id}" ]; then
      rmdir "$_close_session_dir_created" 2>/dev/null || true
    fi
  fi
}
trap '_close_cleanup' EXIT

# Positional/flag conflict detection (before the resolver).
# When both a positional sprint ID and --sprint are given with different
# values, refuse immediately with a conflict diagnostic.
if [ -n "$_SPRINT_FLAG" ] && [ -n "$_POSITIONAL_SPRINT" ]; then
  if [ "$_SPRINT_FLAG" != "$_POSITIONAL_SPRINT" ]; then
    die "positional sprint ID '$_POSITIONAL_SPRINT' conflicts with --sprint '$_SPRINT_FLAG'"
  fi
fi

# Merge positional into --sprint for the resolver (the resolver only
# accepts --sprint for the sprint-close command class).
_effective_sprint="${_SPRINT_FLAG:-${_POSITIONAL_SPRINT:-}}"

# Detect whether to use the resolver or the legacy single-sprint path.
# Two conditions skip the resolver:
#   1. SPRINT_STATUS_YAML is set — the caller explicitly chose the file.
#   2. .gaia/state/ does not exist — legacy layout, no per-sprint files.
# This decision is made once BEFORE calling the resolver and is not
# inferred from any resolver failure.
_state_dir="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state"
_use_resolver=0
if [ -z "${SPRINT_STATUS_YAML:-}" ] && [ -d "$_state_dir" ]; then
  _use_resolver=1
else
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    warn "WARNING: SPRINT_STATUS_YAML is set — resolver and session binding bypassed; target file: ${SPRINT_STATUS_YAML}"
  fi
fi

# Build resolver arguments.
_resolver_args=(--command sprint-close)
if [ -n "$_effective_sprint" ]; then
  _resolver_args+=(--sprint "$_effective_sprint")
fi

# Resolve the target sprint ID. The resolver handles:
#   - explicit --sprint (highest priority)
#   - session binding fallback
#   - single-sprint default
# On failure (unknown ID, conflict, ambiguous), it prints diagnostics to
# stderr and returns non-zero — close.sh propagates that exit (fail closed).
if [ "$_use_resolver" -eq 1 ] && type resolve_sprint_arg >/dev/null 2>&1; then
  _resolver_stderr="$(mktemp)"
  trap 'rm -f "$_resolver_stderr"; _close_cleanup' EXIT
  _resolver_rc=0
  RESOLVED_SPRINT="$(resolve_sprint_arg "${_resolver_args[@]}" 2>"$_resolver_stderr")" || _resolver_rc=$?
  if [ "$_resolver_rc" -ne 0 ]; then
    # Fail closed: surface the resolver's diagnostic and exit non-zero.
    cat "$_resolver_stderr" >&2
    rm -f "$_resolver_stderr"
    exit "$_resolver_rc"
  fi
  rm -f "$_resolver_stderr"
else
  # Resolver skipped (SPRINT_STATUS_YAML set, .gaia/state/ absent, or
  # session-binding.sh not found). Use the effective sprint or fall
  # through to the legacy single-sprint path.
  RESOLVED_SPRINT="$_effective_sprint"
fi

# ---------- Dependency check ----------

command -v yq >/dev/null 2>&1 || die "yq required (mikefarah v4); install via 'brew install yq' or equivalent"

# When a specific sprint was resolved, look for its per-sprint state file
# first; fall back to the main sprint-status.yaml for single-sprint mode.
if [ -n "${RESOLVED_SPRINT:-}" ]; then
  _per_sprint="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/state/sprint-status-${RESOLVED_SPRINT}.yaml"
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    YAML_PATH="$SPRINT_STATUS_YAML"
  elif [ -f "$_per_sprint" ]; then
    YAML_PATH="$_per_sprint"
  else
    # Fall back to main file (single-sprint layout or env override).
    YAML_PATH="$(resolve_yaml_path)"
  fi
else
  YAML_PATH="$(resolve_yaml_path)"
fi
[ -f "$YAML_PATH" ] || die "sprint-status.yaml not found at $YAML_PATH"

SPRINT_ID="$(yaml_top_scalar sprint_id "$YAML_PATH")"
[ -n "$SPRINT_ID" ] || die "sprint_id not found in $YAML_PATH"

# Sanity: when the resolver gave us an ID, the state file must match.
if [ -n "${RESOLVED_SPRINT:-}" ] && [ "$SPRINT_ID" != "$RESOLVED_SPRINT" ]; then
  die "sprint ID mismatch: resolver gave '${RESOLVED_SPRINT}' but state file contains '${SPRINT_ID}'"
fi

# Cross-check: when SPRINT_STATUS_YAML bypassed the resolver, verify the
# sprint ID in the file against the session binding (if any).
# A mismatch is refused (fail closed) — a stale env override must not close
# a sprint other than the bound one.
if [ -n "${SPRINT_STATUS_YAML:-}" ] && [ -n "${GAIA_BOUND_SPRINT_ID:-}" ]; then
  if [ "$SPRINT_ID" != "$GAIA_BOUND_SPRINT_ID" ]; then
    die "binding mismatch: SPRINT_STATUS_YAML targets sprint '$SPRINT_ID' but session is bound to '$GAIA_BOUND_SPRINT_ID'"
  fi
elif [ -n "${SPRINT_STATUS_YAML:-}" ] && [ -n "${GAIA_BINDING_DIR:-}" ]; then
  _cross_bound=""
  _cross_bound="$(cat "${GAIA_BINDING_DIR}/${_SB_BINDING_FILENAME:-bound_sprint_id}" 2>/dev/null | tr -d '\n')" || _cross_bound=""
  if [ -n "$_cross_bound" ] && [ "$SPRINT_ID" != "$_cross_bound" ]; then
    die "binding mismatch: SPRINT_STATUS_YAML targets sprint '$SPRINT_ID' but session is bound to '$_cross_bound'"
  fi
fi

# ---------- Step 2 — Idempotency short-circuit ----------
# Done BEFORE retro check so already-closed sprints don't require an existing
# retro doc (idempotency check doesn't require retro presence).
# In concurrent mode: closed + archive present = exit 0; closed + archive
# missing = resume via the close writer (exception to closed-id refusal).
# In single-sprint mode: closed = exit 0 regardless of archive presence.

current_status="$(yaml_top_scalar status "$YAML_PATH")"
if [ "$current_status" = "closed" ]; then
  existing_closed_at="$(yaml_top_scalar closed_at "$YAML_PATH")"

  # Detect concurrent mode via the lock library.
  _is_concurrent=0
  _lock_lib="${PLUGIN_SCRIPTS_DIR}/lib/acquire-lock.sh"
  if [ -f "$_lock_lib" ]; then
    # shellcheck source=../../../scripts/lib/acquire-lock.sh
    . "$_lock_lib"
    _max_conc=""
    _cfg="${PROJECT_CONFIG:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/config/project-config.yaml}"
    if [ -f "$_cfg" ]; then
      _max_conc="$(yq '.sprint.max_concurrent_active // ""' "$_cfg" 2>/dev/null)" || _max_conc=""
    fi
    _state_dir="$(dirname "$YAML_PATH")"
    if acquire_lock_is_concurrent_mode "$_max_conc" "$_state_dir" 2>/dev/null; then
      _is_concurrent=1
    fi
  fi

  if [ "$_is_concurrent" -eq 1 ]; then
    # Concurrent mode: check for archive.
    _archive_pattern="$ARCHIVE_DIR/${SPRINT_ID}-closed-*.yaml"
    _archive_count=0
    for _af in $_archive_pattern; do
      [ -f "$_af" ] && _archive_count=$((_archive_count + 1))
    done

    if [ "$_archive_count" -gt 0 ]; then
      warn "warning: sprint ${SPRINT_ID} already closed at ${existing_closed_at:-(unknown)}"
      _close_succeeded=1
      exit 0
    fi
    # Archive missing — resume. Will be passed to the close writer below.
    _RESUME_MODE=1
    warn "warning: sprint ${SPRINT_ID} is closed but archive is missing — resuming"
  else
    # Single-sprint mode: exit 0 regardless of archive presence.
    warn "warning: sprint ${SPRINT_ID} already closed at ${existing_closed_at:-(unknown)}"
    _close_succeeded=1
    exit 0
  fi
fi

# ---------- Step 1 — Pre-condition: retro doc exists ----------

# Glob accepts both `retrospective-{id}-{date}.md` and
# `retrospective-{id}-{date}-{HHMM}.md` clobber-avoidance variants.
# Route through the shared three-tier resolver at
# `gaia-framework/plugins/gaia/scripts/lib/artifact-three-tier-resolve.sh`
# (env-var → legacy-flat-positive-evidence → canonical-nested-default)
# so both legacy `implementation-artifacts/retrospective-*.md` AND the new
# `implementation-artifacts/retrospective/retrospective-*.md` resolve.
SCRIPT_DIR_S6="$(cd "$(dirname "$0")" && pwd)"
RESOLVER_HELPER="${SCRIPT_DIR_S6}/../../../scripts/lib/artifact-three-tier-resolve.sh"

# Always search the existing $ART_DIR (the canonical location the existing
# tests + production wiring already pass in). When the new resolver is
# available, ALSO probe its result so the dual-path layout (legacy flat +
# canonical nested) is honored. Preserves backward-compat verbatim while
# adding new-layout support.
retro_match_count=$(find "$ART_DIR" -maxdepth 1 -type f \
  -name "retrospective-${SPRINT_ID}-*.md" 2>/dev/null | wc -l | tr -d ' ')

if [ "${retro_match_count:-0}" -eq 0 ] && [ -x "$RESOLVER_HELPER" ]; then
  resolver_dir="$(bash "$RESOLVER_HELPER" --family retro --id "$SPRINT_ID" --project-root "${PROJECT_PATH:-${PROJECT_ROOT:-$PWD}}" 2>/dev/null || true)"
  if [ -n "$resolver_dir" ] && [ -d "$resolver_dir" ] && [ "$resolver_dir" != "$ART_DIR" ]; then
    retro_match_count=$(find "$resolver_dir" -maxdepth 1 -type f \
      -name "retrospective-${SPRINT_ID}-*.md" 2>/dev/null | wc -l | tr -d ' ')
  fi
fi

if [ "${retro_match_count:-0}" -eq 0 ]; then
  die "error: retro doc not found for ${SPRINT_ID}; run /gaia-retro first"
fi

# ---------- Step 3 — Pre-condition: all-done or force ----------

stories_done_count=0
stories_total_count=0
non_done_keys=()
while IFS='=' read -r k s; do
  [ -n "$k" ] || continue
  stories_total_count=$((stories_total_count + 1))
  if [ "$s" = "done" ]; then
    stories_done_count=$((stories_done_count + 1))
  else
    non_done_keys+=("$k")
  fi
done < <(parse_stories "$YAML_PATH")

# Build rollover key array from --force-with-rollover (comma-separated).
rollover_keys=()
if [ -n "$FORCE_ROLLOVER_RAW" ]; then
  IFS=',' read -r -a rollover_keys <<<"$FORCE_ROLLOVER_RAW"
fi

if [ "${#non_done_keys[@]}" -gt 0 ]; then
  if [ "${#rollover_keys[@]}" -eq 0 ]; then
    die "error: sprint ${SPRINT_ID} has non-done stories: ${non_done_keys[*]}; pass --force-with-rollover to proceed"
  fi
  # Validate the provided keys are exactly the non-done set (sorted comparison).
  expected_sorted=$(printf '%s\n' "${non_done_keys[@]}" | LC_ALL=C sort -u)
  provided_sorted=$(printf '%s\n' "${rollover_keys[@]}" | LC_ALL=C sort -u)
  if [ "$expected_sorted" != "$provided_sorted" ]; then
    die "error: --force-with-rollover key mismatch; non-done stories are: ${non_done_keys[*]}; got: ${rollover_keys[*]}"
  fi
elif [ "${#rollover_keys[@]}" -gt 0 ]; then
  # All stories done but caller passed rollover keys — refuse (mismatch).
  die "error: --force-with-rollover key mismatch; no non-done stories but got: ${rollover_keys[*]}"
fi

# ---------- Step 3a — Pre-condition: sprint-review sentinel (unconditional) --
# The sprint-review sentinel proves that /gaia-sprint-review ran and produced
# a verdict. This check fires for ALL closeable source states (active, review)
# — it is NOT gated on the sprint's current status value. Without a sentinel,
# close is refused unless --force is passed.
#
# Sentinel files (either one satisfies the gate):
#   - dispatch checkpoint: .gaia/memory/checkpoints/sprint-review-{id}-val-dispatched.json
#   - envelope sentinel:   .gaia/memory/checkpoints/val-envelope-*.json whose
#                          artifact_path matches the sprint id.

_ckpt_dir="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory/checkpoints"
_dispatch_sentinel="${_ckpt_dir}/sprint-review-${SPRINT_ID}-val-dispatched.json"
_envelope_glob="${_ckpt_dir}/val-envelope-*.json"
_sentinel_found=0

if [ -f "$_dispatch_sentinel" ]; then
  _sentinel_found=1
else
  # Probe envelope sentinels for a matching artifact_path.
  for _env in $_envelope_glob; do
    [ -f "$_env" ] || continue
    if grep -E "\"artifact_path\":[[:space:]]*\"${SPRINT_ID}\"" "$_env" >/dev/null 2>&1; then
      _sentinel_found=1
      break
    fi
  done
fi

if [ "$_sentinel_found" -ne 1 ]; then
  if [ "$FORCE_BYPASS_SENTINEL" -eq 1 ]; then
    warn "warning: no sprint-review sentinel for ${SPRINT_ID}; proceeding due to --force (audited bypass)"
    _sentinel_force_bypassed=1
  else
    die "sprint-close refused: no sprint-review sentinel for ${SPRINT_ID}; run /gaia-sprint-review first, OR pass --force for the documented bypass"
  fi
else
  _sentinel_force_bypassed=0
fi

# ---------- Step 4 — Status write via sprint-state.sh close writer ----------
# All state-file writes are delegated to the sprint-state.sh close writer.
# close.sh takes no lock and performs no direct yq writes. When
# sprint-state.sh is missing or not executable, close.sh fails loudly.

CLOSED_AT="$(iso_now)"
SPRINT_STATE_SH="${SPRINT_STATE_SH:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/scripts/sprint-state.sh}"

if [ ! -x "$SPRINT_STATE_SH" ]; then
  die "sprint-state.sh not found or not executable at $SPRINT_STATE_SH — cannot close sprint"
fi

# Build the close writer arguments.
_close_args=(close --sprint-id "$SPRINT_ID" --closed-at "$CLOSED_AT"
             --pre-close-status "$current_status")
# Pass --force only when the sentinel was actually bypassed (not just
# when the user passed --force — if the sentinel was present, it's a
# normal review-to-closed regardless of --force).
if [ "${_sentinel_force_bypassed:-0}" -eq 1 ]; then
  _close_args+=(--force)
fi
if [ -n "$FORCE_ROLLOVER_RAW" ]; then
  _close_args+=(--rollover-keys "$FORCE_ROLLOVER_RAW")
fi
if [ "${_RESUME_MODE:-0}" -eq 1 ]; then
  _close_args+=(--resume)
fi

# Capture the close writer's exit code and stderr.
_close_stderr="$(mktemp)"
_close_rc=0
"$SPRINT_STATE_SH" "${_close_args[@]}" 2>"$_close_stderr" || _close_rc=$?

if [ "$_close_rc" -eq 0 ]; then
  rm -f "$_close_stderr"
elif [ "$_close_rc" -eq 2 ]; then
  # Sprint-id mismatch or transition refusal — propagate the message.
  cat "$_close_stderr" >&2
  rm -f "$_close_stderr"
  die "close writer failed (exit $_close_rc)"
elif [ "$_close_rc" -eq 3 ] || [ "$_close_rc" -eq 4 ] || [ "$_close_rc" -eq 5 ]; then
  # Lock contention, symlink, or identity mismatch.
  cat "$_close_stderr" >&2
  rm -f "$_close_stderr"
  exit "$_close_rc"
else
  cat "$_close_stderr" >&2
  rm -f "$_close_stderr"
  die "close writer failed (exit $_close_rc)"
fi

# ---------- Step 5 — Archive ----------

mkdir -p "$ARCHIVE_DIR"
ARCHIVE_PATH="$ARCHIVE_DIR/${SPRINT_ID}-closed-$(close_date_stamp).yaml"

# Build the rollover JSON array literal once — reused for both the archived
# yaml record and the lifecycle event data payload.
rollover_array="$(json_string_array "${rollover_keys[@]:-}")"
# Guard: json_string_array of an unset/empty array via the "[@]:-" idiom can
# inject a single empty argument on bash 3.2; normalize to "[]" if so.
[ "$rollover_array" = '[""]' ] && rollover_array='[]'

# If the operator passed --force-with-rollover, record the rollover list in
# the archived yaml (the live yaml stays clean — rollover is sprint-plan
# territory).
cp "$YAML_PATH" "$ARCHIVE_PATH"
if [ "${#rollover_keys[@]}" -gt 0 ]; then
  yq -i ".rollover_keys = ${rollover_array}" "$ARCHIVE_PATH" \
    || die "yq write of rollover_keys failed on $ARCHIVE_PATH"
fi

# ---------- Step 6 — Lifecycle event ----------

# Source total_points from the yaml (already validated to exist).
total_points_raw="$(yaml_top_scalar total_points "$YAML_PATH")"
# Default to 0 if absent — keeps the JSON valid.
total_points="${total_points_raw:-0}"

# Compose data payload. Use printf to avoid shell-escaping landmines.
data_payload=$(printf '{"sprint_id":"%s","closed_at":"%s","total_points":%s,"stories_done":%s,"stories_rolled_over":%s,"rollover_target_sprint":null}' \
  "$SPRINT_ID" "$CLOSED_AT" "$total_points" "$stories_done_count" "$rollover_array")

if [ -x "$LIFECYCLE_EVENT_SH" ]; then
  "$LIFECYCLE_EVENT_SH" \
      --type sprint_closed \
      --workflow gaia-sprint-close \
      --data "$data_payload" \
    || die "lifecycle-event.sh failed for sprint ${SPRINT_ID} close"
else
  # Fallback: write JSONL line directly. Same nested-data schema as the helper.
  mkdir -p "$MEMORY_PATH"
  lc_file="$MEMORY_PATH/lifecycle-events.jsonl"
  ts="$(iso_now)"
  printf '{"timestamp":"%s","event_type":"sprint_closed","workflow":"gaia-sprint-close","pid":%d,"data":%s}\n' \
    "$ts" "$$" "$data_payload" >> "$lc_file"
fi

# ---------- Step 6b — Advisory checklist ----------
# Append a non-blocking "Lifecycle Skill Checklist (advisory)" section to the
# sprint-close summary, enumerating canonical artifact-producing skills and
# their on-disk state. Consumes the lifecycle-overrides helper for the [~]
# bypassed-row case. Non-blocking — never affects exit status.

LIFECYCLE_LIB_S4="$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
SUMMARY_FILE="${ARCHIVE_PATH%.yaml}-close-summary.md"

# Resolve sprint-scoped bypasses (defensive against helper absence).
bypass_json='{"bypasses":[]}'
if [ -f "$LIFECYCLE_LIB_S4" ]; then
  bypass_json="$(bash "$LIFECYCLE_LIB_S4" read --sprint-id "$SPRINT_ID" 2>/dev/null || echo '{"bypasses":[]}')"
fi

# Canonical skill → artifact map. Each entry: skill|artifact-path-relative-to-.gaia/artifacts
declare -a SKILL_ARTIFACT_MAP=(
  "gaia-trace|test-artifacts/traceability-matrix.md"
  "gaia-readiness-check|../state/readiness-check-ledger.yaml"
  "gaia-threat-model|planning-artifacts/threat-model.md"
  "gaia-create-prd|planning-artifacts/prd.md"
  "gaia-create-arch|planning-artifacts/architecture.md"
  "gaia-create-epics|planning-artifacts/epics-and-stories.md"
  "gaia-test-strategy|test-artifacts/test-plan.md"
)

ART_BASE="${GAIA_ARTIFACTS_DIR:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts}"
checklist_tmp="$(mktemp)"
missing_count=0
bypass_count=0
present_count=0
{
  printf '\n## Lifecycle Skill Checklist (advisory)\n\n'
  for row in "${SKILL_ARTIFACT_MAP[@]}"; do
    skill="${row%%|*}"
    relpath="${row##*|}"
    artpath="$ART_BASE/$relpath"
    is_bypassed=0
    if printf '%s' "$bypass_json" | jq -e --arg s "$skill" '.bypasses | any(.skill == $s or .skill == ("/" + $s))' >/dev/null 2>&1; then
      is_bypassed=1
    fi
    if [ "$is_bypassed" -eq 1 ]; then
      reason="$(printf '%s' "$bypass_json" | jq -r --arg s "$skill" '[.bypasses[] | select(.skill == $s or .skill == ("/" + $s))][0].reason')"
      printf -- '- [~] %s — bypassed: %s\n' "$skill" "$reason"
      bypass_count=$((bypass_count + 1))
    elif [ -f "$artpath" ]; then
      printf -- '- [x] %s — %s present\n' "$skill" "$relpath"
      present_count=$((present_count + 1))
    else
      printf -- '- [ ] %s — %s MISSING (no bypass recorded)\n' "$skill" "$relpath"
      missing_count=$((missing_count + 1))
    fi
  done
  if [ "$missing_count" -eq 0 ] && [ "$bypass_count" -eq 0 ]; then
    printf '\nAll lifecycle skills produced their canonical artifacts; no bypasses recorded for %s.\n' "$SPRINT_ID"
  fi
} > "$checklist_tmp"

# Append to summary file (create if absent).
if [ ! -f "$SUMMARY_FILE" ]; then
  printf '# Sprint %s close summary\n\nClosed at %s.\n' "$SPRINT_ID" "$CLOSED_AT" > "$SUMMARY_FILE"
fi

# Record --force sentinel bypass in the close summary (audited escape hatch).
if [ "${_sentinel_force_bypassed:-0}" -eq 1 ]; then
  printf '\n## Sentinel bypass (--force)\n\nSprint %s was closed with --force: no sprint-review sentinel was present.\nThis bypass is audited. The operator accepted responsibility for closing without review evidence.\n' \
    "$SPRINT_ID" >> "$SUMMARY_FILE"
fi

cat "$checklist_tmp" >> "$SUMMARY_FILE"
rm -f "$checklist_tmp"

# ---------- Step 7 — Confirmation ----------

printf 'sprint %s closed at %s; archive: %s; lifecycle event recorded\n' \
  "$SPRINT_ID" "$CLOSED_AT" "$ARCHIVE_PATH"

_close_succeeded=1
exit 0
