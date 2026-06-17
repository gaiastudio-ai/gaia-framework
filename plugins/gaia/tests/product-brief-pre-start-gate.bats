#!/usr/bin/env bats
# product-brief-pre-start-gate.bats — E46-S9 (FR-358, FR-347)
#
# VCP-PB-01 / VCP-PB-02 — pre_start gate enforcement on the
# /gaia-product-brief skill. The gate is wired via E45-S2's shared
# gate-predicates.sh library; this fixture validates the skill-specific
# contract: brainstorm artifact required, with the canonical halt
# message reachable via grep.
#
# Test plan classification: Script-verifiable (2). All bats tests run
# hermetically under $BATS_TEST_TMPDIR. macOS /bin/bash 3.2 compatible.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-product-brief"
SETUP="$SKILL_DIR/scripts/setup.sh"

setup() {
  common_setup
  # AF-2026-05-21-20: canonical .gaia/artifacts/ + legacy docs/ (back-compat).
  mkdir -p "$TEST_TMP/.gaia/artifacts/creative-artifacts"
  mkdir -p "$TEST_TMP/docs/creative-artifacts"
  mkdir -p "$TEST_TMP/_memory/checkpoints"
  export CHECKPOINT_PATH="$TEST_TMP/_memory/checkpoints"
  export LIFECYCLE_EVENTS_LOG="$TEST_TMP/_memory/lifecycle-events.ndjson"

  # Seed minimal project-config.yaml so resolve-config.sh succeeds.
  mkdir -p "$TEST_TMP/skill/config"
  cat >"$TEST_TMP/skill/config/project-config.yaml" <<YAML
project_root: $TEST_TMP
project_path: $TEST_TMP
memory_path: $TEST_TMP/_memory
checkpoint_path: $TEST_TMP/_memory/checkpoints
installed_path: $TEST_TMP/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-25
test_artifacts: $TEST_TMP/docs/test-artifacts
planning_artifacts: $TEST_TMP/docs/planning-artifacts
implementation_artifacts: $TEST_TMP/docs/implementation-artifacts
creative_artifacts: $TEST_TMP/docs/creative-artifacts
YAML
  export CLAUDE_SKILL_DIR="$TEST_TMP/skill"
}

teardown() { common_teardown; }

# -------------------------------------------------------------------------
# VCP-PB-01 — pre_start gate passes when brainstorm artifact exists.
# -------------------------------------------------------------------------
@test "setup.sh exits 0 when a brainstorm artifact exists" {
  # AF-2026-05-21-20: canonical .gaia/artifacts/ path.
  printf '# brainstorm fixture\n' \
    >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-foo.md"
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -eq 0 ]
  # No halt message about /gaia-brainstorm in the output.
  [[ "$output" != *"Run \`/gaia-brainstorm\`"* ]]
  # Setup-complete log line confirms the skill body would proceed.
  [[ "$output" == *"setup complete for create-product-brief"* ]]
}

@test "pre_start passes with multiple brainstorm artifacts" {
  printf '# bs1\n' >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-one.md"
  printf '# bs2\n' >"$TEST_TMP/.gaia/artifacts/creative-artifacts/brainstorm-two.md"
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# VCP-PB-02 — pre_start gate halts when no brainstorm artifact exists.
# -------------------------------------------------------------------------
@test "setup.sh exits non-zero when brainstorm artifact missing" {
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -ne 0 ]
  # Halt message must be grep-matchable on the canonical phrase. The
  # E45-S2 framework wraps the SKILL.md frontmatter error_message — which
  # currently reads `Run `/gaia-brainstorm` first to create a brainstorm
  # artifact` — and prefixes with the quality-gate tag.
  [[ "$output" == *"Run \`/gaia-brainstorm\` first to create a brainstorm artifact"* ]]
  [[ "$output" == *"quality-gate"* ]]
}

@test "halt happens before checkpoint load (no checkpoint side effect)" {
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -ne 0 ]
  # No checkpoint file should have been written for create-product-brief.
  [ ! -f "$CHECKPOINT_PATH/create-product-brief.json" ]
  [ ! -f "$CHECKPOINT_PATH/create-product-brief.yaml" ]
}

@test "an unrelated creative-artifact does not satisfy the gate" {
  # market-research-*.md is NOT a brainstorm artifact.
  printf '# market\n' \
    >"$TEST_TMP/docs/creative-artifacts/market-research-foo.md"
  cd "$TEST_TMP"
  run "$SETUP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run \`/gaia-brainstorm\`"* ]]
}
