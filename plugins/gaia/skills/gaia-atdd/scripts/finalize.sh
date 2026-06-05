#!/usr/bin/env bash
# finalize.sh — /gaia-atdd skill finalize
#
# Extends the finalize scaffolding with a 5-item post-completion checklist
# (1 script-verifiable + 4 LLM-checkable) derived from the atdd checklist.
#
# Responsibilities:
#   1. Run the script-verifiable subset of the 5 checklist items
#      against the atdd-{story_key}.md artifact. Validation runs FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write.
#
# Exit codes:
#   0 — finalize succeeded; the script-verifiable item PASSes (or
#       no artifact was requested — checklist skipped).
#   1 — the script-verifiable checklist item FAILs; the AC4
#       "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   ATDD_ARTIFACT  Absolute path to the atdd-{story_key}.md artifact
#                  to validate. When set, the script runs the 5-item
#                  checklist against it. When set but the file does
#                  not exist or is empty, AC4 fires — a single
#                  "no artifact to validate" violation is emitted
#                  and the script exits non-zero. When unset, the
#                  script skips the checklist (observability still
#                  runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-atdd/finalize.sh"
WORKFLOW_NAME="atdd"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# The artifact path is deterministically derivable from STORY_KEY —
# `.gaia/artifacts/test-artifacts/atdd-${STORY_KEY}.md`. Earlier revisions
# silently skipped the traceability checklist whenever ATDD_ARTIFACT was
# unset, even though the path is reconstructable. We now derive it whenever
# STORY_KEY is set; ATDD_ARTIFACT remains the explicit override for test
# fixtures and bespoke invocations.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${ATDD_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$ATDD_ARTIFACT"
elif [ -n "${STORY_KEY:-}" ]; then
  # Derive from the story key relative to the project root. PROJECT_ROOT
  # falls back to GAIA_PROJECT_ROOT, then to PWD when neither is set.
  # Canonical-first with positive-evidence legacy fallback.
  derive_root="${PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}"
  if [ -f "$derive_root/docs/test-artifacts/atdd-${STORY_KEY}.md" ] && [ ! -d "$derive_root/.gaia/artifacts/test-artifacts" ]; then
    ARTIFACT="$derive_root/docs/test-artifacts/atdd-${STORY_KEY}.md"
  else
    ARTIFACT="$derive_root/.gaia/artifacts/test-artifacts/atdd-${STORY_KEY}.md"
  fi
  ARTIFACT_REQUESTED=1
fi

# ---------- 1. Run the 5-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s [skill: atdd]\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s [skill: atdd]\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

# heading_present() is a single shared implementation
# (plugins/gaia/scripts/lib/heading-present.sh) with one uniform, permissive
# regex accepting optional numbered+lettered outline prefixes (11, 11b, 1.2.3).
# Previously finalize.sh scripts carried divergent inline copies, so the same
# heading passed one skill's check and failed another's. Sourced via a
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

# ac_to_test_table_present <file>
# Pass when an "AC-to-Test Mapping" (or "Traceability") H2 heading exists
# AND a markdown table row references an AC identifier (AC1, AC-EC1, etc.).
ac_to_test_table_present() {
  local f="$1"
  if [ "$(heading_present "$f" "(AC-to-Test[[:space:]]+Mapping|Traceability|AC[[:space:]]+to[[:space:]]+Test)")" = "pass" ] \
    && grep -Eq '^\|[[:space:]]*AC[-A-Z0-9]+' "$f" 2>/dev/null; then
    echo "pass"
  else
    echo "fail"
  fi
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-atdd to produce .gaia/artifacts/test-artifacts/atdd-{story_key}.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 5-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-atdd (5 items — 1 script-verifiable, 4 LLM-checkable)\n' >&2

  # --- Script-verifiable items (1) ---

  # "Test-to-AC traceability documented"
  item_check "SV-01" "Test-to-AC traceability documented" \
    "$(ac_to_test_table_present "$ARTIFACT")"

  # --- LLM-checkable items (4) ---
  printf '\n[LLM-CHECK] The following 4 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Acceptance criteria loaded from story/PRD
  LLM-02 — Each AC mapped to exactly one test
  LLM-03 — Tests fail initially (red phase)
  LLM-04 — Tests are atomic and independent
EOF

  TOTAL_ITEMS=5
  LLM_ITEMS=4
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the atdd artifact to satisfy the failed items, then rerun /gaia-atdd.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no atdd artifact requested (ATDD_ARTIFACT unset and STORY_KEY unset) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 1b. Size advisory (risk-aware) ----------
#
# The 10KB advisory is downgraded from WARNING to INFO when the story's
# `risk` frontmatter field is `high`. Rationale: high-risk stories
# legitimately produce more ATDD content (more ACs, more edge cases). A
# WARNING on every high-risk artifact is signal-blind. For medium / low /
# unset risk a WARNING still fires; for high risk the same observation is
# logged at INFO level so the audit trail is preserved without polluting
# the WARNING channel.
if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  size_bytes="$(wc -c <"$ARTIFACT" | tr -d ' ')"
  if [ "$size_bytes" -gt 10240 ]; then
    size_kb=$(( size_bytes / 1024 ))
    # Resolve the story risk by parsing the story file frontmatter when
    # available. If the story file or risk field is absent, default to
    # `medium` so the conservative (WARNING) path fires.
    story_risk="medium"
    if [ -n "${STORY_KEY:-}" ]; then
      project_root_for_risk="${PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}"
      # Canonical-first with positive-evidence legacy fallback.
      if [ -d "$project_root_for_risk/.gaia/artifacts/implementation-artifacts" ]; then
        story_glob="$project_root_for_risk/.gaia/artifacts/implementation-artifacts/${STORY_KEY}-"*.md
      else
        story_glob="$project_root_for_risk/docs/implementation-artifacts/${STORY_KEY}-"*.md
      fi
      # shellcheck disable=SC2086
      for sf in $story_glob; do
        if [ -f "$sf" ]; then
          # Extract `risk:` value from the frontmatter — strip whitespace
          # and any surrounding quotes. Tolerate either quoted or bare
          # YAML scalar form. Matches only the first occurrence and stops
          # at the closing `---` delimiter.
          parsed_risk="$(sed -n '/^---$/,/^---$/p' "$sf" \
            | grep -E '^[[:space:]]*risk[[:space:]]*:' \
            | head -1 \
            | sed -E 's/^[[:space:]]*risk[[:space:]]*:[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]+$//')"
          if [ -n "$parsed_risk" ]; then story_risk="$parsed_risk"; fi
          break
        fi
      done
    fi
    if [ "$story_risk" = "high" ]; then
      printf '[INFO] ATDD output exceeds 10KB (%dKB) for high-risk story — review for completeness (advisory).\n' \
        "$size_kb" >&2
    else
      printf '[WARNING] ATDD output exceeds 10KB (%dKB) — review for completeness.\n' \
        "$size_kb" >&2
    fi
  fi
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
