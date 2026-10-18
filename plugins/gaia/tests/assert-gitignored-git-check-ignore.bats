#!/usr/bin/env bats
# assert-gitignored-git-check-ignore.bats — tests for git check-ignore upgrade
# and project-relative path fix in assert_gitignored / track-b-dispatch.sh.
#
# Covers:
#   - covering directory entry passes via git check-ignore (in-repo)
#   - covering double-star wildcard passes via git check-ignore (in-repo)
#   - uncovered path HALTs (in-repo)
#   - absolute CLAUDE_PROJECT_ROOT no longer breaks the check (in-repo)
#   - absolute CLAUDE_PROJECT_ROOT with project root NOT a git repo
#   - non-git fallback uses grep -F (literal match)
#   - non-git fallback HALTs on missing pattern

setup() {
  HELPER="${BATS_TEST_DIRNAME}/../scripts/lib/transcript-writer.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# --- In-repo tests (git check-ignore path) ---

@test "covering directory entry passes via git check-ignore" {
  # Scenario 1: .gitignore has ".gaia/memory/" — covers the checkpoint prefix.
  # git check-ignore reads .gitignore without needing a commit.
  cd "$TMPDIR_TEST"
  git init -q .
  printf '.gaia/memory/\n' > .gitignore

  source "$HELPER"
  # Must exit 0 — git check-ignore sees ".gaia/memory/" as covering.
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "covering double-star wildcard passes via git check-ignore" {
  # Scenario 2: .gitignore has "**/.gaia/memory/" covering deeply.
  cd "$TMPDIR_TEST"
  git init -q .
  printf '**/.gaia/memory/\n' > .gitignore

  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "uncovered path HALTs with exit 1 and HALT message" {
  # Scenario 3: .gitignore only has *.log — does NOT cover the prefix.
  cd "$TMPDIR_TEST"
  git init -q .
  printf '*.log\n' > .gitignore

  source "$HELPER"
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT:"* ]]
  [[ "$output" == *"must be in .gitignore"* ]]
}

@test "absolute CLAUDE_PROJECT_ROOT does not break the check (in-repo)" {
  # Scenario 4: CLAUDE_PROJECT_ROOT is an absolute path, .gitignore has the
  # literal sprint-review wildcard. The old code built an absolute pattern
  # that grep -F could never match. After the fix the pattern is relative.
  cd "$TMPDIR_TEST"
  git init -q .
  printf '.gaia/memory/checkpoints/sprint-review-*\n' > .gitignore

  # Source with CLAUDE_PROJECT_ROOT set to an absolute path.
  export CLAUDE_PROJECT_ROOT="$TMPDIR_TEST"
  source "$HELPER"
  # The function receives the RELATIVE pattern now — must pass.
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "absolute CLAUDE_PROJECT_ROOT with project root NOT a git repo" {
  # Scenario: project root is not a git repo (the documented layout).
  # .gitignore exists but git check-ignore is unavailable.
  # assert_gitignored should fall back to grep -F and pass when the
  # literal pattern is in .gitignore.
  cd "$TMPDIR_TEST"
  # NOT a git repo — do not run git init.
  printf '.gaia/memory/checkpoints/sprint-review-\n' > .gitignore

  export CLAUDE_PROJECT_ROOT="$TMPDIR_TEST"
  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

# --- Non-git fallback tests ---

@test "non-git fallback passes when literal pattern present in .gitignore" {
  # Scenario 5: no git repo, .gitignore has the literal prefix.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory/checkpoints/sprint-review-\n' > .gitignore

  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "non-git fallback HALTs when pattern absent from .gitignore" {
  # Scenario 6: no git repo, .gitignore does NOT contain the prefix.
  cd "$TMPDIR_TEST"
  printf '*.log\n' > .gitignore

  source "$HELPER"
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT:"* ]]
  [[ "$output" == *"must be in .gitignore"* ]]
}

# --- Call-site integration test: track-b-dispatch.sh line ~220 ---

@test "track-b-dispatch.sh gitignore check passes with absolute CLAUDE_PROJECT_ROOT at non-git root" {
  # Integration test: run the real track-b-dispatch.sh through its gitignore
  # pre-flight (line ~220). The fixture mirrors this project's layout: a
  # non-git project root with CLAUDE_PROJECT_ROOT set to its absolute path
  # and a .gitignore containing the literal checkpoint prefix.
  #
  # CWD is NOT inside a git repo, so assert_gitignored falls back to the
  # grep -F path. The old bug built the pattern as
  # "${PROJECT_ROOT}/.../.gaia/memory/checkpoints/sprint-review-" — an
  # absolute path that grep -F could never match in .gitignore. With the
  # fix, the call site passes the project-relative pattern and grep -F
  # matches.

  local TRACK_B="${BATS_TEST_DIRNAME}/../skills/gaia-sprint-review/scripts/track-b-dispatch.sh"
  [ -f "$TRACK_B" ] || skip "track-b-dispatch.sh not found in source tree"
  command -v yq >/dev/null 2>&1 || skip "yq not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  # Build fixture: a plain directory (NOT a git repo) so the grep -F
  # fallback is exercised.
  local project_root="$TMPDIR_TEST/project"
  mkdir -p "$project_root"
  cd "$project_root"

  # .gitignore with the literal checkpoint prefix — this is what grep -F
  # must match. With the old absolute-path bug, the pattern was
  # "/abs/path/.gaia/..." which grep -F could never find here.
  printf '.gaia/memory/checkpoints/sprint-review-\n' > .gitignore

  # Minimal project-config.yaml with one Track B stack.
  mkdir -p .gaia/config
  cat > .gaia/config/project-config.yaml <<'YAML'
sprint_review:
  plugin_commands:
    fixture-stack: "true"
YAML

  # Run the script with CLAUDE_PROJECT_ROOT set to the absolute project root.
  run env \
    CLAUDE_PROJECT_ROOT="$project_root" \
    PROJECT_ROOT="" \
    PROJECT_PATH="" \
    bash "$TRACK_B" --sprint sprint-fixture --config .gaia/config/project-config.yaml

  # The script must NOT halt on the gitignore check.
  if [[ "$output" == *"HALT:"*"must be in .gitignore"* ]]; then
    printf 'FAIL: gitignore pre-flight halted — absolute-path pattern bug\noutput: %s\n' "$output" >&2
    return 1
  fi

  # The script should exit 0 (the stack command is "true").
  [ "$status" -eq 0 ]
}
