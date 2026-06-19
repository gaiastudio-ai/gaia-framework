#!/usr/bin/env bats
# test-manual-surface-adapter.bats — AC1: 4 surfaces selectable via runtime profile
#
# Validates that surface-adapter.sh exposes browser, api, mobile, desktop
# surfaces and returns CONFIGURED (exit 0) when the corresponding platform
# or sprint_review category is present in the project config.
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  ADAPTER="$PLUGIN_DIR/skills/gaia-test-manual/scripts/surface-adapter.sh"

  TEST_TMP="$(mktemp -d)"

  # Minimal config with all 4 surfaces configured
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web, server, ios]
sprint_review:
  desktop_commands:
    electron:
      command: "echo desktop-test"
YAML
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- AC1: All 4 surfaces selectable ----------

@test "browser surface returns CONFIGURED when web platform present" {
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

@test "api surface returns CONFIGURED when server platform present" {
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

@test "mobile surface returns CONFIGURED when ios platform present" {
  run bash "$ADAPTER" --surface mobile --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

@test "mobile surface returns CONFIGURED when android platform present" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [android]
YAML
  run bash "$ADAPTER" --surface mobile --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

@test "desktop surface returns CONFIGURED when desktop_commands present" {
  run bash "$ADAPTER" --surface desktop --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

@test "unknown surface returns error exit 1" {
  run bash "$ADAPTER" --surface hologram --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 1 ]
}

@test "missing --surface flag returns error exit 1" {
  run bash "$ADAPTER" --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 1 ]
}

@test "output contains surface name on CONFIGURED" {
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "api"
}

# ---------- AC1: block-style YAML platforms ----------

@test "browser CONFIGURED with block-style YAML platforms list" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms:
  - web
  - server
YAML
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "CONFIGURED"
}

@test "api CONFIGURED with block-style YAML platforms list" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms:
  - web
  - server
YAML
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "CONFIGURED"
}
