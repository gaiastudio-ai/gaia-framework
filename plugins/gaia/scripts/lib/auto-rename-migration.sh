#!/usr/bin/env bash
# auto-rename-migration.sh — One-shot per-file auto-rename migration for the
# E98 CI customization layered model (FR-519, ADR-114 §(f), SR-84).
#
# E98-S5. Sourceable, NOT executable.
#
# Exposes:
#   gaia_auto_rename_migration [--force]
#     Scans ${PROJECT_ROOT}/.github/workflows/*.yml. For each file whose
#     prefix-detection classification is `unprefixed`, prompts the user with
#     three branches:
#       (y) rename to gaia-{base}.yml + scaffold overlay stubs
#       (n) rename to user-{base}.yml (no overlays, byte-identical content)
#       (s) skip-all — write ${PROJECT_ROOT}/.gaia/memory/.config-stale
#
# Non-interactive (GAIA_NONINTERACTIVE=1) flow gated by SR-84:
#   BOTH --force CLI arg AND GAIA_MIGRATE_ALLOW_FORCE=1 env-var required;
#   otherwise HALT with the canonical message.
#
# Backup contract (AC3 / AC5):
#   .gaia-backup/ci-regen-{ISO-8601-timestamp}/ at PROJECT_ROOT (not under
#   .gaia/), mode 0755, files mode 0644, sha256-verified byte-identical copy
#   of every file the migration is about to mutate.
#
# Per-file decision override (for non-interactive bats coverage):
#   GAIA_MIGRATE_DECISION_{basename_with_underscores}=y|n|s
#   e.g., GAIA_MIGRATE_DECISION_ci_yml=y to set the y-branch for ci.yml.
#
# Source guard: _GAIA_AUTO_RENAME_MIGRATION_LOADED=1 after first source.

if [ "${_GAIA_AUTO_RENAME_MIGRATION_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GAIA_AUTO_RENAME_MIGRATION_LOADED=1

LC_ALL=C
export LC_ALL

# Internal: source the E98-S1 prefix-detection helper.
_gaia_arm_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$_gaia_arm_dir/ci-prefix-detection.sh"

# Internal: write a fresh ISO-8601 UTC timestamp to stdout (filesystem-safe).
_gaia_arm_timestamp() {
  date -u +'%Y%m%dT%H%M%SZ'
}

# Internal: convert a basename to the env-var-safe form used for the
# GAIA_MIGRATE_DECISION_* override (e.g., ci.yml → ci_yml).
_gaia_arm_decision_env_key() {
  local base="$1"
  printf 'GAIA_MIGRATE_DECISION_%s' "$(printf '%s' "$base" | tr '.' '_' | tr '-' '_')"
}

# Internal: write the `.gaia/memory/.config-stale` marker with the ADR-102 shape.
_gaia_arm_write_stale_flag() {
  local memory_dir="$1"
  local reason="${2:-deferred-migration}"
  mkdir -p "$memory_dir"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$memory_dir/.config-stale" <<EOF
# .config-stale — ADR-102 stale-flag registry
timestamp: $ts
originating_skill: auto-rename-migration.sh
reason: $reason
fr_back_link: FR-528
related_fr: FR-519
EOF
}

# Internal: scaffold the two overlay stubs for a gaia-{base}.yml file.
_gaia_arm_scaffold_overlays() {
  local workflows_dir="$1"
  local base="$2"      # base name WITHOUT the gaia- prefix and WITHOUT .yml extension

  local jobs_overlay="$workflows_dir/gaia-${base}.user-jobs.yml"
  local steps_overlay="$workflows_dir/gaia-${base}.user-steps.yml"

  cat > "$jobs_overlay" <<'YAML'
# User-jobs overlay — merged into the managed jobs: map at /gaia-config-ci
# --regenerate time. Add custom jobs here. The stitcher (E98-S2) rejects
# job names colliding with GAIA-template jobs per SR-78 / E98-S3.
#
# Example:
#   jobs:
#     coverage-upload:
#       runs-on: ubuntu-latest
#       steps:
#         - run: echo coverage
jobs: {}
YAML

  cat > "$steps_overlay" <<'YAML'
# User-steps overlay — block-level splicing around the managed steps block
# per FR-517 / ADR-114 §(c). steps_before_gaia goes BEFORE the managed
# steps; steps_after_gaia goes AFTER.
steps_before_gaia: []
steps_after_gaia: []
YAML

  chmod 0644 "$jobs_overlay" "$steps_overlay" 2>/dev/null || true
}

# Internal: create a per-invocation backup directory and copy the
# pre-mutation file into it sha256-verified.
_gaia_arm_backup_one() {
  local project_root="$1"
  local file="$2"
  local backup_root="$3"   # pre-computed timestamped dir

  # `install -d -m 0755` sets the mode atomically regardless of umask
  # (more reliable than `mkdir -p && chmod 0755` under unusual umasks).
  # `install` is in coreutils on Linux and macOS.
  install -d -m 0755 "$backup_root" || {
    mkdir -p "$backup_root"
    chmod 0755 "$backup_root" 2>/dev/null || true
  }

  local base
  base="$(basename "$file")"
  install -m 0644 "$file" "$backup_root/$base" || {
    cp "$file" "$backup_root/$base"
    chmod 0644 "$backup_root/$base" 2>/dev/null || true
  }

  # sha256-verify byte-identical copy.
  local src_sha bak_sha
  src_sha=$(shasum -a 256 "$file" | awk '{print $1}')
  bak_sha=$(shasum -a 256 "$backup_root/$base" | awk '{print $1}')
  if [ "$src_sha" != "$bak_sha" ]; then
    printf 'auto-rename-migration.sh: backup sha256 mismatch for %s\n' "$file" >&2
    return 1
  fi

  # SR-84 manifest append (E98-S6): record `<sha256>  <relpath>` for the
  # backed-up file. The manifest is rebuilt cumulatively per call so the
  # final file lists every backed-up entry. verify-backup-integrity.sh
  # reads this file as its expected-state source of truth.
  printf '%s  %s\n' "$bak_sha" "$base" >> "$backup_root/.sha256-manifest"
}

# Internal: read per-file decision. Order:
#   1. GAIA_MIGRATE_DECISION_{base} env-var (bats / non-interactive)
#   2. AskUserQuestion (interactive — orchestrated by the SKILL.md caller,
#      NOT this script; this script only consumes the decision env-var the
#      orchestrator sets after the prompt resolves)
#   3. Default to 's' (skip-all) when no decision is available — SAFE default
_gaia_arm_get_decision() {
  local base="$1"
  local env_key
  env_key=$(_gaia_arm_decision_env_key "$base")
  local v="${!env_key:-}"
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  printf 's'
}

gaia_auto_rename_migration() {
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) shift ;;
    esac
  done

  local project_root="${PROJECT_ROOT:-$(pwd)}"
  local workflows_dir="$project_root/.github/workflows"
  # AF-2026-05-27-3 (ADR-111): the .config-stale marker lives under the canonical
  # .gaia/memory tree (legacy _memory removed with the consolidation migration).
  local memory_dir="$project_root/.gaia/memory"

  if [ ! -d "$workflows_dir" ]; then
    return 0
  fi

  # Enumerate candidate files (any *.yml under .github/workflows).
  local candidates=()
  local f
  for f in "$workflows_dir"/*.yml; do
    [ -f "$f" ] || continue
    local cls
    cls=$(gaia_ci_classify "$f")
    if [ "$cls" = "unprefixed" ]; then
      candidates+=("$f")
    fi
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    # No candidates — already migrated or nothing to do.
    return 0
  fi

  # SR-84 non-interactive guard (AC6): non-interactive mode requires BOTH
  # --force AND GAIA_MIGRATE_ALLOW_FORCE=1.
  if [ "${GAIA_NONINTERACTIVE:-0}" = "1" ]; then
    if [ "$force" -ne 1 ] || [ "${GAIA_MIGRATE_ALLOW_FORCE:-0}" != "1" ]; then
      printf 'auto-rename-migration.sh: HALT: non-interactive auto-rename migration requires --force AND GAIA_MIGRATE_ALLOW_FORCE=1 per SR-84\n' >&2
      return 1
    fi
  fi

  # Create the per-invocation backup directory (used by Y/N branches).
  local backup_root
  backup_root="$project_root/.gaia-backup/ci-regen-$(_gaia_arm_timestamp)"

  # Process each candidate.
  for f in "${candidates[@]}"; do
    local base full_base no_ext
    full_base="$(basename "$f")"      # e.g., ci.yml
    no_ext="${full_base%.yml}"        # e.g., ci

    local decision
    decision=$(_gaia_arm_get_decision "$full_base")

    case "$decision" in
      y|Y)
        # Backup-first.
        _gaia_arm_backup_one "$project_root" "$f" "$backup_root" || return 1
        # Rename.
        mv "$f" "$workflows_dir/gaia-${full_base}"
        chmod 0644 "$workflows_dir/gaia-${full_base}" 2>/dev/null || true
        # Scaffold overlays.
        _gaia_arm_scaffold_overlays "$workflows_dir" "$no_ext"
        printf 'auto-rename-migration.sh: %s → gaia-%s (Y-branch + overlay stubs scaffolded)\n' \
          "$full_base" "$full_base" >&2
        ;;
      n|N)
        _gaia_arm_backup_one "$project_root" "$f" "$backup_root" || return 1
        mv "$f" "$workflows_dir/user-${full_base}"
        chmod 0644 "$workflows_dir/user-${full_base}" 2>/dev/null || true
        printf 'auto-rename-migration.sh: %s → user-%s (N-branch, no overlays)\n' \
          "$full_base" "$full_base" >&2
        ;;
      s|S)
        _gaia_arm_write_stale_flag "$memory_dir" "skip-all on $full_base — deferred FR-519 migration"
        printf 'auto-rename-migration.sh: WARNING: deferred migration for %s — .gaia/memory/.config-stale written (stale per FR-528)\n' \
          "$full_base" >&2
        ;;
      *)
        printf 'auto-rename-migration.sh: invalid decision %s for %s — skipping\n' \
          "$decision" "$full_base" >&2
        ;;
    esac
  done

  return 0
}
