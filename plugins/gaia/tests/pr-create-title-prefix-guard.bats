#!/usr/bin/env bats
# pr-create-title-prefix-guard.bats — conventional-commit title validation
# and story-reference body-line tests for pr-create.sh.

load 'test_helper.bash'

PR_CREATE="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/pr-create.sh"

# Helper: stub `gh` so we can capture --title and --body args without
# hitting GitHub. Writes title to gh-title.txt and body to gh-body.txt.
setup() {
  common_setup
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Capture --title and --body values to sidecar files.
while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      printf '%s\n' "TITLE=$2" >&1
      printf '%s' "$2" > "${TEST_TMP}/gh-title.txt"
      shift 2 ;;
    --body)
      printf '%s' "$2" > "${TEST_TMP}/gh-body.txt"
      shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"

  # pr-create.sh requires (a) an in-tree git workspace and (b) a
  # non-protected current branch. Build a per-test git repo.
  WORK_REPO="$TEST_TMP/repo"
  mkdir -p "$WORK_REPO"
  (
    cd "$WORK_REPO" || exit 1
    git init -q -b main
    git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
      commit -q --allow-empty -m "init"
    git checkout -q -b feat/test-pr
  )
  export PROJECT_PATH="$WORK_REPO"
  cd "$WORK_REPO"

  BODY_FILE="$TEST_TMP/body.md"
  printf '%s\n' "## Test body" > "$BODY_FILE"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Title pass-through (conventional-commit shapes) — AC1
# ---------------------------------------------------------------------------

@test "story-key-scoped conventional title passes through" {
  run "$PR_CREATE" E88-S1 "feat(E88-S1): foo" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "feat(E88-S1): foo" ]
}

@test "conventional title with extra text passes through" {
  run "$PR_CREATE" E92-S3 "fix(E92-S3): swap hook to PLUGIN_ROOT" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "fix(E92-S3): swap hook to PLUGIN_ROOT" ]
}

@test "product-scoped title passes through" {
  run "$PR_CREATE" E88-S1 "fix(x): y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "fix(x): y" ]
}

@test "scopeless title passes through" {
  run "$PR_CREATE" E88-S1 "fix: y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "fix: y" ]
}

@test "breaking-scope title passes through" {
  run "$PR_CREATE" E88-S1 "feat(x)!: y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "feat(x)!: y" ]
}

@test "breaking-scopeless title passes through" {
  run "$PR_CREATE" E88-S1 "feat!: breaking change" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/gh-title.txt")" = "feat!: breaking change" ]
}

# ---------------------------------------------------------------------------
# Title refusal (non-conventional shapes) — AC2
# ---------------------------------------------------------------------------

@test "bare title is refused" {
  run "$PR_CREATE" E88-S1 "add foo to bar" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "empty-subject refused (nothing after colon)" {
  run "$PR_CREATE" E88-S1 "fix:" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "empty-subject refused (no space after colon)" {
  run "$PR_CREATE" E88-S1 "fix:y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "empty-subject refused (trailing space only)" {
  run "$PR_CREATE" E88-S1 "fix: " --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "parenthesised non-conventional title is refused" {
  run "$PR_CREATE" E88-S1 "Refactor (cleanup)" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "multi-line title refused (LF — exercises guard, not regex)" {
  run "$PR_CREATE" E88-S1 $'fix: y\nadd foo' --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "multi-line title refused (story scenario 6 input)" {
  run "$PR_CREATE" E88-S1 $'add foo\nfix: y' --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

@test "multi-line title refused (CR — exercises guard, not regex)" {
  run "$PR_CREATE" E88-S1 $'fix: y\rz' --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"title must be a single conventional-commit line"* ]]
  [ ! -f "$TEST_TMP/gh-title.txt" ]
}

# ---------------------------------------------------------------------------
# Body story reference — AC3
# ---------------------------------------------------------------------------

@test "body file without Story: gets it appended" {
  printf 'Some PR body\n' > "$BODY_FILE"
  run "$PR_CREATE" E88-S1 "fix: y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  grep -q '^Story: E88-S1' < "$TEST_TMP/gh-body.txt"
}

@test "default body carries Story: reference" {
  run "$PR_CREATE" E88-S1 "fix: y" --base staging
  [ "$status" -eq 0 ]
  grep -q '^Story: E88-S1' < "$TEST_TMP/gh-body.txt"
}

@test "body file with existing Story: keeps exactly one" {
  printf 'Some body\nStory: [E88-S1](link)\n' > "$BODY_FILE"
  run "$PR_CREATE" E88-S1 "fix: y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  local count
  count=$(grep -c '^Story:' < "$TEST_TMP/gh-body.txt")
  [ "$count" -eq 1 ]
}

@test "body with mid-line Story: still gets anchored Story: appended" {
  printf 'See the Story: reference in the text above\n' > "$BODY_FILE"
  run "$PR_CREATE" E88-S1 "fix: y" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  # The mid-line mention does NOT satisfy the ^Story: anchor, so a line-start
  # Story: reference must be appended.
  grep -q '^Story: E88-S1' < "$TEST_TMP/gh-body.txt"
}
