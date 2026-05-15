#!/usr/bin/env bash
# cache-refresh-advisory.sh — gaia-dev-story Step 14b advisory (E92-S4).
#
# Story: E92-S4 — Plugin-cache refresh dogfooding playbook.
# Anchor: AI-RETRO-S46-4 (sprint-46 retro action item).
# Refs: feedback_plugin_cache_refresh_after_merge memory.
#
# Background:
#   The Claude Code substrate caches plugin SKILL.md and scripts at
#   ~/.claude/plugins/cache/<plugin>/<version>/ at session start.
#   Post-merge changes to those files DO NOT propagate to the running
#   session — the cached pre-merge version executes until the operator
#   refreshes the cache. This is a dogfooding-loop-specific friction;
#   marketplace consumers who install AFTER the merge get the new
#   behavior on first invocation.
#
# Contract (mirrors Step 6b conditional-check-hints.sh non-blocking
# advisory pattern):
#   - Reads a list of changed files (one per line) from a file path
#     supplied via --diff-files, OR from stdin when --diff-files is
#     not provided.
#   - Filters that list to entries matching ANY of:
#       plugins/gaia/skills/*/SKILL.md
#       plugins/gaia/skills/*/scripts/*.sh
#       plugins/gaia/agents/*.md
#       plugins/gaia/hooks/*.json
#   - If at least one match exists, emits ONE advisory line to stderr:
#       step14b_advisory: plugin-cache refresh recommended — touched files: <list>
#     The <list> is a comma-separated enumeration of the matched files
#     (at most 10 entries; longer lists truncated with ",...").
#   - If no match, emits nothing to stderr.
#   - ALWAYS exits 0 (non-blocking). Caller continues to Step 15
#     regardless.
#
# Usage:
#   cache-refresh-advisory.sh --diff-files <path>
#   cache-refresh-advisory.sh < <(git diff --name-only ...)
#
# Filter rules (pattern matches against the path as listed, no globbing):
#   include: matches `plugins/gaia/skills/<any>/SKILL.md`,
#            `plugins/gaia/skills/<any>/scripts/<any>.sh`,
#            `plugins/gaia/agents/<any>.md`, or
#            `plugins/gaia/hooks/<any>.json`.
#   exclude: paths under `plugins/gaia/tests/`, `docs/`, `.github/`,
#            and any `*.bats` file are NEVER matched (defense-in-depth
#            mirroring forbidden-sentinel-scan.sh's production-path
#            filter).
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/cache-refresh-advisory.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------- Arg parse ----------
DIFF_FILES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --diff-files)
      [ $# -ge 2 ] || { log "--diff-files requires a value"; exit 2; }
      DIFF_FILES="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,55p' "$0" | sed -n '/^# /s/^# //p'
      exit 0 ;;
    *)
      log "unknown flag: $1"; exit 2 ;;
  esac
done

# ---------- Read input ----------
if [ -n "$DIFF_FILES" ]; then
  [ -f "$DIFF_FILES" ] || { log "diff-files not found: $DIFF_FILES"; exit 2; }
  INPUT="$(cat "$DIFF_FILES")"
else
  INPUT="$(cat)"
fi

# Empty input -> no advisory.
if [ -z "${INPUT// /}" ]; then
  exit 0
fi

# ---------- Filter ----------
MATCHED=""
COUNT=0
MAX=10
TRUNCATED=0

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Exclusions first (defense in depth).
  case "$line" in
    plugins/gaia/tests/*)     continue ;;
    docs/*)                   continue ;;
    .github/*)                continue ;;
    *.bats)                   continue ;;
  esac

  # Inclusions.
  case "$line" in
    plugins/gaia/skills/*/SKILL.md)            ;;
    plugins/gaia/skills/*/scripts/*.sh)        ;;
    plugins/gaia/agents/*.md)                  ;;
    plugins/gaia/hooks/*.json)                 ;;
    *)
      continue ;;
  esac

  if [ "$COUNT" -lt "$MAX" ]; then
    if [ -z "$MATCHED" ]; then
      MATCHED="$line"
    else
      MATCHED="$MATCHED, $line"
    fi
  else
    TRUNCATED=1
  fi
  COUNT=$((COUNT + 1))
done <<EOF
$INPUT
EOF

if [ "$COUNT" -eq 0 ]; then
  exit 0
fi

if [ "$TRUNCATED" -eq 1 ]; then
  MATCHED="${MATCHED},..."
fi

# Exactly one advisory line; format mirrors NFR-DSH-5 single-line gate-log.
log "step14b_advisory: plugin-cache refresh recommended — touched files: $MATCHED"
exit 0
