#!/usr/bin/env bats
# worktree-val-sentinel-path.bats — regression tests for Val sentinel
# placement, hash integrity, and test-artifact slug preservation in
# linked worktrees.

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/lib/write-val-envelope.sh"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-test-artifact-per-story.sh"
  ASSERT_HELPER="$SCRIPTS_DIR/lib/assert-agent-envelope.sh"
}

teardown() {
  # Clean up any worktrees we created.
  if [ -n "${_WT_MAIN:-}" ] && [ -d "$_WT_MAIN" ]; then
    git -C "$_WT_MAIN" worktree prune 2>/dev/null || true
  fi
  common_teardown
}

# Helper: build a valid Val envelope JSON.
_envelope() {
  local artifact="${1:-.gaia/artifacts/planning-artifacts/prd.md}"
  local verdict="${2:-PASSED}"
  printf '{"agent":"val","persona_sig":"val-dev-test","timestamp":"2026-10-25T12:00:00Z","artifact_path":"%s","verdict":"%s"}' "$artifact" "$verdict"
}

# Helper: set up a fully isolated fixture project with config, a git main
# checkout, and a linked worktree. Sets _FX_ROOT, _FX_MAIN, _FX_WT, _FX_HOME.
_setup_worktree_fixture() {
  _FX_HOME="$TEST_TMP/home"
  _FX_ROOT="$TEST_TMP/home/proj"
  _FX_MAIN="$_FX_ROOT/product"
  _FX_WT="$_FX_ROOT/.gaia-worktrees/E900-S1"
  mkdir -p "$_FX_HOME" "$_FX_ROOT/.gaia/config" "$_FX_ROOT/.gaia/memory/checkpoints"
  cat > "$_FX_ROOT/.gaia/config/project-config.yaml" <<YAML
project_root: $_FX_ROOT
project_path: product
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
  mkdir -p "$_FX_MAIN"
  git -C "$_FX_MAIN" init -q 2>/dev/null
  git -C "$_FX_MAIN" -c user.name=t -c user.email=t@t commit --allow-empty -m init -q 2>/dev/null
  _WT_MAIN="$_FX_MAIN"
  git -C "$_FX_MAIN" worktree add "$_FX_WT" -b wt-branch -q 2>/dev/null
  mkdir -p "$_FX_WT/src"
}

# ---------------------------------------------------------------------------
# AC1: sentinel placed under project root, not the worktree
# ---------------------------------------------------------------------------

@test "sentinel lands at project root via walk-up from a real worktree" {
  _setup_worktree_fixture
  local artifact="test-artifact-worktree"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local root_canon
  root_canon="$(cd "$_FX_ROOT" && pwd -P)"
  local home_canon
  home_canon="$(cd "$_FX_HOME" && pwd -P)"

  run bash -c "
    export HOME='$home_canon'
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT CHECKPOINT_PATH _GAIA_PATHS_LOADED GAIA_NO_PROJECT_WALKUP
    cd '$_FX_WT/src'
    '$HELPER' --envelope '$envelope'
  "
  [ "$status" -eq 0 ] || { echo "FAILED: $output" >&2; false; }
  [ -f "$root_canon/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ] \
    || { echo "sentinel not at project root" >&2; find "$_FX_ROOT" -name 'val-envelope-*' >&2; false; }

  git -C "$_FX_MAIN" worktree remove "$_FX_WT" --force 2>/dev/null || true
}

@test "explicit CHECKPOINT_PATH override still wins over walk-up" {
  local override="$TEST_TMP/override-cp"
  mkdir -p "$override"
  local artifact="test-artifact-override"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  CHECKPOINT_PATH="$override" run "$HELPER" --envelope "$envelope"
  [ "$status" -eq 0 ]
  [ -f "$override/val-envelope-${expected_hash}.json" ]
}

@test "sentinel via resolver fallback with explicit config lands at project root" {
  local root="$TEST_TMP/proj-cfg"
  mkdir -p "$root/.gaia/config" "$root/.gaia/memory/checkpoints"
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
  local deep="$TEST_TMP/other/deep"
  mkdir -p "$deep"
  local artifact="test-artifact-cfg"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  (
    cd "$deep"
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT CHECKPOINT_PATH _GAIA_PATHS_LOADED
    GAIA_SHARED_CONFIG="$root/.gaia/config/project-config.yaml" \
      "$HELPER" --envelope "$envelope"
  ) > "$TEST_TMP/cfg-out.txt" 2>&1
  [ "$?" -eq 0 ] || { cat "$TEST_TMP/cfg-out.txt"; false; }
  [ -f "$root/.gaia/memory/checkpoints/val-envelope-${expected_hash}.json" ] \
    || { echo "sentinel not at config root" >&2; false; }
}

# ---------------------------------------------------------------------------
# AC2: distinct artifacts produce distinct sentinel keys; writer and
# asserter agree on ONE key formula
# ---------------------------------------------------------------------------

@test "three different artifact paths produce three distinct sentinel keys" {
  local cp="$TEST_TMP/cp-distinct"
  mkdir -p "$cp"

  local a1=".gaia-worktrees/E900-S1/plan.md"
  local a2=".gaia-worktrees/E900-S2/plan.md"
  local a3="plan.md"

  CHECKPOINT_PATH="$cp" run "$HELPER" --envelope "$(_envelope "$a1" PASSED)"
  [ "$status" -eq 0 ]
  CHECKPOINT_PATH="$cp" run "$HELPER" --envelope "$(_envelope "$a2" FAILED)"
  [ "$status" -eq 0 ]
  CHECKPOINT_PATH="$cp" run "$HELPER" --envelope "$(_envelope "$a3" PASSED)"
  [ "$status" -eq 0 ]

  local count
  count=$(find "$cp" -name 'val-envelope-*.json' -not -name '*.tmp*' | wc -l)
  count=$(echo "$count" | tr -d ' ')
  [ "$count" -eq 3 ] \
    || { echo "expected 3 distinct sentinels, got $count" >&2; ls "$cp/" >&2; false; }
}

@test "writer hash matches the asserter formula from project root" {
  local root="$TEST_TMP/proj-agree"
  local cp="$root/.gaia/memory/checkpoints"
  mkdir -p "$cp"
  local artifact=".gaia/artifacts/planning-artifacts/prd.md"
  local envelope
  envelope=$(_envelope "$artifact")

  local sentinel_path
  sentinel_path=$(CHECKPOINT_PATH="$cp" "$HELPER" --envelope "$envelope")
  [ -n "$sentinel_path" ]

  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)
  local expected_path="$cp/val-envelope-${expected_hash}.json"

  [ "$sentinel_path" = "$expected_path" ] \
    || { echo "writer=$sentinel_path asserter=$expected_path" >&2; false; }

  source "$ASSERT_HELPER"
  run assert_agent_envelope "$sentinel_path"
  [ "$status" -eq 0 ]
}

@test "writer hash matches asserter formula for an absolute artifact path" {
  local root="$TEST_TMP/proj-abs"
  local cp="$root/.gaia/memory/checkpoints"
  mkdir -p "$cp"
  local rel="artifacts/plan.md"
  local abs="$root/$rel"
  local envelope
  envelope=$(_envelope "$abs")

  local sentinel_path
  sentinel_path=$(PROJECT_ROOT="$root" CHECKPOINT_PATH="$cp" "$HELPER" --envelope "$envelope")
  [ -n "$sentinel_path" ]

  local expected_hash
  expected_hash=$(printf '%s' "$rel" | shasum -a 256 | cut -c1-16)
  local expected_path="$cp/val-envelope-${expected_hash}.json"
  [ "$sentinel_path" = "$expected_path" ] \
    || { echo "writer=$sentinel_path expected=$expected_path" >&2; false; }
}

# ---------------------------------------------------------------------------
# AC3: slug preservation in resolve-test-artifact-per-story.sh
# ---------------------------------------------------------------------------

@test "resolver finds slug from implementation-artifacts direct layout" {
  local root="$TEST_TMP/proj-slug"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-test-slug/E900-S5-my-story-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S5 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-test-slug/E900-S5-my-story-slug/atdd.md"* ]] \
    || { echo "slug lost: $output" >&2; false; }
}

@test "resolver finds slug from legacy stories/ layout" {
  local root="$TEST_TMP/proj-legacy-slug"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-legacy/stories/E900-S6-legacy-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S6 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-legacy/E900-S6-legacy-slug/atdd.md"* ]] \
    || { echo "slug lost in legacy: $output" >&2; false; }
}

@test "resolver resolves project root from a real worktree CWD" {
  _setup_worktree_fixture
  local root_canon
  root_canon="$(cd "$_FX_ROOT" && pwd -P)"
  local home_canon
  home_canon="$(cd "$_FX_HOME" && pwd -P)"
  mkdir -p "$_FX_ROOT/.gaia/artifacts/implementation-artifacts/epic-E900-wt/E900-S9-wt-story"
  mkdir -p "$_FX_ROOT/.gaia/artifacts/test-artifacts"

  run bash -c "
    export HOME='$home_canon'
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT _GAIA_PATHS_LOADED GAIA_NO_PROJECT_WALKUP
    cd '$_FX_WT'
    '$RESOLVER' atdd E900-S9 --write
  "
  [ "$status" -eq 0 ] || { echo "FAILED: $output" >&2; false; }
  [[ "$output" == "$root_canon/"* ]] \
    || { echo "resolved inside worktree: $output" >&2; false; }
  [[ "$output" == *"epic-E900-wt/E900-S9-wt-story/atdd.md"* ]] \
    || { echo "slug lost from worktree: $output" >&2; false; }

  git -C "$_FX_MAIN" worktree remove "$_FX_WT" --force 2>/dev/null || true
}

@test "fallback scans test-artifacts for slug-bearing epic/story dirs" {
  local root="$TEST_TMP/proj-fb-slug"
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E900-fallback-epic/E900-S7-fallback-story"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S7 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900-fallback-epic/E900-S7-fallback-story/atdd.md"* ]] \
    || { echo "fallback slug lost: $output" >&2; false; }
}

@test "fallback produces bare key when no slugged dirs exist" {
  local root="$TEST_TMP/proj-bare"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S8 --write
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E900/E900-S8/atdd.md"* ]] \
    || { echo "unexpected: $output" >&2; false; }
}

@test "rung 0 requires epic-* parent and rejects non-epic directories" {
  local root="$TEST_TMP/proj-nonepic"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/sprint-archive/E900-S4-old"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S4 --write
  [ "$status" -eq 0 ]
  [[ "$output" != *"sprint-archive"* ]] \
    || { echo "matched non-epic parent: $output" >&2; false; }
}

@test "resolver prefix boundary rejects longer key that shares a numeric prefix" {
  local root="$TEST_TMP/proj-boundary"
  local long_key="E900-S50"
  local short_key="E900-S5"
  mkdir -p "$root/.gaia/artifacts/implementation-artifacts/epic-E900-bound/${long_key}-other-story"
  mkdir -p "$root/.gaia/artifacts/test-artifacts"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd "$short_key" --write
  [ "$status" -eq 0 ]
  [[ "$output" != *"${long_key}"* ]] \
    || { echo "false prefix match: $output" >&2; false; }
}

@test "fallback prefix boundary rejects longer epic and story key prefixes" {
  local root="$TEST_TMP/proj-fb-bound"
  # Only longer-key variants exist; the exact prefix must not match them.
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E9000-wrong/E900-S50-other"

  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S5 --write
  [ "$status" -eq 0 ]
  [[ "$output" != *"E900-S50"* ]] \
    || { echo "story prefix leak: $output" >&2; false; }
  [[ "$output" != *"E9000"* ]] \
    || { echo "epic prefix leak: $output" >&2; false; }
  # Falls back to the bare key because no exact prefix match exists.
  [[ "$output" == *"epic-E900/E900-S5/atdd.md"* ]] \
    || { echo "unexpected: $output" >&2; false; }
}

# ---------------------------------------------------------------------------
# AC4: non-worktree behaviour unchanged
# ---------------------------------------------------------------------------

@test "non-worktree sentinel placement via explicit config" {
  local root="$TEST_TMP/proj-normal"
  local cp="$root/.gaia/memory/checkpoints"
  mkdir -p "$cp" "$root/.gaia/config"
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
  local artifact="normal-artifact"
  local envelope
  envelope=$(_envelope "$artifact")
  local expected_hash
  expected_hash=$(printf '%s' "$artifact" | shasum -a 256 | cut -c1-16)

  (
    cd "$root"
    unset CHECKPOINT_PATH _GAIA_PATHS_LOADED
    CLAUDE_PROJECT_ROOT="$root" "$HELPER" --envelope "$envelope"
  ) > "$TEST_TMP/normal-out.txt" 2>&1
  [ "$?" -eq 0 ] || { cat "$TEST_TMP/normal-out.txt"; false; }
  [ -f "$cp/val-envelope-${expected_hash}.json" ]
}
