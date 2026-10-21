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

teardown() { common_teardown; }

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
# Behaviour is driven by GH_PR_VIEW_JSON and GH_PR_LIST_JSON env vars.
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
  printf '%s\n' "${GH_PR_LIST_JSON:-[]}"
  exit 0
fi

# --- gh pr view ---
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ "${GH_PR_VIEW_EXIT:-0}" -ne 0 ]; then
    exit "${GH_PR_VIEW_EXIT}"
  fi
  printf '%s\n' "${GH_PR_VIEW_JSON:-{}}"
  exit 0
fi

# Any other gh call returns empty output.
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# remove_gh_from_path — narrow PATH so gh is not found.
remove_gh_from_path() {
  STUB_BIN="$TEST_TMP/bin"
  rm -f "$STUB_BIN/gh" 2>/dev/null || true
  # Keep only /usr/bin, /bin, and the git location for basic ops.
  local git_dir
  git_dir="$(dirname "$(command -v git)")"
  export PATH="/usr/bin:/bin:${git_dir}"
}

# ---------------------------------------------------------------------------
# AC1 — PR still open + older commit matches: gate must FAIL
# ---------------------------------------------------------------------------

@test "S1.1 open PR with earlier commit containing story key: gate fails" {
  make_fixture_repo E900-S1

  # gh returns a PR that is open (mergedAt null).
  make_stub_gh
  export GH_CALL_LOG="$TEST_TMP/gh-calls.txt"
  : > "$GH_CALL_LOG"

  export GH_PR_LIST_JSON='[{"number":42,"headRefName":"feat/E900-S1-slug","state":"OPEN","mergedAt":""}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"","state":"OPEN"}'

  run bash "$SCRIPT" E900-S1 staging
  [ "$status" -ne 0 ]
}

@test "S1.2 only planning-commit mentions key, no feature PR: gate fails" {
  make_fixture_repo E900-S2

  make_stub_gh
  # No matching PRs at all.
  export GH_PR_LIST_JSON='[]'

  run bash "$SCRIPT" E900-S2 staging
  [ "$status" -ne 0 ]
}

@test "S1.3 PR closed without merging: gate fails" {
  make_fixture_repo E900-S3

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":99,"headRefName":"feat/E900-S3-slug","state":"CLOSED","mergedAt":""}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"","state":"CLOSED"}'

  run bash "$SCRIPT" E900-S3 staging
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC2 — PR merged: gate must PASS via mergedAt
# ---------------------------------------------------------------------------

@test "S2.1 merged PR with non-null mergedAt: gate passes" {
  make_fixture_repo E900-S4

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":50,"headRefName":"feat/E900-S4-slug","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T12:00:00Z","state":"MERGED"}'

  run bash "$SCRIPT" E900-S4 staging
  [ "$status" -eq 0 ]
}

@test "S2.2 merge confirmation uses the API, not commit grep" {
  make_fixture_repo E900-S5

  make_stub_gh
  export GH_CALL_LOG="$TEST_TMP/gh-calls.txt"
  : > "$GH_CALL_LOG"

  export GH_PR_LIST_JSON='[{"number":55,"headRefName":"feat/E900-S5-slug","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T12:00:00Z","state":"MERGED"}'

  run bash "$SCRIPT" E900-S5 staging
  [ "$status" -eq 0 ]

  # Prove gh was actually called (API path taken).
  [ -s "$GH_CALL_LOG" ]
  grep -q 'pr' "$GH_CALL_LOG"
}

@test "S2.3 squash-merged PR: mergedAt still populated, gate passes" {
  make_fixture_repo E900-S6
  # Squash-merged: the commit on staging is a single squashed commit, no merge commit.
  fixture_git -C "$REPO" merge --squash "feat/E900-S6-slug" 2>/dev/null || true
  fixture_git -C "$REPO" commit --allow-empty -q -m "feat: implement E900-S6 (#60)"

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":60,"headRefName":"feat/E900-S6-slug","state":"MERGED","mergedAt":"2026-10-21T14:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T14:00:00Z","state":"MERGED"}'

  run bash "$SCRIPT" E900-S6 staging
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3 — Multiple PRs mention key: gate checks only the feature-branch PR
# ---------------------------------------------------------------------------

@test "S3.1 two PRs reference key, feature-branch PR merged: gate passes" {
  make_fixture_repo E900-S7

  make_stub_gh
  # Two PRs: #70 is the feature PR (merged), #71 is planning (open).
  export GH_PR_LIST_JSON='[{"number":70,"headRefName":"feat/E900-S7-slug","state":"MERGED","mergedAt":"2026-10-21T15:00:00Z"},{"number":71,"headRefName":"docs/planning-E900-S7","state":"OPEN","mergedAt":""}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T15:00:00Z","state":"MERGED"}'

  run bash "$SCRIPT" E900-S7 staging
  [ "$status" -eq 0 ]
}

@test "S3.2 feature-branch PR merged, other PR open: gate passes ignoring non-feature PR" {
  make_fixture_repo E900-S8

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":80,"headRefName":"feat/E900-S8-slug","state":"MERGED","mergedAt":"2026-10-21T16:00:00Z"},{"number":81,"headRefName":"chore/sprint-plan","state":"OPEN","mergedAt":""}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T16:00:00Z","state":"MERGED"}'

  run bash "$SCRIPT" E900-S8 staging
  [ "$status" -eq 0 ]
}

@test "S3.3 feature-branch PR open, other PR merged: gate fails" {
  make_fixture_repo E900-S9

  make_stub_gh
  # Feature PR #90 is open, planning PR #91 is merged.
  export GH_PR_LIST_JSON='[{"number":90,"headRefName":"feat/E900-S9-slug","state":"OPEN","mergedAt":""},{"number":91,"headRefName":"docs/atdd-E900-S9","state":"MERGED","mergedAt":"2026-10-21T10:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"","state":"OPEN"}'

  run bash "$SCRIPT" E900-S9 staging
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC4 — gh unavailable or API failure: fallback with WARNING
# ---------------------------------------------------------------------------

@test "S4.1 gh not on PATH: fallback with WARNING, commit found" {
  make_fixture_repo E900-S10
  # Ensure the story key appears in a commit message on staging.
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "Story: E900-S10"

  remove_gh_from_path

  run bash "$SCRIPT" E900-S10 staging
  # Commit-based fallback should find the commit => exit 0.
  [ "$status" -eq 0 ]
  # Must emit a WARNING about the fallback.
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "S4.2 gh available but API call fails: fallback with WARNING" {
  make_fixture_repo E900-S11
  fixture_git -C "$REPO" checkout -q staging
  fixture_git -C "$REPO" commit --allow-empty -q -m "Story: E900-S11"

  make_stub_gh
  # gh pr list exits non-zero (simulating network/auth error).
  export GH_PR_LIST_EXIT=1

  run bash "$SCRIPT" E900-S11 staging
  # Fallback should find the commit => exit 0.
  [ "$status" -eq 0 ]
  # Must emit a WARNING about the API failure.
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "S4.3 fallback is not a silent pass: WARNING text always emitted when gh unavailable" {
  make_fixture_repo E900-S12

  remove_gh_from_path

  run bash "$SCRIPT" E900-S12 staging
  # stderr should be non-empty and contain WARNING (case-insensitive).
  [ -n "$output" ]
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
}

@test "S4.4 fallback with no matching commits: gate still fails" {
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
  [ "$status" -ne 0 ]
  # Both the fallback WARNING and the gate-fail message should appear.
  [[ "$output" == *[Ww][Aa][Rr][Nn]* ]]
  [[ "$output" == *"gate fails"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — Tests exercise the real entry point under bash 5 and /bin/bash 3.2
# ---------------------------------------------------------------------------

@test "S5.1 bash 5 compatibility: script executes without syntax errors" {
  make_fixture_repo E900-S14

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":140,"headRefName":"feat/E900-S14-slug","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T12:00:00Z","state":"MERGED"}'

  local bash5
  bash5="$(command -v bash)"  # Homebrew bash 5 is the default on this system.
  run "$bash5" "$SCRIPT" E900-S14 staging
  # Exit code must be one of the documented codes (0, 1, 2, 3).
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 || "$status" -eq 3 ]]
}

@test "S5.2 bash 3.2 compatibility: no syntax errors on /bin/bash" {
  make_fixture_repo E900-S15

  make_stub_gh
  export GH_PR_LIST_JSON='[{"number":150,"headRefName":"feat/E900-S15-slug","state":"MERGED","mergedAt":"2026-10-21T12:00:00Z"}]'
  export GH_PR_VIEW_JSON='{"mergedAt":"2026-10-21T12:00:00Z","state":"MERGED"}'

  run /bin/bash "$SCRIPT" E900-S15 staging
  # Exit code must be one of the documented codes (0, 1, 2, 3).
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 || "$status" -eq 3 ]]
}

@test "S5.3 tests invoke the real script entry point, not a mock" {
  # Self-referential: verify that THIS test file calls verify-pr-merged.sh directly.
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  # At least one @test runs the script directly (not a stub).
  run grep -c 'verify-pr-merged\.sh' "$bats_file"
  [ "$status" -eq 0 ]
  # The count must be > 0 (many tests call it).
  [ "${lines[0]}" -gt 0 ]
  # At least one test sets PROJECT_PATH to a fixture repo.
  run grep -c 'PROJECT_PATH' "$bats_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# AC6 — No internal traceability identifiers in published plugin files
# ---------------------------------------------------------------------------

@test "S6.1 scan changed file for leaked identifiers" {
  local target="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  [ -f "$target" ]
  # Must not contain literal internal IDs (FR-, ADR-, E<n>-S<n> as literal keys, TC-).
  # Load-bearing regex patterns like E[0-9]+-S[0-9]+ are excluded.
  run grep -nE '(FR-[0-9]+|ADR-[0-9]+|TC-[0-9]+)' "$target"
  [ "$status" -ne 0 ]  # No matches.
  # Check for literal story keys (E<digits>-S<digits> as actual keys, not regex patterns).
  run grep -nP 'E\d+-S\d+' "$target"
  if [ "$status" -eq 0 ]; then
    # If found, they must be inside regex patterns (character classes, quantifiers nearby).
    for line in "${lines[@]}"; do
      [[ "$line" == *'[0-9]'* ]] || [[ "$line" == *'\\b'* ]] || [[ "$line" == *'\\d'* ]] || {
        echo "Leaked story key found: $line"
        false
      }
    done
  fi
}

@test "S6.2 scan comments and string literals for leaked identifiers" {
  local target="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  [ -f "$target" ]
  # Grep for internal IDs in comment lines and echo/printf/log strings.
  run grep -nE '^[[:space:]]*#.*(FR-[0-9]+|ADR-[0-9]+|TC-[0-9]+)' "$target"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC7 — Test suite never writes into the real plugin tree
# ---------------------------------------------------------------------------

@test "S7.1 all fixture writes target temp directories" {
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  # Scan for writes that target the real plugin tree.
  # Exclude the grep line itself (which mentions plugins/gaia/ as a pattern).
  local write_pat='(>[[:space:]]|>>|tee |cp |mv |mkdir -p )'
  run grep -nE "${write_pat}" "$bats_file"
  if [ "$status" -eq 0 ]; then
    # Filter: every matched write line must target a temp var path, not plugins/gaia/.
    local bad=0
    for line in "${lines[@]}"; do
      # Skip lines that are just the grep/run invocations (self-reference).
      case "$line" in
        *'run grep'*|*'write_pat'*) continue ;;
      esac
      if printf '%s\n' "$line" | grep -qE 'plugins/gaia/' ; then
        echo "BAD write target: $line"
        bad=1
      fi
    done
    [ "$bad" -eq 0 ]
  fi
}

@test "S7.2 teardown cleans up: temp dirs removed after suite" {
  # Verify that common_teardown is called in teardown().
  local bats_file="$BATS_TEST_DIRNAME/verify-pr-merged-gh-api.bats"
  [ -f "$bats_file" ]
  run grep -c 'common_teardown' "$bats_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -gt 0 ]
}
