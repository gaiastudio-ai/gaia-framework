#!/usr/bin/env bats
# e77-s16-plugin-detection.bats — E77-S16 / FR-420 / AC4
#
# plugin-detection.sh scans a project root and emits JSON describing whether
# the project is a Claude Code plugin. Classification rule: 3+ co-occurring
# signals out of {SKILL.md files, adapter.json files, plugin manifest at
# `.claude-plugin/plugin.json` or `manifest.yaml`, commands/*.md directory,
# `settings.json` with hooks/permissions, `.claude/` directory}. Single-
# signal projects MUST NOT be classified as plugins (false-positive guard).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_DETECT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/plugin-detection.sh"

@test "3+ signals (SKILL.md + adapter.json + manifest) classifies as plugin" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo" "$proj/scripts/adapters/bar" "$proj/.claude-plugin"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  echo '{}' > "$proj/scripts/adapters/bar/adapter.json"
  echo '{"name":"x","version":"0.1.0"}' > "$proj/.claude-plugin/plugin.json"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": true'* ]]
  [[ "$output" == *'"signal_count": 3'* ]]
}

@test "single signal (only SKILL.md) does NOT classify as plugin" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": false'* ]]
  [[ "$output" == *'"signal_count": 1'* ]]
}

@test "two signals (SKILL.md + adapter.json) does NOT classify as plugin" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo" "$proj/scripts/adapters/bar"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  echo '{}' > "$proj/scripts/adapters/bar/adapter.json"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": false'* ]]
  [[ "$output" == *'"signal_count": 2'* ]]
}

@test "zero signals — empty project — emits is_plugin=false, signal_count=0" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": false'* ]]
  [[ "$output" == *'"signal_count": 0'* ]]
}

@test "4 signals (SKILL.md + adapter.json + manifest + commands/) classifies as plugin" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo" "$proj/scripts/adapters/bar" "$proj/.claude-plugin" "$proj/commands"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  echo '{}' > "$proj/scripts/adapters/bar/adapter.json"
  echo '{"name":"x"}' > "$proj/.claude-plugin/plugin.json"
  echo '# command' > "$proj/commands/foo.md"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": true'* ]]
  [[ "$output" == *'"signal_count": 4'* ]]
}

@test "manifest.yaml at project root counts as a manifest signal" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo" "$proj/scripts/adapters/bar"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  echo '{}' > "$proj/scripts/adapters/bar/adapter.json"
  printf 'name: foo\nversion: 0.1.0\n' > "$proj/manifest.yaml"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"is_plugin": true'* ]]
}

@test "emits a 'signals' array listing each matched signal name" {
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/plugins/foo" "$proj/scripts/adapters/bar" "$proj/.claude-plugin"
  echo '---' > "$proj/plugins/foo/SKILL.md"
  echo '{}' > "$proj/scripts/adapters/bar/adapter.json"
  echo '{}' > "$proj/.claude-plugin/plugin.json"
  run "$PLUGIN_DETECT" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"signals":'* ]]
  [[ "$output" == *'skill_md'* ]]
  [[ "$output" == *'adapter_json'* ]]
  [[ "$output" == *'plugin_manifest'* ]]
}

@test "missing --project-root prints actionable error and exits 1" {
  run "$PLUGIN_DETECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--project-root"* ]]
}

@test "non-existent project root exits 1 with directory error" {
  run "$PLUGIN_DETECT" --project-root "$TEST_TMP/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"directory"* ]]
}
