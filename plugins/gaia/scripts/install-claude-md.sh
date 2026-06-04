#!/usr/bin/env bash
# install-claude-md.sh — materialize / merge the GAIA CLAUDE.md block into a
# target project's root CLAUDE.md.
#
# Background (issue #1113):
#   /gaia-init (greenfield) and /gaia-brownfield (existing codebase) generated
#   .gaia/config/project-config.yaml + a CI scaffold, but never wrote a
#   project-root CLAUDE.md — the file that tells Claude Code this is a GAIA
#   project (runtime tree, how-to-start, hard rules, upstream-bug-report
#   policy). Without it a freshly-initialized project has no GAIA context.
#
#   A brownfield project frequently ALREADY has its own CLAUDE.md carrying the
#   user's project-specific instructions. Blindly copying would clobber it;
#   skipping would leave the project with no GAIA context. So the GAIA content
#   is a MARKER-DELIMITED block that is APPENDED to an existing CLAUDE.md,
#   preserving the user's content verbatim above it. Mirrors the .gitignore
#   "seed-or-append-GAIA-block" idiom in generate-config.sh.
#
# Three modes (idempotent):
#   1. No CLAUDE.md            -> seed: copy the template verbatim (greenfield).
#   2. CLAUDE.md, no GAIA block -> append the GAIA block, preserving the user's
#                                  existing content above it (brownfield).
#   3. CLAUDE.md WITH the block -> no-op (already managed; safe re-run).
#
# The GAIA block is bounded by the markers:
#   <!-- >>> GAIA (managed by /gaia-init · /gaia-brownfield) -->
#   ... block ...
#   <!-- <<< GAIA -->
# Presence of the open marker is the idempotency sentinel.
#
# Usage:
#   install-claude-md.sh --target <project-root>
#   install-claude-md.sh --help
#
# Exit codes:
#   0  success (seeded, appended, or already-present no-op)
#   1  plugin source template is missing (plugin corruption; reinstall)
#   2  usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="install-claude-md.sh"

# The open marker — also the idempotency sentinel. Kept in sync with the
# template's first line.
GAIA_MARKER="<!-- >>> GAIA (managed by /gaia-init · /gaia-brownfield) -->"

# Resolve plugin root from this script's location:
#   <plugin-root>/scripts/install-claude-md.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_PATH="${PLUGIN_ROOT}/templates/CLAUDE.md"

target=""

usage() {
  cat <<'USAGE'
Usage: install-claude-md.sh --target <project-root>

Materialize / merge the GAIA CLAUDE.md block into the target project's root
CLAUDE.md.

Behavior (idempotent):
  - No CLAUDE.md: seed it from the template (greenfield).
  - CLAUDE.md present, no GAIA block: append the GAIA block, preserving the
    user's existing content above it (brownfield — never clobber).
  - CLAUDE.md already carries the GAIA block: no-op.
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

# Mode 1 — fresh seed.
if [ ! -f "${target_file}" ]; then
  cp "${TEMPLATE_PATH}" "${target_file}"
  printf '%s: seeded CLAUDE.md -> %s\n' "$SCRIPT_NAME" "${target_file}"
  exit 0
fi

# Mode 3 — already managed (GAIA block present): no-op.
if grep -qF "${GAIA_MARKER}" "${target_file}" 2>/dev/null; then
  printf '%s: CLAUDE.md already carries the GAIA block at %s — no-op\n' "$SCRIPT_NAME" "${target_file}"
  exit 0
fi

# Mode 2 — existing CLAUDE.md without a GAIA block: append it, preserving the
# user's content. Ensure exactly one blank line separates the user's content
# from the appended block. Atomic write (temp + mv).
tmp="$(mktemp "${target_file}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
{
  cat "${target_file}"
  # Guarantee a separating blank line regardless of the user's trailing
  # newline state.
  printf '\n'
  cat "${TEMPLATE_PATH}"
} > "${tmp}"
mv -f "${tmp}" "${target_file}"
trap - EXIT
printf '%s: appended GAIA block to existing CLAUDE.md at %s (user content preserved)\n' "$SCRIPT_NAME" "${target_file}"
exit 0
