#!/usr/bin/env bash
# finalize.sh — /gaia-threat-model skill finalize (E28-S50 + E42-S11)
#
# E42-S11 extends the bare-bones Cluster 6 finalize scaffolding with a
# 25-item post-completion checklist (15 script-verifiable + 10
# LLM-checkable) derived from the V1 security-threat-model checklist.
# See .gaia/artifacts/implementation-artifacts/E42-S11-* for the V1 → V2 mapping.
#
# Responsibilities (per brief §Cluster 6 + story E42-S11):
#   1. Run the script-verifiable subset of the 25 V1 checklist items
#      against the threat-model.md artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S10 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 15 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 6 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   THREAT_MODEL_ARTIFACT  Absolute path to the threat-model artifact
#                          to validate. When set, the script runs the
#                          25-item checklist against it. When set but
#                          the file does not exist or is empty, AC4
#                          fires — a single "no artifact to validate"
#                          violation is emitted and the script exits
#                          non-zero. When unset, the script falls back
#                          to canonical-first resolution (AF-2026-05-21-15):
#                          prefer .gaia/artifacts/planning-artifacts/threat-model.md
#                          (post-ADR-111 canonical); use legacy
#                          .gaia/artifacts/planning-artifacts/threat-model.md only
#                          on positive pre-ADR-111 evidence. If neither
#                          is present, the checklist run is skipped
#                          (classic Cluster 6 behaviour — observability
#                          still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-threat-model/finalize.sh"
# WORKFLOW_NAME matches the V1 workflow id (security-threat-model)
# per the prior Val finding on E42-S11 — do NOT rename to
# "threat-model".
WORKFLOW_NAME="security-threat-model"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths (AF-2026-05-21-15 three-tier idiom) ----------
# Tier 1 — env-var override: THREAT_MODEL_ARTIFACT wins when set.
# Tier 2 — positive pre-ADR-111 evidence: legacy file exists AND canonical
#          dir does NOT exist → use legacy docs/planning-artifacts/threat-model.md.
# Tier 3 — canonical default: .gaia/artifacts/planning-artifacts/threat-model.md per ADR-111.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${THREAT_MODEL_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$THREAT_MODEL_ARTIFACT"
elif [ -f "docs/planning-artifacts/threat-model.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/threat-model.md"
elif [ -f ".gaia/artifacts/planning-artifacts/threat-model.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/threat-model.md"
fi

# ---------- 1. Run the 25-item checklist ----------
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

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# file_exists <file>
file_exists() {
  [ -f "$1" ] && echo "pass" || echo "fail"
}

# heading_present <file> <heading-regex>
# Pass when an H2 heading matching the pattern exists.
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

# pattern_present <file> <extended-regex>
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# assets_table_column_present <file> <column-label>
# Pass when a line starting with '|' contains the named column header
# (case-insensitive) anywhere in the file.
assets_table_column_present() {
  local f="$1" col="$2"
  awk -v col="$col" '
    BEGIN { lcol = tolower(col); found = 0 }
    /^[[:space:]]*\|/ {
      line = tolower($0)
      if (index(line, "| " lcol) > 0 || index(line, "|" lcol) > 0) { found = 1 }
    }
    END { exit (found ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# stride_six_categories_per_component <file>
# Pass when every component block under ## STRIDE Analysis enumerates
# all six STRIDE categories: Spoofing, Tampering, Repudiation,
# Information Disclosure, Denial of Service, Elevation of Privilege.
#
# A "component block" is delimited by a level-3 heading (### Component
# ...) or a markdown table whose first column is the component name.
# The scan is tolerant of both markdown list blocks (one bullet per
# category) and markdown tables (one row per component with six
# category columns). Missing any of the six categories for any
# component fails the check.
stride_six_categories_per_component() {
  local f="$1"
  awk '
    BEGIN {
      IGNORECASE = 1
      in_stride = 0
      in_component = 0
      component_count = 0
      missing = 0
      s = 0; t = 0; r = 0; i_flag = 0; d = 0; e = 0
    }
    function reset_flags() {
      s = 0; t = 0; r = 0; i_flag = 0; d = 0; e = 0
    }
    function finalize_component() {
      if (in_component) {
        component_count++
        if (s == 0 || t == 0 || r == 0 || i_flag == 0 || d == 0 || e == 0) {
          missing = 1
        }
      }
    }
    # Enter STRIDE section.
    /^##[[:space:]]+STRIDE[[:space:]]+Analysis/ {
      in_stride = 1
      finalize_component()
      in_component = 0
      reset_flags()
      next
    }
    # Exit STRIDE section on next H2.
    /^##[[:space:]]+[A-Za-z]/ {
      if (in_stride) {
        finalize_component()
        in_component = 0
        reset_flags()
      }
      in_stride = 0
      next
    }
    # Component boundary: ### heading or table row with a component name.
    in_stride && /^###[[:space:]]+/ {
      finalize_component()
      in_component = 1
      reset_flags()
      next
    }
    # Table row pattern — treat each table data row as a component
    # if it is not the header or separator and the line has 6+ cells.
    in_stride && /^[[:space:]]*\|/ {
      line = $0
      # Skip separator rows.
      if (line ~ /\|[[:space:]]*-+[[:space:]]*\|/) { next }
      # Skip the header row (matches when the line contains the
      # STRIDE category names). We detect the header by presence of
      # at least three category words on the same row.
      lc = tolower(line)
      header_hits = 0
      if (index(lc, "spoofing")) header_hits++
      if (index(lc, "tampering")) header_hits++
      if (index(lc, "repudiation")) header_hits++
      if (index(lc, "information disclosure")) header_hits++
      if (index(lc, "denial of service")) header_hits++
      if (index(lc, "elevation of privilege")) header_hits++
      if (header_hits >= 3) { next }
      # Count pipes — a component row should have at least 7 cells
      # (component name + 6 category columns).
      n = gsub(/\|/, "|", line)
      if (n < 7) { next }
      finalize_component()
      in_component = 1
      reset_flags()
      # Inline scan — table-driven components declare presence via
      # non-empty cell content for each category column. We accept
      # any non-empty cell as "category evaluated"; emptiness is a
      # fail. Split into fields and check fields 3..8 (skipping the
      # leading empty + component-name cell).
      ncol = split($0, cells, "|")
      non_empty = 0
      for (k = 3; k <= 8 && k <= ncol; k++) {
        cell = cells[k]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
        if (cell != "" && cell !~ /^[[:space:]]*-[[:space:]]*$/) {
          non_empty++
        }
      }
      if (non_empty >= 6) {
        s = 1; t = 1; r = 1; i_flag = 1; d = 1; e = 1
      } else {
        # Not every category present in the table row — mark which
        # columns are populated. For table format we require all six
        # cells non-empty; partial populates failure is captured by
        # the global non_empty < 6 path keeping flags at 0.
      }
      next
    }
    # Within a ### component block, scan bullets for the six
    # category names.
    in_stride && in_component {
      lc = tolower($0)
      if (lc ~ /spoofing/)                 { s = 1 }
      if (lc ~ /tampering/)                { t = 1 }
      if (lc ~ /repudiation/)              { r = 1 }
      if (lc ~ /information[[:space:]]+disclosure/) { i_flag = 1 }
      if (lc ~ /denial[[:space:]]+of[[:space:]]+service/) { d = 1 }
      if (lc ~ /elevation[[:space:]]+of[[:space:]]+privilege/) { e = 1 }
    }
    END {
      finalize_component()
      if (component_count == 0) { exit 1 }
      exit (missing == 0 ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

# dread_five_dimensions_per_threat <file>
# Pass when every threat row under ## DREAD Scoring has all five
# DREAD dimensions (D, R, E, A, D) populated with non-empty values.
# A "threat row" is a data row in a markdown table under the DREAD
# section; the header row must contain at minimum five DREAD-ish
# column labels. Checks that each row has >= 5 non-empty cells after
# the leading threat identifier cell.
dread_five_dimensions_per_threat() {
  local f="$1"
  awk '
    BEGIN {
      IGNORECASE = 1
      in_dread = 0
      header_seen = 0
      rows = 0
      missing = 0
    }
    /^##[[:space:]]+DREAD[[:space:]]+Scoring/ {
      in_dread = 1
      header_seen = 0
      next
    }
    /^##[[:space:]]+[A-Za-z]/ {
      if (in_dread) {
        # leaving section
      }
      in_dread = 0
      next
    }
    in_dread && /^[[:space:]]*\|/ {
      line = $0
      lc = tolower(line)
      # Skip separator rows.
      if (line ~ /\|[[:space:]]*-+[[:space:]]*\|/) { next }
      # Detect header — we expect a row with at least "damage" and
      # "reproducibility" or the letters D/R/E/A/D across columns.
      if (!header_seen) {
        if (lc ~ /damage/ || lc ~ /reproducibility/ || lc ~ /exploitability/ || lc ~ /affected/ || lc ~ /discoverability/ || lc ~ /\|[[:space:]]*d[[:space:]]*\|/) {
          header_seen = 1
          next
        }
        # First data row before a header — treat as data anyway.
      }
      # Data row.
      rows++
      ncol = split($0, cells, "|")
      non_empty = 0
      # Count cells 3..ncol-1 (skip leading empty + threat name, and
      # trailing empty after last pipe).
      for (k = 3; k <= ncol - 1; k++) {
        cell = cells[k]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
        if (cell != "" && cell !~ /^-+$/) { non_empty++ }
      }
      if (non_empty < 5) { missing = 1 }
    }
    END {
      if (rows == 0) { exit 1 }
      exit (missing == 0 ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

# high_critical_threats_have_mitigations <file>
# Pass when every threat row marked Risk=High or Risk=Critical in the
# DREAD section appears as a row (by threat name) in the Mitigations
# section. The threat name is taken from the first non-empty cell of
# each DREAD data row.
high_critical_threats_have_mitigations() {
  local f="$1"
  awk '
    BEGIN {
      IGNORECASE = 1
      section = ""
      missing = 0
      threat_count = 0
    }
    /^##[[:space:]]+DREAD[[:space:]]+Scoring/    { section = "dread"; next }
    /^##[[:space:]]+Mitigations/                 { section = "mit"; next }
    /^##[[:space:]]+[A-Za-z]/                    { section = ""; next }
    section == "dread" && /^[[:space:]]*\|/ {
      if ($0 ~ /\|[[:space:]]*-+[[:space:]]*\|/) next
      lc = tolower($0)
      if (lc ~ /high/ || lc ~ /critical/) {
        # Extract the first data cell as threat name.
        ncol = split($0, cells, "|")
        name = cells[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        lname = tolower(name)
        # Skip header row (contains "threat" or "risk" as title).
        if (lname ~ /^threat([[:space:]]|$)/ || lname == "threat" || lname == "name") next
        if (name != "" && name != "-" && name !~ /^-+$/) {
          hc[name] = 1
          threat_count++
        }
      }
    }
    section == "mit" {
      line = tolower($0)
      for (t in hc) {
        lt = tolower(t)
        if (index(line, lt) > 0) { seen[t] = 1 }
      }
    }
    END {
      if (threat_count == 0) {
        # No H/C threats → trivially satisfied.
        exit 0
      }
      for (t in hc) {
        if (!(t in seen)) { missing = 1 }
      }
      exit (missing == 0 ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

# risk_values_valid <file>
# Pass when every cell under a Risk column contains one of
# Critical/High/Medium/Low (case-insensitive).
risk_values_valid() {
  local f="$1"
  awk '
    BEGIN { IGNORECASE = 1; bad = 0; rows = 0 }
    /^[[:space:]]*\|[[:space:]]*Risk[[:space:]]*\|/ ||
    /\|[[:space:]]*Risk[[:space:]]+Level[[:space:]]*\|/ {
      # Header row — capture column index of Risk.
      ncol = split($0, cells, "|")
      for (k = 1; k <= ncol; k++) {
        c = cells[k]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); c = tolower(c)
        if (c == "risk" || c == "risk level") { risk_col = k }
      }
      in_table = 1
      next
    }
    /^[[:space:]]*\|[[:space:]]*-+[[:space:]]*\|/ { next }
    in_table && /^[[:space:]]*\|/ {
      ncol = split($0, cells, "|")
      if (risk_col > 0 && risk_col <= ncol) {
        v = cells[risk_col]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") {
          rows++
          lv = tolower(v)
          if (lv !~ /^(critical|high|medium|low)$/) { bad = 1 }
        }
      }
      next
    }
    /^[^\|]/ { in_table = 0; risk_col = 0 }
    END { exit (bad == 0 ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# sr_identifiers_with_acceptance <file>
# Pass when every SR-\d+ identifier in the Security Requirements
# section is followed by at least one acceptance criterion bullet
# before the next SR- identifier or the end of the section. Accepts
# any bullet line ("- ...", "* ...", or "  - ...") and lines
# explicitly tagged "Acceptance" / "AC:".
sr_identifiers_with_acceptance() {
  local f="$1"
  awk '
    BEGIN {
      IGNORECASE = 1
      in_sr = 0
      cur = ""
      missing = 0
      sr_count = 0
    }
    /^##[[:space:]]+Security[[:space:]]+Requirements/ { in_sr = 1; next }
    /^##[[:space:]]+[A-Za-z]/                         {
      if (in_sr && cur != "" && ac[cur] == 0) { missing = 1 }
      in_sr = 0; cur = ""
      next
    }
    !in_sr { next }
    # SR-N identifier anywhere on the line opens a new requirement.
    match($0, /SR-[0-9]+/) {
      if (cur != "" && ac[cur] == 0) { missing = 1 }
      cur = substr($0, RSTART, RLENGTH)
      ac[cur] = 0
      sr_count++
      # A single bullet line can contain both the SR- and AC text.
      rest = substr($0, RSTART + RLENGTH)
      if (length(rest) > 0 && rest ~ /[A-Za-z]/) { ac[cur] = 1 }
      next
    }
    # Any non-empty bullet line after the SR- line counts as an
    # acceptance criterion.
    in_sr && cur != "" {
      if ($0 ~ /^[[:space:]]*[-*][[:space:]]+/) { ac[cur] = 1 }
      if ($0 ~ /acceptance/) { ac[cur] = 1 }
      if ($0 ~ /^[[:space:]]*AC[[:space:]]*:/) { ac[cur] = 1 }
    }
    END {
      if (cur != "" && ac[cur] == 0) { missing = 1 }
      if (sr_count == 0) { exit 1 }
      exit (missing == 0 ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-threat-model to produce .gaia/artifacts/planning-artifacts/threat-model.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 25-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-threat-model (25 items — 15 script-verifiable, 10 LLM-checkable)\n' >&2

  # --- Script-verifiable items (15) ---

  # Output Verification (SV-01..SV-02, SV-05, SV-15)
  item_check "SV-01" "Output file saved to resolved path ($ARTIFACT)" \
    "$(file_exists "$ARTIFACT")"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Assets (SV-03..SV-05)
  item_check "SV-03" "Assets section present (## Assets heading)" \
    "$(heading_present "$ARTIFACT" "Assets")"
  item_check "SV-04" "Assets table declares a Sensitivity column" \
    "$(assets_table_column_present "$ARTIFACT" "Sensitivity")"
  item_check "SV-05" "Asset locations mapped to components (Component column present in Assets table)" \
    "$(assets_table_column_present "$ARTIFACT" "Component")"

  # STRIDE Analysis (SV-06..SV-07)
  item_check "SV-06" "STRIDE Analysis section present (## STRIDE Analysis heading)" \
    "$(heading_present "$ARTIFACT" "STRIDE[[:space:]]+Analysis")"
  item_check "SV-07" "All six STRIDE categories evaluated per component" \
    "$(stride_six_categories_per_component "$ARTIFACT")"

  # DREAD Scoring (SV-08..SV-10)
  item_check "SV-08" "DREAD Scoring section present (## DREAD Scoring heading)" \
    "$(heading_present "$ARTIFACT" "DREAD[[:space:]]+Scoring")"
  item_check "SV-09" "Each threat scored on all 5 DREAD dimensions" \
    "$(dread_five_dimensions_per_threat "$ARTIFACT")"
  item_check "SV-10" "Risk levels restricted to Critical/High/Medium/Low" \
    "$(risk_values_valid "$ARTIFACT")"

  # Mitigations (SV-11..SV-12)
  item_check "SV-11" "Mitigations section present (## Mitigations heading)" \
    "$(heading_present "$ARTIFACT" "Mitigations")"
  item_check "SV-12" "High and critical threats have mitigations" \
    "$(high_critical_threats_have_mitigations "$ARTIFACT")"

  # Security Requirements (SV-13..SV-14)
  item_check "SV-13" "Security Requirements section present (## Security Requirements heading)" \
    "$(heading_present "$ARTIFACT" "Security[[:space:]]+Requirements")"
  item_check "SV-14" "Each requirement has acceptance criteria (SR-\\d+ identifiers with AC bullets)" \
    "$(sr_identifiers_with_acceptance "$ARTIFACT")"

  # Sidecar reference (SV-15)
  item_check "SV-15" "Decisions recorded in security-sidecar (sidecar reference present)" \
    "$(pattern_present "$ARTIFACT" '(security-sidecar|sidecar_decision[[:space:]]*:)')"

  # --- LLM-checkable items (10) ---
  printf '\n[LLM-CHECK] The following 10 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Threats are specific and actionable, not generic
  LLM-02 — Mitigations are specific and implementable
  LLM-03 — Risk levels align coherently with DREAD scores
  LLM-04 — Asset locations mapped to components correctly
  LLM-05 — STRIDE coverage is meaningful per component (not boilerplate)
  LLM-06 — Acceptance criteria per SR- are testable
  LLM-07 — Asset sensitivity classifications are accurate (critical/high/medium/low)
  LLM-08 — Mitigation prioritization reflects risk reduction vs implementation effort
  LLM-09 — Security requirements map back to architecture components they protect
  LLM-10 — No critical threats are missing from STRIDE coverage (completeness judgment)
EOF

  TOTAL_ITEMS=25
  LLM_ITEMS=10
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the threat-model artifact to satisfy the failed items, then rerun /gaia-threat-model.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no threat-model artifact found (THREAT_MODEL_ARTIFACT unset and no threat-model.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 7 >/dev/null 2>&1; then
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
