#!/usr/bin/env bash
# acquire-lock.sh — shared locking helper.
#
# Public API:
#   acquire_lock <lock_file> <timeout_seconds> <fd_number> [--strict]
#   release_lock <fd_number>
#   require_flock_for_parallel
#   acquire_lock_close_predicate <max_concurrent_active> <state_dir>
#
# Lock constants (exported after sourcing):
#   GAIA_LOCK_L1_TEMPLATE — per-sprint state lock path template
#   GAIA_LOCK_L2_PATH     — resource ledger lock (relative to state dir)
#   GAIA_LOCK_L3_PATH     — promotion-merge lock (relative to state dir)
#   GAIA_LOCK_L4_PATH     — sprint lifecycle lock (relative to state dir)
#   GAIA_LOCK_L5_PATH     — proxy lock (relative to state dir)
#   GAIA_LOCK_L1_TIMEOUT  — 5s
#   GAIA_LOCK_L2_TIMEOUT  — 5s
#   GAIA_LOCK_L3_TIMEOUT  — 120s (overridable via GAIA_MERGE_LOCK_TIMEOUT)
#   GAIA_LOCK_L4_TIMEOUT  — 10s
#   GAIA_LOCK_L5_TIMEOUT  — 2s
#   ACQUIRE_LOCK_EXIT_TIMEOUT  — exit code 3 (lock timeout)
#   ACQUIRE_LOCK_EXIT_SYMLINK  — exit code 4 (strict-mode non-regular-file)
#   ACQUIRE_LOCK_EXIT_IDENTITY — exit code 5 (strict-mode identity mismatch)
#   ACQUIRE_LOCK_EXIT_PUBLISH  — exit code 6 (publication check failed)
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
#
# Test-only function hooks (not env vars, not user-facing):
#   _al_pre_link_hook <lock_path> — called between the type gate and the
#     hard-link step in the fallback path. Lets tests swap a directory into
#     the lock path to prove the post-link publication check catches it.
#   _al_identity_hook <lock_path> <fd> — called during the strict-mode
#     post-lock identity re-check. Lets tests inject a deterministic
#     mismatch.
#   _al_reap_window_hook <lock_path> <shadow_path> — called in
#     _al_try_reap between the shadow pin and the final inode
#     comparison, before the guarded rm. Lets tests replace the lock
#     file and prove the inode guard catches the replacement.
#   _al_reap_pre_rm_hook <lock_path> — called in _al_try_reap after
#     the inode comparison passes and inside the reap mutex, just
#     before the rename-and-verify removal step. Lets tests pause a
#     single reaper in the real TOCTOU window to prove the mutex
#     serialises concurrent reapers.
#   _al_pre_flock_hook <lock_path> <fd> — called between opening the
#     descriptor and calling flock on every flock path. Lets tests
#     observe or manipulate the pre-flock state deterministically.
#   _al_post_link_hook <lock_path> <tmp_path> — called after a
#     successful ln but before the publication inode check. Lets tests
#     delete the temp to simulate a colliding writer and trigger the
#     refusal path.
#   _al_publish_cleanup_hook <lock_path> — called in the publication-
#     refusal cleanup path before the rename-and-verify that removes a
#     stale lock left by a failed acquirer. Lets tests inject a
#     replacement file to prove the cleanup does not delete it.

# Sourcing contract: this library DOES NOT alter the caller's shell options.
# Every public function sets its own errexit/pipefail internally via subshell
# or local save/restore.  LC_ALL=C is exported for deterministic sorting but
# does not affect option flags.
LC_ALL=C; export LC_ALL

# --- Source-time probes (environment only, no project paths) ---

_ACQUIRE_LOCK_FLOCK_BIN="$(command -v flock 2>/dev/null || true)"

# Probe flock capabilities on an isolated temp file (never the real lock).
# Result cached in _ACQUIRE_LOCK_FLOCK_CAP:
#   "w" — supports -w (timeout); use flock -x -w <N>.
#   "n" — supports -n (non-blocking) but not -w; use a polling loop.
#   ""  — incompatible (neither -w nor -n); cannot use flock.
_ACQUIRE_LOCK_FLOCK_CAP=""
if [ -n "$_ACQUIRE_LOCK_FLOCK_BIN" ]; then
  _al_cap_tmp="$(mktemp /tmp/.al-flock-cap.XXXXXXXXXX 2>/dev/null)" || _al_cap_tmp=""
  if [ -n "$_al_cap_tmp" ]; then
    if "$_ACQUIRE_LOCK_FLOCK_BIN" -x -w 0 "$_al_cap_tmp" true 2>/dev/null; then
      _ACQUIRE_LOCK_FLOCK_CAP="w"
    elif eval "exec 223<\"$_al_cap_tmp\"" 2>/dev/null; then
      if "$_ACQUIRE_LOCK_FLOCK_BIN" -n -x 223 2>/dev/null; then
        _ACQUIRE_LOCK_FLOCK_CAP="n"
        "$_ACQUIRE_LOCK_FLOCK_BIN" -u 223 2>/dev/null || true
      fi
      # Close fd 223 on every path (success or failure) so the probe
      # leaves no leaked descriptor.
      eval "exec 223<&-" 2>/dev/null || true
    fi
    rm -f "$_al_cap_tmp" 2>/dev/null || true
  fi
  unset _al_cap_tmp
fi

if stat -c %Y "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  _ACQUIRE_LOCK_STAT_FMT="gnu"
elif stat -f %m "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
  _ACQUIRE_LOCK_STAT_FMT="bsd"
else
  _ACQUIRE_LOCK_STAT_FMT=""
fi

# --- Lock constants (five independent, non-nested locks) ---

# Lock path templates (relative to the state directory).
# L1 is parameterized by sprint_id; the rest are fixed filenames.
export GAIA_LOCK_L1_TEMPLATE="sprint-status-{sprint_id}.yaml.lock"
export GAIA_LOCK_L2_PATH=".concurrent-resource-ledger.lock"
export GAIA_LOCK_L3_PATH=".promotion-merge.lock"
export GAIA_LOCK_L4_PATH=".sprint-lifecycle.lock"
export GAIA_LOCK_L5_PATH=".sprint-proxy.lock"

# Timeouts (seconds). L3 is overridable via GAIA_MERGE_LOCK_TIMEOUT.
export GAIA_LOCK_L1_TIMEOUT=5
export GAIA_LOCK_L2_TIMEOUT=5
export GAIA_LOCK_L3_TIMEOUT="${GAIA_MERGE_LOCK_TIMEOUT:-120}"
export GAIA_LOCK_L4_TIMEOUT=10
export GAIA_LOCK_L5_TIMEOUT=2

# Distinct exit codes.
export ACQUIRE_LOCK_EXIT_TIMEOUT=3
export ACQUIRE_LOCK_EXIT_SYMLINK=4
export ACQUIRE_LOCK_EXIT_IDENTITY=5
export ACQUIRE_LOCK_EXIT_PUBLISH=6

# --- Internal: shell-option save/restore (Bash 3.2 compatible) ---
#
# Each public function calls _al_save_opts on entry and _al_restore_opts on
# every return path, so the library never leaks errexit, nounset or pipefail
# into the sourcing shell.  The _al_saved_* variables are per-call
# (single-threaded bash), not per-nesting-level, which is safe because the
# only public entry points (acquire_lock, release_lock,
# require_flock_for_parallel, and the two predicates) never call each other.

_al_save_opts() {
  _al_saved_errexit=0;  case "$-" in *e*) _al_saved_errexit=1  ;; esac
  _al_saved_nounset=0;  case "$-" in *u*) _al_saved_nounset=1  ;; esac
  _al_saved_pipefail=0
  if set -o | grep -q 'pipefail.*on' 2>/dev/null; then _al_saved_pipefail=1; fi
  set -euo pipefail
}

_al_restore_opts() {
  [ "$_al_saved_errexit" = "1" ]  || set +e
  [ "$_al_saved_nounset" = "1" ]  || set +u
  [ "$_al_saved_pipefail" = "1" ] || set +o pipefail
}

# --- Internal: per-acquirer identity (Bash 3.2 compatible) ---
#
# _al_self_pid_via_sh <var_name>
#   Sets the named variable to the PID of the calling shell by spawning
#   sh -c 'echo $PPID' and reading the result from an exclusive temp
#   file (mktemp, O_EXCL). This is the macOS bash 3.2 fallback where
#   neither $BASHPID nor /proc exists. Fails closed (returns 1 with a
#   diagnostic) rather than falling back to $$ on any error, since $$
#   is shared across subshells and produces wrong identity.
#
# _al_set_self_pid <var_name>
#   Sets the named variable to the PID of the current shell. Must NOT
#   be called inside $() — command substitution forks and gives its own
#   PID. Strategy:
#     1. $BASHPID (bash 4+): immediate.
#     2. /proc/self/stat (Linux): read first field, no fork.
#     3. _al_self_pid_via_sh (macOS bash 3.2): one fork, exclusive temp.
#     4. Fail closed (return 1) — never falls back to $$.

_al_self_pid_via_sh() {
  local _var="$1"
  local _pid_tmp=""
  _pid_tmp="$(mktemp /tmp/.al-self-pid.XXXXXXXXXX 2>/dev/null)" || _pid_tmp=""
  if [ -z "$_pid_tmp" ]; then
    printf 'acquire-lock: cannot determine per-acquirer identity (mktemp failed)\n' >&2
    return 1
  fi
  sh -c 'echo $PPID' > "$_pid_tmp" 2>/dev/null || {
    rm -f "$_pid_tmp" 2>/dev/null || true
    printf 'acquire-lock: cannot determine per-acquirer identity (sh -c failed)\n' >&2
    return 1
  }
  local _read_pid=""
  read -r _read_pid < "$_pid_tmp" 2>/dev/null || _read_pid=""
  rm -f "$_pid_tmp" 2>/dev/null || true
  if [ -z "$_read_pid" ]; then
    printf 'acquire-lock: cannot determine per-acquirer identity (empty pid)\n' >&2
    return 1
  fi
  eval "$_var=\"\$_read_pid\""
}

_al_set_self_pid() {
  local _var="$1"
  if [ -n "${BASHPID:-}" ]; then
    eval "$_var=\"\$BASHPID\""
    return
  fi
  if [ -r /proc/self/stat ]; then
    local _stat_pid=""
    read -r _stat_pid _ < /proc/self/stat 2>/dev/null || _stat_pid=""
    if [ -n "$_stat_pid" ]; then
      eval "$_var=\"\$_stat_pid\""
      return
    fi
  fi
  _al_self_pid_via_sh "$_var"
}

# --- Internal: per-fd registry (Bash 3.2 compatible via indirect vars) ---
# Each fd gets three variables: _AL_PATH_<fd>, _AL_MODE_<fd>, _AL_OWNER_<fd>.
# Mode is "flock" or "fallback". Path is the lock file path. Owner is the
# per-acquirer PID recorded at acquisition time (from _al_self_pid).

_al_set_registry() {
  local fd="$1" mode="$2" path="$3" owner="${4:-}"
  eval "_AL_PATH_${fd}=\"\$path\""
  eval "_AL_MODE_${fd}=\"\$mode\""
  eval "_AL_OWNER_${fd}=\"\$owner\""
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

_al_get_owner() {
  local fd="$1"
  local var="_AL_OWNER_${fd}"
  printf '%s' "${!var:-}"
}

_al_clear_registry() {
  local fd="$1"
  eval "_AL_PATH_${fd}="
  eval "_AL_MODE_${fd}="
  eval "_AL_OWNER_${fd}="
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

# --- Internal: device:inode identity of a path (portable, ALWAYS dereferencing) ---
#
# Returns "dev:ino" on stdout, or fails. Used by strict-mode post-lock
# identity re-checks where inode alone is insufficient (a recycled inode on
# a different device would be a false match).

_al_dev_ino() {
  local path="$1" result=""
  if [ "$_ACQUIRE_LOCK_STAT_FMT" = "gnu" ]; then
    result="$(stat -L -c '%d:%i' "$path" 2>/dev/null)" || result=""
  elif [ "$_ACQUIRE_LOCK_STAT_FMT" = "bsd" ]; then
    result="$(stat -L -f '%d:%i' "$path" 2>/dev/null)" || result=""
  fi
  if [ -z "$result" ]; then
    return 1
  fi
  printf '%s' "$result"
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

  # The path existed but was not a regular file. Under concurrent reaping
  # (mv rename-and-verify), the file may vanish between -e and -f above.
  # Re-test: if the path is now absent or regular, the non-regular state
  # was a vacancy — return 0 and let the caller retry normally.
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
    leftover="$(find "$lock_file" -mindepth 1 ! -name '.lock-tmp.*' ! -name '.lock-reap.*' 2>/dev/null)" || leftover=""
    leftover="${leftover%%$'\n'*}"
    if [ -n "$leftover" ]; then
      printf 'acquire-lock: lock path is a directory with unrelated contents: %s\n' \
        "$lock_file" >&2
      printf 'acquire-lock: refusing to use it as a lock — remove it by hand.\n' >&2
      return 1
    fi
    rm -f "$lock_file"/.lock-tmp.* "$lock_file"/.lock-reap.* 2>/dev/null || true
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

# --- Internal: strict-mode path type enforcer ---
#
# Like _al_enforce_path_type but REFUSES (rather than cleaning up) any
# non-regular file at the lock path. Used only by cross-session locks
# (L2, L3, L4) in strict mode. Returns ACQUIRE_LOCK_EXIT_SYMLINK (4)
# with a stable diagnostic when the path is not a regular file.

_al_enforce_path_type_strict() {
  local lock_file="$1"

  # Symlink, directory, fifo, socket, device: refuse with a diagnostic.
  if [ -L "$lock_file" ] || { [ -e "$lock_file" ] && [ ! -f "$lock_file" ]; }; then
    printf 'lock_symlink_detected: %s\n' "$lock_file" >&2
    return "$ACQUIRE_LOCK_EXIT_SYMLINK"
  fi

  # Absent or already a regular file: fine.
  return 0
}

# --- Internal: strict-mode post-lock identity re-check ---
#
# After the lock is held, verify that the lock file's inode matches the
# held fd's inode. On mismatch, release and retry. Returns 0 on match,
# 1 on mismatch. Where stat is unavailable, degrades to pass (return 0).
#
# Uses inode-only comparison for the fd vs. lock-path check because the
# fd path's device number is unreliable: on macOS /dev/fd/N is a devfs
# device node whose stat reports the devfs device, not the real file's
# device, so a dev:ino comparison always fails there. The inode alone is
# sufficient to detect a replaced file (a swap produces a different inode).
# The dev:ino helper is used for the LOCK PATH side only when comparing
# two real paths (e.g. in the fallback identity re-check).

# Three-outcome identity verifier for flock descriptors.
#
# Returns:
#   0 — VERIFIED: the fd's inode equals the path's inode.
#   1 — MISMATCH: the path is gone, or its inode differs from the fd's.
#   2 — UNAVAILABLE: no usable fd path, or the fd inode lookup failed.
#
# UNAVAILABLE while ordinary-file stat works (_ACQUIRE_LOCK_STAT_FMT
# non-empty) is treated as a refusal by callers: the reaper can reap on
# such hosts, so an unverified flock would be unsafe. UNAVAILABLE with
# no usable stat at all is allowed (the reaper can't reap without stat,
# so the risk that drove this check does not exist).

_al_verify_fd_identity() {
  local lock_file="$1" fd="$2"

  # Test-only hook.
  if declare -F _al_identity_hook >/dev/null 2>&1; then
    _al_identity_hook "$lock_file" "$fd"
  fi

  local fd_path=""
  if [ -e "/proc/self/fd/${fd}" ]; then
    fd_path="/proc/self/fd/${fd}"
  elif [ -e "/dev/fd/${fd}" ]; then
    fd_path="/dev/fd/${fd}"
  else
    return 2  # UNAVAILABLE
  fi

  local fd_ino=""
  fd_ino="$(_al_inode "$fd_path" 2>/dev/null)" || fd_ino=""
  case "$fd_ino" in ''|*[!0-9]*) return 2 ;; esac  # non-numeric → UNAVAILABLE

  # Path gone → MISMATCH (the file was deleted/replaced).
  local path_ino=""
  path_ino="$(_al_inode "$lock_file" 2>/dev/null)" || path_ino=""
  if [ -z "$path_ino" ]; then
    return 1  # MISMATCH
  fi

  if [ "$path_ino" = "$fd_ino" ]; then
    return 0  # VERIFIED
  fi
  return 1    # MISMATCH
}

# Backward-compatible wrapper used by the old strict-mode callers.
_al_verify_identity_strict() {
  local _vid_rc=0
  _al_verify_fd_identity "$@" || _vid_rc=$?
  case "$_vid_rc" in
    0) return 0 ;;  # VERIFIED
    1) return 1 ;;  # MISMATCH
    2) # UNAVAILABLE: refuse if stat works, degrade to pass if not.
       if [ -n "$_ACQUIRE_LOCK_STAT_FMT" ]; then return 1; fi
       return 0 ;;
  esac
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

  # --- Step 1: Pin the inspected file via a shadow hard link ---
  # The shadow keeps the inode alive so the kernel cannot recycle it, and
  # gives the reaper a private path to read from (no other process can
  # unlink it). If ln fails, the file disappeared between the existence
  # check and the link attempt — do not reap.
  local lock_dir
  lock_dir="$(dirname "$lock_file")"
  local shadow="${lock_dir}/.lock-reap.$$.$RANDOM"
  if ! ln "$lock_file" "$shadow" 2>/dev/null; then
    return 1
  fi

  # --- Step 2: Read PID and epoch from the shadow ---
  # Reading from the shadow is safe: the shadow name is unique to this
  # process and no other process can unlink it. A failed read under the
  # old code was the root of Bug 2 — structurally impossible here.
  local recorded_pid=""
  if ! read -r recorded_pid _ < "$shadow" 2>/dev/null; then
    # Read failed. If the file has content (non-empty), the content is
    # unreadable (permissions or I/O error). A live holder's PID may be
    # inside. Conservative: do not reap (AC1).
    if [ -s "$shadow" ]; then
      rm -f "$shadow" 2>/dev/null || true
      return 1
    fi
    # Empty file: read "failed" because there was no content (EOF).
    # Fall through to the ownerless branch.
  fi

  # --- Step 3: Decide ---
  local _reap_candidate=0 age=""

  # Track whether fd 222 is held (for cleanup on all exit paths).
  local _reap_probe_held=0

  if [ -z "$recorded_pid" ] || ! [ "$recorded_pid" -gt 0 ] 2>/dev/null; then
    # No valid PID line — ownerless file (empty sentinel or remnant).
    # A reliable flock probe is REQUIRED before reaping: the file may
    # be held by a flock-mode process (which writes no PID). Without a
    # usable flock binary (or with an incompatible one), the probe
    # cannot run and reaping is refused. The acquirer times out with a
    # diagnostic naming the cause.
    local _reap_probe_ok=0
    if [ -n "$_ACQUIRE_LOCK_FLOCK_BIN" ] && [ -n "$_ACQUIRE_LOCK_FLOCK_CAP" ]; then
      local _reap_probe_rc=0
      if eval "exec 222<\"${lock_file}\"" 2>/dev/null; then
        "$_ACQUIRE_LOCK_FLOCK_BIN" -n -x 222 2>/dev/null \
          && _reap_probe_rc=0 || _reap_probe_rc=1
        if [ "$_reap_probe_rc" -ne 0 ]; then
          # Active flock holder — do not reap. Release probe.
          eval "exec 222<&-" 2>/dev/null || true
          rm -f "$shadow" 2>/dev/null || true
          return 1
        fi
        # Probe acquired: no holder found. Verify fd 222 locked the
        # SAME inode the shadow pinned.
        _reap_probe_held=1
        _reap_probe_ok=1
        local _probe_ino=""
        _probe_ino="$(_al_inode "/proc/self/fd/222" 2>/dev/null)" || \
          _probe_ino="$(_al_inode "/dev/fd/222" 2>/dev/null)" || _probe_ino=""
        local _shadow_ino_early=""
        _shadow_ino_early="$(_al_inode "$shadow" 2>/dev/null)" || _shadow_ino_early=""
        if [ -z "$_probe_ino" ] || [ -z "$_shadow_ino_early" ] \
           || [ "$_probe_ino" != "$_shadow_ino_early" ]; then
          "$_ACQUIRE_LOCK_FLOCK_BIN" -u 222 2>/dev/null || true
          eval "exec 222<&-" 2>/dev/null || true
          _reap_probe_held=0
          rm -f "$shadow" 2>/dev/null || true
          return 0
        fi
      fi
    fi
    if [ "$_reap_probe_ok" = "1" ]; then
      _reap_candidate=1
    else
      # No reliable probe available — refuse to reap. Record why so
      # the timeout diagnostic can name this cause.
      _AL_REAP_NO_PROBE=1
      rm -f "$shadow" 2>/dev/null || true
      return 0
    fi
  elif kill -0 "$recorded_pid" 2>/dev/null; then
    # PID alive — never reap regardless of age.
    rm -f "$shadow" 2>/dev/null || true
    return 1
  else
    # PID dead — reap only if age exceeds threshold.
    # PID recycling note: a recycled PID is a false positive on kill -0.
    # The reap threshold (60s minimum) provides the second gate.
    age="$(_al_file_age "$shadow" 2>/dev/null)" || age=""
    if [ -n "$age" ] && [ "$age" -ge "$reap_threshold" ]; then
      _reap_candidate=1
    else
      rm -f "$shadow" 2>/dev/null || true
      return 1
    fi
  fi

  # --- Step 4: Mutex-guarded rename-and-verify delete ---
  #
  # A mkdir mutex serialises reapers so only one is between the inode
  # check and the removal at any time. Inside the mutex the lock file
  # is renamed to a private temp and re-verified; if the file changed
  # hands the temp is linked back. Pattern follows the in-tree prior
  # art in sprint-progress-snapshot.sh (_reap_lock).
  if [ "$_reap_candidate" = "1" ]; then
    local shadow_ino lock_ino
    shadow_ino="$(_al_inode "$shadow" 2>/dev/null)" || shadow_ino=""

    # Test-only hook: fires between the shadow pin and the final inode
    # comparison, before the guarded rm. Not a user-facing surface.
    if declare -F _al_reap_window_hook >/dev/null 2>&1; then
      _al_reap_window_hook "$lock_file" "$shadow"
    fi

    lock_ino="$(_al_inode "$lock_file" 2>/dev/null)" || lock_ino=""

    if [ -n "$lock_ino" ] && [ -n "$shadow_ino" ] && [ "$lock_ino" = "$shadow_ino" ]; then
      # Inode matches — acquire the reap mutex before removal.
      #
      # The mutex is a regular file created atomically via hard link
      # (ln tmp mutex: fails with EEXIST if it exists). The file
      # contains a unique owner token "<pid> <nonce>". Only the owner
      # removes it (after a token self-check); a dead owner's mutex
      # is NEVER reclaimed automatically. If a reaper dies while
      # holding the mutex, acquirers time out with a diagnostic
      # naming the leftover file and the manual remedy.
      local _reap_mutex="${lock_file}.reap-mtx"
      local _mtx_token="$$ $RANDOM$RANDOM"
      local _mtx_tmp="${lock_dir}/.reap-mtx-tmp.$$.$RANDOM"

      # Refuse a symlink at the mutex path.
      [ ! -L "$_reap_mutex" ] || rm -f "$_reap_mutex" 2>/dev/null || true

      printf '%s\n' "$_mtx_token" > "$_mtx_tmp" 2>/dev/null || {
        rm -f "$_mtx_tmp" 2>/dev/null || true
        if [ "$_reap_probe_held" = "1" ]; then
          "$_ACQUIRE_LOCK_FLOCK_BIN" -u 222 2>/dev/null || true
          eval "exec 222<&-" 2>/dev/null || true
        fi
        rm -f "$shadow" 2>/dev/null || true
        return 0
      }
      if ! ln "$_mtx_tmp" "$_reap_mutex" 2>/dev/null; then
        # Mutex already exists (live, stalled, or dead owner). Back off;
        # do not attempt to reclaim. The acquirer retries until timeout.
        rm -f "$_mtx_tmp" 2>/dev/null || true
        if [ "$_reap_probe_held" = "1" ]; then
          "$_ACQUIRE_LOCK_FLOCK_BIN" -u 222 2>/dev/null || true
          eval "exec 222<&-" 2>/dev/null || true
        fi
        rm -f "$shadow" 2>/dev/null || true
        return 0
      fi
      rm -f "$_mtx_tmp" 2>/dev/null || true

      # We hold the mutex. Re-verify the inode (may have changed).
      lock_ino="$(_al_inode "$lock_file" 2>/dev/null)" || lock_ino=""
      if [ -n "$lock_ino" ] && [ "$lock_ino" = "$shadow_ino" ]; then
        # Test-only hook: fires after the inode comparison passes and
        # inside the reap mutex, just before the rename-and-verify
        # removal step. Not a user-facing surface.
        if declare -F _al_reap_pre_rm_hook >/dev/null 2>&1; then
          _al_reap_pre_rm_hook "$lock_file"
        fi

        # Rename to a private temp, verify, then delete.
        local _reap_del="${lock_dir}/.lock-reap-del.$$.$RANDOM"
        if mv "$lock_file" "$_reap_del" 2>/dev/null; then
          local _del_ino=""
          _del_ino="$(_al_inode "$_reap_del" 2>/dev/null)" || _del_ino=""
          if [ -n "$_del_ino" ] && [ "$_del_ino" = "$shadow_ino" ]; then
            # Correct file — safe to delete.
            rm -f "$_reap_del" 2>/dev/null || true
            if [ -n "$recorded_pid" ] && [ "$recorded_pid" -gt 0 ] 2>/dev/null; then
              printf 'acquire-lock: reaped stale lock %s (pid=%s dead, age=%ss)\n' \
                "$lock_file" "$recorded_pid" "$age" >&2
            fi
          else
            # Wrong file — a new holder linked between our check and mv.
            # Restore via ln (fails harmlessly if the path is occupied).
            if ln "$_reap_del" "$lock_file" 2>/dev/null; then
              rm -f "$_reap_del" 2>/dev/null || true
            fi
            # If ln failed, the holder's file remains only at the private
            # .lock-reap-del.* path while another file occupies the lock
            # path. In production this branch is unreachable: the reaper
            # holds the mutex and verified the inode, so the lock path
            # cannot change between the check and the rename. Only the
            # test hook (_al_reap_pre_rm_hook) can inject a replacement
            # that reaches here.
          fi
        fi
      fi

      # Token-guarded cleanup: remove the mutex only if it still holds
      # our own token. This is a consistency check (no reclaim exists
      # that could replace it, but a future design change is safe).
      local _final_token=""
      read -r _final_token < "$_reap_mutex" 2>/dev/null || _final_token=""
      if [ "$_final_token" = "$_mtx_token" ]; then
        rm -f "$_reap_mutex" 2>/dev/null || true
      fi
    fi
    # On a host where stat does not work, skip removal (conservative:
    # a stale lock remains until the next process's reaper can stat).
  fi

  # Release the probe flock if held, then clean up the shadow.
  if [ "$_reap_probe_held" = "1" ]; then
    "$_ACQUIRE_LOCK_FLOCK_BIN" -u 222 2>/dev/null || true
    eval "exec 222<&-" 2>/dev/null || true
  fi
  rm -f "$shadow" 2>/dev/null || true
  return 0
}

# --- Public: acquire_lock <lock_file> <timeout_seconds> <fd_number> [--strict] ---

acquire_lock() {
  _al_save_opts
  local _al_rc=0
  _al_acquire_impl "$@" || _al_rc=$?
  _al_restore_opts
  return "$_al_rc"
}

_al_acquire_impl() {
  local lock_file="$1" timeout="$2" fd="$3"
  local _al_strict=0
  if [ "${4:-}" = "--strict" ]; then
    _al_strict=1
  fi

  # Per-acquirer identity: the real PID of THIS shell, not the parent.
  # Must not be inside $() — see _al_set_self_pid. Fails closed if the
  # identity cannot be determined (never falls back to $$).
  local _al_self=""
  if ! _al_set_self_pid _al_self; then
    return 1
  fi

  # Validate fd is a positive integer before it reaches any eval.
  case "$fd" in
    ''|*[!0-9]*)
      printf 'acquire-lock: fd must be a positive integer, got: %s\n' "$fd" >&2
      return 1 ;;
  esac

  # When parallel execution is active, flock is mandatory at every locking
  # entry point — not only in sprint-state.sh. The gate is inside acquire_lock
  # itself so no caller can bypass it.
  if [ "${GAIA_PARALLEL_EXECUTION:-}" = "1" ]; then
    _al_require_flock_impl || return $?
  fi

  # Harden mkdir: emit a diagnostic naming the directory and return
  # non-zero on failure, instead of silently continuing.
  local _al_lock_dir
  _al_lock_dir="$(dirname "$lock_file")"
  if ! mkdir -p "$_al_lock_dir" 2>/dev/null; then
    printf 'acquire-lock: cannot create lock directory: %s\n' "$_al_lock_dir" >&2
    return 1
  fi

  # Strict-mode pre-check: refuse any non-regular file at the lock path.
  if [ "$_al_strict" = "1" ]; then
    _al_enforce_path_type_strict "$lock_file" || return $?
  fi

  # Fast path: flock present (unless GAIA_LOCK_FORCE_FALLBACK overrides).
  # A single original deadline covers flock waits, reopen attempts and
  # bounded backoff. No spinning, no deadline reset.
  if [ -n "$_ACQUIRE_LOCK_FLOCK_BIN" ] && [ -n "$_ACQUIRE_LOCK_FLOCK_CAP" ] \
     && [ "${GAIA_LOCK_FORCE_FALLBACK:-}" != "1" ]; then
    local _al_flock_start
    _al_flock_start="$(date +%s)"

    while true; do
      local _al_fnow _al_remaining
      _al_fnow="$(date +%s)"
      _al_remaining=$(( timeout - (_al_fnow - _al_flock_start) ))
      if [ "$_al_remaining" -le 0 ]; then
        printf 'lock_timeout: %s after %ss\n' "$lock_file" "$timeout" >&2
        return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
      fi

      # Enforce path type before opening.
      if [ "$_al_strict" = "1" ]; then
        _al_enforce_path_type_strict "$lock_file" || return $?
      else
        _al_enforce_path_type "$lock_file" || return 1
      fi

      # Create the lock file with restrictive permissions.
      ( umask 077; set -C; : > "$lock_file" ) 2>/dev/null || true
      if ! eval "exec ${fd}>>\"${lock_file}\"" 2>/dev/null; then
        printf 'acquire-lock: permission denied opening lock file: %s\n' \
          "$lock_file" >&2
        return 1
      fi
      if ! _al_verify_opened_fd "$lock_file" "$fd"; then
        eval "exec ${fd}>&-" 2>/dev/null || true
        printf 'acquire-lock: lock path changed identity during open: %s\n' \
          "$lock_file" >&2
        return 1
      fi

      # Test-only hook: fires between opening the descriptor and calling
      # flock. Lets tests observe or manipulate the pre-flock state.
      if declare -F _al_pre_flock_hook >/dev/null 2>&1; then
        _al_pre_flock_hook "$lock_file" "$fd"
      fi

      # Acquire the kernel lock within the remaining deadline.
      if [ "$_ACQUIRE_LOCK_FLOCK_CAP" = "w" ]; then
        # Full flock: single blocking call with timeout.
        if ! "$_ACQUIRE_LOCK_FLOCK_BIN" -x -w "$_al_remaining" "$fd"; then
          eval "exec ${fd}>&-" 2>/dev/null || true
          printf 'lock_timeout: %s after %ss\n' "$lock_file" "$timeout" >&2
          return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
        fi
      else
        # Polling mode (flock supports -n but not -w, e.g. BusyBox).
        # Bounded backoff within the one original deadline.
        local _al_poll_ok=0 _al_poll_attempt=0
        while true; do
          if "$_ACQUIRE_LOCK_FLOCK_BIN" -n -x "$fd" 2>/dev/null; then
            _al_poll_ok=1
            break
          fi
          _al_fnow="$(date +%s)"
          if [ $(( _al_fnow - _al_flock_start )) -ge "$timeout" ]; then
            break
          fi
          _al_poll_attempt=$(( _al_poll_attempt + 1 ))
          local _al_poll_base=10
          if [ "$_al_poll_attempt" -le 1 ]; then _al_poll_base=10
          elif [ "$_al_poll_attempt" -le 2 ]; then _al_poll_base=20
          else _al_poll_base=50; fi
          local _al_poll_jitter=$(( RANDOM % 20 ))
          local _al_poll_ms=$(( _al_poll_base + _al_poll_jitter ))
          sleep "$(printf '%d.%03d' $((_al_poll_ms / 1000)) $((_al_poll_ms % 1000)))" 2>/dev/null \
            || sleep 1
        done
        if [ "$_al_poll_ok" -ne 1 ]; then
          eval "exec ${fd}>&-" 2>/dev/null || true
          printf 'lock_timeout: %s after %ss\n' "$lock_file" "$timeout" >&2
          return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
        fi
      fi

      # Post-lock identity re-check: the descriptor must still refer to
      # the same inode as the path. If the reaper deleted the path and a
      # new file appeared, the inodes differ and we must retry.
      local _al_vid_rc=0
      _al_verify_fd_identity "$lock_file" "$fd" || _al_vid_rc=$?
      if [ "$_al_vid_rc" -eq 2 ]; then
        # UNAVAILABLE: refuse if ordinary-file stat works (the reaper can
        # reap on such hosts, so an unverified flock is unsafe). Allow if
        # stat is absent (the reaper can't reap without stat, so the risk
        # does not exist).
        if [ -n "$_ACQUIRE_LOCK_STAT_FMT" ]; then
          "$_ACQUIRE_LOCK_FLOCK_BIN" -u "$fd" 2>/dev/null || true
          eval "exec ${fd}>&-" 2>/dev/null || true
          printf 'acquire-lock: cannot verify lock identity (fd inode lookup unavailable): %s\n' \
            "$lock_file" >&2
          return 1
        fi
        # No stat at all — degrade to verified (reaper can't reap anyway).
        _al_vid_rc=0
      fi

      if [ "$_al_vid_rc" -eq 0 ]; then
        # VERIFIED. Check for a live fallback holder (mixed-mode guard).
        # If a live fallback holder is present, release the flock and
        # retry within the deadline (the holder may release soon).
        local _al_fb_pid=""
        read -r _al_fb_pid _ < "$lock_file" 2>/dev/null || true
        if [ -n "$_al_fb_pid" ] && [ "$_al_fb_pid" -gt 0 ] 2>/dev/null \
           && [ "$_al_fb_pid" != "$_al_self" ] \
           && kill -0 "$_al_fb_pid" 2>/dev/null; then
          "$_ACQUIRE_LOCK_FLOCK_BIN" -u "$fd" 2>/dev/null || true
          eval "exec ${fd}>&-" 2>/dev/null || true
          # Retry within the deadline instead of failing immediately.
          _al_fnow="$(date +%s)"
          if [ $(( _al_fnow - _al_flock_start )) -ge "$timeout" ]; then
            printf 'lock_timeout: %s after %ss\n' "$lock_file" "$timeout" >&2
            return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
          fi
          sleep 0.1 2>/dev/null || sleep 1
          continue
        fi
        _al_set_registry "$fd" "flock" "$lock_file" "$_al_self"
        _al_trace "acquire" "$lock_file"
        return 0
      fi

      # MISMATCH: unlock, close, reopen and retry within the deadline.
      "$_ACQUIRE_LOCK_FLOCK_BIN" -u "$fd" 2>/dev/null || true
      eval "exec ${fd}>&-" 2>/dev/null || true
      _al_fnow="$(date +%s)"
      if [ $(( _al_fnow - _al_flock_start )) -ge "$timeout" ]; then
        printf 'lock_identity_unstable: identity re-check mismatch: %s\n' \
          "$lock_file" >&2
        return "$ACQUIRE_LOCK_EXIT_IDENTITY"
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
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
  # Set by the reaper when it declines to clear an ownerless file
  # because no reliable flock probe is available.
  _AL_REAP_NO_PROBE=0

  while true; do
    local now_epoch
    now_epoch="$(date +%s)"
    local elapsed=$(( now_epoch - start_epoch ))
    if [ "$elapsed" -ge "$timeout" ]; then
      printf 'lock_timeout: %s after %ss\n' "$lock_file" "$timeout" >&2
      # If a reap-mutex file exists, it may be blocking reaping.
      local _mtx_diag="${lock_file}.reap-mtx"
      if [ -e "$_mtx_diag" ] || [ -L "$_mtx_diag" ]; then
        printf 'acquire-lock: a reaper mutex is blocking lock cleanup: %s\n' "$_mtx_diag" >&2
        printf 'acquire-lock: to recover, stop or quiesce every process that uses this lock path, then remove the file.\n' >&2
      fi
      # If the reaper declined to clear an ownerless file because no
      # reliable flock probe was available, say so.
      if [ "$_AL_REAP_NO_PROBE" = "1" ]; then
        printf 'acquire-lock: cannot safely clear %s: it may be held by a process using flock, and this process has no usable flock to check.\n' "$lock_file" >&2
        printf 'acquire-lock: to recover, either make util-linux flock available on this process'\''s PATH, or quiesce every user of this lock path and configure all of them to use the same locking mode before retrying.\n' >&2
      fi
      return "$ACQUIRE_LOCK_EXIT_TIMEOUT"
    fi

    # In strict mode, re-check path type on every iteration.
    if [ "$_al_strict" = "1" ]; then
      _al_enforce_path_type_strict "$lock_file" || return $?
    fi

    # Try to reap stale lock.
    _al_try_reap "$lock_file" "$timeout" || true

    # Refuse to link against anything that is not a plain regular file.
    # `ln SOURCE DIR` is the link-INTO-directory form and always succeeds,
    # so without this every concurrent acquirer would "win" at once and
    # mutual exclusion would silently disappear. The reaper above already
    # routes through the same gate; re-assert it here because it is the
    # invariant the ln(2) below depends on for its atomicity.
    if [ "$_al_strict" = "0" ]; then
      if ! _al_enforce_path_type "$lock_file"; then
        return 1
      fi
    fi

    # Test-only hook: fires between the type gate and the link step so
    # tests can swap a directory into the lock path and prove the post-link
    # publication check catches it. Not a user-facing surface.
    if declare -F _al_pre_link_hook >/dev/null 2>&1; then
      _al_pre_link_hook "$lock_file"
    fi

    # Atomic create-with-content: write to a temp file exclusively, then
    # hard-link. ln fails atomically if the target already exists (EEXIST).
    #
    # The temp is created via mktemp (O_EXCL) so no two acquirers share
    # a name, even on bash 3.2 where subshells share $$ and can draw the
    # same $RANDOM in the same second. The owner token uses the real
    # per-acquirer PID (_al_self), not $$.
    local tmp_lock=""
    local _al_prev_umask
    _al_prev_umask="$(umask)"
    umask 077
    tmp_lock="$(mktemp "${lock_dir}/.lock-tmp.XXXXXXXXXX" 2>/dev/null)" || tmp_lock=""
    if [ -z "$tmp_lock" ]; then
      umask "$_al_prev_umask"
      printf 'acquire-lock: cannot create a lock file under %s\n' "$lock_dir" >&2
      return 1
    fi
    _al_trace "tmp" "$tmp_lock"
    # The full token includes PID, epoch, and a nonce (the mktemp basename)
    # so each acquisition is uniquely identifiable. The PID stays first and
    # epoch second, so `read -r pid _` readers and the age contract are
    # unchanged. The nonce makes read-then-rm safe in the refusal cleanup:
    # while its owner is alive a lock file is removed only by its owner
    # (release compares the full token, the reaper skips live owners, other
    # acquirers' cleanup removes only their own token, and the path-type
    # check removes only symlinks and directories).
    local _al_nonce=""
    _al_nonce="$(basename "$tmp_lock")"
    local _al_full_token="$_al_self $now_epoch $_al_nonce"
    if ! { printf '%s\n' "$_al_full_token" > "$tmp_lock"; } 2>/dev/null; then
      umask "$_al_prev_umask"
      rm -f "$tmp_lock" 2>/dev/null || true
      _al_trace "create-failed" "$tmp_lock"
      printf 'acquire-lock: cannot create a lock file under %s\n' "$lock_dir" >&2
      return 1
    fi
    umask "$_al_prev_umask"
    if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
      # Test-only hook: fires after a successful ln but before the inode
      # check, so tests can delete the temp to simulate a colliding
      # writer and trigger the publication-refusal path.
      if declare -F _al_post_link_hook >/dev/null 2>&1; then
        _al_post_link_hook "$lock_file" "$tmp_lock"
      fi
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
        # Strict-mode post-lock identity re-check (fallback path).
        # The fallback path uses the temp file's dev:ino as the reference.
        if [ "$_al_strict" = "1" ]; then
          local _al_path_id _al_tmp_id
          _al_path_id="$(_al_dev_ino "$lock_file" 2>/dev/null)" || _al_path_id=""
          _al_tmp_id="$(_al_dev_ino "$tmp_lock" 2>/dev/null)" || _al_tmp_id=""
          if [ -n "$_al_path_id" ] && [ -n "$_al_tmp_id" ] && \
             [ "$_al_path_id" != "$_al_tmp_id" ]; then
            # Identity mismatch in fallback — cannot retry easily, fail.
            rm -f "$tmp_lock" 2>/dev/null || true
            rm -f "$lock_file" 2>/dev/null || true
            continue
          fi
        fi
        rm -f "$tmp_lock" 2>/dev/null || true
        _al_set_registry "$fd" "fallback" "$lock_file" "$_al_full_token"
        _al_trace "acquire" "$lock_file"
        return 0
      fi
      # The link went somewhere else (or the path is not a regular file).
      # Clean up: remove the directory-landed link (if any) and the temp.
      rm -f "$lock_file/$(basename "$tmp_lock")" 2>/dev/null || true
      rm -f "$tmp_lock" 2>/dev/null || true

      # If a regular file at the lock path holds THIS acquirer's full
      # token, remove it. Read the first line and compare against the
      # exact token this acquisition wrote; rm only on a match. The path
      # is never moved or renamed: a replacement holder's lock stays
      # continuously present. Read-then-rm is safe because while its
      # owner is alive, a lock file is removed only by its owner (release
      # compares the full token, the reaper skips live owners, other
      # acquirers' cleanup removes only their own token, and the path-
      # type check removes only symlinks and directories).
      # Test-only hook: fires before the cleanup read, letting tests
      # inject a replacement file to prove it is not touched.
      if declare -F _al_publish_cleanup_hook >/dev/null 2>&1; then
        _al_publish_cleanup_hook "$lock_file"
      fi
      if [ -f "$lock_file" ] && [ ! -L "$lock_file" ]; then
        local _pub_line=""
        read -r _pub_line < "$lock_file" 2>/dev/null || _pub_line=""
        if [ "$_pub_line" = "$_al_full_token" ]; then
          rm -f "$lock_file" 2>/dev/null || true
        fi
      fi

      printf 'acquire-lock: refusing a lock that did not publish at %s\n' \
        "$lock_file" >&2
      return "$ACQUIRE_LOCK_EXIT_PUBLISH"
    fi
    rm -f "$tmp_lock" 2>/dev/null || true

    attempt=$(( attempt + 1 ))
    # Exponential backoff: 10, 20, 50 (cap) ms + jitter 0-19ms.
    # A waiter that sleeps too long overshoots a lock freed early in that
    # window: with N concurrent writers and a short hold, the queue drains
    # slower than the work takes and waiters burn their whole timeout without
    # ever seeing the free window. Capping the re-probe interval near 50ms
    # keeps pickup prompt while still backing off enough to avoid a busy
    # spin. Jitter stays proportional to the cap so concurrent waiters
    # still desynchronise.
    if [ "$attempt" -le 1 ]; then
      base_ms=10
    elif [ "$attempt" -le 2 ]; then
      base_ms=20
    else
      base_ms=50
    fi
    local jitter=$(( RANDOM % 20 ))
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
  _al_save_opts
  local _al_rc=0
  _al_release_impl "$@" || _al_rc=$?
  _al_restore_opts
  return "$_al_rc"
}

_al_release_impl() {
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
    # Ownership-checked removal: compare the full first line of the lock
    # file against the token stored at acquisition time. For locks created
    # by an older helper (two-field records, no nonce), fall back to PID-
    # only comparison. This prevents subshells of the same parent from
    # removing each other's locks.
    local file_line="" owner=""
    read -r file_line < "$lf" 2>/dev/null || file_line=""
    owner="$(_al_get_owner "$fd")"
    if [ -z "$owner" ]; then
      # No registry entry (old helper or unregistered fd). Fall back to
      # PID-only: extract the first field from the file and compare to $$.
      local holder=""
      holder="${file_line%% *}"
      if [ "$holder" = "$$" ]; then
        rm -f "$lf" 2>/dev/null || true
      else
        printf 'acquire-lock: release_lock fd=%s — not owner (file pid=%s, self=%s)\n' \
          "$fd" "$holder" "$$" >&2
      fi
    elif [ "$file_line" = "$owner" ]; then
      rm -f "$lf" 2>/dev/null || true
    else
      local holder=""
      holder="${file_line%% *}"
      printf 'acquire-lock: release_lock fd=%s — not owner (file pid=%s, self=%s)\n' \
        "$fd" "$holder" "${owner%% *}" >&2
    fi
  fi

  _al_clear_registry "$fd"
}

# --- Public: require_flock_for_parallel ---

require_flock_for_parallel() {
  _al_save_opts
  local _al_rc=0
  _al_require_flock_impl || _al_rc=$?
  _al_restore_opts
  return "$_al_rc"
}

_al_require_flock_impl() {
  # Re-probe at call time (not the source-time cache).
  if ! command -v flock >/dev/null 2>&1; then
    printf 'FATAL: parallel execution requires flock (util-linux). ' >&2
    printf 'Install via "brew install util-linux" (macOS) or ' >&2
    printf '"apt-get install util-linux" (Debian/Ubuntu), ' >&2
    printf 'or run sequentially.\n' >&2
    return 1
  fi
  # Presence is not enough: the binary must support -w or -n for real
  # kernel locking. BusyBox flock supports -n but not -w; a flock that
  # supports neither is incompatible.
  if [ -z "$_ACQUIRE_LOCK_FLOCK_CAP" ]; then
    printf 'FATAL: parallel execution requires flock with -w or -n support. ' >&2
    printf 'The installed flock is incompatible. ' >&2
    printf 'Install util-linux flock, or run sequentially.\n' >&2
    return 1
  fi
  # The forced-fallback override makes every acquisition take the ln(2)
  # path, so passing the gate on "flock is installed" while the override
  # is set would report a guarantee the run does not have.
  if [ "${GAIA_LOCK_FORCE_FALLBACK:-}" = "1" ]; then
    printf 'FATAL: parallel execution requires flock, but GAIA_LOCK_FORCE_FALLBACK=1 ' >&2
    printf 'forces the hard-link fallback path. Unset it, or run sequentially.\n' >&2
    return 1
  fi
}

# --- Public: acquire_lock_close_predicate <max_concurrent_active> <state_dir> ---
#
# Determines which lock a close write should acquire. The library stays
# config-agnostic: callers resolve the concurrent-sprint limit themselves
# and pass it as the first argument. The second argument is the state
# directory to probe for per-sprint state files.
#
# Returns two words on stdout: <lock_path> <timeout>.
#   - L4 (lifecycle lock) when max_concurrent_active > 1, OR when per-sprint
#     state files exist in the state directory (the transitional state).
#   - L1 (per-sprint state lock) only in single-sprint mode: limit absent
#     or 1 AND no per-sprint files.
#
# The caller is responsible for resolving the sprint_id for L1.

acquire_lock_close_predicate() {
  local limit="${1:-}" state_dir="${2:-}"

  # Strip trailing slash to prevent double-slash in constructed paths.
  state_dir="${state_dir%/}"

  # Concurrent mode: limit > 1 always takes L4.
  if [ -n "$limit" ] && [ "$limit" -gt 1 ] 2>/dev/null; then
    printf '%s %s\n' "${state_dir:+${state_dir}/}${GAIA_LOCK_L4_PATH}" "$GAIA_LOCK_L4_TIMEOUT"
    return 0
  fi

  # Transitional state: per-sprint files exist even though limit is 1 or absent.
  # This covers reverse migration where per-sprint files still exist.
  local _al_per_sprint_files=""
  if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
    _al_per_sprint_files="$(find "$state_dir" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || _al_per_sprint_files=""
  fi
  if [ -n "$_al_per_sprint_files" ]; then
    printf '%s %s\n' "${state_dir:+${state_dir}/}${GAIA_LOCK_L4_PATH}" "$GAIA_LOCK_L4_TIMEOUT"
    return 0
  fi

  # Single-sprint mode: use L1. The caller must substitute {sprint_id}.
  printf '%s %s\n' "${state_dir:+${state_dir}/}${GAIA_LOCK_L1_TEMPLATE}" "$GAIA_LOCK_L1_TIMEOUT"
  return 0
}

# --- Public: acquire_lock_is_concurrent_mode <max_concurrent_active> <state_dir> ---
#
# Returns 0 when the project is in concurrent mode, 1 for single-sprint.
# The library stays config-agnostic: callers resolve the concurrent-sprint
# limit themselves and pass it as the first argument. The second argument is
# the state directory to probe for per-sprint state files.
#
# Concurrent: max_concurrent_active > 1, OR per-sprint files exist in the
# state directory (the transitional state where per-sprint files remain from
# a reverse migration). Single-sprint: limit absent or 1 AND no per-sprint
# files.

acquire_lock_is_concurrent_mode() {
  local limit="${1:-}" state_dir="${2:-}"

  # Concurrent mode: limit > 1.
  if [ -n "$limit" ] && [ "$limit" -gt 1 ] 2>/dev/null; then
    return 0
  fi

  # Transitional state: per-sprint files exist even though limit is 1 or absent.
  local _al_cm_psf=""
  if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
    _al_cm_psf="$(find "$state_dir" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || _al_cm_psf=""
  fi
  if [ -n "$_al_cm_psf" ]; then
    return 0
  fi

  return 1
}

# --- CLI entry point (only when executed directly, not sourced) ---

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--check-parallel" ]; then
  require_flock_for_parallel
  exit $?
fi
