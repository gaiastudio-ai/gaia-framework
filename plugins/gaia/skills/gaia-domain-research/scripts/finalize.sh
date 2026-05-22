#!/usr/bin/env bash
# finalize.sh — /gaia-domain-research skill finalize (E28-S37 + E42-S3)
#
# E42-S3 extends the original Cluster 4 finalize scaffolding with a
# 22-item post-completion checklist (13 script-verifiable + 9
# LLM-checkable). The script-verifiable subset is enforced here; the
# LLM-checkable subset is delegated to the host LLM via a structured
# stderr payload that mirrors the E42-S1 / E42-S2 convention.
#
# Responsibilities (per brief §Cluster 4 + story E42-S3):
#   1. Run the script-verifiable subset of the 22 V1 checklist items
#      against the domain-research artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches gaia-brainstorm / E42-S1 and gaia-market-research / E42-S2
# contract).
#
# Exit codes:
#   0 — finalize succeeded; all 13 script-verifiable items PASS.
#   1 — one or more script-verifiable checklist items FAIL, or a
#       checkpoint/lifecycle-event failure. Failed item names are listed
#       on stderr under a "Checklist violations:" header followed by a
#       one-line remediation hint.
#
# Environment:
#   DOMAIN_RESEARCH_ARTIFACT  Absolute path to the artifact to validate.
#                             When unset, the script looks for
#                             .gaia/artifacts/planning-artifacts/domain-research.md
#                             relative to the current working directory.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-domain-research/finalize.sh"
WORKFLOW_NAME="domain-research"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path ----------
# DOMAIN_RESEARCH_ARTIFACT wins when set (test fixtures + explicit
# invocation). Otherwise fall back to the canonical output location
# .gaia/artifacts/planning-artifacts/domain-research.md in the current working
# directory. A missing artifact is NOT fatal to the observability side
# effects — the checklist run is simply skipped.
ARTIFACT=""
# AF-2026-05-21-25 three-tier idiom: env-var → positive-evidence legacy → canonical default.
if [ -n "${DOMAIN_RESEARCH_ARTIFACT:-}" ]; then
  ARTIFACT="$DOMAIN_RESEARCH_ARTIFACT"
elif [ -f "docs/planning-artifacts/domain-research.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/domain-research.md"
elif [ -f ".gaia/artifacts/planning-artifacts/domain-research.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/domain-research.md"
fi

# ---------- 1. Run the 22-item checklist ----------
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

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# glossary_term_count <file>
# Counts bullet-list items under the ## Terminology Glossary heading,
# stopping at the next H2. Returns the integer count on stdout. This is
# the AC2 anchor — the negative fixture omits the glossary entirely so
# the count is 0.
glossary_term_count() {
  local f="$1"
  awk '
    /^##[[:space:]]+[Tt]erminology[[:space:]]+[Gg]lossary/ { in_section = 1; next }
    in_section && /^##[[:space:]]/ { in_section = 0 }
    in_section && /^[[:space:]]*(-|\*|[0-9]+\.)[[:space:]]/ { count++ }
    END { print count + 0 }
  ' "$f"
}

if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 22-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-domain-research (22 items — 13 script-verifiable, 9 LLM-checkable)\n' >&2

  # --- Script-verifiable items (13) ---
  item_check "SV-01" "Output artifact exists at resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Top-level title or YAML frontmatter present.
  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Scope — V1 "Domain/industry clearly defined" and "Focus areas identified".
  item_check "SV-04" "Domain/industry clearly defined" \
    "$(pattern_present "$ARTIFACT" '[Dd]omain|[Ii]ndustry')"
  item_check "SV-05" "Focus areas identified" \
    "$(pattern_present "$ARTIFACT" '[Ff]ocus[[:space:]]+area|^##[[:space:]]+[Dd]omain[[:space:]]+[Oo]verview')"

  # Required V2 output sections (Step 5 of SKILL.md).
  item_check "SV-06" "Domain Overview section present" \
    "$(heading_present "$ARTIFACT" "Domain Overview")"
  item_check "SV-07" "Key Players section present" \
    "$(heading_present "$ARTIFACT" "Key Players")"
  item_check "SV-08" "Regulatory Landscape section present" \
    "$(heading_present "$ARTIFACT" "Regulatory Landscape")"
  item_check "SV-09" "Trends section present" \
    "$(heading_present "$ARTIFACT" "Trends")"
  item_check "SV-10" "Terminology Glossary section present" \
    "$(heading_present "$ARTIFACT" "Terminology Glossary")"
  item_check "SV-11" "Risk Assessment section present" \
    "$(heading_present "$ARTIFACT" "Risk Assessment")"
  item_check "SV-12" "Recommendations section present" \
    "$(heading_present "$ARTIFACT" "Recommendations")"

  # Glossary population — the V1 "Terminology glossary included" item
  # requires the section AND at least 3 glossary entries so an empty
  # heading cannot spoof a PASS.
  TERM_COUNT="$(glossary_term_count "$ARTIFACT")"
  if [ "$TERM_COUNT" -ge 3 ]; then
    item_check "SV-13" "Terminology Glossary populated with at least 3 terms" pass
  else
    item_check "SV-13" "Terminology Glossary populated with at least 3 terms (found $TERM_COUNT)" fail
  fi

  # --- LLM-checkable items (9) ---
  # These items require semantic judgment and are delegated back to the
  # host LLM. Payload format mirrors the E42-S1 / E42-S2 convention.
  printf '\n[LLM-CHECK] The following 9 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Key players identified with roles and context
  LLM-02 — Regulatory landscape captures applicable regulations with scope
  LLM-03 — Industry trends mapped with evidence or direction of travel
  LLM-04 — Terminology glossary entries are accurate and domain-specific
  LLM-05 — Regulatory and compliance risks identified with impact/likelihood
  LLM-06 — Technical risks specific to the domain identified
  LLM-07 — Market and competitive risks evaluated
  LLM-08 — Web access availability and limitations noted if web access unavailable
  LLM-09 — Recommendations actionable and grounded in the risk assessment
EOF

  TOTAL_ITEMS=22
  LLM_ITEMS=9
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the domain-research artifact to satisfy the failed items, then rerun /gaia-domain-research.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no domain-research artifact found (DOMAIN_RESEARCH_ARTIFACT unset and no domain-research.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
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
