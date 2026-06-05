#!/usr/bin/env bash
# finalize.sh — /gaia-brainstorm skill finalize
#
# Implements a 24-item post-completion checklist
# (15 script-verifiable + 9 LLM-checkable).
# The script-verifiable subset is enforced here; the LLM-checkable subset
# is delegated to the host LLM via a structured stderr payload.
#
# Responsibilities:
#   1. Run the script-verifiable subset of the 24 checklist items
#      against the brainstorm artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write.
#
# Exit codes:
#   0 — finalize succeeded; all 15 script-verifiable items PASS.
#   1 — one or more script-verifiable checklist items FAIL, or a
#       checkpoint/lifecycle-event failure. Failed item names are listed
#       on stderr under a "Checklist violations:" header followed by a
#       one-line remediation hint.
#
# Environment:
#   BRAINSTORM_ARTIFACT  Absolute path to the artifact to validate. When
#                        unset, the script scans .gaia/artifacts/creative-artifacts/
#                        for the most recent brainstorm-*.md file.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-brainstorm/finalize.sh"
WORKFLOW_NAME="brainstorm-project"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path (three-tier idiom) ----------
# Tier 1 — BRAINSTORM_ARTIFACT env-var override wins when set.
# Tier 2 — legacy layout detected: legacy dir exists AND canonical dir does NOT
#          → use most-recent .gaia/artifacts/creative-artifacts/brainstorm-*.md.
# Tier 3 — canonical default: most-recent .gaia/artifacts/creative-artifacts/brainstorm-*.md.
# A missing artifact is NOT fatal — the checklist run is simply skipped.
ARTIFACT=""
if [ -n "${BRAINSTORM_ARTIFACT:-}" ]; then
  ARTIFACT="$BRAINSTORM_ARTIFACT"
elif [ -d "docs/creative-artifacts" ] && [ ! -d ".gaia/artifacts/creative-artifacts" ]; then
  # shellcheck disable=SC2012
  ARTIFACT="$(ls -1t docs/creative-artifacts/brainstorm-*.md 2>/dev/null | head -n 1 || true)"
elif [ -d ".gaia/artifacts/creative-artifacts" ]; then
  # shellcheck disable=SC2012
  ARTIFACT="$(ls -1t .gaia/artifacts/creative-artifacts/brainstorm-*.md 2>/dev/null | head -n 1 || true)"
fi

# ---------- 1. Run the 24-item checklist ----------
# The 15 script-verifiable items are enforced by item_check(); the 9
# LLM-checkable items are emitted as a structured payload for the host LLM.
VIOLATIONS=()
CHECKED=0
PASSED=0

# item_check <id> <description> <boolean-result>
# boolean-result: "pass" or "fail".
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

# heading_present <file> <heading-text>
# Returns "pass" when an H2 heading with the given text (case-insensitive,
# literal match; trailing content after the text is tolerated, e.g.
# "## Opportunity Areas (ranked)") is present anywhere in the file.
# heading_present() is a single shared implementation
# (plugins/gaia/scripts/lib/heading-present.sh) with one uniform, permissive
# regex accepting optional numbered+lettered outline prefixes (11, 11b, 1.2.3).
# Previously multiple finalize.sh scripts carried divergent inline copies, so
# the same heading passed one skill's check and failed another's. Sourced via a
# $0-relative path so it works whether or not this script defines
# PLUGIN_SCRIPTS_DIR.
_GAIA_HEADING_LIB="$(cd "$(dirname "$0")" && pwd)/../../../scripts/lib/heading-present.sh"
if [ -r "$_GAIA_HEADING_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_GAIA_HEADING_LIB"
else
  # Fallback inline definition (kept byte-equivalent to the shared lib) so the
  # checklist still runs if the lib is somehow unreadable.
  heading_present() {
    local f="$1" text="$2"
    if grep -Ei "^##[[:space:]]+([0-9]+[a-z]?(\.[0-9]+[a-z]?)*\.?[[:space:]]+)?${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
      echo "pass"
    else
      echo "fail"
    fi
  }
fi

# opportunity_count <file>
# Counts list items (- or N.) under the ## Opportunity Areas heading,
# stopping at the next H2. Returns the integer count on stdout.
opportunity_count() {
  local f="$1"
  awk '
    /^##[[:space:]]+[Oo]pportunity[[:space:]][Aa]reas/ { in_section = 1; next }
    in_section && /^##[[:space:]]/ { in_section = 0 }
    in_section && /^[[:space:]]*(-|\*|[0-9]+\.)[[:space:]]/ { count++ }
    END { print count + 0 }
  ' "$f"
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 24-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-brainstorm (24 items — 15 script-verifiable, 9 LLM-checkable)\n' >&2

  # --- Script-verifiable items (15) ---
  item_check "SV-01" "Output artifact exists at resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  case "$(basename "$ARTIFACT")" in
    brainstorm-*.md) item_check "SV-03" "Output filename matches brainstorm-{slug}.md pattern" pass ;;
    *)               item_check "SV-03" "Output filename matches brainstorm-{slug}.md pattern" fail ;;
  esac

  item_check "SV-04" "Vision Summary section present" "$(heading_present "$ARTIFACT" "Vision Summary")"
  item_check "SV-05" "Target Users section present"   "$(heading_present "$ARTIFACT" "Target Users")"
  item_check "SV-06" "Pain Points section present"    "$(heading_present "$ARTIFACT" "Pain Points")"
  item_check "SV-07" "Differentiators section present" \
    "$(heading_present "$ARTIFACT" "Differentiators")"
  item_check "SV-08" "Competitive Landscape section present" \
    "$(heading_present "$ARTIFACT" "Competitive Landscape")"
  item_check "SV-09" "Opportunity Areas section present" \
    "$(heading_present "$ARTIFACT" "Opportunity Areas")"

  OPP_COUNT="$(opportunity_count "$ARTIFACT")"
  if [ "$OPP_COUNT" -ge 3 ]; then
    item_check "SV-10" "At least 3 opportunity areas identified" pass
  else
    item_check "SV-10" "At least 3 opportunity areas identified (found $OPP_COUNT)" fail
  fi

  item_check "SV-11" "Parking Lot section present" \
    "$(heading_present "$ARTIFACT" "Parking Lot")"
  item_check "SV-12" "Next Steps section present" \
    "$(heading_present "$ARTIFACT" "Next Steps")"

  # Creative-artifacts/ was checked before the session started — verified by
  # the artifact living in that directory or being pointed-at explicitly.
  # Accept BARE relative paths too. The original arms all required a `/`
  # somewhere before the directory name (the `*/dir/*` form), so a
  # project-root relative path like `.gaia/artifacts/creative-artifacts/
  # brainstorm-yara.md` (no leading slash, no parent component) matched none of
  # them and SV-13 falsely FAILed despite the artifact being in the correct
  # canonical directory.
  case "$ARTIFACT" in
    */.gaia/artifacts/creative-artifacts/*|*/docs/creative-artifacts/*|*/fixtures/*|/*) item_check "SV-13" "Creative-artifacts/ checked for prior outputs" pass ;;
    .gaia/artifacts/creative-artifacts/*|docs/creative-artifacts/*|fixtures/*)         item_check "SV-13" "Creative-artifacts/ checked for prior outputs" pass ;;
    *)                                            item_check "SV-13" "Creative-artifacts/ checked for prior outputs" fail ;;
  esac

  # Artifact has a top-level title (H1) or YAML frontmatter.
  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-14" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-14" "Artifact has frontmatter or top-level title" fail
  fi

  # Opportunities listed as structured list (>=1 bullet/numbered item).
  if [ "$OPP_COUNT" -ge 1 ]; then
    item_check "SV-15" "Opportunities listed as a structured list" pass
  else
    item_check "SV-15" "Opportunities listed as a structured list" fail
  fi

  # --- LLM-checkable items (9) — emitted as a structured payload ---
  # These items require semantic judgment and are delegated back to the
  # host LLM. The payload format is one JSON-like line per item on stderr,
  # prefixed with [LLM-CHECK].
  printf '\n[LLM-CHECK] The following 9 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Business idea clearly articulated
  LLM-02 — Target users well-defined
  LLM-03 — Pain points specific and grounded in user information
  LLM-04 — Differentiators stated clearly vs competitors
  LLM-05 — Direct and indirect competitors identified
  LLM-06 — Competitive positioning mapped
  LLM-07 — Each opportunity has supporting evidence
  LLM-08 — Opportunities ranked by impact and feasibility
  LLM-09 — Parking-lot entries include deprioritization reasoning and revival conditions
EOF

  # Summary — always printed so observers see the checklist outcome even
  # when all items PASS.
  TOTAL_ITEMS=24
  LLM_ITEMS=9
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the brainstorm artifact to satisfy the failed items, then rerun /gaia-brainstorm finalize.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no brainstorm artifact found (BRAINSTORM_ARTIFACT unset and no brainstorm-*.md at .gaia/artifacts/creative-artifacts/ or docs/creative-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 5 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 3. Emit lifecycle event (observability — never suppressed) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

# ---------- 4. Auto-save session memory ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt is preserved. Failure is
# non-blocking — the auto-save helper itself logs warnings to stderr but
# never affects this script's exit code. SKILL_NAME is resolved from the
# parent directory name so the wire-in is identical across all Phase 1-3
# finalize.sh files.
AUTOSAVE_LIB="$PLUGIN_SCRIPTS_DIR/lib/auto-save-memory.sh"
SKILL_NAME="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"
if [ -f "$AUTOSAVE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$AUTOSAVE_LIB"
  if ! _auto_save_memory "$SKILL_NAME" "${ARTIFACT:-}"; then
    AUTOSAVE_RC=$?
    if [ "$AUTOSAVE_RC" -eq 64 ]; then
      log "auto-save aborted: cannot resolve agent sidecar for skill $SKILL_NAME"
    fi
  fi
else
  log "auto-save-memory.sh not found at $AUTOSAVE_LIB — skipping auto-save (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit "$CHECKLIST_STATUS"
