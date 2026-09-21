#!/usr/bin/env bats
# merge-remote-state-confirmation.bats — behavioural coverage for the merge
# helper's failure classification.
#
# The merge helper runs `gh pr merge`, which performs the remote merge first
# and only then attempts a local branch switch. Under worktree mode the base
# branch is checked out in the primary tree, so that local switch fails and
# gh exits non-zero AFTER the pull request has already merged. These tests
# pin the behaviour that the helper confirms the pull request's real state
# with the remote before it declares a failure, and that it finishes the
# branch cleanup gh abandoned.
#
# The gh CLI is stubbed as a fake executable on PATH. The real GitHub API is
# never contacted. Every fixture git call carries an inline committer
# identity and disables signing, and HOME / GIT_CONFIG_GLOBAL are isolated,
# so the suite behaves identically on a CI runner with no ambient git config.

load 'test_helper.bash'

MERGE_REL="../skills/gaia-dev-story/scripts/merge.sh"

setup() {
  common_setup
  MERGE_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$MERGE_REL")" && pwd)/$(basename "$MERGE_REL")"

  # Isolate git config: a CI runner has no ambient identity, and a developer
  # machine must not leak one in either.
  export HOME="$TEST_TMP/home"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"

  GH_ARGS="$TEST_TMP/gh-args.txt"
  export GH_ARGS
  : > "$GH_ARGS"

  make_stub_gh
  make_fixture_repo
  make_fixture_config
}

teardown() { common_teardown; }

# fixture_git — every fixture git invocation goes through here so the inline
# committer identity and the signing opt-out can never be forgotten.
fixture_git() {
  git -c user.email=fixture@example.invalid \
      -c user.name=fixture \
      -c commit.gpgsign=false \
      "$@"
}

make_fixture_repo() {
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q
  fixture_git -C "$REPO" checkout -q -b feat/story-branch
  fixture_git -C "$REPO" commit --allow-empty -q -m init
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

# make_stub_gh — one stub script whose behaviour is selected per test by the
# GH_SCENARIO environment variable. It records every argv to a sidecar file
# so tests can assert which calls were actually made.
make_stub_gh() {
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"

scenario="${GH_SCENARIO:-merged}"

# `gh pr view` — the state query, used both before the merge attempt and on
# the failure path.
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *baseRefName*) printf 'staging\n'; exit 0 ;;
    *headRefName*) printf 'feat/story-branch\n'; exit 0 ;;
    *mergedAt*)    printf 'OPEN\n'; exit 0 ;;   # pre-merge idempotency probe
    # The caller asks for state,mergeCommit with --jq '.state', so real gh
    # emits the bare state string here.
    *mergeCommit*)
      case "$scenario" in
        remote-merged|delete-branch|delete-branch-absent)
          printf 'MERGED\n'; exit 0 ;;
        worktree-state-unavailable)
          printf 'gh: could not reach api.github.com\n' >&2; exit 1 ;;
        *)
          printf 'OPEN\n'; exit 0 ;;
      esac ;;
  esac
  exit 0
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'example-org/example-repo\n'
  exit 0
fi

# `gh pr merge` — always fails; the wording is what each scenario varies.
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  case "$scenario" in
    remote-merged|delete-branch|delete-branch-absent|worktree-state-unavailable)
      printf "failed to run git: fatal: 'staging' is already used by worktree at '/tmp/primary'\n" >&2 ;;
    remote-open)
      printf 'gh: something unrecognised went wrong\n' >&2 ;;
    conflict)
      printf 'Pull request is not mergeable: the merge commit cannot be cleanly created.\n' >&2 ;;
    protection)
      printf 'Protected branch update failed: 2 of 3 required status checks have not succeeded.\n' >&2 ;;
  esac
  exit 1
fi

# `gh api` — the branch-ref deletion the recovery path performs.
if [ "$1" = "api" ]; then
  if [ "$scenario" = "delete-branch-absent" ]; then
    printf 'gh: Reference does not exist (HTTP 422)\n' >&2
    exit 1
  fi
  exit 0
fi

exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

@test "a merge that fails only on the local checkout but merged on the remote is reported as success" {
  export GH_SCENARIO=remote-merged
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
  # The generic failure line must not be emitted for a merge that succeeded.
  [[ "$output" != *"Merge failed:"* ]]
}

@test "the remote-confirmed recovery logs the local checkout problem as a warning not an error" {
  export GH_SCENARIO=remote-merged
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"already used by worktree"* ]]
}

@test "the recovery path queries the remote for the pull request state and merge commit" {
  export GH_SCENARIO=remote-merged
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  run grep -F 'mergeCommit' "$GH_ARGS"
  [ "$status" -eq 0 ]
}

@test "branch cleanup the merge command abandoned is completed by the recovery path" {
  export GH_SCENARIO=delete-branch
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
  run grep -F 'heads/feat/story-branch' "$GH_ARGS"
  [ "$status" -eq 0 ]
}

@test "a head branch already absent from the remote does not fail the recovery path" {
  export GH_SCENARIO=delete-branch-absent
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged:squash"* ]]
}

@test "branch cleanup is skipped when branch deletion was not requested" {
  export GH_SCENARIO=remote-merged
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 0 ]
  run grep -F 'heads/feat/story-branch' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a merge that genuinely did not happen on the remote still fails" {
  export GH_SCENARIO=remote-open
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"Merge failed:"* ]]
  [[ "$output" != *"merged:squash"* ]]
}

@test "an unavailable remote state query yields a message naming the worktree checkout conflict" {
  export GH_SCENARIO=worktree-state-unavailable
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"worktree"* ]]
  [[ "$output" == *"confirm"* ]]
  [[ "$output" != *"Merge failed:"* ]]
}

@test "a merge conflict is still reported with the conflict message and no remote state query" {
  export GH_SCENARIO=conflict
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"Merge conflict detected."* ]]
  run grep -F 'mergeCommit' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "branch protection is still reported with the protection message and no remote state query" {
  export GH_SCENARIO=protection
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --no-delete-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"Branch protection blocked the merge."* ]]
  run grep -F 'mergeCommit' "$GH_ARGS"
  [ "$status" -ne 0 ]
}

@test "a pull request already merged before any attempt short-circuits without a merge call" {
  # The pre-merge idempotency probe reports MERGED, so no merge is attempted.
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$*" in
  *mergedAt*) printf 'MERGED\n' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMP/bin/gh"
  run "$MERGE_SH" 42 STORY-KEY --strategy squash --delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"already_merged"* ]]
  run grep -F 'pr merge' "$GH_ARGS"
  [ "$status" -ne 0 ]
}
