#!/usr/bin/env bats
# skill-rename-preflight.bats — coverage for the skill-rename pre-flight
# checklist helper that scans five surfaces for stale references after a
# skill directory or test file is renamed.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Resolve the script under test (lives in gaia-dev-story/scripts/)
# ---------------------------------------------------------------------------
PREFLIGHT_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/skill-rename-preflight.sh"

setup() {
  common_setup

  # --- Build a fixture tree mimicking the five surfaces ----

  # 1. .github/workflows/ with a hardcoded bats invocation list
  mkdir -p "$TEST_TMP/.github/workflows"
  cat > "$TEST_TMP/.github/workflows/plugin-ci.yml" <<'YAML'
jobs:
  skills-bats-tests:
    steps:
      - run: |
          bats tests/skills/gaia-post-deploy.bats
          bats tests/skills/gaia-deploy-checklist.bats
          bats tests/skills/gaia-sprint-close.bats
YAML

  # 2. knowledge CSVs and lifecycle-sequence.yaml
  mkdir -p "$TEST_TMP/plugins/gaia/knowledge"
  cat > "$TEST_TMP/plugins/gaia/knowledge/workflow-manifest.csv" <<'CSV'
name,displayName,description
"gaia-post-deploy","Post Deploy","Run post-deployment checks"
"gaia-sprint-close","Sprint Close","Close the sprint"
CSV
  cat > "$TEST_TMP/plugins/gaia/knowledge/gaia-help.csv" <<'CSV'
module,phase,name,code,command
"core","deploy","post-deploy","post-deploy","gaia-post-deploy"
"core","sprint","sprint-close","sprint-close","gaia-sprint-close"
CSV
  cat > "$TEST_TMP/plugins/gaia/knowledge/lifecycle-sequence.yaml" <<'YAML'
sequence:
  - name: gaia-post-deploy
    phase: deploy
  - name: gaia-sprint-close
    phase: sprint
YAML

  # 3. tests/skills/ directory (repo-root level)
  mkdir -p "$TEST_TMP/tests/skills"
  touch "$TEST_TMP/tests/skills/gaia-post-deploy.bats"

  # 4. plugins/gaia/tests/ directory
  mkdir -p "$TEST_TMP/plugins/gaia/tests"
  touch "$TEST_TMP/plugins/gaia/tests/gaia-post-deploy.bats"

  # 5. The NEW skill's SKILL.md with a legacy _gaia/lifecycle/ path
  mkdir -p "$TEST_TMP/plugins/gaia/skills/gaia-deploy-post"
  cat > "$TEST_TMP/plugins/gaia/skills/gaia-deploy-post/SKILL.md" <<'MD'
# gaia-deploy-post

Post-deployment verification skill.

Path: _gaia/lifecycle/templates/post-deploy.yaml
MD
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Script exists and is executable
# ---------------------------------------------------------------------------

@test "skill rename preflight: script exists and is executable" {
  [ -f "$PREFLIGHT_SCRIPT" ]
  [ -x "$PREFLIGHT_SCRIPT" ]
}

# ---------------------------------------------------------------------------
# Accepts --old / --new and exits 0 (advisory, non-blocking)
# ---------------------------------------------------------------------------

@test "skill rename preflight: exits 0 with valid args" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
}

@test "skill rename preflight: exits 0 even when hits are found" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  # Output should contain at least one hit
  [[ "$output" == *"gaia-post-deploy"* ]]
}

# ---------------------------------------------------------------------------
# Surface 1: .github/workflows/ hardcoded bats invocation lists
# ---------------------------------------------------------------------------

@test "skill rename preflight: detects old name in workflow bats list" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin-ci.yml"* ]]
  [[ "$output" == *"gaia-post-deploy"* ]]
}

# ---------------------------------------------------------------------------
# Surface 2: knowledge CSVs + lifecycle YAML
# ---------------------------------------------------------------------------

@test "skill rename preflight: detects old name in workflow-manifest.csv" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow-manifest.csv"* ]]
}

@test "skill rename preflight: detects old name in gaia-help.csv" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gaia-help.csv"* ]]
}

@test "skill rename preflight: detects old name in lifecycle-sequence.yaml" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lifecycle-sequence.yaml"* ]]
}

# ---------------------------------------------------------------------------
# Surface 3: test directories (both locations)
# ---------------------------------------------------------------------------

@test "skill rename preflight: detects old name in tests/skills/ directory" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/skills/"* ]]
  [[ "$output" == *"gaia-post-deploy"* ]]
}

@test "skill rename preflight: detects old name in plugins/gaia/tests/ directory" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugins/gaia/tests/"* ]]
}

# ---------------------------------------------------------------------------
# Surface 4: legacy _gaia/lifecycle/ path in the renamed SKILL.md
# ---------------------------------------------------------------------------

@test "skill rename preflight: flags legacy lifecycle path in new SKILL.md" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-post-deploy --new gaia-deploy-post \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_gaia/lifecycle/"* ]]
  [[ "$output" == *"SKILL.md"* ]]
}

# ---------------------------------------------------------------------------
# Clean surface: no false positives for names not present
# ---------------------------------------------------------------------------

@test "skill rename preflight: reports clean when no hits found" {
  run bash "$PREFLIGHT_SCRIPT" --old gaia-nonexistent-skill --new gaia-also-nonexistent \
    --repo-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

# ---------------------------------------------------------------------------
# Main-guard: script is sourceable without running main
# ---------------------------------------------------------------------------

@test "skill rename preflight: sourceable without executing main" {
  # Source the script in a subshell — it must NOT produce output or exit
  run bash -c "source '$PREFLIGHT_SCRIPT' && echo 'sourced-ok'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

# ---------------------------------------------------------------------------
# Public function coverage (satisfies the public-function-coverage gate):
# source the script and call the scan_workflows function directly.
# ---------------------------------------------------------------------------

@test "skill rename preflight: scan_workflows function is callable when sourced" {
  run bash -c "
    source '$PREFLIGHT_SCRIPT'
    scan_workflows '$TEST_TMP' 'gaia-post-deploy'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin-ci.yml"* ]]
}

@test "skill rename preflight: scan_knowledge function is callable when sourced" {
  run bash -c "
    source '$PREFLIGHT_SCRIPT'
    scan_knowledge '$TEST_TMP' 'gaia-post-deploy'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow-manifest.csv"* ]]
}

@test "skill rename preflight: scan_test_dirs function is callable when sourced" {
  run bash -c "
    source '$PREFLIGHT_SCRIPT'
    scan_test_dirs '$TEST_TMP' 'gaia-post-deploy'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/skills/"* ]]
}

@test "skill rename preflight: scan_legacy_paths function is callable when sourced" {
  run bash -c "
    source '$PREFLIGHT_SCRIPT'
    scan_legacy_paths '$TEST_TMP' 'gaia-deploy-post'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"_gaia/lifecycle/"* ]]
}
