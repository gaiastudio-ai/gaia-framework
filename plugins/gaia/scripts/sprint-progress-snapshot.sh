#!/usr/bin/env bash
# sprint-progress-snapshot.sh — sole writer of the sprint progress cache.
#
# Reads sprint-status.yaml, story files, the review-gate ledger, and the
# action-items registry, then writes a single JSON cache at
# .gaia/state/.sprint-progress-cache.json.  Four rendering surfaces
# (sidebar, band, status line, dashboard) consume the cache instead of
# parsing story files directly.
#
# Environment variable overrides (for testability):
#   PROJECT_ROOT          Project root directory (default: CLAUDE_PROJECT_ROOT or PWD)
#   SPRINT_STATUS_YAML    Path to sprint-status.yaml (default: .gaia/state/sprint-status.yaml)
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

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${_GAIA_PATHS_LOADED:-0}" != "1" ]; then
  # shellcheck source=lib/gaia-paths.sh
  . "${_SELF_DIR}/lib/gaia-paths.sh" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_CACHE_NAME=".sprint-progress-cache.json"
_SIDECAR_NAME=".sprint-progress-mtimes"
_LOCK_SUFFIX=".lock"
_ALLOWED_COMMANDS=("/gaia-test-manual" "/gaia-sprint-close" "/gaia-action-items")

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

# Detect date flavour: GNU uses `date -d`, BSD uses `date -r` for epoch
# and `date -jf` for parsing date strings.
if date -u -d @0 +%s >/dev/null 2>&1; then
  _SNAP_DATE_FMT="gnu"   # date -u -d @EPOCH / date -u -d YYYY-MM-DD
else
  _SNAP_DATE_FMT="bsd"   # date -u -r EPOCH / date -jf '%Y-%m-%d'
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

_date_to_epoch() {
  if [ "$_SNAP_DATE_FMT" = "gnu" ]; then
    date -u -d "$1" +%s 2>/dev/null || printf ''
  else
    date -jf '%Y-%m-%d' "$1" +%s 2>/dev/null || printf ''
  fi
}

# _epoch_to_date EPOCH — convert epoch seconds to YYYY-MM-DD
_epoch_to_date() {
  if [ "$_SNAP_DATE_FMT" = "gnu" ]; then
    date -u -d "@$1" +%Y-%m-%d 2>/dev/null || printf '1970-01-01'
  else
    date -u -r "$1" +%Y-%m-%d 2>/dev/null || printf '1970-01-01'
  fi
}

_mtime_to_date() { _epoch_to_date "$1"; }

# ---------------------------------------------------------------------------
# JSON escaping (pure bash, no subprocess)
# ---------------------------------------------------------------------------

_json_escape_var() {
  # Escape backslashes and double-quotes in $1, print result.
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

# _json_str_or_null VAL — prints "VAL" or null.
_json_str_or_null() {
  if [ -n "$1" ] && [ "$1" != "null" ]; then
    printf '"%s"' "$(_json_escape_var "$1")"
  else
    printf 'null'
  fi
}

# ---------------------------------------------------------------------------
# Input sanitization
# ---------------------------------------------------------------------------

# _sanitize_alias STR — strip control chars (NL/CR/TAB/ESC/etc.), cap to 100 chars
_sanitize_alias() {
  local v="$1"
  # Strip control characters (bytes 0x00-0x1F and 0x7F)
  v="$(printf '%s' "$v" | tr -d '[:cntrl:]')"
  [ "${#v}" -le 100 ] || v="${v:0:100}"
  printf '%s' "$v"
}

# _validate_threshold STR — return a valid non-negative integer, or 120 with a warning
_validate_threshold() {
  local v="$1"
  # Must be a plain non-negative integer (digits only, bounded length)
  if [ -n "$v" ] && [ "${#v}" -le 10 ] && [[ $v =~ ^[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    [ -z "$v" ] || _warn "invalid threshold value '${v:0:20}', using default 120"
    printf '120'
  fi
}

# ---------------------------------------------------------------------------
# Command allowlist
# ---------------------------------------------------------------------------

_validate_command() {
  local cmd="$1"
  if [ -z "$cmd" ]; then printf 'null'; return 0; fi
  local allowed
  for allowed in "${_ALLOWED_COMMANDS[@]}"; do
    if [ "$cmd" = "$allowed" ]; then printf '%s' "$cmd"; return 0; fi
  done
  printf 'null'
}

# ---------------------------------------------------------------------------
# Story-key validation
# ---------------------------------------------------------------------------

_valid_story_key() {
  [[ $1 =~ ^E[0-9]+\-S[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Single-flight non-blocking lock
# ---------------------------------------------------------------------------

_SNAPSHOT_LOCK_FD=9
_SNAPSHOT_LOCK_FILE=""
_SNAPSHOT_LOCK_BACKEND=""

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
  _SNAPSHOT_LOCK_FILE="$lock_file"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

  if ! _snapshot_lock_path_policy "$lock_file"; then return 1; fi

  if command -v flock >/dev/null 2>&1 && [ "${GAIA_LOCK_FORCE_FALLBACK:-}" != "1" ]; then
    _SNAPSHOT_LOCK_BACKEND="flock"
    eval "exec ${_SNAPSHOT_LOCK_FD}>>'${lock_file}'"
    if flock -n "$_SNAPSHOT_LOCK_FD" 2>/dev/null; then return 0; fi
    eval "exec ${_SNAPSHOT_LOCK_FD}>&-" 2>/dev/null || true
    return 1
  fi

  # Fallback: atomic ln, single attempt, stale-holder reap
  _SNAPSHOT_LOCK_BACKEND="fallback"
  local tmp_lock="${lock_file}.tmp.$$.${RANDOM}"
  printf '%s %s\n' "$$" "$(date +%s)" > "$tmp_lock" 2>/dev/null || {
    rm -f "$tmp_lock" 2>/dev/null || true; return 1
  }
  if ln "$tmp_lock" "$lock_file" 2>/dev/null; then
    rm -f "$tmp_lock" 2>/dev/null || true; return 0
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
        rm -f "$tmp2" 2>/dev/null || true; return 0
      fi
      rm -f "$tmp2" 2>/dev/null || true
    fi
  fi
  return 1
}

_release_snapshot_lock() {
  local lock_file="${_SNAPSHOT_LOCK_FILE:-}"
  [ -n "$lock_file" ] || return 0
  if [ "$_SNAPSHOT_LOCK_BACKEND" = "flock" ]; then
    flock -u "$_SNAPSHOT_LOCK_FD" 2>/dev/null || true
    eval "exec ${_SNAPSHOT_LOCK_FD}>&-" 2>/dev/null || true
  else
    local holder=""
    read -r holder _ < "$lock_file" 2>/dev/null || true
    [ "$holder" = "$$" ] && rm -f "$lock_file" 2>/dev/null || true
  fi
  _SNAPSHOT_LOCK_FILE=""
}

# ---------------------------------------------------------------------------
# Sprint-status.yaml reader (awk-based, fast)
# ---------------------------------------------------------------------------

_read_sprint_yaml() {
  local yaml_file="$1"
  [ -f "$yaml_file" ] || { printf 'ABSENT'; return 0; }
  awk '
  BEGIN { in_stories=0; in_goals=0; si=0; gi=0; ck="" }
  /^sprint_id:/ { val=$0; sub(/^sprint_id:[[:space:]]*/, "", val); gsub(/"/, "", val); print "SPRINT_ID=" val; next }
  /^status:/ && !in_stories { val=$0; sub(/^status:[[:space:]]*/, "", val); gsub(/"/, "", val); print "SPRINT_STATUS=" val; next }
  /^start_date:/ { val=$0; sub(/^start_date:[[:space:]]*/, "", val); gsub(/"/, "", val); print "START_DATE=" val; next }
  /^end_date:/ { val=$0; sub(/^end_date:[[:space:]]*/, "", val); gsub(/"/, "", val); print "END_DATE=" val; next }
  /^capacity_utilization:/ { val=$0; sub(/^capacity_utilization:[[:space:]]*/, "", val); gsub(/"/, "", val); print "CAPACITY_UTILIZATION=" val; next }
  /^epic_focus:/ { val=$0; sub(/^epic_focus:[[:space:]]*/, "", val); gsub(/"/, "", val); print "EPIC_FOCUS=" val; next }
  /^goals:/ { in_goals=1; in_stories=0; rest=$0; sub(/^goals:[[:space:]]*/, "", rest); if (rest ~ /^\[\]/) in_goals=0; next }
  in_goals && /^[[:space:]]+-/ { gsub(/^[[:space:]]+-[[:space:]]*"?|"?[[:space:]]*$/, ""); if (gi==0) print "GOAL=" $0; gi++; next }
  in_goals && /^[^[:space:]]/ { in_goals=0 }
  /^stories:/ { in_stories=1; in_goals=0; next }
  in_stories && /^[^[:space:]]/ && !/^stories:/ { in_stories=0; next }
  in_stories && /^[[:space:]]+-[[:space:]]+key:/ { si++; val=$0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", val); gsub(/"/, "", val); ck=val; print "STORY_KEY_" si "=" val; next }
  in_stories && ck != "" {
    if (/^[[:space:]]+status:/)     { val=$0; sub(/^[[:space:]]+status:[[:space:]]*/, "", val); gsub(/"/, "", val); print "STORY_YAML_STATUS_" si "=" val; next }
    if (/^[[:space:]]+points:/)     { val=$0; sub(/^[[:space:]]+points:[[:space:]]*/, "", val); gsub(/"/, "", val); print "STORY_POINTS_" si "=" val; next }
    if (/^[[:space:]]+risk_level:/) { val=$0; sub(/^[[:space:]]+risk_level:[[:space:]]*/, "", val); gsub(/"/, "", val); print "STORY_RISK_" si "=" val; next }
    if (/^[[:space:]]+blocked_by:/) { val=$0; sub(/^[[:space:]]+blocked_by:[[:space:]]*/, "", val); gsub(/"/, "", val); if (val=="null"||val==""||val=="~") val="null"; print "STORY_BLOCKED_BY_" si "=" val; next }
    if (/^[[:space:]]+phase:/)      { val=$0; sub(/^[[:space:]]+phase:[[:space:]]*/, "", val); gsub(/"/, "", val); print "STORY_PHASE_" si "=" val; next }
  }
  END { print "STORY_COUNT=" si }
  ' "$yaml_file"
}

# ---------------------------------------------------------------------------
# Batched story-file resolution — ONE find over implementation-artifacts
# ---------------------------------------------------------------------------

_resolve_all_story_paths() {
  local impl_dir="$1"; shift
  find "$impl_dir" -type f \( -name 'story.md' -o -name 'E*.md' \) 2>/dev/null | awk -v keys="$*" '
  BEGIN { n=split(keys,ka," "); for(i=1;i<=n;i++) wanted[ka[i]]=1 }
  {
    path=$0; fname=path; sub(/.*\//,"",fname)
    parent=path; sub(/\/[^\/]*$/,"",parent); pname=parent; sub(/.*\//,"",pname)
    if (fname=="story.md") {
      for(k in wanted) { kp=k"-"; if(substr(pname,1,length(kp))==kp||pname==k) { t=1; if(!(k in bt)||t<bt[k]){bt[k]=t;bp[k]=path;delete am[k]}else if(t==bt[k]&&path!=bp[k])am[k]=1 } }
    }
    if (pname=="stories") {
      for(k in wanted) { kp=k"-"; if(substr(fname,1,length(kp))==kp) { t=2; if(!(k in bt)||t<bt[k]){bt[k]=t;bp[k]=path;delete am[k]}else if(t==bt[k]&&path!=bp[k])am[k]=1 } }
    }
    if (fname!="story.md"&&pname!="stories") {
      for(k in wanted) { kp=k"-"; kex=k".md"; if(substr(fname,1,length(kp))==kp||fname==kex) { t=3; if(!(k in bt)||t<bt[k]){bt[k]=t;bp[k]=path;delete am[k]}else if(t==bt[k]&&path!=bp[k])am[k]=1 } }
    }
  }
  END { for(k in wanted) { if(k in am) print "AMBIG\t"k; else if(k in bp) print "FOUND\t"k"\t"bp[k]; else print "MISSING\t"k } }
  '
}

# ---------------------------------------------------------------------------
# Config readers (awk-based for speed)
# ---------------------------------------------------------------------------

_read_user_aliases() {
  local config_file="$1"
  if [ -f "$config_file" ]; then
    local aliases
    aliases="$(awk '
      /^sprint_status_mod:/ { in_mod=1; next }
      in_mod && /^[^[:space:]]/ { in_mod=0 }
      in_mod && /user_aliases:/ { in_aliases=1; next }
      in_aliases && /^[[:space:]]+- / { val=$0; sub(/^[[:space:]]+-[[:space:]]*/, "", val); gsub(/["'\'']/, "", val); print val; next }
      in_aliases && /^[[:space:]]/ && !/^[[:space:]]+- / { in_aliases=0 }
    ' "$config_file" 2>/dev/null)" || aliases=""
    if [ -n "$aliases" ]; then printf '%s\n' "$aliases"; return 0; fi
  fi
  printf 'user\n'
  git config user.name 2>/dev/null || true
}

_read_threshold() {
  local config_file="$1"
  if [ -f "$config_file" ]; then
    local val
    val="$(awk '
      /^sprint_status_mod:/ { in_mod=1; next }
      in_mod && /^[^[:space:]]/ { in_mod=0 }
      in_mod && /waiting_agent_threshold_seconds:/ { sub(/.*waiting_agent_threshold_seconds:[[:space:]]*/, ""); gsub(/"/, ""); if ($0!=""&&$0!="null") print $0 }
    ' "$config_file" 2>/dev/null)" || val=""
    if [ -n "$val" ]; then
      _validate_threshold "$val"
      return 0
    fi
  fi
  printf '120'
}

_read_action_items() {
  local registry="$1"
  [ -f "$registry" ] || return 0
  yq -r '(.items // [])[] | [.id // "", .status // "", .assignee // "", .created_at // .created // ""] | @tsv' "$registry" 2>/dev/null || {
    _warn "action-items registry is unparseable, skipping rule-c"
    return 0
  }
}

# ---------------------------------------------------------------------------
# Sidecar I/O
# ---------------------------------------------------------------------------

_read_sidecar() { [ -f "$1" ] && cat "$1" || true; }

_write_atomic() {
  local target="$1" content="$2"
  local tmp; tmp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

# ---------------------------------------------------------------------------
# Empty-cache template — used when sprint-status.yaml is absent or has no id
# ---------------------------------------------------------------------------

_write_empty_cache() {
  local cache_file="$1" sidecar_file="$2" gen_at="$3" aliases_json="$4" threshold="$5"
  _write_atomic "$cache_file" \
    "{\"schema_version\":\"1.0\",\"generated_at\":\"${gen_at}\",\"sprint\":null,\"totals\":{\"done_points\":0,\"total_points\":0,\"done_stories\":0,\"total_stories\":0,\"progress_pct\":0},\"by_status\":{},\"day\":{\"current\":0,\"total\":null,\"pace\":null},\"active_phase\":null,\"phases\":[],\"unphased_stories\":[],\"stories\":[],\"action_needed\":[],\"drift\":[],\"readiness\":{\"sprint_review\":false,\"sprint_close\":false},\"user_aliases\":${aliases_json},\"waiting_agent_threshold_seconds\":${threshold}}"
  _write_atomic "$sidecar_file" ""
}

# ---------------------------------------------------------------------------
# Delimited-field to JSON-array builder
# Items are separated by ";;;" and each item is "key:::value".
# ---------------------------------------------------------------------------

_delimited_to_json_array() {
  local data="$1" key_label="$2" val_label="$3"
  local result="[" first=1
  if [ -n "$data" ]; then
    local IFS_SAVE="$IFS"
    IFS=";;;"
    # shellcheck disable=SC2086
    set -- $data
    IFS="$IFS_SAVE"
    while [ $# -gt 0 ]; do
      local part="$1"; shift
      [ -n "$part" ] || continue
      local k="${part%%:::*}" v="${part#*:::}"
      [ "$first" = "1" ] || result="${result},"
      result="${result}{\"${key_label}\":\"${v}\",\"${val_label}\":${k}}"
      first=0
    done
  fi
  printf '%s]' "$result"
}

_gate_rows_to_json() {
  local data="$1"
  local result="[" first=1
  if [ -n "$data" ]; then
    local IFS_SAVE="$IFS"
    IFS=";;;"
    # shellcheck disable=SC2086
    set -- $data
    IFS="$IFS_SAVE"
    while [ $# -gt 0 ]; do
      local part="$1"; shift
      [ -n "$part" ] || continue
      local gname="${part%%:::*}" gstatus="${part#*:::}"
      [ "$first" = "1" ] || result="${result},"
      result="${result}{\"name\":\"${gname}\",\"status\":\"${gstatus}\"}"
      first=0
    done
  fi
  printf '%s]' "$result"
}

# ---------------------------------------------------------------------------
# Compute day/pace from sprint dates
# ---------------------------------------------------------------------------

_compute_day_pace() {
  local start_date="$1" end_date="$2" done_pts="$3" total_pts="$4"
  local day_current=0 day_total="null" day_pace="null"
  local today_str
  today_str="$(date -u +%Y-%m-%d)"

  if [ -n "$start_date" ] && [ "$start_date" != "null" ]; then
    local se te
    se="$(_date_to_epoch "$start_date")" || se=""
    te="$(_date_to_epoch "$today_str")" || te=""
    if [ -n "$se" ] && [ -n "$te" ]; then
      day_current=$(( (te - se) / 86400 ))
      [ "$day_current" -ge 0 ] || day_current=0
    fi
  fi

  if [ -n "$start_date" ] && [ "$start_date" != "null" ] \
     && [ -n "$end_date" ] && [ "$end_date" != "null" ]; then
    local se2 ee
    se2="$(_date_to_epoch "$start_date")" || se2=""
    ee="$(_date_to_epoch "$end_date")" || ee=""
    if [ -n "$se2" ] && [ -n "$ee" ]; then
      day_total="$(( (ee - se2) / 86400 ))"
    fi
  fi

  if [ "$day_total" != "null" ] && [ -n "$day_total" ]; then
    if [ "$day_current" = "0" ]; then
      day_pace="starting"
    elif [ -n "$end_date" ] && [ "$end_date" != "null" ]; then
      local ee2 te2
      ee2="$(_date_to_epoch "$end_date")" || ee2=""
      te2="$(_date_to_epoch "$today_str")" || te2=""
      if [ -n "$ee2" ] && [ -n "$te2" ] && [ "$te2" -gt "$ee2" ]; then
        day_pace="overdue"
      elif [ "$day_total" -gt 0 ] && [ "$day_current" -gt 0 ]; then
        if [ $((done_pts * day_total)) -ge $((total_pts * day_current)) ]; then
          day_pace="on-pace"
        else
          day_pace="behind-pace"
        fi
      else
        day_pace="on-pace"
      fi
    fi
  fi

  printf '%d\t%s\t%s' "$day_current" "$day_total" "$day_pace"
}

# ---------------------------------------------------------------------------
# Build phases JSON from collected phase data
# ---------------------------------------------------------------------------

_build_phases_json() {
  local phase_data="$1"
  local phases_json="" active_phase="null"

  [ -n "$phase_data" ] || { printf '\t%s' "$active_phase"; return 0; }

  local sorted_nums
  sorted_nums="$(printf '%s\n' "$phase_data" | cut -f1 | sort -n | uniq)"

  # First pass: find active_phase (lowest phase with a non-done story)
  while IFS= read -r pn; do
    [ -n "$pn" ] || continue
    local has_non_done=0
    while IFS=$'\t' read -r ppn pk pst; do
      [ "$ppn" = "$pn" ] || continue
      [ "$pst" = "done" ] || has_non_done=1
    done <<< "$phase_data"
    if [ "$has_non_done" = "1" ] && [ "$active_phase" = "null" ]; then
      active_phase="$pn"
    fi
  done <<< "$sorted_nums"

  # Second pass: build JSON with correct statuses
  while IFS= read -r pn; do
    [ -n "$pn" ] || continue
    local p_skeys="" p_dc=0 p_tc=0
    while IFS=$'\t' read -r ppn pk pst; do
      [ "$ppn" = "$pn" ] || continue
      p_skeys="${p_skeys:+${p_skeys},}\"${pk}\""
      p_tc=$((p_tc + 1))
      [ "$pst" != "done" ] || p_dc=$((p_dc + 1))
    done <<< "$phase_data"

    local pstatus="future"
    if [ "$active_phase" = "null" ] || [ "$pn" -lt "$active_phase" ]; then
      pstatus="done"
    elif [ "$pn" = "$active_phase" ]; then
      pstatus="active"
    fi

    phases_json="${phases_json:+${phases_json},}{\"phase\":${pn},\"status\":\"${pstatus}\",\"stories\":[${p_skeys}],\"done_count\":${p_dc},\"total_count\":${p_tc}}"
  done <<< "$sorted_nums"

  printf '%s\t%s' "$phases_json" "$active_phase"
}

# ---------------------------------------------------------------------------
# Warm fast-path: update only time-derived fields in the existing cache
# ---------------------------------------------------------------------------

_try_warm_fast_path() {
  local cache_file="$1" sidecar="$2"
  [ -f "$cache_file" ] && [ -n "$sidecar" ] || return 1

  # Collect sidecar paths and expected mtimes
  local -a paths_arr=() mt_expected=()
  while IFS=$'\t' read -r _ _ wpath wmt; do
    [ -n "$wpath" ] || continue
    paths_arr+=("$wpath")
    mt_expected+=("$wmt")
  done <<< "$sidecar"

  [ "${#paths_arr[@]}" -gt 0 ] || return 1

  # ONE batch stat
  local actual
  actual="$(_stat_mtime_batch "${paths_arr[@]}")" || return 1
  local wi=0
  while IFS= read -r act_mt; do
    [ "$act_mt" = "${mt_expected[$wi]}" ] || return 1
    wi=$((wi + 1))
  done <<< "$actual"

  # Nothing changed -- update time-derived fields with ONE date + ONE jq call
  local date_out
  date_out="$(date -u '+%Y-%m-%dT%H:%M:%SZ %Y-%m-%d %s')"
  local gen_at="${date_out%% *}"
  local rest="${date_out#* }"
  local today_str="${rest%% *}"
  local now_ep="${rest##* }"

  # Build a map of story key -> mtime from the sidecar (pure bash, no subprocess)
  local story_mtimes_json="{"
  local _smf=1
  while IFS=$'\t' read -r _sty _sk2 _sp2 _sm2; do
    [ "$_sty" = "story" ] && [ -n "$_sk2" ] && [ -n "$_sm2" ] || continue
    [ "$_smf" = "1" ] || story_mtimes_json="${story_mtimes_json},"
    story_mtimes_json="${story_mtimes_json}\"${_sk2}\":${_sm2}"
    _smf=0
  done <<< "$sidecar"
  story_mtimes_json="${story_mtimes_json}}"

  local warm_cache
  warm_cache="$(jq \
    --arg gen "$gen_at" \
    --arg today "$today_str" \
    --argjson now_ep "$now_ep" \
    --argjson smtimes "$story_mtimes_json" \
    '
    .generated_at = $gen |
    (if .sprint != null and .sprint.start_date != null and .sprint.start_date != "" then
      (($today | strptime("%Y-%m-%d") | mktime) - (.sprint.start_date | strptime("%Y-%m-%d") | mktime)) / 86400 | floor
    else 0 end) as $cur |
    .day.current = $cur |
    (if .day.total != null then
      if $cur == 0 then "starting"
      elif .sprint.end_date != null and .sprint.end_date != "" then
        if (($today | strptime("%Y-%m-%d") | mktime) > (.sprint.end_date | strptime("%Y-%m-%d") | mktime)) then "overdue"
        elif .day.total > 0 and $cur > 0 then
          if (.totals.done_points * .day.total) >= (.totals.total_points * $cur) then "on-pace"
          else "behind-pace" end
        else "on-pace" end
      else "on-pace" end
    else null end) as $pace |
    .day.pace = $pace |
    # Recompute stale_review drift from story mtimes and current time
    .drift = [.drift[] | select(.type != "stale_review")] +
      [.stories[] | select(.status == "review") |
       .key as $k |
       if ($smtimes[$k] // 0) > 0 and ($now_ep - ($smtimes[$k] // 0)) > 172800 then
         {story_key: $k, type: "stale_review", detail: "Story in review for over 48 hours"}
       else empty end]
    ' "$cache_file" 2>/dev/null)" || return 1

  [ -n "$warm_cache" ] || return 1
  _write_atomic "$cache_file" "$warm_cache"
  return 0
}

# ---------------------------------------------------------------------------
# Append a meta entry to the sidecar string
# ---------------------------------------------------------------------------

_sidecar_append_meta() {
  local entries="$1" sentinel="$2" filepath="$3"
  [ -f "$filepath" ] || { printf '%s' "$entries"; return 0; }
  local mt; mt="$(_stat_mtime "$filepath")"
  if [ -n "$entries" ]; then
    printf '%s\nmeta\t%s\t%s\t%s' "$entries" "$sentinel" "$filepath" "$mt"
  else
    printf 'meta\t%s\t%s\t%s' "$sentinel" "$filepath" "$mt"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_snapshot_main() {
  local RESOLVED_ROOT
  RESOLVED_ROOT="$(cd "${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-$PWD}}" 2>/dev/null && pwd -P)"

  local STATE_DIR="${RESOLVED_ROOT}/.gaia/state"
  local CACHE_FILE="${STATE_DIR}/${_CACHE_NAME}"
  local SIDECAR_FILE="${STATE_DIR}/${_SIDECAR_NAME}"
  local LOCK_FILE="${CACHE_FILE}${_LOCK_SUFFIX}"
  local CONFIG_FILE="${RESOLVED_ROOT}/.gaia/config/project-config.yaml"
  local IMPL_DIR="${RESOLVED_ROOT}/.gaia/artifacts/implementation-artifacts"

  mkdir -p "$STATE_DIR" 2>/dev/null || true

  # --- Lock ---
  if ! _try_snapshot_lock "$LOCK_FILE"; then
    _warn "lock held by another process, skipping"; exit 0
  fi
  trap '_release_snapshot_lock' EXIT INT TERM

  # --- Paths ---
  local YAML_FILE="${SPRINT_STATUS_YAML:-${STATE_DIR}/sprint-status.yaml}"
  local ledger_path="${STATE_DIR}/.review-gate-ledger"
  local action_items_path=""
  if [ -s "${STATE_DIR}/action-items.yaml" ]; then
    action_items_path="${STATE_DIR}/action-items.yaml"
  elif [ -x "${_SELF_DIR}/lib/resolve-artifact-path.sh" ]; then
    action_items_path="$(
      "${_SELF_DIR}/lib/resolve-artifact-path.sh" action_items --project-root "$RESOLVED_ROOT" --existing-only 2>/dev/null
    )" || action_items_path=""
  fi

  # --- Sidecar + warm fast-path ---
  local old_sidecar=""
  old_sidecar="$(_read_sidecar "$SIDECAR_FILE")"

  if _try_warm_fast_path "$CACHE_FILE" "$old_sidecar"; then
    exit 0
  fi

  # =========================================================================
  # Cold path: full rebuild
  # =========================================================================

  # --- Config ---
  local alias_list threshold
  alias_list="$(_read_user_aliases "$CONFIG_FILE")"
  threshold="$(_read_threshold "$CONFIG_FILE")"

  # Sanitize aliases: strip control chars, cap per-alias length and count
  local aliases_json_str="" alias_count=0
  local -a user_aliases_lower=()
  while IFS= read -r aline; do
    [ -n "$aline" ] || continue
    [ "$alias_count" -lt 20 ] || break
    local clean; clean="$(_sanitize_alias "$aline")"
    [ -n "$clean" ] || continue
    alias_count=$((alias_count + 1))
    local ea="${clean//\\/\\\\}"; ea="${ea//\"/\\\"}"
    aliases_json_str="${aliases_json_str:+${aliases_json_str},}\"${ea}\""
    user_aliases_lower+=("$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]')")
  done <<< "$alias_list"
  local aliases_json="[${aliases_json_str}]"

  # --- Sprint YAML ---
  local yaml_output
  yaml_output="$(_read_sprint_yaml "$YAML_FILE")"

  if [ "$yaml_output" = "ABSENT" ]; then
    _write_empty_cache "$CACHE_FILE" "$SIDECAR_FILE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$aliases_json" "${threshold:-120}"
    exit 0
  fi

  local SPRINT_ID="" SPRINT_STATUS="" START_DATE="" END_DATE="" GOAL="" CAPACITY_UTIL="" EPIC_FOCUS=""
  local STORY_COUNT=0
  local -a S_KEYS=() S_YAML_ST=() S_PTS=() S_RISKS=() S_BLOCKED=() S_PHASES=()

  # shellcheck disable=SC2034
  while IFS= read -r line; do
    case "$line" in
      SPRINT_ID=*)          SPRINT_ID="${line#SPRINT_ID=}" ;;
      SPRINT_STATUS=*)      SPRINT_STATUS="${line#SPRINT_STATUS=}" ;;
      START_DATE=*)         START_DATE="${line#START_DATE=}" ;;
      END_DATE=*)           END_DATE="${line#END_DATE=}" ;;
      GOAL=*)               GOAL="${line#GOAL=}" ;;
      CAPACITY_UTILIZATION=*) CAPACITY_UTIL="${line#CAPACITY_UTILIZATION=}" ;;
      EPIC_FOCUS=*)         EPIC_FOCUS="${line#EPIC_FOCUS=}" ;;
      STORY_COUNT=*)        STORY_COUNT="${line#STORY_COUNT=}" ;;
      STORY_KEY_*)          local idx="${line%%=*}"; idx="${idx#STORY_KEY_}";          S_KEYS[idx]="${line#*=}" ;;
      STORY_YAML_STATUS_*)  local idx="${line%%=*}"; idx="${idx#STORY_YAML_STATUS_}";  S_YAML_ST[idx]="${line#*=}" ;;
      STORY_POINTS_*)       local idx="${line%%=*}"; idx="${idx#STORY_POINTS_}";       S_PTS[idx]="${line#*=}" ;;
      STORY_RISK_*)         local idx="${line%%=*}"; idx="${idx#STORY_RISK_}";         S_RISKS[idx]="${line#*=}" ;;
      STORY_BLOCKED_BY_*)   local idx="${line%%=*}"; idx="${idx#STORY_BLOCKED_BY_}";   S_BLOCKED[idx]="${line#*=}" ;;
      STORY_PHASE_*)        local idx="${line%%=*}"; idx="${idx#STORY_PHASE_}";        S_PHASES[idx]="${line#*=}" ;;
    esac
  done <<< "$yaml_output"

  if [ -z "$SPRINT_ID" ]; then
    _write_empty_cache "$CACHE_FILE" "$SIDECAR_FILE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$aliases_json" "${threshold:-120}"
    exit 0
  fi

  # --- Validate keys ---
  local -a valid_keys=()
  local i
  for i in $(seq 1 "$STORY_COUNT"); do
    local key="${S_KEYS[$i]:-}"
    [ -n "$key" ] || continue
    _valid_story_key "$key" || { _warn "skipping invalid story key: $key"; continue; }
    valid_keys+=("$key")
  done

  # --- Resolve story paths (sidecar cache + batched find) ---
  local yaml_changed=0
  if [ -f "$YAML_FILE" ]; then
    local yaml_mt; yaml_mt="$(_stat_mtime "$YAML_FILE")"
    local old_yaml_mt=""
    [ -z "$old_sidecar" ] || old_yaml_mt="$(printf '%s' "$old_sidecar" | awk -F'\t' '$2=="__sprint_status__"{print $4;exit}')"
    [ -n "$old_yaml_mt" ] && [ "$yaml_mt" = "$old_yaml_mt" ] || yaml_changed=1
  else
    yaml_changed=1
  fi

  local -a story_paths=()
  local need_find=0 keys_to_find_str=""

  if [ "${#valid_keys[@]}" -gt 0 ]; then
    for key in "${valid_keys[@]}"; do
      local cached_path=""
      [ -z "$old_sidecar" ] || cached_path="$(printf '%s' "$old_sidecar" | awk -F'\t' -v k="$key" '$1=="story"&&$2==k{print $3;exit}')"
      if [ -n "$cached_path" ] && [ -f "$cached_path" ] && [ "$yaml_changed" = "0" ]; then
        story_paths+=("$key	$cached_path")
      else
        need_find=1
        keys_to_find_str="${keys_to_find_str:+${keys_to_find_str} }${key}"
      fi
    done
  fi

  if [ "$need_find" = "1" ] && [ -d "$IMPL_DIR" ] && [ -n "$keys_to_find_str" ]; then
    local find_output
    # shellcheck disable=SC2086
    find_output="$(_resolve_all_story_paths "$IMPL_DIR" $keys_to_find_str)"
    while IFS=$'\t' read -r sc fkey fpath; do
      sc="$(printf '%s' "$sc" | tr -d ' ')"
      fkey="$(printf '%s' "$fkey" | tr -d ' ')"
      case "$sc" in
        FOUND)   story_paths+=("$fkey	$fpath") ;;
        AMBIG)   _warn "multiple files match key $fkey, skipping" ;;
        MISSING) _warn "no file found for key $fkey" ;;
      esac
    done <<< "$find_output"
  fi

  # --- Containment check ---
  # Reject any path (including file-level symlinks) whose real target is outside
  # the project root. Guard realpath with [ -e ] for BSD compatibility.
  local -a checked_paths=()
  if [ "${#story_paths[@]}" -gt 0 ]; then
    for entry in "${story_paths[@]}"; do
      local ck="${entry%%	*}" cp="${entry#*	}"
      [ -e "$cp" ] || { _warn "story file missing for $ck: $cp"; continue; }
      # Reject file-level symlinks pointing outside the project root
      if [ -L "$cp" ]; then
        local link_target
        link_target="$(readlink "$cp" 2>/dev/null)" || link_target=""
        # Resolve relative symlink targets against the parent dir
        if [ -n "$link_target" ]; then
          case "$link_target" in
            /*) ;; # absolute
            *)  link_target="$(cd "$(dirname "$cp")" && pwd -P)/${link_target}" ;;
          esac
          # Resolve the target fully
          if [ -e "$link_target" ]; then
            link_target="$(cd "$(dirname "$link_target")" && pwd -P)/$(basename "$link_target")"
          fi
          case "$link_target" in
            "${RESOLVED_ROOT}/"*) ;;
            *) _warn "symlink escapes project root for $ck, skipping"; continue ;;
          esac
        fi
      fi
      local resolved
      resolved="$(cd "$(dirname "$cp")" && pwd -P)/$(basename "$cp")"
      case "$resolved" in
        "${RESOLVED_ROOT}/"*) checked_paths+=("$ck	$cp") ;;
        *) _warn "path escapes project root for $ck, skipping" ;;
      esac
    done
  fi

  # --- Batch stat + batch parse ---
  local -a ck_arr=() cp_arr=() mt_arr=()
  if [ "${#checked_paths[@]}" -gt 0 ]; then
    local -a stat_files=()
    for entry in "${checked_paths[@]}"; do
      ck_arr+=("${entry%%	*}")
      cp_arr+=("${entry#*	}")
      stat_files+=("${entry#*	}")
    done
    local all_mts
    all_mts="$(_stat_mtime_batch "${stat_files[@]}")" || all_mts=""
    while IFS= read -r mt; do mt_arr+=("$mt"); done <<< "$all_mts"
  fi

  local all_parsed=""
  if [ "${#cp_arr[@]}" -gt 0 ]; then
    all_parsed="$(awk '
    BEGIN { in_fm=0;fm_done=0;in_tasks=0;in_gate=0;gsep=0;key="";st="";pts=0;ttl="";mav="false";td=0;tt=0;gp=0;gt=0;ti="";gr="";fc=0 }
    FILENAME!=pf { if(fc>0){if(gt==0)gt=6;gsub(/\\/,"\\\\",ttl);gsub(/"/,"\\\"",ttl);gsub(/\t/," ",ttl);if(length(ttl)>200)ttl=substr(ttl,1,200);printf"%s\t%s\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\n",key,st,pts,ttl,mav,td,tt,gp,gt,ti,gr}; pf=FILENAME;fc++;in_fm=0;fm_done=0;in_tasks=0;in_gate=0;gsep=0;key="";st="";pts=0;ttl="";mav="false";td=0;tt=0;gp=0;gt=0;ti="";gr="" }
    /^---$/&&!fm_done{if(in_fm){fm_done=1;in_fm=0}else in_fm=1;next}
    in_fm&&/^status:/{v=$0;sub(/^status:[[:space:]]*/,"",v);gsub(/"/,"",v);st=v;next}
    in_fm&&/^points:/{v=$0;sub(/^points:[[:space:]]*/,"",v);gsub(/"/,"",v);pts=v+0;next}
    in_fm&&/^title:/{v=$0;sub(/^title:[[:space:]]*/,"",v);gsub(/^"/,"",v);gsub(/"[[:space:]]*$/,"",v);gsub(/^'\''/,"",v);gsub(/'\''[[:space:]]*$/,"",v);ttl=v;next}
    in_fm&&/^manual_verification:/{v=$0;sub(/^manual_verification:[[:space:]]*/,"",v);gsub(/"/,"",v);mav=v;next}
    in_fm&&/^key:/{v=$0;sub(/^key:[[:space:]]*/,"",v);gsub(/"/,"",v);key=v;next}
    /^## Tasks \/ Subtasks/{in_tasks=1;in_gate=0;next}
    /^## /&&in_tasks{in_tasks=0}
    in_tasks&&/^- \[/{tt++;dm=substr($0,4,1);if(dm=="x"||dm=="X"){td++;tid="true"}else tid="false";tx=$0;sub(/^- \[.\][[:space:]]*/,"",tx);gsub(/\\/,"\\\\",tx);gsub(/"/,"\\\"",tx);gsub(/\t/," ",tx);if(length(tx)>200)tx=substr(tx,1,200);if(ti!="")ti=ti";;;";ti=ti tid":::"tx;next}
    /^## Review Gate/{in_gate=1;in_tasks=0;gsep=0;next}
    /^## /&&in_gate{in_gate=0}
    in_gate&&/^\|.*\|.*\|/{if($0~/Review.*Status.*Report/)next;if($0~/^[[:space:]]*\|[-]+/){gsep=1;next};if(!gsep)next;l=$0;gsub(/^[[:space:]]*\|[[:space:]]*/,"",l);n=split(l,c,/[[:space:]]*\|[[:space:]]*/);if(n>=2){gn=c[1];gs=c[2];gsub(/^[[:space:]]+|[[:space:]]+$/,"",gn);gsub(/^[[:space:]]+|[[:space:]]+$/,"",gs);if(gs=="NOT STARTED")gs="UNVERIFIED";gt++;if(gs=="PASSED")gp++;if(gr!="")gr=gr";;;";gr=gr gn":::"gs}}
    END{if(gt==0)gt=6;gsub(/\\/,"\\\\",ttl);gsub(/"/,"\\\"",ttl);gsub(/\t/," ",ttl);if(length(ttl)>200)ttl=substr(ttl,1,200);printf"%s\t%s\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\n",key,st,pts,ttl,mav,td,tt,gp,gt,ti,gr}
    ' "${cp_arr[@]}")" || all_parsed=""
  fi

  # Batch ledger verdicts
  local all_verdicts=""
  if [ -f "$ledger_path" ] && [ "${#ck_arr[@]}" -gt 0 ]; then
    local keys_str; keys_str="$(printf '%s\n' "${ck_arr[@]}")"
    all_verdicts="$(awk -F'\t' -v keys="$keys_str" '
      BEGIN{n=split(keys,ka,"\n");for(i=1;i<=n;i++)w[ka[i]]=1}
      $1 in w&&$2=="manual-test"{last[$1]=$4}
      END{for(k in last)print k"\t"last[k]}
    ' "$ledger_path")" || all_verdicts=""
  fi

  # Pre-build key-to-yaml-index map and mtime-to-date map
  local key_idx_map=""
  for yi in $(seq 1 "$STORY_COUNT"); do
    key_idx_map="${key_idx_map}${S_KEYS[$yi]:-}	${yi}
"
  done

  local mt_date_map=""
  if [ "${#mt_arr[@]}" -gt 0 ]; then
    local unique_mts; unique_mts="$(printf '%s\n' "${mt_arr[@]}" | sort -u)"
    mt_date_map="$(printf '%s\n' "$unique_mts" | while IFS= read -r emt; do
      [ -n "$emt" ] || continue
      printf '%s\t%s\n' "$emt" "$(_mtime_to_date "$emt")"
    done)"
  fi

  # Fast epoch-to-date lookup (no subprocess)
  _mt_date_fast() {
    local line="${mt_date_map#*"$1"	}"
    if [ "$line" != "$mt_date_map" ]; then
      printf '%s' "${line%%
*}"
    else
      printf '1970-01-01'
    fi
  }

  # --- Process stories ---
  local stories_jsonl="" new_sidecar="" by_status_data="" phase_data="" unphased=""
  local done_points=0 total_points=0 done_stories=0 total_stories=0
  local all_done=1 all_done_or_review=1 has_stories=0 latest_done_mt=0
  local action_lines="" drift_lines=""
  local now_epoch; now_epoch="$(date +%s)"

  if [ "${#ck_arr[@]}" -gt 0 ]; then
    local -a parsed_lines=()
    [ -z "$all_parsed" ] || while IFS= read -r pl; do parsed_lines+=("$pl"); done <<< "$all_parsed"

    local si
    for si in $(seq 0 $((${#ck_arr[@]} - 1))); do
      local ck="${ck_arr[$si]}" cp="${cp_arr[$si]}" fmt="${mt_arr[$si]:-0}"
      has_stories=1; total_stories=$((total_stories + 1))
      new_sidecar="${new_sidecar:+${new_sidecar}
}story	${ck}	${cp}	${fmt}"

      # Yaml data via index map (no subprocess)
      local yidx=""
      local il="${key_idx_map#*"${ck}"	}"
      [ "$il" = "$key_idx_map" ] || yidx="${il%%
*}"
      local s_phase="${S_PHASES[${yidx:-0}]:-}" s_risk="${S_RISKS[${yidx:-0}]:-medium}"
      local s_blocked="${S_BLOCKED[${yidx:-0}]:-null}" s_yaml_st="${S_YAML_ST[${yidx:-0}]:-}"

      local parsed="${parsed_lines[$si]:-}"
      [ -n "$parsed" ] || { _warn "failed to parse $ck"; continue; }
      local p_key="" p_st="" p_pts="" p_ttl="" p_mv="" p_td="" p_tt="" p_gp="" p_gt="" p_ti="" p_gr=""
      # shellcheck disable=SC2034
      IFS=$'\t' read -r p_key p_st p_pts p_ttl p_mv p_td p_tt p_gp p_gt p_ti p_gr <<< "$parsed"

      local status="${p_st:-unknown}" points="${p_pts:-0}"
      local title="${p_ttl:-Story $ck}"
      [ "${#title}" -le 200 ] || title="${title:0:200}"
      local dir_name; dir_name="${cp%/*}"; dir_name="${dir_name##*/}"
      local slug="${dir_name#"${ck}"-}"; [ "$slug" != "$dir_name" ] || slug="$dir_name"

      # Totals
      total_points=$((total_points + points))
      if [ "$status" = "done" ]; then
        done_points=$((done_points + points)); done_stories=$((done_stories + 1))
        [ "$fmt" -le "$latest_done_mt" ] || latest_done_mt="$fmt"
      else all_done=0; fi
      [ "$status" = "done" ] || [ "$status" = "review" ] || all_done_or_review=0
      by_status_data="${by_status_data:+${by_status_data}
}${status}	${points}"

      # Phase / unphased
      if [ -n "$s_phase" ] && [ "$s_phase" != "null" ]; then
        phase_data="${phase_data:+${phase_data}
}${s_phase}	${ck}	${status}"
      else
        unphased="${unphased:+${unphased},}\"${ck}\""
      fi

      # Story JSON
      local bss="null"; [ "$status" != "blocked" ] || bss="\"$(_mt_date_fast "$fmt")\""
      local mv=""; [ -z "$all_verdicts" ] || { local vl="${all_verdicts#*"${ck}"	}"; [ "$vl" = "$all_verdicts" ] || mv="${vl%%
*}"; }
      # Build task items JSON inline (no subprocess)
      local ti_j="[" _tf=1
      if [ -n "$p_ti" ]; then
        local _IS="$IFS"; IFS=";;;"
        # shellcheck disable=SC2086
        set -- $p_ti; IFS="$_IS"
        while [ $# -gt 0 ]; do local _tp="$1"; shift; [ -n "$_tp" ] || continue
          [ "$_tf" = "1" ] || ti_j="${ti_j},"
          ti_j="${ti_j}{\"text\":\"${_tp#*:::}\",\"done\":${_tp%%:::*}}"
          _tf=0; done; fi
      ti_j="${ti_j}]"
      # Build gate rows JSON inline (no subprocess)
      local gr_j="[" _gf=1
      if [ -n "$p_gr" ]; then
        local _IS="$IFS"; IFS=";;;"
        # shellcheck disable=SC2086
        set -- $p_gr; IFS="$_IS"
        while [ $# -gt 0 ]; do local _gp="$1"; shift; [ -n "$_gp" ] || continue
          [ "$_gf" = "1" ] || gr_j="${gr_j},"
          gr_j="${gr_j}{\"name\":\"${_gp%%:::*}\",\"status\":\"${_gp#*:::}\"}"
          _gf=0; done; fi
      gr_j="${gr_j}]"
      local mreq="false"; [ "$p_mv" != "true" ] || mreq="true"
      local vj="null"; [ -z "$mv" ] || vj="\"$mv\""
      local bbj="null"; [ "$s_blocked" = "null" ] || [ -z "$s_blocked" ] || bbj="\"$s_blocked\""
      local phj="null"; [ -z "$s_phase" ] || [ "$s_phase" = "null" ] || phj="$s_phase"

      stories_jsonl="${stories_jsonl:+${stories_jsonl},}{\"key\":\"${ck}\",\"title\":\"${title}\",\"slug\":\"${slug}\",\"status\":\"${status}\",\"points\":${points},\"phase\":${phj},\"risk_level\":\"${s_risk}\",\"blocked_by\":${bbj},\"blocked_since\":${bss},\"tasks\":{\"done\":${p_td:-0},\"total\":${p_tt:-0},\"items\":${ti_j}},\"gates\":{\"passed\":${p_gp:-0},\"total\":${p_gt:-6},\"rows\":${gr_j}},\"manual_test\":{\"required\":${mreq},\"verdict\":${vj}}}"

      # Rule (a)
      if [ "$mreq" = "true" ] && [ "${p_gp:-0}" = "6" ] && [ "$status" != "done" ]; then
        if [ -z "$mv" ] || [ "$mv" = "UNVERIFIED" ]; then
          action_lines="${action_lines:+${action_lines}
}a	manual_test_due	${ck}	_	/gaia-test-manual	story-file	$(_mt_date_fast "$fmt")	Manual test is due for ${ck}"
        fi
      fi

      # Drift
      if [ -n "$s_yaml_st" ] && [ "$status" != "$s_yaml_st" ]; then
        local det="Story file says ${status}, sprint yaml says ${s_yaml_st}"
        [ "${#det}" -le 200 ] || det="${det:0:200}"
        drift_lines="${drift_lines:+${drift_lines}
}${ck}	status_mismatch	${det}"
      fi
      if [ "$status" = "review" ] && [ $(( now_epoch - fmt )) -gt 172800 ]; then
        drift_lines="${drift_lines:+${drift_lines}
}${ck}	stale_review	Story in review for over 48 hours"
      fi
    done
  fi
  [ "$has_stories" = "1" ] || { all_done=0; all_done_or_review=0; }

  # --- Rule (c) ---
  if [ -n "$action_items_path" ] && [ -f "$action_items_path" ]; then
    local ai_output; ai_output="$(_read_action_items "$action_items_path")" || ai_output=""
    local ai_mt=""; [ ! -f "$action_items_path" ] || ai_mt="$(_stat_mtime "$action_items_path")"
    if [ -n "$ai_output" ]; then
      while IFS=$'\t' read -r ai_id ai_st ai_asn ai_cr; do
        [ -n "$ai_id" ] || continue
        case "$ai_st" in open|in-progress) ;; *) continue ;; esac
        local ai_low; ai_low="$(printf '%s' "$ai_asn" | tr '[:upper:]' '[:lower:]')"
        local amatch=0
        if [ "${#user_aliases_lower[@]}" -gt 0 ]; then
          for al in "${user_aliases_lower[@]}"; do [ "$ai_low" != "$al" ] || { amatch=1; break; }; done
        fi
        [ "$amatch" = "1" ] || continue
        local sc=""
        if [ -n "$ai_cr" ] && [ "$ai_cr" != "null" ]; then sc="${ai_cr:0:10}"
        elif [ -n "$ai_mt" ]; then sc="$(_mtime_to_date "$ai_mt")"
        else sc="$(date -u +%Y-%m-%d)"; fi
        local mc="Action item ${ai_id} is assigned and ${ai_st}"; [ "${#mc}" -le 300 ] || mc="${mc:0:300}"
        action_lines="${action_lines:+${action_lines}
}c	action_item_assigned	_	${ai_id}	/gaia-action-items	action-items	${sc}	${mc}"
      done <<< "$ai_output"
    fi
  fi

  # --- Rule (d) ---
  if [ "$SPRINT_STATUS" = "active" ] && [ "$has_stories" = "1" ] && [ "$all_done" = "1" ]; then
    local sd; [ "$latest_done_mt" -gt 0 ] && sd="$(_mt_date_fast "$latest_done_mt")" || sd="$(date -u +%Y-%m-%d)"
    action_lines="${action_lines:+${action_lines}
}d	sprint_can_close	_	_	/gaia-sprint-close	sprint-status	${sd}	All stories are done, sprint can be closed"
  fi

  # --- Action needed JSON ---
  local an_json=""
  if [ -n "$action_lines" ]; then
    local sorted; sorted="$(printf '%s\n' "$action_lines" | sort -s -t'	' -k1,1 -k3,3 -k4,4)"
    while IFS=$'\t' read -r rl ty sk iid cmd src sin msg; do
      [ "$sk" != "_" ] || sk=""; [ "$iid" != "_" ] || iid=""
      local vc; vc="$(_validate_command "$cmd")"
      local skj="[]"; [ -z "$sk" ] || skj="[\"${sk}\"]"
      local cj="null"; [ "$vc" = "null" ] || cj="\"${vc}\""
      local em="${msg//\\/\\\\}"; em="${em//\"/\\\"}"
      local e="{\"rule\":\"${rl}\",\"type\":\"${ty}\",\"story_keys\":${skj}"
      [ -z "$iid" ] || e="${e},\"item_id\":\"${iid}\""
      e="${e},\"message\":\"${em}\",\"command\":${cj},\"since\":\"${sin}\",\"source\":\"${src}\"}"
      an_json="${an_json:+${an_json},}${e}"
    done <<< "$sorted"
  fi

  # --- By-status ---
  local bs_json=""
  [ -z "$by_status_data" ] || bs_json="$(printf '%s\n' "$by_status_data" | awk -F'\t' '
    {c[$1]++;p[$1]+=$2} END{f=1;for(s in c){if(!f)printf",";printf"\"%s\":{\"count\":%d,\"points\":%d}",s,c[s],p[s];f=0}}')"

  # --- Phases ---
  local phases_result; phases_result="$(_build_phases_json "$phase_data")"
  local phases_json="${phases_result%%	*}" active_phase="${phases_result#*	}"

  # --- Drift JSON ---
  local dr_json=""
  if [ -n "$drift_lines" ]; then
    while IFS=$'\t' read -r dk dt dd; do
      local ed="${dd//\\/\\\\}"; ed="${ed//\"/\\\"}"
      dr_json="${dr_json:+${dr_json},}{\"story_key\":\"${dk}\",\"type\":\"${dt}\",\"detail\":\"${ed}\"}"
    done <<< "$drift_lines"
  fi

  # --- Day / pace ---
  local dp_result; dp_result="$(_compute_day_pace "$START_DATE" "$END_DATE" "$done_points" "$total_points")"
  local day_current day_total day_pace
  IFS=$'\t' read -r day_current day_total day_pace <<< "$dp_result"

  # --- Readiness ---
  local sr="false" scl="false"
  if [ "$has_stories" = "1" ]; then
    [ "$all_done_or_review" != "1" ] || sr="true"
    [ "$all_done" != "1" ] || scl="true"
  fi

  # --- Progress ---
  local progress_pct=0
  [ "$total_points" -eq 0 ] || progress_pct=$(( (done_points * 100) / total_points ))

  # --- Sprint JSON fields (inline to avoid subprocesses) ---
  local goal_raw="${GOAL:-}"; [ "${#goal_raw}" -le 200 ] || goal_raw="${goal_raw:0:200}"
  local sprint_goal="null"
  if [ -n "$goal_raw" ] && [ "$goal_raw" != "null" ]; then
    local _ge="${goal_raw//\\/\\\\}"; sprint_goal="\"${_ge//\"/\\\"}\""; fi
  local sprint_end="null"
  [ -z "$END_DATE" ] || [ "$END_DATE" = "null" ] || sprint_end="\"${END_DATE}\""
  local sprint_cap="null"
  [ -z "$CAPACITY_UTIL" ] || [ "$CAPACITY_UTIL" = "null" ] || sprint_cap="\"${CAPACITY_UTIL}\""
  local sprint_epic="null"
  [ -z "$EPIC_FOCUS" ] || [ "$EPIC_FOCUS" = "null" ] || sprint_epic="\"${EPIC_FOCUS}\""
  local pace_json="null"; [ "$day_pace" = "null" ] || pace_json="\"${day_pace}\""

  # --- Assemble + atomic write ---
  local gen_at; gen_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  _write_atomic "$CACHE_FILE" "$(printf '{
  "schema_version": "1.0",
  "generated_at": "%s",
  "sprint": {"id":"%s","goal":%s,"start_date":"%s","end_date":%s,"status":"%s","total_days":%s,"capacity_utilization":%s,"epic_focus":%s},
  "totals": {"done_points":%d,"total_points":%d,"done_stories":%d,"total_stories":%d,"progress_pct":%d},
  "by_status": {%s},
  "day": {"current":%d,"total":%s,"pace":%s},
  "active_phase": %s,
  "phases": [%s],
  "unphased_stories": [%s],
  "stories": [%s],
  "action_needed": [%s],
  "drift": [%s],
  "readiness": {"sprint_review":%s,"sprint_close":%s},
  "user_aliases": %s,
  "waiting_agent_threshold_seconds": %s
}' "$gen_at" \
   "$SPRINT_ID" "$sprint_goal" "$START_DATE" "$sprint_end" "$SPRINT_STATUS" "$day_total" "$sprint_cap" "$sprint_epic" \
   "$done_points" "$total_points" "$done_stories" "$total_stories" "$progress_pct" \
   "${bs_json:-}" "$day_current" "$day_total" "$pace_json" "$active_phase" \
   "${phases_json:-}" "${unphased:-}" "${stories_jsonl:-}" "${an_json:-}" "${dr_json:-}" \
   "$sr" "$scl" "$aliases_json" "${threshold:-120}")"

  # --- Sidecar meta entries (inline to avoid subprocesses) ---
  local _meta_files="__sprint_status__	${YAML_FILE}
__review_gate_ledger__	${ledger_path}"
  [ -z "$action_items_path" ] || _meta_files="${_meta_files}
__action_items__	${action_items_path}"
  _meta_files="${_meta_files}
__project_config__	${CONFIG_FILE}"
  while IFS=$'\t' read -r _ms _mf; do
    [ -f "$_mf" ] || continue
    local _mm; _mm="$(_stat_mtime "$_mf")"
    new_sidecar="${new_sidecar:+${new_sidecar}
}meta	${_ms}	${_mf}	${_mm}"
  done <<< "$_meta_files"
  _write_atomic "$SIDECAR_FILE" "${new_sidecar:-}"
}

# Main guard — allow sourcing for testability
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _snapshot_main "$@"
fi
