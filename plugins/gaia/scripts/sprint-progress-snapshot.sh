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
# each tracked file with its project-relative path and mtime (0 = absent).
# The per-story parse records are kept in .sprint-progress-parsed, so a run
# only re-parses story files whose path or mtime changed.
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

_stat_mtime_age() {
  local mt now
  mt="$(_stat_mtime "$1")"
  now="$(date +%s)"
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
    */*) d="$(cd -P "${p%/*}" 2>/dev/null && pwd -P)" || return 1
         printf '%s/%s\n' "${d%/}" "${p##*/}" ;;
    *)   d="$(pwd -P)"; printf '%s/%s\n' "${d%/}" "$p" ;;
  esac
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

# _validate_threshold STR — return a valid non-negative integer, or 120 with a warning
_validate_threshold() {
  local v="$1"
  # Must be a plain non-negative integer (digits only, bounded length)
  if [ -n "$v" ] && [ "${#v}" -le 10 ] && [[ $v =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#$v))"
  else
    [ -z "$v" ] || _warn "invalid threshold value '${v:0:20}', using default 120"
    printf '120'
  fi
}

# _validate_command CMD — prints CMD when it is in the hardcoded allowlist,
# otherwise prints null.  The jq assembly applies the same allowlist (it is
# handed _ALLOWED_COMMANDS as positional arguments) on every run, cold or warm.
_validate_command() {
  local cmd="$1"
  if [ -z "$cmd" ]; then printf 'null'; return 0; fi
  local allowed
  for allowed in "${_ALLOWED_COMMANDS[@]}"; do
    if [ "$cmd" = "$allowed" ]; then printf '%s' "$cmd"; return 0; fi
  done
  printf 'null'
}

_valid_story_key() {
  [[ $1 =~ ^E[0-9]+\-S[0-9]+$ ]]
}

# _rel_ok REL — a sidecar path must be project-relative with no `..` segment.
_rel_ok() {
  case "$1" in
    ""|/*|..|../*|*/../*|*/..) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Single-flight non-blocking lock (fixed fd 9)
# ---------------------------------------------------------------------------

_SNAPSHOT_LOCK_FILE=""
_SNAPSHOT_LOCK_BACKEND=""
_SNAPSHOT_LOCK_REFUSED=0
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

_try_snapshot_lock() {
  local lock_file="$1"
  _SNAPSHOT_LOCK_REFUSED=0
  if ! _snapshot_lock_path_policy "$lock_file"; then
    _SNAPSHOT_LOCK_REFUSED=1; return 1
  fi

  if command -v flock >/dev/null 2>&1 && [ "${GAIA_LOCK_FORCE_FALLBACK:-}" != "1" ]; then
    _SNAPSHOT_LOCK_BACKEND="flock"
    exec 9>>"$lock_file" || return 1
    if flock -n 9 2>/dev/null; then _SNAPSHOT_LOCK_FILE="$lock_file"; return 0; fi
    exec 9>&-
    return 1
  fi

  # Fallback: atomic ln, single attempt, stale-holder reap
  _SNAPSHOT_LOCK_BACKEND="fallback"
  local tmp_lock="${lock_file}.tmp.$$.${RANDOM}"
  printf '%s %s\n' "$$" "$(date +%s)" > "$tmp_lock" 2>/dev/null || {
    rm -f "$tmp_lock" 2>/dev/null || true; return 1
  }
  if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
    rm -f "$tmp_lock" 2>/dev/null || true; _SNAPSHOT_LOCK_FILE="$lock_file"; return 0
  fi
  rm -f "$tmp_lock" 2>/dev/null || true

  # Stale-holder reap (dead PID + age > 60 s)
  local holder=""
  read -r holder _ < "$lock_file" 2>/dev/null || true
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    local age; age="$(_stat_mtime_age "$lock_file")" || age=0
    if [ "$age" -ge 60 ]; then
      rm -f "$lock_file" 2>/dev/null || true
      local tmp2="${lock_file}.tmp.$$.${RANDOM}"
      printf '%s %s\n' "$$" "$(date +%s)" > "$tmp2" 2>/dev/null || {
        rm -f "$tmp2" 2>/dev/null || true; return 1
      }
      if ln "$tmp2" "$lock_file" 2>/dev/null; then
        rm -f "$tmp2" 2>/dev/null || true; _SNAPSHOT_LOCK_FILE="$lock_file"; return 0
      fi
      rm -f "$tmp2" 2>/dev/null || true
    fi
  fi
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
  local lock_file="${_SNAPSHOT_LOCK_FILE:-}"
  [ -n "$lock_file" ] || return 0
  if [ "$_SNAPSHOT_LOCK_BACKEND" = "flock" ]; then
    # Closing the only descriptor on the lock file releases the flock.
    exec 9>&- 2>/dev/null || true
  else
    local holder=""
    read -r holder _ < "$lock_file" 2>/dev/null || true
    if [ "$holder" = "$$" ]; then rm -f "$lock_file" 2>/dev/null || true; fi
  fi
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

# _write_atomic_from TARGET — copy stdin to TARGET atomically.
_write_atomic_from() {
  local target="$1" tmp
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

# _read_sprint_yaml FILE — Z (sprint scalar) and K (story) records.
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
  END { for (i=1; i<=si; i++) print "K\037" i "\037" key[i] "\037" yst[i] "\037" ypt[i] "\037" yrk[i] "\037" ybl[i] "\037" yph[i] }
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
  $1 == "P" { id = $2 US $3 US $4; cur = (id in ident) ? ident[id] : 0; if (cur && !(cur in cached)) { cached[cur]=1; buf[cur]=$0 } else cur=0; next }
  ($1 == "T" || $1 == "G") && cur { buf[cur] = buf[cur] "\n" $0; next }
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

# Warm program: validate the prior cache, re-apply the allowlist, refresh the
# time-derived fields.  Input: the cache file.  $smt: "key mtime key mtime …".
# shellcheck disable=SC2016
_JQ_WARM="${_JQ_DEFS}"'
if (type != "object") or (.schema_version != "1.0") or ((.stories | type) != "array")
   or ((.action_needed | type) != "array") or ((.drift | type) != "array")
then error("cache shape mismatch") else . end
| ([$smt | split(" ") | map(select(. != ""))] | .[0]) as $p
| ([range(0; ($p | length) - 1; 2) as $i | {key: $p[$i], value: ($p[$i + 1] | tonumber)}] | from_entries) as $sm
| .action_needed |= map(.command |= allow)
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
        | ($G[$s.k] // []) as $rows
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
                   total: ($rows | length | if . == 0 then 6 else . end), rows: $rows},
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
               since: (if .cr != "" and .cr != "null" then .cr[0:10]
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
      | sort_by(.rule, (.story_keys[0] // ""), (.item_id // ""))
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

# Expected meta entries (name 0x09 project-relative-or-absolute path) are
# provided by the caller in _SNAP_EXPECTED_META.  The sidecar must carry
# exactly those entries; any story path must be project-relative, resolve
# (full symlink chain) inside the project root, and match its mtime; a
# tracked file recorded as absent (mtime 0) must still be absent.
_try_warm_fast_path() {
  [ -f "$CACHE_FILE" ] && [ -f "$SIDECAR_FILE" ] && [ -f "$PARSED_FILE" ] || return 1

  local typ a b c ver=0 seen_meta="" smt=""
  local -a st_paths=() st_exp=() rp_in=() rp_exp=()
  while IFS=$'\t' read -r typ a b c; do
    case "$typ" in
      v2) ver=1 ;;
      story)
        _valid_story_key "$a" || return 1
        _rel_ok "$b" || return 1
        [[ $c =~ ^[0-9]+$ ]] || return 1
        rp_in+=("${RESOLVED_ROOT}/${b}"); rp_exp+=("$c")
        smt="${smt} ${a} ${c}" ;;
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
      *) return 1 ;;
    esac
  done < "$SIDECAR_FILE"
  [ "$ver" = "1" ] || return 1

  # Every expected meta entry must be present.
  local name _p
  while IFS=$'\t' read -r name _p; do
    [ -n "$name" ] || continue
    case "
${seen_meta}" in *"
${name}
"*) ;; *) return 1 ;; esac
  done <<< "$_SNAP_EXPECTED_META"

  # Story paths must resolve (full symlink chain) inside the project root;
  # the mtime that counts is the resolved file's, not a link's.
  if [ "${#rp_in[@]}" -gt 0 ]; then
    local resolved line ri=0
    resolved="$(_realpath_batch "${rp_in[@]}")" || return 1
    while IFS= read -r line; do
      case "$line" in "${RESOLVED_ROOT}/"*) ;; *) return 1 ;; esac
      [ "$ri" -lt "${#rp_in[@]}" ] || return 1
      st_paths+=("$line"); st_exp+=("${rp_exp[$ri]}")
      ri=$((ri + 1))
    done <<< "$resolved"
    [ "$ri" -eq "${#rp_in[@]}" ] || return 1
  fi

  # ONE batch stat of every present tracked file.
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
  local tmp
  _new_tmp "$CACHE_FILE" || return 1
  tmp="$_TMP"
  if jq -c --arg smt "$smt" "$_JQ_WARM" "$CACHE_FILE" --args "${_ALLOWED_COMMANDS[@]}" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    mv -f "$tmp" "$CACHE_FILE"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# Batched story-file resolution — ONE find over implementation-artifacts
# ---------------------------------------------------------------------------

_resolve_all_story_paths() {
  local impl_dir="$1"; shift
  find "$impl_dir" -type f \( -name 'story.md' -o -name 'E*.md' \) 2>/dev/null | SNAP_KEYS="$*" awk '
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
  END { for(i=1;i<=n;i++) { k=ka[i]; if(k in am) print "AMBIG\t"k; else if(k in bp) print "FOUND\t"k"\t"bp[k]; else print "MISSING\t"k } }
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

  if _try_warm_fast_path; then
    return 0
  fi

  # =========================================================================
  # Cold path
  # =========================================================================

  # Start of this build, in epoch seconds.  A tracked file whose mtime is
  # not older than this second may still change within the same second
  # without moving its mtime, so it is recorded as unverified ("racy") and
  # re-read by the next run instead of being trusted.
  local build_start="${EPOCHSECONDS:-}"
  [ -n "$build_start" ] || build_start="$(date +%s)"

  # --- Old sidecar: recorded sprint-status mtime ---
  local old_yaml_mt="" typ a b c
  if [ -f "$SIDECAR_FILE" ]; then
    while IFS=$'\t' read -r typ a b c; do
      if [ "$typ" = "meta" ] && [ "$a" = "__sprint_status__" ] && [ "$b" = "$yaml_rel" ]; then old_yaml_mt="$c"; fi
    done < "$SIDECAR_FILE"
  fi

  # --- Sprint yaml ---
  local yaml_rec
  yaml_rec="$(_read_sprint_yaml "$YAML_FILE")"
  local sprint_id_present=0
  local -a valid_keys=()
  local seen_keys=" " t1 t2 t3 rest
  if [ -n "$yaml_rec" ]; then
    while IFS="$_US" read -r t1 t2 t3 rest; do
      case "$t1" in
        Z) if [ "$t2" = "sprint_id" ] && [ -n "$t3" ] && [ "$t3" != "null" ] && [ "$t3" != "~" ]; then sprint_id_present=1; fi ;;
        K) [ -n "$t3" ] || continue
           if ! _valid_story_key "$t3"; then _warn "skipping invalid story key: ${t3:0:80}"; continue; fi
           case "$seen_keys" in *" ${t3} "*) continue ;; esac
           seen_keys="${seen_keys}${t3} "
           valid_keys+=("$t3") ;;
      esac
    done <<< "$yaml_rec"
  fi
  [ "$sprint_id_present" = "1" ] || valid_keys=()

  local yaml_mt=0
  if [ -f "$YAML_FILE" ]; then yaml_mt="$(_stat_mtime "$YAML_FILE")"; fi
  local yaml_changed=1
  if [ -n "$old_yaml_mt" ] && [ "$old_yaml_mt" = "$yaml_mt" ]; then yaml_changed=0; fi

  # --- Resolve story paths: cached path when the yaml is unchanged, else ONE find.
  # Both lookups print one line per key in yaml order, so the merged list
  # keeps the yaml story order.
  local -a key_path=()
  local keys_to_find="" miss_lines="" key ki=0
  if [ "${#valid_keys[@]}" -gt 0 ]; then
    local cached_out="" ck crel
    if [ "$yaml_changed" = "0" ] && [ -f "$SIDECAR_FILE" ]; then
      cached_out="$(SNAP_KEYS="${valid_keys[*]}" awk -F'\t' '
        BEGIN { n = split(ENVIRON["SNAP_KEYS"], ka, " ") }
        $1 == "story" && !($2 in rel) { rel[$2] = $3 }
        END { for (i = 1; i <= n; i++) print ka[i] "\t" rel[ka[i]] }
      ' "$SIDECAR_FILE" 2>/dev/null)" || cached_out=""
    fi
    for key in "${valid_keys[@]}"; do key_path+=(""); done
    if [ -n "$cached_out" ]; then
      # A cached path is only reused when it lies in the story tree; anything
      # else is re-resolved by the find below.
      _rel_of "$IMPL_DIR"; local impl_rel="$_REL"
      ki=0
      while IFS=$'\t' read -r ck crel; do
        if [ "$ck" = "${valid_keys[$ki]:-}" ] && [ -n "$crel" ] && _rel_ok "$crel" \
           && [ "${crel#"${impl_rel}"/}" != "$crel" ] \
           && [ -f "${RESOLVED_ROOT}/${crel}" ]; then
          key_path[ki]="${RESOLVED_ROOT}/${crel}"
        fi
        ki=$((ki + 1))
      done <<< "$cached_out"
    fi
    for ki in "${!valid_keys[@]}"; do
      [ -n "${key_path[$ki]}" ] || keys_to_find="${keys_to_find:+${keys_to_find} }${valid_keys[$ki]}"
    done
  fi
  if [ -n "$keys_to_find" ]; then
    local find_output="" sc fkey fpath
    if [ -d "$IMPL_DIR" ]; then
      find_output="$(_resolve_all_story_paths "$IMPL_DIR" "$keys_to_find")"
    fi
    ki=0
    while IFS=$'\t' read -r sc fkey fpath; do
      [ -n "$fkey" ] || continue
      # advance to this key's yaml slot (find output follows the same order)
      while [ "$ki" -lt "${#valid_keys[@]}" ] && [ "${valid_keys[$ki]}" != "$fkey" ]; do ki=$((ki + 1)); done
      case "$sc" in
        FOUND)   [ "$ki" -lt "${#valid_keys[@]}" ] && key_path[ki]="$fpath" ;;
        AMBIG)   _warn "multiple files match key $fkey, skipping"; miss_lines="${miss_lines}miss	${fkey}
" ;;
        *)       _warn "no file found for key $fkey"; miss_lines="${miss_lines}miss	${fkey}
" ;;
      esac
    done <<< "${find_output:-$(for key in $keys_to_find; do printf 'MISSING\t%s\n' "$key"; done)}"
  fi
  local -a cand_keys=() cand_paths=()
  for ki in "${!valid_keys[@]}"; do
    if [ -n "${key_path[$ki]}" ]; then cand_keys+=("${valid_keys[$ki]}"); cand_paths+=("${key_path[$ki]}"); fi
  done

  # --- Containment: resolve the full symlink chain, keep paths inside the root ---
  local -a ok_keys=() ok_abs=() ok_rel=()
  if [ "${#cand_keys[@]}" -gt 0 ]; then
    local -a exist_keys=() exist_paths=()
    local ci
    for ci in "${!cand_keys[@]}"; do
      if [ -e "${cand_paths[$ci]}" ]; then
        exist_keys+=("${cand_keys[$ci]}"); exist_paths+=("${cand_paths[$ci]}")
      else
        _warn "story file missing for ${cand_keys[$ci]}: ${cand_paths[$ci]}"
        miss_lines="${miss_lines}miss	${cand_keys[$ci]}
"
      fi
    done
    if [ "${#exist_keys[@]}" -gt 0 ]; then
      local resolved rp ri=0
      resolved="$(_realpath_batch "${exist_paths[@]}")" || resolved=""
      while IFS= read -r rp; do
        [ "$ri" -lt "${#exist_keys[@]}" ] || break
        case "$rp" in
          "${RESOLVED_ROOT}/"*)
            ok_keys+=("${exist_keys[$ri]}"); ok_abs+=("$rp"); ok_rel+=("${rp#"${RESOLVED_ROOT}"/}") ;;
          *)
            _warn "path escapes project root for ${exist_keys[$ri]}, skipping"
            miss_lines="${miss_lines}miss	${exist_keys[$ri]}
" ;;
        esac
        ri=$((ri + 1))
      done <<< "$resolved"
      while [ "$ri" -lt "${#exist_keys[@]}" ]; do
        _warn "path could not be resolved for ${exist_keys[$ri]}, skipping"
        miss_lines="${miss_lines}miss	${exist_keys[$ri]}
"
        ri=$((ri + 1))
      done
    fi
  fi

  # --- Meta files present / absent ---
  local -a stat_targets=()
  for mi in "${!meta_paths[@]}"; do
    if [ -e "${meta_paths[$mi]}" ]; then stat_targets+=("${meta_paths[$mi]}"); fi
  done
  if [ "${#ok_abs[@]}" -gt 0 ]; then stat_targets+=("${ok_abs[@]}"); fi

  # --- ONE batch stat for stories + meta files ---
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
  local -a ok_mts=() ok_rec=()
  local oi
  for oi in "${!ok_abs[@]}"; do ok_mts+=("${stat_out[$si]:-0}"); si=$((si + 1)); done
  # Recorded mtimes: the real value, or "racy" when it is not older than this
  # build (never matches on the next run, so the file is re-read).
  local -a meta_rec=()
  for mi in "${!meta_mts[@]}"; do
    if [ "${meta_mts[$mi]}" != "0" ] && [ "${meta_mts[$mi]}" -ge "$build_start" ]; then meta_rec+=("racy"); else meta_rec+=("${meta_mts[$mi]}"); fi
  done
  for oi in "${!ok_mts[@]}"; do
    if [ "${ok_mts[$oi]}" -ge "$build_start" ]; then ok_rec+=("racy"); else ok_rec+=("${ok_mts[$oi]}"); fi
  done

  # --- Story records (unchanged stories come from the parse cache) ---
  local want="" story_rec="" s_lines="" new_sidecar="v2
"
  for oi in "${!ok_keys[@]}"; do
    want="${want}${ok_keys[$oi]}${_US}${ok_rel[$oi]}${_US}${ok_rec[$oi]}${_US}${ok_abs[$oi]}
"
    s_lines="${s_lines}S${_US}${ok_keys[$oi]}${_US}${ok_rel[$oi]}${_US}${ok_mts[$oi]}
"
    new_sidecar="${new_sidecar}story	${ok_keys[$oi]}	${ok_rel[$oi]}	${ok_rec[$oi]}
"
  done
  if [ -n "$want" ]; then
    local parsed_src="/dev/null"
    if [ -f "$PARSED_FILE" ] && [ ! -L "$PARSED_FILE" ]; then parsed_src="$PARSED_FILE"; fi
    story_rec="$(SNAP_WANT="$want" _story_records "$parsed_src")" || story_rec=""
  fi

  # --- Ledger verdicts ---
  local ledger_rec=""
  if [ -f "$LEDGER_FILE" ] && [ "${#ok_keys[@]}" -gt 0 ]; then
    ledger_rec="$(SNAP_KEYS="${ok_keys[*]}" _ledger_records "$LEDGER_FILE")"
  fi

  # --- Config: aliases + threshold ---
  local cfg_rec cfg_out="" have_alias=0 thr_raw=""
  cfg_rec="$(_read_config_records "$CONFIG_FILE")"
  if [ -n "$cfg_rec" ]; then
    while IFS="$_US" read -r t1 t2; do
      case "$t1" in
        L) have_alias=1; cfg_out="${cfg_out}L${_US}${t2}
" ;;
        H) thr_raw="$t2" ;;
      esac
    done <<< "$cfg_rec"
  fi
  if [ "$have_alias" = "0" ]; then
    local gname
    gname="$(git config user.name 2>/dev/null || true)"
    gname="${gname//$_US/}"
    cfg_out="L${_US}user
L${_US}${gname}
"
  fi
  local thr; thr="$(_validate_threshold "$thr_raw")"

  # --- Action-items registry (canonical state file first, then the resolver) ---
  local ai_rec="" ai_path="" ai_mt=""
  if [ "${#ok_keys[@]}" -gt 0 ] || [ "$sprint_id_present" = "1" ]; then
    if [ -s "$ai_state" ]; then
      ai_path="$ai_state"
    elif [ -x "${_SELF_DIR}/lib/resolve-artifact-path.sh" ]; then
      ai_path="$("${_SELF_DIR}/lib/resolve-artifact-path.sh" action_items --project-root "$RESOLVED_ROOT" --existing-only 2>/dev/null)" || ai_path=""
    fi
    if [ -n "$ai_path" ] && [ -f "$ai_path" ]; then
      ai_rec="$(_action_item_records "$ai_path")"
      for mi in "${!meta_paths[@]}"; do
        if [ "${meta_paths[$mi]}" = "$ai_path" ]; then ai_mt="${meta_mts[$mi]}"; fi
      done
      [ -n "$ai_mt" ] || ai_mt="$(_stat_mtime "$ai_path" 2>/dev/null || printf '0')"
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
  mv -f "$cache_tmp" "$CACHE_FILE"

  # --- Parse cache + sidecar ---
  printf '%s\n' "$story_rec" | _write_atomic_from "$PARSED_FILE"
  for mi in "${!meta_names[@]}"; do
    new_sidecar="${new_sidecar}meta	${meta_names[$mi]}	${meta_rels[$mi]}	${meta_rec[$mi]}
"
  done
  printf '%s%s' "$new_sidecar" "$miss_lines" | _write_atomic_from "$SIDECAR_FILE"
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

  # Review-gate ledger: same precedence as review-gate.sh.
  if [ -n "${REVIEW_GATE_LEDGER:-}" ]; then
    LEDGER_FILE="$REVIEW_GATE_LEDGER"
  elif [ -d "${RESOLVED_ROOT}/.gaia" ]; then
    LEDGER_FILE="${STATE_DIR}/.review-gate-ledger"
  else
    LEDGER_FILE="${RESOLVED_ROOT}/.review-gate-ledger"
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
        _warn "lock held by another process, skipping"; exit 0
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
