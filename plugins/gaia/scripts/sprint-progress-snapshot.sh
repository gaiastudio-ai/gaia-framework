#!/usr/bin/env bash
# sprint-progress-snapshot.sh — sole writer of the sprint progress cache.
#
# Reads sprint-status.yaml, story files, the review-gate ledger, and the
# action-items registry, then writes a single JSON cache at
# .gaia/state/.sprint-progress-cache.json.  Four rendering surfaces
# (sidebar, band, status line, dashboard) consume the cache instead of
# parsing story files directly.
#
# Data flow: awk extracts raw fields into unit-separator (0x1f) delimited
# records, and ONE jq program assembles the whole document from them.  No
# JSON is ever built by string concatenation, so no field value can change
# the document structure, and every string is encoded by jq.
#
# Incremental refresh: the mtime sidecar (.sprint-progress-mtimes) records
# each tracked file with its project-relative path and mtime (0 = absent),
# plus the story tree root and its direct subdirectories (a story directory
# that appears, moves or disappears changes one of their mtimes), and, for a
# story file that is a symlink, the link itself (a link pointed at another
# file is noticed).  The
# per-story parse records are kept in .sprint-progress-parsed, so a run only
# re-parses story files whose path or mtime changed.
#
# Containment: every file the script reads or writes stays inside the
# project root.  Story and meta files are resolved through their full
# symlink chain; a path holding a control byte is refused; the state
# directory must not be a symlink; a symlink or directory at a state file
# name is never replaced.
#
# Environment variable overrides (for testability):
#   PROJECT_ROOT              Project root (default: CLAUDE_PROJECT_ROOT or PWD)
#   SPRINT_STATUS_YAML        Path to sprint-status.yaml (default: .gaia/state/sprint-status.yaml)
#   IMPLEMENTATION_ARTIFACTS  Story tree (default: .gaia/artifacts/implementation-artifacts,
#                             falling back to the legacy docs/implementation-artifacts)
#   REVIEW_GATE_LEDGER        Review-gate ledger path (same resolution as review-gate.sh)
#   GAIA_LOCK_FORCE_FALLBACK  Force the ln-based lock backend (skip flock)
#
# The post-transition hook in sprint-state.sh honours:
#   GAIA_SNAPSHOT_HOOK_DISABLE=1   Suppress the hook entirely (test suites)
#   GAIA_SNAPSHOT_HOOK_ACTIVE=1    Prevent re-entrant invocation
#
# Exit codes:
#   0 — success (cache written) OR lock held by another (skip)
#   1 — fatal error only

set -euo pipefail
LC_ALL=C; export LC_ALL

# EPOCHSECONDS and EPOCHREALTIME are clock variables only from bash 5 on.  On
# an older shell (macOS ships bash 3.2) a value inherited from the environment
# is plain text that never moves, so it is dropped and the script falls back
# to `date` and SECONDS.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then unset EPOCHSECONDS EPOCHREALTIME; fi

# ---------------------------------------------------------------------------
# Resolve own directory and load libraries
# ---------------------------------------------------------------------------

# No subshell: only the cold path uses it (to reach lib/resolve-artifact-path.sh).
case "${BASH_SOURCE[0]}" in
  */*) _SELF_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   _SELF_DIR="." ;;
esac

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_CACHE_NAME=".sprint-progress-cache.json"
_SIDECAR_NAME=".sprint-progress-mtimes"
_PARSED_NAME=".sprint-progress-parsed"
_LOCK_SUFFIX=".lock"
_ALLOWED_COMMANDS=("/gaia-test-manual" "/gaia-sprint-close" "/gaia-action-items")
_US=$'\037'   # record field separator (ASCII unit separator)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_warn() { printf 'sprint-progress-snapshot: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Cross-platform detection — run ONCE at source time
# ---------------------------------------------------------------------------

# Detect stat flavour: GNU uses -c, BSD uses -f.
# On GNU, `stat -f %m /` prints filesystem info to stdout (wrong), so we
# must never fall through from a BSD attempt to a GNU attempt in a single
# invocation — that pollutes the captured output.
if stat -c %Y / >/dev/null 2>&1; then
  _SNAP_STAT_FMT="gnu"   # stat -c %Y
else
  _SNAP_STAT_FMT="bsd"   # stat -f %m
fi

# ---------------------------------------------------------------------------
# Cross-platform helpers (use detected flavour, never || chain)
# ---------------------------------------------------------------------------

_stat_mtime() {
  if [ "$_SNAP_STAT_FMT" = "gnu" ]; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

# _stat_mtime_batch FILE [FILE...] — print one mtime per line
_stat_mtime_batch() {
  if [ "$_SNAP_STAT_FMT" = "gnu" ]; then
    stat -c %Y "$@"
  else
    stat -f %m "$@"
  fi
}

# _stat_mtime_age PATH — seconds since PATH was modified.  Returns 1 (and
# prints nothing) when PATH cannot be read, for example because it is gone.
_stat_mtime_age() {
  local mt now
  mt="$(_stat_mtime "$1" 2>/dev/null)" || return 1
  [[ $mt =~ ^[0-9]+$ ]] || return 1
  now="${EPOCHSECONDS:-$(date +%s)}"
  printf '%s' "$(( now - mt ))"
}

# _realpath_one PATH — resolve the FULL symlink chain of PATH (every hop of
# the final component, plus all parent directories via `cd -P`).  Prints the
# physical path; returns 1 on a missing target or a loop longer than 40 hops.
_realpath_one() {
  local p="$1" hops=0 t d
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    t="$(readlink "$p")" || return 1
    case "$t" in
      /*) p="$t" ;;
      *)  case "$p" in */*) p="${p%/*}/$t" ;; *) p="$t" ;; esac ;;
    esac
  done
  [ -e "$p" ] || return 1
  case "$p" in
    */*) d="$(cd -P "${p%/*}" 2>/dev/null && pwd -P)" || return 1 ;;
    *)   d="$(pwd -P)" ;;
  esac
  # A resolved path with a newline would break the one-line-per-path output.
  case "$d/${p##*/}" in *$'\n'*) return 1 ;; esac
  printf '%s/%s\n' "${d%/}" "${p##*/}"
}

# _realpath_batch PATH... — one resolved path per argument, in order, with the
# placeholder "?" for a path that cannot be resolved (never a blank line,
# which command substitution would silently drop at the end).  Uses a single `realpath` process
# when it is available and resolves every argument; otherwise resolves each
# path with _realpath_one.
_realpath_batch() {
  [ "$#" -gt 0 ] || return 0
  local out="" n=0 line
  if command -v realpath >/dev/null 2>&1; then
    # GNU realpath resolves a dangling link without failing unless given -e;
    # BSD realpath already fails on a missing target and has no -e.
    if [ -z "${_SNAP_REALPATH_E:-}" ]; then
      if realpath -e / >/dev/null 2>&1; then _SNAP_REALPATH_E="-e"; else _SNAP_REALPATH_E="none"; fi
    fi
    if [ "$_SNAP_REALPATH_E" = "-e" ]; then
      out="$(realpath -e "$@" 2>/dev/null)" || out=""
    else
      out="$(realpath "$@" 2>/dev/null)" || out=""
    fi
    if [ -n "$out" ]; then
      while IFS= read -r line; do n=$((n + 1)); done <<< "$out"
      if [ "$n" -eq "$#" ]; then printf '%s\n' "$out"; return 0; fi
    fi
  fi
  local p
  for p in "$@"; do
    _realpath_one "$p" || printf '?\n'
  done
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

# _validate_threshold STR — return an integer from 0 to 3600 (the range the
# config schema allows), or 120 with a warning
_validate_threshold() {
  local v="$1"
  # Must be a plain non-negative integer (digits only, bounded length) no
  # larger than one hour
  if [ -n "$v" ] && [ "${#v}" -le 10 ] && [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -le 3600 ]; then
    printf '%s' "$((10#$v))"
  else
    [ -z "$v" ] || _warn "invalid threshold value '${v:0:20}', using default 120"
    printf '120'
  fi
}

# The command allowlist has ONE implementation: the jq `allow` function in
# _JQ_DEFS, handed _ALLOWED_COMMANDS as positional arguments.  The cold
# assembly and the warm re-validation both run every command through it.

_valid_story_key() {
  [[ $1 =~ ^E[0-9]+\-S[0-9]+$ ]]
}

# _rel_ok REL — a sidecar path must be project-relative with no `..` segment
# and no control byte.
_rel_ok() {
  case "$1" in
    ""|/*|..|../*|*/../*|*/..) return 1 ;;
  esac
  ! _has_ctl "$1"
}

# _has_ctl STR — true when STR holds a byte that could shift a record field
# or a line: the unit separator, CR, LF or TAB.
_has_ctl() {
  case "$1" in *[$'\037\r\n\t']*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# Single-flight non-blocking lock (fixed fd 9)
# ---------------------------------------------------------------------------

_SNAPSHOT_LOCK_FILE=""
_SNAPSHOT_LOCK_BACKEND=""
_SNAPSHOT_LOCK_REFUSED=0
_SNAPSHOT_LOCK_REASON=""
_SNAP_TMP_FILES=""

_snapshot_lock_path_policy() {
  local lock_file="$1"
  if [ -d "$lock_file" ]; then
    _warn "lock path is a directory, refusing: $lock_file"; return 1
  fi
  if [ -L "$lock_file" ]; then
    _warn "lock path is a symlink, refusing: $lock_file"; return 1
  fi
  return 0
}

# Both backends share one convention: whoever holds the lock has its
# "PID EPOCH" line as the LAST line of the lock file.  The flock backend
# appends its line once it holds the flock; a fallback holder links a fresh
# file holding only its line; both remove the file on release.  So each
# backend sees the other's live holder.  A lock file whose holder is dead, or
# that is empty, is stale only once it is 60 s old; it is then removed by one
# reaper at a time, by renaming it to a name only that reaper uses and checking
# it is still the file that was judged (never check-then-remove).
_SNAPSHOT_LOCK_LINE=""
_LOCK_LAST=""
_LOCK_IDENT=""

# _lock_last FILE — set _LOCK_LAST to the last non-empty line of FILE ("" for
# an empty file).  Returns 1 when FILE cannot be read (for example, it is
# gone).  No subshell.
_lock_last() {
  _LOCK_LAST=""
  [ -f "$1" ] && [ -r "$1" ] || return 1
  local l
  { while IFS= read -r l || [ -n "$l" ]; do [ -z "$l" ] || _LOCK_LAST="$l"; done < "$1"; } 2>/dev/null || return 1
  return 0
}

# _lock_line — the "PID EPOCH" line this run writes as a holder.
_lock_line() { _SNAPSHOT_LOCK_LINE="$$ ${EPOCHSECONDS:-$(date +%s)}"; }

# _holder_live LINE — true when LINE ("PID EPOCH") names a running process
# that took the lock at most _LOCK_MAX_HOLD seconds ago.  A build never holds
# the lock that long (the hook stops a build after 10 s), so a holder line
# whose PID the system later handed to some other long-lived process stops
# counting as a live holder once its epoch is that old (or lies in the future).
_LOCK_MAX_HOLD=600
_holder_live() {
  local pid="${1%% *}" ep="${1#* }" now
  case "$1" in *" "*) ;; *) return 1 ;; esac
  [[ $pid =~ ^[0-9]+$ ]] && [[ $ep =~ ^[0-9]+$ ]] || return 1
  [ "${#pid}" -le 10 ] && [ "${#ep}" -le 12 ] && [ "$((10#$pid))" -gt 0 ] || return 1
  now="${EPOCHSECONDS:-$(date +%s)}"
  [ $(( now - 10#$ep )) -le "$_LOCK_MAX_HOLD" ] && [ $(( 10#$ep - now )) -le 60 ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# _await_reap MUTEX — wait until no fallback run is reaping a stale lock.  A
# mutex left by a reaper that died is cleared once it is 60 s old.  Every pass
# counts and sleeps, including one that could not clear an aged mutex (for
# example a non-empty directory).  The wait gives up after 2 s of wall-clock
# time.  A shell without EPOCHREALTIME only has whole seconds (SECONDS), so
# it gives up once SECONDS has moved on by 2 (1 to 2 s), or after 100 passes
# of 20 ms plus one age check each, whichever comes first.  A run tries the
# lock at most twice, so a mutex that never clears costs it about 4 s before
# it skips.  Returns 1 when a reap is still in progress.
_await_reap() {
  local mutex="$1" n=0 mage now deadline="" t0="$SECONDS"
  if [ -n "${EPOCHREALTIME:-}" ]; then
    now="${EPOCHREALTIME//[!0-9]/}"; deadline=$(( 10#$now + 2000000 ))
  fi
  while [ -e "$mutex" ] || [ -L "$mutex" ]; do
    if mage="$(_stat_mtime_age "$mutex")" && [ "$mage" -ge 60 ] \
       && [ -d "$mutex" ] && [ ! -L "$mutex" ]; then
      rmdir "$mutex" 2>/dev/null || true
      [ -e "$mutex" ] || [ -L "$mutex" ] || continue
    fi
    n=$((n + 1))
    if [ -n "$deadline" ]; then
      now="${EPOCHREALTIME//[!0-9]/}"; [ $(( 10#$now )) -lt "$deadline" ] || return 1
    else
      [ "$n" -le 100 ] && [ $(( SECONDS - t0 )) -lt 2 ] || return 1
    fi
    sleep 0.02
  done
  return 0
}

_try_snapshot_lock() {
  local lock_file="$1"
  _SNAPSHOT_LOCK_REFUSED=0
  if ! _snapshot_lock_path_policy "$lock_file"; then
    _SNAPSHOT_LOCK_REFUSED=1; return 1
  fi

  if command -v flock >/dev/null 2>&1 && [ "${GAIA_LOCK_FORCE_FALLBACK:-}" != "1" ]; then
    _SNAPSHOT_LOCK_BACKEND="flock"
    exec 9>>"$lock_file" || return 1
    if ! flock -n 9 2>/dev/null; then
      exec 9>&-
      _SNAPSHOT_LOCK_REASON="held by another process"
      return 1
    fi
    # A fallback-backend holder takes no flock; its line says it holds.
    if _lock_last "$lock_file" && [ "${_LOCK_LAST%% *}" != "$$" ] && _holder_live "$_LOCK_LAST"; then
      exec 9>&-
      _SNAPSHOT_LOCK_REASON="held by live process ${_LOCK_LAST%% *}"
      return 1
    fi
    # Announce this holder, then make sure the name still leads to the file
    # this run locked: a fallback run may have replaced an empty lock file
    # just before the line was written.
    _lock_line
    if ! printf '%s\n' "$_SNAPSHOT_LOCK_LINE" >&9 2>/dev/null \
       || ! _lock_last "$lock_file" || [ "$_LOCK_LAST" != "$_SNAPSHOT_LOCK_LINE" ]; then
      exec 9>&-
      _SNAPSHOT_LOCK_REASON="taken by another process"
      return 1
    fi
    # A fallback run reaping a stale lock may have judged this file before
    # the line above was written, and may be moving it aside right now.  Let
    # that reap finish, then check again that the name still leads to this
    # run's line (a reaper that saw the line leaves the file alone, or puts
    # it back; if another run took the name meanwhile, this run backs off).
    # A reap that starts after this check sees the line and leaves the file.
    if [ -e "${lock_file}.reaping" ] || [ -L "${lock_file}.reaping" ]; then
      if ! _await_reap "${lock_file}.reaping" \
         || ! _lock_last "$lock_file" || [ "$_LOCK_LAST" != "$_SNAPSHOT_LOCK_LINE" ]; then
        exec 9>&-
        _SNAPSHOT_LOCK_REASON="taken by another process"
        return 1
      fi
    fi
    _SNAPSHOT_LOCK_FILE="$lock_file"
    return 0
  fi

  # Fallback: atomic ln, stale-holder reap.  A lock file that is empty (a
  # flock-backend run between creating it and writing its line, or one left
  # by an older version), or whose holder PID is dead or not a PID, is reaped
  # once it is older than 60 s.  A lock file that disappears after a failed
  # ln is simply retried.
  _SNAPSHOT_LOCK_BACKEND="fallback"
  _SNAPSHOT_LOCK_REASON=""
  local attempt holder age ident rc
  for attempt in 1 2 3; do
    _fallback_link "$lock_file" && return 0
    [ "$attempt" -lt 3 ] || break
    [ ! -L "$lock_file" ] || break
    [ -e "$lock_file" ] || continue
    [ -f "$lock_file" ] || break
    # Identity of the lock file being judged (inode, size, holder line), so
    # the removal below only ever removes this exact file.
    _lock_ident "$lock_file" || continue
    ident="$_LOCK_IDENT"
    holder="${_LOCK_LAST%% *}"
    if [ -n "$_LOCK_LAST" ] && _holder_live "$_LOCK_LAST"; then
      _SNAPSHOT_LOCK_REASON="held by live process $holder"; return 1
    fi
    # The lock file can vanish (its holder released it) right after it was
    # judged: link again.
    age="$(_stat_mtime_age "$lock_file")" || continue
    if [ "$age" -lt 60 ]; then
      if [ -z "$_LOCK_LAST" ]; then
        _SNAPSHOT_LOCK_REASON="the lock file is empty but only ${age}s old"
      else
        _SNAPSHOT_LOCK_REASON="holder '${holder:0:20}' is not running but the lock is only ${age}s old"
      fi
      [[ ! $holder =~ ^[0-9]+$ ]] || ! kill -0 "$holder" 2>/dev/null \
        || _SNAPSHOT_LOCK_REASON="holder '${holder:0:20}' took the lock too long ago but the lock file is only ${age}s old"
      return 1
    fi
    if [ -z "$_LOCK_LAST" ]; then
      _warn "replacing an empty lock file nobody holds: $lock_file"
    fi
    rc=0; _reap_lock "$lock_file" "$ident" || rc=$?
    case "$rc" in
      0|2) ;;   # removed, or already gone: try ln again
      *) _SNAPSHOT_LOCK_REASON="taken by another process"; return 1 ;;
    esac
  done
  [ -n "$_SNAPSHOT_LOCK_REASON" ] || _SNAPSHOT_LOCK_REASON="the fallback lock could not be taken"
  return 1
}

# _lock_ident FILE — set _LOCK_IDENT to "inode size last-line" of FILE (and
# _LOCK_LAST to its last line).  A holder line carries a PID and an epoch, so
# a lock linked after FILE was judged differs even when the file system hands
# out the freed inode number again.
_lock_ident() {
  local ino
  _LOCK_IDENT=""
  if [ "$_SNAP_STAT_FMT" = "gnu" ]; then ino="$(stat -c '%i %s' "$1" 2>/dev/null)" || return 1
  else ino="$(stat -f '%i %z' "$1" 2>/dev/null)" || return 1; fi
  _lock_last "$1" || return 1
  _LOCK_IDENT="$ino $_LOCK_LAST"
}

# _reap_lock LOCK IDENT — remove the stale LOCK only when it is still the file
# judged as IDENT.  Reapers take turns through a mkdir mutex, so while one
# reaps, no other run removes or replaces the file (a fallback run only links
# a lock where none exists).  Under the mutex the file is checked again, then
# renamed to a name only this run uses and checked once more: the one writer
# left, a flock-backend run that announces itself in a file it just locked,
# gets its file put back.  Returns 0 when the judged file was removed, 2 when
# LOCK was already gone, 1 when another run holds it or is reaping it.
_REAP_MUTEX=""
_reap_lock() {
  local lock_file="$1" ident="$2" reap="${1}.reap.$$.${RANDOM}${RANDOM}" mutex="${1}.reaping" rc=1 mage
  if ! mkdir "$mutex" 2>/dev/null; then
    # A reaper that died inside the mutex leaves it behind; clear it once old.
    if [ -d "$mutex" ] && [ ! -L "$mutex" ]; then
      mage="$(_stat_mtime_age "$mutex" 2>/dev/null)" || mage=0
      if [ "$mage" -ge 60 ]; then rmdir "$mutex" 2>/dev/null || true; fi
    fi
    return 1
  fi
  _REAP_MUTEX="$mutex"
  if ! _lock_ident "$lock_file"; then
    [ -e "$lock_file" ] && rc=1 || rc=2
  elif [ "$_LOCK_IDENT" = "$ident" ] && mv "$lock_file" "$reap" 2>/dev/null; then
    if _lock_ident "$reap" && [ "$_LOCK_IDENT" = "$ident" ]; then
      rc=0
    elif ! ln "$reap" "$lock_file" 2>/dev/null; then
      _warn "lock changed hands while a stale lock was being replaced: $lock_file"
    fi
    rm -f "$reap" 2>/dev/null || true
  fi
  rmdir "$mutex" 2>/dev/null || true
  _REAP_MUTEX=""
  return "$rc"
}

# _fallback_link LOCK — write "PID EPOCH" to an exclusively created temp file
# (noclobber: a planted file or link at the name is never followed) and
# hard-link it to LOCK (atomic: fails when LOCK exists).
_fallback_link() {
  local lock_file="$1" tmp_lock n=0
  _lock_line
  while :; do
    tmp_lock="${1}.tmp.$$.${RANDOM}${RANDOM}"
    set -C
    if { printf '%s\n' "$_SNAPSHOT_LOCK_LINE" > "$tmp_lock"; } 2>/dev/null; then set +C; break; fi
    set +C
    n=$((n + 1)); [ "$n" -lt 20 ] || return 1
  done
  if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
    rm -f "$tmp_lock" 2>/dev/null || true; _SNAPSHOT_LOCK_FILE="$lock_file"; return 0
  fi
  rm -f "$tmp_lock" 2>/dev/null || true
  return 1
}

_release_snapshot_lock() {
  # Remove any in-flight temp file first (a signal can land mid-write).
  if [ -n "$_SNAP_TMP_FILES" ]; then
    local t
    while IFS= read -r t; do
      if [ -n "$t" ] && [ -e "$t" ]; then rm -f "$t" 2>/dev/null || true; fi
    done <<< "$_SNAP_TMP_FILES"
    _SNAP_TMP_FILES=""
  fi
  if [ -n "$_REAP_MUTEX" ]; then rmdir "$_REAP_MUTEX" 2>/dev/null || true; _REAP_MUTEX=""; fi
  local lock_file="${_SNAPSHOT_LOCK_FILE:-}"
  [ -n "$lock_file" ] || return 0
  # Remove the lock file only while it still carries this holder's line (a
  # live holder's file is never replaced by anyone else).  The flock backend
  # removes it while still holding the flock, then closing the descriptor
  # releases the flock.
  if _lock_last "$lock_file" && [ "$_LOCK_LAST" = "$_SNAPSHOT_LOCK_LINE" ]; then
    rm -f "$lock_file" 2>/dev/null || true
  fi
  [ "$_SNAPSHOT_LOCK_BACKEND" != "flock" ] || exec 9>&- 2>/dev/null || true
  _SNAPSHOT_LOCK_FILE=""
}

# Re-run-on-release marker.  A run that finds the lock held leaves this
# marker; the holder re-checks it after releasing and rebuilds once more, so
# a change committed while a snapshot was in flight is never lost.  It is a
# directory (mkdir never follows a planted symlink).
_mark_dirty()  { mkdir "$1" 2>/dev/null || true; }
_clear_dirty() { if [ -d "$1" ] && [ ! -L "$1" ]; then rmdir "$1" 2>/dev/null || true; fi; }
_is_dirty()    { [ -d "$1" ] && [ ! -L "$1" ]; }

# ---------------------------------------------------------------------------
# Atomic write (mktemp in the same directory + mv)
# ---------------------------------------------------------------------------

# _new_tmp TARGET — create an empty, exclusive temp file next to TARGET and
# set _TMP to its path.  noclobber makes the create O_EXCL, so a planted file
# or symlink at the name is never followed or truncated.
_new_tmp() {
  local n=0
  while :; do
    _TMP="${1}.tmp.$$.${RANDOM}${RANDOM}"
    set -C
    if { : > "$_TMP"; } 2>/dev/null; then set +C; break; fi
    set +C
    n=$((n + 1)); [ "$n" -lt 20 ] || return 1
  done
  _SNAP_TMP_FILES="${_SNAP_TMP_FILES}${_TMP}
"
}

# _replace_ok TARGET — true when TARGET may be replaced by a rename.  A
# symlink or directory at the name is refused: `mv` would follow a link to a
# directory and drop the file wherever it points.
_replace_ok() {
  if [ -L "$1" ] || [ -d "$1" ]; then
    _warn "refusing to replace ${1##*/}: it is a symlink or a directory"
    return 1
  fi
  return 0
}

# _write_atomic_from TARGET — copy stdin to TARGET atomically.
_write_atomic_from() {
  local target="$1" tmp
  if ! _replace_ok "$target"; then cat > /dev/null; return 1; fi
  _new_tmp "$target" || return 1
  tmp="$_TMP"
  if cat >> "$tmp"; then
    mv -f "$tmp" "$target"
  else
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Record producers (awk).  Every record is one line of 0x1f-separated fields.
# Fields never contain 0x1f, CR, or newline (stripped at the source).
# ---------------------------------------------------------------------------

# _read_sprint_yaml FILE — Z (sprint scalar) and K (story) records.  A key
# listed twice yields one K record (the first occurrence).
#   Z <name> <value>
#   K <index> <key> <yaml_status> <points> <risk_level> <blocked_by> <phase>
_read_sprint_yaml() {
  local yaml_file="$1"
  [ -f "$yaml_file" ] || return 0
  awk '
  function v(s, name) { s = $0; sub("^[[:space:]]*-?[[:space:]]*" name ":[[:space:]]*", "", s); gsub(/"/, "", s); gsub(/[\037\r]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  function z(name) { print "Z\037" name "\037" v($0, name) }
  BEGIN { in_stories=0; in_goals=0; si=0; gi=0; ck="" }
  /^sprint_id:/ { z("sprint_id"); next }
  /^status:/ && !in_stories { z("status"); next }
  /^start_date:/ { z("start_date"); next }
  /^end_date:/ { z("end_date"); next }
  /^capacity_utilization:/ { z("capacity_utilization"); next }
  /^epic_focus:/ { z("epic_focus"); next }
  /^goals:/ { in_goals=1; in_stories=0; rest=$0; sub(/^goals:[[:space:]]*/, "", rest); if (rest ~ /^\[\]/) in_goals=0; next }
  in_goals && /^[[:space:]]+-/ { g=$0; gsub(/^[[:space:]]+-[[:space:]]*"?|"?[[:space:]]*$/, "", g); gsub(/[\037\r]/, "", g); if (gi==0) print "Z\037goal\037" g; gi++; next }
  in_goals && /^[^[:space:]]/ { in_goals=0 }
  /^stories:/ { in_stories=1; in_goals=0; next }
  in_stories && /^[^[:space:]]/ && !/^stories:/ { in_stories=0; next }
  in_stories && /^[[:space:]]+-[[:space:]]+key:/ { si++; ck=v($0, "key"); key[si]=ck; next }
  in_stories && ck != "" {
    if (/^[[:space:]]+status:/)     { yst[si]=v($0, "status"); next }
    if (/^[[:space:]]+points:/)     { ypt[si]=v($0, "points"); next }
    if (/^[[:space:]]+risk_level:/) { yrk[si]=v($0, "risk_level"); next }
    if (/^[[:space:]]+blocked_by:/) { ybl[si]=v($0, "blocked_by"); next }
    if (/^[[:space:]]+phase:/)      { yph[si]=v($0, "phase"); next }
  }
  END { for (i=1; i<=si; i++) { if (key[i] in emitted) continue; emitted[key[i]]=1; print "K\037" i "\037" key[i] "\037" yst[i] "\037" ypt[i] "\037" yrk[i] "\037" ybl[i] "\037" yph[i] } }
  ' "$yaml_file"
}

# _read_config_records FILE — L (alias) and H (threshold) records.
_read_config_records() {
  local config_file="$1"
  [ -f "$config_file" ] || return 0
  awk '
    /^sprint_status_mod:/ { in_mod=1; next }
    in_mod && /^[^[:space:]]/ { in_mod=0; in_aliases=0 }
    in_mod && /user_aliases:/ { in_aliases=1; next }
    in_aliases && /^[[:space:]]+- / { val=$0; sub(/^[[:space:]]+-[[:space:]]*/, "", val); gsub(/["'\'']/, "", val); gsub(/[\037\r\n]/, "", val); print "L\037" val; next }
    in_aliases && /^[[:space:]]/ && !/^[[:space:]]+- / { in_aliases=0 }
    in_mod && /waiting_agent_threshold_seconds:/ { t=$0; sub(/.*waiting_agent_threshold_seconds:[[:space:]]*/, "", t); gsub(/"/, "", t); gsub(/[\037\r]/, "", t); sub(/[[:space:]]+$/, "", t); if (t!="" && t!="null") print "H\037" t }
  ' "$config_file" 2>/dev/null || true
}

# _story_records PARSED_CACHE — P/T/G records for every wanted story.
#   P <key> <rel> <mtime> <status> <points> <title> <manual_verification>
#   T <key> <done:true|false> <text>
#   G <key> <gate name> <gate status>
# SNAP_WANT (environment) lists the wanted stories, one per line:
#   key 0x1f rel 0x1f mtime 0x1f absolute-path
# A story whose (key, rel, mtime) matches a record set in PARSED_CACHE is
# copied from it; only the others are opened and parsed.
_story_records() {
  awk '
  function sx(s) { gsub(/[\037\r]/, "", s); return s }
  function parse(i,   f, r, line, n, in_fm, fm_done, in_tasks, in_gate, gsep, st, pts, ttl, mav, out, gfound, v, dm, tid, tx, l, c, cn, gn, gs) {
    f = wa[i]; n = 0; in_fm=0; fm_done=0; in_tasks=0; in_gate=0; gsep=0
    st=""; pts=0; ttl=""; mav="false"; out=""; gfound=0
    while ((r = (getline line < f)) > 0) {
      n++
      sub(/\r$/, "", line)
      if (line ~ /^---$/ && !fm_done) { if (in_fm) { fm_done=1; in_fm=0 } else in_fm=1; continue }
      if (in_fm) {
        if (line ~ /^status:/) { v=line; sub(/^status:[[:space:]]*/, "", v); gsub(/"/, "", v); sub(/[[:space:]]+$/, "", v); st=v; continue }
        if (line ~ /^points:/) { v=line; sub(/^points:[[:space:]]*/, "", v); gsub(/"/, "", v); pts=v+0; continue }
        if (line ~ /^title:/) { v=line; sub(/^title:[[:space:]]*/, "", v); sub(/^"/, "", v); sub(/"[[:space:]]*$/, "", v); sub(/^'\''/, "", v); sub(/'\''[[:space:]]*$/, "", v); ttl=v; continue }
        if (line ~ /^manual_verification:/) { v=line; sub(/^manual_verification:[[:space:]]*/, "", v); gsub(/"/, "", v); sub(/[[:space:]]+$/, "", v); mav=v; continue }
        continue
      }
      if (line ~ /^## Tasks \/ Subtasks/) { in_tasks=1; in_gate=0; continue }
      if (line ~ /^## / && in_tasks) in_tasks=0
      if (in_tasks && line ~ /^- \[/) {
        dm = substr(line, 4, 1); tid = (dm=="x" || dm=="X") ? "true" : "false"
        tx = line; sub(/^- \[.\][[:space:]]*/, "", tx)
        out = out "T" US wk[i] US tid US sx(tx) "\n"
        continue
      }
      if (line ~ /^## Review Gate/) { in_gate=1; in_tasks=0; gsep=0; continue }
      if (line ~ /^## / && in_gate) in_gate=0
      if (in_gate && line ~ /^\|.*\|.*\|/) {
        if (line ~ /Review.*Status.*Report/) continue
        if (line ~ /^[[:space:]]*\|[-]+/) { gsep=1; continue }
        if (!gsep) continue
        l = line; gsub(/^[[:space:]]*\|[[:space:]]*/, "", l)
        cn = split(l, c, /[[:space:]]*\|[[:space:]]*/)
        if (cn >= 2) {
          gn = c[1]; gs = c[2]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", gn); gsub(/^[[:space:]]+|[[:space:]]+$/, "", gs)
          out = out "G" US wk[i] US sx(gn) US sx(gs) "\n"; gfound=1
        }
      }
    }
    close(f)
    if (n == 0) { print "sprint-progress-snapshot: story file unreadable for " wk[i] ", skipping" > "/dev/stderr"; return }
    if (!gfound) print "sprint-progress-snapshot: no parseable Review Gate table for " wk[i] ", using default gates" > "/dev/stderr"
    print "P" US wk[i] US wr[i] US wm[i] US sx(st) US pts US sx(ttl) US sx(mav)
    printf "%s", out
  }
  BEGIN {
    FS = "\037"; US = "\037"; nw = 0; cur = 0
    m = split(ENVIRON["SNAP_WANT"], wl, "\n")
    for (j = 1; j <= m; j++) {
      if (wl[j] == "") continue
      split(wl[j], f, US); nw++
      wk[nw]=f[1]; wr[nw]=f[2]; wm[nw]=f[3]; wa[nw]=f[4]
      if (f[3] != "racy") ident[f[1] US f[2] US f[3]] = nw
    }
  }
  $1 == "P" { id = $2 US $3 US $4; cur = (id in ident) ? ident[id] : 0; if (cur && !(cur in cached) && !(cur in bad)) { cached[cur]=1; buf[cur]=$0 } else cur=0; next }
  # Only rows that belong to the story being copied are kept.  A row for any
  # other key means the parse cache was tampered with: the cached
  # record of that story is dropped and its file is parsed again.
  ($1 == "T" || $1 == "G") && cur {
    if ($2 == wk[cur]) buf[cur] = buf[cur] "\n" $0
    else { delete cached[cur]; delete buf[cur]; bad[cur] = 1; cur = 0 }
    next
  }
  { cur = 0 }
  END {
    for (i = 1; i <= nw; i++) {
      if (i in cached) print buf[i]
      else parse(i)
    }
  }
  ' "$1"
}

# _ledger_records LEDGER — V <key> <latest manual-test verdict>.
# SNAP_KEYS (environment) holds the space-separated story keys; passing them
# through the environment keeps BSD awk away from multi-line -v strings.
_ledger_records() {
  awk -F'\t' '
    BEGIN { n = split(ENVIRON["SNAP_KEYS"], ka, " "); for (i = 1; i <= n; i++) w[ka[i]] = 1 }
    ($1 in w) && $2 == "manual-test" { last[$1] = $4 }
    END { for (k in last) { v = last[k]; gsub(/[\037\r]/, "", v); print "V\037" k "\037" v } }
  ' "$1" 2>/dev/null || true
}

# _action_item_records REGISTRY — one A record holding the items as JSON.
_action_item_records() {
  local registry="$1" out
  if out="$(yq -o=json -I=0 '[(.items // [])[] | {"id": (.id // ""), "status": (.status // ""), "assignee": (.assignee // ""), "created": (.created_at // .created // "")}]' "$registry" 2>/dev/null)"; then
    printf 'A%s%s\n' "$_US" "$out"
  else
    _warn "action-items registry is unparseable, skipping rule-c"
  fi
}

# ---------------------------------------------------------------------------
# jq programs
# ---------------------------------------------------------------------------

# Shared definitions.  $ARGS.positional carries the command allowlist.
# shellcheck disable=SC2016  # jq program text, not shell expansions
_JQ_DEFS='
def strip: gsub("[\\x00-\\x1f\\x7f]"; "");
def clean: tostring | gsub("\t"; " ") | strip;
def cap($n): if length > $n then .[0:$n] else . end;
def nn: if . == null then null else (clean | if . == "" or . == "null" or . == "~" then null else . end) end;
def allow: . as $c | if ($c | type) == "string" and (($ARGS.positional | index([$c])) != null) then $c else null end;
def d2ep: if type == "string" then (try (strptime("%Y-%m-%d") | mktime) catch null) else null end;
def ep2d: floor | strftime("%Y-%m-%d");
def canon_gates: ["Code Review", "QA Tests", "Security Review", "Test Automation", "Test Review", "Performance Review"];
def capstr($n): if type == "string" then cap($n) else . end;
def natkey: [scan("[0-9]+|[^0-9]+") | (tonumber? // .)];
def timefields($sm):
  (now | floor) as $now
  | ($now | ep2d | d2ep) as $tep
  | (if .sprint == null then null else (.sprint.start_date | d2ep) end) as $sep
  | (if .sprint == null then null else (.sprint.end_date | d2ep) end) as $eep
  | (if $sep != null and $tep != null then ([((($tep - $sep) / 86400) | floor), 0] | max) else 0 end) as $cur
  | (if $sep != null and $eep != null then ((($eep - $sep) / 86400) | floor) else null end) as $tot
  | .generated_at = ($now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  | (if .sprint != null then .sprint.total_days = $tot else . end)
  | .day = {
      current: $cur,
      total: $tot,
      pace: (if $tot == null then null
             elif $cur == 0 then "starting"
             elif $eep != null and $tep > $eep then "overdue"
             elif $tot > 0 and $cur > 0 then
               (if (.totals.done_points * $tot) >= (.totals.total_points * $cur) then "on-pace" else "behind-pace" end)
             else "on-pace" end)
    }
  | .drift = ([.drift[] | select(.type != "stale_review")]
      + [.stories[] | select(.status == "review") | .key as $k | ($sm[$k] // 0) as $m
         | select($m > 0 and ($now - $m) > 172800)
         | {story_key: $k, type: "stale_review", detail: "Story in review for over 48 hours"}]);
'

# Warm program: validate the prior cache, re-sanitise every string it carries
# (control bytes stripped, field caps re-applied; a control byte always shows
# as an escape in the serialised document, so one scan of it decides whether
# the full walk is needed), keep only action entries
# whose rule, type and message have the exact shapes this script writes,
# re-apply the allowlist, refresh the time-derived fields.  Input: the cache
# file.  $smt: "key mtime key mtime …".
# shellcheck disable=SC2016
_JQ_WARM="${_JQ_DEFS}"'
def action_ok:
  type == "object" and (.message | type) == "string"
  and ((.rule == "a" and .type == "manual_test_due" and (.message | test("^Manual test is due for E[0-9]+-S[0-9]+$")))
    or (.rule == "c" and .type == "action_item_assigned" and (.message | test("^Action item .+ is assigned and (open|in-progress)$")))
    or (.rule == "d" and .type == "sprint_can_close" and .message == "All stories are done, sprint can be closed"));
if (type != "object") or (.schema_version != "1.0") or ((.stories | type) != "array")
   or ((.action_needed | type) != "array") or ((.drift | type) != "array")
   or ([.stories[] | type] | all(. == "object") | not)
then error("cache shape mismatch") else . end
| (if (tojson | test("\\\\(u00[01]|u007f|[bfnrt])"; "i")) then walk(if type == "string" then strip else . end) else . end)
| .stories |= map(
    (if (.title | type) == "string" and (.title | length) > 200 then .title = .title[0:200] else . end)
    | (if (.slug | type) == "string" and (.slug | length) > 200 then .slug = .slug[0:200] else . end)
    | (if (.status | type) == "string" and (.status | length) > 50 then .status = .status[0:50] else . end)
    | (if (.tasks.items | type) == "array" and any(.tasks.items[]; (.text | type) == "string" and (.text | length) > 200)
       then .tasks.items |= map(if type == "object" then .text |= capstr(200) else . end) else . end)
    | (if (.gates.rows | type) == "array" and any(.gates.rows[]; ((.name | type) == "string" and (.name | length) > 100) or ((.status | type) == "string" and (.status | length) > 50))
       then .gates.rows |= map(if type == "object" then (.name |= capstr(100) | .status |= capstr(50)) else . end) else . end))
| .action_needed |= map(select(action_ok) | .message |= cap(300) | .command |= allow)
| ([$smt | split(" ") | map(select(. != ""))] | .[0]) as $p
| ([range(0; ($p | length) - 1; 2) as $i | {key: $p[$i], value: ($p[$i + 1] | tonumber)}] | from_entries) as $sm
| timefields($sm)
'

# Cold program: assemble the whole document from records on stdin.
# shellcheck disable=SC2016
_JQ_COLD="${_JQ_DEFS}"'
[inputs | split("\u001f")] as $R
| ([$R[] | select(.[0] == "Z") | {key: .[1], value: (.[2] // "")}] | from_entries) as $Z
| ([$R[] | select(.[0] == "K") | {key: (.[2] // ""), value: {ys: (.[3] // ""), risk: (.[5] // ""), blk: (.[6] // ""), ph: (.[7] // "")}}] | from_entries) as $Y
| ([$R[] | select(.[0] == "M") | {key: .[1], value: ((.[2] // "") | tonumber? // null)}] | from_entries) as $MT
| (reduce ($R[] | select(.[0] == "P")) as $r ({}; .[$r[1]] = {status: ($r[4] // ""), points: ($r[5] // ""), title: ($r[6] // ""), mv: ($r[7] // "")})) as $P
| (reduce ($R[] | select(.[0] == "T")) as $r ({}; .[$r[1]] += [{text: ($r[3] // "" | clean | cap(200)), done: ($r[2] == "true")}])) as $T
| (reduce ($R[] | select(.[0] == "G")) as $r ({}; .[$r[1]] += [{name: ($r[2] // "" | clean | cap(100)),
      status: ($r[3] // "" | clean | cap(50) | if . == "NOT STARTED" then "UNVERIFIED" else . end)}])) as $G
| (reduce ($R[] | select(.[0] == "V")) as $r ({}; .[$r[1]] = ($r[2] // "" | clean | cap(50)))) as $V
| ([$R[] | select(.[0] == "L") | (.[1] // "") | strip | cap(100) | select(. != "")] | .[0:20]) as $aliases
| ([$R[] | select(.[0] == "H") | (.[1] // "") | tonumber? ] | (.[0] // 120)) as $thr
| ([$R[] | select(.[0] == "A") | .[1]] | .[0]
    | if . == null then [] else (try fromjson catch []) end
    | if type == "array" then . else [] end) as $AI
| ($Z.sprint_id // "" | nn) as $sid
| if $sid == null then
    {schema_version: "1.0", generated_at: "", sprint: null,
     totals: {done_points: 0, total_points: 0, done_stories: 0, total_stories: 0, progress_pct: 0},
     by_status: {}, day: {current: 0, total: null, pace: null}, active_phase: null,
     phases: [], unphased_stories: [], stories: [], action_needed: [], drift: [],
     readiness: {sprint_review: false, sprint_close: false},
     user_aliases: $aliases, waiting_agent_threshold_seconds: $thr}
    | timefields({})
  else
    ([$R[] | select(.[0] == "S") | {k: .[1], rel: (.[2] // ""), mt: ((.[3] // "0") | tonumber? // 0)}
      | select($P[.k] != null)]) as $S
    | [ $S[] | . as $s | $P[$s.k] as $p | ($Y[$s.k] // {}) as $y
        | ($p.status | clean | cap(50) | if . == "" then "unknown" else . end) as $st
        | (($p.points | tonumber? | floor) // 0) as $pts
        | ($y.ph | nn | if . == null then null else (tonumber? | select(. == floor and . >= 0)) // null end) as $ph
        | ($s.rel | split("/") | if length >= 2 then .[-2] else "" end) as $dir
        | (reduce (($G[$s.k] // [])[] | select(.name as $n | canon_gates | index([$n]) != null)) as $g
             ([]; if (map(.name) | index([$g.name])) != null then . else . + [$g] end)) as $rows
        | ($T[$s.k] // []) as $items
        | {key: $s.k,
           title: ($p.title | clean | cap(200) | if . == "" then "Story \($s.k)" else . end),
           slug: ($dir | if startswith($s.k + "-") then .[(($s.k | length) + 1):] else . end | clean | cap(200)),
           status: $st,
           points: $pts,
           phase: $ph,
           risk_level: ((($y.risk | nn) // "medium") | cap(50)),
           blocked_by: ($y.blk | nn | if . == null then null else cap(200) end),
           blocked_since: (if $st == "blocked" then ($s.mt | ep2d) else null end),
           tasks: {done: ([$items[] | select(.done)] | length), total: ($items | length), items: $items},
           gates: {passed: ([$rows[] | select(.status == "PASSED")] | length),
                   total: (canon_gates | length), rows: $rows},
           manual_test: {required: (($p.mv | clean) == "true"),
                         verdict: ($V[$s.k] // null | if . == "" then null else . end)},
           _mt: $s.mt,
           _ys: ($y.ys | nn)} ] as $stories
    | ($stories | length) as $n
    | ([$stories[] | select(.status == "done")]) as $done
    | (($done | map(.points) | add) // 0) as $dp
    | (($stories | map(.points) | add) // 0) as $tp
    | ($n > 0 and ($done | length) == $n) as $all_done
    | ($n > 0 and ([$stories[] | select(.status == "done" or .status == "review")] | length) == $n) as $all_dr
    | ($Z.status // "" | nn | if . == null then null else cap(50) end) as $sst
    | ([$stories[] | select(.phase != null) | .phase] | unique) as $pnums
    | ([$pnums[] as $pn | select([$stories[] | select(.phase == $pn and .status != "done")] | length > 0) | $pn] | .[0]) as $active
    | ($MT.ai_mt // null) as $aimt
    | ([$aliases[] | ascii_downcase]) as $al
    | (
        [ $stories[] | select(.manual_test.required and .gates.passed == 6 and .status != "done"
                              and (.manual_test.verdict == null or .manual_test.verdict == "UNVERIFIED"))
          | {rule: "a", type: "manual_test_due", story_keys: [.key],
             message: ("Manual test is due for \(.key)" | cap(300)),
             command: ("/gaia-test-manual" | allow), since: (._mt | ep2d), source: "story-file"} ]
      + ( [ $AI[] | select(type == "object")
            | {id: (.id // "" | clean | cap(100)), st: (.status // "" | clean),
               asn: (.assignee // "" | clean | ascii_downcase), cr: (.created // "" | clean)}
            | select(.id != "" and (.st == "open" or .st == "in-progress"))
            | select(.asn as $a | ($al | index([$a])) != null)
            | {rule: "c", type: "action_item_assigned", story_keys: [], item_id: .id,
               message: ("Action item \(.id) is assigned and \(.st)" | cap(300)),
               command: ("/gaia-action-items" | allow),
               since: (if (.cr | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) then .cr[0:10]
                       elif $aimt != null and $aimt > 0 then ($aimt | ep2d)
                       else (now | ep2d) end),
               source: "action-items"} ]
          | unique_by(.item_id) )
      + (if $sst == "active" and $all_done then
           [{rule: "d", type: "sprint_can_close", story_keys: [],
             message: "All stories are done, sprint can be closed",
             command: ("/gaia-sprint-close" | allow),
             since: (([$done[] | ._mt] | max) as $m | if $m != null and $m > 0 then ($m | ep2d) else (now | ep2d) end),
             source: "sprint-status"}]
         else [] end)
      | sort_by(.rule, (.story_keys[0] // "" | natkey), (.item_id // "" | natkey))
      ) as $actions
    | {schema_version: "1.0",
       generated_at: "",
       sprint: {id: ($sid | cap(200)),
                goal: ($Z.goal // "" | nn | if . == null then null else cap(200) end),
                start_date: ($Z.start_date // "" | nn | if . == null then null else cap(40) end),
                end_date: ($Z.end_date // "" | nn | if . == null then null else cap(40) end),
                status: $sst,
                total_days: null,
                capacity_utilization: ($Z.capacity_utilization // "" | nn | if . == null then null else cap(200) end),
                epic_focus: ($Z.epic_focus // "" | nn | if . == null then null else cap(200) end)},
       totals: {done_points: $dp, total_points: $tp, done_stories: ($done | length), total_stories: $n,
                progress_pct: (if $tp == 0 then 0 else (($dp * 100 / $tp) | floor) end)},
       by_status: (reduce $stories[] as $s ({}; .[$s.status].count += 1 | .[$s.status].points += $s.points)),
       day: {current: 0, total: null, pace: null},
       active_phase: $active,
       phases: [ $pnums[] as $pn | [$stories[] | select(.phase == $pn)] as $ps
                 | {phase: $pn,
                    status: (if $active == null or $pn < $active then "done" elif $pn == $active then "active" else "future" end),
                    stories: [$ps[] | .key],
                    done_count: ([$ps[] | select(.status == "done")] | length),
                    total_count: ($ps | length)} ],
       unphased_stories: [$stories[] | select(.phase == null) | .key],
       stories: [$stories[] | del(._mt, ._ys)],
       action_needed: $actions,
       drift: [ $stories[] | select(._ys != null and .status != ._ys)
                | {story_key: .key, type: "status_mismatch",
                   detail: ("Story file says \(.status), sprint yaml says \(._ys | cap(50))" | cap(200))} ],
       readiness: {sprint_review: $all_dr, sprint_close: $all_done},
       user_aliases: $aliases,
       waiting_agent_threshold_seconds: $thr}
    | timefields([$stories[] | {key: .key, value: ._mt}] | from_entries)
  end
'

# ---------------------------------------------------------------------------
# Warm fast-path: nothing tracked changed — refresh time-derived fields only
# ---------------------------------------------------------------------------

# _warm_reject REASON — the sidecar cannot be trusted: say why on stderr and
# fall back to a cold run.  An ordinary change (an mtime that moved, a file
# that appeared) falls back silently instead; only a sidecar that is out of
# date, malformed or points somewhere it must not is reported.
_warm_reject() { _warn "sidecar $1, rebuilding"; return 1; }

# Expected meta entries (name 0x09 project-relative-or-absolute path) are
# provided by the caller in _SNAP_EXPECTED_META.  The sidecar must carry
# exactly those entries and, when the story tree exists, an entry for the
# tree root; any story path must be project-relative, resolve (full symlink
# chain) inside the project root, and match its mtime; a tracked file
# recorded as absent (mtime 0) must still be absent.
_try_warm_fast_path() {
  [ -f "$CACHE_FILE" ] && [ -f "$SIDECAR_FILE" ] && [ -f "$PARSED_FILE" ] || return 1
  # Never trust (or follow) a link planted at one of the state file names.
  [ ! -L "$CACHE_FILE" ] && [ ! -L "$SIDECAR_FILE" ] && [ ! -L "$PARSED_FILE" ] || return 1

  local typ a b c ver=0 seen_meta="" rest have_root=0
  local -a st_paths=() st_exp=() rp_in=() rp_exp=() rp_key=() rp_kind=() smt_parts=()
  local -a link_key=() link_res=()
  while IFS=$'\t' read -r typ a b c; do
    case "$typ" in
      v4) ver=1 ;;
      v[0-9]*) ;;   # another format version: refused below as out of date
      story)
        _valid_story_key "$a" || _warm_reject "has an invalid story key" || return 1
        _rel_ok "$b" || _warm_reject "story path for $a is not project-relative" || return 1
        [[ $c =~ ^[0-9]+$ ]] || return 1
        rp_in+=("${RESOLVED_ROOT}/${b}"); rp_exp+=("$c"); rp_key+=("$a"); rp_kind+=("s")
        smt_parts+=("$a" "$c") ;;
      link)
        # The story file was found through this symlink; it must still lead
        # to the recorded story path.
        _valid_story_key "$a" || _warm_reject "has an invalid story key" || return 1
        _rel_ok "$b" || _warm_reject "link path for $a is not project-relative" || return 1
        rp_in+=("${RESOLVED_ROOT}/${b}"); rp_exp+=(""); rp_key+=("$a"); rp_kind+=("l") ;;
      dir)
        # The story tree root or one of its direct subdirectories.
        _has_ctl "$a" && { _warm_reject "has a story-tree entry with control characters"; return 1; }
        case "$a" in "$_SNAP_IMPL_REL"|"$_SNAP_IMPL_REL"/*) ;; *) return 1 ;; esac
        rest="${a#"$_SNAP_IMPL_REL"}"; rest="${rest#/}"
        case "$rest" in */*|.|..) _warm_reject "has a story-tree entry outside the tree"; return 1 ;; esac
        [ -n "$rest" ] || have_root=1
        [[ $b =~ ^[0-9]+$ ]] || return 1
        case "$a" in /*) st_paths+=("$a") ;; *) st_paths+=("${RESOLVED_ROOT}/${a}") ;; esac
        st_exp+=("$b") ;;
      meta)
        [[ $c =~ ^[0-9]+$ ]] || return 1
        local exp_line="${_SNAP_EXPECTED_META#*"${a}"	}"
        [ "$exp_line" != "$_SNAP_EXPECTED_META" ] || return 1
        exp_line="${exp_line%%
*}"
        [ "$b" = "$exp_line" ] || return 1
        local abs="$b"; case "$abs" in /*) ;; *) abs="${RESOLVED_ROOT}/${abs}" ;; esac
        if [ "$c" = "0" ]; then
          if [ -e "$abs" ]; then return 1; fi
        else
          st_paths+=("$abs"); st_exp+=("$c")
        fi
        seen_meta="${seen_meta}${a}
" ;;
      # A key whose story file was missing is re-resolved by a cold run.
      miss) return 1 ;;
      *) _warm_reject "has an unknown entry"; return 1 ;;
    esac
  done < "$SIDECAR_FILE"
  [ "$ver" = "1" ] || { _warm_reject "format is out of date"; return 1; }
  # The cold run always records the story-tree root when the tree exists; a
  # sidecar without it could hide a story directory that was added.
  if [ "$have_root" = "0" ] && [ -d "$IMPL_DIR" ] && [ ! -L "$IMPL_DIR" ]; then
    _warm_reject "has no story-tree entry"; return 1
  fi

  # Every expected meta entry must be present.
  local name _p
  while IFS=$'\t' read -r name _p; do
    [ -n "$name" ] || continue
    case "
${seen_meta}" in *"
${name}
"*) ;; *) _warm_reject "has no entry for ${name}"; return 1 ;; esac
  done <<< "$_SNAP_EXPECTED_META"

  # Story paths must resolve (full symlink chain) inside the project root.
  # The recorded story path is the resolved file itself, so it must still
  # resolve to itself (a path that now leads elsewhere was replaced by a
  # link), and a recorded link must still lead to its story's file.
  if [ "${#rp_in[@]}" -gt 0 ]; then
    local resolved line ri=0
    resolved="$(_realpath_batch "${rp_in[@]}")" || return 1
    while IFS= read -r line; do
      [ "$ri" -lt "${#rp_in[@]}" ] || return 1
      case "$line" in
        "?") return 1 ;;   # gone: an ordinary change
        "${RESOLVED_ROOT}/"*) ;;
        *) _warm_reject "story path for ${rp_key[$ri]} resolves outside the project root"; return 1 ;;
      esac
      _has_ctl "$line" && { _warm_reject "story path for ${rp_key[$ri]} contains control characters"; return 1; }
      if [ "${rp_kind[$ri]}" = "s" ]; then
        [ "$line" = "${rp_in[$ri]}" ] || return 1
        st_paths+=("$line"); st_exp+=("${rp_exp[$ri]}")
      else
        link_key+=("${rp_key[$ri]}"); link_res+=("$line")
      fi
      ri=$((ri + 1))
    done <<< "$resolved"
    [ "$ri" -eq "${#rp_in[@]}" ] || return 1
    # Every link must lead to its story's recorded path: ONE awk join over
    # the story rows then the link rows (linear, and no associative arrays,
    # which bash 3.2 lacks).  Keys, story paths and resolved link paths hold
    # no tab or line break (checked above), so the fields cannot shift.  A
    # link whose key has no story row fails.
    if [ "${#link_key[@]}" -gt 0 ]; then
      local sj li
      {
        for sj in "${!rp_key[@]}"; do
          [ "${rp_kind[$sj]}" != "s" ] || printf 's\t%s\t%s\n' "${rp_key[$sj]}" "${rp_in[$sj]}"
        done
        for li in "${!link_key[@]}"; do
          printf 'l\t%s\t%s\n' "${link_key[$li]}" "${link_res[$li]}"
        done
      } | awk -F '\t' '
        $1 == "s" { p[$2] = $3; next }
        !($2 in p) || p[$2] != $3 { bad = 1; exit }
        END { exit bad }' || return 1
    fi
  fi

  # ONE batch stat of every present tracked file.  An mtime that moved in
  # EITHER direction (a checkout can move it backwards) counts as a change.
  if [ "${#st_paths[@]}" -gt 0 ]; then
    local actual wi=0 act_mt
    actual="$(_stat_mtime_batch "${st_paths[@]}" 2>/dev/null)" || return 1
    while IFS= read -r act_mt; do
      [ "$wi" -lt "${#st_exp[@]}" ] || return 1
      [ "$act_mt" = "${st_exp[$wi]}" ] || return 1
      wi=$((wi + 1))
    done <<< "$actual"
    [ "$wi" -eq "${#st_exp[@]}" ] || return 1
  fi

  # Nothing changed — ONE jq call re-validates and refreshes the cache.
  local tmp smt=""
  [ "${#smt_parts[@]}" -eq 0 ] || smt="${smt_parts[*]}"
  _new_tmp "$CACHE_FILE" || return 1
  tmp="$_TMP"
  if ! jq -c --arg smt "$smt" "$_JQ_WARM" "$CACHE_FILE" --args "${_ALLOWED_COMMANDS[@]}" > "$tmp" 2>/dev/null \
     || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    _warn "cache does not match the schema, rebuilding"
    return 1
  fi
  if _replace_ok "$CACHE_FILE"; then
    mv -f "$tmp" "$CACHE_FILE"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# Batched story-file resolution — ONE find over implementation-artifacts
# ---------------------------------------------------------------------------

# A story file that is a symlink is taken like a regular file; the
# containment step then resolves its full chain and keeps it only when the
# target lies inside the project root (or warns that it escapes).
# Paths are read NUL-separated and every newline inside a path is turned into
# 0x01 first, so a directory name with a newline can never split into two
# lines; a path holding 0x01, 0x1f, CR or TAB is refused (BADPATH) instead of
# being taken, because those bytes could shift a record field later on.
_resolve_all_story_paths() {
  local impl_dir="$1"; shift
  find "$impl_dir" \( -type f -o -type l \) \( -name 'story.md' -o -name 'E*.md' \) -print0 2>/dev/null \
    | tr '\n\000' '\001\n' | SNAP_KEYS="$*" awk '
  BEGIN { n=split(ENVIRON["SNAP_KEYS"],ka," "); for(i=1;i<=n;i++) wanted[ka[i]]=1 }
  # keyof(NAME) — the story key NAME starts with ("KEY" or "KEY-..."), or "".
  function keyof(name,   k) {
    if (!match(name, /^E[0-9]+-S[0-9]+/)) return ""
    k = substr(name, 1, RLENGTH)
    if (length(name) > RLENGTH && substr(name, RLENGTH + 1, 1) != "-") return ""
    return k
  }
  function take(k, t, path) {
    if (k == "" || !(k in wanted)) return
    if (path ~ /[\001\037\r\t]/) { bad[k]=1; return }
    if (!(k in bt) || t < bt[k]) { bt[k]=t; bp[k]=path; delete am[k] }
    else if (t == bt[k] && path != bp[k]) am[k]=1
  }
  {
    path=$0; fname=path; sub(/.*\//,"",fname)
    parent=path; sub(/\/[^\/]*$/,"",parent); pname=parent; sub(/.*\//,"",pname)
    if (fname=="story.md") take(keyof(pname), 1, path)
    else if (pname=="stories") { k=keyof(fname); if (k != "" && fname != k ".md") take(k, 2, path) }
    else { base=fname; sub(/\.md$/,"",base); take(keyof(base), 3, path) }
  }
  END { for(i=1;i<=n;i++) { k=ka[i]; if(k in bad) print "BADPATH\t"k; if(k in am) print "AMBIG\t"k; else if(k in bp) print "FOUND\t"k"\t"bp[k]; else print "MISSING\t"k } }
  '
}

# _rel_of PATH — project-relative form of PATH when it is inside the root.
# Sets _REL (no subshell).  Accepts both the physical root and the root as
# given (on macOS a temp root under /var is physically /private/var).
_rel_of() {
  case "$1" in
    "${RESOLVED_ROOT}/"*) _REL="${1#"${RESOLVED_ROOT}"/}" ;;
    "${GIVEN_ROOT}/"*)    _REL="${1#"${GIVEN_ROOT}"/}" ;;
    *) _REL="$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# One build: warm fast path, or a (partially) incremental cold rebuild
# ---------------------------------------------------------------------------

_snapshot_build() {
  # Tracked meta files and the paths the sidecar must record for them.
  local ai_state="${STATE_DIR}/action-items.yaml"
  local ai_planning="${RESOLVED_ROOT}/.gaia/artifacts/planning-artifacts/action-items.yaml"
  local -a meta_names=("__sprint_status__" "__review_gate_ledger__" "__project_config__" "__action_items_state__" "__action_items_planning__")
  local -a meta_paths=("$YAML_FILE" "$LEDGER_FILE" "$CONFIG_FILE" "$ai_state" "$ai_planning")
  local -a meta_rels=()
  local mi
  _SNAP_EXPECTED_META=""
  for mi in "${!meta_paths[@]}"; do
    _rel_of "${meta_paths[$mi]}"; meta_rels+=("$_REL")
    _SNAP_EXPECTED_META="${_SNAP_EXPECTED_META}${meta_names[$mi]}	${_REL}
"
  done
  local yaml_rel="${meta_rels[0]}"
  _rel_of "$IMPL_DIR"; _SNAP_IMPL_REL="$_REL"

  if _try_warm_fast_path; then
    return 0
  fi

  # =========================================================================
  # Cold path
  # =========================================================================

  # A run started by the post-transition hook begins in the very second the
  # transition wrote its files.  Waiting for the next second first means
  # those files are older than this build, so they are recorded with their
  # real mtime (not "racy") and the next run can take the warm path.
  if [ "${GAIA_SNAPSHOT_HOOK_ACTIVE:-}" = "1" ]; then _wait_next_second; fi

  # Start of this build, in epoch seconds.  A tracked file whose mtime is
  # not older than this second may still change within the same second
  # without moving its mtime, so it is recorded as unverified ("racy") and
  # re-read by the next run instead of being trusted.
  local build_start="${EPOCHSECONDS:-}"
  [ -n "$build_start" ] || build_start="$(date +%s)"

  # --- Meta files must resolve inside the project root before they are read ---
  local -a meta_ok=() chk_idx=() chk_paths=()
  for mi in "${!meta_paths[@]}"; do
    meta_ok+=(1)
    if [ -e "${meta_paths[$mi]}" ]; then chk_idx+=("$mi"); chk_paths+=("${meta_paths[$mi]}"); fi
  done
  if [ "${#chk_paths[@]}" -gt 0 ]; then
    local m_resolved m_line m_i=0
    m_resolved="$(_realpath_batch "${chk_paths[@]}")" || m_resolved=""
    while IFS= read -r m_line; do
      [ "$m_i" -lt "${#chk_idx[@]}" ] || break
      if ! _inside_root "$m_line"; then
        meta_ok[${chk_idx[$m_i]}]=0
        _warn "${chk_paths[$m_i]} resolves outside the project root, not reading it"
      fi
      m_i=$((m_i + 1))
    done <<< "$m_resolved"
    while [ "$m_i" -lt "${#chk_idx[@]}" ]; do
      meta_ok[${chk_idx[$m_i]}]=0
      _warn "${chk_paths[$m_i]} could not be resolved, not reading it"
      m_i=$((m_i + 1))
    done
  fi

  # --- Old sidecar: recorded sprint-status mtime and story-tree directories ---
  local old_yaml_mt="" typ a b c
  local -a old_dirs=()
  if [ -f "$SIDECAR_FILE" ] && [ ! -L "$SIDECAR_FILE" ]; then
    while IFS=$'\t' read -r typ a b c; do
      case "$typ" in
        meta) if [ "$a" = "__sprint_status__" ] && [ "$b" = "$yaml_rel" ]; then old_yaml_mt="$c"; fi ;;
        dir)  old_dirs+=("${a}	${b}") ;;
      esac
    done < "$SIDECAR_FILE"
  fi

  # --- Sprint yaml (keys arrive de-duplicated, first occurrence kept) ---
  local yaml_rec=""
  if [ "${meta_ok[0]}" = "1" ]; then yaml_rec="$(_read_sprint_yaml "$YAML_FILE")"; fi
  local sprint_id_present=0
  local -a valid_keys=()
  local t1 t2 t3 rest
  if [ -n "$yaml_rec" ]; then
    while IFS="$_US" read -r t1 t2 t3 rest; do
      case "$t1" in
        Z) if [ "$t2" = "sprint_id" ] && [ -n "$t3" ] && [ "$t3" != "null" ] && [ "$t3" != "~" ]; then sprint_id_present=1; fi ;;
        K) [ -n "$t3" ] || continue
           if ! _valid_story_key "$t3"; then _warn "skipping invalid story key: ${t3:0:80}"; continue; fi
           valid_keys+=("$t3") ;;
      esac
    done <<< "$yaml_rec"
  fi
  [ "$sprint_id_present" = "1" ] || valid_keys=()

  # --- Story-tree directories: the root and its direct subdirectories.  A
  # story directory that is added, removed or renamed changes one of their
  # mtimes, which forces a fresh search (so a duplicate that appears for an
  # already-resolved key is noticed).
  # One find lists them (a glob over a large flat tree is slow in the C
  # locale on recent bash).  -type d never matches a symlink.  The listing
  # order is the directory's own order, which only changes when an entry is
  # added or removed, and that moves the root's mtime anyway.
  local -a tree_dirs=()
  if [ -d "$IMPL_DIR" ] && [ ! -L "$IMPL_DIR" ]; then
    tree_dirs+=("$IMPL_DIR")
    local dd
    while IFS= read -r -d '' dd; do
      _has_ctl "$dd" && continue
      tree_dirs+=("$dd")
    done < <(find "$IMPL_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi

  # --- Meta files present / absent, story-tree dirs: ONE batch stat ---
  local -a stat_targets=()
  for mi in "${!meta_paths[@]}"; do
    if [ -e "${meta_paths[$mi]}" ]; then stat_targets+=("${meta_paths[$mi]}"); fi
  done
  if [ "${#tree_dirs[@]}" -gt 0 ]; then stat_targets+=("${tree_dirs[@]}"); fi
  local -a stat_out=()
  if [ "${#stat_targets[@]}" -gt 0 ]; then
    local all_mts mt_line
    all_mts="$(_stat_mtime_batch "${stat_targets[@]}" 2>/dev/null)" || all_mts=""
    while IFS= read -r mt_line; do stat_out+=("$mt_line"); done <<< "$all_mts"
  fi
  local si=0
  local -a meta_mts=()
  for mi in "${!meta_paths[@]}"; do
    if [ -e "${meta_paths[$mi]}" ]; then meta_mts+=("${stat_out[$si]:-0}"); si=$((si + 1)); else meta_mts+=("0"); fi
  done
  local yaml_mt="${meta_mts[0]}"
  local -a dir_lines=()
  local dirs_same=1 di dir_mt
  for di in "${!tree_dirs[@]}"; do
    dir_mt="${stat_out[$si]:-0}"; si=$((si + 1))
    _rel_of "${tree_dirs[$di]}"
    [ "${old_dirs[$di]:-}" = "${_REL}	${dir_mt}" ] || dirs_same=0
    if [ "$dir_mt" -ge "$build_start" ]; then dir_mt="racy"; fi
    dir_lines+=("dir	${_REL}	${dir_mt}")
  done
  [ "${#old_dirs[@]}" -eq "${#tree_dirs[@]}" ] || dirs_same=0

  local yaml_changed=1
  if [ -n "$old_yaml_mt" ] && [ "$old_yaml_mt" = "$yaml_mt" ]; then yaml_changed=0; fi

  # --- Resolve story paths: cached path when neither the yaml nor the story
  # tree changed, else ONE find.  Both lookups print one line per key in yaml
  # order, so the merged list keeps the yaml story order.
  local -a key_path=() find_keys=() miss_arr=()
  local ki=0
  if [ "${#valid_keys[@]}" -gt 0 ]; then
    local cached_out="" ck crel
    if [ "$yaml_changed" = "0" ] && [ "$dirs_same" = "1" ] && [ -f "$SIDECAR_FILE" ] && [ ! -L "$SIDECAR_FILE" ]; then
      cached_out="$(SNAP_KEYS="${valid_keys[*]}" awk -F'\t' '
        BEGIN { n = split(ENVIRON["SNAP_KEYS"], ka, " ") }
        $1 == "story" && !($2 in rel) { rel[$2] = $3 }
        $1 == "link" && !($2 in lnk) { lnk[$2] = $3 }
        END { for (i = 1; i <= n; i++) print ka[i] "\t" ((ka[i] in lnk) ? lnk[ka[i]] : rel[ka[i]]) }
      ' "$SIDECAR_FILE" 2>/dev/null)" || cached_out=""
    fi
    for ki in "${!valid_keys[@]}"; do key_path+=(""); done
    if [ -n "$cached_out" ]; then
      # A cached path is only reused when it lies in the story tree; anything
      # else is re-resolved by the find below.
      ki=0
      while IFS=$'\t' read -r ck crel; do
        if [ "$ck" = "${valid_keys[$ki]:-}" ] && [ -n "$crel" ] && _rel_ok "$crel" \
           && [ "${crel#"${_SNAP_IMPL_REL}"/}" != "$crel" ] \
           && [ -f "${RESOLVED_ROOT}/${crel}" ]; then
          key_path[ki]="${RESOLVED_ROOT}/${crel}"
        fi
        ki=$((ki + 1))
      done <<< "$cached_out"
    fi
    for ki in "${!valid_keys[@]}"; do
      [ -n "${key_path[$ki]}" ] || find_keys+=("${valid_keys[$ki]}")
    done
  fi
  if [ "${#find_keys[@]}" -gt 0 ]; then
    local find_output="" sc fkey fpath
    if [ -d "$IMPL_DIR" ]; then
      find_output="$(_resolve_all_story_paths "$IMPL_DIR" "${find_keys[*]}")"
    else
      printf -v find_output 'MISSING\t%s\n' "${find_keys[@]}"
    fi
    ki=0
    while IFS=$'\t' read -r sc fkey fpath; do
      [ -n "$fkey" ] || continue
      # advance to this key's yaml slot (find output follows the same order)
      while [ "$ki" -lt "${#valid_keys[@]}" ] && [ "${valid_keys[$ki]}" != "$fkey" ]; do ki=$((ki + 1)); done
      case "$sc" in
        FOUND)   [ "$ki" -lt "${#valid_keys[@]}" ] && key_path[ki]="$fpath" ;;
        BADPATH) _warn "a story path for key $fkey contains control characters, ignoring it" ;;
        AMBIG)   _warn "multiple files match key $fkey, skipping"; miss_arr+=("miss	${fkey}") ;;
        *)       _warn "no file found for key $fkey"; miss_arr+=("miss	${fkey}") ;;
      esac
    done <<< "$find_output"
  fi
  local -a cand_keys=() cand_paths=()
  for ki in "${!valid_keys[@]}"; do
    if [ -n "${key_path[$ki]}" ]; then cand_keys+=("${valid_keys[$ki]}"); cand_paths+=("${key_path[$ki]}"); fi
  done

  # --- Containment: resolve the full symlink chain, keep paths inside the
  # root, and refuse any path holding a byte that could shift a record field.
  local -a ok_keys=() ok_abs=() ok_rel=() link_lines=()
  if [ "${#cand_keys[@]}" -gt 0 ]; then
    local -a exist_keys=() exist_paths=()
    local ci
    for ci in "${!cand_keys[@]}"; do
      if [ -e "${cand_paths[$ci]}" ]; then
        exist_keys+=("${cand_keys[$ci]}"); exist_paths+=("${cand_paths[$ci]}")
      else
        _warn "story file missing for ${cand_keys[$ci]}: ${cand_paths[$ci]}"
        miss_arr+=("miss	${cand_keys[$ci]}")
      fi
    done
    if [ "${#exist_keys[@]}" -gt 0 ]; then
      local resolved rp ri=0
      resolved="$(_realpath_batch "${exist_paths[@]}")" || resolved=""
      while IFS= read -r rp; do
        [ "$ri" -lt "${#exist_keys[@]}" ] || break
        if _has_ctl "$rp"; then
          _warn "story path for ${exist_keys[$ri]} contains control characters, skipping"
          miss_arr+=("miss	${exist_keys[$ri]}")
        elif ! _inside_root "$rp"; then
          _warn "path escapes project root for ${exist_keys[$ri]}, skipping"
          miss_arr+=("miss	${exist_keys[$ri]}")
        elif [ ! -f "$rp" ]; then
          # A link to a directory, a FIFO or a device is not a story file;
          # reading it would stop or hang the whole parse.
          _warn "story file for ${exist_keys[$ri]} is not a regular file, skipping"
          miss_arr+=("miss	${exist_keys[$ri]}")
        else
          ok_keys+=("${exist_keys[$ri]}"); ok_abs+=("$rp"); ok_rel+=("${rp#"${RESOLVED_ROOT}"/}")
          if [ -L "${exist_paths[$ri]}" ]; then
            _rel_of "${exist_paths[$ri]}"
            if _rel_ok "$_REL"; then link_lines+=("link	${exist_keys[$ri]}	${_REL}"); fi
          fi
        fi
        ri=$((ri + 1))
      done <<< "$resolved"
      while [ "$ri" -lt "${#exist_keys[@]}" ]; do
        _warn "path could not be resolved for ${exist_keys[$ri]}, skipping"
        miss_arr+=("miss	${exist_keys[$ri]}")
        ri=$((ri + 1))
      done
    fi
  fi

  # --- Story mtimes: ONE batch stat ---
  local -a ok_mts=() ok_rec=()
  local oi
  if [ "${#ok_abs[@]}" -gt 0 ]; then
    local st_mts st_line
    st_mts="$(_stat_mtime_batch "${ok_abs[@]}" 2>/dev/null)" || st_mts=""
    while IFS= read -r st_line; do ok_mts+=("${st_line:-0}"); done <<< "$st_mts"
  fi
  for oi in "${!ok_abs[@]}"; do [ -n "${ok_mts[$oi]:-}" ] || ok_mts[oi]=0; done
  # Recorded mtimes: the real value, or "racy" when it is not older than this
  # build (never matches on the next run, so the file is re-read).  A meta
  # file that is not read (it resolves outside the root) is always "racy",
  # so every run re-checks it.
  local -a meta_rec=()
  for mi in "${!meta_mts[@]}"; do
    if [ "${meta_ok[$mi]}" != "1" ] \
       || { [ "${meta_mts[$mi]}" != "0" ] && [ "${meta_mts[$mi]}" -ge "$build_start" ]; }; then
      meta_rec+=("racy")
    else
      meta_rec+=("${meta_mts[$mi]}")
    fi
  done
  for oi in "${!ok_mts[@]}"; do
    if [ "${ok_mts[$oi]}" -ge "$build_start" ]; then ok_rec+=("racy"); else ok_rec+=("${ok_mts[$oi]}"); fi
  done

  # --- Story records (unchanged stories come from the parse cache) ---
  local want="" story_rec="" s_lines=""
  local -a want_arr=() s_arr=() story_lines=()
  for oi in "${!ok_keys[@]}"; do
    want_arr+=("${ok_keys[$oi]}${_US}${ok_rel[$oi]}${_US}${ok_rec[$oi]}${_US}${ok_abs[$oi]}")
    s_arr+=("S${_US}${ok_keys[$oi]}${_US}${ok_rel[$oi]}${_US}${ok_mts[$oi]}")
    story_lines+=("story	${ok_keys[$oi]}	${ok_rel[$oi]}	${ok_rec[$oi]}")
  done
  if [ "${#want_arr[@]}" -gt 0 ]; then
    printf -v want '%s\n' "${want_arr[@]}"
    printf -v s_lines '%s\n' "${s_arr[@]}"
    local parsed_src="/dev/null"
    if [ -f "$PARSED_FILE" ] && [ ! -L "$PARSED_FILE" ]; then parsed_src="$PARSED_FILE"; fi
    if ! story_rec="$(SNAP_WANT="$want" _story_records "$parsed_src")"; then
      # awk cannot recover from a read error, so one unreadable story file
      # stops the whole parse.  Parse the stories one at a time instead: only
      # the unreadable one is lost, and it is re-checked on the next run.
      local -a one_arr=()
      local one_rec
      for oi in "${!want_arr[@]}"; do
        if one_rec="$(SNAP_WANT="${want_arr[$oi]}" _story_records /dev/null)"; then
          [ -z "$one_rec" ] || one_arr+=("$one_rec")
        else
          _warn "story file for ${ok_keys[$oi]} could not be read, skipping"
          miss_arr+=("miss	${ok_keys[$oi]}")
        fi
      done
      story_rec=""
      [ "${#one_arr[@]}" -eq 0 ] || { printf -v story_rec '%s\n' "${one_arr[@]}"; story_rec="${story_rec%$'\n'}"; }
    fi
  fi

  # --- Ledger verdicts ---
  local ledger_rec=""
  if [ "${meta_ok[1]}" = "1" ] && [ -f "$LEDGER_FILE" ] && [ "${#ok_keys[@]}" -gt 0 ]; then
    ledger_rec="$(SNAP_KEYS="${ok_keys[*]}" _ledger_records "$LEDGER_FILE")"
  fi

  # --- Config: aliases + threshold ---
  local cfg_rec="" cfg_out="" have_alias=0 thr_raw=""
  local -a cfg_arr=()
  if [ "${meta_ok[2]}" = "1" ]; then cfg_rec="$(_read_config_records "$CONFIG_FILE")"; fi
  if [ -n "$cfg_rec" ]; then
    while IFS="$_US" read -r t1 t2; do
      case "$t1" in
        L) have_alias=1; cfg_arr+=("L${_US}${t2}") ;;
        H) thr_raw="$t2" ;;
      esac
    done <<< "$cfg_rec"
  fi
  if [ "$have_alias" = "0" ]; then
    local gname
    gname="$(git config user.name 2>/dev/null || true)"
    gname="${gname//$_US/}"
    cfg_arr=("L${_US}user" "L${_US}${gname}")
  fi
  printf -v cfg_out '%s\n' "${cfg_arr[@]}"
  local thr; thr="$(_validate_threshold "$thr_raw")"

  # --- Action-items registry (canonical state file first, then the resolver) ---
  local ai_rec="" ai_path="" ai_mt="" ai_readable=1
  if [ "${#ok_keys[@]}" -gt 0 ] || [ "$sprint_id_present" = "1" ]; then
    if [ -s "$ai_state" ]; then
      ai_path="$ai_state"
    elif [ -x "${_SELF_DIR}/lib/resolve-artifact-path.sh" ]; then
      ai_path="$("${_SELF_DIR}/lib/resolve-artifact-path.sh" action_items --project-root "$RESOLVED_ROOT" --existing-only 2>/dev/null)" || ai_path=""
    fi
    if [ -n "$ai_path" ] && [ -f "$ai_path" ]; then
      local ai_known=0
      for mi in "${!meta_paths[@]}"; do
        if [ "${meta_paths[$mi]}" = "$ai_path" ]; then
          ai_known=1; ai_mt="${meta_mts[$mi]}"; ai_readable="${meta_ok[$mi]}"
        fi
      done
      if [ "$ai_known" = "0" ]; then
        local ai_real
        if ai_real="$(_realpath_one "$ai_path")" && _inside_root "$ai_real"; then :; else
          ai_readable=0; _warn "$ai_path resolves outside the project root, not reading it"
        fi
      fi
      if [ "$ai_readable" = "1" ]; then
        ai_rec="$(_action_item_records "$ai_path")"
        [ -n "$ai_mt" ] || ai_mt="$(_stat_mtime "$ai_path" 2>/dev/null || printf '0')"
      fi
    fi
  fi

  # --- Assemble with ONE jq call and write atomically ---
  local cache_tmp
  _new_tmp "$CACHE_FILE" || return 1
  cache_tmp="$_TMP"
  if ! {
    [ -z "$yaml_rec" ]   || printf '%s\n' "$yaml_rec"
    printf '%s' "$s_lines"
    [ -z "$story_rec" ]  || printf '%s\n' "$story_rec"
    [ -z "$ledger_rec" ] || printf '%s\n' "$ledger_rec"
    printf '%s' "$cfg_out"
    printf 'H%s%s\n' "$_US" "$thr"
    printf 'M%sai_mt%s%s\n' "$_US" "$_US" "${ai_mt:-0}"
    [ -z "$ai_rec" ]     || printf '%s\n' "$ai_rec"
  } | jq -n -R -c "$_JQ_COLD" --args "${_ALLOWED_COMMANDS[@]}" > "$cache_tmp" || [ ! -s "$cache_tmp" ]; then
    rm -f "$cache_tmp" 2>/dev/null || true
    _warn "cache assembly failed, keeping the previous cache"
    return 0
  fi
  if ! _replace_ok "$CACHE_FILE"; then
    rm -f "$cache_tmp" 2>/dev/null || true
    return 0
  fi
  mv -f "$cache_tmp" "$CACHE_FILE"

  # --- Parse cache + sidecar ---
  printf '%s\n' "$story_rec" | _write_atomic_from "$PARSED_FILE" || true
  local -a side_arr=("v4")
  [ "${#story_lines[@]}" -eq 0 ] || side_arr+=("${story_lines[@]}")
  [ "${#link_lines[@]}" -eq 0 ] || side_arr+=("${link_lines[@]}")
  [ "${#dir_lines[@]}" -eq 0 ] || side_arr+=("${dir_lines[@]}")
  for mi in "${!meta_names[@]}"; do
    side_arr+=("meta	${meta_names[$mi]}	${meta_rels[$mi]}	${meta_rec[$mi]}")
  done
  [ "${#miss_arr[@]}" -eq 0 ] || side_arr+=("${miss_arr[@]}")
  local new_sidecar
  printf -v new_sidecar '%s\n' "${side_arr[@]}"
  printf '%s' "$new_sidecar" | _write_atomic_from "$SIDECAR_FILE" || true
}

# _inside_root PATH — true when the resolved PATH lies inside the project
# root and holds no control byte.
_inside_root() {
  case "$1" in "${RESOLVED_ROOT}/"*) ;; *) return 1 ;; esac
  ! _has_ctl "$1"
}

# _wait_next_second — sleep until the epoch second changes.
_wait_next_second() {
  local s0="${EPOCHSECONDS:-}" frac rem
  if [ -z "$s0" ] || [ -z "${EPOCHREALTIME:-}" ]; then sleep 1; return 0; fi
  frac="${EPOCHREALTIME#*[.,]}"; frac="${frac:0:3}"
  rem=$(( 1000 - 10#${frac:-0} ))
  if [ "$rem" -ge 1000 ]; then sleep 1; else printf -v rem '0.%03d' "$rem"; sleep "$rem"; fi
  while [ "$EPOCHSECONDS" = "$s0" ]; do sleep 0.02; done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_snapshot_main() {
  GIVEN_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$PWD}}"
  while [ "${#GIVEN_ROOT}" -gt 1 ] && [ "${GIVEN_ROOT%/}" != "$GIVEN_ROOT" ]; do GIVEN_ROOT="${GIVEN_ROOT%/}"; done
  RESOLVED_ROOT="$(cd "$GIVEN_ROOT" 2>/dev/null && pwd -P)" || {
    _warn "project root not found"; exit 1; }

  STATE_DIR="${RESOLVED_ROOT}/.gaia/state"
  CACHE_FILE="${STATE_DIR}/${_CACHE_NAME}"
  SIDECAR_FILE="${STATE_DIR}/${_SIDECAR_NAME}"
  PARSED_FILE="${STATE_DIR}/${_PARSED_NAME}"
  LOCK_FILE="${CACHE_FILE}${_LOCK_SUFFIX}"
  CONFIG_FILE="${RESOLVED_ROOT}/.gaia/config/project-config.yaml"
  YAML_FILE="${SPRINT_STATUS_YAML:-${STATE_DIR}/sprint-status.yaml}"

  # Story tree: env override, canonical tree, then the legacy docs/ tree.
  if [ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
    IMPL_DIR="$IMPLEMENTATION_ARTIFACTS"
  elif [ -d "${RESOLVED_ROOT}/.gaia/artifacts/implementation-artifacts" ]; then
    IMPL_DIR="${RESOLVED_ROOT}/.gaia/artifacts/implementation-artifacts"
  else
    IMPL_DIR="${RESOLVED_ROOT}/docs/implementation-artifacts"
  fi

  while [ "${#IMPL_DIR}" -gt 1 ] && [ "${IMPL_DIR%/}" != "$IMPL_DIR" ]; do IMPL_DIR="${IMPL_DIR%/}"; done

  # Review-gate ledger: same precedence as review-gate.sh.
  if [ -n "${REVIEW_GATE_LEDGER:-}" ]; then
    LEDGER_FILE="$REVIEW_GATE_LEDGER"
  elif [ -d "${RESOLVED_ROOT}/.gaia" ]; then
    LEDGER_FILE="${STATE_DIR}/.review-gate-ledger"
  else
    LEDGER_FILE="${RESOLVED_ROOT}/.review-gate-ledger"
  fi

  # The state directory must be a real directory inside the project root: a
  # symlinked .gaia or .gaia/state would send every write somewhere else.
  # RESOLVED_ROOT is physical, so two link checks are enough (no fork).
  if [ -L "${RESOLVED_ROOT}/.gaia" ] || [ -L "$STATE_DIR" ]; then
    _warn "state directory is a symlink, refusing to write: $STATE_DIR"; exit 0
  fi
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true

  trap '_release_snapshot_lock' EXIT
  trap '_release_snapshot_lock; exit 143' TERM
  trap '_release_snapshot_lock; exit 130' INT

  local dirty="${LOCK_FILE}.dirty" pass=0
  while :; do
    if ! _try_snapshot_lock "$LOCK_FILE"; then
      [ "$_SNAPSHOT_LOCK_REFUSED" = "0" ] || exit 0
      # Ask the holder to rebuild after it releases, then retry once in case
      # it released between our attempt and the marker.
      _mark_dirty "$dirty"
      if [ "$pass" -gt 0 ] || ! _try_snapshot_lock "$LOCK_FILE"; then
        _warn "lock not taken (${_SNAPSHOT_LOCK_REASON:-held by another process}), skipping"; exit 0
      fi
    fi
    pass=$((pass + 1))
    _clear_dirty "$dirty"
    _snapshot_build
    _release_snapshot_lock
    _is_dirty "$dirty" || break
    [ "$pass" -lt 5 ] || break
  done
  exit 0
}

# Main guard — allow sourcing for testability
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _snapshot_main "$@"
fi
