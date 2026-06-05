#!/usr/bin/env bash
# gaia-cleanup-legacy-engine.sh — GAIA foundation script
#
# Idempotent migration CLI that removes the legacy GAIA workflow engine and its
# support artifacts from the local runtime tree at {project-root}/_gaia/.
# This script is NOT invoked by the PR that ships it — end users run it
# post-install during manual cutover (see also `/gaia-migrate` for the
# fully-automated v1→v2 path; this script is the engine-deletion subset).
#
# Pre-flight guards (HALT on any failure):
#   1. Clean git working tree under _gaia/ (unless --force-dirty)
#   2. No in-flight legacy-engine checkpoints in _memory/checkpoints/
#   3. verify-cluster-gates.sh exits 0
#
# Deletion targets:
#   _gaia/core/engine/
#   _gaia/core/protocols/
#   _gaia/_config/{lifecycle,workflow,task,skill}-manifest files
#   _gaia/{core,lifecycle,dev,creative,testing}/config.yaml
#   _gaia/**/.resolved/ (recursive)
#
# Survivors:
#   _gaia/_config/global.yaml, agent-manifest.csv, files-manifest.csv, gaia-help.csv
#
# Exit codes:
#   0 — success (deletion complete or already clean)
#   1 — pre-flight gate failed (dirty tree / in-flight checkpoint / cluster gate)
#   3 — filesystem error during deletion (permission, lock, read-only mount)
#   64 — usage error
#
# Usage: gaia-cleanup-legacy-engine.sh --project-root PATH [--dry-run] [--force-dirty]

set -euo pipefail

PROJECT_ROOT=""
DRY_RUN=0
FORCE_DIRTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 --project-root PATH [--dry-run] [--force-dirty]

Removes legacy GAIA workflow engine and support artifacts from {PATH}/_gaia/.
Run after /gaia-migrate apply has succeeded and you have verified the v2
plugin is functional in the project; this script removes the v1 engine
files that /gaia-migrate already backed up under .gaia-migrate-backup/.
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: $0 --project-root PATH [--dry-run] [--force-dirty]" >&2; exit 64 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Usage: $0 --project-root PATH [--dry-run] [--force-dirty]" >&2
  exit 64
fi
if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "project-root does not exist: $PROJECT_ROOT" >&2
  exit 64
fi

cd "$PROJECT_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_GATES="$SCRIPT_DIR/verify-cluster-gates.sh"

# ---------------------------------------------------------------------------
# Pre-flight 1: clean working tree under _gaia/
# ---------------------------------------------------------------------------
if [[ "$FORCE_DIRTY" -eq 0 ]]; then
  if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty=$(git -C "$PROJECT_ROOT" status --porcelain _gaia 2>/dev/null || true)
    if [[ -n "$dirty" ]]; then
      echo "ABORT: uncommitted changes under _gaia/ — commit/stash or pass --force-dirty" >&2
      echo "$dirty" >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Pre-flight 2: no in-flight legacy-engine checkpoints
# ---------------------------------------------------------------------------
CHECKPOINT_DIR="$PROJECT_ROOT/_memory/checkpoints"
if [[ -d "$CHECKPOINT_DIR" ]]; then
  # Search only the top-level (not completed/).
  in_flight=""
  while IFS= read -r -d '' cp_file; do
    if grep -qE 'workflow\.xml|_gaia/core/engine|_gaia/core/protocols|config\.yaml' "$cp_file" 2>/dev/null; then
      in_flight+="${cp_file}"$'\n'
    fi
  done < <(find "$CHECKPOINT_DIR" -maxdepth 1 -name '*.yaml' -print0 2>/dev/null)
  if [[ -n "$in_flight" ]]; then
    echo "ABORT: in-flight legacy-engine checkpoint(s) detected — resolve or archive before running cleanup:" >&2
    printf '%s' "$in_flight" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Pre-flight 3: verify all cluster gates PASSED
# ---------------------------------------------------------------------------
if [[ -x "$VERIFY_GATES" ]]; then
  if ! "$VERIFY_GATES" --project-root "$PROJECT_ROOT" >/dev/null 2>&1; then
    echo "ABORT: cluster-gate pre-start check FAILED — run verify-cluster-gates.sh for details" >&2
    "$VERIFY_GATES" --project-root "$PROJECT_ROOT" >&2 || true
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Build deletion manifest.
# ---------------------------------------------------------------------------
declare -a FILE_TARGETS=(
  "_gaia/_config/lifecycle-sequence.yaml"
  "_gaia/_config/workflow-manifest.csv"
  "_gaia/_config/task-manifest.csv"
  "_gaia/_config/skill-manifest.csv"
  "_gaia/core/config.yaml"
  "_gaia/lifecycle/config.yaml"
  "_gaia/dev/config.yaml"
  "_gaia/creative/config.yaml"
  "_gaia/testing/config.yaml"
)

declare -a DIR_TARGETS=(
  "_gaia/core/engine"
  "_gaia/core/protocols"
)

# Nested .resolved/ directories discovered dynamically (portable to bash 3.2 — no mapfile).
RESOLVED_DIRS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && RESOLVED_DIRS+=("$d")
done < <(find "_gaia" -type d -name ".resolved" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Dry-run preview.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== DRY RUN — manifest (no changes will be made) ==="
  for f in "${FILE_TARGETS[@]}"; do
    [[ -e "$PROJECT_ROOT/$f" ]] && echo "rm    $f"
  done
  for d in "${DIR_TARGETS[@]}"; do
    [[ -d "$PROJECT_ROOT/$d" ]] && echo "rm -r $d"
  done
  for d in "${RESOLVED_DIRS[@]}"; do
    echo "rm -r $d"
  done
  echo "=== (end dry run) ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Actual deletion (idempotent — missing paths are NOT errors).
# ---------------------------------------------------------------------------
deleted=0

safe_remove_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if rm -f "$path" 2>/dev/null; then
      echo "removed: $path"
      deleted=$((deleted + 1))
    else
      echo "ERROR: failed to remove file (permission denied or locked): $path" >&2
      return 3
    fi
  fi
  return 0
}

safe_remove_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then
    if rm -rf "$path" 2>/dev/null; then
      # Confirm removal (rm -rf can silently skip when permissions block children)
      if [[ -d "$path" ]]; then
        echo "ERROR: failed to remove directory (permission denied or locked): $path" >&2
        return 3
      fi
      echo "removed: $path/"
      deleted=$((deleted + 1))
    else
      echo "ERROR: failed to remove directory (permission denied or locked): $path" >&2
      return 3
    fi
  fi
  return 0
}

for f in "${FILE_TARGETS[@]}"; do
  safe_remove_file "$PROJECT_ROOT/$f" || exit 3
done

for d in "${DIR_TARGETS[@]}"; do
  safe_remove_dir "$PROJECT_ROOT/$d" || exit 3
done

if [[ "${#RESOLVED_DIRS[@]}" -gt 0 ]]; then
  for d in "${RESOLVED_DIRS[@]}"; do
    safe_remove_dir "$PROJECT_ROOT/$d" || exit 3
  done
fi

if [[ "$deleted" -eq 0 ]]; then
  echo "gaia-cleanup-legacy-engine: already clean — no legacy artifacts found"
else
  echo "gaia-cleanup-legacy-engine: complete — $deleted target(s) removed"
fi
exit 0
