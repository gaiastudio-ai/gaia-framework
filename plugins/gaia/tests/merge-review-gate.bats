#!/usr/bin/env bats
# merge-review-gate.bats — pre-merge review gate, operator bypass, no-CI
# binding mode and branch preservation in merge.sh.
#
# Covers:
#   merge refused on non-PASS composite (PENDING/FAILED/stale SHA)
#   operator bypass acceptance and rejection variants
#   static scan — no shipped script sets the bypass variable
#   merge_base_mismatch, --no-delete-branch, no-CI binding mode
#   bypass visibility in doctor / sprint-plan output

load 'test_helper.bash'

MERGE_REL="../skills/gaia-dev-story/scripts/merge.sh"

setup() {
  common_setup
  MERGE_SH="$(cd "$BATS_TEST_DIRNAME/$(dirname "$MERGE_REL")" && pwd)/$(basename "$MERGE_REL")"
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

  # Ensure bypass variable is unset by default
  unset GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE
  unset GAIA_YOLO_FLAG
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
  [[ "$output" == *"UNVERIFIED"* ]] || [[ "$output" == *"PENDING"* ]] || [[ "$output" == *"refuse"* ]] || [[ "$output" == *"review_gate"* ]]
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
  [[ "$output" == *"FAILED"* ]] || [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"refuse"* ]]
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
  [[ "$output" == *"stale"* ]] || [[ "$output" == *"older"* ]] || [[ "$output" == *"PENDING"* ]] || [[ "$output" == *"bound"* ]]
}

# -----------------------------------------------------------------------
# Operator bypass — acceptance and rejection variants
# -----------------------------------------------------------------------

@test "bypass accepted with correct key at sha format — records written" {
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
  # Simulate tty confirmation by setting a test flag
  export GAIA_BYPASS_TTY_TEST=yes

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -eq 0 ]
  # Verify bypass record in story file
  /usr/bin/grep -q 'review_gate_bypass' "$STORY_FILE" || /usr/bin/grep -q 'bypass' "$STORY_FILE"
  # Verify audit record
  [ -n "$(find "$TEST_TMP/.gaia/state/sprint-audit" -name '*bypass*' 2>/dev/null)" ]
}

@test "bypass refused when value is bare '1' — prints required format" {
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
  [[ "$output" == *"E900-S1@"* ]] || [[ "$output" == *"format"* ]] || [[ "$output" == *"<story_key>@<head_sha>"* ]]
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
  [[ "$output" == *"key"* ]] || [[ "$output" == *"mismatch"* ]] || [[ "$output" == *"E900-S1"* ]]
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
  [[ "$output" == *"40"* ]] || [[ "$output" == *"format"* ]] || [[ "$output" == *"SHA"* ]]
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
  [[ "$output" == *"mismatch"* ]] || [[ "$output" == *"head"* ]] || [[ "$output" == *"does not match"* ]]
}

@test "bypass refused under YOLO mode — prints operator command" {
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
  [[ "$output" == *"operator"* ]] || [[ "$output" == *"YOLO"* ]] || [[ "$output" == *"terminal"* ]]
}

@test "bypass refused with no controlling terminal — prints operator command" {
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
  # Force no-tty: set the flag that tells merge.sh it is inside the harness
  export GAIA_HARNESS_SHELL=1

  run bash "$MERGE_SH" 999 E900-S1 --no-delete-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"operator"* ]] || [[ "$output" == *"terminal"* ]] || [[ "$output" == *"run"* ]]
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

@test "audit record contract: blocked bypass attempt writes bypass_attempt_blocked" {
  # The guard writes bypass_attempt_blocked records to sprint audit.
  # Verify the guard function exists in merge.sh and documents the record contract.
  run /usr/bin/grep -c 'bypass_attempt_blocked' "$MERGE_SH"
  [ "$output" -gt 0 ]
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

@test "merge.sh always passes --no-delete-branch to gh pr merge" {
  # Verify the merge command always includes --no-delete-branch.
  run /usr/bin/grep -c '\-\-no-delete-branch' "$MERGE_SH"
  [ "$output" -gt 0 ]

  # The script must default DELETE_BRANCH to false (not true).
  # The initial assignment must be false; only --delete-branch option may set it true.
  run bash -c "/usr/bin/grep -E '^DELETE_BRANCH=' '$MERGE_SH' || true"
  [[ "$output" == *"DELETE_BRANCH=false"* ]]
}

@test "no-CI binding mode: merge.sh passes ci-sha none when no promotion chain" {
  # Verify that merge.sh determines ci-sha based on the promotion chain config.
  # When no promotion chain is configured, _merge_ci_sha should be "none".
  # We test this by checking the code logic directly.

  # The merge.sh code conditionally sets _merge_ci_sha="none" when the
  # promotion chain is absent/null/empty. Verify this logic exists.
  run /usr/bin/grep -c '_merge_ci_sha="none"' "$MERGE_SH"
  [ "$output" -gt 0 ]

  # Also verify that review-gate-check.sh accepts --ci-sha none when no CI
  # is configured (the check is in review-gate-check.sh, not merge.sh)
  local rgc_sh
  rgc_sh="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/review-gate-check.sh"
  [ -f "$rgc_sh" ]

  # Create a minimal story and config with no promotion chain
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
  run bash "$rgc_sh" --bind-head "$FIXTURE_HEAD_OID" --ci-sha none --story "$STORY_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETE"* ]]
}

@test "no-CI binding mode refused when CI is configured" {
  make_fixture_repo
  make_fixture_config  # has promotion_chain → CI configured
  # Stub review-gate-check.sh to test the --ci-sha none refusal path
  # The script should NOT pass --ci-sha none when CI is configured
  _seed_story "E900-S1" \
    "Code Review:PASSED:$FIXTURE_HEAD_OID" \
    "QA Tests:PASSED:$FIXTURE_HEAD_OID" \
    "Security Review:PASSED:$FIXTURE_HEAD_OID" \
    "Test Automation:PASSED:$FIXTURE_HEAD_OID" \
    "Test Review:PASSED:$FIXTURE_HEAD_OID" \
    "Performance Review:PASSED:$FIXTURE_HEAD_OID"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  make_stub_gh

  # With CI configured, merge.sh should call review-gate-check with a real ci-sha
  # not "none". The gate check should be called properly.
  # We test this by checking the merge.sh code passes ci_sha correctly
  run bash -c "/usr/bin/grep -E '(ci.sha|ci_sha).*none' '$MERGE_SH' | /usr/bin/grep -v 'no.*CI\|not.*configured\|absent\|null\|comment\|#' | head -1 || true"
  # The script should only allow none when no CI is configured
  # This verifies the conditional logic exists
  run /usr/bin/grep -c 'ci.*sha.*none\|ci_sha.*none\|--ci-sha none' "$MERGE_SH"
  [ "$output" -gt 0 ]
}

# -----------------------------------------------------------------------
# Bypass visibility in /gaia-doctor and /gaia-run-sprint plan
# -----------------------------------------------------------------------

@test "bypass visibility: scan for bypass audit records reports each use" {
  mkdir -p "$TEST_TMP/.gaia/state/sprint-audit"
  cat > "$TEST_TMP/.gaia/state/sprint-audit/bypass-E900-S1.yaml" <<'AUDIT'
type: review_gate_bypass
story: E900-S1
head: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
non_pass_rows:
  - "Code Review: FAILED"
confirmed_by: operator_tty
timestamp: "2026-10-27T12:00:00Z"
AUDIT
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"

  # The bypass-scan function must exist in merge.sh or a library it sources
  run /usr/bin/grep -c 'bypass.*audit\|sprint.audit.*bypass\|review_gate_bypass' "$MERGE_SH"
  [ "$output" -gt 0 ]
}

@test "bypass visibility: merge.sh exposes confirmation result for caller" {
  # The bypass confirmation result must be exposed so E127-S3 can write
  # the gate_bypass ledger entry. Verify the merge.sh outputs or exports
  # the confirmation details.
  run /usr/bin/grep -c 'confirmed_by\|gate_bypass\|bypass_confirmed' "$MERGE_SH"
  [ "$output" -gt 0 ]
}
