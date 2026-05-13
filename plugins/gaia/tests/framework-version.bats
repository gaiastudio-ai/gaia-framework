#!/usr/bin/env bats
# framework-version.bats — unit tests for the extracted framework-version.sh
# library (E86-S1).
#
# Story: E86-S1 — Shared `lib/framework-version.sh` extraction from
#                  `template-header.sh`.
# Traces: FR-472, TC-FVD-41..TC-FVD-44, SR-60.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  LIB_SRC="$BATS_TEST_DIRNAME/../scripts/lib/framework-version.sh"
  TEMPLATE_HEADER="$BATS_TEST_DIRNAME/../scripts/template-header.sh"
  REAL_PLUGIN_JSON="$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json"
  # The library resolves plugin.json via `$here/../../.claude-plugin/plugin.json`
  # where $here is the dir of the library file. Mirror that structure: stage
  # the lib at $TEST_TMP/plugins/gaia/scripts/lib/framework-version.sh and the
  # manifest at $TEST_TMP/plugins/gaia/.claude-plugin/plugin.json.
  STAGED_LIB="$TEST_TMP/plugins/gaia/scripts/lib/framework-version.sh"
  STAGED_MANIFEST="$TEST_TMP/plugins/gaia/.claude-plugin/plugin.json"
  mkdir -p "$TEST_TMP/plugins/gaia/scripts/lib" "$TEST_TMP/plugins/gaia/.claude-plugin"
}
teardown() { common_teardown; }

@test "AC1 / TC-FVD-41: source + call outputs valid semver + exit 0" {
  [ -f "$LIB_SRC" ]
  run bash -c "source '$LIB_SRC' && resolve_framework_version"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "AC1: output matches the version field in plugin.json (plugin.json fallback path)" {
  # AC1 asserts the version output matches plugin.json. The library prefers
  # resolve-config.sh when available (which may return a stale project value
  # — that drift is the subject of E86-S2). Test the plugin.json fallback
  # path by staging the lib + manifest in isolation, with no co-located
  # resolve-config.sh.
  cp "$LIB_SRC" "$STAGED_LIB"
  cp "$REAL_PLUGIN_JSON" "$STAGED_MANIFEST"
  expected="$(python3 -c "import json; print(json.load(open('$REAL_PLUGIN_JSON'))['version'])")"
  run --separate-stderr bash -c "PATH=/usr/bin:/bin source '$STAGED_LIB' && resolve_framework_version"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "AC2 / TC-FVD-42: missing plugin.json returns exit 1, stderr diagnostic" {
  cp "$LIB_SRC" "$STAGED_LIB"
  run --separate-stderr bash -c "PATH=/usr/bin:/bin source '$STAGED_LIB' && resolve_framework_version"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"plugin.json"* ]] || [[ "$output" == *"plugin.json"* ]]
}

@test "AC3 / TC-FVD-43: empty version field returns exit 2" {
  cp "$LIB_SRC" "$STAGED_LIB"
  cat > "$STAGED_MANIFEST" <<JSON
{
  "name": "gaia",
  "version": ""
}
JSON
  run --separate-stderr bash -c "PATH=/usr/bin:/bin source '$STAGED_LIB' && resolve_framework_version"
  [ "$status" -eq 2 ]
}

@test "AC3: absent version key returns exit 2" {
  cp "$LIB_SRC" "$STAGED_LIB"
  cat > "$STAGED_MANIFEST" <<JSON
{
  "name": "gaia"
}
JSON
  run --separate-stderr bash -c "PATH=/usr/bin:/bin source '$STAGED_LIB' && resolve_framework_version"
  [ "$status" -eq 2 ]
}

@test "AC4 / TC-FVD-44: source guard prevents double-source side effects" {
  run bash -c "
    source '$LIB_SRC'
    first_guard=\$_FRAMEWORK_VERSION_SH_SOURCED
    source '$LIB_SRC'
    second_guard=\$_FRAMEWORK_VERSION_SH_SOURCED
    [ \"\$first_guard\" = '1' ] && [ \"\$second_guard\" = '1' ] && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "AC5: GAIA_FRAMEWORK_VERSION is exported after successful resolve" {
  run bash -c "
    source '$LIB_SRC'
    resolve_framework_version >/dev/null
    echo \"GFV=\$GAIA_FRAMEWORK_VERSION\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ GFV=[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "AC6 (SR-60): trust-boundary doc comment block present" {
  grep -qE "(trust boundary|SR-60|plugin distribution)" "$LIB_SRC"
}

@test "AC7: template-header.sh does NOT define resolve_framework_version()" {
  # `grep -c` exits 1 on zero matches but prints "0" anyway. Use grep -q
  # against the function-definition pattern (followed by `{` or whitespace);
  # AC7 wants ZERO definitions (the function is now in the lib).
  ! grep -qE 'resolve_framework_version[[:space:]]*\(\)[[:space:]]*\{' "$TEMPLATE_HEADER"
}

@test "AC8: framework-version.sh defines resolve_framework_version()" {
  grep -qE 'resolve_framework_version[[:space:]]*\(\)[[:space:]]*\{' "$LIB_SRC"
}

@test "Backward compat: template-header.sh emits a framework_version line" {
  run bash -c "
    cd '$TEST_TMP'
    '$TEMPLATE_HEADER' --workflow test --template test
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ framework_version:[[:space:]][0-9]+\.[0-9]+\.[0-9]+ ]]
}
