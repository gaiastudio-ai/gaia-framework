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

# ---------- 0. Resolve artifact path (E105-S2 / ADR-127 §7.2 + three-tier) ----------
# Tier 1 — TEST_STRATEGY_ARTIFACT env-var override wins.
# Tier 2 — NEW canonical home: .gaia/artifacts/planning-artifacts/test-strategy.md
#          (E105-S2: docs-about-testing moved out of test-artifacts/).
# Tier 3 — positive pre-ADR-111 evidence: legacy strategy/test-strategy.md
#          under docs/test-artifacts/ exists AND canonical .gaia/ dir does NOT.
# Tier 4 — legacy E53 placement: .gaia/artifacts/test-artifacts/strategy/test-strategy.md
#          (read-compat for pre-migration projects).
ARTIFACT=""
ARTIFACT_REQUESTED=0
if [ -n "${TEST_STRATEGY_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$TEST_STRATEGY_ARTIFACT"
elif [ -f ".gaia/artifacts/planning-artifacts/test-strategy.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/test-strategy.md"
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

  # ---------- 0c. Producer-side test-plan.md alias (AF-2026-05-24-9 / Test02 F-5) ----------
  # Test02 F-5: /gaia-test-strategy --plan writes test-strategy.md but
  # /gaia-create-epics gates on test-plan.md (via validate-gate.sh
  # test_plan_exists). The legacy /gaia-test-design is deprecated and
  # routes to /gaia-test-strategy, so the operator gets a naming-mismatch
  # halt that requires manual `cp test-strategy.md test-plan.md`.
  #
  # Producer-side fix: write a sibling test-plan.md alias next to the
  # canonical test-strategy.md so both names resolve to the same content.
  # When /gaia-create-epics later checks for test-plan.md, it finds it.
  # Idempotent on re-runs (overwrites).
  ARTIFACT_DIR="$(dirname "$ARTIFACT")"
  TEST_PLAN_ALIAS="$ARTIFACT_DIR/test-plan.md"
  if [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
    cp "$ARTIFACT" "$TEST_PLAN_ALIAS" 2>/dev/null && \
      log "wrote test-plan.md alias at $TEST_PLAN_ALIAS (F-5 mitigation — downstream /gaia-create-epics gates on this name)" || \
      log "WARNING: could not write test-plan.md alias at $TEST_PLAN_ALIAS"
  fi

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
# AF-2026-05-22-9 Bug-16: capture stderr so the underlying failure is visible
# in the operator log instead of being silently dropped. Failure remains
# non-fatal (observability is non-blocking) but the cause is now surfaced.
if [ -x "$CHECKPOINT" ]; then
  # F-15 (AF-2026-05-26-1): checkpoint.sh write REQUIRES --step (it die's
  # "--step is required" without it). Pass the final step number so the
  # observability write actually lands instead of failing silently.
  _cp_err=$("$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 1 2>&1 >/dev/null) || {
    log "checkpoint.sh write failed (non-fatal — observability gap only): ${_cp_err:-no stderr}"
  }
  unset _cp_err
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write"
fi

# ---------- 3. Emit lifecycle event ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  # F-15 (AF-2026-05-26-1): lifecycle-event.sh has NO `emit` subcommand and no
  # --event/--status flags — its interface is `--type <event_type> --workflow
  # <name> [--data <json>]`. The prior `emit --event ... --status ...` shape hit
  # the unknown-flag path and exited 1 (events never emitted). Carry the
  # checklist pass/fail outcome in --data to preserve the observability intent.
  _le_err=$("$LIFECYCLE_EVENT" \
      --type workflow_complete \
      --workflow "$WORKFLOW_NAME" \
      --data "{\"checklist\":\"$([ "$CHECKLIST_STATUS" -eq 0 ] && echo pass || echo fail)\"}" \
      2>&1 >/dev/null) || {
    log "lifecycle-event.sh emit failed (non-fatal — observability gap only): ${_le_err:-no stderr}"
  }
  unset _le_err
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
    # AF-2026-05-30-2 / Test10 F-22: gate the auto-stub on whether the run
    # was a docs-only run vs a real hydration run. Docs-only runs (no --plan
    # or --scaffold mode flag, or the strategy artifact was authored without
    # any new test_execution-relevant input) should NOT mutate
    # project-config.yaml — the operator just wanted the doc. The
    # GAIA_TEST_STRATEGY_DOCS_ONLY env signal (or no-mode-signal default for
    # invocations that produce only the artifact) skips the auto-stub
    # silently; the NOTICE path still surfaces missing sections.
    if [ "${GAIA_TEST_STRATEGY_DOCS_ONLY:-0}" = "1" ]; then
      if [ -n "$missing_sections" ]; then
        _ms="$(printf '%s' "$missing_sections" | sed 's/^[[:space:]]*//')"
        log "NOTICE (docs-only run): project-config.yaml is missing section(s) [${_ms}]. Auto-stub SKIPPED — run /gaia-test-strategy --plan to hydrate, or add manually via /gaia-config-test, /gaia-bridge-enable, /gaia-config-env."
        missing_sections=""  # neutralize the downstream auto-stub branch
      fi
    fi
    if [ -n "$missing_sections" ] && [ "${GAIA_TEST_STRATEGY_NO_AUTOSTUB:-0}" = "1" ]; then
      # F-027 (Test04): opt-out — the operator owns project-config.yaml and may
      # not want it mutated. With GAIA_TEST_STRATEGY_NO_AUTOSTUB=1, skip the
      # hydration and instead tell them exactly which sections to add by hand.
      _ms="$(printf '%s' "$missing_sections" | sed 's/^[[:space:]]*//')"
      log "NOTICE: project-config.yaml is missing section(s) [${_ms}] but auto-stub is DISABLED (GAIA_TEST_STRATEGY_NO_AUTOSTUB=1). Add them manually via /gaia-config-test, /gaia-bridge-enable, /gaia-config-env before invoking downstream skills."
    elif [ -n "$missing_sections" ]; then
      # AF-2026-05-24-14 / Test02 F-6: upgraded from warn-only to
      # auto-stub-hydrate. Previously this block only emitted a WARNING
      # and asked the operator to manually invoke config_hydrate_section
      # — but downstream skills (gaia-bridge-enable, gaia-test-automate,
      # gaia-deploy) still halted with generic "X missing" errors.
      # We now write empty stubs for the missing sections so those
      # downstream skills find the keys present (with empty bodies) and
      # can either proceed with defaults OR emit a more-specific
      # "section present but empty" error pointing at the right skill
      # to populate them.
      # AF-2026-05-31-1 / Test12 F-13: surface the side-effect explicitly
      # BEFORE the mutation lands, not only in the post-mutation summary.
      # A `--plan` operator running what looks like a doc-authoring command
      # has no expectation that project-config.yaml will be touched; the
      # quiet auto-stub left a "wait, why did my config change?" trail.
      # The pre-mutation banner names the file, the sections that will be
      # appended, and the opt-out env var IN THE SAME LINE — so a single
      # scroll-back surfaces the contract.
      _ms_pre="$(printf '%s' "$missing_sections" | sed 's/^[[:space:]]*//')"
      log "NOTICE — test-strategy --plan will APPEND empty stubs to project-config.yaml for sections [${_ms_pre}] so downstream skills (gaia-bridge-enable, gaia-test-automate, gaia-deploy) can resolve the keys. Set GAIA_TEST_STRATEGY_NO_AUTOSTUB=1 to skip this auto-stub and receive a manual-add NOTICE instead."
      log "test-strategy.md was written; project-config.yaml is missing sections:${missing_sections}"
      log "F-6 auto-stub-hydration: writing empty stubs for each missing section so downstream skills can resolve the keys"
      log "Downstream skills affected: /gaia-bridge-enable (test_execution_bridge), /gaia-test-automate (test_execution.tier_N.command), /gaia-deploy (environments). Populate the stubs via /gaia-config-test, /gaia-bridge-enable scaffold, /gaia-config-env before invoking those."

      # Append empty-stub blocks. Each block has a comment marker so it's
      # obvious which sections came from the auto-hydrator vs being
      # operator-authored.
      ensure_trailing_newline() {
        if [ -s "$1" ] && [ "$(tail -c 1 "$1" | wc -l | tr -d ' ')" = "0" ]; then
          printf '\n' >> "$1"
        fi
      }
      ensure_trailing_newline "$CONFIG_PATH"

      case " $missing_sections " in
        *" test_execution "*)
          cat >> "$CONFIG_PATH" <<'STUB'

# AF-2026-05-24-14 F-6 auto-stub — populate via /gaia-config-test
test_execution: {}
STUB
          ;;
      esac
      case " $missing_sections " in
        *" test_execution_bridge "*)
          cat >> "$CONFIG_PATH" <<'STUB'

# AF-2026-05-24-14 F-6 auto-stub — populate via /gaia-bridge-enable
test_execution_bridge:
  bridge_enabled: false
STUB
          ;;
      esac
      case " $missing_sections " in
        *" environments "*)
          cat >> "$CONFIG_PATH" <<'STUB'

# AF-2026-05-24-14 F-6 auto-stub — populate via /gaia-config-env
environments: {}
STUB
          ;;
      esac
      # F-027 (Test04): make the config mutation transparent — the operator
      # owns this file, so emit an explicit summary naming exactly which
      # sections were appended and how to revert, not just a generic "complete".
      _stubbed="$(printf '%s' "$missing_sections" | sed 's/^[[:space:]]*//')"
      log "NOTICE: auto-stub-hydration MUTATED $CONFIG_PATH — appended empty stub section(s): [${_stubbed}]. Each block is tagged with an 'AF-2026-05-24-14 F-6 auto-stub' comment marker. To revert: delete those marked blocks. To populate: /gaia-config-test, /gaia-bridge-enable, /gaia-config-env. Set GAIA_TEST_STRATEGY_NO_AUTOSTUB=1 to skip this hydration entirely."
      log "auto-stub-hydration complete; review $CONFIG_PATH and populate the stubs before invoking downstream skills"
    fi
  fi
fi

log "finalize complete for $WORKFLOW_NAME"
exit "$CHECKLIST_STATUS"
