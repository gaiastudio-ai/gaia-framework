#!/usr/bin/env bats
# gaia-init.bats — unit tests for plugins/gaia/skills/gaia-init/scripts/*.sh and SKILL.md.
# Story: E71-S1 — `/gaia-init` greenfield conversational setup.
#
# Acceptance criteria coverage:
#   AC1, AC8 — SKILL.md frontmatter + registry rows
#   AC2      — generate-config.sh emits a YAML that matches expected shape
#   AC3      — mobile follow-ups populate platforms[]
#   AC4      — RETIRED (greenfield-guard.sh removed by E85-S7 / FR-460 / ADR-099;
#                       replaced by inline config_phase lookup in E85-S3)
#   AC5      — validate-platform-stack.sh
#   AC6      — generate-ci-scaffold.sh
#   AC7      — next-steps rendering instructions live in SKILL.md (presence-tested)

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-init" && pwd)"
  SKILL_SCRIPTS="$SKILL_DIR/scripts"
  KNOWLEDGE_DIR="$(cd "$BATS_TEST_DIRNAME/../knowledge" && pwd)"
}
teardown() { common_teardown; }

# --- AC8: SKILL.md frontmatter --------------------------------------------

@test "gaia-init: SKILL.md exists" {
  [ -f "$SKILL_DIR/SKILL.md" ]
}

@test "gaia-init: SKILL.md frontmatter has name=gaia-init" {
  grep -E '^name:[[:space:]]*gaia-init$' "$SKILL_DIR/SKILL.md"
}

@test "gaia-init: SKILL.md frontmatter has description" {
  grep -E '^description:[[:space:]]*\S' "$SKILL_DIR/SKILL.md"
}

@test "gaia-init: SKILL.md mentions /gaia-init trigger" {
  grep -F '/gaia-init' "$SKILL_DIR/SKILL.md"
}

@test "gaia-init: gaia-help.csv contains gaia-init row" {
  grep -F 'gaia-init' "$KNOWLEDGE_DIR/gaia-help.csv"
}

@test "gaia-init: workflow-manifest.csv contains gaia-init row" {
  grep -F 'gaia-init' "$KNOWLEDGE_DIR/workflow-manifest.csv"
}

# --- AC4 retirement guard (E85-S7 / FR-460 / ADR-099) ---------------------

@test "greenfield-guard.sh has been retired (file does not exist)" {
  [ ! -f "$SKILL_SCRIPTS/greenfield-guard.sh" ]
}

# --- AC5: validate-platform-stack.sh --------------------------------------

@test "validate-platform-stack.sh: rejects ios platform with java-only stack" {
  cat > "$TEST_TMP/cfg.yaml" <<YAML
platforms:
  - ios
stacks:
  - name: api
    language: java
    paths:
      - services/api
YAML
  run "$SKILL_SCRIPTS/validate-platform-stack.sh" "$TEST_TMP/cfg.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ios"* ]]
}

@test "validate-platform-stack.sh: accepts ios platform with swift stack" {
  cat > "$TEST_TMP/cfg.yaml" <<YAML
platforms:
  - ios
stacks:
  - name: ios-app
    language: swift
    paths:
      - apps/ios
YAML
  run "$SKILL_SCRIPTS/validate-platform-stack.sh" "$TEST_TMP/cfg.yaml"
  [ "$status" -eq 0 ]
}

@test "validate-platform-stack.sh: accepts ios platform with react-native stack" {
  cat > "$TEST_TMP/cfg.yaml" <<YAML
platforms:
  - ios
  - android
stacks:
  - name: app
    language: react-native
    paths:
      - apps/mobile
YAML
  run "$SKILL_SCRIPTS/validate-platform-stack.sh" "$TEST_TMP/cfg.yaml"
  [ "$status" -eq 0 ]
}

@test "validate-platform-stack.sh: rejects android platform without android-capable stack" {
  cat > "$TEST_TMP/cfg.yaml" <<YAML
platforms:
  - android
stacks:
  - name: api
    language: python
    paths:
      - services/api
YAML
  run "$SKILL_SCRIPTS/validate-platform-stack.sh" "$TEST_TMP/cfg.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"android"* ]]
}

@test "validate-platform-stack.sh: passes when no platforms declared" {
  cat > "$TEST_TMP/cfg.yaml" <<YAML
stacks:
  - name: api
    language: python
    paths:
      - services/api
YAML
  run "$SKILL_SCRIPTS/validate-platform-stack.sh" "$TEST_TMP/cfg.yaml"
  [ "$status" -eq 0 ]
}

# --- AC2: generate-config.sh ----------------------------------------------

@test "generate-config.sh: emits required top-level keys" {
  mkdir -p "$TEST_TMP/proj/.gaia/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "stacks": [{"name": "api", "language": "node", "paths": ["services/api"]}],
  "compliance": {"regimes": ["gdpr"], "ui_present": true},
  "environments": {"staging": {"url": "https://staging.example.com", "credentials": {"api_token": "STAGING_TOKEN"}}},
  "ci_platform": {"provider": "github-actions"}
}
JSON
  [ -s "$TEST_TMP/proj/.gaia/config/project-config.yaml" ]
  grep -F 'project_root:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  grep -F 'stacks:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  grep -F 'compliance:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  grep -F 'environments:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  grep -F 'ci_platform:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
}

@test "generate-config.sh: env credentials use env-var name only (no literal secret)" {
  mkdir -p "$TEST_TMP/proj/.gaia/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "environments": {"staging": {"url": "https://staging.example.com", "credentials": {"api_token": "STAGING_TOKEN"}}}
}
JSON
  # env-var NAME is referenced; a literal sk- secret never appears.
  grep -F 'STAGING_TOKEN' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  ! grep -E 'sk-[A-Za-z0-9]{8,}' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
}

@test "generate-config.sh: populates platforms when mobile shape" {
  mkdir -p "$TEST_TMP/proj/.gaia/config"
  cat <<JSON | "$SKILL_SCRIPTS/generate-config.sh" --path "$TEST_TMP/proj" --name demo
{
  "stacks": [{"name": "app", "language": "swift", "paths": ["apps/ios"]}],
  "platforms": ["ios"]
}
JSON
  grep -F 'platforms:' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  grep -F 'ios' "$TEST_TMP/proj/.gaia/config/project-config.yaml"
}

@test "generate-config.sh: refuses to overwrite existing config (greenfield invariant)" {
  mkdir -p "$TEST_TMP/proj/.gaia/config"
  printf 'preexisting: true\n' > "$TEST_TMP/proj/.gaia/config/project-config.yaml"
  run bash -c "echo '{}' | '$SKILL_SCRIPTS/generate-config.sh' --path '$TEST_TMP/proj' --name demo"
  [ "$status" -ne 0 ]
}

# --- AC6: generate-ci-scaffold.sh -----------------------------------------

@test "generate-ci-scaffold.sh: github-actions emits canonical workflow path" {
  mkdir -p "$TEST_TMP/proj"
  run "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider github-actions
  [ "$status" -eq 0 ]
  [ -s "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.yml" ]
  [ -s "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: workflow file has 'Generated by /gaia-init' header" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider github-actions
  grep -F 'Generated by /gaia-init' "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.yml"
}

@test "generate-ci-scaffold.sh: user-steps companion is preserved on regeneration" {
  mkdir -p "$TEST_TMP/proj/.github/workflows"
  printf '# user customizations\nsteps: [user-defined]\n' \
    > "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.user-steps.yml"
  local before
  before="$(cat "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.user-steps.yml")"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider github-actions
  local after
  after="$(cat "$TEST_TMP/proj/.github/workflows/gaia-pre-merge.user-steps.yml")"
  [ "$before" = "$after" ]
}

@test "generate-ci-scaffold.sh: gitlab-ci emits .gitlab-ci.yml + companion" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider gitlab-ci
  [ -s "$TEST_TMP/proj/.gitlab-ci.yml" ]
  [ -s "$TEST_TMP/proj/.gitlab-ci.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: circleci emits .circleci/config.yml + companion" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider circleci
  [ -s "$TEST_TMP/proj/.circleci/config.yml" ]
  [ -s "$TEST_TMP/proj/.circleci/config.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: jenkins emits Jenkinsfile + companion" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider jenkins
  [ -s "$TEST_TMP/proj/Jenkinsfile" ]
  [ -s "$TEST_TMP/proj/Jenkinsfile.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: azure-pipelines emits azure-pipelines.yml + companion" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider azure-pipelines
  [ -s "$TEST_TMP/proj/azure-pipelines.yml" ]
  [ -s "$TEST_TMP/proj/azure-pipelines.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: bitbucket-pipelines emits bitbucket-pipelines.yml + companion" {
  mkdir -p "$TEST_TMP/proj"
  "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider bitbucket-pipelines
  [ -s "$TEST_TMP/proj/bitbucket-pipelines.yml" ]
  [ -s "$TEST_TMP/proj/bitbucket-pipelines.user-steps.yml" ]
}

@test "generate-ci-scaffold.sh: rejects unknown provider" {
  mkdir -p "$TEST_TMP/proj"
  run "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider banana
  [ "$status" -ne 0 ]
}

@test "generate-ci-scaffold.sh: 'none' provider is a no-op (exits 0, writes nothing)" {
  mkdir -p "$TEST_TMP/proj"
  run "$SKILL_SCRIPTS/generate-ci-scaffold.sh" --path "$TEST_TMP/proj" --provider none
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_TMP/proj/.github" ]
}

# --- AC7: SKILL.md instructs next-steps render ----------------------------

@test "SKILL.md: documents next-steps rendering (file list, credential reminder, pointer)" {
  grep -F 'Next Steps' "$SKILL_DIR/SKILL.md" || grep -F 'next-steps' "$SKILL_DIR/SKILL.md"
}

# --- E71-S6: Step 2.2 project-shape enum relabel + plugin alias acceptance ---
# Story: E71-S6 — AC1-AC6 (AF-2026-05-08-3, TC-RSV2-INIT-4, TC-RSV2-INIT-5)

@test "E71-S6 AC1: Step 2.2 enum lists single-backend" {
  grep -F 'single-backend' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists microservices" {
  grep -F 'microservices' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists web-app" {
  grep -F 'web-app' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists mobile-only" {
  grep -F 'mobile-only' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists mobile+backend" {
  grep -F 'mobile+backend' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists fullstack" {
  grep -F 'fullstack' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists microservices+mobile" {
  grep -F 'microservices+mobile' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC1: Step 2.2 enum lists claude-code-plugin" {
  grep -F 'claude-code-plugin' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC2: web-app option carries label 'Web app (frontend + backend)'" {
  grep -F 'Web app (frontend + backend)' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC2: fullstack option carries label 'Web + mobile + backend'" {
  grep -F 'Web + mobile + backend' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC3: claude-code-plugin option surfaces aliases (claude-plugin, plugin)" {
  grep -F 'aliases: claude-plugin, plugin' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC3: SKILL.md documents case-insensitive alias-normalization arm" {
  grep -iF 'case-insensitive' "$SKILL_DIR/SKILL.md" \
    && grep -iF 'normaliz' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC4: generate-config.sh is_plugin_shape gate is byte-identical (canonical literal preserved)" {
  grep -F 'is_plugin_shape = project_shape == "claude-code-plugin"' "$SKILL_SCRIPTS/generate-config.sh"
}

@test "E71-S6 AC5: SKILL.md defers schema-level decision to AI-2026-05-08-3" {
  grep -F 'AI-2026-05-08-3' "$SKILL_DIR/SKILL.md"
}

@test "E71-S6 AC5: project-config.schema.json project_kind has no enum constraint" {
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../schemas" && pwd)/project-config.schema.json"
  # The story preserves the schema's open-vocabulary stance: project_kind block must
  # NOT contain an "enum" constraint. We extract the project_kind object and assert
  # no "enum" key exists within it. Use python for reliable JSON parsing.
  run python3 -c "
import json, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
pk = schema.get('properties', {}).get('project_kind', {})
if 'enum' in pk:
    sys.exit(1)
sys.exit(0)
"
  [ "$status" -eq 0 ]
}

@test "E71-S6 AC6: Step 2a mobile follow-ups still gated on canonical mobile triplet" {
  # Trigger predicate must reference all three canonical mobile shapes.
  grep -F 'mobile-only' "$SKILL_DIR/SKILL.md" \
    && grep -F 'mobile+backend' "$SKILL_DIR/SKILL.md" \
    && grep -F 'microservices+mobile' "$SKILL_DIR/SKILL.md"
}
