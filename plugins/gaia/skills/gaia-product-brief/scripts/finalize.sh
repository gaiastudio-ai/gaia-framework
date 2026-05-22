#!/usr/bin/env bash
# finalize.sh — /gaia-product-brief skill finalize (E28-S36 + E42-S5)
#
# E42-S5 extends the original Cluster 4 finalize scaffolding with a
# 27-item post-completion checklist (18 script-verifiable + 9
# LLM-checkable). The script-verifiable subset is enforced here; the
# LLM-checkable subset is delegated to the host LLM via a structured
# stderr payload that mirrors the E42-S1 / E42-S2 / E42-S3 / E42-S4
# convention.
#
# Responsibilities (per brief §Cluster 4 + story E42-S5):
#   1. Run the script-verifiable subset of the 27 V1 checklist items
#      against the product-brief artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S4 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 18 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 4 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       "no artifact to validate" AC4 violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   PRODUCT_BRIEF_ARTIFACT  Absolute path to the artifact to validate.
#                           When set, the script runs the 27-item
#                           checklist against it. When set but the
#                           file does not exist, AC4 fires — a single
#                           "no artifact to validate" violation is
#                           emitted and the script exits non-zero.
#                           When unset, the script looks for the most
#                           recent .gaia/artifacts/creative-artifacts/product-brief-*.md
#                           relative to the current working directory.
#                           If neither is present, the checklist run
#                           is skipped (classic Cluster 4 behaviour —
#                           observability still runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-product-brief/finalize.sh"
WORKFLOW_NAME="create-product-brief"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"
GATE_PREDICATES="$PLUGIN_SCRIPTS_DIR/lib/gate-predicates.sh"
SKILL_MD_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path ----------
# PRODUCT_BRIEF_ARTIFACT wins when set (test fixtures + explicit
# invocation). If it is set but the file is missing, AC4 fires. If
# unset, pick the most recent .gaia/artifacts/creative-artifacts/product-brief-*.md.
# If neither is present the checklist is simply skipped (observability
# still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${PRODUCT_BRIEF_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$PRODUCT_BRIEF_ARTIFACT"
else
  # ADR-111 smart-fallback: prefer .gaia/artifacts/creative-artifacts/,
  # fall back to legacy docs/creative-artifacts/ for pre-migration installs.
  # Pick the newest product-brief-*.md under whichever directory exists,
  # without relying on GNU-only ls flags — portable across BSD/macOS and
  # GNU coreutils.
  if [ -d ".gaia/artifacts/creative-artifacts" ]; then
    BRIEF_DIR=".gaia/artifacts/creative-artifacts"
  elif [ -d "docs/creative-artifacts" ]; then
    BRIEF_DIR="docs/creative-artifacts"
  else
    BRIEF_DIR=""
  fi
  if [ -n "$BRIEF_DIR" ]; then
    newest=""
    newest_mtime=0
    for f in "$BRIEF_DIR"/product-brief-*.md; do
      [ -f "$f" ] || continue
      mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
      if [ "${mtime:-0}" -gt "$newest_mtime" ] 2>/dev/null; then
        newest_mtime="$mtime"
        newest="$f"
      fi
    done
    if [ -n "$newest" ]; then
      ARTIFACT="$newest"
    fi
  fi
fi

# ---------- 0b. Quality gates: post_complete (E45-S2 / FR-347) ----------
# Source the shared gate-predicates library and evaluate the
# post_complete list declared in this skill's SKILL.md frontmatter.
# Sets GATE_STATUS to 1 if any gate fails. The existing 27-item
# checklist still runs after — both are aggregated into the final
# exit code so observability side effects (checkpoint, lifecycle
# event) always run.
GATE_STATUS=0
if [ -f "$GATE_PREDICATES" ] && [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  # shellcheck disable=SC1090
  . "$GATE_PREDICATES"
  if ! _gate_run_post_complete "$SKILL_MD_PATH" "$ARTIFACT" "$SCRIPT_NAME: quality-gate"; then
    GATE_STATUS=1
  fi
elif [ ! -f "$GATE_PREDICATES" ]; then
  log "gate-predicates.sh not found at $GATE_PREDICATES — skipping quality gates (non-fatal)"
fi

# ---------- 1. Run the 27-item checklist ----------
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
heading_present() {
  local f="$1" text="$2"
  if grep -Ei "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# section_body_nonempty <file> <heading-text>
# Pass when the H2 section exists AND has at least one non-blank,
# non-comment content line before the next H2 heading.
section_body_nonempty() {
  local f="$1" text="$2"
  awk -v hdr="$text" '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ "^##[[:space:]]+" hdr "([[:space:]]|$|[[:punct:]])") {
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

# scope_has_in_and_out <file>
# Pass when the Scope and Boundaries section mentions both in-scope and
# out-of-scope (or "out of scope") content.
scope_has_in_and_out() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; has_in = 0; has_out = 0 }
    {
      if ($0 ~ /^##[[:space:]]+[Ss]cope[[:space:]]+and[[:space:]]+[Bb]oundaries/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if (tolower($0) ~ /in[- ]?scope|in scope/) { has_in = 1 }
        if (tolower($0) ~ /out[- ]?of[- ]?scope|out of scope|out-of-scope/) { has_out = 1 }
      }
    }
    END { exit ((has_in && has_out) ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# persona_count <file>
# Counts persona-ish entries under Target Users. Recognises either
# bold "**Persona X" markers or "Role:" lines.
persona_count() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; count = 0 }
    {
      if ($0 ~ /^##[[:space:]]+[Tt]arget[[:space:]]+[Uu]sers/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        if ($0 ~ /\*\*[Pp]ersona/) { count++ }
        else if (tolower($0) ~ /^[[:space:]]*-[[:space:]]+role:/) { count++ }
      }
    }
    END { print count + 0 }
  ' "$f"
}

# features_count <file>
# Counts list items (ordered or unordered) under the Key Features
# section.
features_count() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; count = 0 }
    {
      if ($0 ~ /^##[[:space:]]+[Kk]ey[[:space:]]+[Ff]eatures/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        # Ordered list item ("1. ...", "2. ..."), unordered ("- ...",
        # "* ..."). Ignore deeper indentation — top-level bullets only.
        if ($0 ~ /^[0-9]+\.[[:space:]]+[^[:space:]]/) { count++ }
        else if ($0 ~ /^-[[:space:]]+[^[:space:]]/) { count++ }
        else if ($0 ~ /^\*[[:space:]]+[^[:space:]]/) { count++ }
      }
    }
    END { print count + 0 }
  ' "$f"
}

# competitors_count <file>
# Counts competitor rows under the Competitive Landscape section.
# Primary signal: data rows in a markdown table after the header
# separator. Fallback: bulleted items.
competitors_count() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; in_table = 0; count = 0; saw_sep = 0 }
    {
      if ($0 ~ /^##[[:space:]]+[Cc]ompetitive[[:space:]]+[Ll]andscape/) {
        in_section = 1; in_table = 0; saw_sep = 0; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        # Table separator row like |---|---|
        if ($0 ~ /^\|[[:space:]]*:?-+/) { saw_sep = 1; in_table = 1; next }
        if (in_table) {
          if ($0 ~ /^\|/ && $0 !~ /^\|[[:space:]]*:?-+/) { count++ }
          else if ($0 !~ /^\|/) { in_table = 0 }
        } else if ($0 ~ /^-[[:space:]]+[^[:space:]]/) {
          # Fallback — bulleted competitor
          count++
        }
      }
    }
    END { print count + 0 }
  ' "$f"
}

# metrics_measurable <file>
# Pass when the Success Metrics section contains at least one numeric
# signal (percentage, currency, count, time window, ratio).
metrics_measurable() {
  local f="$1"
  awk '
    BEGIN { in_section = 0; found = 0 }
    {
      if ($0 ~ /^##[[:space:]]+[Ss]uccess[[:space:]]+[Mm]etrics/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]/) { in_section = 0 }
      if (in_section) {
        # Any of: NN%, $NN, NNms/s/bps, NN/NN, "p99", "p95", etc.
        # Portable word-boundary form for "pNN" and "NPS" — mawk and BSD
        # awk do not support \<...\>, so we anchor with non-alphanumeric
        # neighbours or BOL/EOL. See gaia-shell-idioms (E45-S7).
        if ($0 ~ /[0-9]+(\.[0-9]+)?[[:space:]]*%|\$[0-9]|(^|[^A-Za-z0-9])p[0-9]+([^A-Za-z0-9]|$)|[0-9]+[[:space:]]*(ms|bps|hours?|days?|months?|minutes?|seconds?)|(^|[^A-Za-z0-9])NPS([^A-Za-z0-9]|$)/) {
          found = 1
        }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && [ ! -f "$ARTIFACT" ]; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk.
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-product-brief to produce .gaia/artifacts/creative-artifacts/product-brief-*.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  log "running 27-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-product-brief (27 items — 18 script-verifiable, 9 LLM-checkable)\n' >&2

  # --- Script-verifiable items (18) ---
  item_check "SV-01" "Output artifact exists at docs/creative-artifacts/product-brief-*.md" \
    "$([ -f "$ARTIFACT" ] && echo pass || echo fail)"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Top-level title or YAML frontmatter present.
  if head -n 20 "$ARTIFACT" | grep -Eq '^(# |---)'; then
    item_check "SV-03" "Artifact has frontmatter or top-level title" pass
  else
    item_check "SV-03" "Artifact has frontmatter or top-level title" fail
  fi

  # Nine required sections (per architecture §10.31.1 / VCP-GATE-03 anchor).
  item_check "SV-04" "Vision Statement section present" \
    "$(heading_present "$ARTIFACT" "Vision Statement")"
  item_check "SV-05" "Target Users section present" \
    "$(heading_present "$ARTIFACT" "Target Users")"
  item_check "SV-06" "Problem Statement section present" \
    "$(heading_present "$ARTIFACT" "Problem Statement")"
  item_check "SV-07" "Proposed Solution section present" \
    "$(heading_present "$ARTIFACT" "Proposed Solution")"
  item_check "SV-08" "Key Features section present" \
    "$(heading_present "$ARTIFACT" "Key Features")"
  item_check "SV-09" "Scope and Boundaries section present" \
    "$(heading_present "$ARTIFACT" "Scope and Boundaries")"
  item_check "SV-10" "Risks and Assumptions section present" \
    "$(heading_present "$ARTIFACT" "Risks and Assumptions")"
  item_check "SV-11" "Competitive Landscape section present" \
    "$(heading_present "$ARTIFACT" "Competitive Landscape")"
  item_check "SV-12" "Success Metrics section present" \
    "$(heading_present "$ARTIFACT" "Success Metrics")"

  # Deeper presence checks — defend against empty section bodies.
  item_check "SV-13" "Vision Statement body non-empty" \
    "$(section_body_nonempty "$ARTIFACT" "Vision Statement")"

  PERSONA_COUNT="$(persona_count "$ARTIFACT")"
  if [ "${PERSONA_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    item_check "SV-14" "At least one persona listed in Target Users (found $PERSONA_COUNT)" pass
  else
    item_check "SV-14" "At least one persona listed in Target Users (found ${PERSONA_COUNT:-0})" fail
  fi

  FEATURE_COUNT="$(features_count "$ARTIFACT")"
  if [ "${FEATURE_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    item_check "SV-15" "Key Features list non-empty (found $FEATURE_COUNT)" pass
  else
    item_check "SV-15" "Key Features list non-empty (found ${FEATURE_COUNT:-0})" fail
  fi

  item_check "SV-16" "Scope and Boundaries documents both in-scope and out-of-scope" \
    "$(scope_has_in_and_out "$ARTIFACT")"

  COMPETITOR_COUNT="$(competitors_count "$ARTIFACT")"
  if [ "${COMPETITOR_COUNT:-0}" -ge 1 ] 2>/dev/null; then
    item_check "SV-17" "At least one competitor listed in Competitive Landscape (found $COMPETITOR_COUNT)" pass
  else
    item_check "SV-17" "At least one competitor listed in Competitive Landscape (found ${COMPETITOR_COUNT:-0})" fail
  fi

  item_check "SV-18" "Success Metrics contain measurable values" \
    "$(metrics_measurable "$ARTIFACT")"

  # --- LLM-checkable items (9) ---
  printf '\n[LLM-CHECK] The following 9 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Vision statement is coherent and aspirational
  LLM-02 — Target user personas are plausible and grounded in research
  LLM-03 — Problem statement is grounded in user/market research findings
  LLM-04 — Proposed solution addresses the stated problem
  LLM-05 — Key features are prioritised with rationale
  LLM-06 — Risks are credible and assumptions are testable
  LLM-07 — Competitive landscape differentiation is clear
  LLM-08 — Success metrics are measurable and attributable to the product
  LLM-09 — Scope boundaries are defensible against feature creep
EOF

  TOTAL_ITEMS=27
  LLM_ITEMS=9
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the product-brief artifact to satisfy the failed items, then rerun /gaia-product-brief.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no product-brief artifact found (PRODUCT_BRIEF_ARTIFACT unset and no .gaia/artifacts/creative-artifacts/product-brief-*.md) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 8 >/dev/null 2>&1; then
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
# Composite exit: non-zero if either the post_complete gate or the
# existing 27-item checklist failed. Observability side effects
# (checkpoint, lifecycle event) above still ran regardless.
if [ "$GATE_STATUS" -ne 0 ] || [ "$CHECKLIST_STATUS" -ne 0 ]; then
  exit 1
fi
exit 0
