#!/usr/bin/env bash
# lifecycle-overrides.sh — Reader/writer helpers for the ADR-120
# `.gaia/state/lifecycle-overrides.yaml` audit trail of bypassed MANDATORY
# lifecycle skills.
#
# Three exported functions:
#   lifecycle_read_bypasses [--sprint-id <id>]
#       Reads the file (or returns {bypasses: []} on absent), optionally
#       filters by sprint_id, emits JSON to stdout.
#
#   lifecycle_append_bypass --skill <s> --reason "<text>" --sprint-id <id>
#       Validates the candidate against the JSON schema, computes
#       recorded_at + recorded_by, appends atomically under flock.
#
#   lifecycle_list_bypasses_for_sprint <sprint_id> [--format table|json]
#       Filtered read, table or JSON output.
#
# Requires: yq, jq. ajv-cli is NOT required — schema validation is
# performed inline via jq against the JSON schema's structural fields.
#
# Conforms to FR-536, ADR-120, ADR-111 (canonical .gaia/state/ path).

set -euo pipefail

# Resolve canonical paths.
LIFECYCLE_OVERRIDES_FILE_DEFAULT=".gaia/state/lifecycle-overrides.yaml"
LIFECYCLE_OVERRIDES_LOCK_DEFAULT=".gaia/state/lifecycle-overrides.yaml.lock"

# Allow callers to override paths via env var (matches sprint-state.sh pattern).
_lifecycle_overrides_file() {
  printf '%s\n' "${LIFECYCLE_OVERRIDES_FILE:-${LIFECYCLE_OVERRIDES_FILE_DEFAULT}}"
}

_lifecycle_overrides_lock() {
  printf '%s\n' "${LIFECYCLE_OVERRIDES_LOCK:-${LIFECYCLE_OVERRIDES_LOCK_DEFAULT}}"
}

_lifecycle_bootstrap_if_absent() {
  local f
  f="$(_lifecycle_overrides_file)"
  if [ ! -f "$f" ]; then
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "bypasses: []" > "$f"
  fi
}

# ---- Public: read ----------------------------------------------------------
lifecycle_read_bypasses() {
  local sprint_id_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint-id) sprint_id_filter="$2"; shift 2 ;;
      *) printf 'lifecycle_read_bypasses: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
  done
  local f
  f="$(_lifecycle_overrides_file)"
  if [ ! -f "$f" ]; then
    printf '{"bypasses":[]}\n'
    return 0
  fi
  local payload
  payload="$(yq -o=json eval '.' "$f" 2>/dev/null || printf '{"bypasses":[]}')"
  if [ -n "$sprint_id_filter" ]; then
    printf '%s' "$payload" | jq --arg sid "$sprint_id_filter" '{bypasses: [.bypasses[] | select(.sprint_id == $sid)]}'
  else
    printf '%s\n' "$payload"
  fi
}

# ---- Public: append --------------------------------------------------------
lifecycle_append_bypass() {
  local skill="" reason="" sprint_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill) skill="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --sprint-id) sprint_id="$2"; shift 2 ;;
      *) printf 'lifecycle_append_bypass: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
  done

  # Schema validation — inline (no ajv-cli dependency).
  if [ -z "$skill" ]; then
    printf 'bypass record invalid: --skill is required\n' >&2
    return 1
  fi
  if [ -z "$reason" ]; then
    printf 'bypass record invalid: --reason is required (no anonymous bypasses)\n' >&2
    return 1
  fi
  local reason_len="${#reason}"
  if [ "$reason_len" -lt 10 ]; then
    printf 'bypass record invalid: --reason must be at least 10 chars (got %d)\n' "$reason_len" >&2
    return 1
  fi
  if [ "$reason_len" -gt 500 ]; then
    printf 'bypass record invalid: --reason must be at most 500 chars (got %d)\n' "$reason_len" >&2
    return 1
  fi
  if [ -z "$sprint_id" ]; then
    printf 'bypass record invalid: --sprint-id is required\n' >&2
    return 1
  fi
  if ! printf '%s' "$sprint_id" | grep -Eq '^sprint-[0-9]+$'; then
    printf 'bypass record invalid: --sprint-id must match ^sprint-[0-9]+$ (got: %s)\n' "$sprint_id" >&2
    return 1
  fi

  local recorded_at recorded_by
  recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  recorded_by="$(git config user.name 2>/dev/null || true)"
  if [ -z "$recorded_by" ]; then
    recorded_by="${USER:-unknown}"
  fi

  local f lock
  f="$(_lifecycle_overrides_file)"
  lock="$(_lifecycle_overrides_lock)"
  mkdir -p "$(dirname "$f")"

  # Flock + atomic tempfile + mv. Use flock(1) when available; fall back to
  # mkdir-based lock when not.
  local tmp
  tmp="$(mktemp "$(dirname "$f")/.lifecycle-overrides.tmp.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  _do_append() {
    _lifecycle_bootstrap_if_absent
    # Compose entry as JSON; merge into existing list with yq.
    local entry_json
    entry_json="$(jq -n --arg s "$skill" --arg r "$reason" --arg at "$recorded_at" --arg by "$recorded_by" --arg sid "$sprint_id" \
      '{skill:$s, reason:$r, recorded_at:$at, recorded_by:$by, sprint_id:$sid}')"
    yq -i ".bypasses += [$entry_json]" "$f"
  }

  if command -v flock >/dev/null 2>&1; then
    # Linux flock semantics.
    exec {LOCK_FD}>"$lock"
    flock -w 5 "$LOCK_FD" || { printf 'lifecycle_append_bypass: failed to acquire lock at %s\n' "$lock" >&2; return 1; }
    _do_append
    exec {LOCK_FD}>&-
  else
    # macOS lacks flock by default. Use mkdir-based lock (atomic per POSIX).
    local lockdir="${lock}.d"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      waited=$((waited + 1))
      if [ "$waited" -ge 50 ]; then
        printf 'lifecycle_append_bypass: failed to acquire lock at %s after 5s\n' "$lockdir" >&2
        return 1
      fi
      sleep 0.1
    done
    trap 'rmdir "'"$lockdir"'" 2>/dev/null || true; rm -f "'"$tmp"'"' RETURN
    _do_append
  fi
}

# ---- Public: list ----------------------------------------------------------
lifecycle_list_bypasses_for_sprint() {
  local sprint_id="${1:-}"
  shift || true
  local format="table"
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) format="$2"; shift 2 ;;
      *) printf 'lifecycle_list_bypasses_for_sprint: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
  done
  if [ -z "$sprint_id" ]; then
    printf 'lifecycle_list_bypasses_for_sprint: sprint_id is required\n' >&2
    return 1
  fi

  local payload
  payload="$(lifecycle_read_bypasses --sprint-id "$sprint_id")"
  local count
  count="$(printf '%s' "$payload" | jq '.bypasses | length')"
  if [ "$format" = "json" ]; then
    printf '%s\n' "$payload"
    return 0
  fi

  # Table format
  if [ "$count" -eq 0 ]; then
    printf 'No bypasses recorded for %s.\n' "$sprint_id"
    return 0
  fi
  printf '%-30s | %-50s | %-22s | %s\n' "Skill" "Reason" "Recorded At" "Recorded By"
  printf '%s\n' "$(printf '%.0s-' {1..120})"
  printf '%s' "$payload" | jq -r '.bypasses[] | "\(.skill)\t\(.reason)\t\(.recorded_at)\t\(.recorded_by)"' | \
    while IFS=$'\t' read -r skill reason recorded_at recorded_by; do
      printf '%-30s | %-50s | %-22s | %s\n' "$skill" "$reason" "$recorded_at" "$recorded_by"
    done
}

# If sourced, expose functions only. If run directly, dispatch via first arg.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    read) lifecycle_read_bypasses "$@" ;;
    append) lifecycle_append_bypass "$@" ;;
    list) lifecycle_list_bypasses_for_sprint "$@" ;;
    *) printf 'usage: %s {read|append|list} ...\n' "$0" >&2; exit 1 ;;
  esac
fi
