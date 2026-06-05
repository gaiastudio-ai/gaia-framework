#!/usr/bin/env bats
# plugin-version-resolution.bats — E89-S4 .plugin-version semver-tagged persona_sig.
#
# Covers TC-AFE-13..14 (foundation-level):
#   TC-AFE-13: .plugin-version reference idiom returns VERSION=<semver> when present.
#   TC-AFE-14a: idiom falls back to VERSION=dev when .plugin-version is absent.
#   TC-AFE-14b: actual plugin .plugin-version file exists and is semver-shaped.
#   TC-AFE-14c: validator.md documents the .plugin-version + dev fallback contract.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_DIR
}

teardown() {
  common_teardown
}

# Reference compute idiom from validator.md L74-76 (extracted for testability).
_compute_version() {
  local plugin_dir="$1"
  cat "$plugin_dir/.plugin-version" 2>/dev/null || echo dev
}

# ---------------- TC-AFE-13: idiom returns VERSION=<semver> when present ----------------
@test "TC-AFE-13: reference idiom returns the semver when .plugin-version is present" {
  local fake_plugin="$TEST_TMP/fake-plugin"
  mkdir -p "$fake_plugin"
  printf '%s' "1.152.0" > "$fake_plugin/.plugin-version"
  local result
  result="$(_compute_version "$fake_plugin")"
  [ "$result" = "1.152.0" ]
}

# ---------------- TC-AFE-14a: dev fallback when absent ----------------
@test "TC-AFE-14a: reference idiom falls back to 'dev' when .plugin-version is absent" {
  local fake_plugin="$TEST_TMP/fake-plugin-no-version"
  mkdir -p "$fake_plugin"
  local result
  result="$(_compute_version "$fake_plugin")"
  [ "$result" = "dev" ]
}

# ---------------- TC-AFE-14b: actual plugin .plugin-version exists + semver-shaped ----------------
@test "TC-AFE-14b: plugin .plugin-version exists and is semver-shaped" {
  [ -f "$PLUGIN_DIR/.plugin-version" ]
  local content
  content="$(cat "$PLUGIN_DIR/.plugin-version")"
  # Match X.Y.Z (no pre-release suffix expected post-E89-S4).
  [[ "$content" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ---------------- TC-AFE-14c: validator.md documents the contract ----------------
@test "TC-AFE-14c: validator.md documents the .plugin-version + dev fallback contract" {
  local validator_md="$PLUGIN_DIR/agents/validator.md"
  [ -f "$validator_md" ]
  grep -qF ".plugin-version" "$validator_md"
  grep -qF "dev" "$validator_md"
  grep -qF "defensive default" "$validator_md"
}

# ---------------- TC-AFE-14d: persona_sig pattern regex ----------------
@test "TC-AFE-14d: persona_sig pattern matches val-<semver>-<digest>" {
  local plugin_version
  plugin_version="$(cat "$PLUGIN_DIR/.plugin-version")"
  # Simulated persona_sig (the actual digest comes from validator.md sha256).
  local fake_digest="61bc6591202bbced"
  local persona_sig="val-${plugin_version}-${fake_digest}"
  [[ "$persona_sig" =~ ^val-[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]+$ ]]
}

# ---------------- TC-AFE-14e: version-bump.js documents .plugin-version write ----------------
@test "TC-AFE-14e: version-bump.js writes .plugin-version alongside plugin.json" {
  local bump_js="$PLUGIN_DIR/../../scripts/version-bump.js"
  [ -f "$bump_js" ]
  grep -qF "PLUGIN_VERSION_REL" "$bump_js"
  grep -qF ".plugin-version" "$bump_js"
}
