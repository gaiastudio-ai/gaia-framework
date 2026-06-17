#!/usr/bin/env bats
# plugin-version-lockstep.bats — E97-S7
#
# Asserts:
#  - plugin.json `version` field and .plugin-version agree byte-for-byte
#  - release.yml maintains .plugin-version alongside plugin.json
#  - validator.md still cites .plugin-version as the persona_sig anchor

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  REPO_ROOT="$( cd "$PLUGIN_DIR/../.." && pwd )"
}

teardown() {
  common_teardown
}

@test ".plugin-version exists and is semver-shaped" {
  [ -f "$PLUGIN_DIR/.plugin-version" ]
  run cat "$PLUGIN_DIR/.plugin-version"
  [ "$status" -eq 0 ]
  # Match X.Y.Z (allowing optional rc / pre-release suffix)
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]
}

@test ".plugin-version and plugin.json agree on the version string" {
  local plugin_version
  plugin_version="$(cat "$PLUGIN_DIR/.plugin-version" | tr -d '[:space:]')"
  local json_version
  json_version="$(grep -E '^[[:space:]]*"version":' "$PLUGIN_DIR/.claude-plugin/plugin.json" \
    | head -1 \
    | sed -E 's/.*"version":[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$plugin_version" ]
  [ -n "$json_version" ]
  [ "$plugin_version" = "$json_version" ]
}

@test "release.yml maintains .plugin-version alongside plugin.json" {
  local rel="$REPO_ROOT/.github/workflows/release.yml"
  [ -f "$rel" ]
  # The `git add` line in the release-PR step must stage .plugin-version too.
  run grep -E 'git add.*\.plugin-version' "$rel"
  [ "$status" -eq 0 ]
}

@test "release.yml writes .plugin-version with the bumped version" {
  local rel="$REPO_ROOT/.github/workflows/release.yml"
  # Some step must echo / printf / write the bumped version into .plugin-version.
  run grep -E '(\.plugin-version|plugin-version)' "$rel"
  [ "$status" -eq 0 ]
  # Look for "echo|printf|tee" + .plugin-version pattern
  run grep -E '(echo|printf|tee).*\.plugin-version' "$rel"
  [ "$status" -eq 0 ]
}

@test "validator.md still cites .plugin-version as persona_sig anchor" {
  # E89-S4 invariant — ensure we did not break the persona_sig contract.
  run grep -F '.plugin-version' "$PLUGIN_DIR/agents/validator.md"
  [ "$status" -eq 0 ]
  # The "dev" fallback contract is preserved
  run grep -F 'echo dev' "$PLUGIN_DIR/agents/validator.md"
  [ "$status" -eq 0 ]
}
