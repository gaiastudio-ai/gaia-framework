#!/usr/bin/env bats
# worktree-chain-scripts.bats — the chain-script working-directory contract.
#
# Canonical ordering for all five git-dependent dev-story chain scripts:
#   cd into ${PROJECT_PATH:-.}  ->  run the non-git guard  ->  parse arguments
#
# The guard reads CWD and nothing else, so it must run AFTER the cd or it tests
# the caller's directory instead of the working tree the script is meant to act
# on. Three scripts guard before cd today and must be reordered; two already
# have the correct order and are pinned here against regression.
#
# Order is asserted STRUCTURALLY (relative position of the real literals in the
# real file), never by absolute line number, and is backed by behavioural runs
# of the real scripts against real throwaway repositories.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  DEVSTORY_SCRIPTS="$PLUGIN_ROOT/skills/gaia-dev-story/scripts"

  NONGIT_CWD="$TEST_TMP/non-git-fixture"
  mkdir -p "$NONGIT_CWD"
  ( cd "$NONGIT_CWD" && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
    || skip "fixture CWD unexpectedly inside a git work tree"
}

teardown() { common_teardown; }

_mk_primary_repo() {
  local dir="$1" branch="${2:-staging}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch" .
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test User"
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm "initial commit"
  ( cd "$dir" && pwd )
}

# _line_of <file> <fixed-string> — 1-based line number of the first match, or
# empty. Uses grep -n on a FILE (never a pipeline) so pipefail cannot bite.
_line_of() {
  local hit
  hit="$(grep -nF -m1 -- "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${hit%%:*}"
}

# _assert_cd_before_guard <script> — the load-bearing structural assertion.
_assert_cd_before_guard() {
  local f="$1" cd_line guard_line
  [ -f "$f" ] || { echo "script not found: $f"; return 1; }
  cd_line="$(_line_of "$f" 'cd "$WORK_DIR"')"
  guard_line="$(_line_of "$f" 'non_git_cwd_skip "$SCRIPT_NAME"')"
  [ -n "$cd_line" ] || { echo "no cd \"\$WORK_DIR\" literal in $f"; return 1; }
  [ -n "$guard_line" ] || { echo "no non_git_cwd_skip call in $f"; return 1; }
  if [ "$cd_line" -ge "$guard_line" ]; then
    echo "expected cd (line $cd_line) BEFORE guard call (line $guard_line) in $f"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Structural ordering
# ---------------------------------------------------------------------------

@test "pr-create.sh changes directory before running the non-git guard (AC2)" {
  _assert_cd_before_guard "$DEVSTORY_SCRIPTS/pr-create.sh"
}

@test "ci-wait.sh changes directory before running the non-git guard (AC2)" {
  _assert_cd_before_guard "$DEVSTORY_SCRIPTS/ci-wait.sh"
}

@test "merge.sh changes directory before running the non-git guard (AC2)" {
  _assert_cd_before_guard "$DEVSTORY_SCRIPTS/merge.sh"
}

@test "git-branch.sh keeps cd before guard (AC2)" {
  _assert_cd_before_guard "$DEVSTORY_SCRIPTS/git-branch.sh"
}

@test "verify-pr-merged.sh keeps cd before guard (AC2)" {
  local f="$DEVSTORY_SCRIPTS/verify-pr-merged.sh" cd_line guard_line
  cd_line="$(_line_of "$f" 'cd "$WORK_DIR"')"
  guard_line="$(_line_of "$f" 'non_git_cwd_skip "$SCRIPT_NAME"')"
  [ -n "$cd_line" ]
  [ -n "$guard_line" ]
  [ "$cd_line" -lt "$guard_line" ]
}

# ---------------------------------------------------------------------------
# Behavioural: the guard must see PROJECT_PATH, not the ambient CWD
# ---------------------------------------------------------------------------

@test "each chain script acts on PROJECT_PATH when CWD is a non-git directory (AC2)" {
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  # A DECOY repo: a second, unrelated real git tree. A script that cd'd into
  # "some git tree" rather than the one PROJECT_PATH names would still clear the
  # no-skip check below, so the positive assertion that follows is what actually
  # binds the working directory to PROJECT_PATH.
  local decoy; decoy="$(_mk_primary_repo "$TEST_TMP/decoy" main)"
  cd "$NONGIT_CWD"

  # Positive, PROJECT_PATH-specific effect: git-branch.sh must create the story
  # branch in the PROJECT_PATH repo and NOT in the decoy.
  PROJECT_PATH="$primary" run "$DEVSTORY_SCRIPTS/git-branch.sh" "K2-S9" "marker-slug"
  [ "$status" -eq 0 ]
  git -C "$primary" show-ref --verify --quiet "refs/heads/feat/K2-S9-marker-slug" \
    || { echo "branch was not created in the PROJECT_PATH repo"; return 1; }
  if git -C "$decoy" show-ref --verify --quiet "refs/heads/feat/K2-S9-marker-slug"; then
    echo "branch landed in the decoy repo: the script did not honour PROJECT_PATH"
    return 1
  fi
  [ "$(git -C "$primary" rev-parse --abbrev-ref HEAD)" = "feat/K2-S9-marker-slug" ]

  # With PROJECT_PATH at a real repo, no script may take the skip path: the
  # guard must be testing the resolved working directory.
  local spec script
  for spec in \
      "git-branch.sh:K1-S1:slug" \
      "pr-create.sh:K1-S1:a title" \
      "ci-wait.sh:1234:--timeout:1" \
      "merge.sh:1234:K1-S1" \
      "verify-pr-merged.sh:K1-S1:staging" ; do
    local IFS=':'
    # shellcheck disable=SC2206
    local parts=( $spec )
    unset IFS
    script="${parts[0]}"
    local args=( "${parts[@]:1}" )
    PROJECT_PATH="$primary" run --separate-stderr "$DEVSTORY_SCRIPTS/$script" "${args[@]}"
    if [[ "$stderr" == *"skipped (non-git CWD)"* ]]; then
      echo "$script wrongly skipped: guard read the ambient CWD, not PROJECT_PATH"
      return 1
    fi
  done
}

@test "each chain script still skips with the canonical warning when PROJECT_PATH is non-git (AC6)" {
  # CWD is a REAL repo so an unmoved guard would NOT skip; the skip must come
  # from the guard testing the non-git PROJECT_PATH after the cd. This is what
  # proves the reorder did not break the degradation path.
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cd "$primary"
  local spec script
  for spec in \
      "git-branch.sh:K1-S1:slug" \
      "pr-create.sh:K1-S1:a title" \
      "ci-wait.sh:1234:--timeout:1" \
      "merge.sh:1234:K1-S1" \
      "verify-pr-merged.sh:K1-S1:staging" ; do
    local IFS=':'
    # shellcheck disable=SC2206
    local parts=( $spec )
    unset IFS
    script="${parts[0]}"
    local args=( "${parts[@]:1}" )
    PROJECT_PATH="$NONGIT_CWD" run --separate-stderr "$DEVSTORY_SCRIPTS/$script" "${args[@]}"
    [ "$status" -eq 0 ] || { echo "$script: expected exit 0, got $status"; return 1; }
    [[ "$stderr" == *"skipped (non-git CWD)"* ]] \
      || { echo "$script: missing canonical skip warning"; return 1; }
  done
}

@test "the non-git skip precedes argument validation after the reorder (AC6)" {
  # The discriminating shape: CWD is a real repo (so an unmoved guard would NOT
  # skip) while PROJECT_PATH is non-git. Only the cd-then-guard order makes the
  # guard test PROJECT_PATH and short-circuit before the argument validation.
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  cd "$primary"

  PROJECT_PATH="$NONGIT_CWD" run --separate-stderr \
    "$DEVSTORY_SCRIPTS/pr-create.sh" "K1-S1" "a title" --body-file "$TEST_TMP/does-not-exist.md"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped (non-git CWD)"* ]]
  [[ "$stderr" != *"not readable"* ]]

  PROJECT_PATH="$NONGIT_CWD" run --separate-stderr \
    "$DEVSTORY_SCRIPTS/merge.sh" 1234 "K1-S1" --strategy bogus-strategy
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped (non-git CWD)"* ]]
  [[ "$stderr" != *"Invalid merge_strategy"* ]]
}

@test "pr-create.sh resolves a relative --body-file against PROJECT_PATH after the reorder (AC2)" {
  # PROJECT_PATH is a REAL repo, so the non-git guard cannot short-circuit and
  # the readability check is genuinely reached. The body file exists ONLY inside
  # PROJECT_PATH, so a relative path resolves iff the cd already happened.
  local primary; primary="$(_mk_primary_repo "$TEST_TMP/primary")"
  printf 'body text\n' > "$primary/body.md"
  # CWD is a DIFFERENT real repo, so the guard cannot short-circuit on either
  # ordering and the readability check is genuinely reached in both.
  local elsewhere; elsewhere="$(_mk_primary_repo "$TEST_TMP/elsewhere" main)"
  cd "$elsewhere"
  [ ! -e "$elsewhere/body.md" ]

  PROJECT_PATH="$primary" run --separate-stderr \
    "$DEVSTORY_SCRIPTS/pr-create.sh" "K1-S1" "a title" --body-file "body.md"
  # Before the reorder the check runs pre-cd against the caller's directory and
  # dies "not readable"; after it, the file resolves under PROJECT_PATH.
  [[ "$stderr" != *"--body-file path is not readable"* ]] \
    || { echo "relative --body-file resolved against the caller CWD, not PROJECT_PATH"; return 1; }
}

# ---------------------------------------------------------------------------
# The workflow's own worktree gate, pinned at the fence level
# ---------------------------------------------------------------------------

# _step_3a_region — the Step 3a body from the dev-story skill document.
_step_3a_region() {
  local md="$PLUGIN_ROOT/skills/gaia-dev-story/SKILL.md"
  [ -f "$md" ] || return 1
  awk '/^### Step 3a /{f=1} /^### Step 3b /{f=0} f' "$md"
}

@test "the worktree create call sits inside the mode gate control flow (AC6)" {
  local region; region="$(_step_3a_region)" || { echo "step region not found"; return 1; }
  [ -n "$region" ]

  local body; body="$(printf '%s\n' "$region" | awk '/```bash/{f=1;next} /```/{f=0} f')"
  printf '%s\n' "$body" | grep -q 'worktree_create' \
    || { echo "no create call found in the step fences"; return 1; }

  # Walk the fence bodies tracking whether we are inside the else arm of a
  # `worktree_mode_enabled` gate. EVERY create call must be reached that way --
  # checking only the first gate/else pair would let a create escape its own
  # block while an unrelated earlier gate kept the ordering looking right.
  local line depth=0 gate_depth=-1 in_else=0 unguarded=0
  while IFS= read -r line; do
    case "$line" in
      *"if ! worktree_mode_enabled"*)
        depth=$((depth + 1)); gate_depth="$depth"; in_else=0 ;;
      *"if "*) depth=$((depth + 1)) ;;
      "else"|*" else")
        [ "$depth" = "$gate_depth" ] && in_else=1 ;;
      "fi"|*" fi")
        [ "$depth" = "$gate_depth" ] && { in_else=0; gate_depth=-1; }
        depth=$((depth - 1)) ;;
    esac
    case "$line" in
      *worktree_create*)
        [ "$in_else" = "1" ] || unguarded=$((unguarded + 1)) ;;
    esac
  done <<EOF
$body
EOF

  [ "$unguarded" -eq 0 ] \
    || { echo "$unguarded create call(s) sit outside the mode gate's else arm"; return 1; }
}

@test "the step documents no bypass token for the mode gate (AC6)" {
  local region; region="$(_step_3a_region)" || { echo "step region not found"; return 1; }
  # An "I already checked" argument would be unverifiable by construction, so
  # the step must not carry one.
  if printf '%s\n' "$region" | grep -q 'mode-checked'; then
    echo "the step still references a gate-bypass token"
    return 1
  fi
}
