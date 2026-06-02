#!/usr/bin/env bats
# resolve-config-artifact-paths.bats — E60-S2 / ADR-074 contract C1
# Locks ADR-074 contract C1 — do not edit without an ADR amendment.
#
# Verifies that resolve-config.sh resolves the four artifact-path keys
# (planning_artifacts, implementation_artifacts, test_artifacts,
# creative_artifacts) when invoked positionally as
#   resolve-config.sh <key>
# emitting ONLY the resolved scalar value on stdout with exit 0 — both
# in the default scenario (project-config.yaml carries the canonical
# `docs/<dir>` defaults added by E60-S1) and the override scenario
# (project-level project-config.yaml supersedes any framework default
# per ADR-044 §10.26.3, project > global).
#
# Mirrors the Cluster 1 fixture pattern (synthetic configs in
# TEST_TMP/skill, CLAUDE_SKILL_DIR-driven discovery; the real repo
# configs are not touched). See resolve-config-sizing-map.bats for the
# sibling pattern this file follows.

load 'test_helper.bash'

setup() { common_setup; SCRIPT="$SCRIPTS_DIR/resolve-config.sh"; }
teardown() { common_teardown; }

mk_required_fields() {
  # Emit the required-field block to stdout. The resolver dies with exit
  # 2 on any missing required field, so every fixture builder must seed
  # these. Keep distinct from the host's real project-config.yaml.
  cat <<'YAML'
project_root: /tmp/gaia-art
project_path: /tmp/gaia-art/app
memory_path: /tmp/gaia-art/_memory
checkpoint_path: /tmp/gaia-art/_memory/checkpoints
installed_path: /tmp/gaia-art/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-28
YAML
}

mk_shared_with_artifact_defaults() {
  # Writes a synthetic shared project-config.yaml with the four
  # canonical artifact-path defaults (E60-S1 contract). Each key carries
  # the documented `docs/<dir>` value, mirroring the real
  # gaia-public/plugins/gaia/config/project-config.yaml.
  local dir="$1"
  mkdir -p "$dir/config"
  {
    mk_required_fields
    cat <<'YAML'
planning_artifacts: docs/planning-artifacts
implementation_artifacts: docs/implementation-artifacts
test_artifacts: docs/test-artifacts
creative_artifacts: docs/creative-artifacts
YAML
  } > "$dir/config/project-config.yaml"
}

mk_shared_with_planning_override() {
  # Writes a synthetic shared project-config.yaml with a custom
  # planning_artifacts override (`planning/`). The other three keys keep
  # their canonical defaults so this fixture isolates the override
  # behavior to a single key.
  local dir="$1"
  mkdir -p "$dir/config"
  {
    mk_required_fields
    cat <<'YAML'
planning_artifacts: planning/
implementation_artifacts: docs/implementation-artifacts
test_artifacts: docs/test-artifacts
creative_artifacts: docs/creative-artifacts
YAML
  } > "$dir/config/project-config.yaml"
}

run_resolver_isolated() {
  # Invoke "$SCRIPT $@" with a fully isolated environment — clears every
  # discovery vector that could leak the host project's config into the
  # resolver (CLAUDE_PROJECT_ROOT, GAIA_SHARED_CONFIG, GAIA_LOCAL_CONFIG)
  # and clears the four GAIA_*_ARTIFACTS env overrides so the resolver
  # falls through to the file-system layer that the test fixture seeded.
  # CLAUDE_SKILL_DIR is the canonical bats-fixture discovery path (L6).
  # Caller must `cd "$TEST_TMP"` first so $PWD/config/ does not exist
  # (otherwise the L5 PWD discovery would beat the L6 CLAUDE_SKILL_DIR
  # fallback).
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    -u GAIA_PLANNING_ARTIFACTS -u GAIA_IMPLEMENTATION_ARTIFACTS \
    -u GAIA_TEST_ARTIFACTS -u GAIA_CREATIVE_ARTIFACTS \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# AC1 / AC2 — default-path positional resolution (one test per key).
# Invocation: `resolve-config.sh <key>` emits the resolved scalar on stdout.
# Order S1, S2, S3, S4 of the story Test Scenarios table.
# ---------------------------------------------------------------------------

@test "artifact-paths (positional): planning_artifacts default → docs/planning-artifacts" {
  mk_shared_with_artifact_defaults "$TEST_TMP/skill"
  cd "$TEST_TMP"  # PWD must not contain a config/ dir, otherwise L5 wins.
  run_resolver_isolated planning_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = "docs/planning-artifacts" ]
}

@test "artifact-paths (positional): implementation_artifacts default → docs/implementation-artifacts" {
  mk_shared_with_artifact_defaults "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run_resolver_isolated implementation_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = "docs/implementation-artifacts" ]
}

@test "artifact-paths (positional): test_artifacts default → docs/test-artifacts" {
  mk_shared_with_artifact_defaults "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run_resolver_isolated test_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = "docs/test-artifacts" ]
}

@test "artifact-paths (positional): creative_artifacts default → docs/creative-artifacts" {
  mk_shared_with_artifact_defaults "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run_resolver_isolated creative_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = "docs/creative-artifacts" ]
}

# ---------------------------------------------------------------------------
# AC3 — project-config.yaml override beats default.
# Story Test Scenario #5: fixture sets planning_artifacts: planning/.
# ---------------------------------------------------------------------------

@test "artifact-paths (positional): project override wins — planning/ returned" {
  mk_shared_with_planning_override "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run_resolver_isolated planning_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = "planning/" ]
}

# ---------------------------------------------------------------------------
# Story Test Scenario #6 — missing key surfaces a clear stderr message.
# Mirrors the existing positional-query unknown-arg behavior (sizing_map
# parser dies with exit 2 on any unknown argument).
# ---------------------------------------------------------------------------

@test "artifact-paths (positional): unknown key → non-zero exit + clear stderr" {
  mk_shared_with_artifact_defaults "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run_resolver_isolated nonexistent_key
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonexistent_key"* ]]
}
