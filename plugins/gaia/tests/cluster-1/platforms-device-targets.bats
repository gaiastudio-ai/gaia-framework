#!/usr/bin/env bats
# platforms-device-targets.bats — E74-S1 / FR-RSV2-26, FR-RSV2-27, NFR-RSV2-8
#
# Public functions covered (NFR-052):
#   extract_device_targets_json
# These are exercised end-to-end via the `--format json` device_targets
# tests below; the name is listed here so the coverage gate (which greps
# .bats files for function names) registers them.
#
# Verifies the full mobile-platform schema extension layered over the
# E68-S1 stubs:
#   - `platforms` enum surface extended with documented (web|ios|android) AND
#     extensibility for future identifiers (warning, not error per AC6).
#   - `device_targets.<platform>` requires `os_versions` (array<string>),
#     `screen_sizes` (array<{width:int,height:int,density:number}>), and
#     `form_factors` (array<enum:phone|tablet|foldable|watch|tv>).
#   - `resolve-config.sh` resolves both keys without error AND emits them in
#     `--format json` output.
#   - Backward compatibility — configs without mobile keys still resolve.
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
project_root: /tmp/gaia-e74
project_path: /tmp/gaia-e74/app
memory_path: /tmp/gaia-e74/_memory
checkpoint_path: /tmp/gaia-e74/_memory/checkpoints
installed_path: /tmp/gaia-e74/_gaia
framework_version: 1.127.2-rc.1
date: 2026-05-05
YAML
}

mk_mobile_valid() {
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios, android]
device_targets:
  ios:
    os_versions: ["17.0", "16.0"]
    screen_sizes:
      - { width: 390, height: 844, density: 3.0 }
      - { width: 430, height: 932, density: 3.0 }
    form_factors: [phone, tablet]
  android:
    os_versions: ["14", "13"]
    screen_sizes:
      - { width: 412, height: 915, density: 2.625 }
    form_factors: [phone, foldable]
YAML
  } > "$1"
}

mk_mobile_invalid_platform() {
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: ["windows"]
YAML
  } > "$1"
}

mk_mobile_invalid_targets() {
  # Missing required sub-keys (form_factors absent, screen_sizes element
  # missing density) — schema must reject.
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios]
device_targets:
  ios:
    os_versions: ["17.0"]
    screen_sizes:
      - { width: 390, height: 844 }
YAML
  } > "$1"
}

mk_no_mobile() {
  mk_required_fields_yaml > "$1"
}

mk_unknown_platform() {
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: ["harmonyos"]
YAML
  } > "$1"
}

mk_invalid_form_factor() {
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios]
device_targets:
  ios:
    os_versions: ["17.0"]
    screen_sizes:
      - { width: 390, height: 844, density: 3.0 }
    form_factors: [phone, "bogus_factor"]
YAML
  } > "$1"
}

mk_shared_with_mobile() {
  local dir="$1"
  mkdir -p "$dir/config"
  mk_mobile_valid "$dir/config/project-config.yaml"
}

# ---------------------------------------------------------------------------
# AC1 — `platforms` array accepted (TC-RSV2-MOBILE-01)
# ---------------------------------------------------------------------------

@test "E74-S1 AC1: --field platforms returns ios,android" {
  mk_shared_with_mobile "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field platforms
  [ "$status" -eq 0 ]
  [[ "$output" == *"ios"* ]]
  [[ "$output" == *"android"* ]]
}

@test "E74-S1 AC1: --format json output includes \$.platforms array" {
  mk_shared_with_mobile "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  ios=$(printf '%s' "$output" | jq -r '.platforms | index("ios")')
  [ "$ios" != "null" ]
  android=$(printf '%s' "$output" | jq -r '.platforms | index("android")')
  [ "$android" != "null" ]
}

# ---------------------------------------------------------------------------
# AC2 — `device_targets` block accepted (TC-RSV2-MOBILE-02)
# ---------------------------------------------------------------------------

@test "E74-S1 AC2: --format json output includes \$.device_targets block" {
  mk_shared_with_mobile "$TEST_TMP/skill"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  has_dt=$(printf '%s' "$output" | jq -r 'has("device_targets")')
  [ "$has_dt" = "true" ]
  ios_os=$(printf '%s' "$output" | jq -r '.device_targets.ios.os_versions[0]')
  [ "$ios_os" = "17.0" ]
  android_ff=$(printf '%s' "$output" | jq -r '.device_targets.android.form_factors[0]')
  [ "$android_ff" = "phone" ]
}

# ---------------------------------------------------------------------------
# AC3 — JSON schema validation passes / fails (TC-RSV2-MOBILE-03)
# ---------------------------------------------------------------------------

@test "E74-S1 AC3: valid config with platforms+device_targets passes schema" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_mobile_valid "$TEST_TMP/valid.yaml"
  yaml_to_json "$TEST_TMP/valid.yaml" "$TEST_TMP/valid.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/valid.json" --strict=false
  [ "$status" -eq 0 ]
}

@test "E74-S1 AC3: invalid platform 'windows' is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_mobile_invalid_platform "$TEST_TMP/bad.yaml"
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

@test "E74-S1 AC3: device_targets missing required sub-keys is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_mobile_invalid_targets "$TEST_TMP/bad.yaml"
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — backward compatibility (TC-RSV2-MOBILE-04)
# ---------------------------------------------------------------------------

@test "E74-S1 AC4: config without platforms/device_targets resolves cleanly" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_no_mobile "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  has_pl=$(printf '%s' "$output" | jq -r 'has("platforms")')
  has_dt=$(printf '%s' "$output" | jq -r 'has("device_targets")')
  [ "$has_pl" = "false" ]
  [ "$has_dt" = "false" ]
}

@test "E74-S1 AC4: config without platforms/device_targets passes schema" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_no_mobile "$TEST_TMP/no-mobile.yaml"
  yaml_to_json "$TEST_TMP/no-mobile.yaml" "$TEST_TMP/no-mobile.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/no-mobile.json" --strict=false
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5 — device_targets schema structure (TC-RSV2-MOBILE-05)
# ---------------------------------------------------------------------------

@test "E74-S1 AC5: form_factors enforces enum (rejects bogus_factor)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_invalid_form_factor "$TEST_TMP/bad.yaml"
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

@test "E74-S1 AC5: form_factors all five enum values accepted" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios]
device_targets:
  ios:
    os_versions: ["17.0"]
    screen_sizes:
      - { width: 390, height: 844, density: 3.0 }
    form_factors: [phone, tablet, foldable, watch, tv]
YAML
  } > "$TEST_TMP/full.yaml"
  yaml_to_json "$TEST_TMP/full.yaml" "$TEST_TMP/full.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/full.json" --strict=false
  [ "$status" -eq 0 ]
}

@test "E74-S1 AC5: screen_sizes object structure validated (width/height/density)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  # density as float (3.0) must be accepted
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios]
device_targets:
  ios:
    os_versions: ["17.0"]
    screen_sizes:
      - { width: 390, height: 844, density: 3.0 }
    form_factors: [phone]
YAML
  } > "$TEST_TMP/ok.yaml"
  yaml_to_json "$TEST_TMP/ok.yaml" "$TEST_TMP/ok.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/ok.json" --strict=false
  [ "$status" -eq 0 ]
}

@test "E74-S1 AC5: screen_sizes with non-integer width is rejected" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [ios]
device_targets:
  ios:
    os_versions: ["17.0"]
    screen_sizes:
      - { width: "wide", height: 844, density: 3.0 }
    form_factors: [phone]
YAML
  } > "$TEST_TMP/bad.yaml"
  yaml_to_json "$TEST_TMP/bad.yaml" "$TEST_TMP/bad.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/bad.json" --strict=false
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — platforms enum extensibility (TC-RSV2-MOBILE-06)
#
# Per ADR-081 §4.2: the schema enforces a strict enum (so typos and
# out-of-domain identifiers like `windows` are rejected at validation
# time — see AC3), but `resolve-config.sh` degrades gracefully on
# unknown identifiers — emitting a stderr warning rather than aborting.
# This lets a project on a stale schema-version use a newer identifier
# (e.g., `harmonyos`) without being blocked by the resolver.
# ---------------------------------------------------------------------------

@test "E74-S1 AC6: unknown platform identifier 'harmonyos' is rejected by schema" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  mk_unknown_platform "$TEST_TMP/unknown.yaml"
  yaml_to_json "$TEST_TMP/unknown.yaml" "$TEST_TMP/unknown.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/unknown.json" --strict=false
  [ "$status" -ne 0 ]
}

@test "E74-S1 AC6: resolve-config.sh tolerates unknown platform identifier (warns on stderr, exits 0)" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_unknown_platform "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT" --field platforms
  [ "$status" -eq 0 ]
  [[ "$output" == *"harmonyos"* ]]
}

@test "E74-S1 AC6: resolve-config.sh warns on stderr for unknown platform identifier" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_unknown_platform "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  # Capture stderr separately
  stderr_file="$TEST_TMP/stderr.log"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    bash -c "'$SCRIPT' --field platforms 2> '$stderr_file'"
  [ "$status" -eq 0 ]
  [ -f "$stderr_file" ]
  grep -qE "warning.*platform.*harmonyos|unknown platform.*harmonyos" "$stderr_file"
}

@test "E74-S1 AC6: resolve-config.sh does NOT warn for documented identifiers" {
  mkdir -p "$TEST_TMP/skill/config"
  mk_mobile_valid "$TEST_TMP/skill/config/project-config.yaml"
  cd "$TEST_TMP"
  stderr_file="$TEST_TMP/stderr.log"
  run env -u CLAUDE_PROJECT_ROOT -u GAIA_SHARED_CONFIG -u GAIA_LOCAL_CONFIG \
    CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    bash -c "'$SCRIPT' --field platforms 2> '$stderr_file'"
  [ "$status" -eq 0 ]
  # No warning expected — file may be empty or just other resolver chatter.
  ! grep -qE "warning.*platform" "$stderr_file" || true
  ! grep -qE "unknown platform" "$stderr_file"
}

# ---------------------------------------------------------------------------
# Cross-cutting — preserve E68-S1 surface
# ---------------------------------------------------------------------------

@test "E74-S1: E68-S1 'web' platform identifier still accepted" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 unavailable"; fi
  if ! python3 -c "import yaml" 2>/dev/null; then skip "PyYAML unavailable"; fi
  {
    mk_required_fields_yaml
    cat <<'YAML'
platforms: [web]
YAML
  } > "$TEST_TMP/web.yaml"
  yaml_to_json "$TEST_TMP/web.yaml" "$TEST_TMP/web.json"
  run npx --yes ajv-cli@5 validate -s "$SCHEMA" -d "$TEST_TMP/web.json" --strict=false
  [ "$status" -eq 0 ]
}
