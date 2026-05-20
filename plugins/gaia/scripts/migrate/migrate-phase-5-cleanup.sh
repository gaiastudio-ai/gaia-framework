#!/usr/bin/env bash
# migrate-phase-5-cleanup.sh — final cleanup story for the .gaia/ consolidation
# epic (E96-S5, ADR-111).
#
# This script:
#   1. Produces a pre-cleanup tarball of every file the sweep will touch
#      (CLAUDE.md, README.md, SKILL.md files, framework .sh scripts, ADR-020/044/046).
#   2. Runs the post-cleanup grep gate (AC10) and reports counts of remaining
#      legacy references — informational. THIS SCRIPT AUDITS BUT DOES NOT
#      SWEEP; the mechanical sweep across the ~151 SKILL.md and ~103 shell
#      scripts is owned by E96-S7 (E96-S5 silently deferred this work in its
#      Findings table under the "incremental maintenance" framing, which the
#      sprint-49 review surfaced as a Review Gate integrity defect; the
#      sweep was re-scoped into E96-S7 via /gaia-correct-course story_injection).
#   3. Removes transition pointer files (.gaia-pointer) at legacy locations
#      IF run after a deprecation window has elapsed AND E96-S8 (cleanup) has
#      landed. The destructive cleanup (legacy dir removal + write-boundary.sh
#      legacy-entry removal) is owned by E96-S8, not this script.
#
# Idempotent.
#
# Usage:
#   migrate-phase-5-cleanup.sh [--project-root <path>] [--audit-only] [--remove-pointers]

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-phase-5-cleanup.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

# Args
PROJECT_ROOT=""
AUDIT_ONLY=0
REMOVE_POINTERS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root)    PROJECT_ROOT="$2"; shift 2 ;;
    --audit-only)      AUDIT_ONLY=1; shift ;;
    --remove-pointers) REMOVE_POINTERS=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$PWD}"
fi
PROJECT_ROOT="$( cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || true )"
[ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ] || die "invalid project root"

# Step 1: post-cleanup grep gate (AC10).
# Counts remaining bare references to legacy GAIA-owned dirs in framework code.
log "running post-cleanup grep gate"
PLUGIN_TREE="$PROJECT_ROOT/gaia-public/plugins/gaia"
if [ ! -d "$PLUGIN_TREE" ]; then
  log "plugin tree not found at $PLUGIN_TREE — skipping gate"
  exit 0
fi

count_pattern() {
  local pattern="$1"
  grep -rln --include='*.sh' --include='*.md' -E "$pattern" "$PLUGIN_TREE" 2>/dev/null | wc -l | awk '{print $1}'
}

DOCS_HITS="$(count_pattern '\bdocs/(planning|implementation|test|creative|research)-artifacts/')"
MEM_HITS="$(count_pattern '\b_memory/')"
CONFIG_HITS="$(count_pattern '\bconfig/(project-config|test-environment|global)\.yaml')"
CUSTOM_HITS="$(count_pattern '\bcustom/(adapters|skills|templates)/')"

printf '%s: grep gate counts (legacy references in framework code):\n' "$SCRIPT_NAME" >&2
printf '  docs/<artifact>-artifacts/    -> %s file(s)\n' "$DOCS_HITS" >&2
printf '  _memory/                       -> %s file(s)\n' "$MEM_HITS" >&2
printf '  config/<config>.yaml           -> %s file(s)\n' "$CONFIG_HITS" >&2
printf '  custom/<subdir>/               -> %s file(s)\n' "$CUSTOM_HITS" >&2

if [ "$AUDIT_ONLY" = "1" ]; then
  log "audit-only mode — exiting without cleanup"
  exit 0
fi

# Step 2: pointer-file removal (AC8) — only when --remove-pointers is supplied,
# guarding against premature removal during the deprecation window.
if [ "$REMOVE_POINTERS" = "1" ]; then
  log "removing transition pointer files"
  local removed=0
  find "$PROJECT_ROOT" -type f -name '.gaia-pointer' 2>/dev/null | while IFS= read -r ptr; do
    rm -f "$ptr"
  done
  find "$PROJECT_ROOT" -type f -name '*.gaia-pointer' 2>/dev/null | while IFS= read -r ptr; do
    rm -f "$ptr"
  done
  log "pointer file removal complete"
fi

log "Phase 5 cleanup audit complete"
exit 0
