#!/usr/bin/env bats
# gaia-config-sprint-review.bats — E93-S2
#
# Public functions covered: gaia-config-sprint-review (skill — schema-driven
# validation via existing validate-project-config.sh). This bats suite
# exercises the schema constraints added by E93-S2 and the SKILL.md surface.
#
# Covers TC-SGR-37 sub-cases (a)-(e) per test-plan §11.78.10:
#   (a) conforming-config validation PASS
#   (b) playwright_headed: false REJECT with NFR-069 reference
#   (c) timeout_per_stack: 5 REJECT (below min 30)
#   (d) missing-section graceful degradation (no errors, no warnings)
#   (e) SKILL.md ships at canonical path with required subcommands
#
# Plus a story-local case for AC3 unknown-stack-identifier acceptance at
# schema level (the WARN is emitted by /gaia-config-validate, not the
# schema validator).

setup() {
  # Tests at plugins/gaia/tests/ — REPO_ROOT is three levels up (gaia-public/).
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/plugins/gaia/scripts/validate-project-config.sh"
  SCHEMA="$REPO_ROOT/plugins/gaia/schemas/project-config.schema.json"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-config-sprint-review/SKILL.md"
  TMPDIR_TEST="$(mktemp -d)"
}

# Mirror config-phase-schema.bats: detect available JSON-Schema validators
# and skip strict-constraint tests when none is available.
have_ajv() { command -v ajv >/dev/null 2>&1; }
have_python_jsonschema() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import jsonschema' 2>/dev/null
}
have_python_yaml() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import yaml' 2>/dev/null
}
have_strict_validator() {
  have_ajv || have_python_jsonschema
}

# Validate a yaml fixture against the schema using the first available
# strict validator (ajv | python jsonschema). Returns 0 on schema-conformant,
# 1 on violation. Returns 99 if no validator is available — caller MUST skip.
validate_strict() {
  local fixture="$1"
  if ! have_python_yaml; then
    return 99
  fi
  local json_tmp="$TMPDIR_TEST/fixture.json"
  python3 -c "
import yaml, json
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
import json, jsonschema, sys
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
"
    return $?
  fi
  return 99
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

_min_required_yaml() {
  cat <<'YAML'
project_root: /tmp/p
project_path: /tmp/p/src
memory_path: /tmp/p/_memory
checkpoint_path: /tmp/p/_memory/checkpoints
installed_path: /tmp/p/_gaia
framework_version: 1.158.0
date: 2026-05-19
YAML
}

# ---------- Pre-flight ----------

@test "Pre-flight: schema file shipped" {
  [ -f "$SCHEMA" ]
}

@test "Pre-flight: validate-project-config.sh is executable" {
  [ -x "$SCRIPT" ]
}

@test "Pre-flight: SKILL.md exists at canonical path" {
  [ -f "$SKILL_FILE" ]
}

# ---------- AC1 / TC-SGR-37(a): conforming sprint_review section validates ----------

@test "TC-SGR-37(a): conforming sprint_review section validates clean (exit 0)" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  backend_commands:
    backend-python: "pytest -v -s -m e2e"
    backend-node: "npm run test:e2e"
  frontend_command: "npx playwright test"
  playwright_headed: true
  timeout_per_stack: 300
  human_confirm: required
  screen_recording_fallback: true
YAML
  } > "$fixture"
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
}

# ---------- AC2 / TC-SGR-37(b): playwright_headed: false REJECTED (NFR-069) ----------

@test "TC-SGR-37(b): playwright_headed: false REJECTED (NFR-069 / T-SGR-2)" {
  have_strict_validator || skip "no strict JSON-Schema validator (ajv / python jsonschema) on PATH"
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  playwright_headed: false
YAML
  } > "$fixture"
  run validate_strict "$fixture"
  # Non-zero exit IS the contract. The error-message text varies by
  # validator (ajv emits 'must be equal to constant'; python jsonschema
  # emits 'False is not allowed for ...'); skip output-text assertion.
  [ "$status" -ne 0 ]
}

# ---------- AC2 (additional): default playwright_headed: true validates ----------

@test "AC2-extra: omitting playwright_headed entirely validates clean (default true applies)" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  human_confirm: required
YAML
  } > "$fixture"
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
}

# ---------- AC1 / TC-SGR-37(c): timeout_per_stack below min REJECTED ----------

@test "TC-SGR-37(c): timeout_per_stack: 5 REJECTED (below minimum 30)" {
  have_strict_validator || skip "no strict JSON-Schema validator on PATH"
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  timeout_per_stack: 5
YAML
  } > "$fixture"
  run validate_strict "$fixture"
  [ "$status" -ne 0 ]
}

@test "AC1-extra: timeout_per_stack above max REJECTED" {
  have_strict_validator || skip "no strict JSON-Schema validator on PATH"
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  timeout_per_stack: 9999
YAML
  } > "$fixture"
  run validate_strict "$fixture"
  [ "$status" -ne 0 ]
}

@test "AC1-extra: human_confirm with invalid enum value REJECTED" {
  have_strict_validator || skip "no strict JSON-Schema validator on PATH"
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  human_confirm: never
YAML
  } > "$fixture"
  run validate_strict "$fixture"
  [ "$status" -ne 0 ]
}

# ---------- TC-SGR-37(d): missing-section graceful degradation ----------

@test "TC-SGR-37(d): project-config.yaml with NO sprint_review section validates clean" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  _min_required_yaml > "$fixture"
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
  # No reference to sprint_review in output (silent absence)
  ! echo "${output}${stderr:-}" | grep -qE 'sprint_review'
}

# ---------- TC-SGR-37(f): frontend_commands map (issue #1047 / AF-2026-06-01-4) ----------

@test "TC-SGR-37(f): two-web-stack frontend_commands map validates clean (exit 0)" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  frontend_commands:
    frontend: "npx playwright test"
    website:  "cd website && pnpm test:e2e"
  playwright_headed: true
  timeout_per_stack: 300
  human_confirm: required
  screen_recording_fallback: true
YAML
  } > "$fixture"
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
}

@test "TC-SGR-37(f): legacy frontend_command scalar + frontend_commands map co-exist (exit 0)" {
  # Backward-compat: existing configs that still set the scalar keep working
  # even when the new map is also present. The map wins on key collision.
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  frontend_command: "npx playwright test"
  frontend_commands:
    website: "cd website && pnpm test:e2e"
  playwright_headed: true
YAML
  } > "$fixture"
  run "$SCRIPT" "$fixture"
  [ "$status" -eq 0 ]
}

# ---------- AC3: unknown stack identifiers in *_commands maps validate at schema level ----------

@test "AC3: unknown backend-stack identifier in backend_commands validates at schema (WARN is /gaia-config-validate concern)" {
  local fixture="$TMPDIR_TEST/project-config.yaml"
  {
    _min_required_yaml
    cat <<'YAML'
sprint_review:
  backend_commands:
    backend-haskell: "stack test --fast"
YAML
  } > "$fixture"
  run "$SCRIPT" "$fixture"
  # Schema does not reject unknown stack identifiers (additionalProperties on the map)
  [ "$status" -eq 0 ]
}

# ---------- TC-SGR-37(e): SKILL.md surface ----------

@test "TC-SGR-37(e): SKILL.md documents all four subcommands (get / set / show / clear)" {
  grep -qE '^- `get \[--key' "$SKILL_FILE"
  grep -qE '^- `set --key' "$SKILL_FILE"
  grep -qE '^- `show`' "$SKILL_FILE"
  grep -qE '^- `clear --key' "$SKILL_FILE"
}

@test "TC-SGR-37(e): SKILL.md declares the canonical ADR-044 comment-preserving editor rule" {
  grep -qE 'ADR-044' "$SKILL_FILE"
  grep -qE 'config-yaml-editor\.sh' "$SKILL_FILE"
}

@test "TC-SGR-37(e): SKILL.md NFR-069 enforcement rule on playwright_headed: false" {
  grep -qE 'NFR-069' "$SKILL_FILE"
  grep -qE 'playwright_headed must be true' "$SKILL_FILE"
}

@test "TC-SGR-37(e): SKILL.md is listed under orchestration_class light-procedural" {
  grep -qE '^orchestration_class:[[:space:]]*light-procedural$' "$SKILL_FILE"
}

# ---------- Schema correctness — playwright_headed has const: true ----------

@test "Schema invariant: playwright_headed defined with const: true" {
  python3 -c "
import json, sys
with open('$SCHEMA') as f:
    s = json.load(f)
sr = s['properties']['sprint_review']['properties']
ph = sr['playwright_headed']
assert ph.get('const') is True, f'expected playwright_headed const: true; got {ph}'
" || return 1
}

@test "Schema invariant: timeout_per_stack defined with minimum 30 + maximum 3600" {
  python3 -c "
import json
s = json.load(open('$SCHEMA'))
t = s['properties']['sprint_review']['properties']['timeout_per_stack']
assert t['minimum'] == 30 and t['maximum'] == 3600
"
}

@test "Schema invariant: human_confirm enum [required, optional]" {
  python3 -c "
import json
s = json.load(open('$SCHEMA'))
hc = s['properties']['sprint_review']['properties']['human_confirm']
assert hc['enum'] == ['required', 'optional']
"
}
