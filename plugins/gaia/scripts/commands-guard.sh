#!/usr/bin/env bash
# commands-guard.sh — GAIA foundation script (E28-S127)
#
# FR-329 regression guard. Fails the build if any gaia-*.md file reappears
# under gaia-framework/plugins/gaia/commands/. The commands/ surface was retired
# as part of Cluster 18 (Cleanup & Migration) and MUST NOT be repopulated —
# skills under plugins/gaia/skills/ are the sole user-invocation surface.
#
# Refs: FR-329, NFR-050, ADR-048
# Story: E28-S127 Task 6 / AC5
#
# This is a NARROW-SCOPE guard: directory-emptiness check only. Broader
# active-code scanning for legacy file-path references is handled by
# dead-reference-scan.sh (same directory).
#
# Exit codes:
#   0 — clean (commands/ absent OR present with no gaia-*.md files)
#   1 — regression detected (one or more gaia-*.md files found)
#   64 — usage error
#
# Usage: commands-guard.sh --project-root PATH

set -euo pipefail

PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --project-root PATH"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: $0 --project-root PATH" >&2; exit 64 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Usage: $0 --project-root PATH" >&2
  exit 64
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "project-root does not exist: $PROJECT_ROOT" >&2
  exit 64
fi

COMMANDS_DIR="$PROJECT_ROOT/plugins/gaia/commands"

# Clean path: the retired directory does not exist at all.
if [[ ! -d "$COMMANDS_DIR" ]]; then
  echo "commands-guard: CLEAN — plugins/gaia/commands/ does not exist (FR-329 satisfied)"
  exit 0
fi

# Collect any gaia-*.md files in the retired directory.
offenders=""
while IFS= read -r -d '' f; do
  offenders+="${f#"$PROJECT_ROOT"/}"$'\n'
done < <(find "$COMMANDS_DIR" -maxdepth 1 -type f -name 'gaia-*.md' -print0 2>/dev/null)

offenders=$(printf '%s' "$offenders" | sed '/^$/d')

if [[ -z "$offenders" ]]; then
  echo "commands-guard: CLEAN — plugins/gaia/commands/ exists but contains no gaia-*.md files (FR-329 satisfied)"
  exit 0
fi

echo "commands-guard: FAILED — FR-329 regression detected"
echo
echo "The plugins/gaia/commands/ directory was retired under FR-329 (Slash Command"
echo "Retirement) and MUST NOT be repopulated. The following file(s) were found:"
echo
printf '%s\n' "$offenders"
echo
echo "Move each file's functionality to a SKILL.md under plugins/gaia/skills/{name}/"
echo "and remove the file from plugins/gaia/commands/. See FR-329 in prd.md and"
echo "ADR-048 in architecture.md for the retirement rationale."
exit 1
