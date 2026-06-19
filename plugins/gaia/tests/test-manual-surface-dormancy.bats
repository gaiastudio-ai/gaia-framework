#!/usr/bin/env bats
# test-manual-surface-dormancy.bats — AC2: unconfigured surface is SKIPPED
#
# Validates that a surface whose platform/category is NOT in the project
# config returns SKIPPED (exit 2), stdout contains "not configured", and
# the output does NOT contain UNVERIFIED or FAILED.
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  ADAPTER="$PLUGIN_DIR/skills/gaia-test-manual/scripts/surface-adapter.sh"

  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/.gaia/config"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------- AC2: browser SKIPPED when web not in platforms ----------

@test "browser SKIPPED when web not in platforms" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
}

@test "browser SKIPPED output contains 'not configured'" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "not configured"
}

@test "browser SKIPPED output does not contain UNVERIFIED" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  ! echo "$output" | grep -qi "UNVERIFIED"
}

@test "browser SKIPPED output does not contain FAILED" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [server]
YAML
  run bash "$ADAPTER" --surface browser --config "$TEST_TMP/.gaia/config/project-config.yaml"
  ! echo "$output" | grep -qi "FAILED"
}

# ---------- AC2: api SKIPPED when server not in platforms ----------

@test "api SKIPPED when server not in platforms" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
YAML
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
}

@test "api SKIPPED exit code is exactly 2 not 1" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web]
YAML
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
  [ "$status" -ne 1 ]
}

# ---------- AC2: mobile SKIPPED when neither ios nor android ----------

@test "mobile SKIPPED when neither ios nor android in platforms" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web, server]
YAML
  run bash "$ADAPTER" --surface mobile --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
}

# ---------- AC2: desktop SKIPPED when no desktop_commands ----------

@test "desktop SKIPPED when no desktop_commands section" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web, server]
YAML
  run bash "$ADAPTER" --surface desktop --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
}

@test "desktop SKIPPED when desktop_commands is empty" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
platforms: [web, server]
sprint_review:
  desktop_commands: {}
YAML
  run bash "$ADAPTER" --surface desktop --config "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 2 ]
}

# ---------- AC2: empty platforms list → all platform-keyed surfaces SKIPPED ----------

@test "all surfaces SKIPPED when config has no platforms and no desktop_commands" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project_name: test-project
YAML
  for surface in browser api mobile desktop; do
    run bash "$ADAPTER" --surface "$surface" --config "$TEST_TMP/.gaia/config/project-config.yaml"
    [ "$status" -eq 2 ]
  done
}
