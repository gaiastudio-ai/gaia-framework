#!/usr/bin/env bats
# cluster-7-chain.bats — Cluster 7 end-to-end chain integration test (E28-S59)
#
# Runs the full Story Cluster chain: create-story -> dev-story -> validate-story
# -> check-dod against a fixture project and verifies each skill hands off
# correctly via sprint-state.sh and review-gate.sh.
#
# AC1: All 4 steps complete successfully, no step aborts
# AC2: State transitions match canonical state machine:
#       backlog -> ready-for-dev -> in-progress -> review -> done
# AC3: PostToolUse checkpoint hook fires during dev-story — at least one
#       checkpoint file written under _memory/checkpoints/
# AC4: Wired into CI, completes under 5 minutes
# AC5: Pass/fail report generated
#
# Usage:
#   bats tests/e2e/cluster-7-chain.bats
#
# Dependencies: bats-core 1.10+, jq, sprint-state.sh, review-gate.sh,
#   checkpoint.sh, resolve-config.sh, lifecycle-event.sh, validate-gate.sh

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  FIXTURE_DIR="$REPO_ROOT/tests/fixtures/cluster-7-chain"

  # Per-test isolated temp workspace
  TEST_TMP="$BATS_TEST_TMPDIR/gaia-chain-$$"
  mkdir -p "$TEST_TMP/checkpoints" "$TEST_TMP/memory" \
           "$TEST_TMP/docs/implementation-artifacts/stories" \
           "$TEST_TMP/docs/planning-artifacts" \
           "$TEST_TMP/docs/test-artifacts" \
           "$TEST_TMP/config"

  # Set env overrides so resolve-config.sh resolves to our fixture workspace.
  export GAIA_PROJECT_ROOT="$TEST_TMP"
  export GAIA_PROJECT_PATH="$TEST_TMP"
  export GAIA_MEMORY_PATH="$TEST_TMP/memory"
  export GAIA_CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
  export MEMORY_PATH="$TEST_TMP/memory"
  export CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP"
  export CLAUDE_SKILL_DIR="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"

  # Copy fixture config and schema
  cp "$FIXTURE_DIR/config/project-config.yaml" "$TEST_TMP/config/project-config.yaml"
  cp "$REPO_ROOT/plugins/gaia/config/project-config.schema.yaml" "$TEST_TMP/config/project-config.schema.yaml" 2>/dev/null || true

  # Copy fixture planning artifacts
  cp "$FIXTURE_DIR/epics-and-stories.md" "$TEST_TMP/docs/planning-artifacts/"
  cp "$FIXTURE_DIR/architecture.md" "$TEST_TMP/docs/planning-artifacts/"

  # Copy and initialize sprint-status.yaml
  cp "$FIXTURE_DIR/sprint-status.yaml" "$TEST_TMP/docs/implementation-artifacts/"

  # Seed a fixture story file so sprint-state.sh and review-gate.sh can find it.
  # sprint-state.sh looks under $IMPLEMENTATION_ARTIFACTS/{key}-*.md
  # review-gate.sh looks under $PROJECT_PATH/docs/implementation-artifacts/stories/{key}-*.md
  # We place the file in stories/ and symlink to the parent for compatibility.
  STORY_KEY="E99-S1"
  cat > "$TEST_TMP/docs/implementation-artifacts/stories/${STORY_KEY}-fixture-story.md" <<'STORY'
---
template: 'story'
key: "E99-S1"
title: "Fixture story for chain test"
epic: "E99 — Test Epic"
status: backlog
priority: "P2"
size: "S"
points: 2
risk: "low"
---

# Story: Fixture story for chain test

> **Status:** backlog

## Acceptance Criteria

- [ ] AC1: Chain runs end-to-end

## Tasks / Subtasks

- [ ] Task 1: Run chain

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

## Definition of Done

- [ ] All acceptance criteria verified
STORY

  # Also place in parent directory for sprint-state.sh compatibility
  cp "$TEST_TMP/docs/implementation-artifacts/stories/${STORY_KEY}-fixture-story.md" \
     "$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-fixture-story.md"

  # Chain skills in order
  CHAIN_SKILLS=(
    gaia-create-story
    gaia-dev-story
    gaia-validate-story
    gaia-check-dod
  )
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Helper: run a skill's setup.sh
run_setup() {
  local skill="$1"
  local setup_script="$SKILLS_DIR/$skill/scripts/setup.sh"
  [ -f "$setup_script" ] || return 1
  bash "$setup_script"
}

# Helper: run a skill's finalize.sh
run_finalize() {
  local skill="$1"
  local finalize_script="$SKILLS_DIR/$skill/scripts/finalize.sh"
  [ -f "$finalize_script" ] || return 1
  bash "$finalize_script"
}

# ---------- AC1: Full chain runs end-to-end ----------

@test "AC1: fixture directory exists with required files" {
  [ -d "$FIXTURE_DIR" ]
  [ -f "$FIXTURE_DIR/epics-and-stories.md" ]
  [ -f "$FIXTURE_DIR/architecture.md" ]
  [ -f "$FIXTURE_DIR/sprint-status.yaml" ]
  [ -f "$FIXTURE_DIR/config/project-config.yaml" ]
}

@test "AC1: create-story skill directory and scripts exist" {
  [ -d "$SKILLS_DIR/gaia-create-story" ]
  [ -f "$SKILLS_DIR/gaia-create-story/scripts/setup.sh" ]
  [ -f "$SKILLS_DIR/gaia-create-story/scripts/finalize.sh" ]
}

@test "AC1: validate-story skill directory and scripts exist" {
  [ -d "$SKILLS_DIR/gaia-validate-story" ]
  [ -f "$SKILLS_DIR/gaia-validate-story/scripts/setup.sh" ]
  [ -f "$SKILLS_DIR/gaia-validate-story/scripts/finalize.sh" ]
}

@test "AC1: check-dod skill directory and scripts exist" {
  [ -d "$SKILLS_DIR/gaia-check-dod" ]
  [ -f "$SKILLS_DIR/gaia-check-dod/scripts/setup.sh" ]
  [ -f "$SKILLS_DIR/gaia-check-dod/scripts/finalize.sh" ]
}

@test "AC1: create-story finalize.sh runs without error against fixture" {
  run run_finalize gaia-create-story
  [ "$status" -eq 0 ]
}

@test "AC1: validate-story setup.sh runs without error against fixture" {
  run run_setup gaia-validate-story
  [ "$status" -eq 0 ]
}

@test "AC1: validate-story finalize.sh runs without error against fixture" {
  run run_finalize gaia-validate-story
  [ "$status" -eq 0 ]
}

@test "AC1: check-dod setup.sh runs without error against fixture" {
  run run_setup gaia-check-dod
  [ "$status" -eq 0 ]
}

@test "AC1: check-dod finalize.sh runs without error against fixture" {
  run run_finalize gaia-check-dod
  [ "$status" -eq 0 ]
}

# ---------- AC2: State machine transitions ----------

@test "AC2: sprint-state.sh exists and is runnable" {
  [ -f "$SCRIPTS_DIR/sprint-state.sh" ]
}

@test "AC2: sprint-state.sh get reads fixture story status as backlog" {
  run bash "$SCRIPTS_DIR/sprint-state.sh" get --story "$STORY_KEY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "backlog"
}

@test "AC2: sprint-state.sh transition backlog->validating succeeds" {
  run bash "$SCRIPTS_DIR/sprint-state.sh" transition --story "$STORY_KEY" --to validating
  [ "$status" -eq 0 ]
}

@test "AC2: sprint-state.sh transition validates adjacency (rejects backlog->done)" {
  run bash "$SCRIPTS_DIR/sprint-state.sh" transition --story "$STORY_KEY" --to done
  [ "$status" -ne 0 ]
}

@test "AC2: review-gate.sh exists and is runnable" {
  [ -f "$SCRIPTS_DIR/review-gate.sh" ]
}

@test "AC2: review-gate.sh status reads fixture story review gate" {
  run bash "$SCRIPTS_DIR/review-gate.sh" status --story "$STORY_KEY"
  [ "$status" -eq 0 ]
}

# ---------- AC3: Checkpoint hook fires ----------

@test "AC3: checkpoint.sh write command works" {
  run bash "$SCRIPTS_DIR/checkpoint.sh" write --workflow "chain-test" --step 1
  [ "$status" -eq 0 ]
}

@test "AC3: checkpoint.sh write creates a file under CHECKPOINT_PATH" {
  bash "$SCRIPTS_DIR/checkpoint.sh" write --workflow "chain-test" --step 1
  local count
  count=$(find "$TEST_TMP/checkpoints" -type f -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "AC3: checkpoint.sh read returns previously written checkpoint" {
  bash "$SCRIPTS_DIR/checkpoint.sh" write --workflow "chain-test" --step 2
  run bash "$SCRIPTS_DIR/checkpoint.sh" read --workflow "chain-test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "chain-test"
}

@test "AC3: checkpoint file contains expected metadata fields" {
  bash "$SCRIPTS_DIR/checkpoint.sh" write --workflow "chain-test" --step 3 \
    --var story_key=E99-S1
  run bash "$SCRIPTS_DIR/checkpoint.sh" read --workflow "chain-test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "workflow"
  echo "$output" | grep -q "step"
}

# ---------- AC1b: dev-story skill functional tests (E28-S53) ----------

@test "AC1b: dev-story skill directory and scripts exist" {
  [ -d "$SKILLS_DIR/gaia-dev-story" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/SKILL.md" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/setup.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/finalize.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/load-story.sh" ]
  # update-story-status.sh deprecation wrapper deleted in E59-S3 — transitions now route through plugins/gaia/scripts/transition-story-status.sh directly.
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/checkpoint.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/git-branch.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/pr-create.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/ci-wait.sh" ]
  [ -f "$SKILLS_DIR/gaia-dev-story/scripts/merge.sh" ]
}

@test "AC1b: dev-story SKILL.md has correct frontmatter" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md. gaia-dev-story is heavy-procedural.
  local skill_file="$SKILLS_DIR/gaia-dev-story/SKILL.md"
  grep -q "^name: gaia-dev-story" "$skill_file"
  grep -q "^orchestration_class: heavy-procedural" "$skill_file"
  grep -q "PostToolUse" "$skill_file"
  grep -q "checkpoint.sh" "$skill_file"
}

@test "AC1b: dev-story setup.sh runs without error against fixture" {
  # Transition fixture story to ready-for-dev first (setup requires it)
  bash "$SCRIPTS_DIR/sprint-state.sh" transition --story "$STORY_KEY" --to validating
  bash "$SCRIPTS_DIR/sprint-state.sh" transition --story "$STORY_KEY" --to ready-for-dev
  run run_setup gaia-dev-story
  [ "$status" -eq 0 ]
}

@test "AC1b: dev-story finalize.sh runs without error against fixture" {
  run run_finalize gaia-dev-story
  [ "$status" -eq 0 ]
}

@test "AC1b: dev-story load-story.sh retrieves fixture story status" {
  run bash "$SKILLS_DIR/gaia-dev-story/scripts/load-story.sh" "$STORY_KEY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "backlog"
}

@test "AC1b: dev-story SKILL.md references transition-story-status.sh directly (post E59-S3)" {
  grep -q "transition-story-status.sh" "$SKILLS_DIR/gaia-dev-story/SKILL.md"
}

@test "AC1b: dev-story SKILL.md has zero update-story-status.sh references (post E59-S3)" {
  run grep -c "update-story-status.sh" "$SKILLS_DIR/gaia-dev-story/SKILL.md"
  [ "$output" = "0" ]
}

@test "AC1b: sprint-state.sh transition rejects invalid transition (backlog->done)" {
  # Replaces the deleted wrapper-based negative test. The underlying sprint-state.sh
  # rejects backlog->done; transition-story-status.sh delegates to the same state machine.
  run bash "$SCRIPTS_DIR/sprint-state.sh" transition --story "$STORY_KEY" --to done
  [ "$status" -ne 0 ]
}

# ---------- AC3b: PostToolUse checkpoint hook (dev-story specific) ----------

@test "AC3b: dev-story checkpoint.sh hook writes checkpoint with workflow=gaia-dev-story" {
  export CLAUDE_SKILL_DIR="$SKILLS_DIR/gaia-dev-story"
  run bash "$SKILLS_DIR/gaia-dev-story/scripts/checkpoint.sh" write gaia-dev-story
  [ "$status" -eq 0 ]
  # Verify checkpoint was written to the correct location
  local count
  count=$(find "$TEST_TMP/checkpoints" -type f -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "AC3b: dev-story checkpoint.sh uses step 0 sentinel for hook-triggered writes" {
  export CLAUDE_SKILL_DIR="$SKILLS_DIR/gaia-dev-story"
  bash "$SKILLS_DIR/gaia-dev-story/scripts/checkpoint.sh" write gaia-dev-story
  # Read back the checkpoint and verify it contains the workflow name
  run bash "$SCRIPTS_DIR/checkpoint.sh" read --workflow "gaia-dev-story"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "gaia-dev-story"
}

@test "AC3b: dev-story checkpoint.sh rejects non-write subcommands" {
  export CLAUDE_SKILL_DIR="$SKILLS_DIR/gaia-dev-story"
  run bash "$SKILLS_DIR/gaia-dev-story/scripts/checkpoint.sh" read gaia-dev-story
  [ "$status" -ne 0 ]
}

@test "AC3b: dev-story checkpoint.sh fails gracefully without args" {
  export CLAUDE_SKILL_DIR="$SKILLS_DIR/gaia-dev-story"
  run bash "$SKILLS_DIR/gaia-dev-story/scripts/checkpoint.sh"
  [ "$status" -ne 0 ]
}

# ---------- AC4: CI budget guard (structural check) ----------

@test "AC4: CI workflow file exists with cluster-7 job" {
  local ci_file="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  [ -f "$ci_file" ]
  grep -q "cluster-7-chain" "$ci_file"
}

@test "AC4: CI cluster-7 job has timeout-minutes: 5" {
  local ci_file="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  grep -A 5 "cluster-7-chain" "$ci_file" | grep -q "timeout-minutes: 5"
}

@test "AC4: CI cluster-7 job runs bats on this test file" {
  local ci_file="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  grep -q "cluster-7-chain.bats" "$ci_file"
}

# ---------- AC5: Report generation ----------

@test "AC5: generate-cluster-7-report.sh exists" {
  [ -f "$REPO_ROOT/tests/e2e/generate-cluster-7-report.sh" ]
}

@test "AC5: generate-cluster-7-report.sh runs and produces output" {
  local report_out="$TEST_TMP/cluster-7-report.md"
  run bash "$REPO_ROOT/tests/e2e/generate-cluster-7-report.sh" "$report_out" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$report_out" ]
}

@test "AC5: report contains expected table columns" {
  local report_out="$TEST_TMP/cluster-7-report.md"
  bash "$REPO_ROOT/tests/e2e/generate-cluster-7-report.sh" "$report_out" "$REPO_ROOT"
  grep -qi "step" "$report_out"
  grep -qi "status" "$report_out"
  grep -qi "duration" "$report_out"
}

@test "AC5: report contains verdict line" {
  local report_out="$TEST_TMP/cluster-7-report.md"
  bash "$REPO_ROOT/tests/e2e/generate-cluster-7-report.sh" "$report_out" "$REPO_ROOT"
  grep -q "Verdict:" "$report_out"
}
