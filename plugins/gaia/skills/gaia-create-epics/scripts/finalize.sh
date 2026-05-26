#!/usr/bin/env bash
# finalize.sh — /gaia-create-epics skill finalize (E28-S47 + E42-S10)
#
# E42-S10 extends the bare-bones Cluster 6 finalize scaffolding with a
# 31-item post-completion checklist (21 script-verifiable + 10
# LLM-checkable) derived from the V1 /gaia-create-epics
# (create-epics-stories) checklist. See
# .gaia/artifacts/implementation-artifacts/E42-S10-* for the V1 -> V2 mapping.
#
# Responsibilities (per brief §Cluster 6 + story E42-S10):
#   1. Run the script-verifiable subset of the 31 V1 checklist items
#      against the epics-and-stories.md artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write
# (matches E42-S1..S9 contract; story AC5).
#
# Exit codes:
#   0 — finalize succeeded; all 21 script-verifiable items PASS (or
#       no artifact was requested — classic Cluster 6 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   EPICS_ARTIFACT         Absolute path to the epics-and-stories artifact
#                          to validate. When set, the script runs the
#                          31-item checklist against it. When set but the
#                          file does not exist or is empty, AC4 fires — a
#                          single "no artifact to validate" violation is
#                          emitted and the script exits non-zero. When
#                          unset, the script looks for
#                          .gaia/artifacts/planning-artifacts/epics-and-stories.md
#                          relative to the current working directory. If
#                          neither is present, the checklist run is
#                          skipped (classic Cluster 6 behaviour —
#                          observability still runs, exit 0).
#   TEST_PLAN_PATH         Override path to test-plan.md (default:
#                          .gaia/artifacts/test-artifacts/test-plan.md).
#   ARCHITECTURE_PATH      Override path to architecture.md (default:
#                          .gaia/artifacts/planning-artifacts/architecture.md).
#   PRD_PATH               Override path to prd.md (default:
#                          .gaia/artifacts/planning-artifacts/prd.md).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-create-epics/finalize.sh"
WORKFLOW_NAME="create-epics-stories"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# EPICS_ARTIFACT wins when set (test fixtures + explicit invocation).
# If it is set but the file is missing or empty, AC4 fires. If unset,
# fall back to .gaia/artifacts/planning-artifacts/epics-and-stories.md. If neither
# is present the checklist is simply skipped (observability still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${EPICS_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$EPICS_ARTIFACT"
else
  # E96-S7 partial-4c: smart-fallback
  if [ -f ".gaia/artifacts/planning-artifacts/epics-and-stories.md" ]; then
    ARTIFACT=".gaia/artifacts/planning-artifacts/epics-and-stories.md"
  elif [ -f "docs/planning-artifacts/epics-and-stories.md" ]; then
    ARTIFACT="docs/planning-artifacts/epics-and-stories.md"
  fi
fi

# E96-S7 partial-4c: smart-fallback for TEST_PLAN / ARCHITECTURE / PRD.
# F-17 (AF-2026-05-26-4): add the strategy/ subdir rung. /gaia-test-strategy
# writes its test-plan alias to .gaia/artifacts/test-artifacts/strategy/test-plan.md
# (the F-5 fix, AF-2026-05-24-9), so SV-16/SV-17 falsely failed when the plan
# lived there. Honour the canonical ADR-072 two-rung order — flat before
# strategy/ — that 8 sibling skills (gaia-trace, gaia-sprint-plan,
# gaia-readiness-check, gaia-edit-test-plan, ...) already use.
if [ -n "${TEST_PLAN_PATH:-}" ]; then
  TEST_PLAN="$TEST_PLAN_PATH"
elif [ -f ".gaia/artifacts/test-artifacts/test-plan.md" ]; then
  TEST_PLAN=".gaia/artifacts/test-artifacts/test-plan.md"
elif [ -f ".gaia/artifacts/test-artifacts/strategy/test-plan.md" ]; then
  TEST_PLAN=".gaia/artifacts/test-artifacts/strategy/test-plan.md"
elif [ -f "docs/test-artifacts/test-plan.md" ]; then
  TEST_PLAN="docs/test-artifacts/test-plan.md"
else
  TEST_PLAN="docs/test-artifacts/strategy/test-plan.md"
fi
if [ -n "${ARCHITECTURE_PATH:-}" ]; then
  ARCHITECTURE="$ARCHITECTURE_PATH"
elif [ -f ".gaia/artifacts/planning-artifacts/architecture.md" ]; then
  ARCHITECTURE=".gaia/artifacts/planning-artifacts/architecture.md"
else
  ARCHITECTURE="docs/planning-artifacts/architecture.md"
fi
if [ -n "${PRD_PATH:-}" ]; then
  PRD="$PRD_PATH"
elif [ -f ".gaia/artifacts/planning-artifacts/prd.md" ]; then
  PRD=".gaia/artifacts/planning-artifacts/prd.md"
else
  PRD="docs/planning-artifacts/prd.md"
fi

# ---------- 0b. Em-dash heading normalization (AF-2026-05-24-9 / Test02 F-7) ----------
# Test02 F-7: the PM/architect subagent reliably emits ASCII `--` instead
# of the canonical em-dash `—` (U+2014) in epic headings. The
# `resolve-epic-slug.sh` resolver accepts both forms per AF-2026-05-22-6
# Bug-5, but `finalize.sh` SV-03 only recognizes the `## Epic N:` form
# (F-8 separate). Either way, the ASCII `--` form is a Markdown
# autocorrect artifact, not the canonical heading shape.
#
# Producer-side fix: normalize ASCII `## EN -- Title` → `## EN — Title`
# (em-dash) in epic headings. Stories under H3 use a different pattern
# (### Story EN-SM — Title) which is harmless to normalize too.
#
# Idempotent: re-runs on already-normalized text are no-ops.
if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
  # Use python3 (always available per ADR-074) for the unicode-aware rewrite.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ARTIFACT" <<'NORMPY' || log "WARNING: em-dash normalization failed (F-7 mitigation)"
import sys, re, io
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
# Match: ## E{N} -- Title (epic headings) and ### Story EN-SM -- Title
new = re.sub(r'^(##+\s+(?:E\d+|Story\s+E\d+-S\d+))\s+--\s+', r'\1 — ', content, flags=re.MULTILINE)
if new != content:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new)
NORMPY
    log "em-dash normalization applied to $ARTIFACT (F-7 mitigation — ASCII -- → em-dash)"
  fi
fi

# ---------- 1. Run the 31-item checklist ----------
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
# Pass when an H2 heading containing the pattern is present.
heading_present() {
  local f="$1" text="$2"
  if grep -Eiq "^##[[:space:]]+${text}([[:space:]]|\$|[[:punct:]])" "$f" 2>/dev/null; then
    echo "pass"
  else
    echo "fail"
  fi
}

# pattern_present <file> <extended-regex>
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# epic_headings_present <file>
# Pass when at least one canonical epic heading exists in either form:
#   `## Epic N:` (legacy form) OR `## EN — Title` (em-dash form preferred
#   by resolve-epic-slug.sh per AF-2026-05-22-6 Bug-5).
# AF-2026-05-24-14 / Test02 F-8: SV-03 previously only accepted the
# `## Epic N:` form, marking the em-dash form as a violation even
# though the resolver accepts both. Now accepts both forms.
epic_headings_present() {
  local f="$1"
  grep -Eq '^##[[:space:]]+(Epic[[:space:]]+[0-9]+|E[0-9]+[[:space:]]+(—|--))' "$f" 2>/dev/null \
    && echo "pass" || echo "fail"
}

# story_headings_present <file>
# Pass when at least one "### Story {KEY}:" heading exists, where KEY
# matches E<num>-S<num>.
story_headings_present() {
  local f="$1"
  grep -Eq '^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+' "$f" 2>/dev/null \
    && echo "pass" || echo "fail"
}

# per_story_field_present <file> <field-label>
# For every "### Story ..." block in the file, verify that a line
# starting with the given field label (e.g. "- Priority:", "- Size:")
# exists before the next heading. Pass iff every story block carries
# the field.
per_story_field_present() {
  local f="$1" label="$2"
  awk -v label="$label" '
    BEGIN { in_story = 0; total = 0; missing = 0; has_field = 0 }
    function finalize_block() {
      if (in_story) {
        total++
        if (!has_field) { missing++ }
      }
    }
    /^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ {
      finalize_block()
      in_story = 1
      has_field = 0
      next
    }
    /^###[[:space:]]/ && !/^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ {
      finalize_block()
      in_story = 0
      has_field = 0
      next
    }
    /^##[[:space:]]/ {
      finalize_block()
      in_story = 0
      has_field = 0
      next
    }
    in_story {
      lower = tolower($0)
      lab = tolower(label)
      # AF-2026-05-22-9 Bug-3: also accept bolded `**Priority:**` /
      # `**Size:**` / etc. field labels, which Derek emits for visual
      # clarity in epics-and-stories.md. Optional `**` markers before
      # the label and around the colon are now tolerated.
      pat = "^[[:space:]]*[-*]?[[:space:]]*(\\*\\*)?" lab "(\\*\\*)?[[:space:]]*:"
      if (match(lower, pat)) { has_field = 1 }
    }
    END {
      finalize_block()
      if (total == 0) { exit 1 }
      exit (missing == 0 ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

# per_story_enum_valid <file> <field-label> <allowed-regex>
# For every story block, find the field line and verify its value
# matches the allowed regex (case-insensitive). Lines without the
# field are ignored here — presence is checked separately.
per_story_enum_valid() {
  local f="$1" label="$2" allowed="$3"
  awk -v label="$label" -v allowed="$allowed" '
    BEGIN { in_story = 0; invalid = 0 }
    /^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ { in_story = 1; next }
    /^###[[:space:]]/ && !/^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ { in_story = 0; next }
    /^##[[:space:]]/ { in_story = 0; next }
    in_story {
      lower = tolower($0)
      lab = tolower(label)
      # AF-2026-05-22-9 Bug-3 mirror: accept bolded labels here too so
      # enum-validation does not silently miss `**Priority:** must` etc.
      pat = "^[[:space:]]*[-*]?[[:space:]]*(\\*\\*)?" lab "(\\*\\*)?[[:space:]]*:[[:space:]]*"
      if (match(lower, pat)) {
        rest = substr(lower, RSTART + RLENGTH)
        # Trim leading spaces and surrounding quotes/backticks/asterisks.
        gsub(/^[[:space:]`"'"'"'*]+/, "", rest)
        gsub(/[[:space:]`"'"'"'*].*$/, "", rest)
        if (rest !~ allowed) { invalid = 1 }
      }
    }
    END { exit (invalid == 0 ? 0 : 1) }
  ' "$f" && echo "pass" || echo "fail"
}

# no_duplicate_story_keys <file>
# Pass when every "### Story {KEY}:" key is unique across the file.
no_duplicate_story_keys() {
  local f="$1"
  awk '
    BEGIN { dup = 0 }
    /^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ {
      match($0, /E[0-9]+-S[0-9]+/)
      key = substr($0, RSTART, RLENGTH)
      seen[key]++
      if (seen[key] > 1) { dup = 1 }
    }
    END { exit (dup ? 1 : 0) }
  ' "$f" && echo "pass" || echo "fail"
}

# no_circular_dependencies <file>
# Parse per-story "Depends on:" lines into a directed graph and run
# Kahn's topological sort. Pass when every story drains (no cycles).
# The literal token "none" is treated as an empty dependency list
# (EC-4). Self-loops (EC-3) are recorded as an edge and fail Kahn.
no_circular_dependencies() {
  local f="$1"
  awk '
    BEGIN { in_story = 0; cur = ""; n = 0 }
    /^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ {
      match($0, /E[0-9]+-S[0-9]+/)
      cur = substr($0, RSTART, RLENGTH)
      if (!(cur in idx)) { idx[cur] = 1; keys[++n] = cur; indeg[cur] = 0 }
      in_story = 1
      next
    }
    /^###[[:space:]]/ && !/^###[[:space:]]+Story[[:space:]]+E[0-9]+-S[0-9]+/ { in_story = 0; next }
    /^##[[:space:]]/ { in_story = 0; next }
    in_story {
      lower = tolower($0)
      if (match(lower, /^[[:space:]]*[-*]?[[:space:]]*depends[[:space:]]+on[[:space:]]*:/)) {
        rest = substr($0, RSTART + RLENGTH)
        gsub(/[\[\]]/, " ", rest)
        lrest = tolower(rest)
        if (lrest ~ /^[[:space:]]*none[[:space:]]*$/) { next }
        line = rest
        while (match(line, /E[0-9]+-S[0-9]+/)) {
          dep = substr(line, RSTART, RLENGTH)
          edges[cur "@@" dep] = 1
          line = substr(line, RSTART + RLENGTH)
        }
      }
    }
    END {
      for (e in edges) {
        split(e, pair, "@@")
        src = pair[1]; dst = pair[2]
        if (!(src in idx)) { idx[src] = 1; keys[++n] = src; indeg[src] = 0 }
        if (!(dst in idx)) { idx[dst] = 1; keys[++n] = dst; indeg[dst] = 0 }
        indeg[src]++
      }
      drained = 0
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          k = keys[i]
          if (k == "") continue
          if (indeg[k] == 0) {
            for (e in edges) {
              split(e, pair, "@@")
              if (pair[2] == k) {
                indeg[pair[1]]--
                delete edges[e]
              }
            }
            drained++
            keys[i] = ""
            changed = 1
          }
        }
      }
      exit (drained == n ? 0 : 1)
    }
  ' "$f" && echo "pass" || echo "fail"
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 / EC-1 — Caller explicitly pointed at an artifact path but it
  # does not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-create-epics to produce .gaia/artifacts/planning-artifacts/epics-and-stories.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 31-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-create-epics (31 items — 21 script-verifiable, 10 LLM-checkable)\n' >&2

  # --- Script-verifiable items (21) ---

  # Output Verification (SV-01..SV-02)
  item_check "SV-01" "Output file saved to docs/planning-artifacts/epics-and-stories.md" \
    "$(file_exists "$ARTIFACT")"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Epics (SV-03..SV-04)
  item_check "SV-03" "Epics section present (## Epic N: headings)" \
    "$(epic_headings_present "$ARTIFACT")"
  item_check "SV-04" "Stories section present (### Story E{N}-S{N}: headings)" \
    "$(story_headings_present "$ARTIFACT")"

  # Per-story frontmatter fields (SV-05..SV-10)
  item_check "SV-05" "Every story declares Priority" \
    "$(per_story_field_present "$ARTIFACT" "Priority")"
  item_check "SV-06" "Every story declares Size" \
    "$(per_story_field_present "$ARTIFACT" "Size")"
  item_check "SV-07" "Every story declares Depends on" \
    "$(per_story_field_present "$ARTIFACT" "Depends on")"
  item_check "SV-08" "Every story declares Blocks" \
    "$(per_story_field_present "$ARTIFACT" "Blocks")"
  item_check "SV-09" "Every story declares Risk (risk_level)" \
    "$(per_story_field_present "$ARTIFACT" "Risk")"
  item_check "SV-10" "Every story declares Acceptance Criteria" \
    "$(per_story_field_present "$ARTIFACT" "Acceptance Criteria")"

  # Enum validation (SV-11..SV-13)
  item_check "SV-11" "Priority values restricted to P0/P1/P2" \
    "$(per_story_enum_valid "$ARTIFACT" "Priority" "^(p0|p1|p2)$")"
  item_check "SV-12" "Size values restricted to S/M/L/XL" \
    "$(per_story_enum_valid "$ARTIFACT" "Size" "^(s|m|l|xl)$")"
  item_check "SV-13" "Risk values restricted to high/medium/low" \
    "$(per_story_enum_valid "$ARTIFACT" "Risk" "^(high|medium|low)$")"

  # Dependencies (SV-14..SV-15)
  item_check "SV-14" "No circular dependencies (topological sort drains every story)" \
    "$(no_circular_dependencies "$ARTIFACT")"
  item_check "SV-15" "No duplicate story keys" \
    "$(no_duplicate_story_keys "$ARTIFACT")"

  # Test Integration (SV-16..SV-17)
  item_check "SV-16" "test-plan.md read and risk levels extracted (test-plan.md exists)" \
    "$(file_exists "$TEST_PLAN")"
  item_check "SV-17" "Every story surfaces a Risk value (risk levels extracted from test-plan)" \
    "$(pattern_present "$ARTIFACT" '^[[:space:]]*[-*]?[[:space:]]*risk[[:space:]]*:[[:space:]]*(high|medium|low)')"

  # Gates (SV-18..SV-20) — upstream artifact consumption and review gate.
  item_check "SV-18" "PRD consumed (prd.md exists upstream)" \
    "$(file_exists "$PRD")"
  item_check "SV-19" "Architecture consumed (architecture.md exists upstream)" \
    "$(file_exists "$ARCHITECTURE")"
  item_check "SV-20" "Review Findings Incorporated section present in architecture" \
    "$(if [ -f "$ARCHITECTURE" ]; then heading_present "$ARCHITECTURE" "Review[[:space:]]+Findings[[:space:]]+Incorporated"; else echo "fail"; fi)"

  # Traceability (SV-21)
  item_check "SV-21" "Traceability referenced (Traces to / FR-### identifier present)" \
    "$(pattern_present "$ARTIFACT" '(traces[[:space:]]+to|FR-[0-9]{3,})')"

  # --- LLM-checkable items (10) ---
  printf '\n[LLM-CHECK] The following 10 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Epics group related features logically
  LLM-02 — Each story follows user story format ("As a ... I want ... so that ...")
  LLM-03 — Stories ordered by dependency topology first, then business priority
  LLM-04 — High-risk stories include ATDD reminder in Dev Notes with adequate guidance
  LLM-05 — Review Findings Incorporated section content actually addresses findings
  LLM-06 — Brownfield mode: stories cover gap requirements only (no existing-feature stories)
  LLM-07 — Story sizes (S/M/L/XL) are reasonable for team velocity
  LLM-08 — Acceptance criteria are testable and unambiguous
  LLM-09 — Each epic has a clearly stated goal and success criteria
  LLM-10 — Priority labels (P0/P1/P2) match business intent described in PRD
EOF

  TOTAL_ITEMS=31
  LLM_ITEMS=10
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the epics-and-stories artifact to satisfy the failed items, then rerun /gaia-create-epics.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no epics-and-stories artifact found (EPICS_ARTIFACT unset and no .gaia/artifacts/planning-artifacts/epics-and-stories.md) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 11 >/dev/null 2>&1; then
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
