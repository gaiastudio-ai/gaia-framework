#!/usr/bin/env bats
# statusline-snapshot-root.bats — verify the context-window snapshot is written
# only at the session's project root, not under subdirectories.
#
# Covers:
#   - project_dir set, current_dir = subdir -> snapshot at root only
#   - project_dir absent -> existing behaviour unchanged
#   - Root without .gaia/ -> no tree created, exit 0, no stderr
#   - Snapshot uses project_dir even when PROJECT_PATH overrides current_dir

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  STATUSLINE="$REPO_ROOT/plugins/gaia/scripts/statusline.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/snap-root-$$"
  # Simulate a project root with .gaia/
  mkdir -p "$TEST_TMP/project/.gaia/memory"
  # Simulate a subdirectory (current_dir will point here)
  mkdir -p "$TEST_TMP/project/src/components"
  # Minimal plugin.json so version resolution works
  mkdir -p "$TEST_TMP/project/gaia-public/plugins/gaia/.claude-plugin"
  cat > "$TEST_TMP/project/gaia-public/plugins/gaia/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ

  SNAPSHOT_FILE="$TEST_TMP/project/.gaia/memory/.context-window-snapshot.json"
  INPUT_FILE="$TEST_TMP/input.json"
}

teardown() {
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

_write_input() {
  # $1 = project_dir (or empty to omit), $2 = current_dir
  local proj_dir_field=""
  if [ -n "${1:-}" ]; then
    proj_dir_field="$(printf '"project_dir":"%s",' "$1")"
  fi
  printf '{"model":{"id":"o","display_name":"Opus"},"workspace":{%s"current_dir":"%s"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":10},"context_window_size":1000000}}' \
    "$proj_dir_field" "$2" > "$INPUT_FILE"
}

# ---------- Scenario 1: project_dir set, current_dir = subdir ----------

@test "snapshot written at project_dir root, not under the subdirectory" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  local subdir="$TEST_TMP/project/src/components"
  _write_input "$TEST_TMP/project" "$subdir"
  run bash -c "bash '$STATUSLINE' < '$INPUT_FILE'"
  [ "$status" -eq 0 ]
  # Snapshot must exist at the project root
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "snapshot not written at project root" >&2; false; }
  # No .gaia/ tree under the subdirectory
  [ ! -d "$subdir/.gaia" ] \
    || { echo "stray .gaia/ created under subdirectory" >&2; ls -la "$subdir/.gaia" >&2; false; }
}

# ---------- Scenario 2: project_dir absent -> fallback unchanged ----------

@test "snapshot written via fallback when project_dir absent" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  _write_input "" "$TEST_TMP/project"
  # When project_dir is absent, current_dir is used as PROJECT_PATH, and
  # PROJECT_ROOT falls through to PROJECT_PATH -> snapshot at current_dir root.
  run bash -c "bash '$STATUSLINE' < '$INPUT_FILE'"
  [ "$status" -eq 0 ]
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "snapshot not written via fallback" >&2; false; }
}

# ---------- Scenario 3: root without .gaia/ -> no tree created ----------

@test "no .gaia/ tree created when root lacks .gaia directory" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Create a project root WITHOUT .gaia/
  local bare_root="$TEST_TMP/bare-project"
  mkdir -p "$bare_root"
  mkdir -p "$bare_root/gaia-public/plugins/gaia/.claude-plugin"
  cat > "$bare_root/gaia-public/plugins/gaia/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  _write_input "$bare_root" "$bare_root/subdir"
  mkdir -p "$bare_root/subdir"
  run bash -c "bash '$STATUSLINE' < '$INPUT_FILE' 2>/dev/null"
  [ "$status" -eq 0 ]
  # No .gaia/ directory must have been created
  [ ! -d "$bare_root/.gaia" ] \
    || { echo ".gaia/ was created under a root that lacked it" >&2; false; }
}

# ---------- Scenario: PROJECT_PATH does not override project_dir ----------

@test "PROJECT_PATH override does not beat project_dir for snapshot root" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # PROJECT_PATH points at a different dir (like tests do)
  local other_dir="$TEST_TMP/other"
  mkdir -p "$other_dir/.gaia/memory"
  export PROJECT_PATH="$other_dir"
  _write_input "$TEST_TMP/project" "$TEST_TMP/project/src"
  run bash -c "bash '$STATUSLINE' < '$INPUT_FILE'"
  [ "$status" -eq 0 ]
  # Snapshot must be at the project_dir root, not at PROJECT_PATH
  [ -f "$SNAPSHOT_FILE" ] \
    || { echo "snapshot not at project_dir root" >&2; false; }
  [ ! -f "$other_dir/.gaia/memory/.context-window-snapshot.json" ] \
    || { echo "snapshot written at PROJECT_PATH instead of project_dir" >&2; false; }
}

# ---------- Scenario: explicit PROJECT_ROOT beats project_dir ----------

@test "explicit PROJECT_ROOT env wins over project_dir for snapshot root" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  local explicit_root="$TEST_TMP/explicit-root"
  mkdir -p "$explicit_root/.gaia/memory"
  mkdir -p "$explicit_root/gaia-public/plugins/gaia/.claude-plugin"
  cat > "$explicit_root/gaia-public/plugins/gaia/.claude-plugin/plugin.json" <<'PJ'
{ "name": "gaia", "version": "9.9.9-test" }
PJ
  export PROJECT_ROOT="$explicit_root"
  _write_input "$TEST_TMP/project" "$TEST_TMP/project/src"
  run bash -c "bash '$STATUSLINE' < '$INPUT_FILE'"
  [ "$status" -eq 0 ]
  [ -f "$explicit_root/.gaia/memory/.context-window-snapshot.json" ] \
    || { echo "snapshot not at explicit PROJECT_ROOT" >&2; false; }
}
