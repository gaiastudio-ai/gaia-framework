#!/usr/bin/env bash
# gaia-reconcile-v2.sh — v2-to-v2 reconciler for project-config.yaml (E85-S8).
#
# Story:  E85-S8
# ADRs:   ADR-101 (v2-to-v2 reconciliation contract),
#         ADR-100 (gaia-migrate.sh return-code semantics),
#         ADR-098 (shared config-hydration.sh + flock contract),
#         ADR-096 (config_phase state machine + schema_version),
#         ADR-044 (YAML comment preservation).
#
# Purpose
# -------
# After a GAIA plugin update, compare the project's existing v2
# `project-config.yaml` against the updated v2 schema and apply
# forward-only, non-destructive reconciliation:
#   - Add missing schema sections via the shared config-hydration helper.
#   - Warn-and-keep retired sections (never delete; inject ADR-101 §3
#     audit comment + emit stderr WARNING).
#   - Treat `config_phase` as read-only — only /gaia-init and hydration
#     triggers (E85-S5, E85-S6) advance it; this reconciler only reads.
#
# Environment variables (AC16)
# ----------------------------
#   MODE          apply | dry-run     Execution mode (default: apply)
#   PROJECT_ROOT  <abs path>          Project root (default: $PWD)
#   DRY_RUN       true | false        Mirrors MODE=dry-run when true (default: false)
#   ASSUME_YES    true | false        Skip interactive prompts (default: false)
#   CLAUDE_PLUGIN_ROOT                Path to the installed plugin (typically
#                                     ~/.claude/plugins/cache/.../gaia/<ver>/)
#
# Exit codes (AC9 / ADR-101 §6)
# -----------------------------
#   0  Success / nothing-to-do / dry-run
#   1  General error / schema not found
#   2  Config missing or unreadable / secret detected
#   3  Schema unreadable / unknown config_phase value
#   4  Schema downgrade detected / lock timeout
#
# Dependencies
# ------------
#   yq       v4.x (YAML parsing)
#   flock    POSIX advisory locking (delegated to config-hydration.sh)
#   sha256   shasum -a 256 (macOS) or sha256sum (Linux) — auto-detected

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-reconcile-v2.sh"

# ---- Logging helpers (audit trail goes to stdout so tests can grep) -------

_grv2_log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*"; }
_grv2_warn() { printf '%s: WARN %s\n' "$SCRIPT_NAME" "$*"; }
_grv2_err() { printf '%s: ERROR %s\n' "$SCRIPT_NAME" "$*" >&2; }
_grv2_info() { printf '%s: INFO %s\n' "$SCRIPT_NAME" "$*"; }
_grv2_audit() { printf '# reconcile-v2 %s\n' "$*"; }

_grv2_iso8601() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# AF-2026-05-13-2 sub-fix (c) — dispatch partial→full advancement to the helper.
# Preserves ADR-101 §6: reconciler is the CALLER, helper is the WRITER.
# Idempotent and silent when phase is not `partial`. Used by BOTH the
# no-diff path (eq branch) and the post-hydration path (lt branch).
_grv2_dispatch_phase_advance() {
  local config_file="$1" context_label="$2"
  local helper="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/config-hydration.sh"
  [ -f "$helper" ] || return 0  # silent — helper-not-found is handled earlier in main flow

  local phase_now
  phase_now="$(yq '.config_phase // "full"' "$config_file" 2>/dev/null | tr -d '"')"
  [ "$phase_now" = "partial" ] || return 0  # nothing to do

  if bash "$helper" advance-phase --to full --config "$config_file" 2>/dev/null; then
    _grv2_log "dispatched config_phase advancement: partial -> full (via config-hydration.sh advance-phase, ${context_label})"
  else
    _grv2_warn "advance-phase --to full returned non-zero; config_phase left at $phase_now"
  fi
}

_grv2_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unknown\n'
  fi
}

# ---- Env-var parsing (AC16) ------------------------------------------------

MODE="${MODE:-apply}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

case "$MODE" in
  dry-run) DRY_RUN="true" ;;
  apply)   : ;;
  *)       _grv2_err "unknown MODE='$MODE' (expected 'apply' or 'dry-run')"; exit 1 ;;
esac

CONFIG_FILE="$PROJECT_ROOT/config/project-config.yaml"

# ---- Schema discovery (AC1 / ADR-101 §1) -----------------------------------

_grv2_discover_schema() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
    && [ -f "${CLAUDE_PLUGIN_ROOT}/schemas/project-config.schema.json" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/schemas/project-config.schema.json"
    return 0
  fi
  local dir="$PROJECT_ROOT"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    local candidate="$dir/gaia-public/plugins/gaia/schemas/project-config.schema.json"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

_grv2_extract_schema_version() {
  local schema_path="$1"
  yq -p=json '.title // ""' "$schema_path" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1
}

_grv2_extract_config_version() {
  local config_path="$1"
  yq '.schema_version // ""' "$config_path" 2>/dev/null \
    | tr -d '"' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_grv2_semver_compare() {
  local a="${1:-0.0.0}" b="${2:-0.0.0}"
  [ -z "$a" ] && a="0.0.0"
  [ -z "$b" ] && b="0.0.0"
  if [ "$a" = "$b" ]; then printf 'eq\n'; return; fi
  local first
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  if [ "$first" = "$a" ]; then printf 'lt\n'; else printf 'gt\n'; fi
}

# ---- Section diff engine (AC3) --------------------------------------------

_grv2_list_config_sections() {
  yq 'keys | .[]' "$1" 2>/dev/null | tr -d '"'
}

_grv2_list_schema_sections() {
  yq -p=json '.properties | keys | .[]' "$1" 2>/dev/null | tr -d '"'
}

_grv2_list_retired_sections() {
  yq -p=json '.properties | to_entries | map(select(.value.deprecated == true)) | .[].key' "$1" 2>/dev/null | tr -d '"'
}

_grv2_in_list() {
  local needle="$1" list="$2"
  printf '%s\n' "$list" | grep -Fxq "$needle"
}

# ---- Secret regex (AC11 / SR-50) ------------------------------------------

_grv2_contains_secret() {
  grep -Eiq '(password|secret|token|api[_-]?key|private[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]+' "$1"
}

# ---- Retired-section comment injection (ADR-101 §3) -----------------------

_grv2_inject_retired_comment() {
  local file="$1" section="$2" schema_ver="$3"
  local marker="# RETIRED in schema v${schema_ver} -- kept for audit per ADR-101 warn-keep"
  local tmp
  tmp="$(mktemp)"
  awk -v section="$section" -v marker="$marker" '
    BEGIN { inserted = 0; prev = "" }
    {
      if (!inserted && $0 ~ "^" section ":") {
        if (prev != marker) {
          print marker
        }
        inserted = 1
      }
      print
      prev = $0
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---- Main -----------------------------------------------------------------

_grv2_main() {
  if [ ! -f "$CONFIG_FILE" ]; then
    _grv2_err "config not found at $CONFIG_FILE"
    exit 2
  fi

  if _grv2_contains_secret "$CONFIG_FILE"; then
    _grv2_err "Potential secret detected in $CONFIG_FILE -- reconciliation aborted"
    exit 2
  fi

  local schema_path
  if ! schema_path="$(_grv2_discover_schema)"; then
    _grv2_err "Schema not found. Expected at \${CLAUDE_PLUGIN_ROOT}/schemas/project-config.schema.json or in-tree at gaia-public/plugins/gaia/schemas/project-config.schema.json. Is the GAIA plugin installed?"
    exit 1
  fi
  if [ ! -r "$schema_path" ]; then
    _grv2_err "Schema at $schema_path is unreadable"
    exit 3
  fi
  _grv2_log "schema: $schema_path"

  local config_ver schema_ver
  config_ver="$(_grv2_extract_config_version "$CONFIG_FILE")"
  schema_ver="$(_grv2_extract_schema_version "$schema_path")"
  if [ -z "$schema_ver" ]; then
    _grv2_err "Schema version could not be extracted from $schema_path (expected vX.Y.Z in title)"
    exit 3
  fi
  _grv2_log "config schema_version=${config_ver:-<absent>} schema title version=$schema_ver"

  local cmp
  cmp="$(_grv2_semver_compare "$config_ver" "$schema_ver")"
  case "$cmp" in
    gt)
      _grv2_err "Schema downgrade detected (config v$config_ver > installed v$schema_ver) -- refusing to reconcile"
      exit 4
      ;;
    eq)
      _grv2_log "Config already at schema v$schema_ver -- nothing to reconcile."
      # AF-2026-05-13-2 sub-fix (c): even when there's no schema diff, the
      # config_phase state machine may still need advancement (partial→full)
      # after all sections are present.
      _grv2_dispatch_phase_advance "$CONFIG_FILE" "no-diff path"
      exit 0
      ;;
    lt)
      _grv2_log "Schema upgrade: ${config_ver:-<absent>} -> $schema_ver"
      ;;
  esac

  local config_sections schema_sections retired_sections
  config_sections="$(_grv2_list_config_sections "$CONFIG_FILE")"
  schema_sections="$(_grv2_list_schema_sections "$schema_path")"
  retired_sections="$(_grv2_list_retired_sections "$schema_path")"

  local missing_sections="" extra_sections="" retired_present=""
  local s
  for s in $schema_sections; do
    if [ -n "$s" ] && ! _grv2_in_list "$s" "$config_sections" \
      && ! _grv2_in_list "$s" "$retired_sections"; then
      missing_sections="${missing_sections}${s}"$'\n'
    fi
  done
  for s in $config_sections; do
    if [ -n "$s" ] && ! _grv2_in_list "$s" "$schema_sections"; then
      extra_sections="${extra_sections}${s}"$'\n'
    fi
  done
  for s in $retired_sections; do
    if [ -n "$s" ] && _grv2_in_list "$s" "$config_sections"; then
      retired_present="${retired_present}${s}"$'\n'
    fi
  done

  if [ "$DRY_RUN" = "true" ]; then
    cat <<DRY
schema_current: "${config_ver:-unknown}"
schema_target: "$schema_ver"
sections_missing:
$(printf '%s' "$missing_sections" | awk 'NF{print "  - " $0}')
sections_retired:
$(printf '%s' "$retired_present" | awk 'NF{print "  - " $0}')
sections_extra:
$(printf '%s' "$extra_sections" | awk 'NF{print "  - " $0}')
actions_planned:
$(printf '%s' "$missing_sections" | awk 'NF{print "  - { action: hydrate, section: " $0 ", detail: \"add via config_hydrate_section\" }"}')
$(printf '%s' "$retired_present" | awk 'NF{print "  - { action: warn-and-keep, section: " $0 ", detail: \"ADR-101 §3 warn-and-keep\" }"}')
DRY
    exit 0
  fi

  local sha_pre backup_path phase_before
  sha_pre="$(_grv2_sha256_file "$CONFIG_FILE")"
  # AC6 — capture config_phase BEFORE any helper-driven advancement so the
  # post-write comparison below detects real advancement.
  phase_before="$(yq '.config_phase // "full"' "$CONFIG_FILE" | tr -d '"')"
  _grv2_audit "pre-write hash: $sha_pre at $(_grv2_iso8601)"
  backup_path="${CONFIG_FILE}.reconcile-v2.bak"
  cp "$CONFIG_FILE" "$backup_path"
  _grv2_audit "pre-write backup created at $backup_path"

  _grv2_audit "flock acquired at $(_grv2_iso8601) pid=$$"

  local helper="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/config-hydration.sh"
  if [ ! -f "$helper" ]; then
    _grv2_err "config-hydration.sh not found at $helper -- cannot reconcile"
    _grv2_audit "flock released at $(_grv2_iso8601) pid=$$"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$helper"
  export CONFIG_HYDRATION_TARGET="$CONFIG_FILE"

  local frag
  for s in $missing_sections; do
    [ -z "$s" ] && continue
    frag="$(mktemp)"
    {
      printf '%s:\n' "$s"
      printf '  # reconciled by gaia-reconcile-v2 at %s\n' "$(_grv2_iso8601)"
    } > "$frag"

    if _grv2_contains_secret "$frag"; then
      _grv2_err "Potential secret detected in section '$s' -- reconciliation aborted"
      rm -f "$frag"
      _grv2_audit "flock released at $(_grv2_iso8601) pid=$$"
      cp "$backup_path" "$CONFIG_FILE"
      exit 2
    fi

    if config_hydrate_section "$s" "$frag"; then
      _grv2_log "hydrated missing section: $s"
    else
      local rc=$?
      case "$rc" in
        2)
          # AF-2026-05-13-2 sub-fix (b) — BREAKING CHANGE.
          # Was: WARN+skip+exit-0 (silently skipped 33/40 sections on 2026-05-13 repro).
          # Now: hard-error+rollback+exit-5, UNLESS the section is in the
          #      _CONFIG_HYDRATION_MANAGED_ELSEWHERE list (AC6 fail-closed scope).
          local in_managed=0
          for me in "${_CONFIG_HYDRATION_MANAGED_ELSEWHERE[@]:-}"; do
            if [ "$me" = "$s" ]; then in_managed=1; break; fi
          done
          if [ "$in_managed" -eq 1 ]; then
            _grv2_log "section '$s' is managed elsewhere (config-hydration.sh) -- skipping cleanly"
            rm -f "$frag"
            continue
          fi
          _grv2_err "section '$s' is declared in schema but not in hydration allowlist or managed-elsewhere set -- aborting (AF-2026-05-13-2 AC5)"
          rm -f "$frag"
          _grv2_audit "flock released at $(_grv2_iso8601) pid=$$"
          # Rollback with explicit error check (Val F4 — never silently leave the
          # config in a half-written state).
          if [ ! -f "$backup_path" ]; then
            _grv2_err "rollback failed: backup file missing at $backup_path -- config may be inconsistent"
          elif ! cp "$backup_path" "$CONFIG_FILE"; then
            _grv2_err "rollback failed: cp from $backup_path returned non-zero -- config may be inconsistent"
          else
            _grv2_audit "config rolled back from $backup_path (AC5)"
          fi
          exit 5
          ;;
        3) _grv2_err "flock timeout while hydrating '$s'"; rm -f "$frag"; _grv2_audit "flock released at $(_grv2_iso8601) pid=$$"; exit 4 ;;
        *) _grv2_warn "config_hydrate_section returned rc=$rc for section '$s' -- continuing per non-blocking policy" ;;
      esac
    fi
    rm -f "$frag"
  done

  for s in $retired_present; do
    [ -z "$s" ] && continue
    _grv2_warn "Section '$s' is deprecated in schema v$schema_ver -- retained per ADR-101 _grv2_warn-and-keep policy"
    _grv2_inject_retired_comment "$CONFIG_FILE" "$s" "$schema_ver"
    _grv2_warn "SR-54 phase-downgrade defense: retained section '$s' protects config_phase='$phase_before' from regression"
  done

  _grv2_audit "flock released at $(_grv2_iso8601) pid=$$"

  # AF-2026-05-13-2 sub-fix (c) — post-hydration partial→full dispatch.
  _grv2_dispatch_phase_advance "$CONFIG_FILE" "post-hydration"

  # AC6 — compare config_phase before vs after to surface helper-driven
  # advancement in the audit trail. The reconciler never writes config_phase
  # directly; advancement comes only from the hydration helper (E85-S5/S6
  # contract). Logging is informational.
  local phase_after
  phase_after="$(yq '.config_phase // "full"' "$CONFIG_FILE" | tr -d '"')"
  if [ "$phase_before" != "$phase_after" ]; then
    _grv2_info "config_phase advanced by helper: $phase_before -> $phase_after (via hydration trigger)"
  fi

  local sha_post
  sha_post="$(_grv2_sha256_file "$CONFIG_FILE")"
  _grv2_audit "post-write hash: $sha_post at $(_grv2_iso8601)"

  if ! yq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
    _grv2_err "post-write YAML validation failed -- restoring from backup"
    cp "$backup_path" "$CONFIG_FILE"
    exit 1
  fi

  _grv2_log "reconciliation complete (sha256: $sha_pre -> $sha_post)"
  exit 0
}

_grv2_main "$@"
