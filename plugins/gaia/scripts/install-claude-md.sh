#!/usr/bin/env bash
# install-claude-md.sh — materialize the project CLAUDE.md from the plugin
# template into a target project root.
#
# Background (issue: CLAUDE.md not copied on init):
#   /gaia-init (greenfield) and /gaia-brownfield (existing codebase) generated
#   .gaia/config/project-config.yaml + a CI scaffold, but never wrote a
#   project-root CLAUDE.md — the file that tells Claude Code this is a GAIA
#   project (runtime tree, how-to-start, hard rules, upstream-bug-report
#   policy). Without it a freshly-initialized project has no GAIA context.
#
# Semantics (mirrors install-test-environment-example.sh):
#   - Unconditional copy when target is ABSENT (fresh-install path).
#   - Byte-identical preserve when target EXISTS (copy-if-absent — NEVER
#     clobber a project that already has its own CLAUDE.md).
#   - Fail-fast non-zero when the plugin source template is missing.
#
# Usage:
#   install-claude-md.sh --target <project-root>
#   install-claude-md.sh --help
#
# Exit codes:
#   0  success (copied on fresh install, or target already present + preserved)
#   1  plugin source template is missing (plugin corruption; reinstall)
#   2  usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="install-claude-md.sh"

# Resolve plugin root from this script's location:
#   <plugin-root>/scripts/install-claude-md.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_PATH="${PLUGIN_ROOT}/templates/CLAUDE.md"

target=""

usage() {
  cat <<'USAGE'
Usage: install-claude-md.sh --target <project-root>

Materialize plugins/gaia/templates/CLAUDE.md into the target project root as
CLAUDE.md.

Behavior:
  - Target absent: copy template (fresh-install path).
  - Target present: preserve byte-identical (copy-if-absent — never clobber
    a user's existing CLAUDE.md).
  - Plugin source missing: exit 1 with a clear error.

Exit codes:
  0  success
  1  plugin source template missing
  2  usage error
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || { printf '%s: --target requires a value\n' "$SCRIPT_NAME" >&2; exit 2; }
      target="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '%s: unexpected argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
done

[ -n "${target}" ] || { printf '%s: --target is required\n' "$SCRIPT_NAME" >&2; usage >&2; exit 2; }
[ -d "${target}" ] || { printf '%s: target directory does not exist: %s\n' "$SCRIPT_NAME" "${target}" >&2; exit 2; }

if [ ! -f "${TEMPLATE_PATH}" ]; then
  printf '%s: ERROR: plugin source template is missing at %s\n' "$SCRIPT_NAME" "${TEMPLATE_PATH}" >&2
  printf '%s: cannot install CLAUDE.md without source. Plugin may be corrupted; reinstall via /plugin marketplace add.\n' "$SCRIPT_NAME" >&2
  exit 1
fi

target_file="${target}/CLAUDE.md"

if [ -f "${target_file}" ]; then
  printf '%s: target already exists at %s — preserving byte-identical (copy-if-absent semantics)\n' "$SCRIPT_NAME" "${target_file}"
  exit 0
fi

cp "${TEMPLATE_PATH}" "${target_file}"
printf '%s: installed CLAUDE.md -> %s\n' "$SCRIPT_NAME" "${target_file}"

exit 0
