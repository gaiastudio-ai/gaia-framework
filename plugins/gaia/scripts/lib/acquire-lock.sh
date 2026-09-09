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
# Lock-path type policy: a lock path is only ever a REGULAR FILE. Anything
# else at that path breaks mutual exclusion rather than merely delaying it,
# so both modes refuse to treat a non-regular path as a lock:
#   - a symlink (dangling or not) is unlinked — it is never a legitimate
#     lock, and following it would turn acquisition into a write primitive
#     against the target;
#   - a socket/fifo/device is unlinked for the same reason;
#   - a DIRECTORY is never removed recursively. `ln SOURCE DIR` is the
#     link-into-directory form and ALWAYS succeeds, so a directory at the
#     lock path would let every concurrent acquirer "win" simultaneously.
#     An empty directory (or one holding only this helper's own
#     .lock-tmp.* residue) is rmdir'd after that residue is cleared;
#     anything else is a hard failure with a diagnostic, so mutual
#     exclusion can never silently degrade into no exclusion at all.
# Every successful create is additionally verified: the published lock path
# must be a regular file sharing an inode with the temp file that was linked
# into place, so a link that landed anywhere but the intended path is
# treated as "not acquired". On a host where neither stat(1) format works
# the inode half degrades away and the regular-file type check carries the
# guarantee on its own — that check is already sufficient for the directory
# case, which is the one that breaks exclusion outright.
#
# flock-mode symlink handling: an lstat/unlink/open sequence is inherently
# racy — a symlink swapped in after the check is still followed by the open,
# and with `exec >` (O_TRUNC) that turns acquisition into a write primitive
# that empties whatever the symlink points at. Three measures together
# remove the primitive rather than merely narrowing the window:
#   - the lock file is created first under `set -C` (noclobber, O_EXCL), so
#     a symlink already in place makes the create fail rather than traverse;
#   - the descriptor is opened with `>>` (O_APPEND), NEVER `>` (O_TRUNC).
#     flock(2) needs an open descriptor, not an emptied file, so even a
#     symlink that IS followed leaves its target byte-for-byte intact;
#   - after the open the path is re-checked: it must still be a non-symlink
#     regular file whose inode matches the descriptor's, or the descriptor
#     is closed and acquisition refuses.
# Residual window: bash cannot pass O_NOFOLLOW to `exec`, so an attacker
# who wins both races can still cause the open to land on their target —
# but with O_APPEND that open neither truncates nor writes, and the inode
# compare turns it into a detected refusal instead of a lock that excludes
# nobody. The fallback path (the live path wherever flock is absent) is
# structurally immune because ln(2) never traverses a final symlink.
#
# Test-only env overrides (not user-facing):
#   GAIA_LOCK_REAP_SECONDS — override the stale-lock reap threshold.
#   GAIA_LOCK_FORCE_FALLBACK — when set to 1, forces the ln(2) hard-link
#     fallback path even when flock is present. Used by concurrency stress
#     tests to exercise the fallback on hosts where flock exists.
#   ACQUIRE_LOCK_DEBUG — set to 1 (together with ACQUIRE_LOCK_DEBUG_LOG)
#     to enable trace output. Both must be set; either alone is a no-op.
#   ACQUIRE_LOCK_DEBUG_LOG — path the trace is appended to. Records
#     "acquire <path> <epoch>", "release <path> <epoch>" and
#     "tmp <temp-path> <epoch>" lines, plus raw backoff sleep_ms values
#     (one bare integer per line) used by the jitter-divergence tests.

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

# --- Internal: inode number of a path (portable, ALWAYS dereferencing) ---
#
# Returns the inode as a bare integer on stdout, or fails. Uses the same
# GNU/BSD stat format already probed at source time.
#
# `-L` is mandatory, not cosmetic. The descriptor paths this is used on are
# a symlink into procfs on Linux (/dev/fd is a symlink to /proc/self/fd, and
# each entry there is itself a symlink to the open file). Without -L, stat
# reports the inode of that procfs symlink rather than of the file it names,
# so a descriptor could never compare equal to its own path and every
# identity check would refuse — fail-closed for every caller on Linux, which
# is where the flock fast path is the live path. On macOS /dev/fd/N is a
# device node stat already resolves to the open file, so both forms agree
# there and the bug is invisible locally.
#
# A host where neither stat form works makes this fail, and every caller
# treats an unavailable inode as "not verified" rather than assuming the
# identity held.

_al_inode() {
  local path="$1" ino=""
  if [ "$_ACQUIRE_LOCK_STAT_FMT" = "gnu" ]; then
    ino="$(stat -L -c %i "$path" 2>/dev/null)" || ino=""
  elif [ "$_ACQUIRE_LOCK_STAT_FMT" = "bsd" ]; then
    ino="$(stat -L -f %i "$path" 2>/dev/null)" || ino=""
  fi
  case "$ino" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$ino"
}

# --- Internal: verify an opened descriptor still refers to the lock path ---
#
# Closes the residual lstat/open race in flock mode: after `exec {fd}>path`
# the path must still be a non-symlink regular file, and — where the host
# exposes descriptors as paths (/dev/fd/N, or /proc/self/fd/N) and stat is
# usable — the inode reachable through the descriptor must equal the inode
# of the path. A swap that happened between the create and the open changes
# one of those, so a mismatch is a refusal. Where descriptor paths or stat
# are unavailable the type checks alone still stand; they are what reject a
# symlink or directory, which is the case that breaks exclusion outright.

_al_verify_opened_fd() {
  local lock_file="$1" fd="$2"
  [ ! -L "$lock_file" ] || return 1
  [ -f "$lock_file" ] || return 1

  # Prefer /proc/self/fd where it exists (Linux): it is the direct form,
  # and /dev/fd there is only a symlink to it. Either works now that
  # _al_inode dereferences, but the direct path is one less indirection.
  local fd_path=""
  if [ -e "/proc/self/fd/${fd}" ]; then
    fd_path="/proc/self/fd/${fd}"
  elif [ -e "/dev/fd/${fd}" ]; then
    fd_path="/dev/fd/${fd}"
  else
    return 0
  fi

  local path_ino fd_ino
  path_ino="$(_al_inode "$lock_file" 2>/dev/null)" || return 0
  fd_ino="$(_al_inode "$fd_path" 2>/dev/null)" || return 0
  [ "$path_ino" = "$fd_ino" ]
}

# --- Internal: enforce the lock-path type policy ---
#
# Ensures the lock path is either absent or a plain regular file before a
# create attempt. Returns 0 when the path is usable (absent, or a regular
# file left for the reaper/ln to arbitrate) and 1 when it is not and could
# not be made so. The directory case emits a diagnostic and refuses rather
# than removing a tree, so a stray mkdir is loud instead of fail-open.

_al_enforce_path_type() {
  local lock_file="$1"

  # A symlink is never a legitimate lock: the file is only ever created by
  # hard-linking a private temp, so a symlink here is a dangling remnant
  # (which ln keeps rejecting EEXIST forever) or a planted redirect. Test
  # for it FIRST — [ -e ] follows symlinks, so a dangling one reads as absent.
  if [ -L "$lock_file" ]; then
    rm -f "$lock_file" 2>/dev/null || true
    return 0
  fi

  # Absent, or already a regular file: nothing to enforce.
  if [ ! -e "$lock_file" ] || [ -f "$lock_file" ]; then
    return 0
  fi

  # Exists but is not a regular file. A directory is the dangerous case:
  # `ln SOURCE DIR` links INTO the directory and always succeeds, so every
  # acquirer would win at once. Reclaim it only when it is provably ours to
  # reclaim — empty, or holding nothing but this helper's own temp residue.
  if [ -d "$lock_file" ]; then
    # No `| head -1` here: a pipeline whose reader exits early can raise
    # SIGPIPE under `set -o pipefail`, and the resulting empty result would
    # read as "empty directory" and reclaim a tree that must be refused.
    # Collect the whole listing and slice the first line in the shell.
    local leftover
    leftover="$(find "$lock_file" -mindepth 1 ! -name '.lock-tmp.*' 2>/dev/null)" || leftover=""
    leftover="${leftover%%$'\n'*}"
    if [ -n "$leftover" ]; then
      printf 'acquire-lock: lock path is a directory with unrelated contents: %s\n' \
        "$lock_file" >&2
      printf 'acquire-lock: refusing to use it as a lock — remove it by hand.\n' >&2
      return 1
    fi
    rm -f "$lock_file"/.lock-tmp.* 2>/dev/null || true
    if ! rmdir "$lock_file" 2>/dev/null; then
      printf 'acquire-lock: lock path is a directory that could not be removed: %s\n' \
        "$lock_file" >&2
      return 1
    fi
    return 0
  fi

  # Socket, fifo, device: not a directory, so ln(2) would reject it EEXIST
  # forever and nothing would ever reclaim it. Unlink it.
  rm -f "$lock_file" 2>/dev/null || true
  if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
    printf 'acquire-lock: lock path is not a regular file and could not be cleared: %s\n' \
      "$lock_file" >&2
    return 1
  fi
  return 0
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

  # Anything at the lock path that is not a plain regular file — a symlink,
  # a directory, a socket, a fifo — is illegitimate. Route every such case
  # through the single type-policy gate rather than testing only for the one
  # type this reaper happens to know about. Using an explicit
  # "exists but is not a regular file" arm (rather than the old negative
  # `[ ! -f ]`, which reads a directory as "absent" and silently declines)
  # means a third file type cannot slip through the same way.
  # Diagnostics are suppressed here: the acquire loop re-asserts the same
  # gate immediately afterwards and is the single place that reports the
  # refusal, so routing it through both would double every message.
  if [ -L "$lock_file" ] || { [ -e "$lock_file" ] && [ ! -f "$lock_file" ]; }; then
    _al_enforce_path_type "$lock_file" 2>/dev/null || return 1
    return 0
  fi

  # Genuinely absent: nothing to reap.
  if [ ! -e "$lock_file" ]; then
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
    # into a write primitive against an arbitrary file. Checking with
    # [ -L ] and then opening is three separate syscalls on a path an
    # attacker can rewrite in between, so do not rely on the check alone:
    #   1. enforce the type policy (unlink a symlink/socket, refuse a
    #      directory) so a stale artefact does not defeat step 2;
    #   2. create the file under `set -C` (noclobber => O_EXCL): if a
    #      symlink is planted before this, the create FAILS rather than
    #      traversing, and an existing regular lock file is left untouched;
    #   3. open the descriptor with `>>` (O_APPEND) rather than `>`
    #      (O_TRUNC). flock(2) only needs an open descriptor, never an
    #      emptied file, and O_TRUNC is the entire reason a followed symlink
    #      was destructive: an appending open of a symlink target leaves it
    #      byte-for-byte intact;
    #   4. re-verify AFTER the open that the path is still a non-symlink
    #      regular file whose inode matches the one actually opened, so a
    #      swap that wins the remaining window becomes a detected refusal
    #      rather than a lock nobody else is excluded from.
    _al_enforce_path_type "$lock_file" || return 1
    ( set -C; : > "$lock_file" ) 2>/dev/null || true
    eval "exec ${fd}>>\"${lock_file}\""
    if ! _al_verify_opened_fd "$lock_file" "$fd"; then
      eval "exec ${fd}>&-" 2>/dev/null || true
      printf 'acquire-lock: lock path changed identity during open: %s\n' \
        "$lock_file" >&2
      return 1
    fi
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

    # Refuse to link against anything that is not a plain regular file.
    # `ln SOURCE DIR` is the link-INTO-directory form and always succeeds,
    # so without this every concurrent acquirer would "win" at once and
    # mutual exclusion would silently disappear. The reaper above already
    # routes through the same gate; re-assert it here because it is the
    # invariant the ln(2) below depends on for its atomicity.
    if ! _al_enforce_path_type "$lock_file"; then
      return 1
    fi

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
    # Brace-wrap the redirection so 2>/dev/null covers the redirection
    # itself, not just printf's own stderr: an unwritable lock directory
    # otherwise leaks a raw `line NNN: <temp path>: Permission denied`
    # next to this script's curated diagnostics.
    if ! { printf '%s %s\n' "$$" "$now_epoch" > "$tmp_lock"; } 2>/dev/null; then
      rm -f "$tmp_lock" 2>/dev/null || true
      _al_trace "create-failed" "$tmp_lock"
      printf 'acquire-lock: cannot create a lock file under %s\n' "$lock_dir" >&2
      return 1
    fi
    if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
      # ln succeeding is NOT proof the lock was published at the intended
      # path: if the path is a directory the link landed INSIDE it, and
      # treating that as acquired hands the same lock to everybody. Confirm
      # the path is now a regular file that shares our temp's inode.
      # The type checks alone already reject the directory case ([ -f ] is
      # false for a directory), so a host with no usable stat still gets the
      # fix; the inode compare is the stronger form where stat is available.
      local published_ino tmp_ino
      published_ino="$(_al_inode "$lock_file" 2>/dev/null)" || published_ino=""
      tmp_ino="$(_al_inode "$tmp_lock" 2>/dev/null)" || tmp_ino=""
      if [ ! -L "$lock_file" ] && [ -f "$lock_file" ] && \
         [ "$published_ino" = "$tmp_ino" ]; then
        rm -f "$tmp_lock" 2>/dev/null || true
        _al_set_registry "$fd" "fallback" "$lock_file"
        _al_trace "acquire" "$lock_file"
        return 0
      fi
      # The link went somewhere else (or the path is not a regular file).
      # Unlink whatever we just created and treat this as not acquired.
      rm -f "$lock_file/$(basename "$tmp_lock")" 2>/dev/null || true
      rm -f "$tmp_lock" 2>/dev/null || true
      printf 'acquire-lock: refusing a lock that did not publish at %s\n' \
        "$lock_file" >&2
      return 1
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
