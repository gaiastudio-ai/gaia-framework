#!/usr/bin/env bats
# git-push.bats — coverage for plugins/gaia/scripts/git-push.sh
#
# Originally scaffolded for auto-reviews helper scripts — bats coverage
#
# Coverage matrix:
#   - happy path: push succeeds first try, exit 0
#   - retry-on-network: first attempt errors with "Could not resolve host",
#                       second succeeds, exit 0
#   - fail-on-auth: push errors with "Permission denied (publickey)",
#                   exit non-zero, NO retry
#   - protected-branch refusal: current branch == main / staging -> refuse
#
# All tests stub `git push` via a fake `git` shim on PATH that records call
# count and returns a stage-controlled exit code per call.

load 'test_helper.bash'

setup() {
  common_setup
  GIT_PUSH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/git-push.sh"
  cd "$TEST_TMP"
  STUB_BIN="$TEST_TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  # The shim relies on real git for `rev-parse`. Resolve real git path now.
  REAL_GIT="$(command -v git)"
  export REAL_GIT
  # Initialize a real git repo for branch operations.
  "$REAL_GIT" init -q -b feat/dummy
  "$REAL_GIT" config user.email "dev@example.com"
  "$REAL_GIT" config user.name "Dev"
  "$REAL_GIT" commit -q --allow-empty -m "init"
  export PATH="$STUB_BIN:$PATH"
  # Speed up retries — drop sleep to a no-op in the script under test.
  export GAIA_GIT_PUSH_BACKOFF=0
}

teardown() { common_teardown; }

# Write a git shim that delegates everything to REAL_GIT EXCEPT `push`.
# For `push`, behavior is controlled by env vars set per test:
#   GAIA_PUSH_FAIL_FIRST_N — number of initial calls to fail
#   GAIA_PUSH_FAIL_MSG     — stderr message when failing
#   GAIA_PUSH_FAIL_FOREVER — if set to 1, every call fails
_install_git_shim() {
  cat > "$STUB_BIN/git" <<'SHIM'
#!/usr/bin/env bash
COUNTER_FILE="${TEST_TMP}/push-count"
if [ "$1" = "push" ]; then
  count=0
  [ -f "$COUNTER_FILE" ] && count="$(cat "$COUNTER_FILE")"
  count=$((count + 1))
  printf '%d\n' "$count" > "$COUNTER_FILE"
  if [ "${GAIA_PUSH_FAIL_FOREVER:-0}" = "1" ]; then
    printf '%s\n' "${GAIA_PUSH_FAIL_MSG:-fatal: push failed}" >&2
    exit 1
  fi
  if [ -n "${GAIA_PUSH_FAIL_FIRST_N:-}" ] && [ "$count" -le "$GAIA_PUSH_FAIL_FIRST_N" ]; then
    printf '%s\n' "${GAIA_PUSH_FAIL_MSG:-fatal: push failed}" >&2
    exit 1
  fi
  printf 'pushed\n'
  exit 0
fi
exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$STUB_BIN/git"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "git-push: happy path on feature branch, single push call, exit 0" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  run "$GIT_PUSH"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}

# ---------------------------------------------------------------------------
# Retry on transient network error
# ---------------------------------------------------------------------------

@test "git-push: retries ONCE on Could not resolve host, then succeeds" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  GAIA_PUSH_FAIL_FIRST_N=1 GAIA_PUSH_FAIL_MSG="fatal: Could not resolve host: github.com" \
    _install_git_shim
  export GAIA_PUSH_FAIL_FIRST_N=1 GAIA_PUSH_FAIL_MSG="fatal: Could not resolve host: github.com"
  run "$GIT_PUSH"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "2" ]
}

# ---------------------------------------------------------------------------
# Fail-fast on auth errors — no retry
# ---------------------------------------------------------------------------

@test "git-push: fail-fast on Permission denied (publickey), no retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="ERROR: Permission denied (publickey)."
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  # Single attempt — auth errors must not retry.
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
  [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"auth"* ]]
}

# ---------------------------------------------------------------------------
# Protected-branch refusal — main / staging
# ---------------------------------------------------------------------------

@test "git-push: refuses to push from main" {
  "$REAL_GIT" checkout -q -b main
  _install_git_shim
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"main"* ]]
  # No push attempt should have been made.
  [ ! -f "$TEST_TMP/push-count" ] || [ "$(cat "$TEST_TMP/push-count")" = "0" ]
}

@test "git-push: refuses to push from staging" {
  "$REAL_GIT" checkout -q -b staging
  _install_git_shim
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging"* ]]
}

# ---------------------------------------------------------------------------
# After two transient failures still fails — only ONE retry.
# ---------------------------------------------------------------------------

@test "git-push: two consecutive network errors -> fails (only one retry)" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FIRST_N=2 GAIA_PUSH_FAIL_MSG="fatal: Could not resolve host"
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "2" ]
}

# ===========================================================================
# Sleep stub for backoff-sequence verification (used by new tests only;
# existing network-retry tests use GAIA_GIT_PUSH_BACKOFF=0 and real sleep).
# ===========================================================================
_install_sleep_stub() {
  cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${TEST_TMP}/sleep.log"
STUB
  chmod +x "$STUB_BIN/sleep"
}

# ===========================================================================
# Transient remote-rejection retry — new behaviour (RED tests)
# ===========================================================================

@test "git-push: transient remote rejection retries with backoff then succeeds" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  _install_sleep_stub
  export GAIA_PUSH_FAIL_FIRST_N=1
  export GAIA_PUSH_FAIL_MSG="! [remote rejected] refs/heads/feat/some-thing -> refs/heads/feat/some-thing (failed)"
  run "$GIT_PUSH"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "2" ]
}

@test "git-push: transient rejection backoff sequence is 2s 4s 8s" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  _install_sleep_stub
  export GAIA_PUSH_FAIL_FIRST_N=3
  export GAIA_PUSH_FAIL_MSG="! [remote rejected] refs/heads/feat/some-thing -> refs/heads/feat/some-thing (failed)"
  export GIT_PUSH_MAX_RETRIES=3
  export GIT_PUSH_BACKOFF_BASE=2
  run "$GIT_PUSH"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/sleep.log" ]
  [ "$(sed -n '1p' "$TEST_TMP/sleep.log")" = "2" ]
  [ "$(sed -n '2p' "$TEST_TMP/sleep.log")" = "4" ]
  [ "$(sed -n '3p' "$TEST_TMP/sleep.log")" = "8" ]
}

@test "git-push: exhausted retries on transient rejection exits non-zero with count" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  _install_sleep_stub
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="! [remote rejected] refs/heads/feat/some-thing -> refs/heads/feat/some-thing (failed)"
  export GIT_PUSH_MAX_RETRIES=3
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "4" ]
  [[ "$output" == *"3 retries"* ]]
}

@test "git-push: invalid GIT_PUSH_MAX_RETRIES dies with validation error" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GIT_PUSH_MAX_RETRIES=abc
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GIT_PUSH_MAX_RETRIES"* ]]
}

@test "git-push: invalid GIT_PUSH_BACKOFF_BASE dies with validation error" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GIT_PUSH_BACKOFF_BASE=foo
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GIT_PUSH_BACKOFF_BASE"* ]]
}

# ===========================================================================
# Mixed permanent + transient rejection — GREEN-from-start guard.
# Current code already fast-fails all rejections. This guard ensures the new
# classifier does not accidentally retry when permanent rejection text is
# also present in stderr.
# ===========================================================================

@test "git-push: mixed permanent and transient rejection does not retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG=$'! [remote rejected] refs/heads/a -> refs/heads/a (failed)\n! [remote rejected] refs/heads/b -> refs/heads/b (hook declined)'
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}

# ===========================================================================
# Green-from-start guards — preserved fast-fail behaviour for permanent
# errors.  These pass against the current code (no new behaviour required)
# and lock down the existing classification so the new retry logic cannot
# regress them.
# ===========================================================================

@test "git-push: Authentication failed exits immediately without retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="fatal: Authentication failed for 'https://github.com/user/repo.git'"
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}

@test "git-push: remote Permission to denied exits immediately without retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="remote: Permission to user/repo.git denied to bot"
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}

@test "git-push: hook declined rejection exits immediately without retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="! [remote rejected] refs/heads/feat/some-thing -> refs/heads/feat/some-thing (hook declined)"
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}

@test "git-push: protected branch rejection exits immediately without retry" {
  "$REAL_GIT" checkout -q -b feat/some-thing
  _install_git_shim
  export GAIA_PUSH_FAIL_FOREVER=1
  export GAIA_PUSH_FAIL_MSG="! [remote rejected] refs/heads/main -> refs/heads/main (protected branch hook declined)"
  run "$GIT_PUSH"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_TMP/push-count")" = "1" ]
}
