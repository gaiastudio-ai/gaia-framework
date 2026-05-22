#!/usr/bin/env bash
# load-spec.sh — gaia-quick-dev quick-spec loader (E28-S117)
#
# Reads the quick spec at docs/implementation-artifacts/quick-spec-{spec_name}.md
# and emits its body on stdout. Fails fast with exit code 2 when the spec is
# missing (AC-EC4 — matches the legacy on_error.missing_file: ask_user contract).
#
# Usage:
#   load-spec.sh <spec_name>
#
# Exit codes:
#   0 — spec body emitted on stdout
#   2 — spec file not found (AC-EC4)
#   1 — usage or unexpected error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-quick-dev/load-spec.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ $# -lt 1 ]; then
  die "usage: load-spec.sh <spec_name>"
fi

SPEC_NAME="$1"

# Resolve the project root — prefer $PROJECT_PATH, fall back to cwd (matches
# the legacy resolve-config.sh contract and the brownfield/native split).
WORK_DIR="${PROJECT_PATH:-$PWD}"
# AF-2026-05-21-25: canonical-first spec lookup, legacy fallback.
if [ -f "$WORK_DIR/.gaia/artifacts/implementation-artifacts/quick-spec-${SPEC_NAME}.md" ]; then
  SPEC_PATH="$WORK_DIR/.gaia/artifacts/implementation-artifacts/quick-spec-${SPEC_NAME}.md"
else
  SPEC_PATH="$WORK_DIR/docs/implementation-artifacts/quick-spec-${SPEC_NAME}.md"
fi

if [ ! -f "$SPEC_PATH" ]; then
  log "Quick spec not found — run /gaia-quick-spec first."
  log "Expected: $SPEC_PATH"
  exit 2
fi

cat "$SPEC_PATH"
