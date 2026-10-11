#!/usr/bin/env bats
# pr-create.bats — coverage for pr-create.sh body-file handling.
#
# Verifies that pr-create.sh accepts the `--body-file <path>` option (and
# its short alias `-F <path>`), reads the body from the file, and forwards
# it to `gh pr create`. The body is kept intact and a `Story:` reference
# line is appended when the file does not already have one.

load 'test_helper.bash'

PR_CREATE_REL="../skills/gaia-dev-story/scripts/pr-create.sh"

setup() {
  common_setup
  PR_CREATE="$(cd "$BATS_TEST_DIRNAME/$(dirname "$PR_CREATE_REL")" && pwd)/$(basename "$PR_CREATE_REL")"
}

teardown() { common_teardown; }

@test "pr-create.sh usage advertises --body-file" {
  run grep -E -- '--body-file' "$PR_CREATE"
  [ "$status" -eq 0 ]
}

@test "pr-create.sh accepts -F as a --body-file alias" {
  run grep -E -- '-F\)|-F ' "$PR_CREATE"
  [ "$status" -eq 0 ]
}

# Body-file content is kept with story reference appended.
@test "body-file content is kept with story reference appended" {
  STAGED_BIN="$TEST_TMP/bin"
  mkdir -p "$STAGED_BIN"
  cat > "$STAGED_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh CLI: return empty for `pr list`, record body for `pr create`.
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  exit 0  # no existing PR
fi
shift 2  # skip "pr create"
while [ $# -gt 0 ]; do
  case "$1" in
    --body)
      printf '%s' "$2" > "${TEST_TMP}/gh-body.txt"
      shift 2 ;;
    *) shift ;;
  esac
done
printf 'https://example.invalid/pr/1\n'
exit 0
STUB
  chmod +x "$STAGED_BIN/gh"
  export PATH="$STAGED_BIN:$PATH"
  export TEST_TMP

  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q \
       && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
       commit --allow-empty -q -m init \
       && git checkout -q -b feat/test )
  export PROJECT_PATH="$REPO"

  BODY_FILE="$TEST_TMP/body.md"
  printf 'CUSTOM-BODY-CONTENT-MARKER\n' > "$BODY_FILE"

  run "$PR_CREATE" K1-S1 "fix: test title" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  # Body must contain the original content.
  grep -Fq 'CUSTOM-BODY-CONTENT-MARKER' < "$TEST_TMP/gh-body.txt"
  # Body must also carry a Story: reference line.
  grep -q '^Story: ' < "$TEST_TMP/gh-body.txt"
}
