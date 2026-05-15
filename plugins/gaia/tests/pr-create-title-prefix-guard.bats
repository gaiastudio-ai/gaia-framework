#!/usr/bin/env bats
# pr-create-title-prefix-guard.bats — E57-S13 AC3 (TD-148).
#
# pr-create.sh prepends `${STORY_KEY}: ` to the PR title. When the caller
# already passes a conventional-commits header like `feat(E88-S1): foo`,
# the prepend produces `E88-S1: feat(E88-S1): foo` which (a) is not
# conventional-commits compliant and (b) is rejected by commitlint. The
# guard added in E57-S13 detects an existing CC prefix and skips the
# prepend; the legacy bare-title path is preserved unchanged.

load 'test_helper.bash'

PR_CREATE="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/pr-create.sh"

# Helper: stub `gh` so we can capture the `--title` arg without actually
# hitting GitHub. The stub prints the title on stdout and exits 0.
setup() {
  common_setup
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Capture the value of `--title` (the arg immediately following the flag).
while [ $# -gt 0 ]; do
  if [ "$1" = "--title" ] && [ $# -ge 2 ]; then
    printf 'TITLE=%s\n' "$2"
    shift 2
    continue
  fi
  shift
done
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"

  # pr-create.sh requires (a) an in-tree git workspace (otherwise it
  # early-returns via non-git CWD guard, skipping the title-prepend logic
  # under test) AND (b) a non-protected current branch (otherwise the
  # assert_branch_not_protected security invariant aborts the script).
  # Build a per-test git repo on a feature branch.
  WORK_REPO="$TEST_TMP/repo"
  mkdir -p "$WORK_REPO"
  (
    cd "$WORK_REPO" || exit 1
    git init -q -b main
    git -c user.email=t@e -c user.name=t commit -q --allow-empty -m "init"
    git checkout -q -b feat/E88-S1-test
  )
  # PROJECT_PATH is the cwd pr-create.sh `cd`s into. Also `cd` the bats
  # process into WORK_REPO so pr-create.sh's non_git_cwd_skip guard (which
  # checks the CURRENT cwd before honoring PROJECT_PATH) sees an in-tree
  # workspace and proceeds to the title-prepend logic under test.
  export PROJECT_PATH="$WORK_REPO"
  cd "$WORK_REPO"

  # Story file detection in pr-create.sh isn't critical; the script does not
  # currently read a story file. The body-file path supplied below is read.
  BODY_FILE="$TEST_TMP/body.md"
  printf '%s\n' "## Test body" > "$BODY_FILE"
}
teardown() { common_teardown; }

@test "TC-PCG-1: title with conventional-commits prefix is NOT re-prepended" {
  run "$PR_CREATE" E88-S1 "feat(E88-S1): foo" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  # The captured TITLE must equal the input title exactly — no E88-S1: prefix.
  [[ "$output" == *"TITLE=feat(E88-S1): foo"* ]]
  [[ "$output" != *"TITLE=E88-S1: feat(E88-S1):"* ]]
}

@test "TC-PCG-2: bare title (no conventional-commits prefix) is prepended with story key" {
  run "$PR_CREATE" E88-S1 "add foo to bar" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=E88-S1: add foo to bar"* ]]
}

@test "TC-PCG-3: title with conventional-commits prefix anchored at start is detected even with extra text after" {
  run "$PR_CREATE" E92-S3 "fix(E92-S3): swap hook to PLUGIN_ROOT" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=fix(E92-S3): swap hook to PLUGIN_ROOT"* ]]
  [[ "$output" != *"TITLE=E92-S3: fix("* ]]
}

@test "TC-PCG-4: title with non-conventional shape that happens to contain parentheses is still prepended" {
  run "$PR_CREATE" E88-S1 "Refactor (cleanup)" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=E88-S1: Refactor (cleanup)"* ]]
}
