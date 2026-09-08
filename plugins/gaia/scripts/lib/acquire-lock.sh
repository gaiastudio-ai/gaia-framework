#!/usr/bin/env bash
# acquire-lock.sh — shared locking helper.
#
# Public API:
#   acquire_lock <lock_file> <timeout_seconds> <fd_number>
#   release_lock <fd_number>
#   require_flock_for_parallel
#
# Network-mounted .gaia/ state trees are unsupported for parallel mode.
# The fallback uses ln(2) hard-link creation for atomicity; on NFS a lost
# reply can report EEXIST for a link that actually succeeded (the classic
# link-count workaround), and flock semantics vary across NFS versions.
# flock remains the recommended primitive on shared filesystems.
# Sequential mode is unaffected.
#
# Stale-lock recovery: when the fallback path encounters a lock file whose
# recorded PID is dead, it reaps the file once its age exceeds a threshold
# of max(60, 3 * timeout) seconds. The 60-second floor provides a safety
# margin against PID recycling. Override via GAIA_LOCK_REAP_SECONDS
# (test-only — not a user-facing surface). Until the threshold is reached,
# subsequent acquire attempts fail with a timeout, making the recovery
# window self-healing but not instant.
#
# Test-only env overrides (not user-facing):
#   GAIA_LOCK_REAP_SECONDS — override the stale-lock reap threshold.
#   GAIA_LOCK_FORCE_FALLBACK — when set to 1, forces the ln(2) hard-link
#     fallback path even when flock is present. Used by concurrency stress
#     tests to exercise the fallback on hosts where flock exists.

set -euo pipefail
LC_ALL=C; export LC_ALL

# --- Source-time probes (environment only, no project paths) ---

_ACQUIRE_LOCK_FLOCK_BIN="$(command -v flock 2>/dev/null || true)"

if stat -c %Y "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  _ACQUIRE_LOCK_STAT_FMT="gnu"
elif stat -f %m "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  _ACQUIRE_LOCK_STAT_FMT="bsd"
else
  _ACQUIRE_LOCK_STAT_FMT=""
fi

# --- Internal: per-fd registry (Bash 3.2 compatible via indirect vars) ---
# Each fd gets two variables: _AL_PATH_<fd> and _AL_MODE_<fd>.
# Mode is "flock" or "fallback". Path is the lock file path.

_al_set_registry() {
  local fd="$1" mode="$2" path="$3"
  eval "_AL_PATH_${fd}=\"\$path\""
  eval "_AL_MODE_${fd}=\"\$mode\""
}

_al_get_path() {
  local fd="$1"
  local var="_AL_PATH_${fd}"
  printf '%s' "${!var:-}"
}

_al_get_mode() {
  local fd="$1"
  local var="_AL_MODE_${fd}"
  printf '%s' "${!var:-}"
}

_al_clear_registry() {
  local fd="$1"
  eval "_AL_PATH_${fd}="
  eval "_AL_MODE_${fd}="
}

# --- Internal: file age in seconds ---

_al_file_age() {
  local path="$1"
  local mtime now
  now="$(date +%s)"
  if [ "$_ACQUIRE_LOCK_STAT_FMT" = "gnu" ]; then
    mtime="$(stat -c %Y "$path" 2>/dev/null)" || return 1
  elif [ "$_ACQUIRE_LOCK_STAT_FMT" = "bsd" ]; then
    mtime="$(stat -f %m "$path" 2>/dev/null)" || return 1
  else
    return 1
  fi
  printf '%s' "$(( now - mtime ))"
}

# --- Internal: debug trace ---

_al_trace() {
  if [ "${ACQUIRE_LOCK_DEBUG:-}" = "1" ] && [ -n "${ACQUIRE_LOCK_DEBUG_LOG:-}" ]; then
    printf '%s %s %s\n' "$1" "$2" "$(date +%s)" >> "$ACQUIRE_LOCK_DEBUG_LOG" 2>/dev/null || true
  fi
}

# --- Internal: stale-lock reap ---

_al_try_reap() {
  local lock_file="$1" timeout="$2"
  local reap_threshold="${GAIA_LOCK_REAP_SECONDS:-}"
  if [ -z "$reap_threshold" ]; then
    local triple=$(( timeout * 3 ))
    reap_threshold=$(( triple > 60 ? triple : 60 ))
  fi

  # A symlink at the lock path is never a legitimate lock. The lock file is
  # only ever created by hard-linking a private temp file, so a symlink is
  # either a dangling remnant (which ln(2) keeps rejecting with EEXIST, and
  # which the [ -f ] test below would otherwise skip forever) or a planted
  # redirect aimed at making a later write land on the target. Unlink it
  # unconditionally and report the path as reclaimed.
  if [ -L "$lock_file" ]; then
    rm -f "$lock_file" 2>/dev/null || true
    return 0
  fi

  if [ ! -f "$lock_file" ]; then
    return 1
  fi

  local recorded_pid=""
  # Read PID and discard the epoch (used only as a format marker).
  read -r recorded_pid _ < "$lock_file" 2>/dev/null || true

  # No valid PID line — ownerless file, immediately stale.
  # A correctly held lock always contains "<pid> <epoch>\n" (created
  # atomically via hard-link). An empty file is a legitimate post-release
  # sentinel (transition-story-status.sh, set-story-sprint.sh re-touch the
  # path for path-split-resolution compatibility) or a remnant from a prior
  # version's bare `touch`. Reap silently — this is expected, not an anomaly.
  if [ -z "$recorded_pid" ] || ! [ "$recorded_pid" -gt 0 ] 2>/dev/null; then
    rm -f "$lock_file" 2>/dev/null || true
    return 0
  fi

  # PID alive — never reap regardless of age.
  if kill -0 "$recorded_pid" 2>/dev/null; then
    return 1
  fi

  # PID dead — reap only if age exceeds threshold.
  # PID recycling note: a recycled PID is a false positive on kill -0.
  # The reap threshold (60s minimum) provides the second gate.
  local age
  age="$(_al_file_age "$lock_file" 2>/dev/null)" || age=""
  if [ -n "$age" ] && [ "$age" -ge "$reap_threshold" ]; then
    rm -f "$lock_file" 2>/dev/null || true
    printf 'acquire-lock: reaped stale lock %s (pid=%s dead, age=%ss)\n' \
      "$lock_file" "$recorded_pid" "$age" >&2
    return 0
  fi

  # PID dead but file not old enough yet — do not reap.
  return 1
}

# --- Public: acquire_lock <lock_file> <timeout_seconds> <fd_number> ---

acquire_lock() {
  local lock_file="$1" timeout="$2" fd="$3"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

  # Fast path: flock present (unless GAIA_LOCK_FORCE_FALLBACK overrides).
  if [ -n "$_ACQUIRE_LOCK_FLOCK_BIN" ] && [ "${GAIA_LOCK_FORCE_FALLBACK:-}" != "1" ]; then
    # Never open through a symlink: `exec >` follows it and truncates the
    # target, so a symlink planted at the lock path turns lock acquisition
    # into a write primitive against an arbitrary file. The fallback path is
    # already safe (it unlinks the symlink itself, leaving the target
    # intact); unlink here so both modes converge on that behaviour.
    if [ -L "$lock_file" ]; then
      rm -f "$lock_file" 2>/dev/null || true
    fi
    eval "exec ${fd}>\"${lock_file}\""
    if "$_ACQUIRE_LOCK_FLOCK_BIN" -x -w "$timeout" "$fd"; then
      _al_set_registry "$fd" "flock" "$lock_file"
      _al_trace "acquire" "$lock_file"
      return 0
    fi
    # Timeout — close the fd and report failure.
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi

  # Fallback path: ln(2) EEXIST atomic-create spin-loop with exponential
  # backoff + jitter. The lock file is created atomically WITH content:
  # write <pid> <epoch> to a private temp file, then hard-link it to the
  # lock path (link(2) creation is atomic — it fails with EEXIST if the
  # target exists). This ensures no acquirer ever observes an empty file.
  local start_epoch
  start_epoch="$(date +%s)"
  local base_ms=50
  local attempt=0
  local lock_dir
  lock_dir="$(dirname "$lock_file")"

  while true; do
    local now_epoch
    now_epoch="$(date +%s)"
    local elapsed=$(( now_epoch - start_epoch ))
    if [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi

    # Try to reap stale lock.
    _al_try_reap "$lock_file" "$timeout" || true

    # Atomic create-with-content: write to a temp file, then hard-link.
    # ln fails atomically if the target already exists (EEXIST).
    # The temp name must be unique per ACQUIRER, not per process: bash
    # subshells share $$ with their parent, so a bare "$$" name collides
    # between concurrent subshells of one script (and between any two
    # acquirers that happen to share a PID namespace view). Two acquirers on
    # one temp path race: A writes it, B reopens it with O_TRUNC, A links the
    # now-empty file into place and publishes a zero-byte lock. BASHPID is
    # per-subshell but is a Bash 4 feature, so fall back to $$ on Bash 3.2
    # and add $RANDOM, which is reseeded per subshell, to disambiguate there.
    local tmp_lock="${lock_dir}/.lock-tmp.${BASHPID:-$$}.$$.$RANDOM"
    # Record the chosen temp path. It exists only between the write and the
    # ln/unlink a few microseconds later, so directory sampling cannot
    # observe it reliably; the trace is what makes per-acquirer uniqueness
    # checkable at all.
    _al_trace "tmp" "$tmp_lock"
    if ! printf '%s %s\n' "$$" "$now_epoch" > "$tmp_lock" 2>/dev/null; then
      rm -f "$tmp_lock" 2>/dev/null || true
      return 1
    fi
    if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
      rm -f "$tmp_lock" 2>/dev/null || true
      _al_set_registry "$fd" "fallback" "$lock_file"
      _al_trace "acquire" "$lock_file"
      return 0
    fi
    rm -f "$tmp_lock" 2>/dev/null || true

    attempt=$(( attempt + 1 ))
    # Exponential backoff: 50, 100, 150 (cap) ms + jitter 0-49ms.
    # The cap is deliberately low. A waiter that sleeps ~500ms overshoots a
    # lock freed early in that window: with N concurrent writers and a short
    # hold, the queue drains slower than the work takes and waiters burn
    # their whole timeout without ever seeing the free window. Capping the
    # re-probe interval near 150ms keeps pickup prompt while still backing
    # off enough to avoid a busy spin. Jitter stays proportional to the cap
    # so concurrent waiters still desynchronise.
    if [ "$attempt" -le 1 ]; then
      base_ms=50
    elif [ "$attempt" -le 2 ]; then
      base_ms=100
    else
      base_ms=150
    fi
    local jitter=$(( RANDOM % 50 ))
    local sleep_ms=$(( base_ms + jitter ))

    # Debug log: record each sleep value for jitter divergence testing.
    if [ "${ACQUIRE_LOCK_DEBUG:-}" = "1" ] && [ -n "${ACQUIRE_LOCK_DEBUG_LOG:-}" ]; then
      printf '%s\n' "$sleep_ms" >> "$ACQUIRE_LOCK_DEBUG_LOG" 2>/dev/null || true
    fi

    # Sleep — a single well-formed decimal that both BSD and GNU accept.
    sleep "$(printf '%d.%03d' $((sleep_ms / 1000)) $((sleep_ms % 1000)))" 2>/dev/null \
      || sleep 1
  done
}

# --- Public: release_lock <fd_number> ---

release_lock() {
  local fd="$1"
  local lf
  lf="$(_al_get_path "$fd")"
  [ -n "$lf" ] || return 0  # Not registered — idempotent no-op.
  local mode
  mode="$(_al_get_mode "$fd")"

  _al_trace "release" "$lf"

  if [ "$mode" = "flock" ]; then
    # Drop the advisory lock explicitly, then close the descriptor. Closing
    # alone releases the lock only when the last fd referring to that open
    # file description goes away; an explicit -u makes the release
    # unconditional and does not depend on no duplicate fd surviving.
    if [ -n "$_ACQUIRE_LOCK_FLOCK_BIN" ]; then
      "$_ACQUIRE_LOCK_FLOCK_BIN" -u "$fd" 2>/dev/null || true
    fi
    eval "exec ${fd}>&-" 2>/dev/null || true
  elif [ "$mode" = "fallback" ]; then
    # Ownership-checked removal: only remove if we are the recorded owner.
    local holder=""
    read -r holder _ < "$lf" 2>/dev/null || true
    if [ "$holder" = "$$" ]; then
      rm -f "$lf" 2>/dev/null || true
    else
      printf 'acquire-lock: release_lock fd=%s — not owner (file pid=%s, self=%s)\n' \
        "$fd" "$holder" "$$" >&2
    fi
  fi

  _al_clear_registry "$fd"
}

# --- Public: require_flock_for_parallel ---

require_flock_for_parallel() {
  # Re-probe at call time (not the source-time cache).
  if ! command -v flock >/dev/null 2>&1; then
    printf 'FATAL: parallel execution requires flock (util-linux). ' >&2
    printf 'Install via "brew install util-linux" (macOS) or ' >&2
    printf '"apt-get install util-linux" (Debian/Ubuntu), ' >&2
    printf 'or run sequentially.\n' >&2
    return 1
  fi
  # Presence of the binary is not enough: the forced-fallback override makes
  # every acquisition take the ln(2) path, so passing the gate on "flock is
  # installed" while the override is set would report a guarantee the run
  # does not have. The gate is fail-closed, so refuse instead.
  if [ "${GAIA_LOCK_FORCE_FALLBACK:-}" = "1" ]; then
    printf 'FATAL: parallel execution requires flock, but GAIA_LOCK_FORCE_FALLBACK=1 ' >&2
    printf 'forces the hard-link fallback path. Unset it, or run sequentially.\n' >&2
    return 1
  fi
}

# --- CLI entry point (only when executed directly, not sourced) ---

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--check-parallel" ]; then
  require_flock_for_parallel
  exit $?
fi
