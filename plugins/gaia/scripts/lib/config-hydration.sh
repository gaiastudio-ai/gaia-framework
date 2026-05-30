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
#   CONFIG_HYDRATION_TARGET       — path to project-config.yaml. Canonical
#                                   default: ${project_root}/.gaia/config/project-config.yaml
#                                   (ADR-111). Legacy fallback: ${project_root}/config/project-config.yaml
#                                   when only the legacy tree exists (pre-migration installs).
#   CONFIG_HYDRATION_LOCK_PATH    — path to lock file. Resolved as dirname($target)/.config-hydration.lock,
#                                   so it follows the same canonical-first resolution as the target.
#   CONFIG_HYDRATION_LOCK_TIMEOUT — seconds (default 30)
#   CLAUDE_PLUGIN_ROOT            — plugin root (used to resolve config-yaml-editor.sh)

# Library guard — prevent double-sourcing side effects (AC1, Task 1.2).
if [ "${_CONFIG_HYDRATION_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_CONFIG_HYDRATION_LOADED=1

# E97-S1 / ADR-111: source lib/gaia-paths.sh so $GAIA_CONFIG_DIR is available
# for canonical-first target resolution. The helper is idempotent via its own
# source guard (_GAIA_PATHS_LOADED), so re-sourcing is a no-op.
# Resolve relative to this script's location; gaia-paths.sh lives in the same
# scripts/lib/ directory.
_CH_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" 2>/dev/null && pwd )"
if [ -r "${_CH_LIB_DIR}/gaia-paths.sh" ]; then
  # shellcheck source=/dev/null
  . "${_CH_LIB_DIR}/gaia-paths.sh" || true
fi

# ---- Constants -------------------------------------------------------------

# Curated section allowlist + managed-elsewhere classification (E85-S11 / AF-2026-05-13-2).
#
# Background:
#   Original E85-S1 allowlist contained 7 entries; reconciler at gaia-reconcile-v2.sh:307-316
#   downgraded "not in allowlist" rc=2 to WARN+continue+exit-0, silently skipping 33 of 40
#   schema sections on v2-to-v2 reconciliation. Reproduced 2026-05-13 on plugin 1.150.0;
#   AF-2026-05-13-2 is the cascade. Pattern is "skill claims success while critical step
#   was silently skipped" — sibling defect to AI-2026-05-09-12.
#
# Contract (ADR-098 + ADR-101 §6 + ADR-096):
#   - Every schema property MUST be in exactly one of:
#       (i)  _CONFIG_HYDRATION_ALLOWLIST       — auto-hydratable; reconciler invokes
#                                                config_hydrate_section to add an empty stub.
#       (ii) _CONFIG_HYDRATION_MANAGED_ELSEWHERE — known to be written by /gaia-init,
#                                                  schema discovery, or another helper; the
#                                                  reconciler MUST skip them WITHOUT raising
#                                                  the AC5 hard-error (exit 5).
#       (iii) `x-no-auto-hydration: true` in the schema property — optional escape hatch
#                                                                  for future schema additions.
#   - Forward + reverse invariants are pinned by bats tests in
#     tests/config-hydration-allowlist-invariant.bats (TC-RV2-45, TC-RV2-46).
#   - `project_shape` (legacy E85-S1 entry) was in the allowlist but NOT in schema v2.0.0
#     (Val F4 dead-code drift on 2026-05-13). Removed in this story.
_CONFIG_HYDRATION_ALLOWLIST=(
  # Configuration sections (auto-hydratable as empty stubs).
  project_name
  ci_cd
  testing
  test_execution_bridge
  test_execution
  sprint
  review_gate
  team_conventions
  agent_customizations
  dev_story
  compliance
  tools
  severity
  gates
  stacks
  cross_service_tests
  environments
  ci_platform
  platforms
  sizing_map
  device_targets
  distribution
  health_check
  val_integration
)

# Sections that are intentionally NOT auto-hydrated. The reconciler MUST recognize these
# and skip them without triggering the AC5 hard-error path. Forward + reverse invariants:
# every schema property is in EXACTLY ONE of allowlist, managed-elsewhere, or x-no-auto-hydration.
#
#   - Computed path/identity (5):        written by resolve-config.sh at runtime.
#   - framework_version (1):             written by gaia-reconcile-v2.sh apply at
#                                        end of successful reconciliation
#                                        (E85-S13 / D8 / AF-2026-05-14-3). Per Val F-2
#                                        on 2026-05-14, resolve-config.sh ONLY READS
#                                        this value at lines ~988-1007 for drift
#                                        detection; it does not write.
#   - date (1):                          written by resolve-config.sh at runtime.
#   - State-machine (2):                 written by config-hydration.sh advance-phase
#                                        and schema discovery.
#   - User-identity (3):                 written by /gaia-init Phase 0 / --full.
#   - Artifact-bucket paths (4):         written by resolve-config.sh and /gaia-init.
#                                        Val F2 on 2026-05-13 surfaced these as a
#                                        reverse-invariant gap.
_CONFIG_HYDRATION_MANAGED_ELSEWHERE=(
  # Computed path/identity (5).
  project_root
  project_path
  memory_path
  checkpoint_path
  installed_path
  # framework_version (1) — written by gaia-reconcile-v2.sh apply (E85-S13).
  framework_version
  # date (1) — written by resolve-config.sh at runtime.
  date
  # State-machine (2).
  config_phase
  schema_version
  # User-identity (3).
  user_name
  communication_language
  project_kind
  # Artifact-bucket paths (4).
  planning_artifacts
  implementation_artifacts
  test_artifacts
  creative_artifacts
  # Legacy / back-compat (1): retained in managed-elsewhere so reconciler
  # tests that still declare `project_shape` in the schema fixture don't
  # trip the AC5 hard-error path. Removed from allowlist (Val F4) but
  # classified here for forward-compat with any caller that still
  # references it.
  project_shape
  # E93-S2 (1): sprint_review is human-managed exclusively via
  # /gaia-config-sprint-review; never auto-hydrated by the reconciler.
  sprint_review
  # E103-S5 (ADR-120, 1): lifecycle is operator-managed (lifecycle.strict_mode
  # default-ON per ADR-120). Never auto-hydrated by the reconciler — operators
  # opt in/out explicitly. The schema property also carries
  # `x-no-auto-hydration: true` as defense-in-depth documentation.
  lifecycle
  # AF-2026-05-30-2 / Test10 F-06 (1): brownfield is operator-managed via
  # /gaia-config-brownfield and feeds /gaia-doctor's tier classifier. Never
  # auto-hydrated by the reconciler. The schema property carries
  # `x-no-auto-hydration: true` as defense-in-depth documentation; this
  # entry registers it for the reconciler's managed-elsewhere check.
  brownfield
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
# config_hydration_resolve_target — E97-S1 / ADR-111 / FR-511.
# Return the resolved project-config.yaml target path on stdout. Same
# resolution order as the in-function target lookup: CONFIG_HYDRATION_TARGET
# override > $GAIA_CONFIG_DIR/project-config.yaml > $CLAUDE_PLUGIN_ROOT-derived
# legacy > "config/project-config.yaml" relative fallback. Exposed so callers
# and tests can inspect resolution without invoking the full hydrate pipeline.
config_hydration_resolve_target() {
  local target="${CONFIG_HYDRATION_TARGET:-}"
  if [ -z "$target" ]; then
    # Tier 1: GAIA_CONFIG_DIR override (E97-S1).
    if [ -n "${GAIA_CONFIG_DIR:-}" ] && [ -f "${GAIA_CONFIG_DIR}/project-config.yaml" ]; then
      target="${GAIA_CONFIG_DIR}/project-config.yaml"
    fi
    # Tier 2 (AF-2026-05-22-5): CLAUDE_PROJECT_ROOT canonical .gaia/config/ —
    # this is where /gaia-init actually writes post-ADR-111. Previously the
    # resolver fell straight through to the legacy config/ path, causing
    # /gaia-create-arch's hydrate-config step to skip with "no
    # config/project-config.yaml found" even on greenfield projects that
    # had a properly initialized .gaia/config/project-config.yaml.
    if [ -z "$target" ] && [ -n "${CLAUDE_PROJECT_ROOT:-}" ] \
       && [ -f "${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml" ]; then
      target="${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml"
    fi
    # Tier 3: CLAUDE_PLUGIN_ROOT-derived (rare — used by some test harnesses).
    if [ -z "$target" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
      local pr
      pr="$(cd "${CLAUDE_PLUGIN_ROOT}/../../.." 2>/dev/null && pwd || true)"
      if [ -n "$pr" ] && [ -f "${pr}/.gaia/config/project-config.yaml" ]; then
        target="${pr}/.gaia/config/project-config.yaml"
      elif [ -n "$pr" ]; then
        target="${pr}/config/project-config.yaml"
      fi
    fi
    # Tier 4: CLAUDE_PROJECT_ROOT legacy.
    if [ -z "$target" ] && [ -n "${CLAUDE_PROJECT_ROOT:-}" ]; then
      target="${CLAUDE_PROJECT_ROOT}/config/project-config.yaml"
    fi
    # Tier 5: relative-canonical (post-ADR-111 default for CWD-rooted runs).
    if [ -z "$target" ] && [ -f ".gaia/config/project-config.yaml" ]; then
      target=".gaia/config/project-config.yaml"
    fi
    # Tier 6: relative-legacy fallback (pre-migration).
    [ -z "$target" ] && target="config/project-config.yaml"
  fi
  printf '%s\n' "$target"
}

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

  # Target config path. E97-S1 / ADR-111: prefer .gaia/config/ (canonical)
  # over legacy config/ (pre-migration fallback). The lib/gaia-paths.sh helper
  # sourced at the top sets GAIA_CONFIG_DIR; if that directory contains
  # project-config.yaml, use it. Otherwise fall through to the legacy lookup.
  local target="${CONFIG_HYDRATION_TARGET:-}"
  if [ -z "$target" ]; then
    # Canonical-first: .gaia/config/project-config.yaml.
    if [ -n "${GAIA_CONFIG_DIR:-}" ] && [ -f "${GAIA_CONFIG_DIR}/project-config.yaml" ]; then
      target="${GAIA_CONFIG_DIR}/project-config.yaml"
    fi
    # Legacy fallback (retained verbatim for back-compat with pre-migration installs).
    if [ -z "$target" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
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

# ---- advance-phase sub-command (E85-S11 / AF-2026-05-13-2 sub-fix c) -----
#
# Adds a small CLI dispatch for the partial→full transition that the reconciler
# (gaia-reconcile-v2.sh) invokes after a successful section-hydration pass.
# Preserves ADR-101 §6: the reconciler dispatches to this helper; the helper
# is the sole writer of `config_phase`. ADR-096 monotonicity is enforced —
# backward transitions return rc=3.
#
# Usage (direct invocation, AF-2026-05-13-2):
#   bash config-hydration.sh advance-phase --to <minimal|partial|full> [--config <path>]
#
# Exit codes:
#   0 — success (advancement applied or already at target; idempotent)
#   2 — config file missing
#   3 — backward transition refused (full→partial, full→minimal, partial→minimal)
#       or unknown target value
#   4 — usage error / missing required flag
#
# Default --config: config/project-config.yaml (relative to CWD).
_ch_advance_phase() {
  local target_phase="" config_path="config/project-config.yaml"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) target_phase="${2:-}"; shift 2 ;;
      --config) config_path="${2:-}"; shift 2 ;;
      *) printf 'config-hydration.sh advance-phase: unknown arg: %s\n' "$1" >&2; return 4 ;;
    esac
  done

  case "$target_phase" in
    minimal|partial|full) ;;
    "") printf 'config-hydration.sh advance-phase: --to <phase> is required\n' >&2; return 4 ;;
    *) printf 'config-hydration.sh advance-phase: invalid target phase: %s\n' "$target_phase" >&2; return 3 ;;
  esac

  if [ ! -f "$config_path" ]; then
    printf 'config-hydration.sh advance-phase: config file not found: %s\n' "$config_path" >&2
    return 2
  fi

  # Read current phase (absence-means-full per ADR-097).
  local current_phase
  current_phase="$(grep -E '^config_phase:[[:space:]]*' "$config_path" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1)"
  [ -z "$current_phase" ] && current_phase="full"

  # Ordinal phase: minimal=0, partial=1, full=2. Backward transitions refused.
  local current_ord target_ord
  case "$current_phase" in
    minimal) current_ord=0 ;;
    partial) current_ord=1 ;;
    full)    current_ord=2 ;;
    *) printf 'config-hydration.sh advance-phase: unknown current config_phase value: %s\n' "$current_phase" >&2; return 3 ;;
  esac
  case "$target_phase" in
    minimal) target_ord=0 ;;
    partial) target_ord=1 ;;
    full)    target_ord=2 ;;
  esac

  if [ "$target_ord" -lt "$current_ord" ]; then
    printf 'config-hydration.sh advance-phase: error: backward config_phase transition (%s→%s) forbidden per ADR-096 monotonicity\n' \
      "$current_phase" "$target_phase" >&2
    return 3
  fi

  # Idempotent — already at target.
  if [ "$target_ord" -eq "$current_ord" ]; then
    return 0
  fi

  _ch_write_phase "$config_path" "$target_phase"
  return 0
}

# ---- Dual-mode dispatch (E85-S11 / Val F1) -------------------------------
#
# The original E85-S1 guard at this position exited 1 on direct invocation,
# preserving the "sourced library only" contract. AF-2026-05-13-2 sub-fix (c)
# adds a small CLI surface (`advance-phase`) that needs direct invocation.
#
# Dual-mode dispatch:
#   - Sourced (BASH_SOURCE[0] != $0): no-op return; library is available.
#   - Direct invocation with NO args: refuse with usage message (preserves the
#     original library-only invariant for accidental `bash config-hydration.sh`).
#   - Direct invocation with args:    route to sub-command handler.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  if [ $# -eq 0 ]; then
    printf 'config-hydration.sh: this file is a sourced library; direct invocation requires a sub-command.\n' >&2
    printf 'usage (sourced): source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh"\n' >&2
    printf 'usage (direct):  bash config-hydration.sh advance-phase --to <minimal|partial|full> [--config <path>]\n' >&2
    exit 1
  fi
  case "$1" in
    advance-phase) shift; _ch_advance_phase "$@"; exit $? ;;
    *)
      printf 'config-hydration.sh: unknown sub-command: %s\n' "$1" >&2
      printf 'available sub-commands: advance-phase\n' >&2
      exit 4
      ;;
  esac
fi
