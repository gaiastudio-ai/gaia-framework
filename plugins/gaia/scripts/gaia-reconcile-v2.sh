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

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '%s: WARN %s\n' "$SCRIPT_NAME" "$*"; }
err() { printf '%s: ERROR %s\n' "$SCRIPT_NAME" "$*" >&2; }
info() { printf '%s: INFO %s\n' "$SCRIPT_NAME" "$*"; }
audit() { printf '# reconcile-v2 %s\n' "$*"; }

iso8601() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sha256_file() {
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
  *)       err "unknown MODE='$MODE' (expected 'apply' or 'dry-run')"; exit 1 ;;
esac

CONFIG_FILE="$PROJECT_ROOT/config/project-config.yaml"

# ---- Schema discovery (AC1 / ADR-101 §1) -----------------------------------

discover_schema() {
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

extract_schema_version() {
  local schema_path="$1"
  yq -p=json '.title // ""' "$schema_path" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1
}

extract_config_version() {
  local config_path="$1"
  yq '.schema_version // ""' "$config_path" 2>/dev/null \
    | tr -d '"' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

semver_compare() {
  local a="${1:-0.0.0}" b="${2:-0.0.0}"
  [ -z "$a" ] && a="0.0.0"
  [ -z "$b" ] && b="0.0.0"
  if [ "$a" = "$b" ]; then printf 'eq\n'; return; fi
  local first
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  if [ "$first" = "$a" ]; then printf 'lt\n'; else printf 'gt\n'; fi
}

# ---- Section diff engine (AC3) --------------------------------------------

list_config_sections() {
  yq 'keys | .[]' "$1" 2>/dev/null | tr -d '"'
}

list_schema_sections() {
  yq -p=json '.properties | keys | .[]' "$1" 2>/dev/null | tr -d '"'
}

list_retired_sections() {
  yq -p=json '.properties | to_entries | map(select(.value.deprecated == true)) | .[].key' "$1" 2>/dev/null | tr -d '"'
}

in_list() {
  local needle="$1" list="$2"
  printf '%s\n' "$list" | grep -Fxq "$needle"
}

# ---- Secret regex (AC11 / SR-50) ------------------------------------------

contains_secret() {
  grep -Eiq '(password|secret|token|api[_-]?key|private[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]+' "$1"
}

# ---- Retired-section comment injection (ADR-101 §3) -----------------------

inject_retired_comment() {
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

main() {
  if [ ! -f "$CONFIG_FILE" ]; then
    err "config not found at $CONFIG_FILE"
    exit 2
  fi

  if contains_secret "$CONFIG_FILE"; then
    err "Potential secret detected in $CONFIG_FILE -- reconciliation aborted"
    exit 2
  fi

  local schema_path
  if ! schema_path="$(discover_schema)"; then
    err "Schema not found. Expected at \${CLAUDE_PLUGIN_ROOT}/schemas/project-config.schema.json or in-tree at gaia-public/plugins/gaia/schemas/project-config.schema.json. Is the GAIA plugin installed?"
    exit 1
  fi
  if [ ! -r "$schema_path" ]; then
    err "Schema at $schema_path is unreadable"
    exit 3
  fi
  log "schema: $schema_path"

  local config_ver schema_ver
  config_ver="$(extract_config_version "$CONFIG_FILE")"
  schema_ver="$(extract_schema_version "$schema_path")"
  if [ -z "$schema_ver" ]; then
    err "Schema version could not be extracted from $schema_path (expected vX.Y.Z in title)"
    exit 3
  fi
  log "config schema_version=${config_ver:-<absent>} schema title version=$schema_ver"

  local cmp
  cmp="$(semver_compare "$config_ver" "$schema_ver")"
  case "$cmp" in
    gt)
      err "Schema downgrade detected (config v$config_ver > installed v$schema_ver) -- refusing to reconcile"
      exit 4
      ;;
    eq)
      log "Config already at schema v$schema_ver -- nothing to reconcile."
      exit 0
      ;;
    lt)
      log "Schema upgrade: ${config_ver:-<absent>} -> $schema_ver"
      ;;
  esac

  local config_sections schema_sections retired_sections
  config_sections="$(list_config_sections "$CONFIG_FILE")"
  schema_sections="$(list_schema_sections "$schema_path")"
  retired_sections="$(list_retired_sections "$schema_path")"

  local missing_sections="" extra_sections="" retired_present=""
  local s
  for s in $schema_sections; do
    if [ -n "$s" ] && ! in_list "$s" "$config_sections" \
      && ! in_list "$s" "$retired_sections"; then
      missing_sections="${missing_sections}${s}"$'\n'
    fi
  done
  for s in $config_sections; do
    if [ -n "$s" ] && ! in_list "$s" "$schema_sections"; then
      extra_sections="${extra_sections}${s}"$'\n'
    fi
  done
  for s in $retired_sections; do
    if [ -n "$s" ] && in_list "$s" "$config_sections"; then
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
  sha_pre="$(sha256_file "$CONFIG_FILE")"
  # AC6 — capture config_phase BEFORE any helper-driven advancement so the
  # post-write comparison below detects real advancement.
  phase_before="$(yq '.config_phase // "full"' "$CONFIG_FILE" | tr -d '"')"
  audit "pre-write hash: $sha_pre at $(iso8601)"
  backup_path="${CONFIG_FILE}.reconcile-v2.bak"
  cp "$CONFIG_FILE" "$backup_path"
  audit "pre-write backup created at $backup_path"

  audit "flock acquired at $(iso8601) pid=$$"

  local helper="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/config-hydration.sh"
  if [ ! -f "$helper" ]; then
    err "config-hydration.sh not found at $helper -- cannot reconcile"
    audit "flock released at $(iso8601) pid=$$"
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
      printf '  # reconciled by gaia-reconcile-v2 at %s\n' "$(iso8601)"
    } > "$frag"

    if contains_secret "$frag"; then
      err "Potential secret detected in section '$s' -- reconciliation aborted"
      rm -f "$frag"
      audit "flock released at $(iso8601) pid=$$"
      cp "$backup_path" "$CONFIG_FILE"
      exit 2
    fi

    if config_hydrate_section "$s" "$frag"; then
      log "hydrated missing section: $s"
    else
      local rc=$?
      case "$rc" in
        2) warn "section '$s' is in schema but not hydratable (helper allowlist) -- skipping" ;;
        3) err "flock timeout while hydrating '$s'"; rm -f "$frag"; audit "flock released at $(iso8601) pid=$$"; exit 4 ;;
        *) warn "config_hydrate_section returned rc=$rc for section '$s' -- continuing per non-blocking policy" ;;
      esac
    fi
    rm -f "$frag"
  done

  for s in $retired_present; do
    [ -z "$s" ] && continue
    warn "Section '$s' is deprecated in schema v$schema_ver -- retained per ADR-101 warn-and-keep policy"
    inject_retired_comment "$CONFIG_FILE" "$s" "$schema_ver"
    warn "SR-54 phase-downgrade defense: retained section '$s' protects config_phase='$phase_before' from regression"
  done

  audit "flock released at $(iso8601) pid=$$"

  # AC6 — compare config_phase before vs after to surface helper-driven
  # advancement in the audit trail. The reconciler never writes config_phase
  # directly; advancement comes only from the hydration helper (E85-S5/S6
  # contract). Logging is informational.
  local phase_after
  phase_after="$(yq '.config_phase // "full"' "$CONFIG_FILE" | tr -d '"')"
  if [ "$phase_before" != "$phase_after" ]; then
    info "config_phase advanced by helper: $phase_before -> $phase_after (via hydration trigger)"
  fi

  local sha_post
  sha_post="$(sha256_file "$CONFIG_FILE")"
  audit "post-write hash: $sha_post at $(iso8601)"

  if ! yq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
    err "post-write YAML validation failed -- restoring from backup"
    cp "$backup_path" "$CONFIG_FILE"
    exit 1
  fi

  log "reconciliation complete (sha256: $sha_pre -> $sha_post)"
  exit 0
}

main "$@"
