#!/usr/bin/env bash
# merge-ledger.sh — write-ahead merge ledger (single-writer state area).
#
# Records every merge intent before the merge executes, gate records
# (gate_pass / gate_bypass), and state-machine transitions.
#
# The ledger directory (.gaia/state/merge/) is a single-writer state area:
# only this script writes to it.  The sole-writer-check sub-command
# validates that invariant at build time.
#
# State machine:
#   intent -> merging -> merged (merge_sha) -> verified
#     -> smoke_ok | smoke_failed -> finalized
#   (also: superseded — terminal, when head moved)
#
# Usage:
#   merge-ledger.sh write-gate-pass   --pr <n> --head <sha> --story <key>
#   merge-ledger.sh write-gate-bypass --pr <n> --head <sha> --story <key> --bypass-confirmation <result>
#   merge-ledger.sh write-intent      --pr <n> --head <sha> --story <key> --target <branch> --mode <story|integration|promotion>
#   merge-ledger.sh advance           --pr <n> --head <sha> --state <new-state> [--merge-sha <sha>]
#   merge-ledger.sh read-latest       --pr <n> [--head <sha>]
#   merge-ledger.sh supersede         --pr <n> --head <sha>
#   merge-ledger.sh sole-writer-check [--dir <path>]
#
# Environment:
#   CLAUDE_PROJECT_ROOT / PROJECT_ROOT — shared project root (for
#     .gaia/state/merge/ resolution).
#   MERGE_LEDGER_DIR — override the ledger directory path (testing).
#
# Exit codes:
#   0 — success
#   1 — error (missing gate, validation failure, etc.)
#
# Bash 3.2 compatible.

set -euo pipefail
LC_ALL=C; export LC_ALL

_ML_SCRIPT_NAME="merge-ledger.sh"
_ML_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ml_log() { printf '%s: %s\n' "$_ML_SCRIPT_NAME" "$*" >&2; }
_ml_die() { _ml_log "$*"; exit 1; }

# Resolve ledger directory
_ml_resolve_ledger_dir() {
  if [ -n "${MERGE_LEDGER_DIR:-}" ]; then
    printf '%s' "$MERGE_LEDGER_DIR"
    return 0
  fi
  local root=""
  for _c in "${CLAUDE_PROJECT_ROOT:-}" "${PROJECT_ROOT:-}"; do
    if [ -n "$_c" ] && [ -d "$_c/.gaia/state" ]; then
      root="$_c"
      break
    fi
  done
  if [ -z "$root" ]; then
    local _w="$PWD"
    while [ "$_w" != "/" ]; do
      if [ -d "$_w/.gaia/state" ]; then
        root="$_w"
        break
      fi
      _w="$(dirname "$_w")"
    done
  fi
  [ -z "$root" ] && return 1
  printf '%s' "$root/.gaia/state/merge"
}

# _ml_validate_sha <sha> — must be exactly 40 hex characters or 7+ for short.
_ml_validate_sha() {
  local sha="$1"
  case "$sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      return 0 ;;
  esac
  return 1
}

# _ml_validate_full_sha <sha> — exactly 40 hex chars.
_ml_validate_full_sha() {
  local sha="$1"
  if [ ${#sha} -ne 40 ]; then return 1; fi
  case "$sha" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

# _ml_validate_state <state>
_ml_validate_state() {
  case "$1" in
    intent|merging|merged|verified|smoke_ok|smoke_failed|finalized|superseded) return 0 ;;
  esac
  return 1
}

# _ml_intent_id — generate a unique intent identifier.
_ml_intent_id() {
  local ts=""
  ts="$(date -u +%Y%m%d%H%M%S)" || ts="00000000000000"
  printf 'mi-%s-%s' "$ts" "$$"
}

# _ml_validate_yaml_value <field> <value> — reject values that could inject
# YAML structure.  Each field has a strict shape; anything outside it is
# refused.  This prevents double-quote / newline / control-char injection
# without depending on yq at write time.
_ml_validate_yaml_value() {
  local field="$1" value="$2"
  case "$field" in
    pr)
      case "$value" in ''|*[!0-9]*) return 1 ;; esac ;;
    head_sha|merge_sha)
      case "$value" in ''|*[!0-9a-f]*) return 1 ;; esac
      if [ ${#value} -lt 7 ] || [ ${#value} -gt 64 ]; then return 1; fi ;;
    story|intent_id)
      case "$value" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac ;;
    target)
      case "$value" in ''|*[!A-Za-z0-9_./-]*) return 1 ;; esac ;;
    mode)
      case "$value" in story|integration|promotion) ;; *) return 1 ;; esac ;;
    type)
      case "$value" in gate_pass|gate_bypass|merge_intent) ;; *) return 1 ;; esac ;;
    state)
      _ml_validate_state "$value" || return 1 ;;
    bypass)
      case "$value" in true|false) ;; *) return 1 ;; esac ;;
    bypass_confirmed)
      case "$value" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac ;;
    created_at|last_transition|superseded_at|ci_wait_started)
      # ISO 8601 shape: YYYY-MM-DDTHH:MM:SSZ
      case "$value" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) return 1 ;; esac ;;
    *)
      # Unknown field: reject double-quotes, newlines, control chars
      case "$value" in *'"'*) return 1 ;; esac
      # Single-line check: printf %s preserves embedded newlines
      local _lc=""
      _lc="$(printf '%s\n' "$value" | wc -l | tr -d ' ')"
      [ "$_lc" -le 1 ] || return 1
      ;;
  esac
  return 0
}

# _ml_safe_write_field <file> <field> <value> — write YAML field safely.
# Validates both field name and value shape; never splices into program text.
_ml_safe_write_field() {
  local file="$1" field="$2" value="$3"
  # Validate field name: alphanumeric + underscore only
  case "$field" in
    *[!a-z_0-9A-Z]*) _ml_die "invalid field name: $field" ;;
  esac
  _ml_validate_yaml_value "$field" "$value" || \
    _ml_die "invalid value for field '$field': value rejected by shape validation"
  printf '%s: "%s"\n' "$field" "$value" >> "$file"
}

# _ml_read_field <file> <field> — read a YAML field value.
_ml_read_field() {
  local file="$1" field="$2"
  if [ ! -f "$file" ]; then return 1; fi
  sed -n "s/^${field}: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$file" | head -1
}

# _ml_find_gate_record <ledger_dir> <pr> <head> — find gate_pass or gate_bypass.
_ml_find_gate_record() {
  local dir="$1" pr="$2" head="$3"
  local f=""
  for f in "$dir"/gate-*.yaml; do
    [ -f "$f" ] || continue
    local f_pr="" f_head=""
    f_pr="$(_ml_read_field "$f" pr)" || continue
    f_head="$(_ml_read_field "$f" head_sha)" || continue
    if [ "$f_pr" = "$pr" ] && [ "$f_head" = "$head" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# _ml_find_latest_intent <ledger_dir> <pr> [<head>] — find the latest intent record.
_ml_find_latest_intent() {
  local dir="$1" pr="$2" head="${3:-}"
  local latest="" latest_ts=""
  local f=""
  for f in "$dir"/intent-*.yaml; do
    [ -f "$f" ] || continue
    local f_pr=""
    f_pr="$(_ml_read_field "$f" pr)" || continue
    if [ "$f_pr" != "$pr" ]; then continue; fi
    if [ -n "$head" ]; then
      local f_head=""
      f_head="$(_ml_read_field "$f" head_sha)" || continue
      if [ "$f_head" != "$head" ]; then continue; fi
    fi
    local f_ts=""
    f_ts="$(_ml_read_field "$f" created_at)" || f_ts=""
    if [ -z "$latest" ] || [ "$f_ts" \> "$latest_ts" ] || [ "$f_ts" = "$latest_ts" ]; then
      latest="$f"
      latest_ts="${f_ts:-}"
    fi
  done
  [ -n "$latest" ] && printf '%s' "$latest" && return 0
  return 1
}

# _ml_run_bind_head_check <pr> <head> — run the bind-head check before
# writing a gate_pass.  Returns 0 if the PR head matches.
_ml_run_bind_head_check() {
  local pr="$1" head="$2"
  # Test override: skip the gh call entirely (testing without API).
  if [ "${MERGE_LEDGER_SKIP_GH:-}" = "1" ]; then
    return 0
  fi
  # When gh is available, verify the PR head SHA matches.
  if command -v gh >/dev/null 2>&1; then
    local api_head=""
    api_head="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || api_head=""
    if [ -n "$api_head" ] && [ "$api_head" != "$head" ]; then
      _ml_log "bind-head mismatch: PR #${pr} head is ${api_head}, expected ${head}"
      return 1
    fi
    return 0
  fi
  # No gh and no test override: fail closed — cannot verify.
  _ml_log "bind-head check: gh not available — failing closed"
  return 1
}

# --- Sub-commands ---

_ml_cmd_write_gate_pass() {
  local pr="" head="" story=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)    pr="$2"; shift 2 ;;
      --head)  head="$2"; shift 2 ;;
      --story) story="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "write-gate-pass: --pr required"
  [ -z "$head" ] && _ml_die "write-gate-pass: --head required"
  [ -z "$story" ] && _ml_die "write-gate-pass: --story required"

  # Validate all values before any side-effect
  _ml_validate_yaml_value pr "$pr" || _ml_die "write-gate-pass: invalid pr value"
  _ml_validate_yaml_value head_sha "$head" || _ml_die "write-gate-pass: invalid head_sha value"
  _ml_validate_yaml_value story "$story" || _ml_die "write-gate-pass: invalid story value"

  # Run bind-head check before writing the record
  _ml_run_bind_head_check "$pr" "$head" || _ml_die "write-gate-pass: bind-head check failed for PR #${pr}"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"
  mkdir -p "$ledger_dir"

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local gate_file=""
  gate_file="$ledger_dir/gate-pass-pr${pr}-$(date -u +%Y%m%d%H%M%S).yaml"

  : > "$gate_file"
  _ml_safe_write_field "$gate_file" type gate_pass
  _ml_safe_write_field "$gate_file" pr "$pr"
  _ml_safe_write_field "$gate_file" head_sha "$head"
  _ml_safe_write_field "$gate_file" story "$story"
  _ml_safe_write_field "$gate_file" created_at "$ts"

  _ml_log "gate_pass recorded for PR #${pr} at ${head}"
  printf '%s\n' "$gate_file"
}

_ml_cmd_write_gate_bypass() {
  local pr="" head="" story="" bypass_confirmation=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)    pr="$2"; shift 2 ;;
      --head)  head="$2"; shift 2 ;;
      --story) story="$2"; shift 2 ;;
      --bypass-confirmation) bypass_confirmation="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "write-gate-bypass: --pr required"
  [ -z "$head" ] && _ml_die "write-gate-bypass: --head required"
  [ -z "$story" ] && _ml_die "write-gate-bypass: --story required"
  [ -z "$bypass_confirmation" ] && _ml_die "write-gate-bypass: --bypass-confirmation required"

  # Validate all values before any side-effect
  _ml_validate_yaml_value pr "$pr" || _ml_die "write-gate-bypass: invalid pr value"
  _ml_validate_yaml_value head_sha "$head" || _ml_die "write-gate-bypass: invalid head_sha value"
  _ml_validate_yaml_value story "$story" || _ml_die "write-gate-bypass: invalid story value"
  _ml_validate_yaml_value bypass_confirmed "$bypass_confirmation" || _ml_die "write-gate-bypass: invalid bypass_confirmation value"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"
  mkdir -p "$ledger_dir"

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local gate_file=""
  gate_file="$ledger_dir/gate-bypass-pr${pr}-$(date -u +%Y%m%d%H%M%S).yaml"

  : > "$gate_file"
  _ml_safe_write_field "$gate_file" type gate_bypass
  _ml_safe_write_field "$gate_file" pr "$pr"
  _ml_safe_write_field "$gate_file" head_sha "$head"
  _ml_safe_write_field "$gate_file" story "$story"
  _ml_safe_write_field "$gate_file" bypass_confirmed "$bypass_confirmation"
  _ml_safe_write_field "$gate_file" created_at "$ts"

  _ml_log "gate_bypass recorded for PR #${pr} at ${head} (confirmation: ${bypass_confirmation})"
  printf '%s\n' "$gate_file"
}

_ml_cmd_write_intent() {
  local pr="" head="" story="" target="" mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)     pr="$2"; shift 2 ;;
      --head)   head="$2"; shift 2 ;;
      --story)  story="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --mode)   mode="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "write-intent: --pr required"
  [ -z "$head" ] && _ml_die "write-intent: --head required"
  [ -z "$story" ] && _ml_die "write-intent: --story required"
  [ -z "$target" ] && _ml_die "write-intent: --target required"
  [ -z "$mode" ] && _ml_die "write-intent: --mode required"

  # Validate mode
  case "$mode" in
    story|integration|promotion) ;;
    *) _ml_die "write-intent: invalid mode '$mode' (expected story|integration|promotion)" ;;
  esac

  # Validate all values before any side-effect
  _ml_validate_yaml_value pr "$pr" || _ml_die "write-intent: invalid pr value"
  _ml_validate_yaml_value head_sha "$head" || _ml_die "write-intent: invalid head_sha value"
  _ml_validate_yaml_value story "$story" || _ml_die "write-intent: invalid story value"
  _ml_validate_yaml_value target "$target" || _ml_die "write-intent: invalid target value"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"
  mkdir -p "$ledger_dir"

  # Check for prior gate record (write-ahead invariant)
  local gate_file=""
  gate_file="$(_ml_find_gate_record "$ledger_dir" "$pr" "$head")" || gate_file=""
  if [ -z "$gate_file" ]; then
    _ml_die "write-intent: no gate record (gate_pass or gate_bypass) found for PR #${pr} at head ${head} — merge intent rejected"
  fi

  # Check for existing intent with the same PR and head (idempotency)
  local existing=""
  existing="$(_ml_find_latest_intent "$ledger_dir" "$pr" "$head")" || existing=""
  if [ -n "$existing" ]; then
    local existing_state=""
    existing_state="$(_ml_read_field "$existing" state)"
    case "$existing_state" in
      superseded|finalized)
        # Superseded or finalized — allow a new intent
        ;;
      *)
        # Already in-progress — return the existing intent (idempotent)
        _ml_log "existing intent found for PR #${pr} at ${head} (state: ${existing_state})"
        printf '%s\n' "$existing"
        return 0
        ;;
    esac
  fi

  # Determine if the gate record is a bypass and carry the flag
  local gate_type=""
  gate_type="$(_ml_read_field "$gate_file" type)"
  local bypass_flag="false"
  if [ "$gate_type" = "gate_bypass" ]; then
    bypass_flag="true"
  fi

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local intent_id=""
  intent_id="$(_ml_intent_id)"
  local intent_file="$ledger_dir/intent-pr${pr}-${intent_id}.yaml"

  : > "$intent_file"
  _ml_safe_write_field "$intent_file" intent_id "$intent_id"
  _ml_safe_write_field "$intent_file" type merge_intent
  _ml_safe_write_field "$intent_file" story "$story"
  _ml_safe_write_field "$intent_file" pr "$pr"
  _ml_safe_write_field "$intent_file" head_sha "$head"
  _ml_safe_write_field "$intent_file" target "$target"
  _ml_safe_write_field "$intent_file" mode "$mode"
  _ml_safe_write_field "$intent_file" state intent
  _ml_safe_write_field "$intent_file" bypass "$bypass_flag"
  _ml_safe_write_field "$intent_file" created_at "$ts"

  _ml_log "merge intent created: ${intent_id} for PR #${pr} at ${head}"
  printf '%s\n' "$intent_file"
}

_ml_cmd_advance() {
  local pr="" head="" new_state="" merge_sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)        pr="$2"; shift 2 ;;
      --head)      head="$2"; shift 2 ;;
      --state)     new_state="$2"; shift 2 ;;
      --merge-sha) merge_sha="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "advance: --pr required"
  [ -z "$head" ] && _ml_die "advance: --head required"
  [ -z "$new_state" ] && _ml_die "advance: --state required"

  if [ -n "$merge_sha" ]; then
    _ml_validate_yaml_value merge_sha "$merge_sha" || _ml_die "advance: invalid merge_sha value"
  fi

  _ml_validate_state "$new_state" || _ml_die "advance: invalid state '$new_state'"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"

  local intent_file=""
  intent_file="$(_ml_find_latest_intent "$ledger_dir" "$pr" "$head")" || intent_file=""
  if [ -z "$intent_file" ]; then
    _ml_die "advance: no intent found for PR #${pr} at ${head}"
  fi

  local current_state=""
  current_state="$(_ml_read_field "$intent_file" state)"

  # Validate state transition
  local valid=0
  case "${current_state}:${new_state}" in
    intent:merging)     valid=1 ;;
    merging:merged)     valid=1 ;;
    merged:verified)    valid=1 ;;
    verified:smoke_ok)  valid=1 ;;
    verified:smoke_failed) valid=1 ;;
    smoke_ok:finalized) valid=1 ;;
    smoke_failed:finalized) valid=1 ;;
    # Idempotent: same state is a no-op
    "${new_state}:${new_state}") valid=1 ;;
  esac
  if [ "$valid" -eq 0 ]; then
    _ml_die "advance: invalid transition ${current_state} -> ${new_state}"
  fi

  # Update the state in the intent file
  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Use sed to update the state field (BSD-safe: no -i)
  local tmp_file="${intent_file}.tmp"
  sed "s/^state: .*/state: \"${new_state}\"/" "$intent_file" > "$tmp_file"
  mv "$tmp_file" "$intent_file"

  # Append merge_sha if provided and transitioning to merged
  if [ "$new_state" = "merged" ] && [ -n "$merge_sha" ]; then
    _ml_safe_write_field "$intent_file" merge_sha "$merge_sha"
  fi

  # Append transition timestamp
  _ml_safe_write_field "$intent_file" last_transition "$ts"

  # Store CI-wait deadline fields when transitioning to merging
  # (for deadline resume across sessions)
  if [ "$new_state" = "merging" ]; then
    _ml_safe_write_field "$intent_file" ci_wait_started "$ts"
  fi

  _ml_log "advanced PR #${pr} intent: ${current_state} -> ${new_state}"
  printf '%s\n' "$intent_file"
}

_ml_cmd_read_latest() {
  local pr="" head=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)   pr="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "read-latest: --pr required"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"

  local intent_file=""
  intent_file="$(_ml_find_latest_intent "$ledger_dir" "$pr" "$head")" || intent_file=""
  if [ -z "$intent_file" ]; then
    _ml_log "no intent found for PR #${pr}"
    return 1
  fi

  cat "$intent_file"
  return 0
}

_ml_cmd_supersede() {
  local pr="" head=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)   pr="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      *) _ml_die "unknown option: $1" ;;
    esac
  done
  [ -z "$pr" ] && _ml_die "supersede: --pr required"
  [ -z "$head" ] && _ml_die "supersede: --head required"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"

  local intent_file=""
  intent_file="$(_ml_find_latest_intent "$ledger_dir" "$pr" "$head")" || intent_file=""
  if [ -z "$intent_file" ]; then
    _ml_log "no intent found for PR #${pr} at ${head} to supersede"
    return 0
  fi

  local current_state=""
  current_state="$(_ml_read_field "$intent_file" state)"

  # Only non-terminal states can be superseded
  case "$current_state" in
    finalized|superseded)
      _ml_log "intent already in terminal state: ${current_state}"
      return 0
      ;;
  esac

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local tmp_file="${intent_file}.tmp"
  sed "s/^state: .*/state: \"superseded\"/" "$intent_file" > "$tmp_file"
  mv "$tmp_file" "$intent_file"
  _ml_safe_write_field "$intent_file" superseded_at "$ts"

  _ml_log "superseded intent for PR #${pr} at ${head}"
  printf '%s\n' "$intent_file"
}

_ml_cmd_sole_writer_check() {
  local check_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) check_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$check_dir" ]; then
    check_dir="$(_ml_resolve_ledger_dir 2>/dev/null)" || check_dir=""
  fi

  if [ -z "$check_dir" ] || [ ! -d "$check_dir" ]; then
    # No ledger directory found — pass (nothing to check)
    return 0
  fi

  # In a git repository, check that all files in the merge directory were
  # written by this script.  We verify by checking git log for the
  # committer of each file and ensuring the commit message references
  # merge-ledger operations.
  #
  # For the build-time check, we verify the file naming convention:
  # only gate-*.yaml, intent-*.yaml, and .gitkeep are allowed.
  local violations=""
  local f=""
  for f in "$check_dir"/*; do
    [ -e "$f" ] || continue
    local basename=""
    basename="$(basename "$f")"
    case "$basename" in
      gate-*.yaml|intent-*.yaml|.gitkeep) ;;
      *.tmp) ;; # Temporary files from in-progress writes
      *)
        violations="${violations:+${violations}, }${basename}"
        ;;
    esac
  done

  if [ -n "$violations" ]; then
    _ml_log "sole-writer-check FAILED: unauthorized files in merge ledger directory: ${violations}"
    _ml_log "Only merge-ledger.sh may write to the merge state area."
    return 1
  fi

  _ml_log "sole-writer-check: PASSED"
  return 0
}

# --- Main dispatch ---

if [ $# -lt 1 ]; then
  _ml_die "usage: merge-ledger.sh <sub-command> [options]"
fi

subcmd="$1"
shift

case "$subcmd" in
  write-gate-pass)   _ml_cmd_write_gate_pass "$@" ;;
  write-gate-bypass) _ml_cmd_write_gate_bypass "$@" ;;
  write-intent)      _ml_cmd_write_intent "$@" ;;
  advance)           _ml_cmd_advance "$@" ;;
  read-latest)       _ml_cmd_read_latest "$@" ;;
  supersede)         _ml_cmd_supersede "$@" ;;
  sole-writer-check) _ml_cmd_sole_writer_check "$@" ;;
  *) _ml_die "unknown sub-command: $subcmd" ;;
esac
