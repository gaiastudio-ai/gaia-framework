#!/usr/bin/env bats
# e55-s6-security-invariants.bats
#
# Story: E55-S6 — Security-controls bash port (TB-10) — un-bypassable by YOLO.
#
# Verifies the three security invariants exposed by
# plugins/gaia/scripts/lib/dev-story-security-invariants.sh:
#   - assert_branch_not_protected
#   - assert_no_secrets_staged
#   - assert_pr_target_from_chain
# AND verifies that pr-create.sh and merge.sh source the lib (regression
# guard against an accidental removal of the source line).
#
# Critical contract: the lib MUST NOT branch on YOLO mode anywhere — a
# code-search regression locks this in (TC-DSH-17 + Test Scenario 11).

load 'test_helper.bash'

setup() { common_setup; _make_local_git_repo; }
teardown() { common_teardown; }

INVARIANTS_SH_REL="lib/dev-story-security-invariants.sh"
INVARIANTS_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/${INVARIANTS_SH_REL}"
PR_CREATE_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/pr-create.sh"
MERGE_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/merge.sh"

# ---------------------------------------------------------------------------
# Source the invariants module as a library and run the named function with
# the remaining args. Output and exit status flow through bats `run`.
# ---------------------------------------------------------------------------
_load_invariants() {
  # shellcheck disable=SC1090
  source "$INVARIANTS_SH"
}

_make_local_git_repo() {
  cd "$TEST_TMP"
  git init -q -b feat/dummy
  git config user.email "dev@example.com"
  git config user.name "Dev"
  # Stamp an initial commit so HEAD exists.
  git commit -q --allow-empty -m "init"
}

# ---------------------------------------------------------------------------
# assert_branch_not_protected
# ---------------------------------------------------------------------------

@test "assert_branch_not_protected: passes on a feature branch" {
  cd "$TEST_TMP"
  git checkout -q -b feat/some-thing
  run bash -c "source '$INVARIANTS_SH' && assert_branch_not_protected"
  [ "$status" -eq 0 ]
}

@test "assert_branch_not_protected: FAILS on main with branch named in message" {
  cd "$TEST_TMP"
  git checkout -q -b main
  run bash -c "source '$INVARIANTS_SH' && assert_branch_not_protected"
  [ "$status" -ne 0 ]
  [[ "$output" == *"main"* ]]
}

@test "assert_branch_not_protected: FAILS on staging with branch named in message" {
  cd "$TEST_TMP"
  git checkout -q -b staging
  run bash -c "source '$INVARIANTS_SH' && assert_branch_not_protected"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging"* ]]
}

@test "assert_branch_not_protected: passes on substring branch like feat/main-thing (no false-positive)" {
  cd "$TEST_TMP"
  git checkout -q -b feat/main-thing
  run bash -c "source '$INVARIANTS_SH' && assert_branch_not_protected"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# assert_no_secrets_staged
# ---------------------------------------------------------------------------

@test "assert_no_secrets_staged: passes when nothing is staged" {
  cd "$TEST_TMP"
  git checkout -q -b feat/clean
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -eq 0 ]
}

@test "assert_no_secrets_staged: FAILS on staged .env" {
  cd "$TEST_TMP"
  git checkout -q -b feat/env
  printf 'X=1\n' > .env
  git add .env
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -ne 0 ]
  [[ "$output" == *".env"* ]]
}

@test "assert_no_secrets_staged: FAILS on staged .env.local" {
  cd "$TEST_TMP"
  git checkout -q -b feat/env-local
  printf 'X=1\n' > .env.local
  git add .env.local
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -ne 0 ]
  [[ "$output" == *".env.local"* ]]
}

@test "assert_no_secrets_staged: FAILS on staged db-credentials.json" {
  cd "$TEST_TMP"
  git checkout -q -b feat/creds
  printf '{}\n' > db-credentials.json
  git add db-credentials.json
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credentials"* ]]
}

@test "assert_no_secrets_staged: FAILS on staged content matching AKIA pattern" {
  cd "$TEST_TMP"
  git checkout -q -b feat/akia
  printf 'AKIA0123456789ABCDEF\n' > config.txt
  git add config.txt
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AKIA"* ]]
}

@test "assert_no_secrets_staged: passes on innocuous staged file" {
  cd "$TEST_TMP"
  git checkout -q -b feat/innocuous
  printf 'export function add(a, b) { return a + b; }\n' > src.ts
  git add src.ts
  run bash -c "source '$INVARIANTS_SH' && assert_no_secrets_staged"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# assert_pr_target_from_chain
# ---------------------------------------------------------------------------

@test "assert_pr_target_from_chain: passes when target matches chain[0].branch" {
  cd "$TEST_TMP"
  cat > project-config.yaml <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
EOF
  PROJECT_CONFIG="$TEST_TMP/project-config.yaml" \
    run bash -c "source '$INVARIANTS_SH' && assert_pr_target_from_chain staging"
  [ "$status" -eq 0 ]
}

@test "assert_pr_target_from_chain: FAILS on mismatch with both values in message" {
  cd "$TEST_TMP"
  cat > project-config.yaml <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
EOF
  PROJECT_CONFIG="$TEST_TMP/project-config.yaml" \
    run bash -c "source '$INVARIANTS_SH' && assert_pr_target_from_chain feat/x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging"* ]]
  [[ "$output" == *"feat/x"* ]]
}

@test "assert_pr_target_from_chain: FAILS clearly when config file is missing" {
  cd "$TEST_TMP"
  PROJECT_CONFIG="$TEST_TMP/nope.yaml" \
    run bash -c "source '$INVARIANTS_SH' && assert_pr_target_from_chain staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# E55-S9 — discovery ladder: when CWD is a sub-tree of a project whose
# config/ lives at an ancestor (the gaia-public/ shape), assert_pr_target_-
# from_chain MUST walk upward to find the config rather than false-flagging.
@test "assert_pr_target_from_chain: discovers config via upward walk (E55-S9)" {
  mkdir -p "$TEST_TMP/anc/config" "$TEST_TMP/anc/sub"
  cat > "$TEST_TMP/anc/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
EOF
  cd "$TEST_TMP/anc/sub"
  unset PROJECT_CONFIG
  run bash -c "source '$INVARIANTS_SH' && assert_pr_target_from_chain staging"
  [ "$status" -eq 0 ]
}

@test "assert_pr_target_from_chain: CLAUDE_PROJECT_ROOT override resolves config (E55-S9)" {
  mkdir -p "$TEST_TMP/proj/config" "$TEST_TMP/elsewhere"
  cat > "$TEST_TMP/proj/config/project-config.yaml" <<'EOF'
ci_cd:
  promotion_chain:
    - id: staging
      branch: staging
EOF
  cd "$TEST_TMP/elsewhere"
  unset PROJECT_CONFIG
  CLAUDE_PROJECT_ROOT="$TEST_TMP/proj" \
    run bash -c "source '$INVARIANTS_SH' && assert_pr_target_from_chain staging"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Regression guards (TC-DSH-17 + Scenario 11)
# ---------------------------------------------------------------------------

@test "regression: pr-create.sh sources lib/dev-story-security-invariants.sh" {
  run grep -F "dev-story-security-invariants.sh" "$PR_CREATE_SH"
  [ "$status" -eq 0 ]
}

@test "regression: merge.sh sources lib/dev-story-security-invariants.sh" {
  run grep -F "dev-story-security-invariants.sh" "$MERGE_SH"
  [ "$status" -eq 0 ]
}

@test "regression: invariants module never branches on is_yolo (YOLO does not bypass)" {
  run grep -F "is_yolo" "$INVARIANTS_SH"
  [ "$status" -ne 0 ]
}
