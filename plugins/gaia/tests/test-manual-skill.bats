#!/usr/bin/env bats
# test-manual-skill.bats — contract tests for the gaia-test-manual SKILL.md,
# help CSV registration, and workflow manifest registration.
#
# Validates SKILL.md shape, orchestration_class, CSV column integrity,
# and the disambiguation section that distinguishes this skill from
# the automated test runner.

load 'test_helper.bash'

setup() {
  common_setup
  PUBLIC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/SKILL.md"
  HELP_CSV="$PUBLIC_ROOT/plugins/gaia/knowledge/gaia-help.csv"
  MANIFEST_CSV="$PUBLIC_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC2 — SKILL.md exists on disk.
# ---------------------------------------------------------------------------

@test "SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

# ---------------------------------------------------------------------------
# AC2 — Frontmatter: name is gaia-test-manual.
# ---------------------------------------------------------------------------

@test "SKILL.md frontmatter name is gaia-test-manual" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$SKILL_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^name:[[:space:]]+gaia-test-manual[[:space:]]*$' "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC2 — Frontmatter: orchestration_class is reviewer.
# ---------------------------------------------------------------------------

@test "SKILL.md frontmatter orchestration_class is reviewer" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$SKILL_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^orchestration_class:[[:space:]]+reviewer[[:space:]]*$' "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC2 — help.csv has a test-manual row in the testing module.
# ---------------------------------------------------------------------------

@test "help CSV has test-manual row in testing module" {
  grep -F '"test-manual"' "$HELP_CSV" | grep -F '"testing"'
}

# ---------------------------------------------------------------------------
# AC2 — workflow-manifest.csv has a test-manual row with native skill path.
# ---------------------------------------------------------------------------

@test "manifest CSV has test-manual row with SKILL.md path" {
  grep -F '"test-manual"' "$MANIFEST_CSV" | grep -F 'plugins/gaia/skills/gaia-test-manual/SKILL.md'
}

# ---------------------------------------------------------------------------
# AC2 — help.csv column count is consistent (no broken rows).
# ---------------------------------------------------------------------------

@test "help CSV test-manual row has correct column count" {
  # Header has 9 columns; every row must match.
  header_cols="$(head -1 "$HELP_CSV" | awk -F',' '{print NF}')"
  row_cols="$(grep -F '"test-manual"' "$HELP_CSV" | awk -F',' '{print NF}')"
  [ "$row_cols" -eq "$header_cols" ]
}

# ---------------------------------------------------------------------------
# AC2 — manifest CSV column count is consistent.
# ---------------------------------------------------------------------------

@test "manifest CSV test-manual row has correct column count" {
  header_cols="$(head -1 "$MANIFEST_CSV" | awk -F',' '{print NF}')"
  row_cols="$(grep -F '"test-manual"' "$MANIFEST_CSV" | awk -F',' '{print NF}')"
  [ "$row_cols" -eq "$header_cols" ]
}

# ---------------------------------------------------------------------------
# AC5 — Disambiguation section present and names gaia-test-run.
# ---------------------------------------------------------------------------

@test "SKILL.md has Disambiguation section" {
  grep -F "## Disambiguation" "$SKILL_FILE"
}

@test "Disambiguation section names gaia-test-run" {
  # Extract text between ## Disambiguation and the next ## heading
  awk '/^## Disambiguation/{found=1; next} found && /^## /{exit} found{print}' "$SKILL_FILE" \
    | grep -F "gaia-test-run"
}

# ---------------------------------------------------------------------------
# AC5 — help.csv description distinguishes from gaia-test-run.
# ---------------------------------------------------------------------------

@test "help CSV description text mentions gaia-test-run for disambiguation" {
  grep -F '"test-manual"' "$HELP_CSV" | grep -F 'gaia-test-run'
}

# ---------------------------------------------------------------------------
# AC2 — SKILL.md has argument-hint.
# ---------------------------------------------------------------------------

@test "SKILL.md has argument-hint" {
  awk 'BEGIN{n=0} /^---$/{n++; next} n==1{print}' "$SKILL_FILE" > "$TEST_TMP/fm.yaml"
  grep -E '^argument-hint:' "$TEST_TMP/fm.yaml"
}

# ---------------------------------------------------------------------------
# AC2 — manifest CSV agent column is manual-tester.
# ---------------------------------------------------------------------------

@test "manifest CSV agent is manual-tester" {
  grep -F '"test-manual"' "$MANIFEST_CSV" | grep -F '"manual-tester"'
}

# ---------------------------------------------------------------------------
# W5 — setup.sh and finalize.sh are executable with bash shebang.
# ---------------------------------------------------------------------------

@test "setup.sh is executable" {
  setup_script="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/setup.sh"
  [ -x "$setup_script" ]
}

@test "setup.sh has a bash shebang" {
  setup_script="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/setup.sh"
  head -1 "$setup_script" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash'
}

@test "finalize.sh is executable" {
  finalize_script="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/finalize.sh"
  [ -x "$finalize_script" ]
}

@test "finalize.sh has a bash shebang" {
  finalize_script="$PUBLIC_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/finalize.sh"
  head -1 "$finalize_script" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash'
}

# ---------------------------------------------------------------------------
# I3 — SKILL.md must NOT reference PLUGIN_DIR (use CLAUDE_PLUGIN_ROOT).
# ---------------------------------------------------------------------------

@test "SKILL.md does not reference PLUGIN_DIR" {
  assert_file_excludes "$SKILL_FILE" 'PLUGIN_DIR'
}
