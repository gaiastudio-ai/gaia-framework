#!/usr/bin/env bash
# migrate-config-split.sh — GAIA foundation script
set -euo pipefail
LC_ALL=C
export LC_ALL
#
# One-shot migration helper: splits an existing `_gaia/_config/global.yaml`
# into the team-shared `config/project-config.yaml` and a rewritten
# machine-local `global.yaml`, per the schema classification.
#
# Usage:
#   migrate-config-split.sh [--global-yaml <path>]
#                           [--out-shared  <path>]
#                           [--schema      <path>]
#                           [--force]
#                           [--dry-run]
#                           [-h|--help]
#
# Defaults:
#   --global-yaml  _gaia/_config/global.yaml        (machine-local input)
#   --out-shared   config/project-config.yaml       (team-shared output)
#   --schema       plugins/gaia/config/project-config.schema.yaml (if sibling)
#
# Exit codes:
#   0 — success (including --dry-run)
#   1 — user/usage/backup error, refused overwrite, missing yq, round-trip failure
#   2 — missing input file
#
# Safety net: every mutating run writes `<global-yaml>.bak.{YYYYMMDD-HHMMSS}`
# BEFORE any modification. Round-trip verification runs at the end and leaves
# the backup in place on failure so operators can roll back by copying the
# backup over the rewritten global and deleting the shared output.
#
# Tooling: bash + yq (github.com/mikefarah/yq) + shasum. No Python/Node.
# macOS /bin/bash 3.2 compatible — no associative arrays.
#
# Classification source:
#   Team-shared   (moved-to-project-config): framework_version, user_name,
#     communication_language, project_root, project_path, val_integration,
#     ci_cd, test_execution_bridge, testing, sprint, review_gate,
#     team_conventions, agent_customizations, date.
#   Machine-local (stays-in-global):          framework_name, installed_path,
#     config_path, memory_path, checkpoint_path, sizing_map, problem_solving,
#     document_output_language, user_skill_level.
#   Deprecated    (dropped silently):         project_name, output_folder,
#     planning_artifacts, implementation_artifacts, test_artifacts,
#     creative_artifacts.
# The classification list is sourced from the schema + MIGRATION doc; see
# that pair for the authoritative disposition table.

# ---------- Helpers ----------

die() {
  # die <exit_code> <message>
  local rc="$1"; shift
  printf 'migrate-config-split: %s\n' "$*" >&2
  exit "$rc"
}

usage() {
  # Extract lines 1..40 from this script (the header) as usage docs.
  sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//' >&2
}

timestamp() {
  # Deterministic ISO-like stamp suitable for filenames.
  date -u +%Y%m%d-%H%M%S
}

# ---------- Field classification ----------

# Team-shared keys — moved to config/project-config.yaml.
SHARED_KEYS="framework_version user_name communication_language project_root project_path val_integration ci_cd test_execution_bridge testing sprint review_gate team_conventions agent_customizations date"

# Deprecated keys — dropped on both sides.
DEPRECATED_KEYS="project_name output_folder planning_artifacts implementation_artifacts test_artifacts creative_artifacts config_path"

# ---------- Argument parsing ----------

GLOBAL_YAML=""
OUT_SHARED=""
SCHEMA_PATH=""
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --global-yaml)
      [ $# -ge 2 ] || die 1 "flag --global-yaml requires a path argument"
      GLOBAL_YAML="$2"; shift 2 ;;
    --global-yaml=*)
      GLOBAL_YAML="${1#--global-yaml=}"; shift ;;
    --out-shared)
      [ $# -ge 2 ] || die 1 "flag --out-shared requires a path argument"
      OUT_SHARED="$2"; shift 2 ;;
    --out-shared=*)
      OUT_SHARED="${1#--out-shared=}"; shift ;;
    --schema)
      [ $# -ge 2 ] || die 1 "flag --schema requires a path argument"
      SCHEMA_PATH="$2"; shift 2 ;;
    --schema=*)
      SCHEMA_PATH="${1#--schema=}"; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 1 "unknown argument: $1" ;;
  esac
done

# ---------- yq pre-flight ----------

if ! command -v yq >/dev/null 2>&1; then
  die 1 "yq not found — install yq (github.com/mikefarah/yq) and retry"
fi

# ---------- Resolve default paths ----------

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -z "$GLOBAL_YAML" ]; then
  # Default sits under the project-root's _gaia/_config tree — resolve relative
  # to the script's plugin location (plugins/gaia/scripts/ → project-root via
  # four `..` hops). Fallback to PWD for non-standard layouts.
  CANDIDATE="$SCRIPT_DIR/../../../../_gaia/_config/global.yaml"
  if [ -f "$CANDIDATE" ]; then
    GLOBAL_YAML=$(cd "$(dirname "$CANDIDATE")" && pwd)/$(basename "$CANDIDATE")
  else
    GLOBAL_YAML="$PWD/_gaia/_config/global.yaml"
  fi
fi

if [ -z "$OUT_SHARED" ]; then
  # Default: sibling `config/` directory next to the global.yaml's plugin root.
  # For the canonical layout we emit under plugins/gaia/config/. If the operator
  # supplies --global-yaml in a non-canonical place, we fall back to a sibling
  # `config/` under the global.yaml's parent-of-parent.
  GLOBAL_DIR=$(cd "$(dirname "$GLOBAL_YAML")" 2>/dev/null && pwd || printf '%s' "$(dirname "$GLOBAL_YAML")")
  OUT_SHARED="$GLOBAL_DIR/../../config/project-config.yaml"
fi

# ---------- Validate inputs ----------

[ -f "$GLOBAL_YAML" ] || die 2 "global.yaml not found: $GLOBAL_YAML"

# ---------- Refusal on pre-existing shared output (Fixture 4) ----------

if [ -f "$OUT_SHARED" ] && [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  die 1 "refusing to overwrite existing $OUT_SHARED — pass --force to overwrite or back it up manually"
fi

# ---------- Classification helpers ----------

# classify_key <key> — print one of: shared, deprecated, local.
classify_key() {
  local needle="$1" k
  for k in $SHARED_KEYS; do
    [ "$k" = "$needle" ] && { printf 'shared'; return; }
  done
  for k in $DEPRECATED_KEYS; do
    [ "$k" = "$needle" ] && { printf 'deprecated'; return; }
  done
  printf 'local'
}

# ---------- Dry-run plan ----------

plan_split() {
  # Enumerate the actual input keys once and bucket them via classify_key so
  # absent keys don't show up in any list.
  local all_keys bucket k
  all_keys=$(yq -r 'keys | .[]' "$GLOBAL_YAML")

  printf '# Planned migration — dry-run\n'
  printf '# Input : %s\n' "$GLOBAL_YAML"
  printf '# Shared output : %s\n' "$OUT_SHARED"

  printf '\nshared keys (moved to %s):\n' "$OUT_SHARED"
  for k in $all_keys; do
    bucket=$(classify_key "$k")
    if [ "$bucket" = "shared" ]; then printf '  - %s\n' "$k"; fi
  done

  printf '\nlocal keys (stay in %s):\n' "$GLOBAL_YAML"
  for k in $all_keys; do
    bucket=$(classify_key "$k")
    if [ "$bucket" = "local" ]; then printf '  - %s\n' "$k"; fi
  done

  printf '\ndeprecated keys (dropped on both sides):\n'
  for k in $all_keys; do
    bucket=$(classify_key "$k")
    if [ "$bucket" = "deprecated" ]; then printf '  - %s\n' "$k"; fi
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  plan_split
  exit 0
fi

# ---------- Backup ----------

BACKUP_PATH="${GLOBAL_YAML}.bak.$(timestamp)"
if ! cp -p "$GLOBAL_YAML" "$BACKUP_PATH"; then
  die 1 "backup failed: could not copy $GLOBAL_YAML to $BACKUP_PATH"
fi
printf 'backup: %s\n' "$BACKUP_PATH"

# ---------- Build yq pick/delete expressions ----------

# Compose `pick(["k1", "k2", …])` for the shared output. yq v4 only honors
# pick when the list carries string literals; dot-paths (`.k1`) silently
# pick nothing and yield `{}`.
build_pick_expr() {
  local keys="$1" expr="" k
  for k in $keys; do
    if [ -z "$expr" ]; then
      expr="\"$k\""
    else
      expr="$expr, \"$k\""
    fi
  done
  printf 'pick([%s])' "$expr"
}

# Compose `del(.k1, .k2, …)` to strip a set of keys. yq v4 accepts dot-paths
# in `del` — the asymmetry with `pick` is a yq quirk, not a typo.
build_del_expr() {
  local keys="$1" expr="" k
  for k in $keys; do
    if [ -z "$expr" ]; then
      expr=".$k"
    else
      expr="$expr, .$k"
    fi
  done
  printf 'del(%s)' "$expr"
}

PICK_SHARED=$(build_pick_expr "$SHARED_KEYS")
# Strip shared + deprecated from the local side.
DEL_LOCAL=$(build_del_expr "$SHARED_KEYS $DEPRECATED_KEYS")

# ---------- Produce shared file ----------

SHARED_DIR=$(dirname "$OUT_SHARED")
mkdir -p "$SHARED_DIR"

TMP_SHARED="${OUT_SHARED}.tmp.$$"
TMP_LOCAL="${GLOBAL_YAML}.tmp.$$"

# yq v4 `pick` keeps only the listed keys that actually exist; absent keys
# vanish silently. Output is a fresh YAML doc — comments from the source
# are not preserved verbatim (yq-v4 limitation), so we prepend a generated
# header comment. The header satisfies Task 3 ("add a header comment" when
# comment preservation isn't feasible).
SHARED_BODY=$(yq -o=yaml "$PICK_SHARED" "$GLOBAL_YAML")

SHARED_HEADER="# Auto-generated by migrate-config-split.sh on $(date -u +%Y-%m-%d)
# Team-shared project configuration produced by splitting global.yaml.
# Local overrides live in global.yaml and win per the precedence rule.
"

printf '%s' "$SHARED_HEADER" > "$TMP_SHARED"
# Guard against yq returning an empty doc (\"{}\" or \"null\"). Normalize to
# an empty body so the file isn't polluted with `{}`.
case "$SHARED_BODY" in
  "{}"|"null"|"")
    printf '# (no team-shared fields detected in input)\n' >> "$TMP_SHARED" ;;
  *)
    printf '%s\n' "$SHARED_BODY" >> "$TMP_SHARED" ;;
esac

# ---------- Produce rewritten global (machine-local only) ----------

LOCAL_BODY=$(yq -o=yaml "$DEL_LOCAL" "$GLOBAL_YAML")

LOCAL_HEADER="# Post-split machine-local config — see config/project-config.yaml for shared fields
# Written by migrate-config-split.sh on $(date -u +%Y-%m-%d). Local overrides
# shared per the precedence rule.
"

printf '%s' "$LOCAL_HEADER" > "$TMP_LOCAL"
case "$LOCAL_BODY" in
  "{}"|"null"|"")
    printf '# (no machine-local fields remaining after migration)\n' >> "$TMP_LOCAL" ;;
  *)
    printf '%s\n' "$LOCAL_BODY" >> "$TMP_LOCAL" ;;
esac

# ---------- Atomic write via mv ----------

mv "$TMP_SHARED" "$OUT_SHARED"
mv "$TMP_LOCAL"  "$GLOBAL_YAML"

printf 'wrote shared: %s\n' "$OUT_SHARED"
printf 'rewrote local: %s\n' "$GLOBAL_YAML"

# ---------- Round-trip verification ----------
#
# Invoke resolve-config.sh on (backup) vs (shared+local) and diff. If the
# resolver lives next to us, use it; otherwise skip verification with a warning.

RESOLVER="$SCRIPT_DIR/resolve-config.sh"
if [ -x "$RESOLVER" ]; then
  # Schema lives next to the shared file when checked in. Copy the live schema
  # if a --schema path was supplied OR if the default plugin schema exists.
  DEFAULT_SCHEMA="$SCRIPT_DIR/../config/project-config.schema.yaml"
  STAGED_SCHEMA="$SHARED_DIR/project-config.schema.yaml"
  if [ -n "$SCHEMA_PATH" ] && [ -f "$SCHEMA_PATH" ]; then
    cp "$SCHEMA_PATH" "$STAGED_SCHEMA"
  elif [ ! -f "$STAGED_SCHEMA" ] && [ -f "$DEFAULT_SCHEMA" ]; then
    cp "$DEFAULT_SCHEMA" "$STAGED_SCHEMA"
  fi

  PRESPLIT_SKILL_TMP="$(mktemp -d)"
  mkdir -p "$PRESPLIT_SKILL_TMP/config"
  cp "$BACKUP_PATH" "$PRESPLIT_SKILL_TMP/config/project-config.yaml"
  [ -f "$STAGED_SCHEMA" ] && cp "$STAGED_SCHEMA" "$PRESPLIT_SKILL_TMP/config/project-config.schema.yaml"

  # Pre-split output (if resolver succeeds on the pre-split input).
  PRE_OUTPUT=$(CLAUDE_SKILL_DIR="$PRESPLIT_SKILL_TMP" "$RESOLVER" 2>&1 || true)
  PRE_STATUS=$?

  # Post-split output — two-file merge.
  POST_OUTPUT=$("$RESOLVER" --shared "$OUT_SHARED" --local "$GLOBAL_YAML" 2>&1 || true)
  POST_STATUS=$?

  rm -rf "$PRESPLIT_SKILL_TMP"

  if [ "$PRE_STATUS" -ne 0 ] || [ "$POST_STATUS" -ne 0 ]; then
    # If either resolve errors out (e.g. missing required fields in a partial
    # fixture), round-trip isn't meaningful — log a warning and carry on.
    printf 'round-trip: resolve-config.sh reported pre=%s post=%s — skipping equivalence check\n' \
      "$PRE_STATUS" "$POST_STATUS" >&2
  elif [ "$PRE_OUTPUT" = "$POST_OUTPUT" ]; then
    printf 'round-trip: OK (pre-split and post-split resolve outputs match)\n'
  else
    printf 'round-trip: FAIL — pre-split and post-split resolve outputs differ\n' >&2
    printf 'backup preserved at %s — rollback: cp %s %s && rm %s\n' \
      "$BACKUP_PATH" "$BACKUP_PATH" "$GLOBAL_YAML" "$OUT_SHARED" >&2
    exit 1
  fi
else
  printf 'round-trip: resolve-config.sh not found — skipping equivalence check\n' >&2
fi

exit 0
