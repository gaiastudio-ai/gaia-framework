#!/usr/bin/env bash
# sprint-status-dashboard.sh — deterministic sprint status dashboard formatter
#
# Cache-first data source: reads the sprint-progress cache JSON at
# .gaia/state/.sprint-progress-cache.json (written by sprint-progress-snapshot.sh)
# and renders an enhanced plain-text dashboard with columns:
#   Story | Title | Status | Pts | Tasks | Gates
# plus phase grouping, a warning header for action-needed items, and
# header/footer fields from the cache.
#
# Fallback: when the cache is unavailable (jq absent, cache missing after
# a failed snapshot rebuild, invalid JSON, or SPRINT_STATUS_YAML set without
# SPRINT_CACHE_JSON), the script falls back to reading sprint-status.yaml
# directly and renders the original four-column table (Story | Title |
# Status | Pts) with no Tasks/Gates/phase grouping. A one-line notice is
# emitted on stderr when the fallback activates.
#
# This script is the read-only rendering peer to sprint-state.sh — it NEVER
# opens sprint-status.yaml for write under any code path, and it never
# writes the cache (that is the sole responsibility of
# sprint-progress-snapshot.sh).
#
# Invocation:
#   sprint-status-dashboard.sh [--help]
#
# Environment:
#   PROJECT_PATH             Root of the project (defaults to ".")
#   SPRINT_CACHE_JSON        Override cache path (snapshot never invoked)
#   SPRINT_STATUS_YAML       Override yaml path (forces fallback when
#                            SPRINT_CACHE_JSON is not also set)
#   SPRINT_PROGRESS_SNAPSHOT Override snapshot script path (test override)
#   MITIGATION_CATALOG       Override mitigation catalog path
#   IMPLEMENTATION_ARTIFACTS Override story-files directory
#
# Exit codes:
#   0 — dashboard rendered successfully (or "No active sprint")
#   1 — sprint-status.yaml not found (fallback path only), parse error,
#       or missing dependencies
#
# POSIX discipline: bash with set -euo pipefail. macOS /bin/bash 3.2 compatible.
# READ-ONLY: This script NEVER writes to sprint-status.yaml or the cache.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="sprint-status-dashboard.sh"

# ---------- Help ----------
if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
sprint-status-dashboard.sh — render sprint status dashboard

Usage: sprint-status-dashboard.sh [--help]

Data source (cache-first):
  Reads .gaia/state/.sprint-progress-cache.json when available. When the
  cache is absent or stale (>60 s), invokes the snapshot script to rebuild
  it. Falls back to reading sprint-status.yaml directly when jq is absent,
  the cache is invalid, or the snapshot fails.

Columns (cache path):
  Story | Title | Status | Pts | Tasks | Gates
  Stories are grouped by phase with header lines. A warning header appears
  when action-needed items exist. The risk annotation column appears when
  any story has high risk.

Columns (fallback path):
  Story | Title | Status | Pts

Environment:
  PROJECT_PATH              Root of the project (default: ".")
  SPRINT_CACHE_JSON         Override cache JSON path (snapshot never invoked)
  SPRINT_STATUS_YAML        Override sprint-status.yaml path (forces
                            fallback when SPRINT_CACHE_JSON is unset)
  SPRINT_PROGRESS_SNAPSHOT  Override snapshot script path (test override)
  MITIGATION_CATALOG        Override mitigation catalog path
  IMPLEMENTATION_ARTIFACTS  Override story-files directory

This script is read-only — it NEVER modifies sprint-status.yaml or the cache.
USAGE
  exit 0
fi

# ---------- Resolve paths ----------
PROJECT_PATH="${PROJECT_PATH:-.}"
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH}}}"
export PROJECT_ROOT

YAML_PATH="${SPRINT_STATUS_YAML:-}"
if [[ -z "$YAML_PATH" ]]; then
  _DASH_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  _RESOLVE_ARTIFACT_PATH="$_DASH_SCRIPT_DIR/lib/resolve-artifact-path.sh"
  if [[ -x "$_RESOLVE_ARTIFACT_PATH" ]]; then
    YAML_PATH="$("$_RESOLVE_ARTIFACT_PATH" sprint_status --project-root "$PROJECT_ROOT" --existing-only 2>/dev/null || true)"
    [[ -z "$YAML_PATH" ]] && YAML_PATH="$("$_RESOLVE_ARTIFACT_PATH" sprint_status --project-root "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT/.gaia/state/sprint-status.yaml")"
  else
    GAIA_STATE_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
    CANONICAL_YAML="$PROJECT_ROOT/docs/implementation-artifacts/sprint-status.yaml"
    FALLBACK_YAML="$PROJECT_ROOT/sprint-status.yaml"
    if [[ -f "$GAIA_STATE_YAML" ]]; then
      YAML_PATH="$GAIA_STATE_YAML"
    elif [[ -f "$CANONICAL_YAML" ]]; then
      YAML_PATH="$CANONICAL_YAML"
    elif [[ -f "$FALLBACK_YAML" ]]; then
      YAML_PATH="$FALLBACK_YAML"
    else
      YAML_PATH="$GAIA_STATE_YAML"
    fi
  fi
fi

# Implementation-artifacts directory — used for story-file lookups.
if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  if [ -d "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" ]; then
    IMPLEMENTATION_ARTIFACTS="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  else
    IMPLEMENTATION_ARTIFACTS="$PROJECT_ROOT/docs/implementation-artifacts"
  fi
fi

# Mitigation catalog path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MITIGATION_CATALOG="${MITIGATION_CATALOG:-$SCRIPT_DIR/../skills/gaia-sprint-status/mitigation-catalog.yaml}"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------- Cross-platform mtime helper ----------
if stat -c %Y / >/dev/null 2>&1; then
  _DASH_STAT_FMT="gnu"
else
  _DASH_STAT_FMT="bsd"
fi

_stat_mtime() {
  if [ "$_DASH_STAT_FMT" = "gnu" ]; then
    stat -c %Y "$1" 2>/dev/null || printf '0'
  else
    stat -f %m "$1" 2>/dev/null || printf '0'
  fi
}

# ---------- Sanitization and validation ----------

# _sanitize_field VALUE — strip terminal-unsafe sequences from a cache string.
# Strips: ESC CSI (incl. private-parameter), OSC (BEL or ESC\-terminated),
# C1 controls U+0080-U+009F (UTF-8 0xC2 0x80-0x9F), DEL 0x7F,
# control chars 0x00-0x1F (except newline 0x0A), U+FFFD, invalid UTF-8.
# Bash 3.2 compatible — uses tr and sed.
_sanitize_field() {
  local v="$1"
  # Strip ESC-based sequences: CSI (ESC [ ... letter), OSC (ESC ] ... BEL/ST)
  # Use sed in multiple passes for clarity and bash 3.2 compat.
  # 1. Strip CSI: ESC [ (optional ? or >) then params then final byte
  v="$(printf '%s' "$v" | sed $'s/\033\\[[?>=]*[0-9;]*[A-Za-z]//g')"
  # 2. Strip OSC terminated by BEL: ESC ] ... BEL
  v="$(printf '%s' "$v" | sed $'s/\033\\][^\007]*\007//g')"
  # 3. Strip OSC terminated by ST (ESC \): ESC ] ... ESC backslash
  v="$(printf '%s' "$v" | sed $'s/\033\\][^\033]*\033\\\\//g')"
  # 4. Strip bare ESC not caught above
  v="$(printf '%s' "$v" | tr -d $'\033')"
  # 5. Strip BEL
  v="$(printf '%s' "$v" | tr -d $'\007')"
  # 6. Strip control chars 0x00-0x09, 0x0B-0x1F (keep 0x0A newline)
  v="$(printf '%s' "$v" | tr -d $'\001\002\003\004\005\006\010\011\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037')"
  # 7. Strip DEL (0x7F)
  v="$(printf '%s' "$v" | tr -d $'\177')"
  # 8. Strip C1 controls: UTF-8 bytes 0xC2 0x80-0x9F (U+0080-U+009F)
  #    and U+FFFD (UTF-8 0xEF 0xBF 0xBD).
  #    macOS sed does not support \xNN in the pattern — build the pattern
  #    via printf so the shell expands the bytes before sed sees them.
  v="$(printf '%s' "$v" | sed "$(printf 's/\xc2[\x80-\x9f]//g')" 2>/dev/null || printf '%s' "$v")"
  v="$(printf '%s' "$v" | sed "$(printf 's/\xef\xbf\xbd//g')" 2>/dev/null || printf '%s' "$v")"
  # 9. Strip invalid UTF-8 via iconv -c (silently drop unconvertible bytes)
  v="$(printf '%s' "$v" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$v")"
  printf '%s' "$v"
}

_validate_story_key() {
  local v="$1"
  # Whole-string match — regex stored in a variable for bash 3.2 compat
  local _re='^E[0-9]+-S[0-9]+$'
  if [[ "$v" =~ $_re ]]; then
    printf '%s' "$v"
  else
    printf '?'
  fi
}

_validate_status() {
  local v="$1"
  case "$v" in
    backlog|ready-for-dev|in-progress|review|blocked|validating|done)
      printf '%s' "$v" ;;
    *)
      printf '?' ;;
  esac
}

_validate_phase_status() {
  local v="$1"
  case "$v" in
    done|active|future)
      printf '%s' "$v" ;;
    *)
      printf '?' ;;
  esac
}

_validate_numeric() {
  local v="$1"
  # Whole-string match — regex stored in a variable for bash 3.2 compat
  local _re='^[0-9]+$'
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    printf '?'
  elif [[ "$v" =~ $_re ]]; then
    printf '%s' "$v"
  else
    printf '?'
  fi
}

# ---------- Load mitigation catalog ----------
catalog_labels=()
catalog_missing=false
catalog_warning=""
if [[ ! -s "$MITIGATION_CATALOG" ]]; then
  catalog_missing=true
  catalog_warning="WARNING: mitigation catalog not found at $MITIGATION_CATALOG — risk surfacing degraded"
else
  while IFS= read -r label_line; do
    [[ -n "$label_line" ]] && catalog_labels+=("$label_line")
  done < <(awk '
    BEGIN { in_mitigations = 0 }
    /^mitigations:/ { in_mitigations = 1; next }
    in_mitigations && /^[^[:space:]#-]/ { in_mitigations = 0 }
    in_mitigations && /^[[:space:]]+label:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]+label:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
    }
  ' "$MITIGATION_CATALOG")
  if [[ ${#catalog_labels[@]} -eq 0 ]]; then
    catalog_missing=true
    catalog_warning="WARNING: mitigation catalog empty at $MITIGATION_CATALOG — risk surfacing degraded"
  fi
fi

# ---------- Stranded-ready scanner (shared by both paths) ----------
_run_stranded_scanner() {
  local _STRANDED_SCANNER="$SCRIPT_DIR/lib/scan-stranded-ready.sh"
  if [[ -x "$_STRANDED_SCANNER" ]]; then
    local stranded_tsv
    stranded_tsv=$(PROJECT_PATH="$PROJECT_PATH" \
      IMPLEMENTATION_ARTIFACTS="$IMPLEMENTATION_ARTIFACTS" \
      "$_STRANDED_SCANNER" 2>/dev/null || true)
    if [[ -n "$stranded_tsv" ]]; then
      printf -- '-%.0s' {1..72}; printf '\n'
      printf '  ## Stranded ready stories\n'
      local idx=0
      while IFS=$'\t' read -r sr_key sr_title _sr_path; do
        [[ -n "$sr_key" ]] || continue
        idx=$((idx + 1))
        printf '  %d. %s — %s\n' "$idx" "$sr_key" "$sr_title"
      done <<<"$stranded_tsv"
      printf '  These stories are Val-PASSED but unassigned. Inject via /gaia-correct-course, or let /gaia-sprint-plan pick them up.\n'
    fi
  fi
}

# ---------- Risk-surfacing block (shared by both paths) ----------
_render_risk_block() {
  local _high_count="$1"
  if [[ "$_high_count" -gt 0 ]]; then
    if [[ "$catalog_missing" == true ]]; then
      printf '  %s\n' "$catalog_warning"
    else
      printf '  Recommended mitigations for HIGH-risk stories:\n'
      local label_iter=""
      for label_iter in ${catalog_labels[@]+"${catalog_labels[@]}"}; do
        printf '    - %s\n' "$label_iter"
      done
      while IFS= read -r id_line; do
        [[ -n "$id_line" ]] && printf '      (id: %s)\n' "$id_line"
      done < <(awk '
        BEGIN { in_mitigations = 0 }
        /^mitigations:/ { in_mitigations = 1; next }
        in_mitigations && /^[^[:space:]#-]/ { in_mitigations = 0 }
        in_mitigations && /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
          v = $0
          sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", v)
          gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
          print v
        }
      ' "$MITIGATION_CATALOG")
    fi
  fi
}

# ==========================================================================
# CACHE PATH — _render_cache_dashboard
# Reads only from the cache JSON via jq. Never reads sprint-status.yaml.
# ==========================================================================
_render_cache_dashboard() {
  local cache_file="$1"

  # --- Read cache fields via jq ---
  local sprint_json
  sprint_json="$(jq -r '.sprint // empty' "$cache_file" 2>/dev/null || true)"
  if [ -z "$sprint_json" ] || [ "$sprint_json" = "null" ]; then
    printf '  No active sprint\n'
    _run_stranded_scanner
    printf '=%.0s' {1..72}; printf '\n'
    return 0
  fi

  local c_sprint_status
  c_sprint_status="$(jq -r '.sprint.status // ""' "$cache_file")"
  if [ "$c_sprint_status" = "closed" ]; then
    printf '  No active sprint\n'
    _run_stranded_scanner
    printf '=%.0s' {1..72}; printf '\n'
    return 0
  fi

  # Header fields
  local c_id c_goal c_start c_end c_total_days c_util c_focus
  c_id="$(_sanitize_field "$(jq -r '.sprint.id // "N/A"' "$cache_file")")"
  c_goal="$(jq -r '.sprint.goal // ""' "$cache_file")"
  c_start="$(_sanitize_field "$(jq -r '.sprint.start_date // "N/A"' "$cache_file")")"
  c_end="$(_sanitize_field "$(jq -r '.sprint.end_date // "N/A"' "$cache_file")")"
  c_total_days="$(jq -r '.sprint.total_days // "null"' "$cache_file")"
  c_util="$(jq -r '.sprint.capacity_utilization // ""' "$cache_file")"
  c_focus="$(jq -r '.sprint.epic_focus // ""' "$cache_file")"

  # Totals
  local c_total_pts c_done_stories c_total_stories
  c_total_pts="$(_validate_numeric "$(jq -r '.totals.total_points // "0"' "$cache_file")")"
  c_done_stories="$(_validate_numeric "$(jq -r '.totals.done_stories // "0"' "$cache_file")")"
  c_total_stories="$(_validate_numeric "$(jq -r '.totals.total_stories // "0"' "$cache_file")")"

  # Readiness
  local c_sprint_close
  c_sprint_close="$(jq -r '.readiness.sprint_close // false' "$cache_file")"

  # Render header
  printf '=%.0s' {1..72}; printf '\n'
  printf '  SPRINT STATUS DASHBOARD\n'
  printf '=%.0s' {1..72}; printf '\n'
  printf '  Sprint:     %s\n' "$c_id"

  # Duration from total_days (null omits the line, non-numeric shows ?)
  if [ "$c_total_days" != "null" ] && [ -n "$c_total_days" ]; then
    local vd
    vd="$(_validate_numeric "$c_total_days")"
    printf '  Duration:   %s days\n' "$vd"
  fi

  printf '  Dates:      %s → %s\n' "$c_start" "$c_end"
  printf '  Velocity:   %s pts\n' "${c_total_pts:-0}"

  if [ -n "$c_util" ] && [ "$c_util" != "null" ]; then
    printf '  Utilization: %s\n' "$(_sanitize_field "$c_util")"
  fi
  if [ -n "$c_focus" ] && [ "$c_focus" != "null" ]; then
    printf '  Focus:      %s\n' "$(_sanitize_field "$c_focus")"
  fi
  if [ -n "$c_goal" ] && [ "$c_goal" != "null" ]; then
    printf '  Goal:       %s\n' "$(_sanitize_field "$c_goal")"
  fi
  printf -- '-%.0s' {1..72}; printf '\n'

  # --- Auto-close banner from cache ---
  if [ "$c_sprint_close" = "true" ]; then
    printf '  [SPRINT READY-TO-REVIEW] %s — %s/%s stories done (end_date: %s)\n' \
      "$c_id" "$c_done_stories" "$c_total_stories" "$c_end"
    printf '    Advisory hint only — this banner does NOT mean the sprint is closed.\n'
    printf '    Every story is done, but the sprint is still status: active and the\n'
    printf '    end-of-sprint CEREMONY has not run yet.\n'
    printf '    Next step — run the ceremony, do NOT hand-edit the sprint state:\n'
    printf '      /gaia-sprint-review   (Val + per-stack verdict; gates the close)\n'
    printf '      then /gaia-sprint-close on a PASSED verdict (writes status: closed,\n'
    printf '      archives the state, emits the lifecycle event — the sanctioned\n'
    printf '      boundary write). After close, /gaia-sprint-plan seeds the\n'
    printf '      next sprint (re-seeds over the closed predecessor — no manual\n'
    printf '      rm needed).\n'
    printf -- '-%.0s' {1..72}; printf '\n'
  fi

  # --- Warning header from action_needed ---
  local action_count=0
  local first_msg=""
  # Count action_needed entries (rules a, c, d only).
  # When auto-close banner is showing (sprint_close=true), suppress rule-d.
  local jq_filter
  if [ "$c_sprint_close" = "true" ]; then
    jq_filter='.action_needed // [] | map(select(.rule != "d")) | length'
  else
    jq_filter='.action_needed // [] | length'
  fi
  action_count="$(jq -r "$jq_filter" "$cache_file" 2>/dev/null || printf '0')"

  if [ "$action_count" -gt 0 ]; then
    if [ "$c_sprint_close" = "true" ]; then
      first_msg="$(jq -r '(.action_needed // [] | map(select(.rule != "d")) | .[0].message) // ""' "$cache_file" 2>/dev/null || true)"
    else
      first_msg="$(jq -r '(.action_needed // [] | .[0].message) // ""' "$cache_file" 2>/dev/null || true)"
    fi
    first_msg="$(_sanitize_field "$first_msg")"
    if [ "$action_count" -eq 1 ]; then
      printf '  WARNING: 1 item needs attention — %s\n' "$first_msg"
    else
      printf '  WARNING: %d items need attention — %s\n' "$action_count" "$first_msg"
    fi
  fi

  # --- Column headers ---
  printf '  %-12s %-38s %-14s %-4s %-7s %-6s\n' "Story" "Title" "Status" "Pts" "Tasks" "Gates"
  printf '  %-12s %-38s %-14s %-4s %-7s %-6s\n' "-----" "-----" "------" "---" "-----" "-----"

  # --- Phase grouping ---
  local phase_count
  phase_count="$(jq -r '.phases | length' "$cache_file" 2>/dev/null || printf '0')"

  local pi=0
  while [ "$pi" -lt "$phase_count" ]; do
    local ph_num ph_status ph_stories
    ph_num="$(_validate_numeric "$(jq -r ".phases[$pi].phase" "$cache_file")")"
    ph_status="$(_validate_phase_status "$(jq -r ".phases[$pi].status" "$cache_file")")"
    printf '  --- Phase %s (%s) ---\n' "$ph_num" "$ph_status"

    # Stories in this phase
    ph_stories="$(jq -r ".phases[$pi].stories[]" "$cache_file" 2>/dev/null || true)"
    local skey
    while IFS= read -r skey; do
      [ -z "$skey" ] && continue
      _render_cache_story_row "$cache_file" "$skey"
    done <<<"$ph_stories"

    pi=$((pi + 1))
  done

  # Unphased stories
  local unphased
  unphased="$(jq -r '.unphased_stories[]' "$cache_file" 2>/dev/null || true)"
  if [ -n "$unphased" ]; then
    printf '  --- Unphased ---\n'
    local ukey
    while IFS= read -r ukey; do
      [ -z "$ukey" ] && continue
      _render_cache_story_row "$cache_file" "$ukey"
    done <<<"$unphased"
  fi

  # --- Footer ---
  printf -- '-%.0s' {1..72}; printf '\n'
  printf '  Total: %s stories | %s points\n' "$c_total_stories" "$c_total_pts"

  # --- Stranded ready stories (exempt from cache-only rule) ---
  _run_stranded_scanner

  # --- Risk block ---
  _render_risk_block "$_CACHE_HIGH_RISK_COUNT"

  printf '=%.0s' {1..72}; printf '\n'
}

# Helper: render a single story row from cache data.
# Uses jq to extract the story object by key.
_CACHE_HIGH_RISK_COUNT=0
_render_cache_story_row() {
  local cache_file="$1" skey="$2"

  # Extract story fields via jq
  local s_json
  s_json="$(jq -r --arg k "$skey" '.stories[] | select(.key == $k)' "$cache_file" 2>/dev/null || true)"
  [ -z "$s_json" ] && return 0

  local s_key s_title s_status s_points s_risk
  local s_tasks_done s_tasks_total s_gates_passed s_gates_total

  s_key="$(_validate_story_key "$(printf '%s' "$s_json" | jq -r '.key // "?"')")"
  s_title="$(_sanitize_field "$(printf '%s' "$s_json" | jq -r '.title // ""')")"
  s_status="$(_validate_status "$(printf '%s' "$s_json" | jq -r '.status // "?"')")"
  s_points="$(_validate_numeric "$(printf '%s' "$s_json" | jq -r '.points // "0"')")"
  s_risk="$(printf '%s' "$s_json" | jq -r '.risk_level // ""')"
  s_tasks_done="$(_validate_numeric "$(printf '%s' "$s_json" | jq -r '.tasks.done // "0"')")"
  s_tasks_total="$(_validate_numeric "$(printf '%s' "$s_json" | jq -r '.tasks.total // "0"')")"
  s_gates_passed="$(_validate_numeric "$(printf '%s' "$s_json" | jq -r '.gates.passed // "0"')")"
  s_gates_total="$(_validate_numeric "$(printf '%s' "$s_json" | jq -r '.gates.total // "6"')")"

  # Truncate title to 36 bytes (sanitize first, then truncate on a
  # character boundary). Under LC_ALL=C, ${#s_title} counts bytes.
  # After slicing, drop any trailing UTF-8 continuation bytes (0x80-0xBF)
  # that would leave a broken character, then run iconv -c to be safe.
  if [ ${#s_title} -gt 36 ]; then
    s_title="${s_title:0:33}"
    # Strip trailing continuation bytes (binary 10xxxxxx = 0x80-0xBF)
    while [ ${#s_title} -gt 0 ]; do
      local _tail_byte
      _tail_byte="$(printf '%s' "${s_title:${#s_title}-1:1}" | od -An -tx1 2>/dev/null | tr -d ' ')"
      case "$_tail_byte" in
        8[0-9a-f]|9[0-9a-f]|a[0-9a-f]|b[0-9a-f])
          s_title="${s_title:0:${#s_title}-1}" ;;
        *) break ;;
      esac
    done
    # If stripping consumed a leading byte of a multibyte sequence, drop it
    if [ ${#s_title} -gt 0 ]; then
      local _last_byte
      _last_byte="$(printf '%s' "${s_title:${#s_title}-1:1}" | od -An -tx1 2>/dev/null | tr -d ' ')"
      case "$_last_byte" in
        c[0-9a-f]|d[0-9a-f]|e[0-9a-f]|f[0-7])
          # This is a leading byte with no continuation bytes — incomplete
          s_title="${s_title:0:${#s_title}-1}" ;;
      esac
    fi
    s_title="$(printf '%s' "$s_title" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$s_title")"
    s_title="${s_title}..."
  fi

  # Tasks column: X/Y when total > 0, dash when total is 0
  local tasks_col
  if [ "$s_tasks_total" = "0" ]; then
    tasks_col="-"
  elif [ "$s_tasks_total" = "?" ] || [ "$s_tasks_done" = "?" ]; then
    tasks_col="?"
  else
    tasks_col="${s_tasks_done}/${s_tasks_total}"
  fi

  # Gates column: X/N
  local gates_col
  if [ "$s_gates_passed" = "?" ] || [ "$s_gates_total" = "?" ]; then
    gates_col="?"
  else
    gates_col="${s_gates_passed}/${s_gates_total}"
  fi

  printf '  %-12s %-38s %-14s %-4s %-7s %-6s' \
    "$s_key" "$s_title" "$s_status" "$s_points" "$tasks_col" "$gates_col"

  # Risk annotation from cache risk_level
  if [ "$s_risk" = "high" ]; then
    _CACHE_HIGH_RISK_COUNT=$((_CACHE_HIGH_RISK_COUNT + 1))
    if [[ "$catalog_missing" != true ]] && [[ ${#catalog_labels[@]} -gt 0 ]]; then
      local idx=$(( (_CACHE_HIGH_RISK_COUNT - 1) % ${#catalog_labels[@]} ))
      printf '  [HIGH-risk: mitigation — %s]' "${catalog_labels[$idx]}"
    fi
  fi
  printf '\n'
}

# ==========================================================================
# FALLBACK PATH helpers — top-level functions for awk extraction and
# coverage-gate compatibility (story_risk, yaml_val, flush_story).
# ==========================================================================

# yaml_val KEY — extract a top-level YAML scalar from YAML_PATH.
yaml_val() {
  grep "^${1}:" "$YAML_PATH" 2>/dev/null | sed "s/^${1}:[[:space:]]*//" | tr -d '"' || true
}

# story_risk KEY — locate story file and read the `risk:` frontmatter field.
# Returns lowercased risk value to stdout. Fallback path only.
story_risk() {
  local key="$1"
  local matches=()
  shopt -s nullglob nocaseglob
  # shellcheck disable=SC2206
  matches=( "${IMPLEMENTATION_ARTIFACTS}/${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/stories/"${key}-"*.md \
            "${IMPLEMENTATION_ARTIFACTS}"/epic-*/"${key}-"*/story.md )
  shopt -u nullglob nocaseglob
  [[ ${#matches[@]} -eq 0 ]] && return 0
  local _filtered=() _mm
  for _mm in ${matches[@]+"${matches[@]}"}; do
    case "$_mm" in */stories/*/story.md) continue ;; esac
    _filtered+=( "$_mm" )
  done
  [[ ${#_filtered[@]} -eq 0 ]] && return 0
  matches=( ${_filtered[@]+"${_filtered[@]}"} )
  local story_file="${matches[0]}"
  [[ -r "$story_file" ]] || return 0
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^[[:space:]]*risk:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*risk:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print tolower(v)
      exit
    }
  ' "$story_file"
}

# flush_story — emit the current story row (fallback path). Uses globals
# s_key, s_title, s_status, s_points, high_risk_story_count, story_count.
flush_story() {
  if [[ -n "$s_key" ]]; then
    local display_title="$s_title"
    if [[ ${#display_title} -gt 36 ]]; then
      display_title="${display_title:0:33}"
      # Strip trailing UTF-8 continuation bytes to avoid broken characters
      while [ ${#display_title} -gt 0 ]; do
        local _tb
        _tb="$(printf '%s' "${display_title:${#display_title}-1:1}" | od -An -tx1 2>/dev/null | tr -d ' ')"
        case "$_tb" in
          8[0-9a-f]|9[0-9a-f]|a[0-9a-f]|b[0-9a-f]) display_title="${display_title:0:${#display_title}-1}" ;;
          *) break ;;
        esac
      done
      if [ ${#display_title} -gt 0 ]; then
        local _lb
        _lb="$(printf '%s' "${display_title:${#display_title}-1:1}" | od -An -tx1 2>/dev/null | tr -d ' ')"
        case "$_lb" in
          c[0-9a-f]|d[0-9a-f]|e[0-9a-f]|f[0-7]) display_title="${display_title:0:${#display_title}-1}" ;;
        esac
      fi
      display_title="$(printf '%s' "$display_title" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$display_title")"
      display_title="${display_title}..."
    fi
    printf '  %-12s %-38s %-14s %s' "$s_key" "$display_title" "$s_status" "$s_points"

    local risk
    risk="$(story_risk "$s_key")"
    if [[ "$risk" == "high" ]]; then
      high_risk_story_count=$((high_risk_story_count + 1))
      if [[ "$catalog_missing" != true ]] && [[ ${#catalog_labels[@]} -gt 0 ]]; then
        local idx=$(( (high_risk_story_count - 1) % ${#catalog_labels[@]} ))
        printf '  [HIGH-risk: mitigation — %s]' "${catalog_labels[$idx]}"
      fi
    fi
    printf '\n'
    story_count=$((story_count + 1))
  fi
  s_key="" s_title="" s_status="" s_points=""
}

# ==========================================================================
# FALLBACK PATH — _render_fallback_dashboard
# Reads sprint-status.yaml directly. Original four-column table.
# ==========================================================================
_render_fallback_dashboard() {
  # Validate yaml exists and is parseable
  if [[ ! -f "$YAML_PATH" ]]; then
    die "sprint-status.yaml not found at $YAML_PATH"
  fi
  if ! grep -q "^sprint_id:" "$YAML_PATH" 2>/dev/null; then
    die "malformed or empty sprint-status.yaml — missing sprint_id key"
  fi

  local sprint_id duration total_points started end_date capacity_util epic_focus
  sprint_id=$(yaml_val sprint_id)
  duration=$(yaml_val duration)
  total_points=$(yaml_val total_points)
  started=$(yaml_val start_date)
  [ -z "$started" ] && started=$(yaml_val started)
  end_date=$(yaml_val end_date)
  if [ -z "$duration" ] && [ -n "$started" ] && [ -n "$end_date" ]; then
    local _start_epoch _end_epoch
    _start_epoch=$(date -u -d "$started" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$started" +%s 2>/dev/null || printf '')
    _end_epoch=$(date -u -d "$end_date" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$end_date" +%s 2>/dev/null || printf '')
    if [ -n "$_start_epoch" ] && [ -n "$_end_epoch" ]; then
      duration=$(( (_end_epoch - _start_epoch) / 86400 ))
      duration="${duration} days"
    fi
  fi
  capacity_util=$(yaml_val capacity_utilization)
  epic_focus=$(yaml_val epic_focus)

  # Render header
  printf '=%.0s' {1..72}; printf '\n'
  printf '  SPRINT STATUS DASHBOARD\n'
  printf '=%.0s' {1..72}; printf '\n'
  printf '  Sprint:     %s\n' "${sprint_id:-N/A}"
  printf '  Duration:   %s\n' "${duration:-N/A}"
  printf '  Dates:      %s → %s\n' "${started:-N/A}" "${end_date:-N/A}"
  printf '  Velocity:   %s pts\n' "${total_points:-0}"
  if [[ -n "$capacity_util" ]]; then
    printf '  Utilization: %s\n' "$capacity_util"
  fi
  if [[ -n "$epic_focus" ]]; then
    printf '  Focus:      %s\n' "$epic_focus"
  fi
  printf -- '-%.0s' {1..72}; printf '\n'

  # Auto-close banner via detect-auto-close (fallback path only)
  local auto_close_json=""
  local SPRINT_STATE_SCRIPT="$SCRIPT_DIR/sprint-state.sh"
  if [[ -x "$SPRINT_STATE_SCRIPT" ]]; then
    auto_close_json=$(SPRINT_STATUS_YAML="$YAML_PATH" \
      PROJECT_PATH="$PROJECT_PATH" \
      "$SPRINT_STATE_SCRIPT" detect-auto-close 2>/dev/null || true)
  fi
  if [[ -n "$auto_close_json" ]]; then
    local ac_sprint_id="" ac_done="" ac_total="" ac_end_date=""
    if [[ "$auto_close_json" =~ \"sprint_id\":\"([^\"]*)\" ]]; then
      ac_sprint_id="${BASH_REMATCH[1]}"
    fi
    if [[ "$auto_close_json" =~ \"done\":([0-9]+) ]]; then
      ac_done="${BASH_REMATCH[1]}"
    fi
    if [[ "$auto_close_json" =~ \"total\":([0-9]+) ]]; then
      ac_total="${BASH_REMATCH[1]}"
    fi
    if [[ "$auto_close_json" =~ \"end_date\":\"([^\"]*)\" ]]; then
      ac_end_date="${BASH_REMATCH[1]}"
    fi
    printf '  [SPRINT READY-TO-REVIEW] %s — %s/%s stories done (end_date: %s)\n' \
      "${ac_sprint_id:-?}" "${ac_done:-?}" "${ac_total:-?}" "${ac_end_date:-(unset)}"
    printf '    Advisory hint only — this banner does NOT mean the sprint is closed.\n'
    printf '    Every story is done, but the sprint is still status: active and the\n'
    printf '    end-of-sprint CEREMONY has not run yet.\n'
    printf '    Next step — run the ceremony, do NOT hand-edit sprint-status.yaml:\n'
    printf '      /gaia-sprint-review   (Val + per-stack verdict; gates the close)\n'
    printf '      then /gaia-sprint-close on a PASSED verdict (writes status: closed,\n'
    printf '      archives the yaml, emits the lifecycle event — the sanctioned\n'
    printf '      boundary write). After close, /gaia-sprint-plan + \n'
    printf '      sprint-state.sh init seed the next sprint (re-seeds over the closed\n'
    printf '      predecessor — no manual rm needed).\n'
    printf -- '-%.0s' {1..72}; printf '\n'
  fi

  # Column headers
  printf '  %-12s %-38s %-14s %s\n' "Story" "Title" "Status" "Pts"
  printf '  %-12s %-38s %-14s %s\n' "-----" "-----" "------" "---"

  # Parse stories from yaml
  local in_stories=false
  story_count=0
  s_key="" s_title="" s_status="" s_points=""
  high_risk_story_count=0

  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^stories: ]]; then
      in_stories=true
      continue
    fi
    if [[ "$in_stories" == true ]]; then
      if [[ "$line" =~ ^[a-z_] ]]; then
        in_stories=false
        flush_story
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*key:[[:space:]]* ]]; then
        flush_story
        s_key=$(echo "$line" | sed 's/.*key:[[:space:]]*//' | tr -d '"')
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]+title:[[:space:]]* ]]; then
        s_title=$(echo "$line" | sed 's/.*title:[[:space:]]*//' | tr -d '"')
      elif [[ "$line" =~ ^[[:space:]]+status:[[:space:]]* ]]; then
        s_status=$(echo "$line" | sed 's/.*status:[[:space:]]*//' | tr -d '"')
      elif [[ "$line" =~ ^[[:space:]]+points:[[:space:]]* ]]; then
        s_points=$(echo "$line" | sed 's/.*points:[[:space:]]*//' | tr -d '"')
      fi
    fi
  done < "$YAML_PATH"
  if [[ "$in_stories" == true ]]; then
    flush_story
  fi

  # Footer
  printf -- '-%.0s' {1..72}; printf '\n'
  printf '  Total: %d stories | %s points\n' "$story_count" "${total_points:-0}"

  # Stranded ready stories (exempt from cache-only rule)
  _run_stranded_scanner

  # Risk block
  _render_risk_block "$high_risk_story_count"

  printf '=%.0s' {1..72}; printf '\n'
}

# ==========================================================================
# MAIN — route to cache or fallback path
# ==========================================================================

# When SPRINT_STATUS_YAML is set without SPRINT_CACHE_JSON, force fallback.
if [[ -n "${SPRINT_STATUS_YAML:-}" ]] && [[ -z "${SPRINT_CACHE_JSON:-}" ]]; then
  log "notice: SPRINT_STATUS_YAML set without cache override, showing basic dashboard"
  _render_fallback_dashboard
  exit 0
fi

# Check jq availability
if ! command -v jq >/dev/null 2>&1; then
  log "notice: jq not available, showing basic dashboard"
  _render_fallback_dashboard
  exit 0
fi

# Derive cache path
CACHE_FILE="${SPRINT_CACHE_JSON:-${PROJECT_ROOT}/.gaia/state/.sprint-progress-cache.json}"

# Shared validity check: non-empty, valid JSON, top-level object with
# the expected shape (sprint and stories keys). Returns 0 when valid.
_cache_is_valid() {
  local f="$1"
  [[ -f "$f" ]] && [[ -r "$f" ]] && [[ -s "$f" ]] || return 1
  jq '.' "$f" >/dev/null 2>&1 || return 1
  # Top level must be an object with "sprint" and "stories" keys.
  jq -e 'type == "object" and has("sprint") and has("stories")' "$f" >/dev/null 2>&1 || return 1
  return 0
}

# When SPRINT_CACHE_JSON is set: never invoke snapshot, read directly.
if [[ -n "${SPRINT_CACHE_JSON:-}" ]]; then
  if _cache_is_valid "$CACHE_FILE"; then
    _render_cache_dashboard "$CACHE_FILE"
    exit 0
  fi
  log "notice: cache override unreadable or invalid, showing basic dashboard"
  _render_fallback_dashboard
  exit 0
fi

# No override — check freshness and rebuild if needed.
_SNAPSHOT_SCRIPT="${SPRINT_PROGRESS_SNAPSHOT:-${SCRIPT_DIR}/sprint-progress-snapshot.sh}"

_needs_rebuild=false
if [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]; then
  _needs_rebuild=true
else
  if ! _cache_is_valid "$CACHE_FILE"; then
    _needs_rebuild=true
  else
    local_mtime="$(_stat_mtime "$CACHE_FILE")"
    now_epoch="$(date +%s)"
    age=$(( now_epoch - local_mtime ))
    if [ "$age" -gt 60 ]; then
      _needs_rebuild=true
    fi
  fi
fi

_snapshot_failed=false
if [ "$_needs_rebuild" = true ]; then
  if [[ -x "$_SNAPSHOT_SCRIPT" ]] || [[ -f "$_SNAPSHOT_SCRIPT" ]]; then
    if ! GAIA_SNAPSHOT_HOOK_DISABLE="${GAIA_SNAPSHOT_HOOK_DISABLE:-}" \
          bash "$_SNAPSHOT_SCRIPT" 2>/dev/null; then
      _snapshot_failed=true
    fi
  else
    _snapshot_failed=true
  fi
fi

# When the snapshot was attempted and failed, always fall back.
if [ "$_snapshot_failed" = true ]; then
  log "notice: cache unavailable, showing basic dashboard"
  _render_fallback_dashboard
  exit 0
fi

# Re-check cache validity after potential rebuild.
if ! _cache_is_valid "$CACHE_FILE"; then
  log "notice: cache unavailable after rebuild, showing basic dashboard"
  _render_fallback_dashboard
  exit 0
fi

_render_cache_dashboard "$CACHE_FILE"
exit 0
