#!/usr/bin/env bats
# gaia-config-validate-schema.bats — E71-S3 AC5
#
# Validates that /gaia-config-validate runs JSON Schema validation against
# project-config.schema.json (E68-S1) and surfaces:
#   - Exit 0 on a schema-conformant project-config.yaml
#   - Exit 1 on a non-conformant file with JSONPath-style locations
#
# Test cases:
#   TC-RSV2-INIT-18 — schema validation pass/fail (AC5)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/validate-project-config.sh"
  SCHEMA="$REPO_ROOT/plugins/gaia/schemas/project-config.schema.json"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-config-validate/SKILL.md"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

@test "validate-project-config.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "schema file shipped (E68-S1)" {
  [ -f "$SCHEMA" ]
}

@test "AC5 — exit 0 on schema-conformant project-config.yaml" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  cat > "$fixture" <<'YAML'
project_root: /tmp/p
project_path: /tmp/p/src
memory_path: /tmp/p/_memory
checkpoint_path: /tmp/p/_memory/checkpoints
installed_path: /tmp/p/_gaia
framework_version: 1.134.1
date: 2026-05-05
YAML
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
}

@test "AC5 — exit 1 on missing required project_root" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  cat > "$fixture" <<'YAML'
project_path: /tmp/p/src
memory_path: /tmp/p/_memory
checkpoint_path: /tmp/p/_memory/checkpoints
installed_path: /tmp/p/_gaia
framework_version: 1.134.1
date: 2026-05-05
YAML
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 1 ]
  # Error must include the missing field name
  echo "${output}${stderr:-}" | grep -qE 'project_root'
}

@test "AC5 — error output references JSONPath-style location" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  cat > "$fixture" <<'YAML'
project_path: /tmp/p/src
memory_path: /tmp/p/_memory
checkpoint_path: /tmp/p/_memory/checkpoints
installed_path: /tmp/p/_gaia
framework_version: 1.134.1
date: 2026-05-05
YAML
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 1 ]
  # JSONPath markers: leading '$' or path-like '.field' notation
  echo "${output}${stderr:-}" | grep -qE '\$\.|\.project_root|/project_root'
}

@test "AC5 — SKILL.md gaia-config-validate references project-config.schema.json" {
  [ -f "$SKILL_FILE" ]
  run grep -F 'project-config.schema.json' "$SKILL_FILE"
  [ "$status" -eq 0 ]
}

@test "AC5 — SKILL.md gaia-config-validate exits 0 valid / 1 invalid" {
  [ -f "$SKILL_FILE" ]
  run grep -E 'exit.{0,40}(0|1).{0,40}(valid|invalid)' "$SKILL_FILE"
  [ "$status" -eq 0 ]
}
