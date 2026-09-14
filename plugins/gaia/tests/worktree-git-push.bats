#!/usr/bin/env bats
# worktree-git-push.bats — the shared push helper's working-directory contract.
#
# The helper gains a net-new contract: resolve the working directory from
# ${PROJECT_PATH:-.} and cd into it before any git operation. The `:-.` default
# keeps every existing caller byte-identical (the one production caller passes
# no arguments and sets no PROJECT_PATH), while a caller that DOES set it gets
# the push it asked for rather than one against whatever directory happened to
# be current.
#
# Real repos, a real bare remote, and the real script throughout.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  GIT_PUSH="$PLUGIN_ROOT/scripts/git-push.sh"
  export GAIA_GIT_PUSH_BACKOFF=0
}

teardown() { common_teardown; }

# _mk_repo_with_remote <dir> <branch> — repo on <branch> wired to a bare remote.
# Echoes the bare remote path.
_mk_repo_with_remote() {
  local dir="$1" branch="$2"
  local remote="${dir}-remote.git"
  git init -q --bare "$remote"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main .
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test User"
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm "initial commit"
  git -C "$dir" remote add origin "$remote"
  if [ "$branch" != "main" ]; then
    git -C "$dir" checkout -q -b "$branch"
  fi
  ( cd "$remote" && pwd )
}

# _remote_branches <bare> — space-separated branch names present on the remote.
_remote_branches() {
  git -C "$1" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | tr '\n' ' '
}

@test "git-push.sh pushes the branch of the repo named by PROJECT_PATH not the ambient CWD (AC3)" {
  # Target repo: the one PROJECT_PATH names, on a feature branch.
  local target_remote
  target_remote="$(_mk_repo_with_remote "$TEST_TMP/target" "feat/K1-S1-slug")"
  # Decoy repo: the ambient CWD, on a different branch with its own remote.
  local decoy_remote
  decoy_remote="$(_mk_repo_with_remote "$TEST_TMP/decoy" "other-branch")"

  cd "$TEST_TMP/decoy"
  PROJECT_PATH="$TEST_TMP/target" run "$GIT_PUSH"
  [ "$status" -eq 0 ]

  local pushed; pushed="$(_remote_branches "$target_remote")"
  [[ "$pushed" == *"feat/K1-S1-slug"* ]]
  # The decoy's branch must NOT have been pushed anywhere.
  local decoyed; decoyed="$(_remote_branches "$decoy_remote")"
  [[ "$decoyed" != *"other-branch"* ]]
}

@test "git-push.sh defaults to the current directory when PROJECT_PATH is unset (AC3)" {
  local remote
  remote="$(_mk_repo_with_remote "$TEST_TMP/plain" "feat/K1-S2-slug")"
  cd "$TEST_TMP/plain"
  # `env --unset` is GNU-only; unset in a subshell so this is portable.
  run bash -c 'unset PROJECT_PATH; exec "$1"' _ "$GIT_PUSH"
  [ "$status" -eq 0 ]
  local pushed; pushed="$(_remote_branches "$remote")"
  [[ "$pushed" == *"feat/K1-S2-slug"* ]]
}

@test "git-push.sh still refuses to push from a protected branch under the working-directory contract (AC3)" {
  local remote
  remote="$(_mk_repo_with_remote "$TEST_TMP/protected" "main")"
  local elsewhere="$TEST_TMP/elsewhere"
  mkdir -p "$elsewhere"
  cd "$elsewhere"
  PROJECT_PATH="$TEST_TMP/protected" run --separate-stderr "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"protected branch"* ]]
  local pushed; pushed="$(_remote_branches "$remote")"
  [[ "$pushed" != *"main"* ]]
}

@test "git-push.sh documents the working-directory contract in its header (AC3)" {
  [ -f "$GIT_PUSH" ] || { echo "script not found: $GIT_PUSH"; return 1; }
  # The header must name PROJECT_PATH in its Environment block, so a caller can
  # discover the contract without reading the implementation.
  local header
  header="$(sed -n '1,40p' "$GIT_PUSH")"
  printf '%s' "$header" | grep -q 'PROJECT_PATH' \
    || { echo "header does not document PROJECT_PATH"; return 1; }
}
