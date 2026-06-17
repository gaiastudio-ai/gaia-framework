#!/usr/bin/env bats
# e70-s5-tool-info.bats — E70-S5 AC3, AC4, AC5: /gaia-tool-info
#
# Verifies the tool-info.sh helper backing /gaia-tool-info <name>:
#   - Prints all required adapter.json fields (provider, category, version-range,
#     runtime-profile, default-timeout-seconds, file-extensions, description).
#   - Includes an availability slot for the probe result.
#   - Honours custom-over-built-in precedence: a custom adapter wins when both exist.
#   - Unknown adapter name exits non-zero with an actionable error listing
#     available adapter names.
#
# Story: E70-S5  (TC-RSV2-QUERY-03, TC-RSV2-QUERY-04, TC-RSV2-QUERY-05)

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL_INFO="$PLUGIN_DIR/scripts/tool-info.sh"

setup() { common_setup; }
teardown() { common_teardown; }

_make_adapter() {
  local root="$1" name="$2" cat="$3" prov="$4" ver="$5"
  mkdir -p "$root/$name"
  cat >"$root/$name/adapter.json" <<JSON
{
  "provider": "$prov",
  "category": "$cat",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": 42,
  "file-extensions": [".py", ".js"],
  "version-range": "$ver",
  "description": "$name fixture adapter"
}
JSON
  cat >"$root/$name/run.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/$name/run.sh"
}

@test "gaia-tool-info <name> renders all required adapter.json fields" {
  local builtin="$TEST_TMP/builtin"; mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_TOOL_INFO_SKIP_PROBE=1 "$TOOL_INFO" semgrep
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "semgrep"
  echo "$output" | grep -q "sast"
  echo "$output" | grep -q ">=1.0.0"
  echo "$output" | grep -q "subprocess"
  echo "$output" | grep -q "42"
  echo "$output" | grep -q '\.py'
  echo "$output" | grep -qi "fixture adapter"
}

@test "gaia-tool-info <name> output includes an availability slot" {
  local builtin="$TEST_TMP/builtin"; mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_TOOL_INFO_SKIP_PROBE=1 "$TOOL_INFO" semgrep
  [ "$status" -eq 0 ]
  # availability label appears even when probe is skipped (slot is rendered).
  echo "$output" | grep -qi "availability"
}

@test "unknown adapter exits non-zero and lists available adapters" {
  local builtin="$TEST_TMP/builtin"; mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep  sast        semgrep  ">=1.0.0"
  _make_adapter "$builtin" gitleaks secret-scan gitleaks ">=8.0.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_TOOL_INFO_SKIP_PROBE=1 "$TOOL_INFO" no-such-tool
  [ "$status" -ne 0 ]
  # Error must enumerate the available adapter names so the user can self-correct.
  echo "$output" | grep -q "semgrep"
  echo "$output" | grep -q "gitleaks"
}

@test "custom adapter wins over built-in when both exist" {
  local builtin="$TEST_TMP/builtin"; local custom="$TEST_TMP/custom"
  mkdir -p "$builtin" "$custom"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"
  _make_adapter "$custom"  semgrep sast semgrep ">=1.50.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$custom" \
    GAIA_TOOL_INFO_SKIP_PROBE=1 "$TOOL_INFO" semgrep
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ">=1.50.0"
}
