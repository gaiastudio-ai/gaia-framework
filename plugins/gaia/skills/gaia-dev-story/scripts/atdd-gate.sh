#!/usr/bin/env bash
# atdd-gate.sh — gaia-dev-story Step 2b ATDD gate (E55-S5)
#
# Purpose:
#   For high-risk stories, halt the dev-story workflow at Step 2b unless an
#   ATDD scenarios file exists under .gaia/artifacts/test-artifacts/. For non-high-risk
#   stories, exit 0 unconditionally.
#
# Per FR-DSH-6 / ADR-073, the canonical glob set is:
#   .gaia/artifacts/test-artifacts/atdd-{epic_key}*.md   — epic-level ATDD coverage
#   .gaia/artifacts/test-artifacts/atdd-{story_key}*.md  — story-level ATDD coverage
# Either glob matching at least one file satisfies the gate.
#
# Field-name alias note: the canonical story template uses `risk:` in
# frontmatter. FR-DSH-6 / ADR-073 prose refers to `risk_level` — these are
# the same semantic field on the target story being processed by
# /gaia-dev-story. This script reads the canonical `risk:` line; if it is
# absent we also scan for `risk_level:` for forward compatibility.
#
# Usage:
#   atdd-gate.sh <story_key>
#
# Environment:
#   PROJECT_PATH — optional. Project root containing docs/. Defaults to the
#                  current working directory.
#
# Exit codes:
#   0 — gate passes (non-high risk, OR high-risk with at least one ATDD file)
#   1 — gate halts  (high-risk story with no matching ATDD file)
#   2 — usage error (missing story_key, missing story file, etc.)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/atdd-gate.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

if [ $# -lt 1 ]; then
  die "usage: atdd-gate.sh <story_key>" 2
fi

STORY_KEY="$1"

# Story-key shape guard (defense-in-depth — the harness already validates this
# under E55-S2's T-37 mitigation, but the gate is callable as a standalone
# script so we re-check here).
if ! printf '%s' "$STORY_KEY" | grep -Eq '^E[0-9]+-S[0-9]+$'; then
  die "invalid story_key: $STORY_KEY (expected ^E[0-9]+-S[0-9]+\$)" 2
fi

EPIC_KEY="${STORY_KEY%-S*}"

PROJECT_ROOT="${PROJECT_PATH:-$(pwd)}"

# AF-2026-05-21-4 Finding 1 fix: route through the shared resolver helper
# so the script honors ADR-111 canonical .gaia/artifacts/ first and legacy
# docs/ as fallback. Previous hardcoded `$PROJECT_ROOT/docs/implementation-artifacts`
# made the gate fail-fast on every story under the .gaia/ canonical layout
# (every low-risk story trips the gate-not-applicable path with a misleading
# "story file not found" error before the risk field is even read).
#
# Resolve under both layouts via the helper. IMPL_DIR is still derived for
# the test-artifacts ATDD glob below; honor both canonical .gaia/ and legacy
# docs/ for that secondary lookup too.
if [ -d "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" ]; then
  IMPL_DIR="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
else
  IMPL_DIR="$PROJECT_ROOT/docs/implementation-artifacts"
fi
if [ -d "$PROJECT_ROOT/.gaia/artifacts/test-artifacts" ]; then
  TEST_DIR="$PROJECT_ROOT/.gaia/artifacts/test-artifacts"
else
  TEST_DIR="$PROJECT_ROOT/docs/test-artifacts"
fi

# Locate the story file via the shared resolver helper (E79-S7 / FR-476).
# Helper honors the E79-S4 nested-over-flat precedence rule and the ADR-111
# canonical-first contract.
SCRIPT_DIR_RESOLVER="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../../scripts" 2>/dev/null && pwd )"
RESOLVER="$SCRIPT_DIR_RESOLVER/resolve-story-file.sh"
STORY_FILE=""
if [ -x "$RESOLVER" ]; then
  STORY_FILE="$( PROJECT_PATH="$PROJECT_ROOT" IMPLEMENTATION_ARTIFACTS="$IMPL_DIR" \
    bash "$RESOLVER" "$STORY_KEY" 2>/dev/null || true )"
fi

# Fallback path-glob if the helper was unavailable (deprecated v1.131.x).
if [ -z "$STORY_FILE" ]; then
  shopt -s nullglob
  STORY_MATCHES=( "$IMPL_DIR/${STORY_KEY}-"*.md "$IMPL_DIR"/epic-*/stories/"${STORY_KEY}-"*.md )
  shopt -u nullglob
  if [ "${#STORY_MATCHES[@]}" -gt 0 ]; then
    STORY_FILE="${STORY_MATCHES[0]}"
  fi
fi

if [ -z "$STORY_FILE" ] || [ ! -f "$STORY_FILE" ]; then
  die "story file not found for key $STORY_KEY (searched $IMPL_DIR/${STORY_KEY}-*.md and $IMPL_DIR/epic-*/stories/${STORY_KEY}-*.md)" 2
fi

# Read the risk field from frontmatter. Accept `risk:` (canonical) or
# `risk_level:` (PRD/ADR longhand alias). Strip surrounding quotes and
# whitespace; lowercase the verdict.
extract_risk() {
  local file="$1"
  # Limit to the YAML frontmatter (between the first two `---` lines).
  awk '
    NR == 1 && /^---/ { in_fm = 1; next }
    in_fm && /^---/   { exit }
    in_fm             { print }
  ' "$file" \
    | grep -E '^(risk|risk_level):' \
    | head -1 \
    | sed -E 's/^[a-z_]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//; s/[[:space:]]+$//' \
    | tr '[:upper:]' '[:lower:]'
}

RISK="$(extract_risk "$STORY_FILE" || true)"

# Non-high risk → pass unconditionally.
if [ "$RISK" != "high" ]; then
  log "risk=${RISK:-unset}; ATDD gate not enforced (high-risk only) — pass"
  exit 0
fi

# High risk → require at least one matching ATDD file.
#
# Issue #1108 — resolve through the SAME per-story helper that /gaia-atdd
# writes with and /gaia-sprint-plan checks with, so the gate accepts the
# canonical NESTED home (test-artifacts/epic-{slug}/{key}-{slug}/atdd.md, per
# AF-2026-05-30-1 / Test03 §7.3) — not just the legacy flat globs. Before this,
# the gate only looked at `atdd-{key}*.md` directly under test-artifacts/, so a
# high-risk story whose ATDD was generated by /gaia-atdd (which writes nested)
# HALTed even though the artifact existed. The resolver's --existing-only
# contract already checks nested-then-flat and exits 0 with the path when
# either rung exists, exit 1 when none does. This is the primary check; the
# flat globs below remain as a defensive fallback when the helper is absent.
RESOLVE_TEST_ARTIFACT="$SCRIPT_DIR_RESOLVER/lib/resolve-test-artifact-per-story.sh"
if [ -f "$RESOLVE_TEST_ARTIFACT" ]; then
  # Pass the resolved test- and impl-artifacts dirs explicitly; these override
  # the resolver's own PROJECT_ROOT-derived defaults, so the gate and the
  # resolver agree on the layout regardless of which root env var the resolver
  # reads internally.
  if ATDD_RESOLVED="$( TEST_ARTIFACTS="$TEST_DIR" IMPLEMENTATION_ARTIFACTS="$IMPL_DIR" \
      bash "$RESOLVE_TEST_ARTIFACT" atdd "$STORY_KEY" --existing-only 2>/dev/null )" \
      && [ -n "$ATDD_RESOLVED" ] && [ -f "$ATDD_RESOLVED" ]; then
    log "risk=high; ATDD file present ($ATDD_RESOLVED) — pass"
    exit 0
  fi
fi

# Defensive fallback — flat-layout globs (legacy / helper-unavailable).
#
# Test10 F-34 — epic-wide glob prefix-boundary guard. The earlier shape
# `atdd-${EPIC_KEY}*.md` was too permissive: with EPIC_KEY=E1 it matched
# `atdd-E10-*.md`, `atdd-E11-*.md`, etc. Tighten with a `{key}-` boundary
# so the epic glob matches `atdd-E1-...md` exclusively (or the exact
# `atdd-E1.md` no-suffix form via a second glob entry).
shopt -s nullglob
# Bare literals like `atdd-${EPIC_KEY}.md` survive nullglob (no glob
# metacharacter to expand), so post-filter the array with a `-f` existence
# test to weed them out when the file is absent. Without this filter,
# `${#ATDD_MATCHES[@]} -gt 0` would always be true and the high-risk gate
# would NEVER halt.
ATDD_CANDIDATES=(
  "$TEST_DIR/atdd-${EPIC_KEY}.md"
  "$TEST_DIR/atdd-${EPIC_KEY}-"*.md
  "$TEST_DIR/atdd-${STORY_KEY}.md"
  "$TEST_DIR/atdd-${STORY_KEY}-"*.md
)
shopt -u nullglob

ATDD_MATCHES=()
for _c in "${ATDD_CANDIDATES[@]}"; do
  [ -f "$_c" ] && ATDD_MATCHES+=("$_c")
done

if [ "${#ATDD_MATCHES[@]}" -gt 0 ]; then
  log "risk=high; ATDD file present (${ATDD_MATCHES[0]}) — pass"
  exit 0
fi

# AF-2026-05-29-1 / Test08 F-15: explicit escape hatch for operators who
# consciously accept the risk and want to proceed without ATDD. Mirrors the
# GAIA_SKIP_BRAINSTORM=1 pattern used by /gaia-product-brief (Test05 F-16).
# WARN — never pass silently — so the deferred work surfaces in the run log
# and downstream review gates have a chance to catch up.
if [ "${GAIA_SKIP_ATDD:-0}" = "1" ]; then
  log "risk=high; ATDD gate skipped via GAIA_SKIP_ATDD=1 — proceeding WITHOUT atdd scenarios."
  log "      run /gaia-atdd $STORY_KEY before merging to satisfy the deferred coverage gap."
  exit 0
fi

log "HALT: high-risk story $STORY_KEY has no ATDD file."
log "      checked the canonical per-story home (/gaia-atdd writes here):"
log "        $TEST_DIR/epic-{slug}/${STORY_KEY}-{slug}/atdd.md"
log "      and the legacy flat fallbacks (prefix-boundary guarded — Test10 F-34):"
log "        $TEST_DIR/atdd-${EPIC_KEY}.md"
log "        $TEST_DIR/atdd-${EPIC_KEY}-*.md"
log "        $TEST_DIR/atdd-${STORY_KEY}.md"
log "        $TEST_DIR/atdd-${STORY_KEY}-*.md"
log "      run /gaia-atdd $STORY_KEY to generate the scenarios file before /gaia-dev-story."
log "      or, if you consciously accept the risk: GAIA_SKIP_ATDD=1 /gaia-dev-story $STORY_KEY"
exit 1
