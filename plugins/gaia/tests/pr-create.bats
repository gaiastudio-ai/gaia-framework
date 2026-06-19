#!/usr/bin/env bats
# pr-create.bats — bats coverage for E55-S13 D2 (TC-DSF-2).
#
# Verifies that pr-create.sh accepts the `--body-file <path>` option (and
# its short alias `-F <path>`), reads the body from the file, and forwards
# it to `gh pr create --body-file`. SKILL.md Step 11 instructs callers to
# pass `--body-file <(printf ...)`; without this option the helper fell
# back to the default body and `pr-body.sh` output was dead code.
#
# Story: E55-S13 — dev-story workflow friction bundle.
# Defect: D2 — pr-create.sh missing --body-file flag.

load 'test_helper.bash'

PR_CREATE_REL="../skills/gaia-dev-story/scripts/pr-create.sh"

setup() {
  common_setup
  PR_CREATE="$(cd "$BATS_TEST_DIRNAME/$(dirname "$PR_CREATE_REL")" && pwd)/$(basename "$PR_CREATE_REL")"
}

teardown() { common_teardown; }

# TC-DSF-2 — pr-create.sh advertises the --body-file flag in its usage banner.
@test "pr-create.sh usage advertises --body-file" {
  run grep -E -- '--body-file' "$PR_CREATE"
  [ "$status" -eq 0 ]
}

# TC-DSF-2b — pr-create.sh accepts the -F short alias.
@test "pr-create.sh accepts -F as a --body-file alias" {
  run grep -E -- '-F\)|-F ' "$PR_CREATE"
  [ "$status" -eq 0 ]
}

# TC-DSF-2c — When --body-file is parsed, the script reads the file content
# and forwards it to gh pr create. Verified via stub gh that records argv
# to a sidecar file.
@test "body-file content is consumed verbatim as PR body" {
  STAGED_BIN="$TEST_TMP/bin"
  mkdir -p "$STAGED_BIN"
  cat > "$STAGED_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh CLI: record argv to sidecar; emit a fake PR URL on `pr create`.
printf '%s\n' "$@" > "${TEST_TMP}/gh-args.txt"
case "$1" in
  pr)
    case "$2" in
      list)    printf '\n' ;;                              # no existing PR
      create)  printf 'https://example.invalid/pr/1\n' ;;  # success
      *)       exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STAGED_BIN/gh"
  export PATH="$STAGED_BIN:$PATH"
  export TEST_TMP

  # Per-test git work tree so non_git_cwd_skip + branch helpers do not abort.
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
       && git checkout -q -b feat/test && git commit --allow-empty -q -m init )
  export PROJECT_PATH="$REPO"

  BODY_FILE="$TEST_TMP/body.md"
  printf 'CUSTOM-BODY-CONTENT-MARKER\n' > "$BODY_FILE"

  run "$PR_CREATE" E55-S13 "test title" --base staging --body-file "$BODY_FILE"
  [ "$status" -eq 0 ]
  # Argv recorded for the gh pr create call MUST contain the body content.
  run grep -F 'CUSTOM-BODY-CONTENT-MARKER' "$TEST_TMP/gh-args.txt"
  [ "$status" -eq 0 ]
}
