#!/usr/bin/env bats
# project-kind.bats — E77-S1 / FR-403 / ADR-087
#
# Public functions covered (NFR-052):
#   resolve-config.sh — project_kind resolution + soft-warn on unknown value
#
# Verifies the Tier-1 `project_kind` field across schema + resolver:
#   - Schema accepts a string `project_kind` value WITHOUT an enum constraint
#     (open vocabulary; advisory warnings only at the resolver layer).
#   - Schema accepts configs that omit `project_kind` entirely (backward compat).
#   - `resolve-config.sh --field project_kind` returns the resolved value.
#   - `resolve-config.sh` emits a stderr WARNING for unknown values that lists
#     recognized values, but exits 0 (advisory, not blocking).
#   - `resolve-config.sh` stays silent for recognized values.
#   - `--format json` and `--all` surface the field only when set.
#
# Inline fixtures match the cluster-1 helper pattern (no fixtures/ dir).

load 'test_helper.bash'

setup() {
  common_setup
  SCHEMA="$(cd "$BATS_TEST_DIRNAME/../../schemas" && pwd)/project-config.schema.json"
  SCRIPT="$SCRIPTS_DIR/resolve-config.sh"
  export SCHEMA SCRIPT
}
teardown() { common_teardown; }

# Convert a YAML fixture to JSON via python so ajv can consume it.
yaml_to_json() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(sys.stdin), default=str))
" < "$1" > "$2"
}

mk_required_fields_yaml() {
  cat <<'YAML'
project_root: /tmp/gaia-e77-s1
project_path: /tmp/gaia-e77-s1/app
memory_path: /tmp/gaia-e77-s1/_memory
checkpoint_path: /tmp/gaia-e77-s1/_memory/checkpoints
installed_path: /tmp/gaia-e77-s1/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-06
YAML
}

mk_with_kind() {
  local kind="$1" out="$2"
  {
    mk_required_fields_yaml
    printf 'project_kind: "%s"\n' "$kind"
  } > "$out"
}

mk_no_kind() {
  mk_required_fields_yaml > "$1"
}

mk_shared_with_kind() {
  local dir="$1" kind="$2"
  mkdir -p "$dir/config"
  mk_with_kind "$kind" "$dir/config/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — recognized value passes through (TC-PLUGIN-LOADER-3)
# ---------------------------------------------------------------------------

@test "E77-S1 AC1: --field project_kind returns claude-code-plugin" {
  mk_shared_with_kind "$TEST_TMP/skill" "claude-code-plugin"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field project_kind
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code-plugin"* ]]
}

@test "E77-S1 AC1: --format json includes \$.project_kind for recognized value" {
  mk_shared_with_kind "$TEST_TMP/skill" "web-app"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  pk=$(printf '%s' "$output" | jq -r '.project_kind')
  [ "$pk" = "web-app" ]
}

# ---------------------------------------------------------------------------
# AC2 — omission preserves backward compatibility (TC-PLUGIN-LOADER-3)
# ---------------------------------------------------------------------------

@test "E77-S1 AC2: --field project_kind returns empty when field omitted" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_no_kind "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field project_kind
  [ "$status" -eq 0 ]
  # Output is a single empty line (no value). Trim and assert empty.
  trimmed="$(printf '%s' "$output" | tr -d '[:space:]')"
  [ -z "$trimmed" ]
}

@test "E77-S1 AC2: --format json omits project_kind key when field omitted" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_no_kind "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  has_pk=$(printf '%s' "$output" | jq -r 'has("project_kind")')
  [ "$has_pk" = "false" ]
}

@test "E77-S1 AC2: omitted project_kind emits no warning on stderr" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_no_kind "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  stderr_file="$TEST_TMP/stderr.log"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    bash -c "'$SCRIPT' --format json 2> '$stderr_file' >/dev/null"
  [ "$status" -eq 0 ]
  ! grep -qE "project_kind" "$stderr_file"
}

# ---------------------------------------------------------------------------
# AC3 — unknown value: WARNING on stderr, exit 0, value passes through
# ---------------------------------------------------------------------------

@test "E77-S1 AC3: unknown project_kind passes through and exits 0" {
  mk_shared_with_kind "$TEST_TMP/skill" "foobar"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field project_kind
  [ "$status" -eq 0 ]
  [[ "$output" == *"foobar"* ]]
}

@test "E77-S1 AC3: unknown project_kind emits warning naming value and recognized values" {
  mk_shared_with_kind "$TEST_TMP/skill" "foobar"
  cd "$TEST_TMP"
  stderr_file="$TEST_TMP/stderr.log"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    bash -c "'$SCRIPT' --field project_kind 2> '$stderr_file'"
  [ "$status" -eq 0 ]
  [ -f "$stderr_file" ]
  # A non-canonical value is soft-warned (accepted under the open vocabulary)
  # with the offending value named, on stderr.
  grep -qE "(warning|note).*project_kind.*foobar|project_kind .*foobar.* (non-canonical|unknown)" "$stderr_file"
  # Recognized-values list must be advertised so users can self-correct.
  grep -qE "claude-code-plugin" "$stderr_file"
}

@test "E77-S1 AC3: recognized project_kind values do NOT emit a warning" {
  for kind in claude-code-plugin web-app mobile-app api library; do
    mkdir -p "$TEST_TMP/skill-$kind/config"
    mk_with_kind "$kind" "$TEST_TMP/skill-$kind/config/project-config.yaml"
    cd "$TEST_TMP"
    stderr_file="$TEST_TMP/stderr-$kind.log"
    run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
      CLAUDE_SKILL_DIR="$TEST_TMP/skill-$kind" \
      bash -c "'$SCRIPT' --field project_kind 2> '$stderr_file'"
    [ "$status" -eq 0 ]
    ! grep -qE "warning.*project_kind|unknown project_kind" "$stderr_file"
  done
}

# ---------------------------------------------------------------------------
# AC4 — schema definition: optional string, no enum
# ---------------------------------------------------------------------------

@test "E77-S1 AC4: schema declares project_kind as optional string with no enum" {
  jq -e '.properties.project_kind.type == "string"' "$SCHEMA"
  # NOT in `required`
  jq -e '.required | index("project_kind") == null' "$SCHEMA"
  # NO enum constraint on project_kind
  jq -e '.properties.project_kind | has("enum") | not' "$SCHEMA"
}

@test "E77-S1 AC4: schema validates a config with project_kind set to recognized value" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_with_kind "claude-code-plugin" "$TEST_TMP/valid.yaml"
  yaml_to_json "$TEST_TMP/valid.yaml" "$TEST_TMP/valid.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/valid.json" --strict=false
  [ "$status" -eq 0 ]
}

@test "E77-S1 AC4: schema validates a config with project_kind set to unknown string" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  # Unknown values are ALLOWED by schema (open vocabulary). Resolver warns;
  # schema does not block.
  mk_with_kind "foobar" "$TEST_TMP/unknown.yaml"
  yaml_to_json "$TEST_TMP/unknown.yaml" "$TEST_TMP/unknown.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/unknown.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — no regression on existing configs that omit project_kind
# ---------------------------------------------------------------------------

@test "E77-S1 AC5: schema validates a config WITHOUT project_kind (backward compat)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_no_kind "$TEST_TMP/no-kind.yaml"
  yaml_to_json "$TEST_TMP/no-kind.yaml" "$TEST_TMP/no-kind.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/no-kind.json" --strict=false
  [ "$status" -eq 0 ]
}

@test "E77-S1 AC5: schema rejects project_kind when set to a non-string (type guard)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  {
    mk_required_fields_yaml
    cat <<'YAML'
project_kind: 42
YAML
  } > "$TEST_TMP/typebad.yaml"
  yaml_to_json "$TEST_TMP/typebad.yaml" "$TEST_TMP/typebad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/typebad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — surfaceable to downstream consumers (--all + json shapes)
# ---------------------------------------------------------------------------

@test "E77-S1 AC6: --all emits project_kind=<value> when set" {
  mk_shared_with_kind "$TEST_TMP/skill" "mobile-app"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --all
  [ "$status" -eq 0 ]
  # shell_escape wraps simple kebab-case strings in single quotes — match the
  # canonical emit form rather than asserting on the bare value.
  [[ "$output" == *"project_kind='mobile-app'"* ]]
}

@test "E77-S1 AC6: --all does NOT emit project_kind when omitted (byte-stability)" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_no_kind "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --all
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"project_kind="* ]]
}
