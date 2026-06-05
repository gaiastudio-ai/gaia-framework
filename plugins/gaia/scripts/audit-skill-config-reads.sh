#!/usr/bin/env bash
# audit-skill-config-reads.sh — audit helper
#
# Scans SKILL.md files for direct references to `global.yaml` or
# `project-config.yaml`. Emits one line per match in the form:
#
#   {relative_skill_path}:{line}:{match_text}
#
# Exit codes:
#   0 — scan ran successfully (match count may be zero)
#   2 — invalid argument (e.g., target directory missing)
#
# Usage:
#   audit-skill-config-reads.sh [SKILLS_DIR]
#
# If SKILLS_DIR is omitted, the script resolves
# ${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/skills by default so it works
# both when invoked directly from a Claude Code plugin at runtime and from
# a developer shell checked out at the repo root.

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    TARGET="${CLAUDE_PLUGIN_ROOT}/skills"
  else
    TARGET="$(cd "$(dirname "$0")/.." && pwd)/skills"
  fi
fi

if [ ! -d "$TARGET" ]; then
  printf 'audit-skill-config-reads: target directory not found: %s\n' "$TARGET" >&2
  exit 2
fi

# Find every SKILL.md under the target, grep for direct references.
# Prune is safe across macOS (BSD find) and Linux (GNU find).
# Using -print0 / xargs -0 to tolerate unusual paths.
matches="$(find "$TARGET" -type f -name 'SKILL.md' -print0 \
  | xargs -0 grep -nE 'global\.yaml|project-config\.yaml' 2>/dev/null || true)"

if [ -z "$matches" ]; then
  printf 'no direct config reads found in %s\n' "$TARGET"
  exit 0
fi

# Emit raw grep output — it is already in `file:line:text` form.
printf '%s\n' "$matches"
exit 0
