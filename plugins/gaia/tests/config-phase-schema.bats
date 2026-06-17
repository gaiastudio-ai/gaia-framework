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
