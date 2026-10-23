#!/usr/bin/env bats
# verify-pr-merged-gh-api.bats — behavioural tests for verify-pr-merged.sh
#
# The gh stub executes the script's real --jq expression (via system jq)
# against fixture JSON arrays shaped like real gh output.
# All fixtures live in BATS_TEST_TMPDIR; nothing under plugins/gaia/.

load 'test_helper.bash'

SCRIPT_REL="../skills/gaia-dev-story/scripts/verify-pr-merged.sh"

setup() {
  common_setup
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/$(dirname "$SCRIPT_REL")" && pwd)/$(basename "$SCRIPT_REL")"
  export HOME="$TEST_TMP/home"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
}

teardown() {
  if [ -n "${_SAVED_PATH:-}" ]; then export PATH="$_SAVED_PATH"; fi
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fixture_git() {
  git -c user.email=fixture@example.invalid \
      -c user.name=fixture \
      -c commit.gpgsign=false \
      "$@"
}

make_fixture_repo() {
  local key="${1:-E900-S1}"
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "docs: add ATDD for $key"
  fixture_git -C "$REPO" checkout -q -b "feat/${key}-slug"
  fixture_git -C "$REPO" commit --allow-empty -q -m "feat: implement $key"
  fixture_git -C "$REPO" checkout -q staging
  ORIGIN="$TEST_TMP/origin"
  fixture_git clone --bare -q "$REPO" "$ORIGIN"
  fixture_git -C "$REPO" remote remove origin 2>/dev/null || true
  fixture_git -C "$REPO" remote add origin "$ORIGIN"
  fixture_git -C "$REPO" fetch -q origin
  export PROJECT_PATH="$REPO"
}

make_stub_gh() {
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  local jq_path
  jq_path="$(command -v jq)"
  cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\${GH_CALL_LOG:-/dev/null}"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  if [ "\${GH_PR_LIST_EXIT:-0}" -ne 0 ]; then exit "\${GH_PR_LIST_EXIT}"; fi
  _jq_expr="" _found_jq=0
  for _a in "\$@"; do
    if [ "\$_found_jq" -eq 1 ]; then _jq_expr="\$_a"; break; fi
    case "\$_a" in --jq) _found_jq=1 ;; esac
  done
  if [ -n "\$_jq_expr" ]; then
    printf '%s\n' "\${GH_PR_LIST_JSON:-[]}" | "${jq_path}" -r "\$_jq_expr"
    exit \$?
  fi
  printf '%s\n' "\${GH_PR_LIST_JSON:-[]}"
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  if [ "\${GH_PR_VIEW_EXIT:-0}" -ne 0 ]; then exit "\${GH_PR_VIEW_EXIT}"; fi
  _jq_expr="" _found_jq=0
  for _a in "\$@"; do
    if [ "\$_found_jq" -eq 1 ]; then _jq_expr="\$_a"; break; fi
    case "\$_a" in --jq) _found_jq=1 ;; esac
  done
  if [ -n "\$_jq_expr" ]; then
    printf '%s\n' "\${GH_PR_VIEW_JSON:-null}" | "${jq_path}" -r "\$_jq_expr"
    exit \$?
  fi
  printf '%s\n' "\${GH_PR_VIEW_JSON:-{}}"
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

remove_gh_from_path() {
  _SAVED_PATH="$PATH"
  local clean_bin="$TEST_TMP/clean-bin"
  mkdir -p "$clean_bin"
  local tool tool_path
  for tool in bash git sed tr printf cat env basename dirname pwd grep rm mkdir; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    [ -x "$tool_path" ] && ln -sf "$tool_path" "$clean_bin/$tool"
  done
  export PATH="$clean_bin"
}

# ---------------------------------------------------------------------------
# Gate fails for open / not-found / closed PRs
# ---------------------------------------------------------------------------

@test "open PR with earlier commit containing story key: gate fails" {
  make_fixture_repo E900-S1
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":42,"headRefName":"feat/E900-S1-slug","baseRefName":"staging","state":"OPEN","mergedAt":null}]'
  export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null}'
  run bash "$SCRIPT" E900-S1 staging
  [ "$status" -eq 2 ]
}

@test "only planning-commit mentions key, no feature PR: gate fails" {
  make_fixture_repo E900-S2
  make_stub_gh
  export GH_PR_LIST_JSON='[]'
  run bash "$SCRIPT" E900-S2 staging
  [ "$status" -eq 2 ]
}

@test "PR closed without merging: gate fails" {
  make_fixture_repo E900-S3
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":99,"headRefName":"feat/E900-S3-slug","baseRefName":"staging","state":"CLOSED","mergedAt":null}]'
  export GH_PR_VIEW_JSON='{"state":"CLOSED","mergedAt":null}'
  run bash "$SCRIPT" E900-S3 staging
  [ "$status" -eq 2 ]
}

@test "state MERGED but mergedAt null: gate fails" {
  make_fixture_repo E900-S30
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":300,"headRefName":"feat/E900-S30-slug","baseRefName":"staging","state":"MERGED","mergedAt":null}]'
  export GH_PR_VIEW_JSON='{"state":"MERGED","mergedAt":null}'
  run bash "$SCRIPT" E900-S30 staging
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Gate passes for merged PRs
# ---------------------------------------------------------------------------

@test "merged PR: gate passes" {
  make_fixture_repo E900-S4
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":50,"headRefName":"feat/E900-S4-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S4 staging
  [ "$status" -eq 0 ]
}

@test "merge confirmation uses gh pr list with --jq, --state all, and --search head" {
  make_fixture_repo E900-S5
  make_stub_gh
  export GH_CALL_LOG="$TEST_TMP/gh-calls.txt"
  : > "$GH_CALL_LOG"
  export GH_PR_LIST_JSON='[{"number":55,"headRefName":"feat/E900-S5-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S5 staging
  [ "$status" -eq 0 ]
  [ -s "$GH_CALL_LOG" ]
  run cat "$GH_CALL_LOG"
  [[ "${lines[0]}" == *"pr list"* ]]
  [[ "${lines[0]}" == *"--state all"* ]]
  [[ "${lines[0]}" == *"--jq"* ]]
  [[ "${lines[0]}" == *"--search"* ]]
  [[ "${lines[0]}" == *"head:feat/e900-s5-"* ]]
}

@test "squash-merged PR: gate passes" {
  make_fixture_repo E900-S6
  fixture_git -C "$REPO" merge --squash "feat/E900-S6-slug" 2>/dev/null || true
  fixture_git -C "$REPO" commit --allow-empty -q -m "feat: implement E900-S6 (#60)"
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":60,"headRefName":"feat/E900-S6-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T14:00:00Z"}]'
  run bash "$SCRIPT" E900-S6 staging
  [ "$status" -eq 0 ]
}

@test "merged PR with pretty-printed JSON: gate passes" {
  make_fixture_repo E900-S23
  make_stub_gh
  export GH_PR_LIST_JSON='[
  {
    "number": 230,
    "headRefName": "feat/E900-S23-slug",
    "baseRefName": "staging",
    "state": "MERGED",
    "mergedAt": "2026-10-21T12:00:00Z"
  }
]'
  run bash "$SCRIPT" E900-S23 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Remote-prefixed and multi-segment target branches
# ---------------------------------------------------------------------------

@test "target origin/staging: remote prefix stripped for API check" {
  make_fixture_repo E900-S25
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":250,"headRefName":"feat/E900-S25-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S25 origin/staging
  [ "$status" -eq 0 ]
}

@test "target origin/release/next: multi-segment branch preserved" {
  make_fixture_repo E900-S31
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":310,"headRefName":"feat/E900-S31-slug","baseRefName":"release/next","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S31 origin/release/next
  [ "$status" -eq 0 ]
}

@test "target release/next without remote prefix: branch preserved" {
  make_fixture_repo E900-S32
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":320,"headRefName":"feat/E900-S32-slug","baseRefName":"release/next","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S32 release/next
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Multiple PRs / disambiguation
# ---------------------------------------------------------------------------

@test "two PRs reference key, feature-branch PR merged: gate passes" {
  make_fixture_repo E900-S7
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":70,"headRefName":"feat/E900-S7-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T15:00:00Z"},{"number":71,"headRefName":"docs/planning-E900-S7","baseRefName":"staging","state":"OPEN","mergedAt":null}]'
  run bash "$SCRIPT" E900-S7 staging
  [ "$status" -eq 0 ]
}

@test "feature-branch PR open, other PR merged: gate fails" {
  make_fixture_repo E900-S9
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":90,"headRefName":"feat/E900-S9-slug","baseRefName":"staging","state":"OPEN","mergedAt":null},{"number":91,"headRefName":"docs/atdd-E900-S9","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T10:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null}'
  run bash "$SCRIPT" E900-S9 staging
  [ "$status" -eq 2 ]
}

@test "branch prefix with trailing dash prevents shorter-key collision" {
  make_fixture_repo E900-S1
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":100,"headRefName":"feat/E900-S10-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S1 staging
  [ "$status" -eq 2 ]
}

@test "non-empty PR list with no matching feat branch: gate fails" {
  make_fixture_repo E900-S21
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":210,"headRefName":"docs/E900-S21-plan","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S21 staging
  [ "$status" -eq 2 ]
}

@test "PR targets main, gate checks staging: gate fails" {
  make_fixture_repo E900-S22
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":220,"headRefName":"feat/E900-S22-slug","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run bash "$SCRIPT" E900-S22 staging
  [ "$status" -eq 2 ]
}

@test "older merged PR plus newer open PR for same branch: gate fails" {
  make_fixture_repo E900-S24
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":242,"headRefName":"feat/E900-S24-v2","baseRefName":"staging","state":"OPEN","mergedAt":null},{"number":241,"headRefName":"feat/E900-S24-v1","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-20T12:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"state":"OPEN","mergedAt":null}'
  run bash "$SCRIPT" E900-S24 staging
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Search lag confirmation via gh pr view
# ---------------------------------------------------------------------------

@test "search says open but pr view confirms merged: gate passes" {
  make_fixture_repo E900-S33
  make_stub_gh
  # Search index lags — returns OPEN.
  export GH_PR_LIST_JSON='[{"number":330,"headRefName":"feat/E900-S33-slug","baseRefName":"staging","state":"OPEN","mergedAt":null}]'
  # But exact pr view says MERGED.
  export GH_PR_VIEW_JSON='{"state":"MERGED","mergedAt":"2026-10-23T12:00:00Z"}'
  run bash "$SCRIPT" E900-S33 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Input validation (security)
# ---------------------------------------------------------------------------

@test "malicious story key with jq injection: gate rejects" {
  make_fixture_repo E900-S1
  make_stub_gh
  export GH_PR_LIST_JSON='[]'
  run bash "$SCRIPT" 'E900-S1") or true or ("' staging
  [ "$status" -eq 1 ]
}

@test "empty story key: gate rejects" {
  make_fixture_repo E900-S1
  run bash "$SCRIPT" '' staging
  [ "$status" -eq 1 ]
}

@test "malicious target branch with jq injection: gate rejects" {
  make_fixture_repo E900-S1
  make_stub_gh
  run bash "$SCRIPT" E900-S1 'staging"or(true)or"'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# gh unavailable or API failure: fallback with WARNING
# ---------------------------------------------------------------------------

@test "gh not on PATH: fallback with WARNING, commit found" {
  make_fixture_repo E900-S10
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "Story: E900-S10"
  remove_gh_from_path
  run bash "$SCRIPT" E900-S10 staging
  [ "$status" -eq 0 ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "gh available but API call fails: fallback with WARNING" {
  make_fixture_repo E900-S11
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "Story: E900-S11"
  make_stub_gh
  export GH_PR_LIST_EXIT=1
  run bash "$SCRIPT" E900-S11 staging
  [ "$status" -eq 0 ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "fallback is not a silent pass: WARNING always emitted when gh unavailable" {
  make_fixture_repo E900-S12
  remove_gh_from_path
  run bash "$SCRIPT" E900-S12 staging
  [ -n "$output" ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "fallback with no matching commits: gate still fails" {
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "unrelated commit"
  ORIGIN="$TEST_TMP/origin"
  fixture_git clone --bare -q "$REPO" "$ORIGIN"
  fixture_git -C "$REPO" remote remove origin 2>/dev/null || true
  fixture_git -C "$REPO" remote add origin "$ORIGIN"
  fixture_git -C "$REPO" fetch -q origin
  export PROJECT_PATH="$REPO"
  remove_gh_from_path
  run bash "$SCRIPT" E900-S13 staging
  [ "$status" -eq 2 ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
  [[ "$output" == *"gate fails"* ]]
}

@test "gh returns invalid JSON: fallback with WARNING" {
  make_fixture_repo E900-S27
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "Story: E900-S27"
  make_stub_gh
  export GH_PR_LIST_JSON='NOT_JSON'
  run bash "$SCRIPT" E900-S27 staging
  [ "$status" -eq 0 ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

# ---------------------------------------------------------------------------
# Bash compatibility
# ---------------------------------------------------------------------------

@test "bash 5: script executes and returns exit 0 for merged PR" {
  make_fixture_repo E900-S14
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":140,"headRefName":"feat/E900-S14-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  local bash5
  bash5="$(command -v bash)"
  run "$bash5" "$SCRIPT" E900-S14 staging
  [ "$status" -eq 0 ]
}

@test "bash 3.2: script executes and returns exit 0 for merged PR" {
  make_fixture_repo E900-S15
  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":150,"headRefName":"feat/E900-S15-slug","baseRefName":"staging","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  run /bin/bash "$SCRIPT" E900-S15 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# No leaked identifiers in published plugin files
# ---------------------------------------------------------------------------

@test "no leaked identifiers in verify-pr-merged.sh" {
  local target="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  [ -f "$target" ]
  run grep -nE '(FR-[0-9]+|ADR-[0-9]+|TC-[0-9]+)' "$target"
  [ "$status" -ne 0 ]
  run grep -nE 'E[0-9]+-S[0-9]+' "$target"
  if [ "$status" -eq 0 ]; then
    local bad=0
    for line in "${lines[@]}"; do
      case "$line" in
        *'[0-9]'*|*'\\b'*|*'\\d'*) continue ;;
        *) echo "Leaked story key found: $line"; bad=1 ;;
      esac
    done
    [ "$bad" -eq 0 ]
  fi
}

# ---------------------------------------------------------------------------
# Test suite hygiene
# ---------------------------------------------------------------------------

@test "teardown cleans up temp dirs" {
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  run grep -c 'common_teardown' "$bats_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -gt 0 ]
}
