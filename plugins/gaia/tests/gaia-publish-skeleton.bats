#!/usr/bin/env bats
# gaia-publish-skeleton.bats — E100-S1 (FR-525, ADR-113, TC-GPO-1/4)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  SKILL="$PLUGIN_DIR/skills/gaia-publish/SKILL.md"
  ORCH="$PLUGIN_DIR/skills/gaia-publish/scripts/gaia-publish.sh"
  PROJECT_ROOT="$TEST_TMP/project"
  CONFIG="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  mkdir -p "$(dirname "$CONFIG")" "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
}

teardown() { common_teardown; }

_write_config() {
  cat > "$CONFIG" <<YAML
distribution:
  channel: ${1:-claude-marketplace}
  registry: ${2:-https://anthropic.com/marketplace}
  manifest: ${3:-plugin.json}
  release_workflow: ${4:-gaia-release.yml}
YAML
}

_write_plugin_json() {
  local version="${1:-1.0.0}"
  printf '{"version":"%s","name":"example"}\n' "$version" > "$PROJECT_ROOT/plugin.json"
}

# ---------- AC1: skill scaffold + script ----------

@test "AC1: SKILL.md exists at canonical path" {
  [ -f "$SKILL" ]
}

@test "AC1: orchestrator script exists + executable" {
  [ -x "$ORCH" ]
}

@test "AC1: SKILL.md frontmatter name is gaia-publish" {
  grep -q '^name: gaia-publish$' "$SKILL"
}

# ---------- AC3: argument parsing ----------

@test "AC3: missing --version fails with usage error (exit 2)" {
  _write_config
  _write_plugin_json
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi 'usage'
}

@test "AC3: unknown flag rejected with usage error" {
  _write_config
  _write_plugin_json
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'unknown flag'
}

@test "AC3: --version= form accepted" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version=1.0.0
  [ "$status" -eq 0 ]
}

# ---------- AC2 / TC-GPO-1: happy path five-step flow ----------

@test "TC-GPO-1: happy-path five steps PASSED with documented markers" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 1/5 (pre-publish-gate): PASSED'
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): PASSED'
  echo "$output" | grep -q 'step 3/5 (trigger-publish): PASSED'
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): PASSED'
  echo "$output" | grep -q 'step 5/5 (final-verdict): PASSED'
}

@test "TC-GPO-1: assessment doc written + names channel + verdict PASSED" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-claude-marketplace-*.md' | head -1)
  [ -n "$doc" ]
  [ -f "$doc" ]
  grep -qF '**Verdict:** PASSED' "$doc"
  grep -q 'Channel:.*claude-marketplace' "$doc"
}

# ---------- AC2 step 2: manifest version mismatch fails ----------

@test "manifest version mismatch → step 2 FAILED → verdict FAILED" {
  _write_config
  _write_plugin_json 2.0.0   # manifest says 2.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0   # asking for 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): FAILED'
  echo "$output" | grep -q 'does not match'
}

@test "leading v on --version is normalized for comparison" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version v1.0.0
  [ "$status" -eq 0 ]
}

# ---------- AC3 / TC-GPO-4: --dry-run ----------

@test "TC-GPO-4: --dry-run exits 0 with steps 4-5 SKIPPED + dry-run marker" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 3/5 (trigger-publish): PASSED'
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): SKIPPED'
  echo "$output" | grep -q 'dry-run mode'
  echo "$output" | grep -q 'step 5/5 (final-verdict): SKIPPED'
}

@test "TC-GPO-4: --dry-run records the dry-run in the assessment doc" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --dry-run
  [ "$status" -eq 0 ]
  local doc
  doc=$(find "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts" -name 'assessment-publish-*' | head -1)
  [ -f "$doc" ]
  grep -q 'Dry-run:.*yes' "$doc"
}

# ---------- AC3: --skip-verify ----------

@test "--skip-verify SKIPs step 4 with WARNING + still PASSED verdict (operator opt-out)" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0 --skip-verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'step 4/5 (post-publish-verify): SKIPPED'
  echo "$output" | grep -qE 'WARNING|skip-verify'
  echo "$output" | grep -q 'step 5/5 (final-verdict): PASSED'
}

# ---------- AC4: config resolution ----------

@test "AC4: missing project-config.yaml fails with clear error" {
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'project-config.yaml not found'
}

@test "AC4: missing distribution.channel fails with clear error" {
  cat > "$CONFIG" <<'YAML'
project_name: example
YAML
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'distribution.channel not set'
}

# ---------- AC5: per-step progress markers consistent ----------

@test "AC5: 5 distinct step markers emitted in canonical order" {
  _write_config
  _write_plugin_json 1.0.0
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 0 ]
  local markers
  markers=$(printf '%s\n' "$output" | grep -c '^\[gaia-publish\] step [1-5]/5')
  [ "$markers" = "5" ]
  # Confirm canonical order via the step-number sequence
  local order
  order=$(printf '%s\n' "$output" | grep -oE 'step [1-5]/5' | sed -E 's|step ([1-5])/5|\1|' | tr -d '\n')
  [ "$order" = "12345" ]
}

# ---------- AC5: SKILL.md cites the five-step canonical order ----------

@test "AC5: SKILL.md cites the five steps in canonical order" {
  grep -q 'Step 1.*[Pp]re-publish gate' "$SKILL"
  grep -q 'Step 2.*[Mm]anifest version check' "$SKILL"
  grep -q 'Step 3.*[Tt]rigger publish' "$SKILL"
  grep -q 'Step 4.*[Pp]ost-publish verify' "$SKILL"
  grep -q 'Step 5.*[Ff]inal verdict' "$SKILL"
}

# ---------- Edge: missing manifest file ----------

@test "missing manifest file → step 2 FAILED → verdict FAILED" {
  _write_config
  # No plugin.json written
  run env CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" bash "$ORCH" --version 1.0.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'step 2/5 (manifest-version-check): FAILED'
  echo "$output" | grep -q 'manifest file not found'
}
