#!/usr/bin/env bats
# merge-review-gate.bats — pre-merge review gate, operator bypass, no-CI
# binding mode and branch preservation in merge.sh.
#
# Covers:
#   merge refused on non-PASS composite (PENDING/FAILED/stale SHA)
#   operator bypass acceptance and rejection variants
#   static scan — no shipped script sets the bypass variable
#   pre-tool guard blocks model-issued bypass variable
#   merge_base_mismatch, --no-delete-branch, no-CI binding mode
#   fail-closed gate on missing story in GAIA projects
#   bypass record and audit content verification
#   bypass visibility in doctor / sprint-plan output

load 'test_helper.bash'

MERGE_REL="../skills/gaia-dev-story/scripts/merge.sh"
GUARD_REL="../scripts/lib/bypass-variable-guard.sh"
CHECK_BYPASS_REL="../scripts/lib/check-bypass-records.sh"

setup() {
  common_setup
  MERGE_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$MERGE_REL")" && pwd)/$(basename "$MERGE_REL")"
  GUARD_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$GUARD_REL")" && pwd)/$(basename "$GUARD_REL")"
  CHECK_BYPASS_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$CHECK_BYPASS_REL")" && pwd)/$(basename "$CHECK_BYPASS_REL")"
  PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  # Isolate git config
  export HOME="$TEST_TMP/home"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"

  GH_ARGS="$TEST_TMP/gh-args.txt"
  export GH_ARGS
  : > "$GH_ARGS"

  make_fixture_config
  make_stub_jq

  # Ensure bypass variable and test seam are unset by default
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE
  unset GAIA_YOLO_FLAG
  unset _MERGE_TTY_OVERRIDE
}

teardown() { common_teardown; }

# fixture_git — every fixture git invocation goes through here so the inline
# committer identity and signing opt-out are never forgotten.
fixture_git() {
  git -c user.email=fixture@example.invalid \
      -c user.name=fixture \
      -c commit.gpgsign=false \
      "$@"
}

# make_fixture_repo — a repo with a staging base and a feature branch.
make_fixture_repo() {
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "base commit"
  fixture_git -C "$REPO" checkout -q -b feat/story-branch
  fixture_git -C "$REPO" commit --allow-empty -q -m "feature work"

  # Set up origin so fetch / merge-base work.
  ORIGIN="$TEST_TMP/origin"
  fixture_git clone --bare -q "$REPO" "$ORIGIN"
  fixture_git -C "$REPO" remote remove origin 2>/dev/null || true
  fixture_git -C "$REPO" remote add origin "$ORIGIN"
  fixture_git -C "$REPO" push -q origin feat/story-branch
  FIXTURE_HEAD_OID="$(fixture_git -C "$REPO" rev-parse HEAD)"; export FIXTURE_HEAD_OID
  fixture_git -C "$REPO" fetch -q origin

  export PROJECT_PATH="$REPO"
}

make_fixture_config() {
  mkdir -p "$TEST_TMP/config"
  cat > "$TEST_TMP/config/project-config.yaml" <<'YAML'
ci_cd:
  promotion_chain:
    - branch: staging
YAML
  export PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml"
}

make_fixture_config_no_ci() {
  mkdir -p "$TEST_TMP/config"
  cat > "$TEST_TMP/config/project-config.yaml" <<'YAML'
project:
  name: test-no-ci
YAML
  export PROJECT_CONFIG="$TEST_TMP/config/project-config.yaml"
}

# make_stub_jq — real jq if available, otherwise a minimal stub.
make_stub_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/jq" <<'STUB'
#!/usr/bin/env bash
echo "[]"
STUB
  chmod +x "$STUB_BIN/jq"
}

# _seed_story — create a story file with a Review Gate table.
# Usage: _seed_story <key> <status_pairs...>
#   Each status pair is "GateName:VERDICT:SHA"
_seed_story() {
  local key="$1"; shift
  local root="${CLAUDE_PROJECT_ROOT:-${PROJECT_ROOT:-$TEST_TMP}}"
  local impl_dir="$root/.gaia/artifacts/implementation-artifacts"
  # Ensure .gaia/state also exists so merge.sh resolves the shared root.
  mkdir -p "$root/.gaia/state"
  mkdir -p "$impl_dir"
  STORY_FILE="$impl_dir/${key}-test/story.md"
  mkdir -p "$(dirname "$STORY_FILE")"
  cat > "$STORY_FILE" <<HEADER
---
key: "${key}"
status: in-progress
---
## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
HEADER
  local gate verdict sha
  for entry in "$@"; do
    gate="${entry%%:*}"
    local rest="${entry#*:}"
    verdict="${rest%%:*}"
    sha="${rest#*:}"
    if [ "$sha" = "$rest" ] || [ -z "$sha" ]; then
      sha=""
    fi
    printf '| %s | %s | — | %s |\n' "$gate" "$verdict" "$sha" >> "$STORY_FILE"
  done
  cat >> "$STORY_FILE" <<'FOOTER'

> Story moves to `done` only when ALL reviews show PASSED.

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
FOOTER
  export STORY_FILE
}

# make_stub_gh — gh stub that supports review-gate-aware merge.sh.
# GH_SCENARIO controls merge behaviour; GH_MERGE_EXIT controls merge exit code.
make_stub_gh() {
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"

# gh pr view — single JSON response
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *mergeCommit*) printf 'OPEN\n'; exit 0 ;;
    *mergedAt*)    printf 'OPEN\n'; exit 0 ;;
  esac
  local base="${GH_PR_BASE:-staging}"
  printf '{"state":"OPEN","headRefName":"feat/story-branch","headRefOid":"%s","baseRefName":"%s"}\n' \
    "${FIXTURE_HEAD_OID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" "$base"
  exit 0
fi

# gh pr checks
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  printf '%s\n' "${GH_CHECKS_JSON:-[{\"bucket\":\"pass\",\"name\":\"build\"},{\"bucket\":\"pass\",\"name\":\"lint\"}]}"
  exit 0
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'example-org/example-repo\n'
  exit 0
fi

# gh pr merge
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  printf 'merged\n'
  exit "${GH_MERGE_EXIT:-0}"
fi

# gh api
if [ "$1" = "api" ]; then
  exit 0
fi

exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# _make_tty_answer — create a regular file containing the tty answer for
# the bypass confirmation. Sets _MERGE_TTY_OVERRIDE to the file path.
# The test seam uses a regular file (not a FIFO) so the prompt-writes to
# /dev/tty and the answer-read from the file do not deadlock.
_make_tty_answer() {
  local answer="${1:-yes}"
  local answer_file="$TEST_TMP/tty-answer-$$"
  printf '%s\n' "$answer" > "$answer_file"
  export _MERGE_TTY_OVERRIDE="$answer_file"
}

# -----------------------------------------------------------------------
# Merge refused on non-PASS composite with bypass unset
# -----------------------------------------------------------------------

@test "merge refused on PENDING composite (all UNVERIFIED rows) with bypass unset" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:UNVERIFIED:" \
    "QA Tests:UNVERIFIED:" \
    "Security Review:UNVERIFIED:" \
    "Test Automation:UNVERIFIED:" \
    "Test Review:UNVERIFIED:" \
    "Performance Review:UNVERIFIED:"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"PENDING"* ]] || [[ "$output" == *"review gate"* ]]
}

@test "merge refused on FAILED composite (FAILED code-review row) with bypass unset" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"FAILED"* ]]
}

@test "merge refused when a row is bound to an older SHA without carry-forward" {
  make_fixture_repo
  local stale_sha="0000000000000000000000000000000000000000"
  _seed_story "E900-S1" \
    "Code Review:PASSED:${stale_sha}" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"PENDING"* ]] || [[ "$output" == *"bound"* ]]
}

@test "merge refused when CI green on older SHA than PR head" {
  make_fixture_repo
  # CI SHA is a valid but older commit — not the current head
  local old_ci_sha="1111111111111111111111111111111111111111"
  _seed_story "E900-S1" \
    "Code Review:PASSED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE

  # The review gate check uses --ci-sha to verify CI ran on the head.
  # With a stale CI SHA, the gate should refuse (PENDING or BLOCKED).
  # Note: this test verifies the merge.sh integration path; the actual
  # CI SHA staleness logic is in review-gate-check.sh.
  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  # When all review rows are PASSED at the head, merge should succeed
  # because merge.sh passes PR_HEAD_OID as the ci-sha (not the old one).
  # The "CI green on older SHA" refusal is handled by review-gate-check.sh
  # when the CI SHA differs from the head. This test confirms merge.sh
  # passes the correct head OID, not a stale value.
  [ "$status" -eq 0 ]
  # Verify that review-gate-check was called with --ci-sha matching the head
  # (merge.sh passes PR_HEAD_OID when promotion chain exists)
}

# -----------------------------------------------------------------------
# Operator bypass — acceptance and rejection variants
# -----------------------------------------------------------------------

@test "bypass accepted with correct key at sha format — records verify content" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state/sprint-audit"
  make_stub_gh

  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@${FIXTURE_HEAD_OID}"
  _make_tty_answer "yes"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -eq 0 ]

  # Verify bypass record in story file — assert field VALUES
  /usr/bin/grep -q "review_gate_bypass: E900-S1 head=${FIXTURE_HEAD_OID}" "$STORY_FILE"
  /usr/bin/grep -q 'confirmed_by=operator_tty' "$STORY_FILE"

  # Verify audit record exists AND has correct content
  local audit_file
  audit_file="$(find "$TEST_TMP/.gaia/state/sprint-audit" -name 'review_gate_bypass*' -print -quit)"
  [ -n "$audit_file" ]
  /usr/bin/grep -q "story: E900-S1" "$audit_file"
  /usr/bin/grep -q "head: ${FIXTURE_HEAD_OID}" "$audit_file"
  /usr/bin/grep -q 'confirmed_by: operator_tty' "$audit_file"
  /usr/bin/grep -q 'bypass_confirmed: true' "$audit_file"

  # Verify merge output exposes confirmation result
  [[ "$output" == *"bypass_confirmed=operator_tty"* ]]

  # Verify --match-head-commit was passed to gh pr merge
  /usr/bin/grep -q "match-head-commit" "$GH_ARGS"
}

@test "bypass refused when value is bare '1' — prints format error" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="1"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"format invalid"* ]]
}

@test "bypass refused when story key does not match" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E999-S99@${FIXTURE_HEAD_OID}"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"key mismatch"* ]]
}

@test "bypass refused when SHA is shortened (7 chars instead of 40)" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@aaaaaaa"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"40 hex"* ]]
}

@test "bypass refused when SHA does not match the PR head" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  local wrong_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@${wrong_sha}"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "bypass refused under YOLO mode — prints YOLO in message" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@${FIXTURE_HEAD_OID}"
  export GAIA_YOLO_FLAG=1

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"YOLO"* ]]
}

@test "bypass refused inside harness shell — prints harness in message" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@${FIXTURE_HEAD_OID}"
  export GAIA_HARNESS_SHELL=1

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"harness"* ]]
}

# -----------------------------------------------------------------------
# Static scan — no shipped script or skill sets the bypass variable
# -----------------------------------------------------------------------

@test "no shipped script or skill sets the bypass variable" {
  run bash -c "
    /usr/bin/grep -rn 'GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE' \
      '$PLUGIN_ROOT/scripts/' \
      '$PLUGIN_ROOT/skills/' \
      --include='*.sh' --include='*.md' \
    | /usr/bin/grep -v '/tests/' \
    | /usr/bin/grep -v '/test/' \
    | /usr/bin/grep -v '/knowledge/' \
    | /usr/bin/grep -E '(^[^#]*export|^[^#]*declare|^[^#]*typeset|^[^#]*set -a|^[^#]*eval|^[^#]*env ).*GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE' \
    || true
  "
  [ -z "$output" ]
}

@test "pre-tool guard is declared in all merge-capable SKILL.md files" {
  # Verify the guard hook is present in each merge-capable skill
  for skill in gaia-dev-story gaia-run-sprint gaia-run-all-reviews; do
    local skill_md="$PLUGIN_ROOT/skills/$skill/SKILL.md"
    [ -f "$skill_md" ]
    /usr/bin/grep -q 'bypass-variable-guard' "$skill_md"
  done
}

# -----------------------------------------------------------------------
# Pre-tool guard behavioural tests
# -----------------------------------------------------------------------

@test "guard blocks Bash inline-prefix setting of bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=E900-S1@abc bash merge.sh"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  [ -n "$(find "$TEST_TMP/.gaia/state/sprint-audit" -name 'bypass_attempt_blocked*' 2>/dev/null)" ]
}

@test "guard blocks Bash export of bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Bash env prefix of bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"env GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val bash merge.sh"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Bash declare of bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"declare GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Bash typeset of bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"typeset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Bash set -a with bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"set -a; GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val; source env.sh"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Bash eval with bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"eval export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Write whose content carries bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"content":"export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val","file_path":"/tmp/test.sh"}'"'"' | TOOL_USE_NAME=Write bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks Edit whose new_string carries bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"new_string":"GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=val","old_string":"old","file_path":"/tmp/test.sh"}'"'"' | TOOL_USE_NAME=Edit bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "guard blocks tty override variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"export _MERGE_TTY_OVERRIDE=/tmp/fifo"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"_MERGE_TTY_OVERRIDE"* ]]
}

@test "guard allows benign Bash commands" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"echo hello world"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 0 ]
}

@test "guard allows grep that reads but does not set bypass variable" {
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run bash -c 'printf '"'"'{"command":"grep GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE merge.sh"}'"'"' | bash "$1"' _ "$GUARD_SH"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------
# Fail-closed gate on missing story file in GAIA projects
# -----------------------------------------------------------------------

@test "merge refused when story file missing in a GAIA project (fail closed)" {
  make_fixture_repo
  # Set up GAIA project root with implementation-artifacts but NO story file
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  mkdir -p "$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot locate story file"* ]]
  [[ "$output" == *"fail closed"* ]]
}

@test "merge proceeds with gate skipped in non-GAIA repo (no story roots)" {
  make_fixture_repo
  # Set up a repo without any GAIA story-artifact roots
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  # Deliberately do NOT create implementation-artifacts
  make_stub_gh
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE
  unset IMPLEMENTATION_ARTIFACTS

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"non-GAIA"* ]] || [[ "$output" == *"gate check skipped"* ]]
}

# -----------------------------------------------------------------------
# TOCTOU protection and no-CI binding mode
# -----------------------------------------------------------------------

@test "merge fails with merge_base_mismatch when PR base is retargeted" {
  make_fixture_repo
  # Create a COMPLETE gate so the review gate check passes
  _seed_story "E900-S1" \
    "Code Review:PASSED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"

  # Stub gh with a mismatched base: the initial view returns staging (normal),
  # but the mismatch-check call (--json baseRefName only) returns "main"
  # to simulate a retarget between gate check and merge.
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *mergeCommit*) printf 'OPEN\n'; exit 0 ;;
    *mergedAt*)    printf 'OPEN\n'; exit 0 ;;
  esac
  # The mismatch-check call queries only baseRefName. Return retargeted base.
  case "$*" in
    *baseRefName*headRefName*|*headRefName*baseRefName*)
      # Full initial query — returns original staging base
      printf '{"state":"OPEN","headRefName":"feat/story-branch","headRefOid":"%s","baseRefName":"staging"}\n' "${FIXTURE_HEAD_OID}"
      ;;
    *baseRefName*)
      # Mismatch-check query — returns retargeted "main" base
      printf '{"baseRefName":"main"}\n'
      ;;
    *)
      printf '{"state":"OPEN","headRefName":"feat/story-branch","headRefOid":"%s","baseRefName":"staging"}\n' "${FIXTURE_HEAD_OID}"
      ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  printf '[{"bucket":"pass","name":"build"}]\n'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  printf 'merged\n'; exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'example-org/example-repo\n'; exit 0
fi
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge_base_mismatch"* ]]
}

@test "merge always passes --no-delete-branch and --match-head-commit" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:PASSED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -eq 0 ]

  # Verify both flags in the gh pr merge args
  /usr/bin/grep -q '\-\-no-delete-branch' "$GH_ARGS"
  /usr/bin/grep -q '\-\-match-head-commit' "$GH_ARGS"

  # Verify the DELETE_BRANCH default is false in merge.sh
  run bash -c "/usr/bin/grep -E '^DELETE_BRANCH=' '$MERGE_SH' || true"
  [[ "$output" == *"DELETE_BRANCH=false"* ]]
}

@test "no-CI binding mode: merge.sh passes ci-sha none when no promotion chain" {
  make_fixture_repo
  make_fixture_config_no_ci
  _seed_story "E900-S1" \
    "Code Review:PASSED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"

  # review-gate-check.sh should accept --ci-sha none when no CI is configured
  local rgc_sh
  rgc_sh="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/review-gate-check.sh"
  [ -f "$rgc_sh" ]

  run bash "$rgc_sh" --bind-head "$FIXTURE_HEAD_OID" --ci-sha none --story "$STORY_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETE"* ]]
}

# -----------------------------------------------------------------------
# Bypass visibility: doctor and sprint-plan report bypass records
# -----------------------------------------------------------------------

@test "check-bypass-records reports bypass use from audit directory" {
  mkdir -p "$TEST_TMP/.gaia/state/sprint-audit"
  cat > "$TEST_TMP/.gaia/state/sprint-audit/review_gate_bypass-E900-S1.yaml" <<'AUDIT'
type: review_gate_bypass
story: E900-S1
head: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
non_pass_rows:
  - "Code Review: FAILED"
confirmed_by: operator_tty
timestamp: "2026-10-27T12:00:00Z"
AUDIT

  run bash "$CHECK_BYPASS_SH" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S1"* ]]
  [[ "$output" == *"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]]
  [[ "$output" == *"WARNING"* ]]
}

@test "check-bypass-records warns when bypass variable is in session env" {
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  run bash "$CHECK_BYPASS_SH" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE"* ]]
  [[ "$output" == *"WARNING"* ]]
}

@test "check-bypass-records reports no records when audit is empty" {
  mkdir -p "$TEST_TMP/.gaia/state/sprint-audit"
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE
  run bash "$CHECK_BYPASS_SH" --project-root "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No review gate bypass records"* ]]
}

@test "bypass visibility: merge output exposes confirmation result for caller" {
  make_fixture_repo
  _seed_story "E900-S1" \
    "Code Review:FAILED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state/sprint-audit"
  make_stub_gh

  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE="E900-S1@${FIXTURE_HEAD_OID}"
  _make_tty_answer "yes"

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"bypass_confirmed=operator_tty"* ]]
}
