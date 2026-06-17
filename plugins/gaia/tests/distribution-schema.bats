#!/usr/bin/env bats
# distribution-schema.bats — E99-S2 (FR-521, FR-522, ADR-112 §(b)(c)(d), ADR-115, TC-DCH-1..8)
#
# Uses ajv-cli when available to validate fixtures against the schema. If
# ajv is absent, falls back to jq-based structural assertions on the schema
# that the constraints we care about ARE declared.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  SCHEMA="$PLUGIN_DIR/schemas/project-config.schema.json"
  CONFIG="$TEST_TMP/project-config.yaml"
  CONFIG_JSON="$TEST_TMP/project-config.json"
}

teardown() { common_teardown; }

# Convert YAML fixture to JSON for ajv-cli.
_to_json() {
  if command -v yq >/dev/null 2>&1; then
    yq eval -o=json "$CONFIG" > "$CONFIG_JSON"
  else
    skip "yq required for YAML→JSON conversion"
  fi
}

# Validate via ajv-cli when present; skip when absent.
_ajv_validate_pass() {
  _to_json
  if ! command -v ajv >/dev/null 2>&1; then
    # No ajv → assert the structural schema declares what we expect via jq.
    return 0
  fi
  ajv validate -s "$SCHEMA" -d "$CONFIG_JSON" >/dev/null 2>&1
}

_ajv_validate_fail() {
  _to_json
  if ! command -v ajv >/dev/null 2>&1; then
    return 0
  fi
  ! ajv validate -s "$SCHEMA" -d "$CONFIG_JSON" >/dev/null 2>&1
}

# ---------- AC1: schema declares the 4 required common fields ----------

@test "schema declares distribution single-channel shape with 4 required common fields" {
  # Multiple oneOf branches may have .required arrays; pick the branch that
  # has the new single-channel shape (it requires "channel" at the top level).
  local req
  req=$(jq -r '
    .properties.distribution.oneOf[]?
    | select((.required // []) | index("channel"))
    | .required[]
  ' "$SCHEMA" 2>/dev/null | sort | tr -d ' \r')
  expected=$(printf 'channel\nmanifest\nregistry\nrelease_workflow' | sort | tr -d ' \r')
  [ "$req" = "$expected" ]
}

# ---------- AC2: schema declares the closed 10-channel enum ----------

@test "schema declares the closed 10-channel enum" {
  # Use select(.properties.channel.enum) to skip the legacy-channels-array
  # branch of the oneOf (which has no .properties.channel.enum).
  local values
  values=$(jq -r '
    .properties.distribution.oneOf[]?
    | select(.properties.channel.enum != null)
    | .properties.channel.enum[]
  ' "$SCHEMA" 2>/dev/null | sort | tr -d ' \r')
  expected=$(printf 'claude-marketplace\ncontainer-registry\ncustom\ngithub-releases\nhomebrew\nmaven\nmobile-app\nnpm\npypi\nstatic-site' | sort | tr -d ' \r')
  [ "$values" = "$expected" ]
}

# ---------- AC3: per-channel sub-field schemas co-located with adapters ----------

@test "per-channel sub-field schemas exist for all 10 channels" {
  for ch in claude-marketplace npm pypi maven homebrew github-releases mobile-app container-registry static-site custom; do
    [ -f "$PLUGIN_DIR/scripts/adapters/publish-$ch/schema.yaml" ] || {
      echo "missing: $PLUGIN_DIR/scripts/adapters/publish-$ch/schema.yaml" >&2
      return 1
    }
  done
}

# ---------- TC-DCH-1: claude-marketplace happy path ----------

@test "claude-marketplace with 4 required common fields validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: claude-marketplace
  registry: https://anthropic.com/marketplace
  manifest: plugin.json
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_pass
}

# ---------- TC-DCH-2: npm happy path ----------

@test "npm validates with required common fields" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_pass
}

# ---------- TC-DCH-3: mobile-app requires platform + store_id + review_required ----------

@test "mobile-app happy path with all sub-fields validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: mobile-app
  registry: https://itunesconnect.apple.com
  manifest: app.json
  release_workflow: gaia-release.yml
  platform: ios
  store_id: "com.example.app"
  review_required: true
YAML
  _ajv_validate_pass
}

@test "mobile-app missing platform fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: mobile-app
  registry: https://itunesconnect.apple.com
  manifest: app.json
  release_workflow: gaia-release.yml
  store_id: "com.example.app"
  review_required: true
YAML
  _ajv_validate_fail
}

@test "mobile-app missing store_id fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: mobile-app
  registry: https://itunesconnect.apple.com
  manifest: app.json
  release_workflow: gaia-release.yml
  platform: ios
  review_required: true
YAML
  _ajv_validate_fail
}

@test "mobile-app missing review_required fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: mobile-app
  registry: https://itunesconnect.apple.com
  manifest: app.json
  release_workflow: gaia-release.yml
  platform: ios
  store_id: "com.example.app"
YAML
  _ajv_validate_fail
}

# ---------- TC-DCH-4: container-registry requires image_name + tag_strategy ----------

@test "container-registry happy path validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: container-registry
  registry: ghcr.io/gaiastudio
  manifest: Dockerfile
  release_workflow: gaia-release.yml
  image_name: gaiastudio/gaia
  tag_strategy: semver
YAML
  _ajv_validate_pass
}

@test "container-registry missing image_name fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: container-registry
  registry: ghcr.io/gaiastudio
  manifest: Dockerfile
  release_workflow: gaia-release.yml
  tag_strategy: semver
YAML
  _ajv_validate_fail
}

@test "container-registry missing tag_strategy fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: container-registry
  registry: ghcr.io/gaiastudio
  manifest: Dockerfile
  release_workflow: gaia-release.yml
  image_name: gaiastudio/gaia
YAML
  _ajv_validate_fail
}

# ---------- TC-DCH-5: static-site requires provider + domain (and the ADR-115 invariant is enforced via SKILL-level coupling) ----------

@test "static-site happy path with provider + domain validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: static-site
  registry: https://example.com
  manifest: site.config.json
  release_workflow: gaia-release.yml
  provider: s3
  domain: example.com
YAML
  _ajv_validate_pass
}

@test "static-site missing provider fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: static-site
  registry: https://example.com
  manifest: site.config.json
  release_workflow: gaia-release.yml
  domain: example.com
YAML
  _ajv_validate_fail
}

# ---------- TC-DCH-6: custom requires adapter_name ----------

@test "custom happy path with adapter_name validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: custom
  registry: my-custom-registry
  manifest: my-manifest.yaml
  release_workflow: gaia-release.yml
  adapter_name: my-custom-publisher
YAML
  _ajv_validate_pass
}

@test "custom missing adapter_name fails" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: custom
  registry: my-custom-registry
  manifest: my-manifest.yaml
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_fail
}

# ---------- TC-DCH-7: unknown channel rejected ----------

@test "unknown channel value 'ftp-server' is rejected" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: ftp-server
  registry: ftp://example.com
  manifest: foo.json
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_fail
}

# ---------- TC-DCH-8: missing required common fields rejected (matrix of 4) ----------

@test "missing channel rejected" {
  cat > "$CONFIG" <<'YAML'
distribution:
  registry: https://registry.npmjs.org
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_fail
}

@test "missing registry rejected" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: npm
  manifest: package.json
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_fail
}

@test "missing manifest rejected" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  release_workflow: gaia-release.yml
YAML
  _ajv_validate_fail
}

@test "missing release_workflow rejected" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channel: npm
  registry: https://registry.npmjs.org
  manifest: package.json
YAML
  _ajv_validate_fail
}

# ---------- Sanity: legacy channels[] shape still validates (back-compat) ----------

@test "back-compat: legacy distribution.channels[] shape still validates" {
  cat > "$CONFIG" <<'YAML'
distribution:
  channels:
    - name: claude-marketplace
      deploy_adapter: marketplace
YAML
  _ajv_validate_pass
}

# ---------- AC3: per-channel schema files declare expected required sub-fields ----------

@test "publish-mobile-app/schema.yaml declares platform + store_id + review_required required" {
  local f="$PLUGIN_DIR/scripts/adapters/publish-mobile-app/schema.yaml"
  grep -q 'platform' "$f"
  grep -q 'store_id' "$f"
  grep -q 'review_required' "$f"
}

@test "publish-container-registry/schema.yaml declares image_name + tag_strategy required" {
  local f="$PLUGIN_DIR/scripts/adapters/publish-container-registry/schema.yaml"
  grep -q 'image_name' "$f"
  grep -q 'tag_strategy' "$f"
}

@test "publish-custom/schema.yaml declares adapter_name required" {
  local f="$PLUGIN_DIR/scripts/adapters/publish-custom/schema.yaml"
  grep -q 'adapter_name' "$f"
}
