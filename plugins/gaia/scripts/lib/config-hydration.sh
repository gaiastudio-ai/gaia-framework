#!/usr/bin/env bash
# config-hydration.sh — shared library for hydrating sections of project-config.yaml.
#
# Story: E85-S1 — Shared config-hydration.sh helper.
# ADRs:  ADR-098 (Helper Contract), ADR-096 (config_phase state machine),
#        ADR-097 (Absence-over-sentinel), ADR-044 (Section-scoped editors),
#        ADR-042 (Scripts-over-LLM).
#
# Usage (sourced library):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
#   config_hydrate_section <section_path> <yaml_fragment_file>
#
# The function:
#   - Validates the section against a hardcoded allowlist (SR-47 / T-INIT-6).
#   - Acquires an exclusive lock on `config/.config-hydration.lock` with a
#     30-second timeout, using flock when available and falling back to
#     mkdir-based mutex on systems without flock (e.g., stock macOS).
#   - Reads the current `config_phase` (treats absent as `full` per ADR-097).
#   - Detects existing section presence and delegates the YAML write to
#     `config-yaml-editor.sh insert|replace`, preserving comments (ADR-044).
#   - Appends `# hydrated by <caller> at <ISO-8601>` above the hydrated section.
#   - Advances `config_phase` monotonically forward (minimal -> partial only).
#     Never writes `config_phase: full` — that transition belongs to
#     `validate-project-config.sh` (E85-S4).
#   - Logs sha256 of project-config.yaml before/after the write.
#
# Environment overrides (mostly for tests):
#   CONFIG_HYDRATION_TARGET       — path to project-config.yaml (default: project_root/config/project-config.yaml)
#   CONFIG_HYDRATION_LOCK_PATH    — path to lock file (default: project_root/config/.config-hydration.lock)
#   CONFIG_HYDRATION_LOCK_TIMEOUT — seconds (default 30)
#   CLAUDE_PLUGIN_ROOT            — plugin root (used to resolve config-yaml-editor.sh)

# Library guard — prevent double-sourcing side effects (AC1, Task 1.2).
if [ "${_CONFIG_HYDRATION_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_CONFIG_HYDRATION_LOADED=1

# ---- Constants -------------------------------------------------------------

# Hardcoded section allowlist (SR-47, Dev Notes). NOT read from SKILL.md
# frontmatter in this story — that is future work per T-INIT-6 mitigation (a).
_CONFIG_HYDRATION_ALLOWLIST=(
  project_name
  project_shape
  stacks
  platforms
  environments
  ci_cd
  compliance
)

# ---- Logging helpers ------------------------------------------------------

# All log levels emit to stderr by default. Set CONFIG_HYDRATION_LOG_STDOUT=1
# to mirror notices and warnings to stdout as well (used by tests that capture
# `bash -c "... 2>&1"` output where stderr ordering differs between Linux and
# macOS bash builds).
_ch_log() { printf 'config-hydration: %s\n' "$*" >&2; }
_ch_warn() {
  printf 'config-hydration: WARN %s\n' "$*" >&2
  [ "${CONFIG_HYDRATION_LOG_STDOUT:-1}" = "1" ] && printf 'config-hydration: WARN %s\n' "$*"
  return 0
}
_ch_critical() {
  printf 'config-hydration: CRITICAL %s\n' "$*" >&2
  [ "${CONFIG_HYDRATION_LOG_STDOUT:-1}" = "1" ] && printf 'config-hydration: CRITICAL %s\n' "$*"
  return 0
}
_ch_notice() {
  printf 'config-hydration: NOTICE %s\n' "$*" >&2
  [ "${CONFIG_HYDRATION_LOG_STDOUT:-1}" = "1" ] && printf 'config-hydration: NOTICE %s\n' "$*"
  return 0
}

_ch_iso8601() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Pick the available sha256 binary at runtime.
_ch_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# Determine the caller for audit logging. Uses FUNCNAME stack if available,
# otherwise falls back to $0 basename.
_ch_caller() {
  if [ "${#FUNCNAME[@]}" -gt 1 ]; then
    # FUNCNAME[0]=this fn, [1]=config_hydrate_section, [2]=actual caller.
    local idx
    idx=$(( ${#FUNCNAME[@]} - 1 ))
    [ "$idx" -lt 2 ] && idx=2
    if [ "$idx" -lt "${#FUNCNAME[@]}" ]; then
      local c="${FUNCNAME[$idx]}"
      [ -n "$c" ] && [ "$c" != "main" ] && [ "$c" != "source" ] && {
        printf '%s\n' "$c"
        return 0
      }
    fi
  fi
  basename "${0:-bash}"
}

# Resolve the path to config-yaml-editor.sh (ADR-044 delegation target).
_ch_editor() {
  local editor=""
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh" ]; then
    editor="${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh"
  else
    # Fallback: locate relative to this library's directory.
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    editor="${lib_dir}/../config-yaml-editor.sh"
  fi
  printf '%s\n' "$editor"
}

# Read the current config_phase from a config file. Echoes the phase string;
# echoes the literal "ABSENT" when the field is missing entirely (ADR-097).
_ch_read_phase() {
  local file="$1"
  local line
  line="$(grep -E '^config_phase:' "$file" 2>/dev/null | head -1 || true)"
  if [ -z "$line" ]; then
    printf 'ABSENT\n'
    return 0
  fi
  # Strip "config_phase:" prefix, surrounding whitespace, and quotes.
  printf '%s\n' "$line" \
    | sed -E 's/^config_phase:[[:space:]]*//' \
    | sed -E 's/^[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# Write a phase via the section editor. Builds a minimal fragment.
_ch_write_phase() {
  local file="$1" new_phase="$2"
  local editor; editor="$(_ch_editor)"
  local tmp
  tmp="$(mktemp)"
  printf 'config_phase: %s\n' "$new_phase" > "$tmp"
  if grep -q '^config_phase:' "$file"; then
    "$editor" replace "$file" config_phase "$tmp" >/dev/null
  else
    "$editor" insert "$file" config_phase "$tmp" >/dev/null
  fi
  rm -f "$tmp"
}

# ---- Locking -------------------------------------------------------------

# Acquire an exclusive lock. Two paths: flock when available, mkdir mutex
# otherwise. Returns 0 on acquire, 1 on timeout. Sets _ch_lock_mode.
_ch_acquire_lock() {
  local lock_path="$1" timeout="$2"
  _ch_lock_mode=""

  if command -v flock >/dev/null 2>&1; then
    # File-descriptor flock pattern. The lock releases automatically when
    # fd 9 is closed (handled by _ch_release_lock).
    exec 9>"$lock_path" 2>/dev/null || return 1
    if flock -x -w "$timeout" 9 2>/dev/null; then
      _ch_lock_mode="flock"
      return 0
    fi
    exec 9>&- 2>/dev/null || true
    return 1
  fi

  # mkdir-based fallback (atomic on POSIX filesystems).
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    if mkdir "$lock_path" 2>/dev/null; then
      printf '%d\n' "$$" > "$lock_path/pid" 2>/dev/null || true
      _ch_lock_mode="mkdir"
      return 0
    fi
    # Stale-lock recovery — clear if holder PID is gone.
    if [ -f "$lock_path/pid" ]; then
      local holder
      holder="$(cat "$lock_path/pid" 2>/dev/null || echo '')"
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$lock_path" 2>/dev/null || true
        continue
      fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

_ch_release_lock() {
  local lock_path="$1"
  case "${_ch_lock_mode:-}" in
    flock)
      exec 9>&- 2>/dev/null || true
      rm -f "$lock_path" 2>/dev/null || true
      ;;
    mkdir)
      rm -rf "$lock_path" 2>/dev/null || true
      ;;
  esac
  _ch_lock_mode=""
}

# Identify a lock holder PID, best-effort. Returns empty string when unknown.
_ch_lock_holder() {
  local lock_path="$1"
  if [ -d "$lock_path" ] && [ -f "$lock_path/pid" ]; then
    cat "$lock_path/pid" 2>/dev/null
    return 0
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "$lock_path" 2>/dev/null | tr -s ' '
  fi
}

# ---- Allowlist check ------------------------------------------------------

_ch_in_allowlist() {
  local root="$1" entry
  for entry in "${_CONFIG_HYDRATION_ALLOWLIST[@]}"; do
    [ "$root" = "$entry" ] && return 0
  done
  return 1
}

# ---- Audit comment insertion ---------------------------------------------

# Insert `# hydrated by <caller> at <iso8601>` immediately above the section
# header line in `file`. Uses awk for portability (BSD sed -i differs from GNU).
_ch_insert_audit_comment() {
  local file="$1" section="$2" caller="$3" ts="$4"
  local comment="# hydrated by ${caller} at ${ts}"
  local tmp
  tmp="$(mktemp)"
  awk -v section="$section" -v comment="$comment" '
    BEGIN { inserted = 0 }
    {
      if (!inserted && $0 ~ "^" section ":") {
        print comment
        inserted = 1
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---- Public API -----------------------------------------------------------

# config_hydrate_section <section_path> <yaml_fragment_file>
#
# Returns:
#   0  on successful hydration
#   1  generic failure (missing file, IO error, etc.)
#   2  section not in allowlist
#   3  lock timeout
config_hydrate_section() {
  if [ "$#" -lt 2 ]; then
    _ch_critical "usage: config_hydrate_section <section_path> <yaml_fragment_file>"
    return 1
  fi

  local section_path="$1"
  local fragment_file="$2"
  local section_root="${section_path%%.*}"

  # Allowlist check (AC4 / SR-47 / T-INIT-6).
  if ! _ch_in_allowlist "$section_root"; then
    _ch_critical "section '$section_root' not in allowlist; caller=$(_ch_caller)"
    return 2
  fi

  # Fragment file checks.
  if [ ! -f "$fragment_file" ]; then
    _ch_critical "fragment file not found: $fragment_file"
    return 1
  fi
  if [ ! -s "$fragment_file" ]; then
    _ch_critical "empty payload: fragment file is 0 bytes ($fragment_file)"
    return 1
  fi

  # Target config path.
  local target="${CONFIG_HYDRATION_TARGET:-}"
  if [ -z "$target" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
      # Resolve project root by walking up from CLAUDE_PLUGIN_ROOT.
      local pr
      pr="$(cd "${CLAUDE_PLUGIN_ROOT}/../../.." 2>/dev/null && pwd || true)"
      [ -n "$pr" ] && target="${pr}/config/project-config.yaml"
    fi
    [ -z "$target" ] && target="config/project-config.yaml"
  fi

  if [ ! -f "$target" ]; then
    _ch_critical "config file not found: $target (target missing)"
    return 1
  fi

  # Lock file path.
  local lock_path="${CONFIG_HYDRATION_LOCK_PATH:-}"
  if [ -z "$lock_path" ]; then
    lock_path="$(dirname "$target")/.config-hydration.lock"
  fi
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  local timeout="${CONFIG_HYDRATION_LOCK_TIMEOUT:-30}"

  # Acquire lock (AC3 / AC11 / SR-43).
  if ! _ch_acquire_lock "$lock_path" "$timeout"; then
    local holder
    holder="$(_ch_lock_holder "$lock_path")"
    _ch_critical "lock timeout after ${timeout}s on $lock_path; check for stale locks${holder:+; holder pid=$holder}"
    return 3
  fi

  # Run the critical section inside an inner function so we can release the
  # lock exactly once and propagate the inner return code. (bash 3.2 RETURN
  # traps mask return codes; an inline release + saved-rc is more portable.)
  _config_hydrate_section_locked "$section_root" "$section_path" "$target" "$fragment_file"
  local _rc=$?
  _ch_release_lock "$lock_path"
  return "$_rc"
}

# Internal: critical-section body. Called by config_hydrate_section with the
# lock already held. Returns the same exit codes as the public API minus 3.
_config_hydrate_section_locked() {
  local section_root="$1"
  local section_path="$2"
  local target="$3"
  local fragment_file="$4"

  # Compute sha256 before (AC5).
  local sha_before; sha_before="$(_ch_sha256 "$target")"

  # Read current phase (AC6/AC7/AC8).
  local current_phase
  current_phase="$(_ch_read_phase "$target")"

  # Detect existing section to choose insert vs replace (AC10).
  local editor; editor="$(_ch_editor)"
  local section_present=0
  if "$editor" extract "$target" "$section_root" >/dev/null 2>&1; then
    section_present=1
  fi

  # Build the section payload. The editor's insert/replace expects the
  # fragment to lead with the section header — verify and patch if missing.
  local payload="$fragment_file"
  local synthesized_payload=""
  if ! head -1 "$fragment_file" | grep -qE "^${section_root}:"; then
    synthesized_payload="$(mktemp)"
    payload="$synthesized_payload"
    {
      printf '%s:\n' "$section_root"
      sed 's/^/  /' "$fragment_file"
    } > "$payload"
  fi

  # Perform the write (AC9 — delegated to ADR-044 editor).
  if [ "$section_present" -eq 1 ]; then
    _ch_notice "section '$section_root' already present — overwriting"
    if ! "$editor" replace "$target" "$section_root" "$payload" >/dev/null; then
      _ch_critical "editor replace failed for section '$section_root'"
      [ -n "$synthesized_payload" ] && rm -f "$synthesized_payload"
      return 1
    fi
  else
    if ! "$editor" insert "$target" "$section_root" "$payload" >/dev/null; then
      _ch_critical "editor insert failed for section '$section_root'"
      [ -n "$synthesized_payload" ] && rm -f "$synthesized_payload"
      return 1
    fi
  fi
  [ -n "$synthesized_payload" ] && rm -f "$synthesized_payload"

  # Insert audit comment (AC5).
  local caller; caller="$(_ch_caller)"
  local ts; ts="$(_ch_iso8601)"
  _ch_insert_audit_comment "$target" "$section_root" "$caller" "$ts"

  # Apply config_phase state machine (AC6/AC7/AC8).
  case "$current_phase" in
    minimal)
      _ch_write_phase "$target" partial
      ;;
    partial|full)
      # partial: idempotent hold. full: terminal.
      :
      ;;
    ABSENT)
      _ch_warn "hydrating a full config (no config_phase field) — this is unusual"
      ;;
    *)
      _ch_warn "unknown config_phase value '${current_phase}' — leaving unchanged"
      ;;
  esac

  # Compute sha256 after, log audit trail (AC5).
  local sha_after; sha_after="$(_ch_sha256 "$target")"
  _ch_log "sha256_before=${sha_before} sha256_after=${sha_after} section=${section_path} caller=${caller}"

  return 0
}

# Direct-invocation forbidden — this is a sourced library only (AC1).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  printf 'config-hydration.sh: this file is a sourced library, not an executable.\n' >&2
  printf 'usage: source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh"\n' >&2
  exit 1
fi
