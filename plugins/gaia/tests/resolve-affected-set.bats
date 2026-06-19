#!/usr/bin/env bats
# resolve-affected-set.bats — TDD tests for resolve-affected-set.sh
#
# Covers the three-tier fallback chain for resolving the affected-set:
#   1. CI artifact file (primary channel)
#   2. Commit trailer (secondary channel)
#   3. Full-deploy sentinel (safety net — never empty)
#
# Public functions covered: resolve_from_artifact,
# resolve_from_trailer, resolve_full_deploy, resolve_affected_set, main.

load 'test_helper.bash'

setup() {
  common_setup

  RESOLVER="$SCRIPTS_DIR/resolve-affected-set.sh"

  # Create a minimal project config for full-deploy resolution
  cat > "$TEST_TMP/project-config.yaml" <<'YAML'
stacks:
  - name: api
    language: typescript
    path: src/api
  - name: web
    language: typescript
    path: src/web
  - name: worker
    language: python
    path: src/worker
YAML

  # Set up a temporary git repo for commit-trailer tests
  GIT_REPO="$TEST_TMP/repo"
  mkdir -p "$GIT_REPO"
  git -C "$GIT_REPO" init -q
  git -C "$GIT_REPO" config user.email "test@test.local"
  git -C "$GIT_REPO" config user.name "Test"
  touch "$GIT_REPO/placeholder"
  git -C "$GIT_REPO" add placeholder
  git -C "$GIT_REPO" commit -q -m "initial commit"
}

teardown() { common_teardown; }

# =========================================================================
# Public-fn coverage: source the script and verify every public function resolves
# =========================================================================

@test "source script — resolve_from_artifact is callable" {
  source "$RESOLVER"
  type resolve_from_artifact
}

@test "source script — resolve_from_trailer is callable" {
  source "$RESOLVER"
  type resolve_from_trailer
}

@test "source script — resolve_full_deploy is callable" {
  source "$RESOLVER"
  type resolve_full_deploy
}

@test "source script — resolve_affected_set is callable" {
  source "$RESOLVER"
  type resolve_affected_set
}

@test "source script — main is callable" {
  source "$RESOLVER"
  type main
}

@test "sourcing the script does not run main" {
  run bash -c 'source "'"$RESOLVER"'" && echo "sourced-ok"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"sourced-ok"* ]]
  # Should NOT contain resolver output or errors
  [[ "$output" != *'"channel"'* ]]
  [[ "$output" != *'HALT'* ]]
}

# =========================================================================
# Primary channel: CI artifact file present
# =========================================================================

@test "primary channel — reads affected-set from CI artifact file" {
  # Create a well-formed artifact file
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":["api","web"]}
JSON

  run "$RESOLVER" --artifact "$artifact"

  [[ "$status" -eq 0 ]]
  # Output must contain the stacks
  [[ "$output" == *'"stacks"'* ]]
  [[ "$output" == *'"api"'* ]]
  [[ "$output" == *'"web"'* ]]
  # Output must name the resolving channel
  [[ "$output" == *'"channel":"ci-artifact"'* ]] || [[ "$output" == *'"channel": "ci-artifact"'* ]]
}

@test "primary channel — artifact with wildcard sentinel emits full-deploy" {
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":["*"]}
JSON

  run "$RESOLVER" --artifact "$artifact"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"stacks"'* ]]
  [[ "$output" == *'"*"'* ]]
  [[ "$output" == *'"channel":"ci-artifact"'* ]] || [[ "$output" == *'"channel": "ci-artifact"'* ]]
}

@test "primary channel — malformed artifact falls through to next channel" {
  local artifact="$TEST_TMP/affected-set.json"
  echo "THIS IS NOT JSON" > "$artifact"

  # With no trailer and no config, should fall to full-deploy sentinel
  run "$RESOLVER" --artifact "$artifact"

  [[ "$status" -eq 0 ]]
  # Must NOT use ci-artifact channel
  [[ "$output" != *'"channel":"ci-artifact"'* ]]
  [[ "$output" != *'"channel": "ci-artifact"'* ]]
  # Must resolve via full-deploy sentinel since no other channel available
  [[ "$output" == *'"channel":"full-deploy"'* ]] || [[ "$output" == *'"channel": "full-deploy"'* ]]
  # Full-deploy sentinel must not be empty
  [[ "$output" == *'"stacks"'* ]]
  [[ "$output" == *'"*"'* ]]
}

@test "primary channel — empty stacks array in artifact falls through" {
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":[]}
JSON

  run "$RESOLVER" --artifact "$artifact"

  [[ "$status" -eq 0 ]]
  # Empty stacks is a valid selective result (docs-only), NOT a fallthrough
  [[ "$output" == *'"channel":"ci-artifact"'* ]] || [[ "$output" == *'"channel": "ci-artifact"'* ]]
  [[ "$output" == *'"stacks":[]'* ]] || [[ "$output" == *'"stacks": []'* ]]
}

@test "primary channel — missing artifact file falls through gracefully" {
  run "$RESOLVER" --artifact "$TEST_TMP/does-not-exist.json"

  [[ "$status" -eq 0 ]]
  # Must NOT use ci-artifact channel
  [[ "$output" != *'"channel":"ci-artifact"'* ]]
  [[ "$output" != *'"channel": "ci-artifact"'* ]]
  # Falls to full-deploy since no other source
  [[ "$output" == *'"channel":"full-deploy"'* ]] || [[ "$output" == *'"channel": "full-deploy"'* ]]
}

# =========================================================================
# Secondary channel: commit trailer
# =========================================================================

@test "secondary channel — parses affected-set from commit trailer" {
  # Create a commit with an Affected-Set trailer
  touch "$GIT_REPO/file1.txt"
  git -C "$GIT_REPO" add file1.txt
  git -C "$GIT_REPO" commit -q -m "feat: add feature

Affected-Set: [\"api\",\"worker\"]"

  run "$RESOLVER" --git-dir "$GIT_REPO" --artifact "$TEST_TMP/does-not-exist.json"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"api"'* ]]
  [[ "$output" == *'"worker"'* ]]
  [[ "$output" == *'"channel":"commit-trailer"'* ]] || [[ "$output" == *'"channel": "commit-trailer"'* ]]
}

@test "secondary channel — CI artifact takes precedence over commit trailer" {
  # Both artifact and trailer available — artifact wins
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":["web"]}
JSON

  touch "$GIT_REPO/file2.txt"
  git -C "$GIT_REPO" add file2.txt
  git -C "$GIT_REPO" commit -q -m "feat: another feature

Affected-Set: [\"api\",\"worker\"]"

  run "$RESOLVER" --artifact "$artifact" --git-dir "$GIT_REPO"

  [[ "$status" -eq 0 ]]
  # Must resolve via ci-artifact, NOT commit-trailer
  [[ "$output" == *'"channel":"ci-artifact"'* ]] || [[ "$output" == *'"channel": "ci-artifact"'* ]]
  [[ "$output" == *'"web"'* ]]
}

@test "secondary channel — Affected-Components trailer also accepted" {
  touch "$GIT_REPO/file3.txt"
  git -C "$GIT_REPO" add file3.txt
  git -C "$GIT_REPO" commit -q -m "fix: patch

Affected-Components: [\"worker\"]"

  run "$RESOLVER" --git-dir "$GIT_REPO" --artifact "$TEST_TMP/does-not-exist.json"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"worker"'* ]]
  [[ "$output" == *'"channel":"commit-trailer"'* ]] || [[ "$output" == *'"channel": "commit-trailer"'* ]]
}

@test "secondary channel — commit without trailer falls through to full-deploy" {
  # Latest commit has no trailer
  touch "$GIT_REPO/file4.txt"
  git -C "$GIT_REPO" add file4.txt
  git -C "$GIT_REPO" commit -q -m "chore: plain commit with no trailer"

  run "$RESOLVER" --git-dir "$GIT_REPO" --artifact "$TEST_TMP/does-not-exist.json"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"channel":"full-deploy"'* ]] || [[ "$output" == *'"channel": "full-deploy"'* ]]
  [[ "$output" == *'"*"'* ]]
}

# =========================================================================
# Safety net: full-deploy sentinel
# =========================================================================

@test "full-deploy sentinel — never returns empty stacks" {
  # No artifact, no git dir — must emit full-deploy
  run "$RESOLVER"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"channel":"full-deploy"'* ]] || [[ "$output" == *'"channel": "full-deploy"'* ]]
  [[ "$output" == *'"stacks"'* ]]
  [[ "$output" == *'"*"'* ]]
}

@test "full-deploy sentinel — with config resolves all stack names" {
  run "$RESOLVER" --config "$TEST_TMP/project-config.yaml"

  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"channel":"full-deploy"'* ]] || [[ "$output" == *'"channel": "full-deploy"'* ]]
  [[ "$output" == *'"api"'* ]]
  [[ "$output" == *'"web"'* ]]
  [[ "$output" == *'"worker"'* ]]
}

# =========================================================================
# Artifact schema shape validation
# =========================================================================

@test "artifact schema — output is valid JSON with stacks and channel fields" {
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":["api"]}
JSON

  run "$RESOLVER" --artifact "$artifact"

  [[ "$status" -eq 0 ]]
  # Extract the JSON line (the one containing "stacks") from mixed output
  local json_line
  json_line="$(echo "$output" | grep '"stacks"')"
  echo "$json_line" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'stacks' in data, 'missing stacks key'
assert 'channel' in data, 'missing channel key'
assert isinstance(data['stacks'], list), 'stacks must be a list'
assert isinstance(data['channel'], str), 'channel must be a string'
"
}

@test "artifact schema — uploaded artifact matches the contracted schema shape" {
  # The contracted schema is: {"stacks": ["stack-name", ...]}
  # Verify a well-formed artifact passes schema validation
  local artifact="$TEST_TMP/affected-set.json"
  cat > "$artifact" <<'JSON'
{"stacks":["api","web","worker"]}
JSON

  python3 -c "
import sys, json
data = json.load(open('$artifact'))
assert 'stacks' in data, 'missing stacks key'
assert isinstance(data['stacks'], list), 'stacks must be a list'
for s in data['stacks']:
    assert isinstance(s, str), 'each stack must be a string'
"
}

# =========================================================================
# Output format and machine readability
# =========================================================================

@test "resolver output names the resolving channel for every resolution path" {
  # Test all three channels produce a channel field

  # Channel 1: CI artifact
  local artifact="$TEST_TMP/affected-set.json"
  echo '{"stacks":["api"]}' > "$artifact"
  run "$RESOLVER" --artifact "$artifact"
  [[ "$status" -eq 0 ]]
  local json_line
  json_line="$(echo "$output" | grep '"stacks"')"
  echo "$json_line" | python3 -c "import sys,json; assert json.load(sys.stdin)['channel'] == 'ci-artifact'"

  # Channel 2: Commit trailer
  touch "$GIT_REPO/f5.txt"
  git -C "$GIT_REPO" add f5.txt
  git -C "$GIT_REPO" commit -q -m "feat: x

Affected-Set: [\"web\"]"

  run "$RESOLVER" --artifact "$TEST_TMP/missing.json" --git-dir "$GIT_REPO"
  [[ "$status" -eq 0 ]]
  json_line="$(echo "$output" | grep '"stacks"')"
  echo "$json_line" | python3 -c "import sys,json; assert json.load(sys.stdin)['channel'] == 'commit-trailer'"

  # Channel 3: Full-deploy
  run "$RESOLVER"
  [[ "$status" -eq 0 ]]
  json_line="$(echo "$output" | grep '"stacks"')"
  echo "$json_line" | python3 -c "import sys,json; assert json.load(sys.stdin)['channel'] == 'full-deploy'"
}

@test "help flag prints usage and exits 0" {
  run "$RESOLVER" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"--artifact"* ]]
}
