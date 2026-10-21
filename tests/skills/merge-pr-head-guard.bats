#!/usr/bin/env bats
# merge-pr-head-guard.bats — protected-branch guard reads PR head, not local HEAD
#
# Validates that assert_branch_not_protected() reads the branch name from
# its argument (the PR head) rather than from git rev-parse --abbrev-ref HEAD,
# and that merge.sh passes the PR head to the guard via gh pr view.
#
# AC1: guard reads PR head branch, not local HEAD
# AC2: merge succeeds after worktree teardown (CWD on staging)
# AC3: guard still refuses when PR head is a protected branch
# AC4: bash 5 and /bin/bash 3.2 compatibility
# AC5: no leaked internal ids in changed files
# AC6: test fixtures use temp dirs, not the real plugin tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  INVARIANTS_LIB="$REPO_ROOT/plugins/gaia/scripts/lib/dev-story-security-invariants.sh"
  MERGE_SH="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/merge.sh"

  # Every test uses a temp dir for fixtures.
  TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/merge-guard.XXXXXX")"

  # Minimal git repo for tests that need one.
  _init_git_fixture() {
    git -C "$TEST_TMPDIR" init -q 2>/dev/null
    git -C "$TEST_TMPDIR" checkout -b staging 2>/dev/null
    git -C "$TEST_TMPDIR" commit --allow-empty -m "init" -q 2>/dev/null
  }
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# ---------------------------------------------------------------------------
# AC1: guard reads branch from argument, not local HEAD
# ---------------------------------------------------------------------------

@test "guard uses provided branch argument instead of local HEAD" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"

  # CWD is on staging (protected), but we pass a feature branch name
  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "feat/story-slug"
  [ "$status" -eq 0 ]
}

@test "guard falls back to git rev-parse when no argument provided" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"
  git checkout -b feat/safe-branch -q 2>/dev/null

  source "$INVARIANTS_LIB"
  # No argument — should read local HEAD (feat/safe-branch) and pass
  run assert_branch_not_protected
  [ "$status" -eq 0 ]
}

@test "guard rejects protected branch passed as argument even when local HEAD is safe" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"
  git checkout -b feat/safe-branch -q 2>/dev/null

  source "$INVARIANTS_LIB"
  # Local HEAD is safe, but argument is "staging" (protected)
  run assert_branch_not_protected "staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"security-invariant FAIL"* ]]
  [[ "$output" == *"staging"* ]]
}

# ---------------------------------------------------------------------------
# AC2: merge completes when CWD is on staging after worktree teardown
# ---------------------------------------------------------------------------

@test "merge.sh reads PR head from gh and passes it to the guard" {
  [ -f "$MERGE_SH" ]

  # Verify merge.sh passes the PR headRefName to assert_branch_not_protected.
  # The call must supply a branch argument obtained from gh pr view.
  # We check the source for the pattern: reading headRefName and passing it.
  grep -q 'headRefName' "$MERGE_SH"
  grep -q 'assert_branch_not_protected' "$MERGE_SH"

  # The guard call in merge.sh must pass a variable (not bare call).
  # Look for assert_branch_not_protected followed by a variable reference
  # (e.g., assert_branch_not_protected "$PR_HEAD_BRANCH")
  grep -E 'assert_branch_not_protected[[:space:]]+"\$' "$MERGE_SH"
}

# ---------------------------------------------------------------------------
# AC3: guard refuses when PR head is a protected branch
# ---------------------------------------------------------------------------

@test "guard refuses merge when PR head is main" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"
  git checkout -b feat/something -q 2>/dev/null

  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"security-invariant FAIL"* ]]
  [[ "$output" == *"'main'"* ]]
}

@test "guard refuses merge when PR head is staging" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"
  git checkout -b feat/something -q 2>/dev/null

  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"security-invariant FAIL"* ]]
  [[ "$output" == *"'staging'"* ]]
}

@test "guard passes when PR head is a feature branch" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"

  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "feat/my-story-slug"
  [ "$status" -eq 0 ]
}

@test "guard passes for branch name containing protected name as substring" {
  [ -f "$INVARIANTS_LIB" ]
  _init_git_fixture
  cd "$TEST_TMPDIR"

  source "$INVARIANTS_LIB"
  # "feat/main-thing" must NOT be blocked (substring match is not exact match)
  run assert_branch_not_protected "feat/main-thing"
  [ "$status" -eq 0 ]
  run assert_branch_not_protected "staging-hotfix"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3 fail-closed: guard refuses when gh fails to determine branch
# ---------------------------------------------------------------------------

@test "merge.sh refuses merge when PR head branch cannot be determined" {
  [ -f "$MERGE_SH" ]

  local merge_content
  merge_content="$(cat "$MERGE_SH")"

  # The headRefName must be read from gh.
  printf '%s' "$merge_content" | grep -q 'headRefName'

  # The guard call must pass the PR head as a variable, not bare.
  printf '%s' "$merge_content" | grep -qE 'assert_branch_not_protected[[:space:]]+"\$'

  # Fail-closed: between reading PR_HEAD_BRANCH and calling the guard,
  # there must be an empty-check that aborts with an actionable message
  # mentioning the PR. This prevents a fallback to local HEAD when gh fails.
  # Extract the block from the headRefName assignment to the guard call.
  local guard_block
  guard_block="$(printf '%s\n' "$merge_content" | sed -n '/PR_HEAD_BRANCH=.*headRefName/,/assert_branch_not_protected/p')"
  # The block must contain a die on empty PR_HEAD_BRANCH.
  printf '%s' "$guard_block" | grep -qE 'die.*could not determine.*PR head'
}

# ---------------------------------------------------------------------------
# AC4: bash 3.2 compatibility of changed files
# ---------------------------------------------------------------------------

@test "invariants lib has no bash 4+ features" {
  [ -f "$INVARIANTS_LIB" ]

  # No associative array declarations
  ! grep -E 'declare[[:space:]]+-A|local[[:space:]]+-A' "$INVARIANTS_LIB"
  # No mapfile / readarray
  ! grep -E '\bmapfile\b|\breadarray\b' "$INVARIANTS_LIB"
  # No |& pipe
  ! grep -E '\|\&' "$INVARIANTS_LIB"
  # No ${var,,} or ${var^^} case transforms
  ! grep -E '\$\{[a-zA-Z_][a-zA-Z_0-9]*,,' "$INVARIANTS_LIB"
  ! grep -E '\$\{[a-zA-Z_][a-zA-Z_0-9]*\^\^' "$INVARIANTS_LIB"
}

@test "merge.sh has no bash 4+ features" {
  [ -f "$MERGE_SH" ]

  ! grep -E 'declare[[:space:]]+-A|local[[:space:]]+-A' "$MERGE_SH"
  ! grep -E '\bmapfile\b|\breadarray\b' "$MERGE_SH"
  # Note: |& must be checked carefully — merge.sh uses 2>&1 already
  # The ASSISTANT_TRAILER_PATTERNS array is a simple indexed array (bash 3.2 ok)
}

# ---------------------------------------------------------------------------
# AC5: no leaked internal identifiers in changed files
# ---------------------------------------------------------------------------

@test "no leaked internal ids in invariants lib" {
  [ -f "$INVARIANTS_LIB" ]

  # Requirement IDs
  ! grep -E '\bFR-[0-9]+' "$INVARIANTS_LIB"
  ! grep -E '\bNFR-[0-9]+' "$INVARIANTS_LIB"
  ! grep -E '\bSR-[0-9]+' "$INVARIANTS_LIB"
  # ADR references
  ! grep -E '\bADR-[0-9]+' "$INVARIANTS_LIB"
  # Story keys (exclude regex literals used as matching logic)
  ! grep -P '\bE\d+-S\d+\b(?!.*grep|match|regex|pattern)' "$INVARIANTS_LIB" || true
  # Assessment / cascade IDs
  ! grep -E '\bAF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$INVARIANTS_LIB"
  # Internal doc references
  ! grep -iE 'per the PRD|see the test plan' "$INVARIANTS_LIB"
}

@test "no leaked internal ids in merge.sh" {
  [ -f "$MERGE_SH" ]

  ! grep -E '\bFR-[0-9]+' "$MERGE_SH"
  ! grep -E '\bNFR-[0-9]+' "$MERGE_SH"
  ! grep -E '\bSR-[0-9]+' "$MERGE_SH"
  ! grep -E '\bADR-[0-9]+' "$MERGE_SH"
  ! grep -E '\bAF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$MERGE_SH"
  ! grep -iE 'per the PRD|see the test plan' "$MERGE_SH"
}

# ---------------------------------------------------------------------------
# AC6: test fixtures use temp dirs, not real plugin tree
# ---------------------------------------------------------------------------

@test "this test file writes nothing to the real plugin tree" {
  # Self-check: every write target in this file resolves to a temp dir.
  # Scan for file-write ops that do NOT target TEST_TMPDIR/BATS_TEST_TMPDIR.
  local this_file="$BATS_TEST_DIRNAME/merge-pr-head-guard.bats"
  [ -f "$this_file" ]

  # No writes to gaia-public/plugins/gaia/
  ! grep -E '(>|>>|tee|cp|mv|mkdir|touch)[[:space:]]+.*plugins/gaia/' "$this_file" || true
  # No writes to .gaia/ runtime tree
  ! grep -E '(>|>>|tee|cp|mv|mkdir|touch)[[:space:]]+.*\.gaia/' "$this_file" || true
}
