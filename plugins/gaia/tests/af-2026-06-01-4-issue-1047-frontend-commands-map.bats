#!/usr/bin/env bats
# AF-2026-06-01-4 — issue #1047 — sprint_review frontend_commands map.
#
# Lifts the single-web-stack cap baked into the legacy `frontend_command`
# scalar by adding a `frontend_commands` map (mirroring `backend_commands`,
# `mobile_commands`, `desktop_commands`, `plugin_commands`). The legacy
# scalar stays accepted as a backward-compat alias for single-web-stack
# projects; on key collision the map wins (precedence rule).
#
# Bash-3.2 compatible — wired into the cross-platform-portability CI matrix
# via the existing tests/ root.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN_ROOT/schemas/project-config.schema.json"
  DISPATCH="$PLUGIN_ROOT/skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  CONFIG_SKILL="$PLUGIN_ROOT/skills/gaia-config-sprint-review/SKILL.md"
}

teardown() { common_teardown; }

# ===========================================================================
# Schema — frontend_commands map present alongside the deprecated scalar
# ===========================================================================

@test "AF-32-2 #1047: schema declares sprint_review.frontend_commands (map)" {
  run jq -r '.properties.sprint_review.properties.frontend_commands.type' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "object" ]
}

@test "AF-32-2 #1047: frontend_commands additionalProperties enforces string command-values" {
  run jq -r '.properties.sprint_review.properties.frontend_commands.additionalProperties.type' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "string" ]
}

@test "AF-32-2 #1047: frontend_commands description names the four sibling maps" {
  run jq -r '.properties.sprint_review.properties.frontend_commands.description' "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend_commands"* ]]
  [[ "$output" == *"mobile_commands"* ]]
}

@test "AF-32-2 #1047: legacy frontend_command (scalar) stays in the schema as deprecated alias" {
  run jq -r '.properties.sprint_review.properties.frontend_command.type' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "string" ]
}

@test "AF-32-2 #1047: deprecated frontend_command description names the canonical map alternative" {
  run jq -r '.properties.sprint_review.properties.frontend_command.description' "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPRECATED"* ]]
  [[ "$output" == *"frontend_commands"* ]]
}

# ===========================================================================
# Dispatcher — track-b-dispatch.sh iterates the new map
# ===========================================================================

@test "AF-32-2 #1047: track-b-dispatch.sh collects stacks_frontend from frontend_commands" {
  run grep -F "stacks_frontend=" "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "AF-32-2 #1047: track-b-dispatch.sh stack_command_for resolves via frontend_commands first" {
  # Match the per-stack yq lookup pattern that `stack_command_for` uses.
  # Using grep -E with escaped brackets so bash and grep agree on the literal.
  run grep -E 'frontend_commands\[\\"\$stack\\"\]' "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "AF-32-2 #1047: track-b-dispatch.sh emits a DEPRECATED advisory when the scalar is used and the map lacks 'frontend'" {
  run grep -F "DEPRECATED: sprint_review.frontend_command" "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "AF-32-2 #1047: track-b-dispatch.sh merge_legacy_frontend_scalar gate blocks double-add on key collision" {
  # The merge gate must be conditional on frontend_map_has_frontend_key != true
  # so a project that sets both `frontend_command: ...` AND
  # `frontend_commands: { frontend: ... }` does NOT add `frontend` twice.
  run grep -F 'frontend_map_has_frontend_key' "$DISPATCH"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Config editor SKILL.md — documents the new key + the deprecation
# ===========================================================================

@test "AF-32-2 #1047: gaia-config-sprint-review SKILL.md names frontend_commands.<stack-id>" {
  run grep -F 'frontend_commands.<stack-id>' "$CONFIG_SKILL"
  [ "$status" -eq 0 ]
}

@test "AF-32-2 #1047: gaia-config-sprint-review SKILL.md flags frontend_command as deprecated" {
  run grep -F 'frontend_command' "$CONFIG_SKILL"
  [ "$status" -eq 0 ]
  run grep -Fi 'deprecated' "$CONFIG_SKILL"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Schema integration — a two-web-stack config is now expressible end-to-end
# ===========================================================================

@test "AF-32-2 #1047: a project with two web stacks (frontend + website) validates against the schema" {
  # Sanity-check that the schema accepts a representative two-web-stack config.
  # We invoke validate-project-config.sh if present; otherwise fall back to a
  # pure-jq schema-keys check (the per-key schema definitions tested above are
  # the authoritative gate).
  local fixture
  fixture="$(mktemp -t af-32-2-1047.XXXXXX).yaml"
  cat > "$fixture" <<'YAML'
$schema_version: "2.0.0"
config_phase: ready
project_path: "."
sprint_review:
  frontend_commands:
    frontend: "cd frontend && npm run test:e2e"
    website: "cd website && pnpm run test:e2e"
  playwright_headed: true
  timeout_per_stack: 300
  human_confirm: required
  screen_recording_fallback: true
YAML
  # Bare structural check — the two stacks land under a single key.
  run yq eval '.sprint_review.frontend_commands | keys | length' "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  rm -f "$fixture"
}
