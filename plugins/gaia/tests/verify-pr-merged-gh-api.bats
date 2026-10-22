#!/usr/bin/env bats
# verify-pr-merged-gh-api.bats — behavioural tests for verify-pr-merged.sh
# proving the gate checks actual PR merge status via the GitHub API
# rather than commit-message grep.
#
# Stubs the gh CLI; never contacts the real GitHub API.
# All fixtures live in BATS_TEST_TMPDIR; nothing under plugins/gaia/.

load 'test_helper.bash'

SCRIPT_REL="../skills/gaia-dev-story/scripts/verify-pr-merged.sh"

setup() {
  common_setup

  SCRIPT="$(cd "$BATS_TEST_DIRNAME/$(dirname "$SCRIPT_REL")" && pwd)/$(basename "$SCRIPT_REL")"

  # Isolated git config — no ambient signing / user.name interference.
  export HOME="$TEST_TMP/home"
  export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
}

teardown() {
  # Restore PATH if narrowed by remove_gh_from_path, so rm/bats cleanup work.
  if [ -n "${_SAVED_PATH:-}" ]; then
    export PATH="$_SAVED_PATH"
  fi
  common_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# fixture_git — every fixture invocation carries its own identity + no signing.
fixture_git() {
  git -c user.email=fixture@example.invalid \
      -c user.name=fixture \
      -c commit.gpgsign=false \
      "$@"
}

# make_fixture_repo — bare minimum repo with staging base and a feature branch.
# The story key appears in an older commit on staging (the false-pass vector).
make_fixture_repo() {
  local key="${1:-E900-S1}"
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  fixture_git -C "$REPO" init -q -b staging

  # An older commit mentions the story key (e.g., planning/ATDD PR).
  fixture_git -C "$REPO" commit --allow-empty -q -m "docs: add ATDD for $key"

  # Feature branch from staging.
  fixture_git -C "$REPO" checkout -q -b "feat/${key}-slug"
  fixture_git -C "$REPO" commit --allow-empty -q -m "feat: implement $key"

  # Back to staging to keep HEAD on the target branch.
  fixture_git -C "$REPO" checkout -q staging

  # Set up a local bare remote so origin/staging resolves.
  ORIGIN="$TEST_TMP/origin"
  fixture_git clone --bare -q "$REPO" "$ORIGIN"
  fixture_git -C "$REPO" remote remove origin 2>/dev/null || true
  fixture_git -C "$REPO" remote add origin "$ORIGIN"
  fixture_git -C "$REPO" fetch -q origin

  export PROJECT_PATH="$REPO"
}

# make_stub_gh — write an executable gh stub under $TEST_TMP/bin.
# When the script passes --jq, the stub returns the pre-computed
# GH_PR_LIST_RESULT (simulating gh's built-in jq filtering).
# Without --jq, it returns GH_PR_LIST_JSON (raw JSON array).
make_stub_gh() {
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

# Record every invocation for post-hoc assertions.
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"

# --- gh pr list ---
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  if [ "${GH_PR_LIST_EXIT:-0}" -ne 0 ]; then
    exit "${GH_PR_LIST_EXIT}"
  fi
  # Detect --jq flag; when present, return pre-filtered result.
  # No `local` — this is a top-level script, not a function.
  _has_jq=0
  for _a in "$@"; do
    case "$_a" in --jq) _has_jq=1 ;; esac
  done
  if [ "$_has_jq" -eq 1 ] && [ -n "${GH_PR_LIST_RESULT+set}" ]; then
    printf '%s\n' "${GH_PR_LIST_RESULT}"
    exit 0
  fi
  printf '%s\n' "${GH_PR_LIST_JSON:-[]}"
  exit 0
fi

# Any other gh call returns empty output.
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# remove_gh_from_path — build a clean PATH containing only the tools the
# script needs but NOT gh.  Avoids the /usr/bin leak (Ubuntu CI has
# /usr/bin/gh) by symlinking individual tools into an isolated directory.
# Saves the original PATH so teardown (which needs rm, etc.) can restore it.
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
# AC1 — PR still open + older commit matches: gate must FAIL
# ---------------------------------------------------------------------------

@test "open PR with earlier commit containing story key: gate fails" {
  make_fixture_repo E900-S1

  make_stub_gh
  export GH_CALL_LOG="$TEST_TMP/gh-calls.txt"
  : > "$GH_CALL_LOG"
  # Real gh shape: open PR has state OPEN.  The --jq filter returns "OPEN".
  export GH_PR_LIST_RESULT="OPEN"

  run bash "$SCRIPT" E900-S1 staging
  [ "$status" -eq 2 ]
}

@test "only planning-commit mentions key, no feature PR: gate fails" {
  make_fixture_repo E900-S2

  make_stub_gh
  # No matching PRs — jq filter returns NO_MATCH.
  export GH_PR_LIST_RESULT="NO_MATCH"

  run bash "$SCRIPT" E900-S2 staging
  [ "$status" -eq 2 ]
}

@test "PR closed without merging: gate fails" {
  make_fixture_repo E900-S3

  make_stub_gh
  export GH_PR_LIST_RESULT="CLOSED"

  run bash "$SCRIPT" E900-S3 staging
  [ "$status" -eq 2 ]
}

@test "real gh null mergedAt for open PR: gate fails (not fooled by null)" {
  make_fixture_repo E900-S20

  make_stub_gh
  # Real gh returns state OPEN when mergedAt is null.
  export GH_PR_LIST_RESULT="OPEN"

  run bash "$SCRIPT" E900-S20 staging
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC2 — PR merged: gate must PASS via state confirmation
# ---------------------------------------------------------------------------

@test "merged PR: gate passes" {
  make_fixture_repo E900-S4

  make_stub_gh
  export GH_PR_LIST_RESULT="MERGED"

  run bash "$SCRIPT" E900-S4 staging
  [ "$status" -eq 0 ]
}

@test "merge confirmation uses gh pr list with --jq and --state all" {
  make_fixture_repo E900-S5

  make_stub_gh
  export GH_CALL_LOG="$TEST_TMP/gh-calls.txt"
  : > "$GH_CALL_LOG"
  export GH_PR_LIST_RESULT="MERGED"

  run bash "$SCRIPT" E900-S5 staging
  [ "$status" -eq 0 ]

  # Prove gh was called with the expected arguments.
  [ -s "$GH_CALL_LOG" ]
  run cat "$GH_CALL_LOG"
  [[ "${lines[0]}" == *"pr list"* ]]
  [[ "${lines[0]}" == *"--state all"* ]]
  [[ "${lines[0]}" == *"--jq"* ]]
  [[ "${lines[0]}" == *"--json"* ]]
}

@test "squash-merged PR: gate passes" {
  make_fixture_repo E900-S6
  fixture_git -C "$REPO" merge --squash "feat/E900-S6-slug" 2>/dev/null || true
  fixture_git -C "$REPO" commit --allow-empty -q -m "feat: implement E900-S6 (#60)"

  make_stub_gh
  export GH_PR_LIST_RESULT="MERGED"

  run bash "$SCRIPT" E900-S6 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — Multiple PRs / disambiguation
# ---------------------------------------------------------------------------

@test "two PRs reference key, feature-branch PR merged: gate passes" {
  make_fixture_repo E900-S7

  make_stub_gh
  # The jq filter already selected only the feature-branch PR → MERGED.
  export GH_PR_LIST_RESULT="MERGED"

  run bash "$SCRIPT" E900-S7 staging
  [ "$status" -eq 0 ]
}

@test "feature-branch PR merged, other PR open: gate passes" {
  make_fixture_repo E900-S8

  make_stub_gh
  # jq filter picks the newest feat/ PR → still MERGED.
  export GH_PR_LIST_RESULT="MERGED"

  run bash "$SCRIPT" E900-S8 staging
  [ "$status" -eq 0 ]
}

@test "feature-branch PR open, other PR merged: gate fails" {
  make_fixture_repo E900-S9

  make_stub_gh
  # jq filter picks the newest feat/ PR → OPEN (the older merged one is not first).
  export GH_PR_LIST_RESULT="OPEN"

  run bash "$SCRIPT" E900-S9 staging
  [ "$status" -eq 2 ]
}

@test "prefix collision: key S1 does not match branch feat/S10-slug" {
  make_fixture_repo E900-S1

  make_stub_gh
  # The jq filter uses startswith("feat/e900-s1-") which does NOT match
  # "feat/e900-s10-slug".  No match for S1 → NO_MATCH.
  export GH_PR_LIST_RESULT="NO_MATCH"

  run bash "$SCRIPT" E900-S1 staging
  [ "$status" -eq 2 ]
}

@test "non-empty PR list with no matching feat branch: gate fails" {
  make_fixture_repo E900-S21

  make_stub_gh
  # PRs exist but none match the feat/<key>- prefix → NO_MATCH.
  export GH_PR_LIST_RESULT="NO_MATCH"

  run bash "$SCRIPT" E900-S21 staging
  [ "$status" -eq 2 ]
}

@test "PR targets main, gate checks staging: gate fails" {
  make_fixture_repo E900-S22

  make_stub_gh
  # Feature PR exists but targets main, not staging.
  # The jq filter checks baseRefName == target → NO_MATCH for staging.
  export GH_PR_LIST_RESULT="NO_MATCH"

  run bash "$SCRIPT" E900-S22 staging
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC4 — gh unavailable or API failure: fallback with WARNING
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

# ---------------------------------------------------------------------------
# AC5 — Tests exercise the real entry point under bash 5 and /bin/bash 3.2
# ---------------------------------------------------------------------------

@test "bash 5: script executes and returns exit 0 for merged PR" {
  make_fixture_repo E900-S14

  make_stub_gh
  export GH_PR_LIST_RESULT="MERGED"

  local bash5
  bash5="$(command -v bash)"
  run "$bash5" "$SCRIPT" E900-S14 staging
  [ "$status" -eq 0 ]
}

@test "bash 3.2: script executes and returns exit 0 for merged PR" {
  make_fixture_repo E900-S15

  make_stub_gh
  export GH_PR_LIST_RESULT="MERGED"

  run /bin/bash "$SCRIPT" E900-S15 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — No internal traceability identifiers in published plugin files
# ---------------------------------------------------------------------------

@test "no leaked FR/ADR/TC identifiers in verify-pr-merged.sh" {
  local target="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  [ -f "$target" ]
  run grep -nE '(FR-[0-9]+|ADR-[0-9]+|TC-[0-9]+)' "$target"
  [ "$status" -ne 0 ]
  # Check for literal story keys using ERE (BSD-safe, not -P).
  run grep -nE 'E[0-9]+-S[0-9]+' "$target"
  if [ "$status" -eq 0 ]; then
    local bad=0
    for line in "${lines[@]}"; do
      # Load-bearing regex patterns are allowed (contain [0-9], \b, etc.).
      case "$line" in
        *'[0-9]'*|*'\\b'*|*'\\d'*) continue ;;
        *)
          echo "Leaked story key found: $line"
          bad=1
          ;;
      esac
    done
    [ "$bad" -eq 0 ]
  fi
}

@test "no leaked identifiers in comments or string literals" {
  local target="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  [ -f "$target" ]
  run grep -nE '^[[:space:]]*#.*(FR-[0-9]+|ADR-[0-9]+|TC-[0-9]+)' "$target"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC7 — Test suite never writes into the real plugin tree
# ---------------------------------------------------------------------------

@test "all fixture writes target temp directories" {
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  local write_pat='(>[[:space:]]|>>|tee |cp |mv |mkdir -p )'
  run grep -nE "${write_pat}" "$bats_file"
  if [ "$status" -eq 0 ]; then
    local bad=0
    for line in "${lines[@]}"; do
      case "$line" in
        *'run grep'*|*'write_pat'*) continue ;;
        *'plugins/gaia/'*)
          echo "BAD write target: $line"
          bad=1
          ;;
      esac
    done
    [ "$bad" -eq 0 ]
  fi
}

@test "teardown cleans up temp dirs" {
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  run grep -c 'common_teardown' "$bats_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -gt 0 ]
}
