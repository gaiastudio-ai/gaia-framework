#!/usr/bin/env bats
# project-config-schema-validation.bats — E68-S1 / AC10, AC11
#
# Verifies that the new project-config.schema.json (JSON Schema draft-07)
# correctly validates project-config.yaml structure:
#   - Valid configs pass.
#   - Credential values literally embedded in environments.*.credentials are
#     rejected.
#   - Invalid test_execution.*.placement enum values are rejected.
#   - Missing required fields are rejected.
#
# Uses `npx ajv-cli` for schema validation. The schema file lives at
# plugins/gaia/schemas/project-config.schema.json.

load 'test_helper.bash'

setup() {
  common_setup
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../../schemas" && pwd)/project-config.schema.json"
  export SCHEMA
}
teardown() { common_teardown; }

# Convert a YAML fixture to JSON via python so ajv can consume it.
# `default=str` coerces YAML-native datetimes (e.g., date: 2026-05-04) into
# strings so json.dumps does not raise TypeError on them.
yaml_to_json() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
" < "$1" > "$2"
}

mk_valid_yaml() {
  cat > "$1" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
compliance:
  regimes: [gdpr, hipaa]
  ui_present: true
tools:
  sast:
    provider: semgrep
test_execution:
  tier_1:
    placement: local
  tier_2:
    placement: ci-pre-merge
severity:
  Critical: BLOCKED
  High: REQUEST_CHANGES
stacks:
  - name: auth
    language: typescript
    paths: ["services/auth/**"]
environments:
  staging:
    url: https://staging.example.com
    credentials:
      db_password: DB_PASSWORD_VAR
ci_platform:
  provider: github-actions
platforms: [web, ios]
YAML
}

# ---------------------------------------------------------------------------
# AC10 — schema file exists and is valid JSON
# ---------------------------------------------------------------------------

@test "E68-S1 schema: project-config.schema.json file exists" {
  [ -f "$SCHEMA" ]
}

@test "E68-S1 schema: schema is valid JSON" {
  run jq -e . "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "E68-S1 schema: schema declares draft-07 via \$schema" {
  run jq -r '."$schema"' "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft-07"* ]]
}

# ---------------------------------------------------------------------------
# AC10 — valid YAML passes schema
# ---------------------------------------------------------------------------

@test "E68-S1 schema: valid project-config.yaml passes schema validation" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_valid_yaml "$TEST_TMP/project-config.yaml"
  yaml_to_json "$TEST_TMP/project-config.yaml" "$TEST_TMP/project-config.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/project-config.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC11 — credential values in environments.credentials.* are rejected
# ---------------------------------------------------------------------------

@test "E68-S1 schema: credential value matching 'sk-' prefix in environments.credentials is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  cat > "$TEST_TMP/bad.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
environments:
  staging:
    credentials:
      db_password: "sk-secret123abc"
YAML
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

@test "E68-S1 schema: credential value matching 'AKIA' prefix is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  cat > "$TEST_TMP/bad.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
environments:
  prod:
    credentials:
      aws_key: "AKIAIOSFODNN7EXAMPLE"
YAML
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC10 — invalid placement enum is rejected
# ---------------------------------------------------------------------------

@test "E68-S1 schema: invalid test_execution.tier_1.placement value is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  cat > "$TEST_TMP/bad.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
test_execution:
  tier_1:
    placement: bogus-value
YAML
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC10 — missing required fields are rejected
# ---------------------------------------------------------------------------

@test "E68-S1 schema: missing required project_root is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  cat > "$TEST_TMP/bad.yaml" <<'YAML'
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
YAML
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — unknown compliance regime in canonical set
# ---------------------------------------------------------------------------

@test "E68-S1 schema: invalid compliance.regimes enum value is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  cat > "$TEST_TMP/bad.yaml" <<'YAML'
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/_memory
checkpoint_path: /tmp/gaia/_memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-04
compliance:
  regimes: ["bogus-regime"]
YAML
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}
