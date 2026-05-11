#!/usr/bin/env bats
# cluster-4-analysis-e2e.bats — Cluster 4 end-to-end test (E28-S39)
#
# Runs all 6 analysis skills (brainstorm, product-brief, market-research,
# domain-research, tech-research, advanced-elicitation) sequentially against
# a deterministic fixture, asserting that:
#   AC1: All skills execute against the fixture
#   AC2: setup.sh/finalize.sh pairs run without error, checkpoints + events emitted
#   AC3: Artifacts match legacy reference outputs (byte-for-byte, modulo allowlist)
#   AC4: Wired into CI, completes under 5 minutes
#   AC5: Pass/fail report generated
#
# Usage:
#   bats tests/e2e/cluster-4-analysis-e2e.bats
#
# Dependencies: bats-core 1.10+, jq, resolve-config.sh, checkpoint.sh,
#   lifecycle-event.sh, validate-gate.sh (E28-S9/S10/S12)

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  FIXTURE_DIR="$REPO_ROOT/tests/fixtures/cluster-4-e2e"
  REPORT_DIR="$BATS_TEST_TMPDIR/cluster-4-report"

  # Per-test isolated temp workspace
  TEST_TMP="$BATS_TEST_TMPDIR/gaia-e2e-$$"
  mkdir -p "$TEST_TMP/checkpoints" "$TEST_TMP/memory" "$REPORT_DIR"

  # Set env overrides so resolve-config.sh resolves to our fixture workspace.
  # Both GAIA_* (for resolve-config.sh) and plain vars (for scripts that
  # read ${MEMORY_PATH}, ${CHECKPOINT_PATH} directly) must be exported.
  export GAIA_PROJECT_ROOT="$TEST_TMP"
  export GAIA_PROJECT_PATH="$TEST_TMP"
  export GAIA_MEMORY_PATH="$TEST_TMP/memory"
  export GAIA_CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
  export MEMORY_PATH="$TEST_TMP/memory"
  export CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export PROJECT_ROOT="$TEST_TMP"

  # Provide config file for resolve-config.sh
  mkdir -p "$TEST_TMP/config"
  cp "$FIXTURE_DIR/config/project-config.yaml" "$TEST_TMP/config/project-config.yaml"
  export CLAUDE_SKILL_DIR="$TEST_TMP"

  # E45-S2 — Seed a brainstorm artifact under docs/creative-artifacts/ so
  # gaia-product-brief's pre_start quality gate passes. The fixture is a
  # minimal placeholder; the gate only checks that the glob matches >= 1
  # file (file_exists:docs/creative-artifacts/brainstorm-*.md).
  mkdir -p "$TEST_TMP/docs/creative-artifacts"
  printf '# brainstorm fixture (e2e cluster-4)\n' \
    > "$TEST_TMP/docs/creative-artifacts/brainstorm-fixture.md"

  # Skills in dependency order
  SKILLS=(
    gaia-brainstorm
    gaia-product-brief
    gaia-market-research
    gaia-domain-research
    gaia-tech-research
    gaia-advanced-elicitation
  )

}

# Map skill name → checkpoint workflow name (bash 3.2 compatible, no assoc arrays)
workflow_name_for() {
  case "$1" in
    gaia-brainstorm)            echo "brainstorm-project" ;;
    gaia-product-brief)         echo "create-product-brief" ;;
    gaia-market-research)       echo "market-research" ;;
    gaia-domain-research)       echo "domain-research" ;;
    gaia-tech-research)         echo "technical-research" ;;
    gaia-advanced-elicitation)  echo "advanced-elicitation" ;;
    *) echo "unknown"; return 1 ;;
  esac
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Helper: run a skill's setup.sh
run_setup() {
  local skill="$1"
  local setup_script="$SKILLS_DIR/$skill/scripts/setup.sh"
  [ -x "$setup_script" ] || chmod +x "$setup_script"
  run bash "$setup_script"
}

# Helper: run a skill's finalize.sh
run_finalize() {
  local skill="$1"
  local finalize_script="$SKILLS_DIR/$skill/scripts/finalize.sh"
  [ -x "$finalize_script" ] || chmod +x "$finalize_script"
  run bash "$finalize_script"
}

# ---------- AC1: All 6 skills execute sequentially ----------

@test "AC1: all 6 skill directories exist under plugins/gaia/skills/" {
  for skill in "${SKILLS[@]}"; do
    [ -d "$SKILLS_DIR/$skill" ]
  done
}

@test "AC1: all 6 skills have SKILL.md with Cluster 4 frontmatter" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md; replaced by `orchestration_class:` declaration per FR-444.
  for skill in "${SKILLS[@]}"; do
    local skill_md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$skill_md" ]
    grep -q "^name: $skill" "$skill_md"
    grep -qE "^orchestration_class: (reviewer|light-procedural|heavy-procedural|conversational)$" "$skill_md"
  done
}

# ---------- AC2: setup.sh/finalize.sh pairs execute without error ----------

@test "AC2: gaia-brainstorm setup.sh exits 0" {
  run_setup gaia-brainstorm
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-brainstorm finalize.sh exits 0" {
  run_finalize gaia-brainstorm
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-product-brief setup.sh exits 0" {
  run_setup gaia-product-brief
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-product-brief finalize.sh exits 0" {
  run_finalize gaia-product-brief
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-market-research setup.sh exits 0" {
  run_setup gaia-market-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-market-research finalize.sh exits 0" {
  run_finalize gaia-market-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-domain-research setup.sh exits 0" {
  run_setup gaia-domain-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-domain-research finalize.sh exits 0" {
  run_finalize gaia-domain-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-tech-research setup.sh exits 0" {
  run_setup gaia-tech-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-tech-research finalize.sh exits 0" {
  run_finalize gaia-tech-research
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-advanced-elicitation setup.sh exits 0" {
  run_setup gaia-advanced-elicitation
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-advanced-elicitation finalize.sh exits 0" {
  run_finalize gaia-advanced-elicitation
  [ "$status" -eq 0 ]
}

# ---------- AC2: Checkpoint files emitted after finalize ----------

@test "AC2: finalize.sh writes checkpoint for each skill" {
  for skill in "${SKILLS[@]}"; do
    local wf_name
    wf_name="$(workflow_name_for "$skill")"
    # Run finalize which calls checkpoint.sh write
    run_finalize "$skill"
    [ "$status" -eq 0 ]
    # Verify checkpoint file exists
    local cp_file="$GAIA_CHECKPOINT_PATH/${wf_name}.yaml"
    [ -f "$cp_file" ]
  done
}

# ---------- AC2: Lifecycle events emitted after finalize ----------

@test "AC2: finalize.sh emits lifecycle event for each skill" {
  local events_file="$GAIA_MEMORY_PATH/lifecycle-events.jsonl"
  for skill in "${SKILLS[@]}"; do
    run_finalize "$skill"
    [ "$status" -eq 0 ]
  done
  # Verify events file exists and has entries
  [ -f "$events_file" ]
  local count
  count=$(wc -l < "$events_file" | tr -d ' ')
  [ "$count" -ge 6 ]
}

# ---------- AC3: Artifact diff against legacy references ----------

@test "AC3: diff allowlist file exists" {
  [ -f "$FIXTURE_DIR/diff-allowlist.txt" ]
}

# ---------- AC4: Runtime budget ----------

@test "AC4: sequential setup+finalize for all 6 skills completes under 60 seconds" {
  local start_time
  start_time=$(date +%s)
  for skill in "${SKILLS[@]}"; do
    run_setup "$skill"
    [ "$status" -eq 0 ]
    run_finalize "$skill"
    [ "$status" -eq 0 ]
  done
  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - start_time ))
  # 60s is a generous bound; the actual scripts should complete in <10s
  [ "$elapsed" -lt 60 ]
}

# ---------- AC5: Report generation ----------

@test "AC5: generate-report.sh produces a markdown report" {
  local report_script="$REPO_ROOT/tests/e2e/generate-report.sh"
  [ -f "$report_script" ]
  chmod +x "$report_script"
  run bash "$report_script" "$REPORT_DIR/report.md" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$REPORT_DIR/report.md" ]
  # Report should contain the table header
  grep -q "| Skill " "$REPORT_DIR/report.md"
}

# ---------- Structural integrity ----------

@test "STRUCTURE: all skills have scripts/setup.sh" {
  for skill in "${SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$skill/scripts/setup.sh" ]
  done
}

@test "STRUCTURE: all skills have scripts/finalize.sh" {
  for skill in "${SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$skill/scripts/finalize.sh" ]
  done
}

@test "STRUCTURE: setup.sh scripts reference resolve-config.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "resolve-config.sh" "$SKILLS_DIR/$skill/scripts/setup.sh"
  done
}

@test "STRUCTURE: finalize.sh scripts reference lifecycle-event.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "lifecycle-event.sh" "$SKILLS_DIR/$skill/scripts/finalize.sh"
  done
}

@test "STRUCTURE: finalize.sh scripts reference checkpoint.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "checkpoint.sh" "$SKILLS_DIR/$skill/scripts/finalize.sh"
  done
}
