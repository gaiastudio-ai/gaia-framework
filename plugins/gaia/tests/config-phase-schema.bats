#!/usr/bin/env bats
# config-phase-schema.bats — coverage for project-config.schema.json v2.0.0 (E85-S2).
#
# Story: E85-S2 — `project-config.schema.json` v2.0.0 — `config_phase` enum +
#                 conditional section requirements.
# ADRs:  ADR-096 (config_phase state machine), ADR-097 (absence-over-sentinel),
#        ADR-044 (section-scoped editors), NFR-062 (backward compatibility).
#
# Validates AC1-AC10 via:
#   1. Structural greps over the schema file (no validator dependency).
#   2. Fixture-based validation through ajv-cli (or python3 jsonschema fallback)
#      when available. When neither validator is present, validator-dependent
#      tests skip gracefully.

load 'test_helper.bash'

setup() {
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"
  FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/config-phase-schema"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Validator detection
# ----------------------------------------------------------------------------

have_ajv() { command -v ajv >/dev/null 2>&1; }
have_npx_ajv() {
  command -v npx >/dev/null 2>&1 \
    && npx --quiet --no-install ajv-cli validate 2>&1 | grep -q "parameter" 2>/dev/null
}
have_python_jsonschema() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import jsonschema' 2>/dev/null
}
have_python_yaml() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import yaml' 2>/dev/null
}

# validate_yaml_against_schema <yaml_file>
# Echoes ajv-cli/python output, returns its exit code.
validate_fixture() {
  local fixture="$1"
  local json_tmp="${TMP}/fixture-$(basename "$fixture" .yaml).json"

  if ! have_python_yaml; then
    return 99  # cannot convert yaml -> json
  fi

  python3 -c "
import sys, yaml, json
with open('$fixture') as f:
    data = yaml.safe_load(f)
with open('$json_tmp', 'w') as f:
    json.dump(data, f)
" 2>&1 || return 1

  if have_ajv; then
    ajv validate -s "$SCHEMA" -d "$json_tmp" 2>&1
    return $?
  fi
  if have_python_jsonschema; then
    python3 -c "
import json, sys
import jsonschema
with open('$SCHEMA') as f:
    schema = json.load(f)
with open('$json_tmp') as f:
    data = json.load(f)
try:
    jsonschema.validate(data, schema)
    print('valid')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print('error:', e.message)
    sys.exit(1)
" 2>&1
    return $?
  fi
  # Fall back to npx ajv-cli (no global install needed).
  if command -v npx >/dev/null 2>&1; then
    npx --quiet ajv-cli validate -s "$SCHEMA" -d "$json_tmp" 2>&1
    return $?
  fi
  return 99  # no validator available
}

have_validator() {
  have_ajv || have_python_jsonschema || command -v npx >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# AC1-AC3 + AC9: Structural greps (no validator dependency)
# ----------------------------------------------------------------------------

@test "schema declares config_phase property with enum and default" {
  [ -f "$SCHEMA" ]
  # config_phase property block exists
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
cp = s['properties'].get('config_phase')
assert cp is not None, 'config_phase property missing'
assert cp.get('type') == 'string', f'config_phase type is {cp.get(\"type\")}, expected string'
assert cp.get('enum') == ['minimal', 'partial', 'full'], f'enum mismatch: {cp.get(\"enum\")}'
assert cp.get('default') == 'full', f'default is {cp.get(\"default\")}, expected full'
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "schema declares schema_version property" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
sv = s['properties'].get('schema_version')
assert sv is not None, 'schema_version property missing'
assert sv.get('type') == 'string', f'schema_version type mismatch: {sv.get(\"type\")}'
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "schema title references v2.0.0 and" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
title = s.get('title', '')
assert 'v2.0.0' in title or '2.0.0' in title, f'title missing 2.0.0: {title}'
print('ok')
"
  [ "$status" -eq 0 ]
}

@test "schema has allOf conditional blocks for each config_phase" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
all_of = s.get('allOf', [])
phases_seen = set()
for blk in all_of:
    cond = blk.get('if', {}).get('properties', {}).get('config_phase', {})
    if 'const' in cond:
        phases_seen.add(cond['const'])
assert phases_seen == {'minimal', 'partial', 'full'}, f'phases: {phases_seen}'
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "config_phase is NOT in top-level required array (backward compat)" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
required = s.get('required', [])
assert 'config_phase' not in required, f'config_phase MUST NOT be in required: {required}'
print('ok')
"
  [ "$status" -eq 0 ]
}

@test "minimal phase requires only project_name + project_kind (additive)" {
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
for blk in s.get('allOf', []):
    cond = blk.get('if', {}).get('properties', {}).get('config_phase', {})
    if cond.get('const') == 'minimal':
        req = blk.get('then', {}).get('required', [])
        assert 'project_name' in req, f'minimal missing project_name: {req}'
        assert 'project_kind' in req, f'minimal missing project_kind: {req}'
        assert 'stacks' not in req, f'minimal MUST NOT require stacks: {req}'
        print('ok')
        exit(0)
exit(2)
"
  [ "$status" -eq 0 ]
}

@test "partial phase requires project_name, project_kind, stacks, platforms" {
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
for blk in s.get('allOf', []):
    cond = blk.get('if', {}).get('properties', {}).get('config_phase', {})
    if cond.get('const') == 'partial':
        req = blk.get('then', {}).get('required', [])
        for needed in ['project_name', 'project_kind', 'stacks', 'platforms']:
            assert needed in req, f'partial missing {needed}: {req}'
        assert 'environments' not in req, f'partial MUST NOT require environments: {req}'
        print('ok')
        exit(0)
exit(2)
"
  [ "$status" -eq 0 ]
}

@test "full phase requires the complete set including environments + ci_cd" {
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
for blk in s.get('allOf', []):
    cond = blk.get('if', {}).get('properties', {}).get('config_phase', {})
    if cond.get('const') == 'full':
        req = blk.get('then', {}).get('required', [])
        for needed in ['project_name', 'project_kind', 'stacks', 'platforms', 'environments', 'ci_cd']:
            assert needed in req, f'full missing {needed}: {req}'
        print('ok')
        exit(0)
exit(2)
"
  [ "$status" -eq 0 ]
}

@test "every if block guards with required:[config_phase] (so absence skips)" {
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
for blk in s.get('allOf', []):
    if 'if' in blk and 'config_phase' in str(blk['if']):
        req = blk['if'].get('required', [])
        assert 'config_phase' in req, f'if block missing required:[config_phase]: {blk[\"if\"]}'
print('ok')
"
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# AC10 / TS1-TS8: Fixture-based validation
# ----------------------------------------------------------------------------

@test "minimal-valid fixture validates against schema" {
  if ! have_validator; then
    skip "no JSON Schema validator available (ajv or python-jsonschema)"
  fi
  fixture="${FIXTURES_DIR}/minimal-valid.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "partial-valid fixture validates against schema" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/partial-valid.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "full-valid fixture validates against schema" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/full-valid.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "legacy-no-phase fixture validates" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/legacy-no-phase.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "minimal-deferrable-absent fixture validates" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/minimal-deferrable-absent.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "full-config-missing-stacks fixture FAILS validation" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/full-missing-stacks.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stacks"* ]]
}

@test "TS7: invalid config_phase value (beta) fails validation" {
  if ! have_validator; then
    skip "no JSON Schema validator available"
  fi
  fixture="${FIXTURES_DIR}/invalid-phase.yaml"
  [ -f "$fixture" ] || skip "fixture not yet created: $fixture"
  run validate_fixture "$fixture"
  [ "$status" -ne 0 ]
}

# ----------------------------------------------------------------------------
# stacks items: test_cmd property is declared (schema-script drift fix)
# ----------------------------------------------------------------------------

@test "stacks items schema declares test_cmd property (type string, minLength 1)" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
items = s['properties']['stacks']['items']['properties']
tc = items.get('test_cmd')
assert tc is not None, 'test_cmd property missing from stacks items'
assert tc.get('type') == 'string', f'test_cmd type is {tc.get(\"type\")}, expected string'
assert tc.get('minLength') == 1, f'test_cmd minLength is {tc.get(\"minLength\")}, expected 1'
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "stacks items test_cmd is NOT in required array" {
  [ -f "$SCHEMA" ]
  run python3 -c "
import json
with open('$SCHEMA') as f:
    s = json.load(f)
req = s['properties']['stacks']['items'].get('required', [])
assert 'test_cmd' not in req, f'test_cmd MUST NOT be required: {req}'
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "review.max_fix_cycles rejects 0, -1, 2.5 and string values" {
  if ! have_validator; then
    skip "no JSON Schema validator available (ajv or python-jsonschema)"
  fi
  # Valid baseline config.
  local base="${TMP}/review-valid.yaml"
  cat > "$base" <<'YAML'
project_name: test-project
project_root: "/tmp/test-project"
project_path: "/tmp/test-project/src"
memory_path: "/tmp/test-project/_memory"
checkpoint_path: "/tmp/test-project/_memory/checkpoints"
installed_path: "/tmp/test-project/.gaia"
framework_version: "1.225.0"
date: "2026-11-01"
YAML

  # Valid value (integer >= 1) must pass.
  cp "$base" "${TMP}/review-ok.yaml"
  printf 'review:\n  max_fix_cycles: 3\n' >> "${TMP}/review-ok.yaml"
  run validate_fixture "${TMP}/review-ok.yaml"
  [ "$status" -eq 0 ] || { echo "valid cap 3 rejected: $output"; return 1; }

  # 0 must be rejected (minimum: 1).
  cp "$base" "${TMP}/review-zero.yaml"
  printf 'review:\n  max_fix_cycles: 0\n' >> "${TMP}/review-zero.yaml"
  run validate_fixture "${TMP}/review-zero.yaml"
  [ "$status" -ne 0 ]

  # -1 must be rejected.
  cp "$base" "${TMP}/review-neg.yaml"
  printf 'review:\n  max_fix_cycles: -1\n' >> "${TMP}/review-neg.yaml"
  run validate_fixture "${TMP}/review-neg.yaml"
  [ "$status" -ne 0 ]

  # 2.5 must be rejected (type: integer).
  cp "$base" "${TMP}/review-float.yaml"
  printf 'review:\n  max_fix_cycles: 2.5\n' >> "${TMP}/review-float.yaml"
  run validate_fixture "${TMP}/review-float.yaml"
  [ "$status" -ne 0 ]

  # "two" must be rejected (type: integer).
  cp "$base" "${TMP}/review-str.yaml"
  printf 'review:\n  max_fix_cycles: "two"\n' >> "${TMP}/review-str.yaml"
  run validate_fixture "${TMP}/review-str.yaml"
  [ "$status" -ne 0 ]
}

@test "config with per-stack test_cmd validates against schema" {
  if ! have_validator; then
    skip "no JSON Schema validator available (ajv or python-jsonschema)"
  fi
  # Write a minimal config with test_cmd under a stack entry.
  cat > "${TMP}/config-test-cmd.yaml" <<'YAML'
project_name: test-project
project_kind: web-app
project_root: "/tmp/test-project"
project_path: "/tmp/test-project/src"
memory_path: "/tmp/test-project/_memory"
checkpoint_path: "/tmp/test-project/_memory/checkpoints"
installed_path: "/tmp/test-project/.gaia"
framework_version: "1.146.1"
date: "2026-05-12"
stacks:
  - name: custom
    language: bash
    paths: ["src/**"]
    test_cmd: "make test-custom"
platforms:
  - web
YAML
  run validate_fixture "${TMP}/config-test-cmd.yaml"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

# --- preflight_commands / post_ci_smoke_commands schema tests ---

@test "schema contains preflight_commands property" {
  /usr/bin/grep -q '"preflight_commands"' "$SCHEMA"
}

@test "schema contains post_ci_smoke_commands property" {
  /usr/bin/grep -q '"post_ci_smoke_commands"' "$SCHEMA"
}

@test "schema accepts preflight_commands as array of strings" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-preflight-valid.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands:
  - "make lint"
  - "make test"
YAML
  run validate_fixture "${TMP}/config-preflight-valid.yaml"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "schema rejects preflight_commands as string" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-preflight-string.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
preflight_commands: "make check"
YAML
  run validate_fixture "${TMP}/config-preflight-string.yaml"
  [ "$status" -ne 0 ]
}

@test "schema accepts post_ci_smoke_commands as array of strings" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-smoke-valid.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
post_ci_smoke_commands:
  - "curl -f http://localhost:8080/health"
YAML
  run validate_fixture "${TMP}/config-smoke-valid.yaml"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "schema rejects post_ci_smoke_commands as integer" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-smoke-integer.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
post_ci_smoke_commands: 42
YAML
  run validate_fixture "${TMP}/config-smoke-integer.yaml"
  [ "$status" -ne 0 ]
}

@test "schema trust-boundary note in preflight_commands description" {
  /usr/bin/grep -A5 '"preflight_commands"' "$SCHEMA" | /usr/bin/grep -qi "trust boundary"
}

@test "schema trust-boundary note in post_ci_smoke_commands description" {
  /usr/bin/grep -A5 '"post_ci_smoke_commands"' "$SCHEMA" | /usr/bin/grep -qi "trust boundary"
}

# ---------- mutation_thresholds schema validation ----------

@test "mutation_thresholds schema accepts P0-P3 integers and rejects P99 and non-integers" {
  have_python_yaml || skip "python3 + PyYAML not available" # lint-pack:allow skip-in-red-test — tool-availability guard, not a red-phase skip
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available" # lint-pack:allow skip-in-red-test — tool-availability guard, not a red-phase skip

  # Valid: full object
  cat > "${TMP}/mt-valid-full.yaml" <<'YAML'
# ---------- dev_story.review_before_merge schema cases ----------

@test "schema accepts dev_story.review_before_merge as boolean true" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-rbm-true.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P0: 80
    P1: 60
    P2: 0
    P3: 0
YAML
  run validate_fixture "${TMP}/mt-valid-full.yaml"
  [ "$status" -eq 0 ] || { echo "full valid rejected: $output"; return 1; }

  # Valid: partial object (P0 only)
  cat > "${TMP}/mt-valid-partial.yaml" <<'YAML'
dev_story:
  review_before_merge: true
YAML
  run validate_fixture "${TMP}/config-rbm-true.yaml"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "schema accepts dev_story.review_before_merge as boolean false" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-rbm-false.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P0: 80
YAML
  run validate_fixture "${TMP}/mt-valid-partial.yaml"
  [ "$status" -eq 0 ] || { echo "partial valid rejected: $output"; return 1; }

  # Rejected: P99 (additionalProperties: false)
  cat > "${TMP}/mt-reject-p99.yaml" <<'YAML'
dev_story:
  review_before_merge: false
YAML
  run validate_fixture "${TMP}/config-rbm-false.yaml"
  [ "$status" -eq 0 ] || { echo "validator output: $output"; return 1; }
}

@test "schema rejects dev_story.review_before_merge as string yes" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-rbm-string.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P99: 50
YAML
  run validate_fixture "${TMP}/mt-reject-p99.yaml"
  [ "$status" -ne 0 ]

  # Rejected: 101 (maximum: 100)
  cat > "${TMP}/mt-reject-101.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P0: 101
YAML
  run validate_fixture "${TMP}/mt-reject-101.yaml"
  [ "$status" -ne 0 ]

  # Rejected: 2.5 (integer required, not number)
  cat > "${TMP}/mt-reject-float.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P0: 2.5
YAML
  run validate_fixture "${TMP}/mt-reject-float.yaml"
  [ "$status" -ne 0 ]

  # Rejected: string value
  cat > "${TMP}/mt-reject-string.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
test_execution:
  mutation_thresholds:
    P0: "eighty"
YAML
  run validate_fixture "${TMP}/mt-reject-string.yaml"
dev_story:
  review_before_merge: "yes"
YAML
  run validate_fixture "${TMP}/config-rbm-string.yaml"
  [ "$status" -ne 0 ]
}

@test "schema rejects dev_story.review_before_merge as integer" {
  have_python_yaml || skip "python3 + PyYAML not available"
  have_ajv || have_python_jsonschema || skip "no JSON schema validator available"
  cat > "${TMP}/config-rbm-int.yaml" <<'YAML'
project_root: /tmp/test
project_path: /tmp/test/src
memory_path: /tmp/test/memory
checkpoint_path: /tmp/test/checkpoints
installed_path: /tmp/test/installed
framework_version: "1.0.0"
date: "2026-01-01"
dev_story:
  review_before_merge: 1
YAML
  run validate_fixture "${TMP}/config-rbm-int.yaml"
  [ "$status" -ne 0 ]
}
