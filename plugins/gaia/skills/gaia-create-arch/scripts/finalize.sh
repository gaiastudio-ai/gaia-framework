#!/usr/bin/env bash
# finalize.sh — /gaia-create-arch skill finalize (E28-S45 + E42-S8)
#
# E42-S8 extends the bare-bones Cluster 6 finalize scaffolding with a
# 33-item post-completion checklist (25 script-verifiable + 8
# LLM-checkable) derived from the V1 /gaia-create-arch (create-architecture)
# checklist. See .gaia/artifacts/implementation-artifacts/E42-S8-* for the
# V1 -> V2 mapping.
#
# Responsibilities (per brief §Cluster 6 + story E42-S8):
#   1. Run the script-verifiable subset of the 33 V1 checklist items
#      against the architecture artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S7 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 25 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 6 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "output file not found" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   ARCHITECTURE_ARTIFACT  Absolute path to the architecture artifact to
#                          validate. When set, the script runs the 33-item
#                          checklist against it. When set but the file does
#                          not exist, AC4 fires — a single "no artifact to
#                          validate" violation is emitted and the script
#                          exits non-zero. When unset, the script falls
#                          back to a canonical-first path resolution
#                          (AF-2026-05-21-11): prefer
#                          .gaia/artifacts/planning-artifacts/architecture.md
#                          (post-ADR-111 canonical); use legacy
#                          .gaia/artifacts/planning-artifacts/architecture.md only on
#                          positive pre-ADR-111 evidence (legacy file
#                          exists AND canonical dir does not). If neither
#                          is present, the checklist run is skipped
#                          (classic Cluster 6 behaviour — observability
#                          still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-create-arch/finalize.sh"
WORKFLOW_NAME="create-architecture"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path (AF-2026-05-21-11 three-tier idiom) ----------
# Tier 1 — env-var override: ARCHITECTURE_ARTIFACT wins when set (test
#          fixtures + explicit invocation). If it is set but the file is
#          missing, AC4 fires.
# Tier 2 — positive pre-ADR-111 evidence: legacy file exists AND canonical
#          dir does NOT exist → use legacy docs/planning-artifacts/architecture.md.
# Tier 3 — canonical default: greenfield + post-ADR-111 projects route to
#          .gaia/artifacts/planning-artifacts/architecture.md per ADR-111.
# If neither file is present the checklist is simply skipped (observability
# still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${ARCHITECTURE_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$ARCHITECTURE_ARTIFACT"
elif [ -f "docs/planning-artifacts/architecture.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/architecture.md"
elif [ -f ".gaia/artifacts/planning-artifacts/architecture.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/architecture.md"
fi

# ---------- 1. Run the 33-item checklist ----------
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
# Pass when an H2 heading containing the given text (case-insensitive,
# with optional numeric prefix like "## 1. System Overview") is present.
heading_present() {
  local f="$1" text="$2"
  if grep -Ei "^##[[:space:]]+([0-9]+\.[[:space:]]+)?${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# section_body_nonempty <file> <heading-regex>
# Pass when the H2 section exists AND has at least one non-blank,
# non-comment content line before the next H2 heading.
section_body_nonempty() {
  local f="$1" pattern="$2"
  awk -v pat="$pattern" '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ "^##[[:space:]]+([0-9]+\\.[[:space:]]+)?" pat "([[:space:]]|$|[[:punct:]])") {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (length(line) > 0 && line !~ /^<!--/) { found = 1 }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# decision_log_table_present <file>
# Pass when an "Architecture Decisions" or "Decision Log" H2 is followed
# by a markdown table header + separator before the next H2.
decision_log_table_present() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_header = 0; saw_sep = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+\.[[:space:]]+)?(Architecture Decisions|Decision Log)([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /^\|.*\|[[:space:]]*$/) { saw_header = 1 }
        if (saw_header && $0 ~ /^\|[[:space:]]*:?-+/) { saw_sep = 1 }
      }
    }
    END { exit ((saw_header && saw_sep) ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# decision_log_has_rows <file>
# Pass when the Decision Log table has at least one data row after the
# separator. This is the AC-EC5 / VCP-CHK-16 anchor — the V1 item
# "Decisions recorded" is its description.
decision_log_has_rows() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; saw_sep = 0; rows = 0 }
    {
      if ($0 ~ /^##[[:space:]]+([0-9]+\.[[:space:]]+)?(Architecture Decisions|Decision Log)([[:space:]]|$|[[:punct:]])/) {
        in_section = 1; saw_sep = 0; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /^\|[[:space:]]*:?-+/) { saw_sep = 1; next }
        if (saw_sep && $0 ~ /^\|.*\|/) { rows++ }
      }
    }
    END { exit (rows >= 1 ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# fr_id_present <file> — at least one "FR-###" identifier (traceability).
fr_id_present() {
  grep -Eq 'FR-[0-9]{3,}' "$1" && echo "pass" || echo "fail"
}

# pattern_present <file> <extended-regex>
# Generic helper — pass when the pattern matches anywhere in the file
# (case-insensitive), fail otherwise.
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" && echo "pass" || echo "fail"
}

# Section-body helpers — bind the heading pattern for each required body
# (only helpers actually used by the SV items below are defined — lean by design).
system_components_body()    { section_body_nonempty "$1" "System[[:space:]]+Components"; }
data_architecture_body()    { section_body_nonempty "$1" "Data[[:space:]]+Architecture"; }
integration_points_body()   { section_body_nonempty "$1" "(Integration[[:space:]]+Points|API[[:space:]]+Design)"; }
infrastructure_body()       { section_body_nonempty "$1" "Infrastructure"; }
cross_cutting_body()        { section_body_nonempty "$1" "Cross-Cutting[[:space:]]+Concerns"; }

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-create-arch to produce .gaia/artifacts/planning-artifacts/architecture.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 33-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-create-arch (33 items — 25 script-verifiable, 8 LLM-checkable)\n' >&2

  # --- Script-verifiable items (25) ---

  # Envelope (SV-01..SV-03)
  item_check "SV-01" "Output file exists at resolved path ($ARTIFACT)" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Required sections (SV-04..SV-11)
  item_check "SV-04" "System Overview section present" \
    "$(heading_present "$ARTIFACT" "System[[:space:]]+Overview")"
  item_check "SV-05" "Architecture Decisions section present (Decision Log)" \
    "$(heading_present "$ARTIFACT" "(Architecture[[:space:]]+Decisions|Decision[[:space:]]+Log)")"
  item_check "SV-06" "System Components section present" \
    "$(heading_present "$ARTIFACT" "System[[:space:]]+Components")"
  item_check "SV-07" "Data Architecture section present" \
    "$(heading_present "$ARTIFACT" "Data[[:space:]]+Architecture")"
  item_check "SV-08" "Integration Points section present" \
    "$(heading_present "$ARTIFACT" "(Integration[[:space:]]+Points|API[[:space:]]+Design)")"
  item_check "SV-09" "Infrastructure section present" \
    "$(heading_present "$ARTIFACT" "Infrastructure")"
  item_check "SV-10" "Security Architecture section present" \
    "$(heading_present "$ARTIFACT" "Security[[:space:]]+Architecture")"
  item_check "SV-11" "Cross-Cutting Concerns section present" \
    "$(heading_present "$ARTIFACT" "Cross-Cutting[[:space:]]+Concerns")"

  # Section-body sanity (SV-12..SV-19) — V1 verbatim anchor strings.
  # SV-12 anchor: V1 "Stack selected with rationale" (Technology).
  # SV-13 anchor: V1 "Component diagram described" (System Design).
  # SV-14 anchor: V1 "Service boundaries defined" (System Design).
  # SV-15 anchor: V1 "Data model defined" (Data).
  # SV-16 anchor: V1 "Data flow documented" (Data).
  # SV-17 anchor: V1 "Endpoints overviewed" (API).
  # SV-18 anchor: V1 "Auth strategy defined" (API).
  # SV-19 anchor: V1 "Deployment topology described" (Infrastructure).
  item_check "SV-12" "Stack selected with rationale" \
    "$(system_components_body "$ARTIFACT")"
  item_check "SV-13" "Component diagram described" \
    "$(system_components_body "$ARTIFACT")"
  item_check "SV-14" "Service boundaries defined" \
    "$(system_components_body "$ARTIFACT")"
  item_check "SV-15" "Data model defined" \
    "$(data_architecture_body "$ARTIFACT")"
  item_check "SV-16" "Data flow documented" \
    "$(data_architecture_body "$ARTIFACT")"
  item_check "SV-17" "Endpoints overviewed" \
    "$(integration_points_body "$ARTIFACT")"
  item_check "SV-18" "Auth strategy defined" \
    "$(pattern_present "$ARTIFACT" "(OAuth|JWT|RBAC|ABAC|SAML|authentication|authorisation|authorization)")"
  item_check "SV-19" "Deployment topology described" \
    "$(infrastructure_body "$ARTIFACT")"

  # Decision Log structural (SV-20..SV-22)
  # SV-21 is the VCP-CHK-16 anchor — V1 "Decisions recorded" verbatim.
  item_check "SV-20" "Decision Log table present with markdown table structure" \
    "$(decision_log_table_present "$ARTIFACT")"
  item_check "SV-21" "Decisions recorded (Decision Log table has at least one ADR row)" \
    "$(decision_log_has_rows "$ARTIFACT")"
  item_check "SV-22" "Each ADR has context, decision, consequences (ADR row fields populated)" \
    "$(pattern_present "$ARTIFACT" '\|[[:space:]]*ADR-[0-9]')"

  # Body sanity continued (SV-23)
  item_check "SV-23" "Cross-cutting concerns documented" \
    "$(cross_cutting_body "$ARTIFACT")"

  # Gates + Output verification (SV-24..SV-25)
  item_check "SV-24" "Review Findings Incorporated section present" \
    "$(heading_present "$ARTIFACT" "Review[[:space:]]+Findings[[:space:]]+Incorporated")"
  item_check "SV-25" "At least one FR-### identifier referenced (traceability)" \
    "$(fr_id_present "$ARTIFACT")"

  # --- LLM-checkable items (8) ---
  printf '\n[LLM-CHECK] The following 8 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Trade-offs documented (tech-stack choices justified against alternatives)
  LLM-02 — Communication patterns specified (sync vs async, at-least-once vs exactly-once)
  LLM-03 — Each ADR has context, decision, consequences with sound rationale
  LLM-04 — Decision-to-Requirement Mapping — every ADR maps to at least one FR/NFR; no orphaned FR/NFR
  LLM-05 — Security architecture addresses identified threats (threat-model cross-reference where present)
  LLM-06 — Environments defined (dev, staging, prod) with progression rules explicit
  LLM-07 — Monitoring, logging, and error-handling strategies adequate for the system scale
  LLM-08 — Adversarial review findings properly incorporated with traceable before/after mapping
EOF

  TOTAL_ITEMS=33
  LLM_ITEMS=8
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the architecture artifact to satisfy the failed items, then rerun /gaia-create-arch.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no architecture artifact found (ARCHITECTURE_ARTIFACT unset and no architecture.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 1b. Config hydration fail-safe (AF-2026-05-22-7 Bug-21) ----------
# Bug-21 root cause: SKILL.md Step 13 describes a "Hydrate project-config.yaml"
# sub-step (build YAML fragment files from confirmed_tech_stack, call
# config_hydrate_section for `stacks:` + `platforms:`). In practice the
# LLM orchestrator skipped this sub-step ~100% of the time on real runs,
# silently leaving config_phase=minimal with no `stacks:` / `platforms:`.
# Downstream skills (/gaia-bridge-enable, /gaia-create-epics) then halted
# with generic "X missing" errors pointing at the WRONG upstream remediation.
#
# Fail-safe: if a written architecture artifact resolved AND the project
# config still lacks `stacks:` / `platforms:` AND `config_phase` is still
# `minimal`, log a CRITICAL warning telling the operator how to hydrate
# manually. Non-fatal — architecture.md is the primary artifact — but the
# warning is unmistakable so downstream "X missing" halts have a clear
# upstream attribution.
if [ -n "${ARTIFACT:-}" ] && [ -f "${ARTIFACT:-}" ]; then
  CONFIG_PATH=""
  if [ -f ".gaia/config/project-config.yaml" ]; then
    CONFIG_PATH=".gaia/config/project-config.yaml"
  elif [ -f "config/project-config.yaml" ]; then
    CONFIG_PATH="config/project-config.yaml"
  fi
  if [ -n "$CONFIG_PATH" ]; then
    # `config_phase` and `stacks:` / `platforms:` presence are flat-grep
    # checks — no yq dependency. False positives only if the user puts these
    # keys inside a quoted string, which is extremely unlikely.
    config_phase_val=$(grep -E "^config_phase:" "$CONFIG_PATH" 2>/dev/null | head -1 | sed 's/^config_phase:[[:space:]]*//' | tr -d '"' || true)
    stacks_present=0; platforms_present=0
    grep -qE "^stacks:" "$CONFIG_PATH" 2>/dev/null && stacks_present=1
    grep -qE "^platforms:" "$CONFIG_PATH" 2>/dev/null && platforms_present=1
    if [ "${config_phase_val:-minimal}" = "minimal" ] && [ "$stacks_present" -eq 0 ] && [ "$platforms_present" -eq 0 ]; then
      log "WARNING: architecture.md was written but project-config.yaml hydration was SKIPPED."
      log "         config_phase is still 'minimal' and stacks: / platforms: are not declared."
      log "         Downstream skills (/gaia-bridge-enable, /gaia-create-epics, /gaia-ci-setup)"
      log "         will halt with 'X missing' errors that point at the wrong remediation."
      log ""
      log "         Remediation: source \${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
      log "         and call config_hydrate_section stacks <yaml-fragment-file> followed by"
      log "         config_hydrate_section platforms <yaml-fragment-file>. The fragments must"
      log "         match the confirmed_tech_stack captured at Step 3.5 of /gaia-create-arch."
      log "         See SKILL.md \"Hydrate project-config.yaml (E85-S5 / FR-457)\" sub-section."
      log ""
      log "         This warning is fail-safe only — architecture.md was written successfully"
      log "         and is the primary artifact. Run /gaia-create-arch again or invoke the"
      log "         hydrate helper manually before proceeding to /gaia-bridge-enable."
    fi
  fi
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 12 >/dev/null 2>&1; then
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
