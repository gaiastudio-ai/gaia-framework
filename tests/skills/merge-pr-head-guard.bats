#!/usr/bin/env bats
# merge-pr-head-guard.bats — protected-branch guard reads PR head, not local HEAD
#
# Validates that merge.sh reads headRefName from gh and passes it to
# assert_branch_not_protected(). Tests are behavioural: they build a bare
# origin + primary checkout on staging (post-teardown state), stub gh,
# and run merge.sh, asserting exit codes and stderr messages.
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

  TEST_TMPDIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/merge-guard.XXXXXX")"

  # Build a minimal bare-origin + primary-checkout fixture that simulates
  # the post-worktree-teardown state (primary checkout on staging).
  _build_merge_fixture() {
    local dev="$TEST_TMPDIR/dev"
    local origin="$TEST_TMPDIR/origin"
    local primary="$TEST_TMPDIR/primary"

    git init -q -b staging "$dev"
    git -C "$dev" config user.email "test@test"
    git -C "$dev" config user.name "test"
    git -C "$dev" commit --allow-empty -q -m "base"

    git clone --bare -q "$dev" "$origin"
    git -C "$dev" remote add origin "$origin" 2>/dev/null ||
      git -C "$dev" remote set-url origin "$origin"

    git clone -q -b staging "$origin" "$primary"
    git -C "$primary" config user.email "test@test"
    git -C "$primary" config user.name "test"

    # Feature branch pushed to origin
    git -C "$dev" checkout -q -b feat/story-branch
    if [ "${FIXTURE_TRAILER:-}" = "1" ]; then
      git -C "$dev" commit --allow-empty -q -m "$(printf 'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>')"
    else
      git -C "$dev" commit --allow-empty -q -m "feat: x"
    fi
    git -C "$dev" push -q origin feat/story-branch

    # Config for assert_pr_target_from_chain
    mkdir -p "$TEST_TMPDIR/cfg"
    printf 'ci_cd:\n  promotion_chain:\n    - branch: staging\n' \
      > "$TEST_TMPDIR/cfg/project-config.yaml"
  }

  # Write a stub gh that returns parameterised headRefName.
  # GH_STUB_HEAD_REF controls the headRefName response:
  #   a branch name  → returned as headRefName
  #   __FAIL__       → gh exits 1
  _write_gh_stub() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'STUBEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${GH_ARGS:-/dev/null}"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefName*) if [ "${GH_STUB_HEAD_REF:-}" = "__FAIL__" ]; then exit 1; fi
                     echo "${GH_STUB_HEAD_REF:-}"; exit 0;;
      *baseRefName*) echo staging; exit 0;;
      *)             echo OPEN; exit 0;;
    esac;;
  "pr checks") echo '[{"bucket":"pass","name":"ci"}]'; exit 0;;
  "pr merge")  echo merged; exit 0;;
  *) exit 0;;
esac
STUBEOF
    chmod +x "$TEST_TMPDIR/bin/gh"
  }

  # Run merge.sh with the fixture and stub gh.
  # $1 = headRefName value for the stub
  # Sets MERGE_RC and MERGE_OUT (combined stdout+stderr).
  _run_merge_fixture() {
    local head_ref="$1"
    _build_merge_fixture
    _write_gh_stub
    local rc=0
    GH_STUB_HEAD_REF="$head_ref" \
    GH_ARGS="$TEST_TMPDIR/gh-args" \
    PROJECT_PATH="$TEST_TMPDIR/primary" \
    PROJECT_ROOT="" \
    CLAUDE_PROJECT_ROOT="" \
    PROJECT_CONFIG="$TEST_TMPDIR/cfg/project-config.yaml" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
      bash "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch \
        > "$TEST_TMPDIR/merge-out" 2>&1 || rc=$?
    MERGE_RC=$rc
    MERGE_OUT="$(cat "$TEST_TMPDIR/merge-out")"
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
  git init -q -b staging "$TEST_TMPDIR/repo"
  git -C "$TEST_TMPDIR/repo" config user.email "test@test"
  git -C "$TEST_TMPDIR/repo" config user.name "test"
  git -C "$TEST_TMPDIR/repo" commit --allow-empty -q -m "init"
  cd "$TEST_TMPDIR/repo"
  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "feat/story-slug"
  [ "$status" -eq 0 ]
}

@test "guard falls back to git rev-parse when no argument provided" {
  [ -f "$INVARIANTS_LIB" ]
  git init -q -b staging "$TEST_TMPDIR/repo"
  git -C "$TEST_TMPDIR/repo" config user.email "test@test"
  git -C "$TEST_TMPDIR/repo" config user.name "test"
  git -C "$TEST_TMPDIR/repo" commit --allow-empty -q -m "init"
  git -C "$TEST_TMPDIR/repo" checkout -b feat/safe-branch -q
  cd "$TEST_TMPDIR/repo"
  source "$INVARIANTS_LIB"
  run assert_branch_not_protected
  [ "$status" -eq 0 ]
}

@test "guard rejects protected branch argument even when local HEAD is safe" {
  [ -f "$INVARIANTS_LIB" ]
  git init -q -b staging "$TEST_TMPDIR/repo"
  git -C "$TEST_TMPDIR/repo" config user.email "test@test"
  git -C "$TEST_TMPDIR/repo" config user.name "test"
  git -C "$TEST_TMPDIR/repo" commit --allow-empty -q -m "init"
  git -C "$TEST_TMPDIR/repo" checkout -b feat/safe-branch -q
  cd "$TEST_TMPDIR/repo"
  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"security-invariant FAIL"* ]]
  [[ "$output" == *"staging"* ]]
}

# ---------------------------------------------------------------------------
# AC1+AC2: merge.sh passes feature-branch PR head to the guard (behavioural)
# ---------------------------------------------------------------------------

@test "merge.sh with feature-branch PR head passes the guard (local HEAD=staging)" {
  _run_merge_fixture "feat/story-branch"
  # The guard must not have fired. merge.sh may fail later — we only care
  # that the protected-branch gate did not trigger.
  [[ "$MERGE_OUT" != *"protected-branch invariant failed"* ]]
  [[ "$MERGE_OUT" != *"could not determine PR head branch"* ]]
}

# ---------------------------------------------------------------------------
# AC3: merge.sh refuses when PR head is a protected branch (behavioural)
# ---------------------------------------------------------------------------

@test "merge.sh refuses when PR head is main" {
  _run_merge_fixture "main"
  [ "$MERGE_RC" -ne 0 ]
  [[ "$MERGE_OUT" == *"protected-branch invariant failed"* ]]
  # gh pr merge must NOT have been called
  if [ -f "$TEST_TMPDIR/gh-args" ]; then
    run grep "pr merge" "$TEST_TMPDIR/gh-args"
    [ "$status" -ne 0 ]
  fi
}

@test "merge.sh refuses when PR head is staging" {
  _run_merge_fixture "staging"
  [ "$MERGE_RC" -ne 0 ]
  [[ "$MERGE_OUT" == *"protected-branch invariant failed"* ]]
  if [ -f "$TEST_TMPDIR/gh-args" ]; then
    run grep "pr merge" "$TEST_TMPDIR/gh-args"
    [ "$status" -ne 0 ]
  fi
}

@test "merge.sh refuses when gh fails to return PR head (fail-closed)" {
  _run_merge_fixture "__FAIL__"
  [ "$MERGE_RC" -ne 0 ]
  [[ "$MERGE_OUT" == *"could not determine PR head branch"* ]]
}

@test "merge.sh refuses when gh returns invalid ref name" {
  _run_merge_fixture "GraphQL: Could not resolve"
  [ "$MERGE_RC" -ne 0 ]
  [[ "$MERGE_OUT" == *"not a valid ref"* ]]
}

# ---------------------------------------------------------------------------
# AC2: stale-base guard uses PR head commit, not local HEAD
# ---------------------------------------------------------------------------

@test "merge.sh stale-base guard uses PR head not local HEAD" {
  # Simulate behind2: PR head rebased on current origin/staging, but
  # primary checkout has not pulled. The guard must pass.
  local dev="$TEST_TMPDIR/dev"
  local origin="$TEST_TMPDIR/origin"
  local primary="$TEST_TMPDIR/primary"

  git init -q -b staging "$dev"
  git -C "$dev" config user.email "test@test"
  git -C "$dev" config user.name "test"
  git -C "$dev" commit --allow-empty -q -m "base"

  git clone --bare -q "$dev" "$origin"
  git -C "$dev" remote add origin "$origin" 2>/dev/null ||
    git -C "$dev" remote set-url origin "$origin"

  git clone -q -b staging "$origin" "$primary"
  git -C "$primary" config user.email "test@test"
  git -C "$primary" config user.name "test"

  # Feature branch
  git -C "$dev" checkout -q -b feat/story-branch
  git -C "$dev" commit --allow-empty -q -m "feat: x"
  git -C "$dev" push -q origin feat/story-branch

  # Another story merges to staging on origin (primary not pulled)
  git -C "$dev" checkout -q staging
  git -C "$dev" commit --allow-empty -q -m "other story merged"
  git -C "$dev" push -q origin staging

  # Rebase feature branch on current staging
  git -C "$dev" checkout -q feat/story-branch
  git -C "$dev" rebase -q staging
  git -C "$dev" push -q -f origin feat/story-branch

  mkdir -p "$TEST_TMPDIR/cfg"
  printf 'ci_cd:\n  promotion_chain:\n    - branch: staging\n' \
    > "$TEST_TMPDIR/cfg/project-config.yaml"

  _write_gh_stub

  local rc=0
  GH_STUB_HEAD_REF="feat/story-branch" \
  GH_ARGS="$TEST_TMPDIR/gh-args" \
  PROJECT_PATH="$primary" \
  PROJECT_ROOT="" \
  CLAUDE_PROJECT_ROOT="" \
  PROJECT_CONFIG="$TEST_TMPDIR/cfg/project-config.yaml" \
  PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$MERGE_SH" 42 E900-S1 --strategy squash --no-delete-branch \
      > "$TEST_TMPDIR/merge-out" 2>&1 || rc=$?

  local out
  out="$(cat "$TEST_TMPDIR/merge-out")"

  # Must NOT abort with stale-base error
  [[ "$out" != *"is not based on"* ]]
}

# ---------------------------------------------------------------------------
# AC3: trailer guard scans PR commits, not local HEAD range
# ---------------------------------------------------------------------------

@test "merge.sh detects attribution trailer in PR commits after teardown" {
  FIXTURE_TRAILER=1 _run_merge_fixture "feat/story-branch"
  [ "$MERGE_RC" -ne 0 ]
  [[ "$MERGE_OUT" == *"assistant attribution trailer"* ]]
  # gh pr merge must NOT have been called
  if [ -f "$TEST_TMPDIR/gh-args" ]; then
    run grep "pr merge" "$TEST_TMPDIR/gh-args"
    [ "$status" -ne 0 ]
  fi
}

@test "guard passes for branch containing protected name as substring" {
  [ -f "$INVARIANTS_LIB" ]
  git init -q -b staging "$TEST_TMPDIR/repo"
  git -C "$TEST_TMPDIR/repo" config user.email "test@test"
  git -C "$TEST_TMPDIR/repo" config user.name "test"
  git -C "$TEST_TMPDIR/repo" commit --allow-empty -q -m "init"
  cd "$TEST_TMPDIR/repo"
  source "$INVARIANTS_LIB"
  run assert_branch_not_protected "feat/main-thing"
  [ "$status" -eq 0 ]
  run assert_branch_not_protected "staging-hotfix"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4: bash 3.2 compatibility
# ---------------------------------------------------------------------------

@test "invariants lib has no bash 4+ features" {
  [ -f "$INVARIANTS_LIB" ]
  local count
  # Associative array declarations
  count="$(grep -cE 'declare[[:space:]]+-A|local[[:space:]]+-A' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  # mapfile / readarray
  count="$(grep -cE '\bmapfile\b|\breadarray\b' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  # ${var,,} or ${var^^}
  count="$(grep -cE '\$\{[a-zA-Z_][a-zA-Z_0-9]*,,' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\$\{[a-zA-Z_][a-zA-Z_0-9]*\^\^' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
}

@test "merge.sh has no bash 4+ features" {
  [ -f "$MERGE_SH" ]
  local count
  count="$(grep -cE 'declare[[:space:]]+-A|local[[:space:]]+-A' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bmapfile\b|\breadarray\b' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC5: no leaked internal identifiers
# ---------------------------------------------------------------------------

@test "no leaked internal ids in invariants lib" {
  [ -f "$INVARIANTS_LIB" ]
  local count
  count="$(grep -cE '\bFR-[0-9]+' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bNFR-[0-9]+' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bSR-[0-9]+' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bADR-[0-9]+' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bAF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -ciE 'per the PRD|see the test plan' "$INVARIANTS_LIB" || true)"
  [ "$count" -eq 0 ]
}

@test "no leaked internal ids in merge.sh" {
  [ -f "$MERGE_SH" ]
  local count
  count="$(grep -cE '\bFR-[0-9]+' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bNFR-[0-9]+' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bSR-[0-9]+' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bADR-[0-9]+' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -cE '\bAF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
  count="$(grep -ciE 'per the PRD|see the test plan' "$MERGE_SH" || true)"
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC6: test fixtures use temp dirs
# ---------------------------------------------------------------------------

@test "this test file writes nothing to the real plugin tree" {
  local this_file="$BATS_TEST_DIRNAME/merge-pr-head-guard.bats"
  [ -f "$this_file" ]
  local count
  # No literal plugin-tree write targets
  count="$(grep -cE '>[[:space:]]+("|'"'"')?(/[^ ]*)?plugins/gaia/' "$this_file" || true)"
  [ "$count" -eq 0 ]
  # No literal .gaia/ write targets (exclude grep pattern strings)
  count="$(grep -cE '>[[:space:]]+("|'"'"')?(/[^ ]*)?\.gaia/' "$this_file" || true)"
  [ "$count" -eq 0 ]
}
