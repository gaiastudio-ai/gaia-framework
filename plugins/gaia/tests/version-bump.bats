#!/usr/bin/env bats
# version-bump.bats — acceptance tests for the project-generic version-bump.js
#
# Tests the five ATDD scenarios for the release version-bump orchestrator:
#   1. Multi-file bump from release.version_files[] config
#   2. Native-format write (JSON + plain-text)
#   3. resolve-config.sh repo-root + subdir discovery
#   4. Missing release.version_files[] → clear error naming the key
#   5. Machine-readable summary output on success
#
# All tests use $TEST_TMP fixtures — never touches the working tree.

load 'test_helper.bash'

setup() {
  common_setup

  # Locate the version-bump.js script under the release skill's scripts/ dir.
  VERSION_BUMP_JS="${BATS_TEST_DIRNAME}/../skills/gaia-release/scripts/version-bump.js"
  export VERSION_BUMP_JS

  # Locate resolve-config.sh (existing foundation script).
  RESOLVE_CONFIG="${BATS_TEST_DIRNAME}/../scripts/resolve-config.sh"
  export RESOLVE_CONFIG
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Helper: scaffold a minimal project fixture in $TEST_TMP
# ---------------------------------------------------------------------------
_scaffold_project() {
  local ver="${1:-1.2.3}"

  # project-config.yaml with release.version_files[]
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"

release:
  version_files:
    - plugin.json
    - VERSION
    - package.json
YAML

  # JSON version file: plugin.json
  cat > "$TEST_TMP/plugin.json" <<JSON
{
  "name": "my-plugin",
  "version": "${ver}",
  "description": "test plugin"
}
JSON

  # JSON version file: package.json
  cat > "$TEST_TMP/package.json" <<JSON
{
  "name": "my-project",
  "version": "${ver}",
  "private": true
}
JSON

  # Plain-text version file: VERSION
  printf '%s\n' "${ver}" > "$TEST_TMP/VERSION"

  # A file NOT listed in version_files — must remain untouched.
  printf '%s\n' "${ver}" > "$TEST_TMP/UNTRACKED_VERSION"
}

# ---------------------------------------------------------------------------
# AC1 — version-bump reads configured file list and bumps every entry
# ---------------------------------------------------------------------------
@test "version-bump reads configured file list and bumps every entry" {
  _scaffold_project "1.2.3"

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]

  # All three configured files must now be 1.2.4.
  local pj_ver pkg_ver txt_ver
  pj_ver=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8')).version)")
  pkg_ver=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/package.json','utf8')).version)")
  txt_ver=$(cat "$TEST_TMP/VERSION")

  [ "$pj_ver"  = "1.2.4" ]
  [ "$pkg_ver" = "1.2.4" ]
  [ "$txt_ver" = "1.2.4" ]

  # The untracked file must NOT have changed.
  local untracked
  untracked=$(cat "$TEST_TMP/UNTRACKED_VERSION")
  [ "$untracked" = "1.2.3" ]
}

# ---------------------------------------------------------------------------
# AC2 — version-bump writes JSON and plain-text files in their native format
# ---------------------------------------------------------------------------
@test "version-bump writes JSON and plain-text version files in their native format" {
  _scaffold_project "2.0.0"

  run node "$VERSION_BUMP_JS" minor \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]

  # JSON files must be valid JSON (node -e will throw on parse error).
  run node -e "JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8'))"
  [ "$status" -eq 0 ]

  run node -e "JSON.parse(require('fs').readFileSync('$TEST_TMP/package.json','utf8'))"
  [ "$status" -eq 0 ]

  # JSON files must retain their OTHER keys untouched.
  local pj_name pj_desc
  pj_name=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8')).name)")
  pj_desc=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8')).description)")
  [ "$pj_name" = "my-plugin" ]
  [ "$pj_desc" = "test plugin" ]

  # The version in JSON files must be the bumped value (minor: 2.0.0 → 2.1.0).
  local pj_ver
  pj_ver=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8')).version)")
  [ "$pj_ver" = "2.1.0" ]

  # Plain-text file must contain ONLY the version string (no JSON wrapping).
  local txt_content
  txt_content=$(cat "$TEST_TMP/VERSION")
  [ "$txt_content" = "2.1.0" ]

  # Malformed file test: a binary / unsupported file should produce an error.
  printf '\x00\x01BINARY' > "$TEST_TMP/BADFILE"
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"

release:
  version_files:
    - BADFILE
YAML

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "BADFILE" ]]
}

# ---------------------------------------------------------------------------
# AC3 — resolve-config.sh resolves project-config from repo root and subdir
# ---------------------------------------------------------------------------
@test "resolve-config.sh resolves project-config from repo root and from a subdir" {
  # Create a minimal project tree.
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"
YAML

  # From repo root: resolve-config should find the config and exit 0.
  run bash -c "cd '$TEST_TMP' && GAIA_NO_PROJECT_WALKUP= '$RESOLVE_CONFIG' project_config_path"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "project-config.yaml" ]]

  # From a nested subdirectory: walk-up discovery should find the same config.
  mkdir -p "$TEST_TMP/src/deep/nested"
  run bash -c "cd '$TEST_TMP/src/deep/nested' && GAIA_NO_PROJECT_WALKUP= '$RESOLVE_CONFIG' project_config_path"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "project-config.yaml" ]]

  # When no config exists anywhere: should exit non-zero with a clear message.
  local empty_dir="$TEST_TMP/empty-root"
  mkdir -p "$empty_dir/sub"
  run bash -c "cd '$empty_dir/sub' && HOME='$empty_dir' GAIA_NO_PROJECT_WALKUP= CLAUDE_PROJECT_ROOT= CLAUDE_SKILL_DIR= '$RESOLVE_CONFIG' project_config_path"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "config" ]] || [[ "$output" =~ "not found" ]] || [[ "$output" =~ "no config" ]]
}

# ---------------------------------------------------------------------------
# AC4 — version-bump emits a clear missing-config error naming the key
# ---------------------------------------------------------------------------
@test "version-bump emits a clear missing-config error naming release.version_files" {
  # Config with NO release.version_files key at all.
  mkdir -p "$TEST_TMP/.gaia/config"
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"
YAML

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
  # The error message must explicitly name the missing config key.
  [[ "$output" =~ "release.version_files" ]]

  # Also test with an empty version_files list.
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"

release:
  version_files: []
YAML

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "release.version_files" ]]
}

# ---------------------------------------------------------------------------
# AC5 — version-bump emits a machine-readable summary and zero exit on success
# ---------------------------------------------------------------------------
@test "version-bump emits a machine-readable summary and zero exit on success" {
  _scaffold_project "3.1.0"

  run node "$VERSION_BUMP_JS" major \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]

  # Output must be parseable JSON.
  run node -e "
    var data = JSON.parse(process.argv[1]);
    if (!data.bumped || !Array.isArray(data.bumped)) process.exit(1);
    if (data.old_version !== '3.1.0') process.exit(1);
    if (data.new_version !== '4.0.0') process.exit(1);
    if (data.bumped.length !== 3) process.exit(1);
    process.exit(0);
  " "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Path-traversal guard — version file outside project root is rejected
# ---------------------------------------------------------------------------
@test "version-bump rejects a version file that escapes the project root" {
  _scaffold_project "1.0.0"

  # Overwrite config to include a path-traversal entry.
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"

release:
  version_files:
    - ../../etc/evil-version
YAML

  # Create the target file so the "file not found" check doesn't fire first.
  mkdir -p "$(dirname "$TEST_TMP/../../etc/evil-version")"
  printf '1.0.0\n' > "$TEST_TMP/../../etc/evil-version"

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  # Must exit non-zero.
  [ "$status" -ne 0 ]
  # Error must mention the offending path and "outside".
  [[ "$output" == *"outside"* ]]
  [[ "$output" == *"evil-version"* ]] || [[ "$output" == *"../../etc/evil-version"* ]]
}

@test "version-bump rejects path-traversal even when resolved path shares a prefix with root" {
  # Ensure /repo-evil does not pass a /repo prefix check (trailing-sep safety).
  _scaffold_project "1.0.0"

  # Create a sibling directory that shares a prefix with the project root.
  local sibling="${TEST_TMP}-evil"
  mkdir -p "$sibling"
  printf '1.0.0\n' > "$sibling/VERSION"

  # Compute relative path from TEST_TMP to sibling/VERSION.
  # Since sibling is TEST_TMP + "-evil", the relative path is ../<basename>-evil/VERSION
  local base
  base="$(basename "$TEST_TMP")"
  local relative="../${base}-evil/VERSION"

  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<YAML
project_root: "$TEST_TMP"
project_path: "$TEST_TMP"
memory_path: "$TEST_TMP/.gaia/memory"
checkpoint_path: "$TEST_TMP/.gaia/memory/checkpoints"
installed_path: "$TEST_TMP"
framework_version: "1.197.0"
date: "2026-06-18"

release:
  version_files:
    - $relative
YAML

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  # Must exit non-zero — the path shares a prefix but is outside the root.
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
}

@test "version-bump allows a valid in-repo path after path-traversal guard is in place" {
  _scaffold_project "5.0.0"

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  # Must succeed — all paths are inside the project root.
  [ "$status" -eq 0 ]

  # Files must have been bumped.
  local pj_ver
  pj_ver=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TEST_TMP/plugin.json','utf8')).version)")
  [ "$pj_ver" = "5.0.1" ]
}
