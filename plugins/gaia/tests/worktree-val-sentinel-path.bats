#!/usr/bin/env bats
# worktree-val-sentinel-path.bats — regression tests for Val sentinel
# placement, hash integrity, asserter agreement, and test-artifact slug
# preservation in linked worktrees.

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$SCRIPTS_DIR/lib/write-val-envelope.sh"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-test-artifact-per-story.sh"
  ASSERT_HELPER="$SCRIPTS_DIR/lib/assert-agent-envelope.sh"
}

teardown() {
  if [ -n "${_WT_MAIN:-}" ] && [ -d "$_WT_MAIN" ]; then
    git -C "$_WT_MAIN" worktree prune 2>/dev/null || true
  fi
  common_teardown
}

_envelope() {
  local artifact="${1:-.gaia/artifacts/planning-artifacts/prd.md}"
  local verdict="${2:-PASSED}"
  printf '{"agent":"val","persona_sig":"val-dev-test","timestamp":"2026-10-25T12:00:00Z","artifact_path":"%s","verdict":"%s"}' "$artifact" "$verdict"
}

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
  mkdir -p "$_FX_MAIN/.gaia"
  printf 'placeholder\n' > "$_FX_MAIN/.gaia/ci-config.yaml"
  git -C "$_FX_MAIN" init -q 2>/dev/null
  git -C "$_FX_MAIN" add -A 2>/dev/null
  git -C "$_FX_MAIN" -c user.name=t -c user.email=t@t commit -m init -q 2>/dev/null
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
# AC2: writer and asserter agree; distinct artifacts produce distinct keys
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

@test "writer hash matches the asserter: project-relative path" {
  local cp="$TEST_TMP/cp-agree"
  mkdir -p "$cp"
  local artifact=".gaia/artifacts/planning-artifacts/prd.md"
  local sentinel_path
  sentinel_path=$(CHECKPOINT_PATH="$cp" "$HELPER" --envelope "$(_envelope "$artifact")")
  [ -n "$sentinel_path" ]
  source "$ASSERT_HELPER"
  run assert_agent_envelope "$sentinel_path"
  [ "$status" -eq 0 ]
}

@test "writer hash matches the asserter: absolute artifact path" {
  local root="$TEST_TMP/proj-abs"
  local cp="$root/.gaia/memory/checkpoints"
  mkdir -p "$cp"
  local rel="artifacts/plan.md"
  local abs="$root/$rel"
  local sentinel_path
  sentinel_path=$(PROJECT_ROOT="$root" CHECKPOINT_PATH="$cp" "$HELPER" --envelope "$(_envelope "$abs")")
  [ -n "$sentinel_path" ]
  # The writer normalizes to project-relative; verify the hash matches.
  local expected_hash
  expected_hash=$(printf '%s' "$rel" | shasum -a 256 | cut -c1-16)
  [[ "$sentinel_path" == *"val-envelope-${expected_hash}.json" ]] \
    || { echo "hash mismatch: $sentinel_path" >&2; false; }
  source "$ASSERT_HELPER"
  run assert_agent_envelope "$sentinel_path"
  [ "$status" -eq 0 ]
}

@test "writer then asserter end-to-end from a real worktree CWD" {
  _setup_worktree_fixture
  local root_canon
  root_canon="$(cd "$_FX_ROOT" && pwd -P)"
  local home_canon
  home_canon="$(cd "$_FX_HOME" && pwd -P)"
  local artifact=".gaia/artifacts/planning-artifacts/prd.md"

  # Write + assert from inside the worktree with no env vars.
  run bash -c "
    export HOME='$home_canon'
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT CHECKPOINT_PATH _GAIA_PATHS_LOADED GAIA_NO_PROJECT_WALKUP
    cd '$_FX_WT/src'
    sp=\$('$HELPER' --envelope '$(_envelope "$artifact")')
    [ -n \"\$sp\" ] || { echo 'writer failed'; exit 1; }
    source '$ASSERT_HELPER'
    assert_agent_envelope \"\$sp\"
  "
  [ "$status" -eq 0 ] || { echo "FAILED: $output" >&2; false; }

  git -C "$_FX_MAIN" worktree remove "$_FX_WT" --force 2>/dev/null || true
}

# Prose guard: each SKILL.md call site must tell the consumer to use the
# writer's printed path, not to recompute the hash independently.
@test "no SKILL.md call site tells the asserter to compute sha256 independently" {
  local skills_dir
  skills_dir="$(cd "$SCRIPTS_DIR/../skills" && pwd)"
  local offending=""
  for f in \
    "$skills_dir/gaia-dev-story/SKILL.md" \
    "$skills_dir/gaia-fix-story/SKILL.md" \
    "$skills_dir/gaia-validate-story/SKILL.md" \
    "$skills_dir/gaia-add-feature/SKILL.md" \
    "$skills_dir/gaia-val-validate/SKILL.md"; do
    [ -f "$f" ] || continue
    # The old pattern: "sentinel_path = ... sha256(...)" or "derived from sha256"
    if grep -q 'sentinel_path.*=.*sha256\|derived from.*sha256.*hex' "$f" 2>/dev/null; then
      offending="${offending}${f}\n"
    fi
  done
  [ -z "$offending" ] \
    || { printf 'FAIL: call sites still compute hash independently:\n%b' "$offending" >&2; false; }
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
  # The fixture has epic-E900-slug with BOTH E900-S5-real and E900-S50-other,
  # plus a longer-epic epic-E9000-wrong.
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E900-slug/E900-S5-real"
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E900-slug/E900-S50-other"
  mkdir -p "$root/.gaia/artifacts/test-artifacts/epic-E9000-wrong"
  PROJECT_ROOT="$root" run "$RESOLVER" atdd E900-S5 --write
  [ "$status" -eq 0 ]
  [[ "$output" != *"E900-S50"* ]] \
    || { echo "story prefix leak: $output" >&2; false; }
  [[ "$output" != *"E9000"* ]] \
    || { echo "epic prefix leak: $output" >&2; false; }
  # Should resolve to the correct slug-bearing dir.
  [[ "$output" == *"epic-E900-slug/E900-S5-real/atdd.md"* ]] \
    || { echo "unexpected: $output" >&2; false; }
}

# ---------------------------------------------------------------------------
# F1: GAIA_MEMORY_PATH isolation — must not break the resolver
# ---------------------------------------------------------------------------

@test "resolver tolerates an unrelated GAIA_MEMORY_PATH during walk-up" {
  _setup_worktree_fixture
  local root_canon
  root_canon="$(cd "$_FX_ROOT" && pwd -P)"
  local home_canon
  home_canon="$(cd "$_FX_HOME" && pwd -P)"
  mkdir -p "$_FX_ROOT/.gaia/artifacts/implementation-artifacts/epic-E900-iso/E900-S10-iso"
  mkdir -p "$_FX_ROOT/.gaia/artifacts/test-artifacts"

  run bash -c "
    export HOME='$home_canon'
    export GAIA_MEMORY_PATH='/tmp/elsewhere'
    unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT _GAIA_PATHS_LOADED GAIA_NO_PROJECT_WALKUP
    cd '$_FX_WT'
    '$RESOLVER' atdd E900-S10 --write
  "
  [ "$status" -eq 0 ] || { echo "FAILED: $output" >&2; false; }
  [[ "$output" == "$root_canon/"* ]] \
    || { echo "wrong root: $output" >&2; false; }

  git -C "$_FX_MAIN" worktree remove "$_FX_WT" --force 2>/dev/null || true
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
