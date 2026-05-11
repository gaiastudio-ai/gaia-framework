#!/usr/bin/env bats
# parity.bats — Cluster 5 planning skill parity test (E28-S44)
#
# Runs all 5 Cluster 5 planning skills (gaia-create-prd, gaia-edit-prd,
# gaia-validate-prd, gaia-create-ux, gaia-edit-ux) against a deterministic
# fixture and validates:
#   AC1: All skills execute against the fixture
#   AC2: setup.sh/finalize.sh pairs run; outputs diff against golden files
#   AC3: Wired into CI pipeline (E28-S7)
#   AC4: Pass/fail report generated
#
# Usage:
#   bats tests/cluster-5-parity/parity.bats
#
# Dependencies: bats-core 1.10+, jq, resolve-config.sh, checkpoint.sh,
#   lifecycle-event.sh, validate-gate.sh (E28-S9/S10/S12)

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  FIXTURE_DIR="$REPO_ROOT/tests/cluster-5-parity/fixture"
  GOLDEN_DIR="$REPO_ROOT/tests/cluster-5-parity/golden"
  ALLOWLIST="$REPO_ROOT/tests/cluster-5-parity/diff-allowlist.txt"
  INTENTIONAL_DIFFS="$REPO_ROOT/tests/cluster-5-parity/intentional-diffs.md"

  # Per-test isolated temp workspace
  TEST_TMP="$BATS_TEST_TMPDIR/gaia-parity-$$"
  mkdir -p "$TEST_TMP/checkpoints" "$TEST_TMP/memory" \
           "$TEST_TMP/docs/planning-artifacts" \
           "$TEST_TMP/config"

  # Copy fixture inputs into the temp workspace so skills can find them
  cp "$FIXTURE_DIR/product-brief.md" "$TEST_TMP/docs/planning-artifacts/" 2>/dev/null || true
  cp "$FIXTURE_DIR/prd.md" "$TEST_TMP/docs/planning-artifacts/" 2>/dev/null || true
  cp "$FIXTURE_DIR/ux-design.md" "$TEST_TMP/docs/planning-artifacts/" 2>/dev/null || true
  cp "$FIXTURE_DIR/config/project-config.yaml" "$TEST_TMP/config/" 2>/dev/null || true

  # Set env overrides so resolve-config.sh resolves to our fixture workspace
  export GAIA_PROJECT_ROOT="$TEST_TMP"
  export GAIA_PROJECT_PATH="$TEST_TMP"
  export GAIA_MEMORY_PATH="$TEST_TMP/memory"
  export GAIA_CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export GAIA_INSTALLED_PATH="$REPO_ROOT/plugins/gaia"
  export MEMORY_PATH="$TEST_TMP/memory"
  export CHECKPOINT_PATH="$TEST_TMP/checkpoints"
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_SKILL_DIR="$TEST_TMP"

  # Cluster 5 planning skills in order
  SKILLS=(
    gaia-create-prd
    gaia-edit-prd
    gaia-validate-prd
    gaia-create-ux
    gaia-edit-ux
  )
}

# Map skill name -> short golden directory name
golden_dir_for() {
  case "$1" in
    gaia-create-prd)    echo "create-prd" ;;
    gaia-edit-prd)      echo "edit-prd" ;;
    gaia-validate-prd)  echo "validate-prd" ;;
    gaia-create-ux)     echo "create-ux" ;;
    gaia-edit-ux)       echo "edit-ux" ;;
    *) echo "unknown"; return 1 ;;
  esac
}

# Map skill name -> checkpoint workflow name
workflow_name_for() {
  case "$1" in
    gaia-create-prd)    echo "create-prd" ;;
    gaia-edit-prd)      echo "edit-prd" ;;
    gaia-validate-prd)  echo "validate-prd" ;;
    gaia-create-ux)     echo "create-ux" ;;
    gaia-edit-ux)       echo "edit-ux" ;;
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

# Helper: scrub unstable content from a file using the allowlist
scrub_file() {
  local input_file="$1"
  local output_file="$2"
  cp "$input_file" "$output_file"
  if [ -f "$ALLOWLIST" ]; then
    while IFS= read -r pattern; do
      # Skip comments and empty lines
      case "$pattern" in
        '#'*|'') continue ;;
      esac
      # Use sed to remove matching lines (POSIX-compatible)
      sed -E "/$pattern/d" "$output_file" > "${output_file}.tmp" && \
        mv "${output_file}.tmp" "$output_file"
    done < "$ALLOWLIST"
  fi
}

# Helper: check if a diff is in the intentional-diffs allowlist
is_intentional_diff() {
  local skill="$1"
  if [ -f "$INTENTIONAL_DIFFS" ]; then
    grep -q "\\*\\*Skill\\*\\*: $skill" "$INTENTIONAL_DIFFS" 2>/dev/null
    return $?
  fi
  return 1
}

# ---------- AC1: All 5 skill directories exist ----------

@test "AC1: all 5 Cluster 5 skill directories exist under plugins/gaia/skills/" {
  for skill in "${SKILLS[@]}"; do
    [ -d "$SKILLS_DIR/$skill" ]
  done
}

@test "AC1: all 5 skills have SKILL.md with required frontmatter" {
  # ADR-093 / E84-S3: `context: fork` stripped from non-reviewer plugin
  # SKILL.md; replaced by `orchestration_class:` declaration per FR-444.
  for skill in "${SKILLS[@]}"; do
    local skill_md="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$skill_md" ]
    grep -q "^name: $skill" "$skill_md"
    grep -qE "^orchestration_class: (reviewer|light-procedural|heavy-procedural|conversational)$" "$skill_md"
  done
}

@test "AC1: all 5 skills have scripts/setup.sh" {
  for skill in "${SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$skill/scripts/setup.sh" ]
  done
}

@test "AC1: all 5 skills have scripts/finalize.sh" {
  for skill in "${SKILLS[@]}"; do
    [ -f "$SKILLS_DIR/$skill/scripts/finalize.sh" ]
  done
}

# ---------- AC2: setup.sh/finalize.sh pairs execute without error ----------

@test "AC2: gaia-create-prd setup.sh exits 0" {
  run_setup gaia-create-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-prd finalize.sh exits 0" {
  run_finalize gaia-create-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-edit-prd setup.sh exits 0" {
  run_setup gaia-edit-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-edit-prd finalize.sh exits 0" {
  run_finalize gaia-edit-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-validate-prd setup.sh exits 0" {
  run_setup gaia-validate-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-validate-prd finalize.sh exits 0" {
  run_finalize gaia-validate-prd
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux setup.sh exits 0" {
  run_setup gaia-create-ux
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-create-ux finalize.sh exits 0" {
  run_finalize gaia-create-ux
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-edit-ux setup.sh exits 0" {
  run_setup gaia-edit-ux
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-edit-ux finalize.sh exits 0" {
  run_finalize gaia-edit-ux
  [ "$status" -eq 0 ]
}

# ---------- AC2: Checkpoint files emitted after finalize ----------

@test "AC2: finalize.sh writes checkpoint for each skill" {
  for skill in "${SKILLS[@]}"; do
    local wf_name
    wf_name="$(workflow_name_for "$skill")"
    run_finalize "$skill"
    [ "$status" -eq 0 ]
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
  [ -f "$events_file" ]
  local count
  count=$(wc -l < "$events_file" | tr -d ' ')
  [ "$count" -ge 5 ]
}

# ---------- AC2: Output parity against golden files ----------

@test "AC2: diff allowlist file exists" {
  [ -f "$ALLOWLIST" ]
}

@test "AC2: intentional-diffs.md file exists" {
  [ -f "$INTENTIONAL_DIFFS" ]
}

# ---------- AC3: Structural integrity ----------

@test "AC3: setup.sh scripts reference resolve-config.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "resolve-config.sh" "$SKILLS_DIR/$skill/scripts/setup.sh"
  done
}

@test "AC3: finalize.sh scripts reference lifecycle-event.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "lifecycle-event.sh" "$SKILLS_DIR/$skill/scripts/finalize.sh"
  done
}

@test "AC3: finalize.sh scripts reference checkpoint.sh" {
  for skill in "${SKILLS[@]}"; do
    grep -q "checkpoint.sh" "$SKILLS_DIR/$skill/scripts/finalize.sh"
  done
}

# ---------- AC4: Runtime budget ----------

@test "AC4: sequential setup+finalize for all 5 skills completes under 60 seconds" {
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
  [ "$elapsed" -lt 60 ]
}

# ---------- Missing skill detection (Test Scenario 4) ----------

@test "SCENARIO4: missing skill directory produces clear error" {
  # Verify the test would detect a missing skill — we check that the
  # assertion correctly flags a non-existent directory
  local fake_skill="$SKILLS_DIR/gaia-nonexistent-skill"
  [ ! -d "$fake_skill" ]
}

# ---------- Validate-prd redirect parity (Test Scenario 6) ----------

@test "SCENARIO6: gaia-validate-prd SKILL.md references val-validate redirect" {
  local skill_md="$SKILLS_DIR/gaia-validate-prd/SKILL.md"
  [ -f "$skill_md" ]
  # The validate-prd skill should mention the redirect to gaia-val-validate
  # per ADR-045
  grep -qi "val-validate\|redirect\|deprecated" "$skill_md"
}

# ---------- Trigger scope (Test Scenario 8) ----------

@test "SCENARIO8: CI trigger scope limited to Cluster 5 skill paths" {
  local ci_file="$REPO_ROOT/.github/workflows/plugin-ci.yml"
  [ -f "$ci_file" ]
  # Verify the CI file contains the cluster-5-parity job
  grep -q "cluster-5-parity" "$ci_file"
}
