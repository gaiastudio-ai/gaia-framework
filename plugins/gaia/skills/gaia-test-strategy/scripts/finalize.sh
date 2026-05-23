#!/usr/bin/env bash
# finalize.sh — /gaia-test-strategy skill finalize (AF-2026-05-22-5)
#
# /gaia-test-strategy is the successor to /gaia-test-design (renamed in
# the test-design → test-strategy deprecation). It had no scripts/
# directory at all — its SKILL.md called
# !${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh
# which silently no-op'd because the file didn't exist, so the SV-01..06
# checklist never ran.
#
# This adapts the gaia-test-design/scripts/finalize.sh pattern to the
# gaia-test-strategy artifact name + the 6-item SV checklist documented
# in gaia-test-strategy/SKILL.md §Validation.
#
# Responsibilities:
#   1. Run the SV-01..06 script-verifiable subset of the SKILL.md §Validation
#      checklist against the test-strategy.md artifact.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# Exit codes:
#   0 — finalize succeeded; all 6 script-verifiable items PASS (or no
#       artifact was requested — classic Cluster 11 behaviour).
#   1 — one or more script-verifiable checklist items FAIL; or a
#       checkpoint/lifecycle-event failure.
#
# Environment:
#   TEST_STRATEGY_ARTIFACT  Absolute path to the test-strategy.md artifact
#                           to validate. When set, the script runs the
#                           6-item checklist against it. When set but the
#                           file does not exist or is empty, AC3 fires —
#                           a single "no artifact to validate" violation
#                           is emitted and the script exits non-zero.
#                           When unset, the script falls back to
#                           .gaia/artifacts/test-artifacts/strategy/test-strategy.md
#                           (canonical post-ADR-111 + the strategy/
#                           subdir per ADR-072). If neither is present,
#                           the checklist run is skipped.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-test-strategy/finalize.sh"
WORKFLOW_NAME="test-strategy"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact path (three-tier idiom) ----------
# Tier 1 — TEST_STRATEGY_ARTIFACT env-var override wins.
# Tier 2 — positive pre-ADR-111 evidence: legacy strategy/test-strategy.md
#          under docs/test-artifacts/ exists AND canonical .gaia/ dir does NOT.
# Tier 3 — canonical default: .gaia/artifacts/test-artifacts/strategy/test-strategy.md.
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${TEST_STRATEGY_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$TEST_STRATEGY_ARTIFACT"
elif [ -f "docs/test-artifacts/strategy/test-strategy.md" ] && [ ! -d ".gaia/artifacts/test-artifacts" ]; then
  ARTIFACT="docs/test-artifacts/strategy/test-strategy.md"
elif [ -f ".gaia/artifacts/test-artifacts/strategy/test-strategy.md" ]; then
  ARTIFACT=".gaia/artifacts/test-artifacts/strategy/test-strategy.md"
fi

# ---------- 1. Run the SV-01..06 checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
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

file_exists() { [ -f "$1" ] && echo pass || echo fail; }
file_nonempty() { [ -s "$1" ] && echo pass || echo fail; }

# section_present <file> <heading-regex>
# Pass when an H2 (or H3) heading matching the regex (case-insensitive,
# numeric outline prefix tolerated) exists in the file.
section_present() {
  local f="$1" pattern="$2"
  if grep -Eqi "^#{2,3}[[:space:]]+([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?${pattern}([[:space:]]|\$|[[:punct:]])" "$f" 2>/dev/null; then
    echo pass
  else
    echo fail
  fi
}

# keyword_present <file> <regex>
keyword_present() {
  local f="$1" pattern="$2"
  if grep -Eqi "$pattern" "$f" 2>/dev/null; then
    echo pass
  else
    echo fail
  fi
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  log "no test-strategy artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-test-strategy --plan to produce .gaia/artifacts/test-artifacts/strategy/test-strategy.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 6-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-test-strategy (6 items — script-verifiable)\n' >&2

  # SV-01: test-strategy.md written.
  item_check "SV-01" "Output file exists at resolved path ($ARTIFACT)" \
    "$(file_exists "$ARTIFACT")"

  # SV-02: Risk assessment section.
  item_check "SV-02" "Risk assessment section present" \
    "$(section_present "$ARTIFACT" "Risk[[:space:]]+[Aa]ssessment")"

  # SV-03: Test pyramid / test levels keyword.
  item_check "SV-03" "Test pyramid / test levels keyword present" \
    "$(keyword_present "$ARTIFACT" "test[[:space:]]+pyramid|test[[:space:]]+levels|unit.*integration.*e2e")"

  # SV-04: Coverage targets / quality gates documented.
  item_check "SV-04" "Coverage targets / quality gates documented" \
    "$(keyword_present "$ARTIFACT" "coverage[[:space:]]+target|quality[[:space:]]+gate|code[[:space:]]+coverage")"

  # SV-05: Scaffold mode — config file generated for detected stack.
  # When invoked from --scaffold, a config file under the test framework dir
  # (e.g., vitest.config.ts, pytest.ini, .nycrc, jest.config.js, etc.) should
  # be present. In --plan mode this check is INFO-level pass (no scaffold expected).
  if [ -n "${SCAFFOLD_CONFIG_PATH:-}" ]; then
    item_check "SV-05" "Scaffold mode generated config file(s) for the detected stack" \
      "$([ -f "$SCAFFOLD_CONFIG_PATH" ] && echo pass || echo fail)"
  else
    item_check "SV-05" "Scaffold-mode config check (--plan mode: skipped)" pass
  fi

  # SV-06: Scaffold mode created test directory structure.
  if [ -n "${SCAFFOLD_TEST_DIR:-}" ]; then
    item_check "SV-06" "Scaffold mode created test directory structure" \
      "$([ -d "$SCAFFOLD_TEST_DIR" ] && echo pass || echo fail)"
  else
    item_check "SV-06" "Scaffold-mode test directory check (--plan mode: skipped)" pass
  fi

  printf '\nChecklist summary: %d/%d items passed\n' "$PASSED" "$CHECKED" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: re-run /gaia-test-strategy --plan to address the missing sections, then re-run finalize.\n' >&2
    CHECKLIST_STATUS=1
  fi

  printf '\n[LLM-CHECK] The following 3 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Project stack detected correctly (matches actual codebase).
  LLM-02 — Framework recommendation matches stack (per ground-truth-management defaults).
  LLM-03 — No actual test implementations created beyond smoke wiring (scaffold mode only).
EOF
else
  log "no test-strategy artifact found (TEST_STRATEGY_ARTIFACT unset and no test-strategy.md at .gaia/artifacts/test-artifacts/strategy/ or docs/test-artifacts/strategy/) — skipping checklist run"
fi

# ---------- 2. Write checkpoint ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    log "checkpoint.sh write failed (non-fatal — observability gap only)"
  fi
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write"
fi

# ---------- 3. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" emit \
      --workflow "$WORKFLOW_NAME" \
      --event finalize-complete \
      --status "$([ "$CHECKLIST_STATUS" -eq 0 ] && echo pass || echo fail)" \
      >/dev/null 2>&1; then
    log "lifecycle-event.sh emit failed (non-fatal — observability gap only)"
  fi
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emit"
fi

# ---------- 4. Config hydration fail-safe (AF-2026-05-22-7 Bug-21) ----------
# Bug-21 root cause: /gaia-test-strategy --plan is supposed to populate the
# test_execution / test_execution_bridge / environments blocks in
# project-config.yaml after authoring the strategy. The hydration step
# doesn't fire because there's no enforcement. Downstream /gaia-bridge-enable
# then halts with "test_execution_bridge missing — run /gaia-ci-setup first"
# pointing at the wrong upstream skill.
#
# Fail-safe: if a strategy artifact was written AND the project config still
# lacks the sections this skill owns, log a CRITICAL warning that names the
# missing sections and the correct remediation. Non-fatal — strategy artifact
# is the primary deliverable — but the warning makes downstream halts
# attributable to the right upstream skill.
if [ -n "${ARTIFACT:-}" ] && [ -f "${ARTIFACT:-}" ]; then
  CONFIG_PATH=""
  if [ -f ".gaia/config/project-config.yaml" ]; then
    CONFIG_PATH=".gaia/config/project-config.yaml"
  elif [ -f "config/project-config.yaml" ]; then
    CONFIG_PATH="config/project-config.yaml"
  fi
  if [ -n "$CONFIG_PATH" ]; then
    missing_sections=""
    grep -qE "^test_execution:" "$CONFIG_PATH" 2>/dev/null || missing_sections="${missing_sections} test_execution"
    grep -qE "^test_execution_bridge:" "$CONFIG_PATH" 2>/dev/null || missing_sections="${missing_sections} test_execution_bridge"
    grep -qE "^environments:" "$CONFIG_PATH" 2>/dev/null || missing_sections="${missing_sections} environments"
    if [ -n "$missing_sections" ]; then
      log "WARNING: test-strategy.md was written but project-config.yaml hydration was SKIPPED."
      log "         Missing sections in $CONFIG_PATH:${missing_sections}"
      log ""
      log "         Downstream skills (/gaia-bridge-enable expects test_execution_bridge,"
      log "         /gaia-test-automate expects test_execution.tier_N.command per AF-22-6"
      log "         Bug-6, /gaia-deploy expects environments) will halt with generic"
      log "         'X missing' errors that point at the wrong upstream remediation."
      log ""
      log "         Remediation: source \${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
      log "         and call config_hydrate_section <section> <yaml-fragment-file> for each"
      log "         missing section. The fragments must match the test_execution placements"
      log "         + tier_N commands + environments declared in test-strategy.md §Test Plan."
      log ""
      log "         This warning is fail-safe only — test-strategy.md was written"
      log "         successfully and is the primary artifact."
    fi
  fi
fi

log "finalize complete for $WORKFLOW_NAME"
exit "$CHECKLIST_STATUS"
