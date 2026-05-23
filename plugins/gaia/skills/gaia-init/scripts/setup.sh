#!/usr/bin/env bash
# setup.sh — gaia-init bootstrap. Foundation script per ADR-042.
# Story: E71-S1.
set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-init/setup.sh"

# AF-2026-05-22-9 Bug-11: surface missing runtime dependencies at init time
# instead of mid-sprint-close. yq (mikefarah Go v4) is required by sprint-
# close and several config-split helpers; preflight the dep here so the
# operator can install it before reaching the failing skill.
if ! command -v yq >/dev/null 2>&1; then
  printf '%s: WARNING — yq (mikefarah Go v4) not on PATH. /gaia-sprint-close and several config helpers will fail. Install via: brew install yq (macOS) | apt-get install yq (Linux) | https://github.com/mikefarah/yq/releases\n' "$SCRIPT_NAME" >&2
elif ! yq --version 2>&1 | grep -qE 'mikefarah|v4\.'; then
  printf '%s: WARNING — yq on PATH is not mikefarah Go v4. The Python yq (Andrey Kislyuk) is API-incompatible. Re-install: brew install yq | https://github.com/mikefarah/yq/releases\n' "$SCRIPT_NAME" >&2
fi

printf '%s: setup complete for gaia-init\n' "$SCRIPT_NAME"
exit 0
