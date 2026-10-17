#!/usr/bin/env bash
# concurrent-resource-ledger.sh — cross-session resource ledger.
#
# Sole writer of .gaia/state/.concurrent-resource-ledger.json.
# Manages dev-slot and teammate budget claims across concurrent sessions.
#
# Subcommands:
#   claim     --sprint <id> --pid <pid> --dev <n> --teammates <n>
#   release   --sprint <id> --pid <pid> --dev <n> --teammates <n>
#   heartbeat --sprint <id> --pid <pid>
#   cleanup   --sprint <id> --pid <pid>
#   reap
#   start-heartbeat-loop --sprint <id> --pid <pid>
#
# Exit codes:
#   0 — success
#   1 — budget exhausted (caller queues or retries with bounded backoff)
#   3 — lock timeout (pass-through from acquire_lock)
#   4 — non-regular-file lock path (pass-through from acquire_lock)
#   5 — identity re-check mismatch (pass-through from acquire_lock)
#   6 — corrupt or unparsable ledger (callers stop, no retry)
#   7 — ledger lock unavailable (generic acquire_lock failure or lock-dir
#       creation failure; callers stop and surface like exit 6)

set -euo pipefail
LC_ALL=C; export LC_ALL

# ---------- Source the lock library ----------

_CRL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/acquire-lock.sh
. "${_CRL_SCRIPT_DIR}/lib/acquire-lock.sh"

# ---------- Constants ----------

_CRL_LEDGER_EXIT_CORRUPT=6
_CRL_LEDGER_EXIT_LOCK_UNAVAIL=7

_CRL_STALE_TIMEOUT="${GAIA_LEDGER_STALE_TIMEOUT:-300}"
_CRL_HEARTBEAT_INTERVAL="${GAIA_LEDGER_HEARTBEAT_INTERVAL:-60}"

# ---------- Config resolution ----------

_crl_config_file() {
  local c
  for c in "${GAIA_SHARED_CONFIG:-}" \
           "${PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
           "${CLAUDE_PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
           "$PWD/.gaia/config/project-config.yaml"; do
    case "$c" in ''|/.gaia/config/project-config.yaml) continue ;; esac
    if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 0
}

# _crl_config_int <parent> <child> <default> — read one integer from config.
_crl_config_int() {
  local parent="$1" child="$2" default="$3" cfg raw
  cfg="$(_crl_config_file)"
  [ -n "$cfg" ] || { printf '%s' "$default"; return 0; }

  if command -v yq >/dev/null 2>&1; then
    raw="$(yq -o=json ".${parent}.${child}" "$cfg" 2>/dev/null)" || raw=""
  elif command -v python3 >/dev/null 2>&1; then
    raw="$(python3 - "$cfg" "$parent" "$child" <<'CRLPY' 2>/dev/null || true
import sys, json
try:
    import yaml
except Exception:
    sys.exit(1)
d = yaml.safe_load(open(sys.argv[1])) or {}
v = (d.get(sys.argv[2]) or {})
v = v.get(sys.argv[3]) if isinstance(v, dict) else None
print(json.dumps(v))
CRLPY
)"
  else
    raw=""
  fi

  case "$raw" in
    ''|null) printf '%s' "$default"; return 0 ;;
    *[!0-9]*) printf '%s' "$default"; return 0 ;;
  esac
  [ "$raw" -ge 0 ] 2>/dev/null || { printf '%s' "$default"; return 0; }
  printf '%s' "$raw"
}

# ---------- State directory resolution ----------

_crl_state_dir() {
  local d
  for d in "${GAIA_STATE_DIR:-}" \
           "${PROJECT_ROOT:-}/.gaia/state" \
           "${CLAUDE_PROJECT_ROOT:-}/.gaia/state" \
           "$PWD/.gaia/state"; do
    case "$d" in ''|/.gaia/state) continue ;; esac
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  printf '%s' "${PROJECT_ROOT:-.}/.gaia/state"
}

# ---------- Single-sprint mode check (AC5, R28) ----------

_crl_is_single_sprint_mode() {
  # Single-sprint mode: max_concurrent_active absent or 1
  # AND no per-sprint files exist under .gaia/state/.
  local limit
  limit="$(_crl_config_int sprint max_concurrent_active 1)"
  if [ "$limit" -gt 1 ] 2>/dev/null; then
    return 1  # concurrent mode
  fi

  local state_dir
  state_dir="$(_crl_state_dir)"
  if [ -d "$state_dir" ]; then
    local per_sprint
    per_sprint="$(find "$state_dir" -maxdepth 1 -name 'sprint-status-*.yaml' \
      ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || per_sprint=""
    if [ -n "$per_sprint" ]; then
      return 1  # transitional state — not single-sprint
    fi
  fi

  return 0  # single-sprint mode
}

# ---------- Session ID resolution ----------

_crl_resolve_session_id() {
  local sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -z "$sid" ]; then
    printf 'concurrent-resource-ledger: no session ID (set CLAUDE_CODE_SESSION_ID or CLAUDE_SESSION_ID)\n' >&2
    return 1
  fi
  # Validate: alphanumeric, hyphens, underscores only (same as session binding).
  case "$sid" in
    *[!A-Za-z0-9_-]*)
      printf 'concurrent-resource-ledger: invalid session ID: %s\n' "$sid" >&2
      return 1
      ;;
  esac
  printf '%s' "$sid"
}

# ---------- Lock helpers ----------

_crl_lock_fd=8

_crl_acquire_l2() {
  local state_dir
  state_dir="$(_crl_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true
  local lock_path="${state_dir}/${GAIA_LOCK_L2_PATH}"
  local rc=0
  acquire_lock "$lock_path" "$GAIA_LOCK_L2_TIMEOUT" "$_crl_lock_fd" --strict || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  # Pass through known lock exit codes; map everything else to exit 7.
  case "$rc" in
    "$ACQUIRE_LOCK_EXIT_TIMEOUT"|"$ACQUIRE_LOCK_EXIT_SYMLINK"|"$ACQUIRE_LOCK_EXIT_IDENTITY")
      return "$rc"
      ;;
    *)
      printf 'concurrent-resource-ledger: ledger lock unavailable (acquire_lock exit %d)\n' "$rc" >&2
      return "$_CRL_LEDGER_EXIT_LOCK_UNAVAIL"
      ;;
  esac
}

_crl_release_l2() {
  release_lock "$_crl_lock_fd"
}

# ---------- Ledger file path ----------

_crl_ledger_path() {
  local state_dir
  state_dir="$(_crl_state_dir)"
  printf '%s' "${state_dir}/.concurrent-resource-ledger.json"
}

# ---------- Atomic write ----------

_crl_tmp_file=""

_crl_cleanup_tmp() {
  if [ -n "$_crl_tmp_file" ] && [ -f "$_crl_tmp_file" ]; then
    rm -f "$_crl_tmp_file" 2>/dev/null || true
  fi
}

_crl_atomic_write() {
  local ledger_path="$1" content="$2"
  local state_dir
  state_dir="$(dirname "$ledger_path")"
  mkdir -p "$state_dir" 2>/dev/null || true
  _crl_tmp_file="$(mktemp "${state_dir}/.ledger-tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$_crl_tmp_file" 2>/dev/null; then
    rm -f "$_crl_tmp_file" 2>/dev/null || true
    _crl_tmp_file=""
    return 1
  fi
  if ! mv -f "$_crl_tmp_file" "$ledger_path" 2>/dev/null; then
    rm -f "$_crl_tmp_file" 2>/dev/null || true
    _crl_tmp_file=""
    return 1
  fi
  _crl_tmp_file=""
  return 0
}

# ---------- Ledger validation ----------

_crl_validate_ledger() {
  local ledger_path="$1"
  if [ ! -f "$ledger_path" ]; then
    return 0  # absent is fine — will be initialised
  fi

  local content
  content="$(cat "$ledger_path" 2>/dev/null)" || {
    printf 'concurrent-resource-ledger: cannot read ledger file: %s\n' "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  }

  # Parse with jq — fail closed on any error.
  if ! printf '%s' "$content" | jq empty 2>/dev/null; then
    printf 'concurrent-resource-ledger: corrupt ledger (invalid JSON): %s\n' "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  fi

  # Validate schema_version.
  local sv
  sv="$(printf '%s' "$content" | jq -r '.schema_version // empty' 2>/dev/null)" || sv=""
  if [ -z "$sv" ]; then
    printf 'concurrent-resource-ledger: corrupt ledger (missing schema_version): %s\n' "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  fi
  if [ "$sv" != "1.0" ]; then
    printf 'concurrent-resource-ledger: corrupt ledger (unsupported schema_version: %s): %s\n' "$sv" "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  fi

  # Validate budget fields exist.
  local bcheck
  bcheck="$(printf '%s' "$content" | jq -r '
    if (.budget | type) != "object" then "bad"
    elif (.budget.max_parallel_dev_slots | type) != "number" then "bad"
    elif (.budget.teammate_dispatch_ceiling | type) != "number" then "bad"
    else "ok" end
  ' 2>/dev/null)" || bcheck="bad"
  if [ "$bcheck" != "ok" ]; then
    printf 'concurrent-resource-ledger: corrupt ledger (invalid budget fields): %s\n' "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  fi

  # Validate sessions map.
  local scheck
  scheck="$(printf '%s' "$content" | jq -r '
    if (.sessions | type) != "object" then "bad"
    else
      [.sessions | to_entries[] | select(
        (.value.sprint_id | type) != "string" or
        (.value.pid | type) != "number" or
        (.value.heartbeat_epoch | type) != "number" or
        (.value.dev_slots_claimed | type) != "number" or
        (.value.teammates_claimed | type) != "number" or
        (.value.dev_slots_claimed < 0) or
        (.value.teammates_claimed < 0)
      )] | if length > 0 then "bad" else "ok" end
    end
  ' 2>/dev/null)" || scheck="bad"
  if [ "$scheck" != "ok" ]; then
    printf 'concurrent-resource-ledger: corrupt ledger (invalid session entries): %s\n' "$ledger_path" >&2
    return "$_CRL_LEDGER_EXIT_CORRUPT"
  fi

  return 0
}

# ---------- Read or initialise ledger ----------

_crl_read_or_init() {
  local ledger_path="$1" max_slots="$2" max_teammates="$3"

  if [ ! -f "$ledger_path" ]; then
    # Initialise empty ledger.
    local init
    init="$(jq -n --arg sv "1.0" \
      --argjson ms "$max_slots" \
      --argjson mt "$max_teammates" \
      '{schema_version: $sv, budget: {max_parallel_dev_slots: $ms, teammate_dispatch_ceiling: $mt}, sessions: {}}')"
    _crl_atomic_write "$ledger_path" "$init" || return 1
  fi

  # Validate.
  _crl_validate_ledger "$ledger_path" || return $?

  cat "$ledger_path"
}

# ---------- Stale reaping ----------

_crl_reap_stale() {
  local ledger_json="$1"
  local state_dir
  state_dir="$(_crl_state_dir)"
  local now
  now="$(date +%s)"
  local sessions_root="${state_dir}/sessions"
  local sessions_root_exists=0
  [ -d "$sessions_root" ] && sessions_root_exists=1

  local reaped_any=0
  local keys
  keys="$(printf '%s' "$ledger_json" | jq -r '.sessions | keys[]' 2>/dev/null)" || keys=""

  local sid entry_pid entry_hb age pid_dead=0 binding_gone=0

  for sid in $keys; do
    entry_pid="$(printf '%s' "$ledger_json" | jq -r --arg k "$sid" '.sessions[$k].pid' 2>/dev/null)" || continue
    entry_hb="$(printf '%s' "$ledger_json" | jq -r --arg k "$sid" '.sessions[$k].heartbeat_epoch' 2>/dev/null)" || continue

    pid_dead=0
    binding_gone=0

    # Factor 1: PID alive?
    if ! kill -0 "$entry_pid" 2>/dev/null; then
      pid_dead=1
    fi

    # Binding directory factor: when sessions root exists, check.
    if [ "$sessions_root_exists" -eq 1 ]; then
      if [ ! -d "${sessions_root}/${sid}" ]; then
        binding_gone=1
      fi
    fi

    # Binding dir gone + sessions root exists => reap regardless of PID.
    if [ "$sessions_root_exists" -eq 1 ] && [ "$binding_gone" -eq 1 ]; then
      age=$(( now - entry_hb ))
      printf 'reaping stale session %s (pid=%s dead, age=%ss)\n' "$sid" "$entry_pid" "$age" >&2
      ledger_json="$(printf '%s' "$ledger_json" | jq --arg k "$sid" 'del(.sessions[$k])')"
      reaped_any=1
      continue
    fi

    # Two-factor check: PID dead AND heartbeat stale.
    if [ "$pid_dead" -eq 1 ]; then
      age=$(( now - entry_hb ))
      if [ "$age" -gt "$_CRL_STALE_TIMEOUT" ]; then
        printf 'reaping stale session %s (pid=%s dead, age=%ss)\n' "$sid" "$entry_pid" "$age" >&2
        ledger_json="$(printf '%s' "$ledger_json" | jq --arg k "$sid" 'del(.sessions[$k])')"
        reaped_any=1
      fi
    fi
  done

  printf '%s' "$ledger_json"
  if [ "$reaped_any" -eq 1 ]; then return 0; fi
  return 0
}

# ---------- Subcommand: claim ----------

_crl_claim() {
  local sprint_id="$1" pid="$2" dev_slots="$3" teammates="$4"

  # Read budget from config (not from the ledger's cached budget field).
  local max_slots max_teammates
  max_slots="$(_crl_config_int parallel_execution max_parallel_dev_slots 4)"
  max_teammates="$(_crl_config_int parallel_execution teammate_dispatch_ceiling 12)"

  local session_id
  session_id="$(_crl_resolve_session_id)" || return 1

  # Acquire L2.
  _crl_acquire_l2 || return $?
  trap '_crl_cleanup_tmp; _crl_release_l2' EXIT INT TERM

  local ledger_path
  ledger_path="$(_crl_ledger_path)"

  local ledger_json
  ledger_json="$(_crl_read_or_init "$ledger_path" "$max_slots" "$max_teammates")" || {
    local rc=$?
    _crl_release_l2
    trap - EXIT INT TERM
    return "$rc"
  }

  # Reap stale entries first.
  ledger_json="$(_crl_reap_stale "$ledger_json")"

  # Sum current claims (excluding this session's existing entry if any).
  local total_dev total_tm
  total_dev="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" \
    '[.sessions | to_entries[] | select(.key != $sid) | .value.dev_slots_claimed] | add // 0')" || total_dev=0
  total_tm="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" \
    '[.sessions | to_entries[] | select(.key != $sid) | .value.teammates_claimed] | add // 0')" || total_tm=0

  # Add this session's existing claims if it already has an entry.
  local existing_dev existing_tm
  existing_dev="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" \
    '.sessions[$sid].dev_slots_claimed // 0')" || existing_dev=0
  existing_tm="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" \
    '.sessions[$sid].teammates_claimed // 0')" || existing_tm=0

  local new_dev new_tm
  new_dev=$(( existing_dev + dev_slots ))
  new_tm=$(( existing_tm + teammates ))

  # Budget check against config limits.
  local would_dev would_tm
  would_dev=$(( total_dev + new_dev ))
  would_tm=$(( total_tm + new_tm ))

  if [ "$would_dev" -gt "$max_slots" ] || [ "$would_tm" -gt "$max_teammates" ]; then
    # Budget exhausted — write ledger (with reaped entries removed) and refuse.
    _crl_atomic_write "$ledger_path" "$ledger_json" || true
    _crl_release_l2
    trap - EXIT INT TERM
    printf 'concurrent-resource-ledger: budget exhausted (dev: %d/%d, teammates: %d/%d)\n' \
      "$would_dev" "$max_slots" "$would_tm" "$max_teammates" >&2
    return 1
  fi

  # Write the claim.
  local now
  now="$(date +%s)"
  ledger_json="$(printf '%s' "$ledger_json" | jq \
    --arg sid "$session_id" \
    --arg sprint "$sprint_id" \
    --argjson pid "$pid" \
    --argjson hb "$now" \
    --argjson dev "$new_dev" \
    --argjson tm "$new_tm" \
    --argjson ms "$max_slots" \
    --argjson mt "$max_teammates" \
    '.budget.max_parallel_dev_slots = $ms |
     .budget.teammate_dispatch_ceiling = $mt |
     .sessions[$sid] = {
       sprint_id: $sprint,
       pid: $pid,
       heartbeat_epoch: $hb,
       dev_slots_claimed: $dev,
       teammates_claimed: $tm
     }'
  )"

  _crl_atomic_write "$ledger_path" "$ledger_json" || {
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  }

  _crl_release_l2
  trap - EXIT INT TERM
  return 0
}

# ---------- Subcommand: release ----------

_crl_release() {
  local sprint_id="$1" pid="$2" dev_slots="$3" teammates="$4"

  local session_id
  session_id="$(_crl_resolve_session_id)" || return 1

  _crl_acquire_l2 || return $?
  trap '_crl_cleanup_tmp; _crl_release_l2' EXIT INT TERM

  local ledger_path
  ledger_path="$(_crl_ledger_path)"

  if [ ! -f "$ledger_path" ]; then
    printf 'concurrent-resource-ledger: release on missing ledger (no-op)\n' >&2
    _crl_release_l2
    trap - EXIT INT TERM
    return 0
  fi

  local ledger_json
  ledger_json="$(_crl_read_or_init "$ledger_path" 4 12)" || {
    local rc=$?
    _crl_release_l2
    trap - EXIT INT TERM
    return "$rc"
  }

  # Check if session entry exists.
  local has_entry
  has_entry="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" \
    'if .sessions[$sid] then "yes" else "no" end')" || has_entry="no"

  if [ "$has_entry" = "\"no\"" ] || [ "$has_entry" = "no" ]; then
    printf 'concurrent-resource-ledger: release on missing session entry %s (no-op)\n' "$session_id" >&2
    _crl_release_l2
    trap - EXIT INT TERM
    return 0
  fi

  # Decrement, clamped at 0, refresh heartbeat.
  local now
  now="$(date +%s)"
  ledger_json="$(printf '%s' "$ledger_json" | jq \
    --arg sid "$session_id" \
    --argjson dev "$dev_slots" \
    --argjson tm "$teammates" \
    --argjson hb "$now" \
    '.sessions[$sid].dev_slots_claimed = ([(.sessions[$sid].dev_slots_claimed - $dev), 0] | max) |
     .sessions[$sid].teammates_claimed = ([(.sessions[$sid].teammates_claimed - $tm), 0] | max) |
     .sessions[$sid].heartbeat_epoch = $hb'
  )"

  _crl_atomic_write "$ledger_path" "$ledger_json" || {
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  }

  _crl_release_l2
  trap - EXIT INT TERM
  return 0
}

# ---------- Subcommand: heartbeat ----------

_crl_heartbeat() {
  local sprint_id="$1" pid="$2"

  local session_id
  session_id="$(_crl_resolve_session_id)" || return 1

  _crl_acquire_l2 || return $?
  trap '_crl_cleanup_tmp; _crl_release_l2' EXIT INT TERM

  local ledger_path
  ledger_path="$(_crl_ledger_path)"

  if [ ! -f "$ledger_path" ]; then
    printf 'concurrent-resource-ledger: heartbeat on missing ledger — refusing\n' >&2
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  fi

  local ledger_json
  ledger_json="$(_crl_read_or_init "$ledger_path" 4 12)" || {
    local rc=$?
    _crl_release_l2
    trap - EXIT INT TERM
    return "$rc"
  }

  # Check if session entry exists.
  local has_entry
  has_entry="$(printf '%s' "$ledger_json" | jq -r --arg sid "$session_id" \
    'if .sessions[$sid] then "yes" else "no" end')" || has_entry="no"

  if [ "$has_entry" = "no" ]; then
    printf 'concurrent-resource-ledger: heartbeat on missing session entry %s — refusing (not recreated)\n' "$session_id" >&2
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  fi

  # Validate PID matches the entry's recorded pid.
  local entry_pid
  entry_pid="$(printf '%s' "$ledger_json" | jq -r --arg sid "$session_id" \
    '.sessions[$sid].pid')" || entry_pid=""

  if [ "$entry_pid" != "$pid" ]; then
    printf 'concurrent-resource-ledger: heartbeat PID mismatch (entry=%s, caller=%s) — refusing\n' \
      "$entry_pid" "$pid" >&2
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  fi

  # Update heartbeat.
  local now
  now="$(date +%s)"
  ledger_json="$(printf '%s' "$ledger_json" | jq \
    --arg sid "$session_id" \
    --argjson hb "$now" \
    '.sessions[$sid].heartbeat_epoch = $hb'
  )"

  _crl_atomic_write "$ledger_path" "$ledger_json" || {
    _crl_release_l2
    trap - EXIT INT TERM
    return 1
  }

  _crl_release_l2
  trap - EXIT INT TERM
  return 0
}

# ---------- Subcommand: cleanup ----------

_crl_cleanup() {
  local sprint_id="$1" pid="$2"

  local session_id
  session_id="$(_crl_resolve_session_id)" || return 1

  _crl_acquire_l2 || return $?
  trap '_crl_cleanup_tmp; _crl_release_l2' EXIT INT TERM

  local ledger_path
  ledger_path="$(_crl_ledger_path)"

  if [ -f "$ledger_path" ]; then
    local ledger_json
    ledger_json="$(_crl_read_or_init "$ledger_path" 4 12)" || {
      local rc=$?
      _crl_release_l2
      trap - EXIT INT TERM
      return "$rc"
    }

    # Remove session entry.
    ledger_json="$(printf '%s' "$ledger_json" | jq --arg sid "$session_id" 'del(.sessions[$sid])')"
    _crl_atomic_write "$ledger_path" "$ledger_json" || true
  fi

  _crl_release_l2
  trap - EXIT INT TERM

  # Stop the heartbeat loop and remove PID file.
  local state_dir
  state_dir="$(_crl_state_dir)"
  local hb_pidfile="${state_dir}/.ledger-heartbeat-${session_id}.pid"
  if [ -f "$hb_pidfile" ]; then
    local hb_pid
    hb_pid="$(cat "$hb_pidfile" 2>/dev/null)" || hb_pid=""
    if [ -n "$hb_pid" ] && kill -0 "$hb_pid" 2>/dev/null; then
      kill "$hb_pid" 2>/dev/null || true
      # Brief wait for the process to exit.
      local _wait=0
      while [ "$_wait" -lt 10 ] && kill -0 "$hb_pid" 2>/dev/null; do
        sleep 0.1 2>/dev/null || sleep 1
        _wait=$((_wait + 1))
      done
    fi
    rm -f "$hb_pidfile" 2>/dev/null || true
  fi

  return 0
}

# ---------- Subcommand: reap ----------

_crl_reap() {
  _crl_acquire_l2 || return $?
  trap '_crl_cleanup_tmp; _crl_release_l2' EXIT INT TERM

  local ledger_path
  ledger_path="$(_crl_ledger_path)"

  if [ ! -f "$ledger_path" ]; then
    _crl_release_l2
    trap - EXIT INT TERM
    return 0
  fi

  local ledger_json
  ledger_json="$(_crl_read_or_init "$ledger_path" 4 12)" || {
    local rc=$?
    _crl_release_l2
    trap - EXIT INT TERM
    return "$rc"
  }

  ledger_json="$(_crl_reap_stale "$ledger_json")"

  _crl_atomic_write "$ledger_path" "$ledger_json" || true

  _crl_release_l2
  trap - EXIT INT TERM
  return 0
}

# ---------- Subcommand: start-heartbeat-loop ----------

_crl_start_heartbeat_loop() {
  local sprint_id="$1" pid="$2"

  local session_id
  session_id="$(_crl_resolve_session_id)" || return 1

  local state_dir
  state_dir="$(_crl_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true

  local hb_pidfile="${state_dir}/.ledger-heartbeat-${session_id}.pid"

  # Launch the background heartbeat loop.
  (
    trap 'exit 0' INT TERM
    while true; do
      sleep "$_CRL_HEARTBEAT_INTERVAL" 2>/dev/null || sleep 60

      # Self-exit when the session PID dies.
      if ! kill -0 "$pid" 2>/dev/null; then
        exit 0
      fi

      # Update heartbeat — ignore errors (lock contention, etc.).
      "$0" heartbeat --sprint "$sprint_id" --pid "$pid" 2>/dev/null || true
    done
  ) </dev/null >/dev/null 2>&1 &

  local loop_pid=$!
  printf '%s' "$loop_pid" > "$hb_pidfile"
  printf '%s\n' "$loop_pid"
  return 0
}

# ---------- CLI argument parsing ----------

_crl_main() {
  local subcmd="${1:-}"
  [ -n "$subcmd" ] || {
    printf 'Usage: concurrent-resource-ledger.sh <claim|release|heartbeat|cleanup|reap|start-heartbeat-loop> [args]\n' >&2
    return 1
  }
  shift

  # Check single-sprint mode — all operations are no-ops except reap.
  if [ "$subcmd" != "reap" ] && _crl_is_single_sprint_mode; then
    return 0
  fi

  local sprint_id="" pid="" dev_slots=0 teammates=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint)  sprint_id="${2:-}";  shift 2 ;;
      --pid)     pid="${2:-}";        shift 2 ;;
      --dev)     dev_slots="${2:-0}"; shift 2 ;;
      --teammates) teammates="${2:-0}"; shift 2 ;;
      *) shift ;;
    esac
  done

  case "$subcmd" in
    claim)
      _crl_claim "$sprint_id" "$pid" "$dev_slots" "$teammates"
      ;;
    release)
      _crl_release "$sprint_id" "$pid" "$dev_slots" "$teammates"
      ;;
    heartbeat)
      _crl_heartbeat "$sprint_id" "$pid"
      ;;
    cleanup)
      _crl_cleanup "$sprint_id" "$pid"
      ;;
    reap)
      if _crl_is_single_sprint_mode; then
        return 0
      fi
      _crl_reap
      ;;
    start-heartbeat-loop)
      _crl_start_heartbeat_loop "$sprint_id" "$pid"
      ;;
    *)
      printf 'concurrent-resource-ledger: unknown subcommand: %s\n' "$subcmd" >&2
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '_crl_cleanup_tmp' EXIT
  _crl_main "$@"
fi
