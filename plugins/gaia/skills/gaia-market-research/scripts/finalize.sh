#!/usr/bin/env bash
# finalize.sh — /gaia-market-research skill finalize (E28-S37 + E42-S2)
#
# E42-S2 extends the original Cluster 4 finalize scaffolding with a
# 28-item post-completion checklist (18 script-verifiable + 10
# LLM-checkable). The script-verifiable subset is enforced here; the
# LLM-checkable subset is delegated to the host LLM via a structured
# stderr payload that mirrors the E42-S1 / gaia-brainstorm convention.
#
# Responsibilities (per brief §Cluster 4 + story E42-S2):
#   1. Run the script-verifiable subset of the 28 V1 checklist items
#      against the market-research artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches gaia-brainstorm / E42-S1 contract).
#
# Exit codes:
#   0 — finalize succeeded; all 18 script-verifiable items PASS.
#   1 — one or more script-verifiable checklist items FAIL, or a
#       checkpoint/lifecycle-event failure. Failed item names are listed
#       on stderr under a "Checklist violations:" header followed by a
#       one-line remediation hint.
#
# Environment:
#   MARKET_RESEARCH_ARTIFACT  Absolute path to the artifact to validate.
#                             When unset, the script looks for
#                             .gaia/artifacts/planning-artifacts/market-research.md
#                             relative to the current working directory.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-market-research/finalize.sh"
WORKFLOW_NAME="market-research"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path ----------
# MARKET_RESEARCH_ARTIFACT wins when set (test fixtures + explicit
# invocation). Otherwise fall back to the canonical output location
# .gaia/artifacts/planning-artifacts/market-research.md in the current working
# directory. A missing artifact is NOT fatal to the observability side
# effects — the checklist run is simply skipped.
ARTIFACT=""
# AF-2026-05-21-25 three-tier idiom.
if [ -n "${MARKET_RESEARCH_ARTIFACT:-}" ]; then
  ARTIFACT="$MARKET_RESEARCH_ARTIFACT"
elif [ -f "docs/planning-artifacts/market-research.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/market-research.md"
elif [ -f ".gaia/artifacts/planning-artifacts/market-research.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/market-research.md"
fi

# ---------- 1. Run the 28-item checklist ----------
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
# Pass when an H2 heading with the given text (case-insensitive,
# literal body match; trailing content tolerated) is present.
heading_present() {
  local f="$1" text="$2"
  if grep -Ei "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

# pattern_present <file> <egrep-pattern>
# Case-insensitive regex match anywhere in the file.
pattern_present() {
  local f="$1" pat="$2"
  if grep -Eqi "$pat" "$f"; then
    echo "pass"
  else
    echo "fail"
  fi
}

# competitor_h3_count <file>
# Counts H3 subsections under ## Competitive Analysis, stopping at the
# next H2. Returns the integer count on stdout.
competitor_h3_count() {
  local f="$1"
  awk '
    /^##[[:space:]]+[Cc]ompetitive[[:space:]]+[Aa]nalysis/ { in_section = 1; next }
    in_section && /^##[[:space:]]/ { in_section = 0 }
    in_section && /^###[[:space:]]/ { count++ }
    END { print count + 0 }
  ' "$f"
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# dimension_with_assumptions <file> <dimension>
# Pass when, inside the ## Market Sizing section, a line containing the
# dimension token (TAM|SAM|SOM) is followed within the next 3 lines by
# a line that mentions "assumption" (case-insensitive). HTML comment
# lines (<!-- ... -->) are excluded so a commented-out assumption note
# cannot spoof a PASS. This is the canonical gate for E42-S2 AC2 — the
# negative fixture omits the assumptions text so these items FAIL.
dimension_with_assumptions() {
  local f="$1" dim="$2"
  awk -v dim="$dim" '
    BEGIN { in_section = 0; window = 0; result = "fail" }
    /^##[[:space:]]+[Mm]arket[[:space:]]+[Ss]izing/ { in_section = 1; next }
    in_section && /^##[[:space:]]/ { in_section = 0 }
    # Skip HTML comment lines entirely — a commented-out "assumptions"
    # note must not spoof a PASS.
    /^[[:space:]]*<!--/,/-->[[:space:]]*$/ { next }
    in_section {
      if (window > 0 && tolower($0) ~ /assumption/) { result = "pass"; exit }
      if (window > 0) { window-- }
      if (index($0, dim) > 0) { window = 3 }
    }
    END { print result }
  ' "$f"
}

if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 28-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-market-research (28 items — 18 script-verifiable, 10 LLM-checkable)\n' >&2

  # --- Script-verifiable items (18) ---
  item_check "SV-01" "Output artifact exists at resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Top-level title or YAML frontmatter present.
  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Scope (V1 ## Scope).
  item_check "SV-04" "Market/industry clearly defined" \
    "$(pattern_present "$ARTIFACT" '^[[:space:]]*[-*][[:space:]]+[Mm]arket|^##[[:space:]]+.*[Mm]arket')"
  item_check "SV-05" "Geographic scope stated" \
    "$(pattern_present "$ARTIFACT" '[Gg]eographic|[Gg]lobal|[Rr]egional|[Ll]ocal')"

  # Required V2 output sections (Step 6 of SKILL.md).
  item_check "SV-06" "Executive Summary section present" \
    "$(heading_present "$ARTIFACT" "Executive Summary")"
  item_check "SV-07" "Competitive Analysis section present" \
    "$(heading_present "$ARTIFACT" "Competitive Analysis")"
  item_check "SV-08" "Customer Segments section present" \
    "$(heading_present "$ARTIFACT" "Customer Segments")"
  item_check "SV-09" "Market Sizing section present" \
    "$(heading_present "$ARTIFACT" "Market Sizing")"
  item_check "SV-10" "Key Findings section present" \
    "$(heading_present "$ARTIFACT" "Key Findings")"
  item_check "SV-11" "Strategic Recommendations section present" \
    "$(heading_present "$ARTIFACT" "Strategic Recommendations")"

  # Competition — at least 3 competitors + positioning matrix.
  COMP_COUNT="$(competitor_h3_count "$ARTIFACT")"
  if [ "$COMP_COUNT" -ge 3 ]; then
    item_check "SV-12" "At least 3 competitors analyzed" pass
  else
    item_check "SV-12" "At least 3 competitors analyzed (found $COMP_COUNT)" fail
  fi
  item_check "SV-13" "Competitive positioning matrix included" \
    "$(pattern_present "$ARTIFACT" 'positioning[[:space:]]+matrix|\|.*\|.*\|')"

  # Market Sizing — TAM/SAM/SOM estimates AND assumptions. The three
  # "<dim> estimates provided with assumptions" items are the canonical
  # anchor for E42-S2 VCP-CHK-04: the negative fixture omits the
  # assumptions wording so these items MUST FAIL on that fixture.
  item_check "SV-14" "TAM estimate provided with assumptions" \
    "$(dimension_with_assumptions "$ARTIFACT" "TAM")"
  item_check "SV-15" "SAM estimate provided with assumptions" \
    "$(dimension_with_assumptions "$ARTIFACT" "SAM")"
  item_check "SV-16" "SOM estimate provided with assumptions" \
    "$(dimension_with_assumptions "$ARTIFACT" "SOM")"

  # Web Access — guard + limitation note (either direction).
  item_check "SV-17" "Web access guard / availability noted" \
    "$(pattern_present "$ARTIFACT" '[Ww]eb[[:space:]]+access')"
  item_check "SV-18" "Limitation noted in output if web access unavailable" \
    "$(pattern_present "$ARTIFACT" '[Ww]eb[[:space:]]+access|[Ll]imitation|[Aa]vailable')"

  # --- LLM-checkable items (10) ---
  printf '\n[LLM-CHECK] The following 10 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Target customer segments defined with evidence
  LLM-02 — User behavior patterns identified
  LLM-03 — Underserved customer needs highlighted
  LLM-04 — Strengths clearly articulated for each competitor
  LLM-05 — Weaknesses clearly articulated for each competitor
  LLM-06 — Competitive positioning mapped clearly
  LLM-07 — TAM assumptions clearly justified
  LLM-08 — SAM assumptions clearly justified
  LLM-09 — SOM assumptions clearly justified
  LLM-10 — Strategic recommendations actionable and grounded
EOF

  TOTAL_ITEMS=28
  LLM_ITEMS=10
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the market-research artifact to satisfy the failed items, then rerun /gaia-market-research.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no market-research artifact found (MARKET_RESEARCH_ARTIFACT unset and no market-research.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
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

# ---------- 4. Auto-save session memory (E45-S3 / ADR-061) ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt mandated by ADR-057 /
# FR-YOLO-2(f) is preserved. Failure is non-blocking — the auto-save
# helper itself logs warnings to stderr but never affects this script's
# exit code. SKILL_NAME is resolved from the parent directory name so
# the wire-in is identical across all 24 Phase 1-3 finalize.sh files.
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
