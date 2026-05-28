#!/usr/bin/env bash
# finalize.sh — /gaia-tech-research skill finalize (E28-S38 + E42-S4)
#
# E42-S4 extends the original Cluster 4 finalize scaffolding with a
# 22-item post-completion checklist (13 script-verifiable + 9
# LLM-checkable). The script-verifiable subset is enforced here; the
# LLM-checkable subset is delegated to the host LLM via a structured
# stderr payload that mirrors the E42-S1 / E42-S2 / E42-S3 convention.
#
# Responsibilities (per brief §Cluster 4 + story E42-S4):
#   1. Run the script-verifiable subset of the 22 V1 checklist items
#      against the technical-research artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1 / E42-S2 / E42-S3 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 13 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 4 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       "no artifact to validate" AC4 violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   TECH_RESEARCH_ARTIFACT  Absolute path to the artifact to validate.
#                           When set, the script runs the 22-item
#                           checklist against it. When set but the
#                           file does not exist, AC4 fires — a single
#                           "no artifact to validate" violation is
#                           emitted and the script exits non-zero.
#                           When unset, the script looks for
#                           .gaia/artifacts/planning-artifacts/technical-research.md
#                           relative to the current working directory.
#                           If neither is present, the checklist run
#                           is skipped (classic Cluster 4 behaviour —
#                           observability still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-tech-research/finalize.sh"
WORKFLOW_NAME="technical-research"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path ----------
# TECH_RESEARCH_ARTIFACT wins when set (test fixtures + explicit
# invocation). If it is set but the file is missing, AC4 fires. If
# unset, fall back to the canonical output location
# .gaia/artifacts/planning-artifacts/technical-research.md. If neither is present
# the checklist is simply skipped (observability still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${TECH_RESEARCH_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$TECH_RESEARCH_ARTIFACT"
elif [ -f ".gaia/artifacts/planning-artifacts/technical-research.md" ]; then
  # ADR-111 smart-fallback: .gaia/artifacts/ first, legacy docs/ second.
  ARTIFACT=".gaia/artifacts/planning-artifacts/technical-research.md"
elif [ -f "docs/planning-artifacts/technical-research.md" ]; then
  ARTIFACT="docs/planning-artifacts/technical-research.md"
fi

# ---------- 1. Run the 22-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

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
# Pass when an H2 heading whose body begins with the given text
# (case-insensitive; trailing content tolerated) is present.
# AF-2026-05-27-8 / Test06 F-001/F-004/F-009: heading_present() is now a single
# shared implementation (plugins/gaia/scripts/lib/heading-present.sh) with one
# uniform, permissive regex accepting optional numbered+lettered outline
# prefixes (11, 11b, 1.2.3). Previously 17 finalize.sh scripts carried THREE
# divergent inline copies, so the same heading passed one skill's check and
# failed another's. Sourced via a $0-relative path so it works whether or not
# this script defines PLUGIN_SCRIPTS_DIR.
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

# alternatives_count <file>
# Counts distinct technology alternatives presented for comparison.
# Uses the evaluation table header row as the primary signal — one
# "dimension" column plus one column per technology. A minimum of 2
# non-dimension columns means at least 2 alternatives were compared.
# Falls back to a permissive heuristic: count the number of bolded
# technology names in the "Technology Overview" or "Evaluation Matrix"
# section.
alternatives_count() {
  local f="$1"
  # Primary signal: first pipe table whose header begins with
  # "| Dimension". Count pipes on the header row; each non-dimension
  # column is an alternative.
  local cols
  cols="$(awk '
    /^\|[[:space:]]*[Dd]imension[[:space:]]*\|/ {
      # Count pipe characters; columns = pipes - 1.
      n = gsub(/\|/, "|"); print (n - 1); exit
    }
  ' "$f")"
  if [ -n "${cols:-}" ] && [ "${cols:-0}" -ge 2 ] 2>/dev/null; then
    # Header row has dimension + alternatives. Count alternatives.
    echo $((cols - 1))
    return
  fi
  # Fallback: count distinct bolded technology names in the first
  # 60 lines under "Technology Overview".
  awk '
    /^##[[:space:]]+[Tt]echnology[[:space:]]+[Oo]verview/ { in_section = 1; next }
    in_section && /^##[[:space:]]/ { in_section = 0 }
    in_section {
      # Match **Bolded Tech Names** tokens.
      while (match($0, /\*\*[^*]+\*\*/)) {
        name = substr($0, RSTART + 2, RLENGTH - 4)
        if (!(name in seen)) { seen[name] = 1; count++ }
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END { print count + 0 }
  ' "$f"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk. Emit a single "no artifact to validate"
  # violation and fall through to observability side effects.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-tech-research to produce .gaia/artifacts/planning-artifacts/technical-research.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 22-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-tech-research (22 items — 13 script-verifiable, 9 LLM-checkable)\n' >&2

  # --- Script-verifiable items (13) ---
  item_check "SV-01" "Output artifact exists at docs/planning-artifacts/technical-research.md" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Top-level title or YAML frontmatter present.
  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Scope — V1 "Technologies clearly identified", "Use case context
  # provided", "Constraints documented".
  item_check "SV-04" "Technologies clearly identified" \
    "$(pattern_present "$ARTIFACT" '[Tt]echnologies?[[:space:]]+[Ee]valuated|^##[[:space:]]+[Tt]echnology[[:space:]]+[Oo]verview')"
  item_check "SV-05" "Use case context provided" \
    "$(pattern_present "$ARTIFACT" '[Uu]se[[:space:]]+case|[Pp]roblem[[:space:]]+context')"
  item_check "SV-06" "Constraints documented" \
    "$(pattern_present "$ARTIFACT" '[Cc]onstraints?')"

  # Required V2 output sections (Step 5 of SKILL.md).
  item_check "SV-07" "Technology Overview section present" \
    "$(heading_present "$ARTIFACT" "Technology Overview")"
  item_check "SV-08" "Evaluation Matrix section present" \
    "$(heading_present "$ARTIFACT" "Evaluation Matrix")"
  item_check "SV-09" "Trade-off Analysis section present" \
    "$(heading_present "$ARTIFACT" "Trade-off Analysis")"
  item_check "SV-10" "Recommendation section present" \
    "$(heading_present "$ARTIFACT" "Recommendation")"
  item_check "SV-11" "Migration / Adoption Considerations section present" \
    "$(heading_present "$ARTIFACT" "Migration")"

  # V1 validation-rule anchor — "At least 2 alternatives compared".
  # This is the AC2 anchor that VCP-CHK-08 specifically guards.
  ALT_COUNT="$(alternatives_count "$ARTIFACT")"
  if [ "${ALT_COUNT:-0}" -ge 2 ] 2>/dev/null; then
    item_check "SV-12" "At least 2 alternatives compared (found $ALT_COUNT)" pass
  else
    item_check "SV-12" "At least 2 alternatives compared (found ${ALT_COUNT:-0})" fail
  fi

  # Pros/cons matrix presence — V1 "Pros/cons matrix included".
  # A structured matrix either spans a table row or a bolded "Pros" /
  # "Cons" sub-header.
  # Matches both standalone "**Pros**"/"**Cons**" bold markers, bolded
  # composite forms like "**Foo — Pros**", pipe-table column headers
  # "| Pros |", and plain "Pros/Cons" headings.
  item_check "SV-13" "Pros/cons matrix included" \
    "$(pattern_present "$ARTIFACT" '(\*\*[^*]*[Pp]ros[^*]*\*\*|\*\*[^*]*[Cc]ons[^*]*\*\*|\|[[:space:]]*[Pp]ros[[:space:]]*\||\|[[:space:]]*[Cc]ons[[:space:]]*\||^#+[[:space:]].*[Pp]ros/[Cc]ons)')"

  # --- LLM-checkable items (9) ---
  # These items require semantic judgment and are delegated back to the
  # host LLM. Payload format mirrors the E42-S1 / E42-S2 / E42-S3
  # convention.
  printf '\n[LLM-CHECK] The following 9 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Trade-off analysis explores meaningful dimensions, not advocacy
  LLM-02 — Maturity assessment reflects real signals (release cadence, stability)
  LLM-03 — Community and ecosystem evaluation grounded in evidence
  LLM-04 — Licensing analysis accurate for the intended deployment model
  LLM-05 — Alternatives compared across dimensions that matter for this use case
  LLM-06 — Recommendation rationale follows from the trade-off analysis
  LLM-07 — Migration / adoption considerations account for team ramp-up and timeline
  LLM-08 — Web access availability and limitations noted if web access unavailable
  LLM-09 — Risk factors acknowledged and tied to the recommendation
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
    printf 'Remediation: amend the technical-research artifact to satisfy the failed items, then rerun /gaia-tech-research.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no technical-research artifact found (TECH_RESEARCH_ARTIFACT unset and no .gaia/artifacts/planning-artifacts/technical-research.md) — skipping checklist run"
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
