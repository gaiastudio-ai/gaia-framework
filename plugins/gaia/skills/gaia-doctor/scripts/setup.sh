#!/usr/bin/env bash
# gaia-doctor — setup.sh
# Resolves SKILL_DIR + PROJECT_ROOT, exports for downstream helpers.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The pre-fix walk-up `cd "$SKILL_DIR/../../../../.."` walks 5 levels above
# the SKILL_DIR. When the skill is loaded from the plugin cache (the typical
# runtime path), 5-levels-up lands INSIDE the plugin cache directory, not at
# the user's project root. The banner then reported a nonsense
# `project_root=.../plugins/cache/...`. Resolution order now matches the
# canonical contract: env-vars first, then the canonical
# `resolve-config.sh project_root` exposure, then walk up $PWD looking for
# the `.gaia/config/project-config.yaml` anchor, then $PWD as last resort.
# The historical 5-levels-up walk is dropped — it produced a
# wrong-but-confidently-stamped banner.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-}}}"
if [ -z "$PROJECT_ROOT" ]; then
  _rc_helper="${SKILL_DIR}/../../scripts/resolve-config.sh"
  if [ -x "$_rc_helper" ]; then
    _rc_out="$("$_rc_helper" project_root 2>/dev/null || printf '')"
    if [ -n "$_rc_out" ] && [ "$_rc_out" != "." ]; then
      PROJECT_ROOT="$_rc_out"
    fi
  fi
fi
if [ -z "$PROJECT_ROOT" ]; then
  # Walk up looking for the canonical anchor.
  _walk="$PWD"
  while [ -n "$_walk" ] && [ "$_walk" != "/" ] && [ "$_walk" != "$HOME" ]; do
    if [ -f "${_walk}/.gaia/config/project-config.yaml" ]; then
      PROJECT_ROOT="$_walk"
      break
    fi
    _walk="$(dirname "$_walk")"
  done
fi
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
export SKILL_DIR PROJECT_ROOT

echo "gaia-doctor: setup ok (project_root=$PROJECT_ROOT)" >&2
