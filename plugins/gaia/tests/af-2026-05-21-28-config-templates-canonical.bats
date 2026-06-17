#!/usr/bin/env bats
# AF-21-28: config templates + user-facing knowledge surface canonical-first.
# Closes the gap missed by SKILL.md + script sweeps (AF-21-10..-27):
#   - config/project-config.yaml.example (template copied by docs/onboarding)
#   - config/project-config.schema.yaml (schema field descriptions)
#   - knowledge/gaia-help.csv (user-facing help text, 65 hits)

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "project-config.yaml.example uses .gaia/artifacts/ paths" {
  grep -qF 'planning_artifacts: .gaia/artifacts/planning-artifacts' "$PLUGIN_ROOT/config/project-config.yaml.example"
  grep -qF 'implementation_artifacts: .gaia/artifacts/implementation-artifacts' "$PLUGIN_ROOT/config/project-config.yaml.example"
  grep -qF 'test_artifacts: .gaia/artifacts/test-artifacts' "$PLUGIN_ROOT/config/project-config.yaml.example"
  grep -qF 'creative_artifacts: .gaia/artifacts/creative-artifacts' "$PLUGIN_ROOT/config/project-config.yaml.example"
}

@test "project-config.yaml.example contains NO bare-legacy docs/<type>-artifacts paths" {
  ! grep -qE '^(planning|implementation|test|creative)_artifacts:\s+docs/' "$PLUGIN_ROOT/config/project-config.yaml.example"
}

@test "gaia-help.csv contains zero docs/<type>-artifacts/ refs (all canonicalized)" {
  ! grep -qE 'docs/(planning|test|creative|implementation|research)-artifacts' "$PLUGIN_ROOT/knowledge/gaia-help.csv"
}

@test "gaia-help.csv canonical .gaia/artifacts refs present" {
  grep -qF '.gaia/artifacts/planning-artifacts' "$PLUGIN_ROOT/knowledge/gaia-help.csv"
  grep -qF '.gaia/artifacts/creative-artifacts' "$PLUGIN_ROOT/knowledge/gaia-help.csv"
}

@test "project-config.schema.yaml descriptions canonical-first with dual-layout note" {
  grep -qF '.gaia/artifacts/test-artifacts directory (with legacy docs/test-artifacts fallback)' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '.gaia/artifacts/planning-artifacts directory (with legacy docs/planning-artifacts fallback)' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '.gaia/artifacts/implementation-artifacts directory (with legacy docs/implementation-artifacts fallback)' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '.gaia/artifacts/creative-artifacts directory (with legacy docs/creative-artifacts fallback)' "$PLUGIN_ROOT/config/project-config.schema.yaml"
}

@test "project-config.schema.yaml default-value placeholders canonical-first" {
  grep -qF '{project_root}/.gaia/artifacts/test-artifacts' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '{project_root}/.gaia/artifacts/planning-artifacts' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '{project_root}/.gaia/artifacts/implementation-artifacts' "$PLUGIN_ROOT/config/project-config.schema.yaml"
  grep -qF '{project_root}/.gaia/artifacts/creative-artifacts' "$PLUGIN_ROOT/config/project-config.schema.yaml"
}
