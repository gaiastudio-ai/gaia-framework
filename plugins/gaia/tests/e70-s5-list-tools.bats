#!/usr/bin/env bats
# e70-s5-list-tools.bats — E70-S5 AC1, AC2: /gaia-list-tools enumeration
#
# Verifies the list-adapters.sh helper backing /gaia-list-tools:
#   - Discovers adapters under built-in (BUILTIN_ADAPTERS_DIR) and project-local
#     (CUSTOM_ADAPTERS_DIR) roots.
#   - Renders a category-grouped table with name, version, provider, runtime-profile,
#     and a three-state availability slot.
#   - Honours custom-over-built-in precedence: custom adapter shows [custom]
#     badge; shadowed built-in shows [shadowed].
#   - Exits 0 on a successful enumeration even when no adapters are found.
#
# Story: E70-S5  (TC-RSV2-QUERY-01, TC-RSV2-QUERY-02)
# Refs:  FR-RSV2-21, FR-RSV2-10

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LIST_TOOLS="$PLUGIN_DIR/scripts/list-adapters.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# Build a fixture adapter directory at $1 with a single adapter named $2,
# category $3, provider $4, version $5.
_make_adapter() {
  local root="$1" name="$2" cat="$3" prov="$4" ver="$5"
  mkdir -p "$root/$name"
  cat >"$root/$name/adapter.json" <<JSON
{
  "provider": "$prov",
  "category": "$cat",
  "runtime-profile": "subprocess",
  "default-timeout-seconds": 30,
  "file-extensions": [".py"],
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

@test "list-adapters.sh enumerates built-in adapters with name, version, provider, runtime-profile" {
  local builtin="$TEST_TMP/builtin"
  mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"
  _make_adapter "$builtin" gitleaks secret-scan gitleaks ">=8.0.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_LIST_TOOLS_SKIP_PROBE=1 "$LIST_TOOLS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "semgrep"
  echo "$output" | grep -q "gitleaks"
  echo "$output" | grep -q ">=1.0.0"
  echo "$output" | grep -q "subprocess"
}

@test "empty adapter directory emits a 'No adapters found' notice and exits 0" {
  local builtin="$TEST_TMP/builtin-empty"
  mkdir -p "$builtin"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_LIST_TOOLS_SKIP_PROBE=1 "$LIST_TOOLS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "No adapters found"
}

@test "custom adapter shadows built-in — custom shows [custom], built-in shows [shadowed]" {
  local builtin="$TEST_TMP/builtin"
  local custom="$TEST_TMP/custom"
  mkdir -p "$builtin" "$custom"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"
  _make_adapter "$custom"  semgrep sast semgrep ">=1.50.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$custom" \
    GAIA_LIST_TOOLS_SKIP_PROBE=1 "$LIST_TOOLS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[custom\]"
  echo "$output" | grep -q "\[shadowed\]"
}

@test "malformed adapter.json is skipped with a warning, listing continues" {
  local builtin="$TEST_TMP/builtin"
  mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep sast semgrep ">=1.0.0"
  mkdir -p "$builtin/broken"
  printf '{ this is not valid json' >"$builtin/broken/adapter.json"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$builtin/broken/run.sh"
  chmod +x "$builtin/broken/run.sh"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_LIST_TOOLS_SKIP_PROBE=1 "$LIST_TOOLS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "semgrep"
  # broken should NOT appear as a normal row; warning surfaces in combined output.
  echo "$output" | grep -qi "broken"
}

@test "output is grouped by category — same category clusters together" {
  local builtin="$TEST_TMP/builtin"
  mkdir -p "$builtin"
  _make_adapter "$builtin" semgrep   sast        semgrep   ">=1.0.0"
  _make_adapter "$builtin" gitleaks  secret-scan gitleaks  ">=8.0.0"
  _make_adapter "$builtin" radon     linter      radon     ">=5.0.0"

  run env BUILTIN_ADAPTERS_DIR="$builtin" CUSTOM_ADAPTERS_DIR="$TEST_TMP/no-custom" \
    GAIA_LIST_TOOLS_SKIP_PROBE=1 "$LIST_TOOLS"
  [ "$status" -eq 0 ]
  # Category headers (one per distinct category) must appear in the output.
  echo "$output" | grep -qi "sast"
  echo "$output" | grep -qi "secret-scan"
  echo "$output" | grep -qi "linter"
}
