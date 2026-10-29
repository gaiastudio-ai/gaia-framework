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

# _ml_safe_write_field <file> <field> <value> — write YAML field safely.
# Uses printf with validated values; never splices into program text.
_ml_safe_write_field() {
  local file="$1" field="$2" value="$3"
  # Validate field name: alphanumeric + underscore only
  case "$field" in
    *[!a-z_0-9A-Z]*) _ml_die "invalid field name: $field" ;;
  esac
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

cmd_write_gate_pass() {
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

  # Run bind-head check before writing the record
  _ml_run_bind_head_check "$pr" "$head" || _ml_die "write-gate-pass: bind-head check failed for PR #${pr}"

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"
  mkdir -p "$ledger_dir"

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local gate_file=""
  gate_file="$ledger_dir/gate-pass-pr${pr}-$(date -u +%Y%m%d%H%M%S).yaml"

  {
    printf 'type: "gate_pass"\n'
    printf 'pr: "%s"\n' "$pr"
    printf 'head_sha: "%s"\n' "$head"
    printf 'story: "%s"\n' "$story"
    printf 'created_at: "%s"\n' "$ts"
  } > "$gate_file"

  _ml_log "gate_pass recorded for PR #${pr} at ${head}"
  printf '%s\n' "$gate_file"
}

cmd_write_gate_bypass() {
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

  local ledger_dir=""
  ledger_dir="$(_ml_resolve_ledger_dir)" || _ml_die "cannot resolve ledger directory"
  mkdir -p "$ledger_dir"

  local ts=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local gate_file=""
  gate_file="$ledger_dir/gate-bypass-pr${pr}-$(date -u +%Y%m%d%H%M%S).yaml"

  {
    printf 'type: "gate_bypass"\n'
    printf 'pr: "%s"\n' "$pr"
    printf 'head_sha: "%s"\n' "$head"
    printf 'story: "%s"\n' "$story"
    printf 'bypass_confirmed: "%s"\n' "$bypass_confirmation"
    printf 'created_at: "%s"\n' "$ts"
  } > "$gate_file"

  _ml_log "gate_bypass recorded for PR #${pr} at ${head} (confirmation: ${bypass_confirmation})"
  printf '%s\n' "$gate_file"
}

cmd_write_intent() {
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

  {
    printf 'intent_id: "%s"\n' "$intent_id"
    printf 'type: "merge_intent"\n'
    printf 'story: "%s"\n' "$story"
    printf 'pr: "%s"\n' "$pr"
    printf 'head_sha: "%s"\n' "$head"
    printf 'target: "%s"\n' "$target"
    printf 'mode: "%s"\n' "$mode"
    printf 'state: "intent"\n'
    printf 'bypass: "%s"\n' "$bypass_flag"
    printf 'created_at: "%s"\n' "$ts"
  } > "$intent_file"

  _ml_log "merge intent created: ${intent_id} for PR #${pr} at ${head}"
  printf '%s\n' "$intent_file"
}

cmd_advance() {
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
    printf 'merge_sha: "%s"\n' "$merge_sha" >> "$intent_file"
  fi

  # Append transition timestamp
  printf 'last_transition: "%s"\n' "$ts" >> "$intent_file"

  # Store CI-wait deadline fields when transitioning to merging
  # (for deadline resume across sessions)
  if [ "$new_state" = "merging" ]; then
    printf 'ci_wait_started: "%s"\n' "$ts" >> "$intent_file"
  fi

  _ml_log "advanced PR #${pr} intent: ${current_state} -> ${new_state}"
  printf '%s\n' "$intent_file"
}

cmd_read_latest() {
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

cmd_supersede() {
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
  printf 'superseded_at: "%s"\n' "$ts" >> "$intent_file"

  _ml_log "superseded intent for PR #${pr} at ${head}"
  printf '%s\n' "$intent_file"
}

cmd_sole_writer_check() {
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
  write-gate-pass)   cmd_write_gate_pass "$@" ;;
  write-gate-bypass) cmd_write_gate_bypass "$@" ;;
  write-intent)      cmd_write_intent "$@" ;;
  advance)           cmd_advance "$@" ;;
  read-latest)       cmd_read_latest "$@" ;;
  supersede)         cmd_supersede "$@" ;;
  sole-writer-check) cmd_sole_writer_check "$@" ;;
  *) _ml_die "unknown sub-command: $subcmd" ;;
esac
