#!/usr/bin/env bash
# gaia-migrate.sh — GAIA v1 to v2 migration script
#
# Automate the v1 → v2 migration. The SKILL.md drives the user-facing flow
# and delegates filesystem operations to this script — this script and the
# SKILL.md are the authoritative sources for the migration workflow.
#
# Usage:
#   gaia-migrate.sh apply   --project-root PATH
#   gaia-migrate.sh dry-run --project-root PATH
#
# Exit codes:
#   0 — success (migration applied, OR dry-run completed cleanly)
#   1 — pre-flight HALT (no v1 install detected, partial install, already migrated)
#   2 — backup failed (disk space, permission)
#   3 — migration step failed (subtask 4.1, 4.2, or 4.3)
#   4 — post-migration validation failed
#   5 — safety gate failed (v2 marker missing/malformed at delete time)
#   6 — manifest mismatch between live source and backup
#   7 — user declined confirmation OR non-TTY without --yes/--force
#   11 — v2 with config + state dirs, needs reconciliation -> exec gaia-reconcile-v2.sh
#   64 — usage error

set -euo pipefail

# Resolve this script's own directory so sibling scripts (e.g. the
# gaia-reconcile-v2.sh dispatch target) can be invoked by path
# even when gaia-migrate.sh is run from an arbitrary cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
PROJECT_ROOT=""
DRY_RUN=false
ASSUME_YES=false      # --yes / --force bypasses the destructive confirmation prompt
BACKUP_DIR=""         # populated by _run_backup; printed by _on_interrupt

# ---------------------------------------------------------------------------
# SIGINT / SIGTERM trap handler
#
# When the operator hits Ctrl+C (or a supervisor sends SIGTERM) during a
# migration, surface (a) a clear "partial migration" banner, (b) the absolute
# backup path, and (c) the exact `cp -a` command needed to restore the project
# from that backup. Exits 130 on SIGINT (128 + SIGINT, the bash convention) and
# 143 on SIGTERM (128 + SIGTERM). If the signal arrives BEFORE _run_backup has
# populated $BACKUP_DIR (e.g., during _detect_v1), the handler still prints a
# safe banner explaining there is nothing yet to restore — backups are taken
# before any destructive write, so v1 state on disk is intact.
# ---------------------------------------------------------------------------
_on_interrupt() {
  local sig="${1:-INT}"
  local exit_code
  case "$sig" in
    TERM) exit_code=143 ;;
    *)    exit_code=130 ;;
  esac

  echo
  echo "=== partial migration — run restore ==="
  if [[ -n "${BACKUP_DIR:-}" ]]; then
    # BACKUP_DIR is published as soon as `_run_backup` has mkdir'd it
    # (before the heavy cp -a phase), so this branch covers the
    # "interrupt landed during/after backup" cases — including a partial
    # backup where the cp was mid-flight. The printed cp -a command is
    # safe to run because no destructive writes have happened yet (the
    # backup MUST complete in full BEFORE _migrate_config_split rewrites
    # any v1 source — see backup-before-migration ordering).
    echo "Backup: $BACKUP_DIR"
    echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  else
    echo "Backup: (none yet — interrupted before backup directory was created)"
    echo "Restore: not required — no destructive writes have run; v1 state on disk is intact."
  fi
  echo "Exit: $exit_code (interrupted by SIG$sig)"
  exit "$exit_code"
}

trap '_on_interrupt INT' INT
trap '_on_interrupt TERM' TERM

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    apply|dry-run)
      MODE="$1"
      shift
      ;;
    --project-root)
      PROJECT_ROOT="${2:-}"
      shift 2
      ;;
    --yes|--force)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 (apply|dry-run) --project-root PATH

apply    — perform the v1 to v2 migration (creates backup first)
dry-run  — print the planned operations without writing anything

Run dry-run first to preview the planned operations. The summary lines
emitted by both modes are the authoritative source of truth.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 (apply|dry-run) --project-root PATH" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: $0 (apply|dry-run) --project-root PATH" >&2
  echo "Mode required: 'apply' or 'dry-run'" >&2
  exit 64
fi

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Usage: $0 (apply|dry-run) --project-root PATH" >&2
  echo "--project-root is required" >&2
  exit 64
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "project-root does not exist: $PROJECT_ROOT" >&2
  exit 64
fi

if [[ "$MODE" == "dry-run" ]]; then
  DRY_RUN=true
fi

# ---------------------------------------------------------------------------
# Central write helper — every cp/mv/rm/mkdir/write routes through here.
# In dry-run mode, the helper logs the intended operation and returns 0
# without touching the filesystem. This is the single safety mechanism for
# dry-run idempotency and accidental write prevention.
# ---------------------------------------------------------------------------
_safe_write() {
  local action="$1"
  shift
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would: $action $*"
    return 0
  fi
  case "$action" in
    mkdir)  mkdir -p "$@" ;;
    cp_a)   cp -a "$@" ;;
    cp)     cp "$@" ;;
    mv)     mv "$@" ;;
    rm)     rm "$@" ;;
    rm_rf)  rm -rf "$@" ;;
    write)
      # write FILE CONTENT — write CONTENT to FILE
      local file="$1"
      shift
      printf '%s\n' "$*" > "$file"
      ;;
    append)
      local file="$1"
      shift
      printf '%s\n' "$*" >> "$file"
      ;;
    *)
      echo "ERROR: _safe_write: unknown action '$action'" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step: detect v1 markers
# ---------------------------------------------------------------------------
_detect_v1() {
  echo "=== detect: v1 markers ==="
  local has_engine has_memory has_custom has_config has_v2

  [[ -d "$PROJECT_ROOT/_gaia" ]] && has_engine=1 || has_engine=0
  [[ -d "$PROJECT_ROOT/_memory" ]] && has_memory=1 || has_memory=0
  [[ -d "$PROJECT_ROOT/custom" ]] && has_custom=1 || has_custom=0
  [[ -f "$PROJECT_ROOT/_gaia/_config/global.yaml" ]] && has_config=1 || has_config=0
  [[ -f "$PROJECT_ROOT/config/project-config.yaml" ]] && has_v2=1 || has_v2=0

  echo "  _gaia/                              : $([ "$has_engine" -eq 1 ] && echo present || echo MISSING)"
  echo "  _memory/                            : $([ "$has_memory" -eq 1 ] && echo present || echo MISSING)"
  echo "  custom/                             : $([ "$has_custom" -eq 1 ] && echo present || echo MISSING)"
  echo "  _gaia/_config/global.yaml           : $([ "$has_config" -eq 1 ] && echo present || echo MISSING)"
  echo "  config/project-config.yaml (v2)     : $([ "$has_v2" -eq 1 ] && echo present || echo MISSING)"

  # Check ordering: the v2-only idempotent success path MUST be evaluated
  # BEFORE the partial-install HALT. Order is:
  #   (1)  v2 marker present + no v1 dirs + state dirs present → return 11
  #        (reconciliation needed; caller exec's gaia-reconcile-v2.sh)
  #   (1b) v2 marker present + no v1 dirs + no state dirs       → return 10
  #        (idempotent success)
  #   (2)  v2 marker present + v1 dirs                          → HALT (1)
  #   (3)  no v1 + no v2                                        → HALT (1)
  #   (4)  partial v1                                           → HALT (1)
  #   (5)  full v1                                              → return 0
  #
  # The function returns:
  #   0   → proceed with migration (full v1 detected)
  #   10  → idempotent success (v2-only, caller exits 0 with "already on v2")
  #   11  → v2 with state dirs, needs reconciliation; caller exec's reconciler
  #   1   → HALT (all other error paths)

  # Detect v2-era state directories. The presence of `_memory/` OR
  # `docs/planning-artifacts/` at the project root is the canonical
  # "has framework-era artifacts" heuristic.
  local has_state_dirs=0
  if [[ -d "$PROJECT_ROOT/_memory" ]] || [[ -d "$PROJECT_ROOT/docs/planning-artifacts" ]]; then
    has_state_dirs=1
  fi

  # (1) v2 + no v1 dirs + state dirs present → return 11 (reconcile path)
  # The v1-marker absence test is `has_engine=0` alone. `_memory/` is v2-era
  # state (excluded from v1-marker test via has_state_dirs above).
  # `custom/` is a canonical v2 surface (custom-over-built-in precedence) —
  # its presence does NOT indicate v1. The previous `has_custom=0` condition
  # produced a false-positive HALT on v2 projects with active custom adapters.
  # If a future call site needs to disambiguate v1-legacy `custom/` from v2
  # `custom/`, check `[ -d "$PROJECT_ROOT/custom/agents" ]` — that subdir
  # was a v1-only layout.
  if [[ "$has_v2" -eq 1 && "$has_engine" -eq 0 && "$has_state_dirs" -eq 1 ]]; then
    echo
    echo "v2 install with framework-era state directories detected — reconciliation path."
    return 11
  fi

  # (1b) Already on v2 — idempotent success
  if [[ "$has_v2" -eq 1 && "$has_engine" -eq 0 && "$has_memory" -eq 0 ]]; then
    echo
    echo "Nothing to migrate — already on v2."
    return 10
  fi

  # (2) Mixed state — v2 marker AND v1 dirs both present
  if [[ "$has_v2" -eq 1 ]]; then
    echo
    echo "HALT: Migration already complete — config/project-config.yaml exists. v2 state detected."
    return 1
  fi

  # (3) No v1 detected AND no v2 marker
  if [[ "$has_engine" -eq 0 && "$has_memory" -eq 0 && "$has_config" -eq 0 ]]; then
    echo
    echo "HALT: No v1 installation detected — nothing to migrate."
    return 1
  fi

  # (4) Partial install — only reachable once v2 marker is absent
  if [[ "$has_engine" -eq 0 || "$has_memory" -eq 0 || "$has_config" -eq 0 ]]; then
    echo
    echo "HALT: v1 installation is partial — required marker missing. Either repair the install or pass --force-partial (not yet supported)."
    return 1
  fi

  # (5) Full v1 — proceed
  echo "  → v1 install detected, ready to migrate"
}

# ---------------------------------------------------------------------------
# Step: backup BEFORE any migration write
# ---------------------------------------------------------------------------
_run_backup() {
  echo
  echo "=== backup: timestamped snapshot ==="
  local ts bdir
  ts="$(date +%Y-%m-%d-%H%M%S)"
  bdir="$PROJECT_ROOT/.gaia-migrate-backup/$ts"
  echo "  destination: $bdir"

  # Disk space check (best-effort: confirm /tmp + project-root have >100MB free)
  local free_kb
  free_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
  if [[ -n "$free_kb" && "$free_kb" -lt 102400 ]]; then
    echo "ERROR: insufficient disk space ($free_kb KB free, need >100MB)" >&2
    return 2
  fi

  _safe_write mkdir "$bdir"

  # Publish the backup destination as soon as it has been mkdir'd so that
  # a SIGINT/SIGTERM arriving mid-backup can still print a useful restore
  # command. The directory may be partially populated at signal time; the
  # trap handler's printed `cp -a "$BACKUP_DIR/." "$PROJECT_ROOT/"` is
  # always safe (no destructive writes have run yet — see backup-before-
  # migration ordering).
  BACKUP_DIR="$bdir"

  # Copy each source — silently skip if absent
  for src in _gaia _memory custom; do
    if [[ -d "$PROJECT_ROOT/$src" ]]; then
      _safe_write cp_a "$PROJECT_ROOT/$src" "$bdir/"
    fi
  done
  if [[ -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    _safe_write cp_a "$PROJECT_ROOT/CLAUDE.md" "$bdir/"
  fi

  # Generate manifest with sha256 (only in apply mode — dry-run can't write the manifest)
  if [[ "$DRY_RUN" == "false" ]]; then
    local manifest="$bdir/backup-manifest.yaml"
    {
      echo "# gaia-migrate backup manifest"
      echo "timestamp: $ts"
      echo "project_root: $PROJECT_ROOT"
      echo "files:"
      ( cd "$bdir" && find . -type f -not -name 'backup-manifest.yaml' -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do
          local sum
          sum=$(shasum -a 256 "$f" | awk '{print $1}')
          echo "  - path: ${f#./}"
          echo "    sha256: $sum"
        done ) >> "$manifest"
    } 2>/dev/null
    if [[ ! -f "$manifest" ]]; then
      # fallback: write the file even if the find pipeline is empty
      cat > "$manifest" <<EOF
# gaia-migrate backup manifest
timestamp: $ts
project_root: $PROJECT_ROOT
files: []
sha256: empty-backup
EOF
    fi
    echo "  manifest: $manifest"
  else
    echo "  [dry-run] would write manifest: $bdir/backup-manifest.yaml"
  fi

  # BACKUP_DIR was already exported at the top of this function so an
  # interrupt during the cp -a phase can still print a meaningful restore
  # path; no further assignment is needed here.
  echo "  backup PASS"
}

# ---------------------------------------------------------------------------
# Subtask 4.1 — templates
# ---------------------------------------------------------------------------
_migrate_templates() {
  echo
  echo "=== migrate 4.1: custom/templates/ ==="
  if [[ ! -d "$PROJECT_ROOT/custom/templates" ]]; then
    echo "  no custom/templates/ to migrate (skipping)"
    echo "  templates PASS"
    return 0
  fi
  # v2 plugin honors custom/templates/ at project root — verify-only
  local count
  count=$(find "$PROJECT_ROOT/custom/templates" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  $count template file(s) preserved at custom/templates/ (v2 path matches v1 — no move needed)"
  echo "  templates PASS"
}

# ---------------------------------------------------------------------------
# Subtask 4.2 — sidecars + schema-drift detection
# ---------------------------------------------------------------------------
# v2 canonical sidecar frontmatter key allowlist. v2 sidecars currently use
# plain markdown bodies with no frontmatter (per the current schema), so the
# baseline is the empty list. Any frontmatter key found in a v1 sidecar that
# is NOT in this allowlist is treated as schema drift and surfaces a
# `manual follow-up: verify sidecar keys` note. Future schema versions that
# ratchet a v2 sidecar schema MUST extend this list.
V2_SIDECAR_CANONICAL_KEYS=()

# _extract_frontmatter_keys <file>
# Print each top-level YAML key found in the file's frontmatter block on its
# own line. Returns silently (no output) if the file has no frontmatter.
# Frontmatter is the block delimited by the first two `---` lines starting
# at line 1. Indented (nested) keys are intentionally ignored — drift is
# evaluated at the top-level key set only.
_extract_frontmatter_keys() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  awk '
    BEGIN { in_fm = 0; opened = 0 }
    NR == 1 {
      if ($0 == "---") { in_fm = 1; opened = 1; next }
      else { exit }
    }
    in_fm && $0 == "---" { exit }
    in_fm && /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      key = $0
      sub(/:.*$/, "", key)
      print key
    }
  ' "$file"
}

# _is_canonical_sidecar_key <key>
# Return 0 if <key> is in V2_SIDECAR_CANONICAL_KEYS, 1 otherwise.
_is_canonical_sidecar_key() {
  local needle="$1" k
  for k in "${V2_SIDECAR_CANONICAL_KEYS[@]:-}"; do
    [[ "$k" == "$needle" ]] && return 0
  done
  return 1
}

_migrate_sidecars() {
  echo
  echo "=== migrate 4.2: _memory/*-sidecar/ ==="
  local sidecar_count=0 file_count=0 drift_count=0
  if [[ -d "$PROJECT_ROOT/_memory" ]]; then
    while IFS= read -r -d '' dir; do
      sidecar_count=$((sidecar_count + 1))
      while IFS= read -r -d '' file; do
        file_count=$((file_count + 1))
        # Extract top-level frontmatter keys and diff against the v2
        # canonical allowlist. Files without frontmatter are silent.
        local keys unknown_keys=() key
        keys="$(_extract_frontmatter_keys "$file")"
        [[ -z "$keys" ]] && continue
        while IFS= read -r key; do
          [[ -z "$key" ]] && continue
          if ! _is_canonical_sidecar_key "$key"; then
            unknown_keys+=("$key")
          fi
        done <<< "$keys"
        if [[ ${#unknown_keys[@]} -gt 0 ]]; then
          drift_count=$((drift_count + 1))
          local rel_path="${file#$PROJECT_ROOT/}"
          local joined
          joined="$(IFS=,; printf '%s' "${unknown_keys[*]}")"
          echo "  manual follow-up: verify sidecar keys ($rel_path): unknown keys: $joined"
        fi
      done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
    done < <(find "$PROJECT_ROOT/_memory" -maxdepth 1 -mindepth 1 -type d -name '*-sidecar' -print0 2>/dev/null)
  fi
  echo "  $sidecar_count sidecar(s), $file_count .md file(s) verified"
  if [[ $drift_count -gt 0 ]]; then
    echo "  $drift_count drifted sidecar file(s) — manual follow-up required (see lines above)"
  else
    echo "  v1 and v2 sidecar layouts match (per current schema) — no transformation needed"
  fi
  echo "  sidecars PASS"
}

# ---------------------------------------------------------------------------
# Required-field preservation and placeholder substitution at the migration
# boundary
# ---------------------------------------------------------------------------
# The resolver validates 7 required fields: project_root, project_path,
# memory_path, checkpoint_path, installed_path, framework_version, date.
# v1 kept these in _gaia/_config/global.yaml; subtask 4.5 deletes that dir
# post-migration. We therefore MUST copy the 7 fields into the v2 team-shared
# file (config/project-config.yaml) BEFORE the destructive delete runs, so
# resolve-config's required-field check keeps passing on v2 projects.
#
# Placeholder substitution: v1 configs frequently used the literal token
# `{project-root}` in path-bearing fields. The v1 XML engine substituted that
# token at runtime using its template-resolution layer; the v2 native plugin
# has NO such runtime substitution. Without explicit substitution here, the
# literal string `{project-root}` would propagate forward into
# project-config.yaml and break every downstream v2 script.
# This helper substitutes the literal token `{project-root}` with the absolute
# `$PROJECT_ROOT` before extracted values are appended to the v2 config.
# Substitution is exact-token (only literal `{project-root}` is replaced);
# values that do not contain the placeholder pass through byte-identical.
#
# $PROJECT_ROOT is required to be set AND absolute before substitution runs.
# If unset or relative, this helper aborts non-zero so the destructive
# `_gaia/` delete in subtask 4.5 cannot run on a half-migrated config.
#
# If any required field is missing or unparseable from the v1 source, ABORT
# before the destructive delete — the caller sees a clear "required field
# missing: <field>" error and v1 dirs remain intact for repair.
#
# Returns 0 when every required field was present and appended to the v2
# file; returns non-zero when a required field was missing (caller must abort).
_derive_required_fields() {
  local v1="$1" v2="$2"
  [ -f "$v1" ] || { echo "ERROR: v1 source missing: $v1" >&2; return 1; }
  [ -f "$v2" ] || { echo "ERROR: v2 target missing: $v2" >&2; return 1; }

  # PROJECT_ROOT precondition guard. Substitution requires an absolute path;
  # aborting here BEFORE any destructive write protects subtask 4.5's
  # `_gaia/` delete from running on a half-migrated config.
  if [ -z "${PROJECT_ROOT:-}" ]; then
    echo "ERROR: PROJECT_ROOT is unset — cannot substitute {project-root} placeholder" >&2
    echo "       _derive_required_fields requires an absolute --project-root" >&2
    return 1
  fi
  case "$PROJECT_ROOT" in
    /*) : ;;  # absolute, OK
    *)
      echo "ERROR: PROJECT_ROOT is relative ('$PROJECT_ROOT') — must be absolute" >&2
      echo "       _derive_required_fields refuses to substitute relative paths" >&2
      return 1
      ;;
  esac

  # Artifact-dir keys joined the resolver's required-fields list. The 3 paths
  # (test_artifacts, planning_artifacts, implementation_artifacts) must be
  # preserved across migration alongside the original 7 required fields —
  # otherwise the v2 project fails resolver's required-field check on first
  # skill invocation after v1 deletion.
  local required=(project_root project_path memory_path checkpoint_path
                  installed_path framework_version date
                  test_artifacts planning_artifacts implementation_artifacts)
  local field value missing=""

  # Use a deterministic extractor identical to resolve-config.sh's parse_yaml_key:
  # top-level `key: value` line, surrounding quotes stripped.
  _extract_key() {
    local file="$1" key="$2" line v
    line=$(grep -E "^${key}[[:space:]]*:" "$file" 2>/dev/null | head -n1 || true)
    [ -z "$line" ] && return 0
    v=${line#*:}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    case "$v" in
      \"*\") v=${v#\"}; v=${v%\"} ;;
      \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    printf '%s' "$v"
  }

  # Substitute the literal token `{project-root}` with the absolute
  # $PROJECT_ROOT. Bash parameter expansion `${var//pattern/replacement}`
  # is an exact-string replacement (no regex) — values without the literal
  # token pass through byte-identical. Substitution applies to BOTH the
  # missing-field probe loop AND the write loop so the validation gate below
  # sees the post-substitution value.
  _substitute_placeholders() {
    local v="$1"
    printf '%s' "${v//\{project-root\}/$PROJECT_ROOT}"
  }

  for field in "${required[@]}"; do
    value=$(_extract_key "$v1" "$field")
    value=$(_substitute_placeholders "$value")
    if [ -z "$value" ]; then
      missing="${missing}${field} "
    fi
  done

  if [ -n "$missing" ]; then
    echo "ERROR: required field missing from v1 config: ${missing% }" >&2
    echo "       Source: $v1" >&2
    echo "       Required: ${required[*]}" >&2
    return 1
  fi

  # All required fields resolved — append them to the v2 file. Each field is
  # emitted on its own line with a leading comment block so it's obvious
  # where they came from.
  {
    echo ""
    echo "# Required fields preserved from v1 _gaia/_config/global.yaml"
    echo "# (resolver required-field list — see resolve-config.sh)"
    echo "# {project-root} placeholders substituted with PROJECT_ROOT"
    for field in "${required[@]}"; do
      value=$(_extract_key "$v1" "$field")
      value=$(_substitute_placeholders "$value")
      # Quote values containing spaces or colons to keep YAML parsers happy.
      case "$value" in
        *' '*|*:*|*\#*) printf '%s: "%s"\n' "$field" "$value" ;;
        *)              printf '%s: %s\n'   "$field" "$value" ;;
      esac
    done
  } >> "$v2"

  return 0
}

# ---------------------------------------------------------------------------
# Subtask 4.3 — config split
# ---------------------------------------------------------------------------
_migrate_config_split() {
  echo
  echo "=== migrate 4.3: config split ==="
  local v1_config="$PROJECT_ROOT/_gaia/_config/global.yaml"
  if [[ ! -f "$v1_config" ]]; then
    echo "  no _gaia/_config/global.yaml — nothing to split"
    echo "  config-split PASS"
    return 0
  fi

  # Keys that stay in global.yaml (local, per-developer)
  local local_keys=(
    framework_name framework_version user_name communication_language
    document_output_language user_skill_level project_name project_root
    project_path output_folder planning_artifacts implementation_artifacts
    test_artifacts creative_artifacts memory_path checkpoint_path
    installed_path config_path
  )

  # Keys that move to project-config.yaml (team-shared)
  local shared_keys=(
    ci_cd val_integration memory_budgets sizing_map problem_solving
    adversarial_triggers
  )

  # Build the two files. Use a simple awk-based YAML key-block extractor
  # (works for top-level keys with their indented children).
  local v2_global="$PROJECT_ROOT/_gaia/_config/global.yaml.v2"
  local v2_shared_dir="$PROJECT_ROOT/config"
  local v2_shared="$v2_shared_dir/project-config.yaml"

  _safe_write mkdir "$v2_shared_dir"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would split $v1_config:"
    echo "    [dry-run] local keys → $v1_config (rewritten in place)"
    echo "    [dry-run] shared keys → $v2_shared"
    echo "  config-split PASS"
    return 0
  fi

  # Extract local keys to v2_global
  {
    echo "# GAIA v2 — local config (per-developer, machine-local)"
    echo "# Migrated from v1 by /gaia-migrate"
    for k in "${local_keys[@]}"; do
      awk -v k="$k" '
        $0 ~ "^"k":" { in_block=1; print; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { print }
      ' "$v1_config"
    done
  } > "$v2_global"

  # Extract shared keys to project-config.yaml
  {
    echo "# GAIA v2 — team-shared config (cloud-synced)"
    echo "# Migrated from v1 by /gaia-migrate"
    for k in "${shared_keys[@]}"; do
      awk -v k="$k" '
        $0 ~ "^"k":" { in_block=1; print; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { print }
      ' "$v1_config"
    done
  } > "$v2_shared"

  # Preserve resolver's 7 required fields in the v2 shared file BEFORE
  # subtask 4.5 deletes _gaia/_config/global.yaml. Run the derivation against
  # the pristine v1 config (still in place) BEFORE the `mv` that rewrites
  # v1_config to the post-split local-keys-only copy — otherwise any required
  # field the split dropped on the floor (e.g., the `date:` sentinel) would
  # be lost forever. If any field is missing from v1 source, abort now (well
  # before the delete step).
  if ! _derive_required_fields "$v1_config" "$v2_shared"; then
    echo "  config-split FAIL — required field missing; refusing to proceed" >&2
    return 1
  fi

  # Replace v1 config with v2_global
  _safe_write mv "$v2_global" "$v1_config"

  echo "  local keys retained in: $v1_config"
  echo "  shared keys written to: $v2_shared"
  echo "  required fields preserved in: $v2_shared"
  echo "  config-split PASS"
}

# ---------------------------------------------------------------------------
# Subtask 4.4 — remove legacy .claude/commands/gaia-*.md stubs
#
# Claude Code registers slash commands from two places: the v2 plugin's
# SKILL.md files AND the legacy `.claude/commands/*.md` stub files left over
# from a v1 install. After `/gaia-migrate apply` installs the v2 plugin, the
# legacy stubs still register the same commands — every /gaia-* appears twice
# in the palette. This step removes the `.claude/commands/gaia-*.md` stubs
# after a verbatim backup into the migration backup tree. The glob is
# leading-anchored (gaia-*.md) so a user's own `my-gaia-tool.md` is never
# touched.
# ---------------------------------------------------------------------------

# Populated by _collect_legacy_command_stubs. Caller reads STUB_COUNT and
# iterates the STUB_PATHS array; both are reset on every call.
STUB_PATHS=()
STUB_COUNT=0

# _collect_legacy_command_stubs: find every file under .claude/commands/
# whose basename matches gaia-*.md at the leading prefix. Populates the
# STUB_PATHS array and STUB_COUNT in place.
_collect_legacy_command_stubs() {
  STUB_PATHS=()
  STUB_COUNT=0
  local dir="$PROJECT_ROOT/.claude/commands"
  [[ ! -d "$dir" ]] && return 0
  # -maxdepth 1 — only direct children (we never recurse into subfolders).
  # -name 'gaia-*.md' — leading-anchored glob, NOT *gaia*.md.
  # -type f — skip directories and symlinks to non-files (defensive).
  while IFS= read -r -d '' f; do
    STUB_PATHS+=("$f")
    STUB_COUNT=$((STUB_COUNT + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name 'gaia-*.md' -print0 2>/dev/null)
}

_migrate_legacy_command_stubs() {
  echo
  echo "=== migrate 4.4: legacy .claude/commands/gaia-*.md stubs ==="

  _collect_legacy_command_stubs

  if [[ "$STUB_COUNT" -eq 0 ]]; then
    echo "Legacy command stubs to remove (0 files) — none present"
    echo "  stubs PASS"
    return 0
  fi

  echo "Legacy command stubs to remove ($STUB_COUNT files):"
  local f
  for f in "${STUB_PATHS[@]}"; do
    echo "  - ${f#"$PROJECT_ROOT"/}"
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would back up the above files to $BACKUP_DIR/.claude/commands/"
    echo "  [dry-run] would sha256-verify each backup copy"
    echo "  [dry-run] would delete each source stub after verification"
    echo "  stubs PASS"
    return 0
  fi

  # Backup MUST precede delete. The v1 stubs are small (<5KB each) so this
  # is cheap. Preserve directory structure under the timestamped backup dir.
  local backup_commands_dir="$BACKUP_DIR/.claude/commands"
  mkdir -p "$backup_commands_dir"

  local deleted=0
  for f in "${STUB_PATHS[@]}"; do
    local base dest src_sha dst_sha
    base="$(basename "$f")"
    dest="$backup_commands_dir/$base"
    cp -a "$f" "$dest"
    src_sha=$(shasum -a 256 "$f" | awk '{print $1}')
    dst_sha=$(shasum -a 256 "$dest" | awk '{print $1}')
    if [[ "$src_sha" != "$dst_sha" ]]; then
      echo "ERROR: backup checksum mismatch for $f (src=$src_sha dst=$dst_sha)" >&2
      echo "  stubs FAIL — aborting before delete (source files left intact)"
      return 3
    fi
    rm -f "$f"
    deleted=$((deleted + 1))
  done

  echo "  backed up $deleted stub(s) to: ${backup_commands_dir#"$PROJECT_ROOT"/}"
  echo "  deleted $deleted stub(s) from: .claude/commands/"
  echo "  stubs PASS"
}

# ---------------------------------------------------------------------------
# Subtask 4.5 — back up + delete v1 directories after successful migration
#
# Runs AFTER the config split has produced `config/project-config.yaml` (the
# v2 marker). Safety rails:
#   (a) v2 marker must exist and contain a non-empty framework_version: OR
#       version: field. Missing / empty → exit 5 (safety gate failed).
#   (b) Every live file under _gaia/, _memory/, custom/ must have a byte-for-
#       byte match in $BACKUP_DIR (the snapshot taken by _run_backup), with
#       ONE intentional exception: _gaia/_config/global.yaml was rewritten in
#       place by _migrate_config_split AFTER the backup was captured, so the
#       pre-split copy in the backup is intentionally different from the live
#       post-split file. Exclude that single path from the comparison.
#       Anything else mismatching → exit 6 (manifest mismatch).
#   (c) Paranoid guards: $BACKUP_DIR must be non-empty, must not equal
#       $PROJECT_ROOT, and $PROJECT_ROOT must not equal / or $HOME. Targets
#       must be inside $PROJECT_ROOT.
#   (d) Destructive confirmation: interactive prompt unless --yes / --force.
#       Non-TTY without --yes → exit 7 (bats-safe; no hang).
#   (e) Each absent v1 dir is skipped silently.
# ---------------------------------------------------------------------------

# _compute_live_manifest DIR MANIFEST — write sha256 + relative-path pairs for
# every file under DIR (skipping symlinks) to MANIFEST. Paths are relative to
# DIR and sorted so a second pass over the backup produces the same ordering.
_compute_live_manifest() {
  local dir="$1" manifest="$2"
  : > "$manifest"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && find . -type f -print0 2>/dev/null | sort -z | \
    while IFS= read -r -d '' f; do
      local sum
      sum=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      printf '%s  %s\n' "$sum" "${f#./}"
    done ) > "$manifest"
}

_migrate_v1_directories() {
  echo
  echo "=== migrate 4.5: v1 directories cleanup ==="

  # Collect which v1 dirs are present (skip absent silently).
  local present_dirs=()
  local d
  for d in _gaia _memory custom; do
    if [[ -d "$PROJECT_ROOT/$d" ]]; then
      present_dirs+=("$d")
    fi
  done

  if [[ "${#present_dirs[@]}" -eq 0 ]]; then
    echo "  no v1 directories present — nothing to delete"
    echo "  v1-dirs PASS"
    return 0
  fi

  # Dry-run listing + size info. Use du -sk for POSIX-portable KB output
  # (macOS vs Linux du -sh formatting differs; sticking to -sk keeps the
  # output deterministic for bats assertions).
  echo "Legacy v1 directories to remove (${#present_dirs[@]} dirs):"
  local total_kb=0
  for d in "${present_dirs[@]}"; do
    local kb files
    kb=$(du -sk "$PROJECT_ROOT/$d" 2>/dev/null | awk '{print $1}')
    files=$(find "$PROJECT_ROOT/$d" -type f 2>/dev/null | wc -l | tr -d ' ')
    total_kb=$((total_kb + kb))
    # Emit dir name, file count, and KB size on one line.
    printf '  - %s (%s file(s), %s KB)\n' "$d" "$files" "$kb"
  done
  printf '  total: %s KB\n' "$total_kb"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would verify backup manifest matches live source"
    echo "  [dry-run] would prompt user to confirm deletion (unless --yes)"
    echo "  [dry-run] would rm -rf the dirs above after manifest match"
    echo "  v1-dirs PASS"
    return 0
  fi

  # Safety gate — v2 marker must exist and be non-empty.
  # The config split places `framework_version:` in _gaia/_config/global.yaml
  # (local keys) and only ci_cd/val_integration/sizing_map etc. in
  # config/project-config.yaml (shared keys). So accept the v2 marker as
  # valid if EITHER:
  #   (a) project-config.yaml has a non-empty framework_version: or version:
  #       field (preferred canonical check), OR
  #   (b) project-config.yaml has at least one non-commented top-level key
  #       (the post-split reality — the file exists and carries shared
  #       config). This is the practical "v2 schema recognized" check.
  # Anything else (missing file, zero top-level keys, only comments) →
  # refuse the delete with exit 5.
  local v2_marker="$PROJECT_ROOT/config/project-config.yaml"
  if [[ ! -f "$v2_marker" ]]; then
    echo "ERROR: safety gate — v2 marker ($v2_marker) missing" >&2
    echo "       Refusing to delete v1 directories. v1 state left intact." >&2
    return 5
  fi
  local marker_ok=0
  if grep -qE '^(framework_version|version):[[:space:]]*[^[:space:]]' "$v2_marker"; then
    marker_ok=1
  elif grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*:' "$v2_marker"; then
    marker_ok=1
  fi
  if [[ "$marker_ok" -eq 0 ]]; then
    echo "ERROR: safety gate — v2 marker ($v2_marker) exists but has no" >&2
    echo "       recognizable schema (no framework_version:/version: and no" >&2
    echo "       top-level keys). Refusing to delete v1 directories." >&2
    return 5
  fi
  echo "  safety gate: v2 marker OK ($v2_marker)"

  # --- Paranoid guards ---
  if [[ -z "${BACKUP_DIR:-}" || ! -d "$BACKUP_DIR" ]]; then
    echo "ERROR: BACKUP_DIR unset or missing — refusing rm -rf" >&2
    return 5
  fi
  if [[ "$BACKUP_DIR" == "$PROJECT_ROOT" ]]; then
    echo "ERROR: BACKUP_DIR == PROJECT_ROOT — refusing rm -rf" >&2
    return 5
  fi
  if [[ "$PROJECT_ROOT" == "/" || "$PROJECT_ROOT" == "${HOME:-/never-match}" ]]; then
    echo "ERROR: refusing rm -rf at \$PROJECT_ROOT=$PROJECT_ROOT" >&2
    return 5
  fi

  # Manifest verification (snapshot integrity). The invariant: "what I'm
  # about to delete is byte-identical to what I preserved in the backup."
  # We re-compute BOTH manifests at delete time and diff them. One path is
  # intentionally excluded from the compare: _gaia/_config/global.yaml was
  # rewritten in place by _migrate_config_split (the line
  # `_safe_write mv "$v2_global" "$v1_config"` rewrites the live source AFTER
  # the backup snapshot was taken). The pre-split copy is preserved in
  # $BACKUP_DIR/_gaia/_config/global.yaml, so the backup is whole; only the
  # comparison would falsely mismatch on that file.
  local live_manifest backup_manifest tmp
  live_manifest="$(mktemp -t gaia-migrate-live.XXXXXX)"
  backup_manifest="$(mktemp -t gaia-migrate-bkp.XXXXXX)"
  tmp="$(mktemp -t gaia-migrate-tmp.XXXXXX)"

  # Build both manifests in a single pass. _compute_live_manifest emits
  # "sha256  relpath" lines for each file under its first argument.
  for d in "${present_dirs[@]}"; do
    _compute_live_manifest "$PROJECT_ROOT/$d" "$tmp"
    sed -e "s|  |  $d/|" "$tmp" >> "$live_manifest"
    _compute_live_manifest "$BACKUP_DIR/$d" "$tmp"
    sed -e "s|  |  $d/|" "$tmp" >> "$backup_manifest"
  done
  rm -f "$tmp"

  # Apply the documented exclusion — _gaia/_config/global.yaml is intentionally
  # rewritten in place by _migrate_config_split, so its live sha256 does NOT
  # match the pre-split sha256 in the backup. Both sides are filtered so the
  # diff does not flag this intentional drift.
  local live_filtered backup_filtered
  live_filtered="$(mktemp -t gaia-migrate-live-f.XXXXXX)"
  backup_filtered="$(mktemp -t gaia-migrate-bkp-f.XXXXXX)"
  grep -v '  _gaia/_config/global\.yaml$' "$live_manifest" > "$live_filtered" || true
  grep -v '  _gaia/_config/global\.yaml$' "$backup_manifest" > "$backup_filtered" || true

  if ! diff -q "$live_filtered" "$backup_filtered" >/dev/null 2>&1; then
    echo "ERROR: manifest mismatch — live source differs from backup snapshot." >&2
    echo "       Refusing to delete. Inspect:" >&2
    echo "         diff $live_filtered $backup_filtered" >&2
    return 6
  fi
  rm -f "$live_manifest" "$backup_manifest" "$live_filtered" "$backup_filtered"
  echo "  manifest match: live source == backup snapshot (excluding intentionally-rewritten _gaia/_config/global.yaml)"

  # Destructive confirmation with non-TTY guard.
  if [[ "$ASSUME_YES" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      echo "ERROR: non-interactive context detected and --yes/--force not supplied." >&2
      echo "       Refusing to delete v1 directories without explicit confirmation." >&2
      return 7
    fi
    printf 'Ready to delete v1 directories (backed up at %s). Proceed? (yes/no) ' "$BACKUP_DIR"
    local reply
    IFS= read -r reply || reply=""
    # Case-insensitive: accept only "yes" (not "y").
    reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
    if [[ "$reply" != "yes" ]]; then
      echo "  user declined — v1 directories left intact."
      return 7
    fi
  fi

  # Delete v1 directories.
  for d in "${present_dirs[@]}"; do
    # Defensive: ensure target is inside PROJECT_ROOT.
    local target="$PROJECT_ROOT/$d"
    case "$target" in
      "$PROJECT_ROOT"/*) : ;;
      *)
        echo "ERROR: target $target is not inside PROJECT_ROOT — refusing rm -rf" >&2
        return 5
        ;;
    esac
    rm -rf "$target"
  done
  echo "  deleted ${#present_dirs[@]} v1 director(ies): ${present_dirs[*]}"

  # Export for use by the final summary.
  V1_DIRS_DELETED=("${present_dirs[@]}")
  echo "  v1-dirs PASS"
}

# ---------------------------------------------------------------------------
# Step: validation
# ---------------------------------------------------------------------------
_run_validate() {
  echo
  echo "=== validate: post-migration checks ==="
  local fail=0

  # 1. Plugin discoverable (best-effort under bats — the .claude/plugins/ dir may not exist locally)
  if [[ -d "$PROJECT_ROOT/.claude/plugins/gaia-framework" ]] || command -v claude >/dev/null 2>&1; then
    echo "  plugin: discoverable"
  else
    echo "  plugin: validation skipped (claude CLI not available — manual follow-up: confirm /plugin list shows gaia)"
  fi

  # 2. project-config.yaml parses
  if [[ -f "$PROJECT_ROOT/config/project-config.yaml" ]]; then
    if grep -qE '^[a-zA-Z_]+:' "$PROJECT_ROOT/config/project-config.yaml"; then
      echo "  project-config.yaml: parses (basic structural check)"
    else
      echo "  ERROR: project-config.yaml exists but contains no top-level keys" >&2
      fail=1
    fi
  fi

  # 3. global.yaml still has local keys (only if _gaia/ still exists — when
  # the v1 cleanup ran, _gaia/ has been deleted and this check is N/A).
  if [[ -f "$PROJECT_ROOT/_gaia/_config/global.yaml" ]]; then
    if grep -qE '^project_path:' "$PROJECT_ROOT/_gaia/_config/global.yaml"; then
      echo "  global.yaml: project_path retained"
    else
      echo "  ERROR: global.yaml lost project_path during split" >&2
      fail=1
    fi
  else
    echo "  global.yaml: N/A (v1 directories removed by cleanup)"
  fi

  return "$fail"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "==============================================================="
echo "gaia-migrate — v1 → v2 migration ($MODE mode)"
echo "project-root: $PROJECT_ROOT"
echo "==============================================================="

# Detect (HALT-able). Return-code semantics:
#   0  → proceed with v1 → v2 migration (full v1 detected)
#   10 → idempotent success (v2-only, no state dirs) — exit 0 with log
#   11 → v2 with state dirs — exec dispatch to gaia-reconcile-v2.sh
#   *  → any other non-zero return is a HALT
set +e
_detect_v1
detect_rc=$?
set -e
case "$detect_rc" in
  10)
    echo "No v1 markers and no config state dirs -- nothing to migrate."
    exit 0
    ;;
  11)
    echo "v2 install detected -- dispatching to gaia-reconcile-v2.sh"
    # `exec` the reconciler, which owns the process after dispatch.
    # MODE, PROJECT_ROOT, DRY_RUN, ASSUME_YES are already in scope from
    # arg parsing and are forwarded via the environment.
    export MODE PROJECT_ROOT DRY_RUN ASSUME_YES
    exec "$SCRIPT_DIR/gaia-reconcile-v2.sh"
    ;;
esac
if [[ "$detect_rc" -ne 0 ]]; then
  exit 1
fi

# Backup (HALT on disk-space)
BACKUP_DIR=""
if ! _run_backup; then
  echo
  echo "FAILED: backup step did not complete. Aborting before any migration write."
  exit 2
fi

# Migrate (3 subtasks)
if ! _migrate_templates; then
  echo "FAILED: templates migration"
  echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  exit 3
fi
if ! _migrate_sidecars; then
  echo "FAILED: sidecars migration"
  echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  exit 3
fi
if ! _migrate_config_split; then
  echo "FAILED: config-split migration"
  echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  exit 3
fi
if ! _migrate_legacy_command_stubs; then
  echo "FAILED: legacy command stubs migration"
  echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  exit 3
fi

# Subtask 4.5 — back up + delete v1 directories. Runs after all migrations
# succeed and before validation. Exit codes 5/6/7 are surfaced directly to
# the caller so bats can assert them precisely.
set +e
V1_DIRS_DELETED=()
_migrate_v1_directories
v1_rc=$?
set -e
if [[ "$v1_rc" -ne 0 ]]; then
  case "$v1_rc" in
    5|6|7) exit "$v1_rc" ;;
    *)
      echo "FAILED: v1 directories cleanup"
      echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
      exit 3
      ;;
  esac
fi

# Validate
if [[ "$DRY_RUN" == "false" ]]; then
  if ! _run_validate; then
    echo
    echo "==============================================================="
    echo "FAILED: post-migration validation reported errors."
    echo "Backup: $BACKUP_DIR"
    echo "Restore: cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
    echo "==============================================================="
    exit 4
  fi
fi

# Summary
echo
echo "==============================================================="
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run — no changes made."
  echo "To apply: $0 apply --project-root \"$PROJECT_ROOT\""
else
  echo "SUCCESS — v1 → v2 migration complete."
  echo "Backup: $BACKUP_DIR"
  echo "Restore command (if needed): cp -a \"$BACKUP_DIR/.\" \"$PROJECT_ROOT/\""
  # Tell the user to smoke-test with the plugin-namespaced form. The
  # unnamespaced /gaia-help can be intercepted by a legacy
  # .claude/commands/gaia-help.md stub, so /gaia:gaia-help is the only form
  # that unambiguously exercises the plugin's gaia-help skill.
  echo
  echo "Next step: run /gaia:gaia-help in Claude Code to smoke-test the plugin install."
  echo "  (The gaia: prefix targets the plugin's gaia-help skill and avoids any legacy"
  echo "   .claude/commands/gaia-help.md stub that might still be registered.)"
  # Legacy command stubs rollback path.
  if [[ -d "$BACKUP_DIR/.claude/commands" ]]; then
    echo
    echo "Legacy command stubs were backed up to: $BACKUP_DIR/.claude/commands/"
    echo "To restore v1 stubs (if you need to run v1 again):"
    echo "  cp -a \"$BACKUP_DIR/.claude/commands/\" \"$PROJECT_ROOT/.claude/\""
    echo
    echo "Known limitation: /gaia-migrate is project-local. If you installed"
    echo "GAIA v1 globally, also run:"
    echo "  rm ~/.claude/commands/gaia-*.md"
  fi
  # v1 directories rollback path.
  if [[ "${#V1_DIRS_DELETED[@]}" -gt 0 ]]; then
    echo
    echo "Legacy v1 directories backed up to: $BACKUP_DIR/"
    echo "To restore v1, run:"
    printf '  cp -a'
    for d in "${V1_DIRS_DELETED[@]}"; do
      printf ' "%s/%s"' "$BACKUP_DIR" "$d"
    done
    printf ' "%s/"\n' "$PROJECT_ROOT"
  fi
fi
echo "==============================================================="
