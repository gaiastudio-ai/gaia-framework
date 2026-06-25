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

# ---------------------------------------------------------------------------
# Multi-component fixture helper
# ---------------------------------------------------------------------------
_scaffold_multicomponent() {
  # Scaffold three independently-versioned components:
  #   packages/sync      — 0.5.0  (ahead)
  #   packages/frontend  — 0.1.0
  #   packages/shared    — 0.1.0

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
    - packages/sync/package.json
    - packages/sync/VERSION
    - packages/frontend/package.json
    - packages/frontend/VERSION
    - packages/shared/package.json
    - packages/shared/VERSION
YAML

  # packages/sync at 0.5.0
  mkdir -p "$TEST_TMP/packages/sync"
  cat > "$TEST_TMP/packages/sync/package.json" <<JSON
{
  "name": "sync",
  "version": "0.5.0"
}
JSON
  printf '0.5.0\n' > "$TEST_TMP/packages/sync/VERSION"

  # packages/frontend at 0.1.0
  mkdir -p "$TEST_TMP/packages/frontend"
  cat > "$TEST_TMP/packages/frontend/package.json" <<JSON
{
  "name": "frontend",
  "version": "0.1.0"
}
JSON
  printf '0.1.0\n' > "$TEST_TMP/packages/frontend/VERSION"

  # packages/shared at 0.1.0
  mkdir -p "$TEST_TMP/packages/shared"
  cat > "$TEST_TMP/packages/shared/package.json" <<JSON
{
  "name": "shared",
  "version": "0.1.0"
}
JSON
  printf '0.1.0\n' > "$TEST_TMP/packages/shared/VERSION"
}

# Helper: read version from a JSON file's "version" key.
_json_ver() {
  node -e "console.log(JSON.parse(require('fs').readFileSync('$1','utf8')).version)"
}

# Helper: read version from a plain-text VERSION file.
_text_ver() {
  cat "$1"
}

# ---------------------------------------------------------------------------
# Per-component scoping — --scope bumps only named components (AC1)
# ---------------------------------------------------------------------------
@test "version-bump --scope bumps only the named component, others untouched (AC1)" {
  _scaffold_multicomponent

  run node "$VERSION_BUMP_JS" minor \
    --scope "packages/frontend" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # frontend must be bumped: 0.1.0 → 0.2.0
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.2.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/frontend/VERSION")" = "0.2.0" ]

  # sync must be untouched: still 0.5.0
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.5.0" ]

  # shared must be untouched: still 0.1.0
  [ "$(_json_ver "$TEST_TMP/packages/shared/package.json")" = "0.1.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/shared/VERSION")" = "0.1.0" ]
}

# ---------------------------------------------------------------------------
# Per-component scope-map — independent magnitudes per component (AC2)
# ---------------------------------------------------------------------------
@test "version-bump --scope-map applies independent bump types per component (AC2)" {
  _scaffold_multicomponent

  run node "$VERSION_BUMP_JS" \
    --scope-map '{"packages/frontend":"minor","packages/shared":"patch"}' \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # frontend: minor bump 0.1.0 → 0.2.0
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.2.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/frontend/VERSION")" = "0.2.0" ]

  # shared: patch bump 0.1.0 → 0.1.1
  [ "$(_json_ver "$TEST_TMP/packages/shared/package.json")" = "0.1.1" ]
  [ "$(_text_ver "$TEST_TMP/packages/shared/VERSION")" = "0.1.1" ]

  # sync: not in scope-map, must be untouched
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.5.0" ]
}

# ---------------------------------------------------------------------------
# Backward compat — no scope flag bumps all files in lockstep (AC1 back-compat)
# ---------------------------------------------------------------------------
@test "version-bump without --scope bumps all files in lockstep, backward compat (AC1)" {
  _scaffold_multicomponent

  # All files start at different versions; the lockstep behavior uses the
  # first file's version (0.5.0) as the reference.
  run node "$VERSION_BUMP_JS" minor \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # All files must be bumped (the lockstep behavior bumps all).
  # The first file is packages/sync/package.json at 0.5.0 → minor → 0.6.0
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.6.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.6.0" ]
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.6.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/frontend/VERSION")" = "0.6.0" ]
  [ "$(_json_ver "$TEST_TMP/packages/shared/package.json")" = "0.6.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/shared/VERSION")" = "0.6.0" ]
}

# ---------------------------------------------------------------------------
# Monotonic guard — sync at 0.5.0 must NOT be downgraded (AC3)
# ---------------------------------------------------------------------------
@test "monotonic guard refuses to downgrade sync from 0.5.0 when minor bump targets 0.2.0 (AC3)" {
  _scaffold_multicomponent

  # Scope all three, bump type minor. Frontend/shared at 0.1.0 → 0.2.0 OK.
  # Sync at 0.5.0 — a minor bump from its own version would give 0.6.0, but
  # the scenario here tests the guard when all scoped files share one bump type
  # and the REFERENCE is each file's own current version.
  # With --scope, each component bumps from its OWN current version.
  # sync: 0.5.0 minor → 0.6.0 (no downgrade, fine)
  #
  # The actual regression scenario: scope-map with a fixed target that would
  # be lower than sync's current version.
  # Use an explicit version target to force the downgrade scenario.
  run node "$VERSION_BUMP_JS" \
    --scope "packages/sync,packages/frontend,packages/shared" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP" \
    0.2.0

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # sync at 0.5.0 — target 0.2.0 is a DOWNGRADE → must be refused (no-op).
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.5.0" ]

  # frontend/shared at 0.1.0 → 0.2.0 is an upgrade → must be written.
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.2.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/frontend/VERSION")" = "0.2.0" ]
  [ "$(_json_ver "$TEST_TMP/packages/shared/package.json")" = "0.2.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/shared/VERSION")" = "0.2.0" ]

  # Extract the JSON summary line (last line of combined output).
  local json_line
  json_line=$(echo "$output" | grep '^{')

  # JSON summary must list sync in the skipped array with reason monotonic-guard.
  run node -e "
    var data = JSON.parse(process.argv[1]);
    var found = (data.skipped || []).some(function(s) {
      return s.file.indexOf('packages/sync/') === 0 && s.reason === 'monotonic-guard';
    });
    process.exit(found ? 0 : 1);
  " "$json_line"
  [ "$status" -eq 0 ]

  # sync files on disk must remain at 0.5.0 (unchanged).
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.5.0" ]
}

# ---------------------------------------------------------------------------
# Monotonic guard — equal version is also a no-op (AC3)
# ---------------------------------------------------------------------------
@test "monotonic guard skips write when target equals current version (AC3)" {
  _scaffold_multicomponent

  # Set explicit target to 0.5.0 — sync is already at 0.5.0, so skip it.
  # frontend/shared at 0.1.0 → 0.5.0 is an upgrade.
  run node "$VERSION_BUMP_JS" \
    --scope "packages/sync,packages/frontend,packages/shared" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP" \
    0.5.0

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # sync at 0.5.0 — target 0.5.0 is equal → no-op.
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]

  # frontend/shared upgraded.
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.5.0" ]
  [ "$(_json_ver "$TEST_TMP/packages/shared/package.json")" = "0.5.0" ]
}

# ---------------------------------------------------------------------------
# All-no-ops exit code — all scoped files at or above target → exit 4 (AC3)
# ---------------------------------------------------------------------------
@test "version-bump exits 4 when every scoped file is already at or above target (AC3)" {
  _scaffold_multicomponent

  # Scope only sync (at 0.5.0), set target to 0.2.0 → downgrade → all no-ops.
  run node "$VERSION_BUMP_JS" \
    --scope "packages/sync" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP" \
    0.2.0

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 4 ]

  # sync must remain untouched.
  [ "$(_json_ver "$TEST_TMP/packages/sync/package.json")" = "0.5.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/sync/VERSION")" = "0.5.0" ]
}

# ---------------------------------------------------------------------------
# Monotonic guard in unscoped (lockstep) mode — divergent files (AC3)
# ---------------------------------------------------------------------------
@test "unscoped lockstep patch skips high-version files via monotonic guard (AC3)" {
  # Scaffold a project where version_files list fileA (low) FIRST, fileB (high).
  # Lockstep uses the first file's version as the reference for the bump.
  # patch from 0.1.0 → 0.1.1 — fileA upgrades, fileB at 5.0.0 is SKIPPED.
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
    - low-ver.json
    - high-ver.json
YAML

  cat > "$TEST_TMP/low-ver.json" <<JSON
{
  "name": "low",
  "version": "0.1.0"
}
JSON

  cat > "$TEST_TMP/high-ver.json" <<JSON
{
  "name": "high",
  "version": "5.0.0"
}
JSON

  run node "$VERSION_BUMP_JS" patch \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  # Exit 0 — low-ver bumped, so at least one file succeeded.
  [ "$status" -eq 0 ]

  # low-ver.json must be bumped: 0.1.0 → 0.1.1
  [ "$(_json_ver "$TEST_TMP/low-ver.json")" = "0.1.1" ]

  # high-ver.json must be SKIPPED (5.0.0 > 0.1.1): unchanged on disk.
  [ "$(_json_ver "$TEST_TMP/high-ver.json")" = "5.0.0" ]

  # Extract the JSON summary line (last line of combined output).
  local json_line
  json_line=$(echo "$output" | grep '^{')

  # JSON summary must list high-ver.json in the skipped array.
  run node -e "
    var data = JSON.parse(process.argv[1]);
    var found = (data.skipped || []).some(function(s) {
      return s.file === 'high-ver.json' && s.reason === 'monotonic-guard';
    });
    process.exit(found ? 0 : 1);
  " "$json_line"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Scope prefix normalization — partial prefix must not match (AC1)
# ---------------------------------------------------------------------------
@test "version-bump --scope rejects partial prefix match, e.g. packages/front vs packages/frontend (AC1)" {
  _scaffold_multicomponent

  # --scope packages/front must NOT match packages/frontend/.
  run node "$VERSION_BUMP_JS" minor \
    --scope "packages/front" \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  # No files match → all-no-ops → exit 4 (nothing to do).
  [ "$status" -eq 4 ]

  # All files must remain untouched.
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.1.0" ]
  [ "$(_text_ver "$TEST_TMP/packages/frontend/VERSION")" = "0.1.0" ]
}

# ---------------------------------------------------------------------------
# Dry-run with --scope shows only scoped entries (AC1)
# ---------------------------------------------------------------------------
@test "version-bump --dry-run --scope shows only scoped entries in summary (AC1)" {
  _scaffold_multicomponent

  run node "$VERSION_BUMP_JS" minor \
    --scope "packages/frontend" \
    --dry-run \
    --config "$TEST_TMP/.gaia/config/project-config.yaml" \
    --project-root "$TEST_TMP"

  echo "output: $output"
  echo "status: $status"

  [ "$status" -eq 0 ]

  # Output must be parseable JSON.
  # Only frontend entries should appear in bumped[].
  run node -e "
    var data = JSON.parse(process.argv[1]);
    if (!data.bumped || !Array.isArray(data.bumped)) process.exit(1);
    if (data.bumped.length !== 2) process.exit(1);
    var files = data.bumped.map(function(b){return b.file;}).sort();
    if (files[0] !== 'packages/frontend/VERSION') process.exit(1);
    if (files[1] !== 'packages/frontend/package.json') process.exit(1);
    process.exit(0);
  " "$output"
  [ "$status" -eq 0 ]

  # Files on disk must NOT have changed (dry-run).
  [ "$(_json_ver "$TEST_TMP/packages/frontend/package.json")" = "0.1.0" ]
}
