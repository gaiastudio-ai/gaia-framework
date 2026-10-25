#!/usr/bin/env bats
# worktree-val-sentinel-path.bats — regression tests for Val sentinel
# placement, hash consistency, and test-artifact slug preservation in
# linked worktrees.

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/lib/write-val-envelope.sh"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-test-artifact-per-story.sh"
}

teardown() {
  common_teardown
}

# Helper: build a valid Val envelope JSON string.
_envelope() {
  local artifact="${1:-.gaia/artifacts/planning-artifacts/prd.md}"
  local verdict="${2:-PASSED}"
  printf '{"agent":"val","persona_sig":"val-dev-test","timestamp":"2026-10-25T12:00:00Z","artifact_path":"%s","verdict":"%s"}' "$artifact" "$verdict"
}

# ---------------------------------------------------------------------------
# AC1: sentinel placed under project root, not the worktree
# ---------------------------------------------------------------------------

@test "sentinel lands at project root checkpoint dir when PROJECT_ROOT is a worktree path" {
  # Arrange: project root with .gaia/memory/checkpoints, and a worktree subdir.
  local root="$TEST_TMP/proj"
  local wt_root="$root/.gaia-worktrees/E900-S1"
  mkdir -p "$root/.gaia/memory/checkpoints"
  mkdir -p "$wt_root/.gaia/memory/checkpoints"

  local artifact="test-artifact-ac1"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  # Act: call with PROJECT_ROOT pointing to the worktree.
  PROJECT_ROOT="$wt_root" CHECKPOINT_PATH="" \
    run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ] || { echo "FAILED: $output" >&2; false; }

  # Assert: sentinel landed at the project root, not the worktree.
  [ -f "$root/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ] \
    || { echo "sentinel not at project root" >&2; ls -la "$root/.gaia/memory/checkpoints/" >&2; false; }
  [ ! -f "$wt_root/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ] \
    || { echo "sentinel wrongly at worktree" >&2; false; }
}

@test "sentinel lands at project root when resolver fallback is used from worktree CWD" {
  # Arrange: minimal project with config so resolve-config.sh can find it.
  local root="$TEST_TMP/proj2"
  local wt_root="$root/.gaia-worktrees/E900-S2"
  mkdir -p "$root/.gaia/config" "$root/.gaia/memory/checkpoints"
  mkdir -p "$wt_root"
  cat > "$root/.gaia/config/project-config.yaml" <<YAML
project_root: $root
project_path: .
memory_path: .gaia/memory
checkpoint_path: .gaia/memory/checkpoints
installed_path: test
framework_version: "0.0.0"
date: "2026-01-01"
test_artifacts: .gaia/artifacts/test-artifacts
planning_artifacts: .gaia/artifacts/planning-artifacts
implementation_artifacts: .gaia/artifacts/implementation-artifacts
creative_artifacts: .gaia/artifacts/creative-artifacts
YAML

  local artifact="test-artifact-resolver"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  # Act: invoke from inside the worktree with no PROJECT_ROOT or CHECKPOINT_PATH.
  (
    cd "$wt_root"
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT CHECKPOINT_PATH
    GAIA_SHARED_CONFIG="$root/.gaia/config/project-config.yaml" \
      "$HELPER" --envelope "$envelope"
  ) > "$TEST_TMP/out2.txt" 2>&1
  [ "$?" -eq 0 ] || { cat "$TEST_TMP/out2.txt"; false; }

  # Assert: sentinel at project root, not CWD.
  [ -f "$root/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ] \
    || { echo "sentinel not at project root" >&2; false; }
}

@test "CHECKPOINT_PATH override still wins over worktree normalization" {
  local override="$TEST_TMP/override-cp"
  mkdir -p "$override"

  local artifact="test-artifact-override"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  CHECKPOINT_PATH="$override" \
    run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  [ -f "$override/val-envelope-${expected_hash}.json" ]
}

# ---------------------------------------------------------------------------
# AC2: hash consistency between worktree and non-worktree callers
# ---------------------------------------------------------------------------

@test "hash is identical for worktree-prefixed and plain project-relative artifact paths" {
  local root="$TEST_TMP/proj-hash"
  local wt_root="$root/.gaia-worktrees/E900-S3/product"
  mkdir -p "$root/.gaia/memory/checkpoints" "$wt_root"

  local rel_path=".gaia/artifacts/planning-artifacts/prd.md"
  local abs_from_root="$root/$rel_path"
  local cp="$root/.gaia/memory/checkpoints"

  # Write from project root with the absolute artifact path.
  local env_abs
  env_abs=$(_envelope "$abs_from_root")
  PROJECT_ROOT="$root" CHECKPOINT_PATH="$cp" \
    run "$HELPER" --envelope "$env_abs"
  [ "$status" -eq 0 ]
  local sentinel_root="$output"

  # Write from worktree with worktree-relative PROJECT_ROOT and the same
  # absolute artifact path.
  local env_abs2
  env_abs2=$(_envelope "$abs_from_root" "FAILED")
  PROJECT_ROOT="$wt_root" CHECKPOINT_PATH="$cp" \
    run "$HELPER" --envelope "$env_abs2"
  [ "$status" -eq 0 ]
  local sentinel_wt="$output"

  # Both must resolve to the same sentinel path (same hash).
  local base_root base_wt
  base_root=$(basename "$sentinel_root")
  base_wt=$(basename "$sentinel_wt")
  [ "$base_root" = "$base_wt" ] \
    || { echo "hash mismatch: root=$base_root worktree=$base_wt" >&2; false; }
}

@test "relative .gaia-worktrees/ prefix stripped before hashing" {
  local cp="$TEST_TMP/cp-strip"
  mkdir -p "$cp"

  local plain=".gaia/artifacts/planning-artifacts/prd.md"
  local with_wt=".gaia-worktrees/E900-S4/$plain"

  # Expected hash is over the plain project-relative path.
  local expected_hash
  expected_hash=$(printf '%s' "$plain" | shasum -a 256 | cut -c1-16)

  # Write with the worktree-prefixed path.
  local env_wt
  env_wt=$(_envelope "$with_wt")
  CHECKPOINT_PATH="$cp" run "$HELPER" --envelope "$env_wt"
  [ "$status" -eq 0 ]
  [ -f "$cp/val-envelope-${expected_hash}.json" ] \
    || { echo "hash did not match plain form" >&2; ls "$cp/" >&2; false; }
}

# ---------------------------------------------------------------------------
# AC3: slug preservation in resolve-test-artifact-per-story.sh
# ---------------------------------------------------------------------------

@test "resolver finds slug from implementation-artifacts direct layout" {
  # Arrange: implementation-artifacts with the current layout (no stories/ sublevel).
  local root="$TEST_TMP/proj-slug"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-test-slug/E900-S5-my-story-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S5 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-test-slug/E900-S5-my-story-slug/atdd.md"* ]] \
    || { echo "slug lost: $output" >&2; false; }
}

@test "resolver finds slug from legacy stories/ layout" {
  # Arrange: legacy layout with stories/ sublevel.
  local root="$TEST_TMP/proj-legacy-slug"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-legacy/stories/E900-S6-legacy-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S6 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-legacy/E900-S6-legacy-slug/atdd.md"* ]] \
    || { echo "slug lost in legacy: $output" >&2; false; }
}

@test "fallback scans test-artifacts for slug-bearing epic/story dirs" {
  # Arrange: no implementation-artifacts, but test-artifacts has the slugged dirs.
  local root="$TEST_TMP/proj-fallback-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E900-fallback-epic/E900-S7-fallback-story"

  # No implementation-artifacts dir at all.
  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S7 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-fallback-epic/E900-S7-fallback-story/atdd.md"* ]] \
    || { echo "fallback slug lost: $output" >&2; false; }
}

@test "fallback produces bare key when no slugged dirs exist" {
  # Arrange: completely empty project — no impl or test artifact dirs.
  local root="$TEST_TMP/proj-bare"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S8 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900/E900-S8/atdd.md"* ]] \
    || { echo "unexpected bare fallback: $output" >&2; false; }
}

@test "resolver prefix boundary: E900-S5 does not match E900-S50" {
  # Arrange: only E900-S50 exists, not E900-S5.
  local root="$TEST_TMP/proj-boundary"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-bound/E900-S50-other-story"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  # E900-S5 must NOT match E900-S50.
  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S5 --write
  [ "$status" -eq 0 ]
  [[ "$output" != *"E900-S50"* ]] \
    || { echo "false prefix match: $output" >&2; false; }
  # Should fall back to the bare key.
  [[ "$output" == *"epic-E900/E900-S5/atdd.md"* ]] \
    || { echo "unexpected path: $output" >&2; false; }
}

# ---------------------------------------------------------------------------
# AC4: non-worktree behaviour unchanged
# ---------------------------------------------------------------------------

@test "non-worktree PROJECT_ROOT sentinel placement unchanged" {
  local root="$TEST_TMP/proj-normal"
  mkdir -p "$root/.gaia/memory/checkpoints"

  local artifact="normal-artifact"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  PROJECT_ROOT="$root" CHECKPOINT_PATH="" \
    run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  [ -f "$root/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ]
}

# ---------------------------------------------------------------------------
# AC6: no writes to real plugin tree (all fixtures use temp dirs)
# ---------------------------------------------------------------------------
# Verified structurally: every test above uses $TEST_TMP-rooted paths.
# The litter guard in test_helper.bash catches any stray writes.
