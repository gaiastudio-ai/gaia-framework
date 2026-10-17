#!/usr/bin/env bats
# merge-pre-merge-guards.bats — behavioural coverage for the three pre-merge
# guards that block the merge when:
#   1. Any PR check is neither pass nor skipping.
#   2. The branch head is not a descendant of the current base tip.
#   3. Any commit in the PR range carries an assistant attribution trailer.
#
# The gh CLI is stubbed. The real GitHub API is never contacted. Fixture git
# calls carry an inline identity and disable signing so the suite works on
# CI runners with no ambient config.

load 'test_helper.bash'

MERGE_REL="../skills/gaia-dev-story/scripts/merge.sh"

setup() {
  common_setup
  MERGE_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$MERGE_REL")" && pwd)/$(basename "$MERGE_REL")"

  # Isolate git config
  export HOME="$TEST_TMP/home"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"

  GH_ARGS="$TEST_TMP/gh-args.txt"
  export GH_ARGS
  : > "$GH_ARGS"

  make_fixture_config
  make_stub_jq
}

teardown() { common_teardown; }

# fixture_git — every fixture git invocation goes through here so the inline
# committer identity and signing opt-out are never forgotten.
fixture_git() {
  git -c user.email=fixture@example.invalid \
      -c user.name=fixture \
      -c commit.gpgsign=false \
      "$@"
}

# make_fixture_repo — a repo with a staging base and a feature branch that is
# a descendant of staging (the happy path). Tests that need a stale base or
# assistant trailers modify this after calling setup.
make_fixture_repo() {
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "base commit"
  fixture_git -C "$REPO" checkout -q -b feat/story-branch
  fixture_git -C "$REPO" commit --allow-empty -q -m "feature work"

  # Set up origin/staging so merge-base --is-ancestor works.
  # A local remote lets us `git fetch origin` without network.
  ORIGIN="$TEST_TMP/origin"
  fixture_git clone --bare -q "$REPO" "$ORIGIN"
  fixture_git -C "$REPO" remote remove origin 2>/dev/null || true
  fixture_git -C "$REPO" remote add origin "$ORIGIN"
  fixture_git -C "$REPO" fetch -q origin

  export PROJECT_PATH="$REPO"
}

make_fixture_config() {
  mkdir -p "$TEST_TMP/config"
  cat > "$TEST_TMP/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - branch: staging
YAML
  export PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml"
}

# make_stub_jq — real jq if available, otherwise a minimal stub that handles
# the specific invocations merge.sh uses.
make_stub_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/jq" <<'STUB'
#!/usr/bin/env bash
echo "[]"
STUB
  chmod +x "$STUB_BIN/jq"
}

# make_stub_gh — scenario-driven gh stub. GH_SCENARIO selects the behaviour.
# Delegates to GH_CHECKS_JSON for the pr checks response.
make_stub_gh() {
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"

scenario="${GH_SCENARIO:-happy}"

# gh pr view
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *baseRefName*) printf 'staging\n'; exit 0 ;;
    *headRefName*) printf 'feat/story-branch\n'; exit 0 ;;
    *mergedAt*)    printf 'OPEN\n'; exit 0 ;;
    *mergeCommit*) printf 'OPEN\n'; exit 0 ;;
  esac
  exit 0
fi

# gh pr checks — the new guard queries this
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  if [ -n "${GH_CHECKS_JSON:-}" ]; then
    printf '%s\n' "$GH_CHECKS_JSON"
  else
    printf '[{"bucket":"pass","name":"build"},{"bucket":"pass","name":"lint"}]\n'
  fi
  exit 0
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'example-org/example-repo\n'
  exit 0
fi

# gh pr merge — happy path succeeds
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  case "$scenario" in
    happy)
      printf 'merged\n'
      exit 0 ;;
    *)
      printf 'merged\n'
      exit 0 ;;
  esac
fi

exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# -----------------------------------------------------------------------
# Guard 1: Red / pending check blocks merge
# -----------------------------------------------------------------------

@test "a failing check blocks the merge and names the failing check on stderr" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"pass","name":"build"},{"bucket":"fail","name":"lint-check"}]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"lint-check"* ]]
  # The merge command must not have been called
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a pending check blocks the merge and names the pending check on stderr" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"pass","name":"build"},{"bucket":"pending","name":"deploy-gate"}]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy-gate"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "all checks pass or skipping allows the merge to proceed" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"pass","name":"build"},{"bucket":"skipping","name":"optional-gate"}]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
}

# -----------------------------------------------------------------------
# Guard 2: Stale base blocks merge
# -----------------------------------------------------------------------

@test "a stale base blocks the merge and names the base branch" {
  make_fixture_repo

  # Advance origin/staging past the feature branch's base
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "advance staging"
  fixture_git -C "$REPO" push -q origin staging
  fixture_git -C "$REPO" checkout -q feat/story-branch
  # Now origin/staging is ahead and HEAD is NOT a descendant of it.
  fixture_git -C "$REPO" fetch -q origin

  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging"* ]]
  [[ "$output" == *"rebase"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a branch that is a descendant of the current base passes the stale-base guard" {
  make_fixture_repo
  make_stub_gh
  # Default fixture: feature is based on staging, so guard passes.
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
}

# -----------------------------------------------------------------------
# Guard 3: Assistant attribution trailer blocks merge
# -----------------------------------------------------------------------

@test "a commit with an anthropic attribution trailer blocks the merge" {
  make_fixture_repo
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "some feature$(printf '\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"noreply@anthropic.com"* ]]
  [[ "$output" == *"rebase"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a commit with a copilot attribution trailer blocks the merge" {
  make_fixture_repo
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "some feature$(printf '\n\nCo-Authored-By: GitHub Copilot <copilot@github.com>')"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"copilot"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a commit with a Claude attribution trailer (case-insensitive) blocks the merge" {
  make_fixture_repo
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "some feature$(printf '\n\nco-authored-by: CLAUDE <claude@example.com>')"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a non-assistant Co-Authored-By trailer does not block the merge" {
  make_fixture_repo
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "some feature$(printf '\n\nCo-Authored-By: Human Developer <human@example.com>')"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
}

@test "the guard prints the offending commit hash when an assistant trailer is found" {
  make_fixture_repo
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "bad commit$(printf '\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
  local bad_hash
  bad_hash="$(fixture_git -C "$REPO" rev-parse --short HEAD)"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"$bad_hash"* ]]
}

# -----------------------------------------------------------------------
# Guard ordering: check state runs first
# -----------------------------------------------------------------------

@test "when both a failing check and stale base exist the check-state guard fires first" {
  make_fixture_repo

  # Advance staging past the feature branch
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "advance staging"
  fixture_git -C "$REPO" push -q origin staging
  fixture_git -C "$REPO" checkout -q feat/story-branch
  fixture_git -C "$REPO" fetch -q origin

  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"fail","name":"ci-build"}]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  # Check-state message appears
  [[ "$output" == *"ci-build"* ]]
}

# -----------------------------------------------------------------------
# Unresolvable base ref fails closed
# -----------------------------------------------------------------------

@test "an unresolvable base ref blocks the merge and names the base" {
  # Create a repo without any origin remote — fetch will fail, which is
  # the fail-closed path for the base-ref prerequisite.
  REPO="$TEST_TMP/repo-no-origin"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b main
  fixture_git -C "$REPO" commit --allow-empty -q -m "base commit"
  fixture_git -C "$REPO" checkout -q -b feat/story-branch
  fixture_git -C "$REPO" commit --allow-empty -q -m "feature work"
  export PROJECT_PATH="$REPO"

  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"fetch"* ]]
  # The fail-closed gate must exit BEFORE the stale-base guard fires.
  [[ "$output" != *"is not based on"* ]]
  # The merge command must not have been called
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker 1 (AC3): multi-paragraph commit body with trailer at the end
# -----------------------------------------------------------------------

@test "a trailer after a multi-paragraph body is detected" {
  make_fixture_repo
  # Create a commit whose body has a description paragraph THEN the trailer.
  fixture_git -C "$REPO" commit --allow-empty -q \
    -m "$(printf 'implement feature X\n\nThis change adds the feature X integration\nwith full backward compatibility.\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"noreply@anthropic.com"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker 2: gh pr checks error fails closed
# -----------------------------------------------------------------------

@test "gh pr checks returning an error fails closed with an actionable message" {
  make_fixture_repo
  # Override the gh stub to make pr checks exit non-zero (network/auth error)
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *baseRefName*) printf 'staging\n'; exit 0 ;;
    *headRefName*) printf 'feat/story-branch\n'; exit 0 ;;
    *mergedAt*)    printf 'OPEN\n'; exit 0 ;;
    *mergeCommit*) printf 'OPEN\n'; exit 0 ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  printf 'gh: could not reach api.github.com\n' >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  printf 'merged\n'; exit 0
fi
exit 0
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not query"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker 3: guard 1 must not skip when jq is absent
# -----------------------------------------------------------------------

@test "guard 1 catches a failing check when jq is absent on PATH" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"fail","name":"broken-check"}]'
  # Shadow jq with a stub that always fails, simulating jq not installed.
  cat > "$TEST_TMP/bin/jq" <<'S'
#!/usr/bin/env bash
exit 1
S
  chmod +x "$TEST_TMP/bin/jq"
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"broken-check"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker 4: empty check list must not pass silently
# -----------------------------------------------------------------------

@test "an empty check list refuses with a wait-and-retry message" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checks reported"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker P2-1: empty check list with jq broken must still fail closed
# -----------------------------------------------------------------------

@test "empty check list with broken jq fails closed" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[]'
  # Shadow jq with a stub that always fails
  cat > "$TEST_TMP/bin/jq" <<'S'
#!/usr/bin/env bash
exit 1
S
  chmod +x "$TEST_TMP/bin/jq"
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checks reported"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Blocker P2-2: stale-base guard when fetch fails
# -----------------------------------------------------------------------

@test "stale-base guard fails closed when git fetch fails" {
  make_fixture_repo
  # Point origin at a non-existent path so fetch fails, but origin/staging
  # still exists as a stale local ref from the initial setup.
  fixture_git -C "$REPO" remote set-url origin /nonexistent/repo.git
  make_stub_gh
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"fetch"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------
# Happy path: all guards pass
# -----------------------------------------------------------------------

@test "when all guards pass the merge proceeds and exits 0" {
  make_fixture_repo
  make_stub_gh
  export GH_CHECKS_JSON='[{"bucket":"pass","name":"build"},{"bucket":"pass","name":"lint"}]'
  run "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
  # The merge command was called
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -eq 0 ]
}
