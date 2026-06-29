#!/usr/bin/env bats
# e28-s285-deployment-model-config-key.bats — explicit deployment_model config key.
#
# Validates:
#   - schema declares an OPTIONAL top-level deployment_model closed enum (AC1)
#   - schema ACCEPTS a config with a valid deployment_model value (AC4)
#   - schema REJECTS an out-of-enum deployment_model value (AC4)
#   - schema ACCEPTS a config WITHOUT deployment_model — back-compat (AC4)
#   - compliance.ui_present is preserved unchanged — additive (AC3)
#   - the config-hydration allowlist-invariant holds with the new property (AC2)

load 'test_helper.bash'

have_python_jsonschema() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null
}

validate_json_against_schema() {
  local json_file="$1" schema="$2"
  python3 -c "
import json, sys, jsonschema
schema = json.load(open('$schema'))
data = json.load(open('$json_file'))
try:
    jsonschema.validate(data, schema)
    print('valid'); sys.exit(0)
except jsonschema.ValidationError as e:
    print('error:', e.message); sys.exit(1)
" 2>&1
}

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN/schemas/project-config.schema.json"
  HYDRATION="$PLUGIN/scripts/lib/config-hydration.sh"
}

teardown() { common_teardown; }

# Minimal valid base config (the required top-level identity props).
_write_base() {
  cat > "$1" <<JSON
{ "project_root": ".", "project_path": ".", "memory_path": "_memory",
  "checkpoint_path": "_memory/checkpoints", "installed_path": "_gaia",
  "framework_version": "1.0.0", "date": "2026-06-29"${2:+, $2} }
JSON
}

# ---------------------------------------------------------------------------
# AC1 — schema shape
# ---------------------------------------------------------------------------

@test "schema declares deployment_model as an optional top-level closed enum (AC1)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 -c "
import json
s = json.load(open('$SCHEMA'))
ps = s['properties']['deployment_model']
assert ps['type'] == 'string', ps
assert isinstance(ps.get('enum'), list) and ps['enum'], 'must be a closed enum'
assert 'deployment_model' not in s.get('required', []), 'must be optional'
print('ok', ','.join(ps['enum']))
"
  echo "out: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# AC4 — accept/reject/back-compat
# ---------------------------------------------------------------------------

@test "schema accepts a config with a valid deployment_model value (AC4)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  _write_base "$TEST_TMP/cfg.json" '"deployment_model": "distribution-only"'
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"valid"* ]]
}

@test "schema rejects an out-of-enum deployment_model value (AC4)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  _write_base "$TEST_TMP/cfg.json" '"deployment_model": "bogus-shape"'
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"error"* ]]
}

@test "schema accepts a config WITHOUT deployment_model — back-compat (AC4)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  _write_base "$TEST_TMP/cfg.json"
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"valid"* ]]
}

# ---------------------------------------------------------------------------
# AC3 — compliance.ui_present preserved (additive)
# ---------------------------------------------------------------------------

@test "compliance.ui_present is preserved unchanged — additive (AC3)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run python3 -c "
import json
s = json.load(open('$SCHEMA'))
comp = s['properties']['compliance']
up = comp['properties']['ui_present']
assert up['type'] == 'boolean', up
print('ok')
"
  echo "out: $output"
  [[ "$output" == *"ok"* ]]
  # And a config setting BOTH deployment_model and compliance.ui_present validates.
  if have_python_jsonschema; then
    _write_base "$TEST_TMP/cfg.json" '"deployment_model": "ui-app", "compliance": {"ui_present": true}'
    run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
    [[ "$output" == *"valid"* ]]
  fi
}

# ---------------------------------------------------------------------------
# AC2 — config-hydration allowlist-invariant
# ---------------------------------------------------------------------------

@test "deployment_model is classified managed-elsewhere (not auto-hydrated) and carries x-no-auto-hydration (AC2)" {
  [ -f "$HYDRATION" ] || skip "config-hydration.sh not found"
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  # Schema flags it x-no-auto-hydration.
  run python3 -c "
import json
s = json.load(open('$SCHEMA'))
assert s['properties']['deployment_model'].get('x-no-auto-hydration') is True
print('schema-ok')
"
  [[ "$output" == *"schema-ok"* ]]
  # And it appears in the managed-elsewhere list (NOT the allowlist).
  run bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_MANAGED_ELSEWHERE[@]}\""
  echo "managed: $output"
  [[ "$output" == *"deployment_model"* ]]
  run bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_ALLOWLIST[@]}\""
  echo "allowlist: $output"
  ! [[ "$output" == *"deployment_model"* ]]
}

# ---------------------------------------------------------------------------
# Name-collision guard: deployment_model must NOT reuse the init
# questionnaire's free-text project_shape vocabulary.
# ---------------------------------------------------------------------------

@test "deployment_model is a distinct key from the init project_shape input field (no vocabulary collision)" {
  have_python_jsonschema || skip "python3 + jsonschema not available"
  # An init-questionnaire project_shape value must NOT validate as a
  # deployment_model (they are deliberately different keys + vocabularies).
  _write_base "$TEST_TMP/cfg.json" '"deployment_model": "single backend"'
  run validate_json_against_schema "$TEST_TMP/cfg.json" "$SCHEMA"
  echo "out: $output"
  [[ "$output" == *"error"* ]]
  # The schema must not have introduced a top-level project_shape key.
  run python3 -c "import json; s=json.load(open('$SCHEMA')); print('present' if 'project_shape' in s['properties'] else 'absent')"
  [ "$output" = "absent" ]
}
