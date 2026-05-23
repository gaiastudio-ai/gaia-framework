#!/usr/bin/env bash
# config-migration-status.sh — Detects multi-shape (E99) migration status
# of a project-config.yaml + emits the canonical WARNING text + writes the
# .config-stale drift marker per ADR-102 / FR-528.
#
# E99-S6. Sourceable, NOT executable.
#
# Exposes three functions:
#
#   gaia_config_migration_status <project-config.yaml>
#     Emits one of:
#       clean                       — fully migrated OR all-deployable
#                                     historical project (no distribution
#                                     needed). Caller does NOT warn.
#       pre-migration               — no environments[].kind anywhere AND
#                                     no distribution: block. Both pieces
#                                     of the multi-shape upgrade are
#                                     missing.
#       partial-missing-distribution — at least one kind: declared but no
#                                     distribution: block.
#       partial-missing-kind        — distribution: present but no kind:
#                                     fields on any environment.
#       unknown                     — environments[] missing entirely.
#
#   gaia_config_migration_warning_text <project-config.yaml>
#     Emits a one-paragraph WARNING text suitable for /gaia-config-validate
#     output, naming the migration command + the missing pieces. Emits
#     empty string when status == clean.
#
#   gaia_config_migration_stale_flag_write <project-config.yaml> <memory-dir>
#     Writes <memory-dir>/.config-stale when the config is NOT clean.
#     Skips write on clean configs. Marker contents follow the ADR-102
#     stale-flag registry shape (timestamp + originating skill + reason +
#     FR back-link).
#
# Source guard: _GAIA_CONFIG_MIGRATION_STATUS_LOADED=1 after first source.

if [ "${_GAIA_CONFIG_MIGRATION_STATUS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_CONFIG_MIGRATION_STATUS_LOADED=1

LC_ALL=C
export LC_ALL

# Internal: does this config declare environments[] at all?
_gaia_cms_has_envs() {
  local config="$1"
  local v
  v=$(yq eval 'has("environments")' "$config" 2>/dev/null)
  [ "$v" = "true" ]
}

# Internal: does ANY environments[] entry carry a kind: field?
_gaia_cms_has_any_kind() {
  local config="$1"
  local v
  v=$(yq eval '[.environments[]? | has("kind")] | any' "$config" 2>/dev/null)
  [ "$v" = "true" ]
}

# Internal: is the distribution: block present?
_gaia_cms_has_dist() {
  local config="$1"
  local v
  v=$(yq eval 'has("distribution")' "$config" 2>/dev/null)
  [ "$v" = "true" ]
}

# Internal: are ALL environments[].kind values "deployable" (after
# applying the NFR-080 default to entries lacking kind:)?
_gaia_cms_all_deployable() {
  local config="$1"
  # Enumerate kinds with the deployable default and verify every line
  # equals "deployable". Empty environments[] returns clean (no non-
  # deployable kinds → vacuous truth).
  local kinds non_deployable
  kinds=$(yq eval '.environments[]? | (.kind // "deployable")' "$config" 2>/dev/null)
  non_deployable=$(printf '%s\n' "$kinds" | grep -v '^deployable$' | grep -v '^$' | wc -l | tr -d ' ')
  [ "$non_deployable" = "0" ]
}

gaia_config_migration_status() {
  local config="${1:-}"
  if [ -z "$config" ]; then
    printf 'config-migration-status.sh: usage: gaia_config_migration_status <project-config.yaml>\n' >&2
    return 2
  fi
  if [ ! -f "$config" ]; then
    printf 'config-migration-status.sh: config file not found: %s\n' "$config" >&2
    return 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'config-migration-status.sh: yq required but not on PATH\n' >&2
    return 2
  fi

  if ! _gaia_cms_has_envs "$config"; then
    printf 'unknown\n'
    return 0
  fi

  local has_kind has_dist
  if _gaia_cms_has_any_kind "$config"; then has_kind=1; else has_kind=0; fi
  if _gaia_cms_has_dist  "$config"; then has_dist=1;  else has_dist=0;  fi

  # Decision matrix:
  #   has_kind  has_dist   status
  #     1         1        clean
  #     1         0        partial-missing-distribution (kind declared,
  #                         needs distribution: to express publish intent
  #                         on non-deployable envs)
  #                         ...UNLESS all envs are deployable (then clean
  #                         because no publish target is needed).
  #     0         1        partial-missing-kind
  #     0         0        pre-migration ... UNLESS all envs are deployable
  #                         (legacy all-deployable historical project; the
  #                         NFR-080 default keeps it clean).

  if [ "$has_kind" = "1" ] && [ "$has_dist" = "1" ]; then
    printf 'clean\n'
    return 0
  fi
  if [ "$has_kind" = "1" ] && [ "$has_dist" = "0" ]; then
    # All-deployable + no distribution is the legacy-style clean shape.
    if _gaia_cms_all_deployable "$config"; then
      printf 'clean\n'
    else
      printf 'partial-missing-distribution\n'
    fi
    return 0
  fi
  if [ "$has_kind" = "0" ] && [ "$has_dist" = "1" ]; then
    printf 'partial-missing-kind\n'
    return 0
  fi
  # has_kind=0 has_dist=0 → pre-migration. NFR-080 zero-breakage at
  # RUNTIME (resolve-env-kind.sh silently defaults to deployable, no
  # stderr warning) is intentional and unchanged. This status surface is
  # the VALIDATE-time WARNING signal — distinct from the runtime resolver
  # — letting the user opt into the new shape explicitly. /gaia-config-
  # validate emits a WARNING (exit 0, advisory); no existing workflow
  # breaks.
  printf 'pre-migration\n'
  return 0
}

gaia_config_migration_warning_text() {
  local config="${1:-}"
  if [ -z "$config" ]; then
    printf 'config-migration-status.sh: usage: gaia_config_migration_warning_text <project-config.yaml>\n' >&2
    return 2
  fi
  local status
  status=$(gaia_config_migration_status "$config")
  case "$status" in
    clean|unknown)
      # No warning for clean or unknown (caller decides what to surface for unknown).
      return 0
      ;;
    pre-migration)
      cat <<'EOF'
WARNING: project-config.yaml lacks the E99 multi-shape fields. Recommended migration (FR-528):
  - Add environments[].kind: deployable | branch-only | distribution-only (per FR-520 / ADR-112 §(a))
  - If you ship a publishable artifact, add a distribution: block (per FR-521 / ADR-112 §(b))
Run /gaia-config-distribution add ... to scaffold the distribution: block, then /gaia-config-env to set the per-env kind: discriminator. See E99 / ADR-112.
EOF
      ;;
    partial-missing-distribution)
      cat <<'EOF'
WARNING: project-config.yaml declares environments[].kind but no distribution: block (FR-528). At least one non-deployable env exists — those envs typically pair with a distribution: block.
Run /gaia-config-distribution add ... to scaffold it. See E99-S2 / ADR-112 §(b).
EOF
      ;;
    partial-missing-kind)
      cat <<'EOF'
WARNING: project-config.yaml has a distribution: block but no environments[].kind discriminator anywhere (FR-528). The kind: field is the canonical signal for /gaia-deploy vs /gaia-publish routing.
Run /gaia-config-env edit <env-id> and set kind: deployable | branch-only | distribution-only on each entry. See E99-S1 / ADR-112 §(a).
EOF
      ;;
  esac
  return 0
}

gaia_config_migration_stale_flag_write() {
  local config="${1:-}"
  local memory_dir="${2:-}"
  if [ -z "$config" ] || [ -z "$memory_dir" ]; then
    printf 'config-migration-status.sh: usage: gaia_config_migration_stale_flag_write <project-config.yaml> <memory-dir>\n' >&2
    return 2
  fi
  local status
  status=$(gaia_config_migration_status "$config")
  case "$status" in
    clean|unknown)
      # No marker write for clean or unknown.
      return 0
      ;;
  esac
  mkdir -p "$memory_dir"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$memory_dir/.config-stale" <<EOF
# .config-stale — ADR-102 stale-flag registry / FR-528 migration marker
timestamp: $ts
originating_skill: config-migration-status.sh
reason: E99 multi-shape migration ($status) — environments[].kind and/or distribution: pending
fr_back_link: FR-528
related_fr: FR-520, FR-521
related_adr: ADR-112
EOF
  return 0
}
