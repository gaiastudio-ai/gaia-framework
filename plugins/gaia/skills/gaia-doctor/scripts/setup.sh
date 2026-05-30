#!/usr/bin/env bash
# gaia-doctor — setup.sh
# Resolves SKILL_DIR + PROJECT_ROOT, exports for downstream helpers.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$(cd "$SKILL_DIR/../../../../.." && pwd)}}}"
export SKILL_DIR PROJECT_ROOT

echo "gaia-doctor: setup ok (project_root=$PROJECT_ROOT)" >&2
