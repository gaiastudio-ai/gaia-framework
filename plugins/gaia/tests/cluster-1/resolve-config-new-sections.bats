#!/usr/bin/env bats
# resolve-config-new-sections.bats — E68-S1 / FR-RSV2-5..22
#
# Verifies that resolve-config.sh resolves the eleven new top-level sections
# introduced by E68-S1 via --field, --all, and --format json modes:
#   compliance, tools, test_execution, severity, gates, stacks,
#   cross_service_tests, environments, ci_platform, platforms, device_targets.
#
# Mirrors the cluster-1 fixture pattern (synthetic configs in TEST_TMP/skill,
# CLAUDE_SKILL_DIR-driven discovery; the real repo configs are not touched).

load 'test_helper.bash'

setup() { common_setup; SCRIPT="$SCRIPTS_DIR/resolve-config.sh"; }
teardown() { common_teardown; }

mk_required_fields() {
  cat <<'YAML'
project_root: /tmp/gaia-e68
project_path: /tmp/gaia-e68/app
memory_path: /tmp/gaia-e68/_memory
checkpoint_path: /tmp/gaia-e68/_memory/checkpoints
installed_path: /tmp/gaia-e68/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
YAML
}

mk_shared_with_new_sections() {
  local dir="$1"
  mkdir -p "$dir/config"
  {
    mk_required_fields
    cat <<'YAML'
compliance:
  regimes: [gdpr, hipaa]
  ui_present: true
tools:
  sast:
    provider: semgrep
  secrets:
    provider: gitleaks
test_execution:
  tier_1:
    placement: local
  tier_2:
    placement: ci-pre-merge
  tier_3:
    placement: ci-post-merge
severity:
  Critical: BLOCKED
  High: REQUEST_CHANGES
  Medium: REQUEST_CHANGES
  Low: APPROVE
  Info: APPROVE
gates:
  code:
    severity:
      Medium: APPROVE
stacks:
  - name: auth
    language: typescript
    paths: ["services/auth/**"]
  - name: api
    language: python
    paths: ["services/api/**"]
cross_service_tests:
  contract_dir: tests/contract
environments:
  staging:
    url: https://staging.example.com
    credentials:
      db_password: DB_PASSWORD_VAR
ci_platform:
  provider: github-actions
platforms: [web, ios]
device_targets:
  ios:
    - "iPhone 15"
YAML
  } > "$dir/config/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC9 — --field mode resolves dotted paths into the new sections
# ---------------------------------------------------------------------------

@test "E68-S1: --field compliance.regimes returns the regimes list" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field compliance.regimes
  [ "$status" -eq 0 ]
  [[ "$output" == *"gdpr"* ]]
  [[ "$output" == *"hipaa"* ]]
}

@test "E68-S1: --field test_execution.tier_1.placement returns 'local'" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field test_execution.tier_1.placement
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

@test "E68-S1: --field tools.sast.provider returns 'semgrep'" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field tools.sast.provider
  [ "$status" -eq 0 ]
  [ "$output" = "semgrep" ]
}

@test "E68-S1: --field tools.secrets.provider returns 'gitleaks'" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field tools.secrets.provider
  [ "$status" -eq 0 ]
  [ "$output" = "gitleaks" ]
}

@test "E68-S1: --field ci_platform.provider returns 'github-actions'" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field ci_platform.provider
  [ "$status" -eq 0 ]
  [ "$output" = "github-actions" ]
}

@test "E68-S1: --field platforms returns the platform list" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field platforms
  [ "$status" -eq 0 ]
  [[ "$output" == *"web"* ]]
  [[ "$output" == *"ios"* ]]
}

@test "E68-S1: --field on unknown new-section path exits 2" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field compliance.bogus_key
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC9 — --all mode emits new sections in the flat-key surface
# ---------------------------------------------------------------------------

@test "E68-S1: --all emits compliance.regimes flattened key" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"compliance.regimes="* ]]
  [[ "$output" == *"tools.sast.provider="* ]]
  [[ "$output" == *"test_execution.tier_1.placement="* ]]
  [[ "$output" == *"ci_platform.provider="* ]]
}

@test "E68-S1: --all preserves existing flat keys when new sections present" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root="* ]]
  [[ "$output" == *"framework_version="* ]]
  [[ "$output" == *"dev_story.tdd_review.threshold="* ]]
}

# ---------------------------------------------------------------------------
# AC9 — --format json includes new sections in JSON output
# ---------------------------------------------------------------------------

@test "E68-S1: --format json includes compliance.regimes" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"compliance"* ]]
  [[ "$output" == *"gdpr"* ]]
}

@test "E68-S1: --format json includes ci_platform and platforms" {
  mk_shared_with_new_sections "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci_platform"* ]]
  [[ "$output" == *"platforms"* ]]
}

# ---------------------------------------------------------------------------
# AC1 — Eleven new top-level sections declared in template (commented out)
# ---------------------------------------------------------------------------

@test "E68-S1: project-config.yaml template declares all eleven new sections (commented)" {
  TEMPLATE="$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.yaml"
  [ -f "$TEMPLATE" ]
  for section in compliance tools test_execution severity gates stacks \
                 cross_service_tests environments ci_platform platforms device_targets; do
    grep -qE "^# ${section}:" "$TEMPLATE" || { echo "missing: ${section}"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# AC1 — schema.yaml declares new top-level keys (so resolver accepts them)
# ---------------------------------------------------------------------------

@test "E68-S1: project-config.schema.yaml declares all eleven new top-level keys" {
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../../config" && pwd)/project-config.schema.yaml"
  [ -f "$SCHEMA" ]
  for key in compliance tools test_execution severity gates stacks \
             cross_service_tests environments ci_platform platforms device_targets; do
    grep -qE "^  ${key}:" "$SCHEMA" || { echo "schema missing: ${key}"; return 1; }
  done
}
