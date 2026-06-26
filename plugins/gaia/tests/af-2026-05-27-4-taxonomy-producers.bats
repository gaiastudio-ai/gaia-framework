#!/usr/bin/env bats
# af-2026-05-27-4-taxonomy-producers.bats
#
# AF-2026-05-27-4 / Test05 F-023, F-025, F-048 — E105-S2 producer half.
#
# The E105-S2 file-move script (migrate-planning-vs-test.sh) and the consumer
# resolver (validate-gate.sh planning-artifacts-first) were already landed
# (see e105-s2-planning-vs-test-taxonomy.bats). This suite covers the remaining
# PRODUCER half: gaia-test-strategy + gaia-trace now WRITE/RESOLVE the
# docs-about-testing to the planning-artifacts/ canonical home, with the legacy
# test-artifacts/strategy/ + flat placements honored read-only.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TS_SKILL="$PLUGIN_ROOT/skills/gaia-test-strategy/SKILL.md"
  TS_FINAL="$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  TR_SKILL="$PLUGIN_ROOT/skills/gaia-trace/SKILL.md"
  TR_FINAL="$PLUGIN_ROOT/skills/gaia-trace/scripts/finalize.sh"
}
teardown() { common_teardown; }

# ---------- gaia-test-strategy producer (F-023, F-048) ----------

@test "F-023: gaia-test-strategy SKILL.md writes test-strategy.md to planning-artifacts/ canonical" {
  grep -qF '.gaia/artifacts/planning-artifacts/test-strategy.md' "$TS_SKILL"
  # The Step-4 output line + checkpoint must point at the new home, not strategy/.
  grep -qE 'Write the compiled test strategy to .*planning-artifacts/test-strategy\.md' "$TS_SKILL"
}

@test "gaia-test-strategy SKILL.md cites / for the move" {
  # ID-free rewrite: the behavioral contract is that the file documents the
  # docs-ABOUT-testing placement rule and names migrate-planning-vs-test.sh
  # as the migration helper — both durable anchors that survive ID scrubbing.
  grep -qE 'docs-ABOUT-testing|migrate-planning-vs-test\.sh' "$TS_SKILL"
}

@test "F-023: gaia-test-strategy finalize.sh resolves planning-artifacts/ test-strategy FIRST" {
  # Compare the CODE arms (ARTIFACT= assignments), not header comments: the
  # new-home assignment must appear before the legacy strategy/ assignment.
  # The path may be project-root-anchored ($_PROJECT_ROOT/...) or bare; match
  # the canonical-vs-legacy suffix regardless of the anchor prefix.
  new_line=$(grep -n 'ARTIFACT=".*\.gaia/artifacts/planning-artifacts/test-strategy.md"' "$TS_FINAL" | head -1 | cut -d: -f1)
  legacy_line=$(grep -n 'ARTIFACT=".*\.gaia/artifacts/test-artifacts/strategy/test-strategy.md"' "$TS_FINAL" | head -1 | cut -d: -f1)
  [ -n "$new_line" ]
  [ -n "$legacy_line" ]
  [ "$new_line" -lt "$legacy_line" ]
}

@test "F-023: gaia-test-strategy finalize.sh still resolves the legacy strategy/ placement (read-compat)" {
  grep -qF '.gaia/artifacts/test-artifacts/strategy/test-strategy.md' "$TS_FINAL"
}

@test "F-048: gaia-test-strategy SKILL.md documents which mode produces which file" {
  # F-048: the test-strategy.md vs test-plan.md split must be documented.
  # ID-free rewrite: the behavioral contract is that the SKILL.md explicitly
  # states which mode (--plan) produces which file (test-strategy.md vs
  # test-plan.md). The phrase "--plan produces" captures this split durably.
  grep -qE '\-\-plan produces|--plan.*produces' "$TS_SKILL"
  grep -qF 'test-plan.md' "$TS_SKILL"
}

# ---------- gaia-trace producer (F-025) ----------

@test "F-025: gaia-trace SKILL.md writes traceability-matrix.md to planning-artifacts/ canonical" {
  grep -qF '.gaia/artifacts/planning-artifacts/traceability-matrix.md' "$TR_SKILL"
  # ID-free rewrite: the behavioral contract is that the file documents the
  # docs-ABOUT-testing placement rule and names migrate-planning-vs-test.sh
  # as the migration helper — both durable anchors that survive ID scrubbing.
  grep -qE 'docs-ABOUT-testing|migrate-planning-vs-test\.sh' "$TR_SKILL"
}

@test "F-025: gaia-trace SKILL.md still honors legacy strategy/ + flat placements (read-compat)" {
  grep -qF '.gaia/artifacts/test-artifacts/strategy/traceability-matrix.md' "$TR_SKILL"
  grep -qF '.gaia/artifacts/test-artifacts/traceability-matrix.md' "$TR_SKILL"
}

@test "F-025: gaia-trace SKILL.md test-plan READ path prefers planning-artifacts/ first" {
  # The read precedence line must mention planning-artifacts before the legacy paths.
  new_line=$(grep -n 'planning-artifacts/test-plan.md' "$TR_SKILL" | head -1 | cut -d: -f1)
  [ -n "$new_line" ]
}

@test "F-025: gaia-trace finalize.sh TM_PATHS lists planning-artifacts/ FIRST" {
  run grep -n 'TM_PATHS=' "$TR_FINAL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planning-artifacts/traceability-matrix.md"* ]]
  # planning-artifacts must precede test-artifacts in the TM_PATHS string.
  line=$(grep 'TM_PATHS=' "$TR_FINAL" | head -1)
  pa_pos=$(awk -v s="$line" 'BEGIN{print index(s,"planning-artifacts/traceability-matrix.md")}')
  ta_pos=$(awk -v s="$line" 'BEGIN{print index(s,"test-artifacts/strategy/traceability-matrix.md")}')
  [ "$pa_pos" -gt 0 ]
  [ "$ta_pos" -gt 0 ]
  [ "$pa_pos" -lt "$ta_pos" ]
}

# ---------- migration script smoke (already landed; guard it stays) ----------

@test "migrate-planning-vs-test.sh exists, dry-run is the default, no rm -rf command" {
  local M="$PLUGIN_ROOT/scripts/migrate-planning-vs-test.sh"
  [ -f "$M" ]
  bash -n "$M"
  grep -qF 'MODE="dry-run"' "$M"
  # No rm -rf in COMMAND position. Strip comment lines and any line that only
  # documents the prohibition ("NEVER rm -rf"); assert zero remaining hits.
  run bash -c "grep -vE '^[[:space:]]*#' '$M' | grep -iv 'never .*rm -rf' | grep -E 'rm[[:space:]]+-rf' || true"
  [ -z "$output" ]
}
