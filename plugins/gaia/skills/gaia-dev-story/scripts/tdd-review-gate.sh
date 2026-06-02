#!/usr/bin/env bash
# tdd-review-gate.sh — gaia-dev-story Steps 5/6/7 TDD review-gate decision
#
# Story:        E57-S2
# Refs:         FR-TDR-2, NFR-TDR-1, AF-2026-04-28-6
# ADRs:         ADR-067 (TDD Review Gate Default), ADR-057 (YOLO SST),
#               ADR-073 (YOLO contract), ADR-044 (Config Split).
#
# Purpose
# -------
# Deterministic SKIP / PROMPT / QA_AUTO decision for the dev-story TDD
# Red / Green / Refactor steps, based on (1) the story's `risk` (canonical)
# / `risk_level` (alias) frontmatter vs the configured threshold, (2) whether
# the requested <phase> is in the configured phases list, and (3) whether
# YOLO mode is active alongside `qa_auto_in_yolo`.
#
# Decision matrix (in this exact order):
#   1. threshold == off                     -> SKIP
#   2. <phase> NOT in configured phases     -> SKIP
#   3. risk-rank < threshold-rank           -> SKIP
#         (rank: off=0, low=1, medium=2, high=3)
#   4. YOLO active AND qa_auto_in_yolo=true -> QA_AUTO
#   5. else                                 -> PROMPT
#
# Safe defaults
# -------------
# Per AC5 / TC-TDR-03 / NFR-TDR-1, a missing or unrecognized story
# `risk_level` MUST default to `high`. The gate MUST fire (PROMPT or
# QA_AUTO) — silent SKIP on missing metadata defeats the gate purpose.
# A one-line stderr warning naming the missing field is emitted.
#
# Path-traversal rejection
# ------------------------
# Per AC6, `story_key` MUST match ^E[0-9]+-S[0-9]+$ exactly. The regex
# check runs BEFORE any path construction or filesystem access.
#
# Usage
# -----
#   tdd-review-gate.sh <story_key> <phase>
#
# Environment
# -----------
#   PROJECT_PATH         optional. Project root containing docs/. Defaults
#                        to the working directory.
#   GAIA_SHARED_CONFIG   optional. Forwarded to resolve-config.sh as the
#                        shared config path override.
#
# Exit codes
#   0 — decision printed on stdout (one of: SKIP, PROMPT, QA_AUTO)
#   2 — usage error (missing arg, malformed story_key, missing story file)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/tdd-review-gate.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

# ---------------------------------------------------------------------------
# Arg validation — runs BEFORE any read of config or story file (AC6).
# ---------------------------------------------------------------------------

if [ $# -lt 2 ]; then
  die "usage: tdd-review-gate.sh <story_key> <phase>"
fi

STORY_KEY="$1"
PHASE="$2"

# AC6 — story_key shape guard. Reject path traversal, lowercase, empty,
# anything that doesn't match the canonical key shape. The regex MUST run
# before any filesystem access.
if ! printf '%s' "$STORY_KEY" | grep -Eq '^E[0-9]+-S[0-9]+$'; then
  die "invalid story_key: '$STORY_KEY' (expected ^E[0-9]+-S[0-9]+\$)"
fi

# ---------------------------------------------------------------------------
# Resolve helper-script paths.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Skill-local helpers (story-parse).
STORY_PARSE="$SCRIPT_DIR/story-parse.sh"
# Shared-foundation helpers (resolve-config, yolo-mode). Walks up:
#   skills/gaia-dev-story/scripts/ -> skills/gaia-dev-story/ ->
#   skills/ -> gaia/ -> shared scripts/.
SHARED_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"
RESOLVE_CONFIG="$SHARED_SCRIPTS/resolve-config.sh"
YOLO_MODE="$SHARED_SCRIPTS/yolo-mode.sh"

# ---------------------------------------------------------------------------
# Locate the story file via the shared resolve-story-file.sh helper
# (E79-S7 / FR-476). Replaces the legacy private nullglob to keep all
# dev-story scripts on a single canonical resolution path. — E55-S13 D3.
# ---------------------------------------------------------------------------

# Path resolution — two-stage env-var precedence
# (E91-S3 / FR-SRF-3 / AI-2026-05-13-17):
#   Stage 1: CLAUDE_PROJECT_ROOT — non-git project-root workspace mode
#            (per CLAUDE.md §"Non-git project-root workspace (supported mode)").
#   Stage 2: PROJECT_PATH — legacy in-tree gaia-framework invocation override.
#   Stage 3: $(pwd) fallback.
# Sibling: AI-2026-05-13-12 walked up at the config-resolution layer
# (resolve-config.sh); E91-S3 mirrors it at the story-state layer.
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$(pwd)}}"
RESOLVE_STORY_FILE="$SHARED_SCRIPTS/resolve-story-file.sh"
if [ ! -x "$RESOLVE_STORY_FILE" ]; then
  die "shared helper missing or not executable: $RESOLVE_STORY_FILE"
fi
# shellcheck disable=SC1090
source "$RESOLVE_STORY_FILE"

# The resolver writes informational WARNING lines to stderr (e.g.,
# "legacy-flat path — ...") on success. The TDD-review gate is a one-line
# decision-emitter; surfacing the resolver's stderr here would pollute
# every gate invocation with migration-nag output. The legacy-flat warning
# is already surfaced by every other resolver caller (story-parse,
# dod-check, finalize, etc.), so dropping it here loses no information.
# AF-2026-05-21-27 canonical-first: pick .gaia/artifacts/ when present, else legacy.
if [ -d "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" ]; then
  _IMPL_DIR="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
else
  _IMPL_DIR="$PROJECT_ROOT/docs/implementation-artifacts"
fi
STORY_FILE=$(IMPLEMENTATION_ARTIFACTS="$_IMPL_DIR" \
             resolve_story_file "$STORY_KEY" 2>/dev/null) \
  || die "story file not found for key $STORY_KEY (resolve-story-file.sh non-zero)"

# ---------------------------------------------------------------------------
# Resolve story risk — prefer story-parse.sh (E57-S5); awk fallback if absent.
# ---------------------------------------------------------------------------
#
# story-parse.sh emits a 10-variable env-var dump. We only need RISK here.
# A subshell + eval keeps the parser outputs out of the parent env beyond
# what we explicitly capture.

extract_risk_local() {
  # Awk fallback — limit to YAML frontmatter and accept either canonical
  # `risk:` or PRD/ADR longhand alias `risk_level:`. Strips quotes /
  # whitespace, lowercases the verdict.
  awk '
    NR == 1 && /^---/ { in_fm = 1; next }
    in_fm && /^---/   { exit }
    in_fm             { print }
  ' "$1" \
    | grep -E '^(risk|risk_level):' \
    | head -1 \
    | sed -E 's/^[a-z_]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//; s/[[:space:]]+$//' \
    | tr '[:upper:]' '[:lower:]'
}

RISK_RAW=""
if [ -x "$STORY_PARSE" ]; then
  # Parse the story file via the canonical helper. Fall back to the awk
  # extractor only if story-parse.sh fails or returns empty RISK.
  if PARSE_OUT="$("$STORY_PARSE" "$STORY_FILE" 2>/dev/null)"; then
    # Eval inside a subshell to keep PARSE_OUT side-effects scoped.
    RISK_RAW="$(eval "$PARSE_OUT"; printf '%s' "${RISK:-}" | tr '[:upper:]' '[:lower:]')"
  fi
fi

if [ -z "$RISK_RAW" ]; then
  RISK_RAW="$(extract_risk_local "$STORY_FILE" || true)"
fi

# Risk-rank table: off=0, low=1, medium=2, high=3.
risk_rank() {
  case "$1" in
    off)    printf '0' ;;
    low)    printf '1' ;;
    medium) printf '2' ;;
    high)   printf '3' ;;
    *)      printf '' ;;   # unrecognized
  esac
}

RISK_RANK="$(risk_rank "$RISK_RAW")"

# AC5 — missing or unrecognized risk -> safe default: high. Emit a one-line
# stderr warning naming the missing field. The gate MUST still fire.
if [ -z "$RISK_RAW" ] || [ -z "$RISK_RANK" ]; then
  log "warning: story $STORY_KEY missing or unrecognized 'risk' frontmatter (got: '${RISK_RAW:-}'); defaulting to 'high' (safe default)"
  RISK_RAW="high"
  RISK_RANK="3"
fi

# ---------------------------------------------------------------------------
# Resolve config. Failures fall back to schema defaults from E57-S1.
# ---------------------------------------------------------------------------

resolve_field() {
  local field="$1" default="$2" out=""
  if [ -x "$RESOLVE_CONFIG" ]; then
    out="$("$RESOLVE_CONFIG" --field "$field" 2>/dev/null || true)"
  fi
  if [ -z "$out" ]; then
    out="$default"
  fi
  printf '%s' "$out"
}

THRESHOLD="$(resolve_field dev_story.tdd_review.threshold medium)"
PHASES_RAW="$(resolve_field dev_story.tdd_review.phases '[red]')"
QA_AUTO_IN_YOLO="$(resolve_field dev_story.tdd_review.qa_auto_in_yolo true)"

THRESHOLD_RANK="$(risk_rank "$THRESHOLD")"
# If threshold is somehow unrecognized (e.g., schema bypass), fall back to
# medium rather than crash — rank=2 keeps the gate firing for medium+ risk.
if [ -z "$THRESHOLD_RANK" ]; then
  log "warning: unrecognized threshold '$THRESHOLD'; defaulting to 'medium'"
  THRESHOLD="medium"
  THRESHOLD_RANK="2"
fi

# ---------------------------------------------------------------------------
# Decision matrix.
# ---------------------------------------------------------------------------

# 1. threshold == off -> SKIP unconditionally.
if [ "$THRESHOLD" = "off" ]; then
  printf 'SKIP\n'
  exit 0
fi

# 2. Phase membership check. PHASES_RAW shapes:
#      [red]                         (resolve-config canonical)
#      [red, green]                  (with whitespace)
#      red                           (legacy single-phase scalar)
# Strip surrounding [], split on commas, trim each item, compare to PHASE.
# Implementation: pipe through awk for deterministic trimming — cleaner than
# nested bash parameter-expansion gymnastics and safer under set -u.
phase_in_list() {
  local needle="$1" raw="$2"
  printf '%s\n' "$raw" \
    | sed -E 's/^\[//; s/\]$//' \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]"'"'"']+//; s/[[:space:]"'"'"']+$//' \
    | grep -Fxq "$needle"
}

if ! phase_in_list "$PHASE" "$PHASES_RAW"; then
  printf 'SKIP\n'
  exit 0
fi

# 3. Threshold rank comparison — risk below threshold -> SKIP.
if [ "$RISK_RANK" -lt "$THRESHOLD_RANK" ]; then
  printf 'SKIP\n'
  exit 0
fi

# 4. YOLO branch — QA_AUTO when YOLO active AND qa_auto_in_yolo=true.
YOLO=0
if [ -x "$YOLO_MODE" ]; then
  if "$YOLO_MODE" is_yolo 2>/dev/null; then
    YOLO=1
  fi
fi

if [ "$YOLO" -eq 1 ] && [ "$QA_AUTO_IN_YOLO" = "true" ]; then
  printf 'QA_AUTO\n'
  exit 0
fi

# 5. Default -> PROMPT.
printf 'PROMPT\n'
exit 0
