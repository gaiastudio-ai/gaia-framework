#!/usr/bin/env bats
# assert-gitignored-git-check-ignore.bats — tests for git check-ignore upgrade,
# project-relative path fix, covering-directory matching, and CWD isolation
# in assert_gitignored / track-b-dispatch.sh.
#
# Covers:
#   - covering directory entry passes via git check-ignore (in-repo)
#   - covering double-star wildcard passes via git check-ignore (in-repo)
#   - uncovered path HALTs (in-repo)
#   - absolute CLAUDE_PROJECT_ROOT no longer breaks the check (in-repo)
#   - absolute CLAUDE_PROJECT_ROOT with project root NOT a git repo
#   - non-git fallback uses grep -F (literal match)
#   - non-git fallback HALTs on missing pattern
#   - non-git fallback honours covering-directory entries
#   - git check-ignore anchored to PROJECT_ROOT (CWD isolation)
#   - probe-suffix mutant is killed
#   - regex metacharacters treated literally in fallback
#   - negation rules in fallback

load 'test_helper.bash'

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

# --- Covering-directory matching in non-git fallback (AC1) ---

@test "non-git fallback honours covering-directory entry with trailing slash" {
  # .gitignore has ".gaia/memory/" which should cover all descendants.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory/\n' > .gitignore

  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "non-git fallback honours covering-directory entry without trailing slash" {
  # .gitignore has ".gaia/memory" (no trailing slash) — still covers children.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory\n' > .gitignore

  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "non-git fallback covering-directory match at intermediate ancestor" {
  # .gitignore has ".gaia/" which covers the deeply nested pattern.
  cd "$TMPDIR_TEST"
  printf '.gaia/\n' > .gitignore

  source "$HELPER"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

# --- CWD isolation via -C PROJECT_ROOT (AC2) ---

@test "git check-ignore anchored to PROJECT_ROOT when CWD is outside the repo" {
  # PROJECT_ROOT points at a git repo; CWD is outside that repo entirely.
  # Without -C PROJECT_ROOT, git rev-parse would fail from here and the
  # function would fall back to the grep path (and not find .gitignore).
  mkdir -p "$TMPDIR_TEST/repo" "$TMPDIR_TEST/elsewhere"
  cd "$TMPDIR_TEST/repo"
  git init -q .
  printf '.gaia/memory/\n' > .gitignore

  export PROJECT_ROOT="$TMPDIR_TEST/repo"
  source "$HELPER"
  cd "$TMPDIR_TEST/elsewhere"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "git check-ignore uses PROJECT_ROOT repo when CWD is inside a different repo" {
  # CWD is inside a SECOND git repo whose .gitignore does NOT cover the
  # pattern. PROJECT_ROOT points at the REAL repo whose .gitignore does.
  # Without -C on rev-parse, rev-parse succeeds in the wrong repo.
  # Without -C on check-ignore, check-ignore reads the wrong .gitignore.
  mkdir -p "$TMPDIR_TEST/real-repo" "$TMPDIR_TEST/other-repo"
  cd "$TMPDIR_TEST/real-repo"
  git init -q .
  printf '.gaia/memory/\n' > .gitignore

  cd "$TMPDIR_TEST/other-repo"
  git init -q .
  printf '*.log\n' > .gitignore

  export PROJECT_ROOT="$TMPDIR_TEST/real-repo"
  source "$HELPER"
  cd "$TMPDIR_TEST/other-repo"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

@test "rev-parse anchored to non-git PROJECT_ROOT when CWD is in a git repo" {
  # PROJECT_ROOT is NOT a git repo (the documented GAIA project layout)
  # but holds a .gitignore. CWD is inside a separate git repo.
  # Without -C on rev-parse, rev-parse succeeds (CWD is in a repo),
  # then check-ignore -C runs against the non-git PROJECT_ROOT and fails
  # (fatal: not a git repository) causing a false HALT.
  # With -C on rev-parse, rev-parse sees PROJECT_ROOT is not a repo,
  # falls to the non-git fallback, and finds the .gitignore there.
  mkdir -p "$TMPDIR_TEST/non-git-project" "$TMPDIR_TEST/some-repo"
  printf '.gaia/memory/\n' > "$TMPDIR_TEST/non-git-project/.gitignore"

  cd "$TMPDIR_TEST/some-repo"
  git init -q .
  printf '*.log\n' > .gitignore

  export PROJECT_ROOT="$TMPDIR_TEST/non-git-project"
  source "$HELPER"
  cd "$TMPDIR_TEST/some-repo"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

# --- Non-git fallback CWD isolation ---

@test "non-git fallback finds gitignore at PROJECT_ROOT when CWD differs" {
  # PROJECT_ROOT holds the .gitignore; CWD is a completely different
  # non-git directory with no .gitignore at all.  Without the
  # PROJECT_ROOT-anchored search, the function walks up from CWD and
  # never finds a .gitignore.
  mkdir -p "$TMPDIR_TEST/project-root" "$TMPDIR_TEST/unrelated-dir"
  printf '.gaia/memory/\n' > "$TMPDIR_TEST/project-root/.gitignore"

  export PROJECT_ROOT="$TMPDIR_TEST/project-root"
  source "$HELPER"
  cd "$TMPDIR_TEST/unrelated-dir"
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
}

# --- Probe-suffix mutant (AC3) ---

@test "probe-suffix mutant is killed -- removing probe suffix changes git check-ignore result" {
  # .gitignore has an entry that matches ONLY the exact probe-suffixed path.
  # If the code dropped the probe suffix, git check-ignore would reject it.
  cd "$TMPDIR_TEST"
  git init -q .
  printf '.gaia/memory/checkpoints/sprint-review-probe\n' > .gitignore

  source "$HELPER"
  # With the probe suffix appended (current code): the entry matches.
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-"

  # Without the probe suffix: the bare prefix is NOT a gitignore entry.
  run git check-ignore -q ".gaia/memory/checkpoints/sprint-review-"
  [ "$status" -ne 0 ]
}

# --- Regex metacharacters treated literally (AC4) ---

@test "non-git fallback treats regex metacharacters literally via fixed-string matching" {
  # .gitignore has "[0-9]" as a literal string — the fallback must NOT treat
  # it as a character class that matches digits.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory/checkpoints/sprint-review-[0-9]\n' > .gitignore

  source "$HELPER"
  # Pattern with an actual digit must NOT match the literal "[0-9]".
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-5"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT:"* ]]

  # Pattern with the exact literal "[0-9]" substring DOES match.
  assert_gitignored ".gaia/memory/checkpoints/sprint-review-[0-9]"
}

# --- Negation rules (AC5) ---

@test "non-git fallback HALTs when path is un-ignored by negation rule" {
  # .gitignore covers .gaia/memory/ then un-ignores the checkpoints/ subtree.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory/\n!.gaia/memory/checkpoints/\n' > .gitignore

  source "$HELPER"
  run assert_gitignored ".gaia/memory/checkpoints/sprint-review-"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT:"* ]]
}

@test "non-git fallback negation does not affect paths outside its scope" {
  # .gitignore negates checkpoints/ but .gaia/memory/other/ is still covered.
  cd "$TMPDIR_TEST"
  printf '.gaia/memory/\n!.gaia/memory/checkpoints/\n' > .gitignore

  source "$HELPER"
  # .gaia/memory/other/ is NOT un-ignored — still covered by .gaia/memory/.
  assert_gitignored ".gaia/memory/other/some-file"
}
