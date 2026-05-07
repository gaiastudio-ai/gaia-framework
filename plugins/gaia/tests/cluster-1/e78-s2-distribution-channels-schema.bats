#!/usr/bin/env bats
# e78-s2-distribution-channels-schema.bats — E78-S2 / FR-424
#
# Verifies that the project-config.schema.json correctly validates the new
# `distribution.channels[]` block introduced by E78-S2:
#   - AC1: type: marketplace is a valid generic type
#   - AC2: provider: github-releases is accepted as a string
#   - AC3: deploy_adapter: marketplace-publish is accepted as a string
#   - AC4: repository accepts owner/repo format
#   - AC5: version_file accepts flat path; rejects JSON Pointer
#   - AC6: version_key accepts a string
#   - AC7: release_notes_source accepts a relative path
#   - AC8: smoke_test.mode accepts manual-checklist; rejects others
#   - AC9: missing distribution key validates (backward compat)
#   - AC10: full valid channel passes ajv-cli validation with zero errors
#
# Uses `npx ajv-cli` for schema validation. Mirrors the existing pattern from
# project-config-schema-validation.bats (E68-S1).

load 'test_helper.bash'

setup() {
  common_setup
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../../schemas" && pwd)/project-config.schema.json"
  export SCHEMA
}
teardown() { common_teardown; }

# Convert a YAML fixture to JSON via python so ajv can consume it.
yaml_to_json() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
" < "$1" > "$2"
}

# Common required-fields preamble for project-config fixtures.
write_preamble() {
  cat > "$1" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-06
YAML
}

# ---------------------------------------------------------------------------
# AC10 / Test Scenario 1 — full valid channel entry passes
# ---------------------------------------------------------------------------

@test "E78-S2 schema: full valid distribution.channels entry passes validation" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      provider: github-releases
      deploy_adapter: marketplace-publish
      repository: my-org/my-plugin
      version_file: package.json
      version_key: version
      release_notes_source: CHANGELOG.md
      smoke_test:
        mode: manual-checklist
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC9 / Test Scenario 2 — missing distribution key is allowed (backward compat)
# ---------------------------------------------------------------------------

@test "E78-S2 schema: config without distribution block validates (backward compat)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC1 / Test Scenario 3 — invalid type value is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: invalid distribution.channels[].type value (npm-registry) is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: npm-registry
      provider: github-releases
      deploy_adapter: marketplace-publish
      repository: my-org/my-plugin
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC5 / Test Scenario 4 — JSON Pointer in version_file is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: version_file containing JSON Pointer (#/version) is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      provider: github-releases
      deploy_adapter: marketplace-publish
      repository: my-org/my-plugin
      version_file: "#/version"
      version_key: version
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test Scenario 5 — channel entry without required `type` is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: distribution.channels[] entry missing required type is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - provider: github-releases
      deploy_adapter: marketplace-publish
      repository: my-org/my-plugin
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC8 / Test Scenario 6 — valid smoke_test.mode passes
# ---------------------------------------------------------------------------

@test "E78-S2 schema: smoke_test.mode=manual-checklist is accepted" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      smoke_test:
        mode: manual-checklist
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC8 / Test Scenario 7 — invalid smoke_test.mode is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: smoke_test.mode=automated is rejected (enum violation)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      smoke_test:
        mode: automated
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC4 / Test Scenario 8 — repository pattern accepts owner/repo format
# ---------------------------------------------------------------------------

@test "E78-S2 schema: repository=my-org/my-plugin is accepted (owner/repo pattern)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      repository: my-org/my-plugin
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — repository missing slash is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: repository without owner/repo slash is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      repository: justmyrepo
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# additionalProperties: false on channel entry — typo in field name is rejected
# ---------------------------------------------------------------------------

@test "E78-S2 schema: channel entry with unknown field is rejected (additionalProperties: false)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  write_preamble "$TEST_TMP/c.yaml"
  cat >> "$TEST_TMP/c.yaml" <<'YAML'
distribution:
  channels:
    - type: marketplace
      typo_field: oops
YAML
  yaml_to_json "$TEST_TMP/c.yaml" "$TEST_TMP/c.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/c.json" --strict=false
  [ "$status" -ne 0 ]
}
