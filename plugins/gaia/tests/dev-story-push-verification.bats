#!/usr/bin/env bats
# dev-story-push-verification.bats — coverage for plugins/gaia/scripts/verify-push.sh
#
# Story: E55-S10 — Add post-step push-verification to dev-story finalize
#
# Coverage matrix (mirrors AC4):
#   - (a) verification SUCCEEDS — local HEAD sha matches `git ls-remote --heads origin <branch>` -> exit 0
#   - (b) verification FAILS — sha mismatch (push silently dropped / ref-update rejected) -> exit non-zero
#   - (c) verification FAILS — branch missing on origin (regression case for sprint-37
#         silent-push incident E53-S244 / E69-S4) -> exit non-zero with diagnostic
#   - (d) protected-branch skip — main / staging skip silently (verifier doesn't push, doesn't verify) -> exit 0
#   - (e) env-override skip — GAIA_PUSH_VERIFY=skip exits 0 silently
#   - (f) finalize integration — when verifier exits non-zero, finalize.sh halts BEFORE
#         writing checkpoint or emitting lifecycle event
#
# All tests stub `git ls-remote` via a fake `git` shim on PATH that records call
# count and returns a stage-controlled stdout per call.

load 'test_helper.bash'

setup() {
  common_setup
  VERIFY_PUSH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/verify-push.sh"
  FINALIZE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/finalize.sh"
  cd "$TEST_TMP"
  STUB_BIN="$TEST_TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  REAL_GIT="$(command -v git)"
  export REAL_GIT
  "$REAL_GIT" init -q -b feat/E55-S10-test
  "$REAL_GIT" config user.email "dev@example.com"
  "$REAL_GIT" config user.name "Dev"
  "$REAL_GIT" commit -q --allow-empty -m "init"
  export PATH="$STUB_BIN:$PATH"
}

teardown() { common_teardown; }

# Install a `git` shim that delegates everything to REAL_GIT EXCEPT
# `ls-remote`. For `ls-remote`, behavior is controlled by env vars:
#   GAIA_LSREMOTE_SHA   — sha to emit on stdout for the matching ref (default: real HEAD)
#   GAIA_LSREMOTE_EMPTY — if "1", emit no output (branch missing on remote)
#   GAIA_LSREMOTE_FAIL  — if "1", exit non-zero (network / auth error)
_install_git_shim() {
  cat > "$STUB_BIN/git" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
  if [ "${GAIA_LSREMOTE_FAIL:-0}" = "1" ]; then
    printf 'fatal: ls-remote failed\n' >&2
    exit 1
  fi
  if [ "${GAIA_LSREMOTE_EMPTY:-0}" = "1" ]; then
    exit 0
  fi
  # Emit `<sha>\t<ref>` for the requested heads/<branch> arg.
  # Args: ls-remote --heads <remote> <branch>
  branch="${4:-}"
  sha="${GAIA_LSREMOTE_SHA:-$($REAL_GIT rev-parse HEAD)}"
  printf '%s\trefs/heads/%s\n' "$sha" "$branch"
  exit 0
fi
exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$STUB_BIN/git"
}

# ---------------------------------------------------------------------------
# (a) verification succeeds
# ---------------------------------------------------------------------------
@test "verify-push: success when remote sha matches local HEAD" {
  _install_git_shim
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (b) verification fails — sha mismatch
# ---------------------------------------------------------------------------
@test "verify-push: HALTs when remote sha differs from local HEAD" {
  _install_git_shim
  GAIA_LSREMOTE_SHA="0000000000000000000000000000000000000000" run "$VERIFY_PUSH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "sha mismatch|differs|expected" >/dev/null
}

# ---------------------------------------------------------------------------
# (c) verification fails — branch missing on origin (sprint-37 regression)
# ---------------------------------------------------------------------------
@test "verify-push: HALTs when branch is absent on origin (E53-S244 / E69-S4 regression)" {
  _install_git_shim
  GAIA_LSREMOTE_EMPTY=1 run "$VERIFY_PUSH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "not found|absent|missing" >/dev/null
}

# ---------------------------------------------------------------------------
# (d) protected-branch skip
# ---------------------------------------------------------------------------
@test "verify-push: skips silently when current branch is main" {
  _install_git_shim
  "$REAL_GIT" checkout -q -b main
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
}

@test "verify-push: skips silently when current branch is staging" {
  _install_git_shim
  "$REAL_GIT" checkout -q -b staging
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (e) env-override skip
# ---------------------------------------------------------------------------
@test "verify-push: GAIA_PUSH_VERIFY=skip bypasses verification" {
  _install_git_shim
  GAIA_LSREMOTE_EMPTY=1 GAIA_PUSH_VERIFY=skip run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (f) finalize integration — halt before checkpoint when verify fails
# ---------------------------------------------------------------------------
@test "finalize.sh: halts BEFORE checkpoint write when verify-push fails" {
  _install_git_shim
  GAIA_LSREMOTE_EMPTY=1 run "$FINALIZE"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "verify-push|push verification" >/dev/null
}

@test "finalize.sh: verify-push runs and passes BEFORE checkpoint/lifecycle steps" {
  _install_git_shim
  # finalize calls checkpoint.sh / lifecycle-event.sh — those scripts probe
  # the project root and may fail in the test sandbox. The contract this test
  # asserts is positional: verify-push runs FIRST, and on success the
  # workflow proceeds to the checkpoint phase. We assert the pass log line
  # is emitted regardless of whether downstream non-finalize steps succeed
  # in the bats sandbox.
  run "$FINALIZE"
  echo "$output" | grep -F "push verification passed" >/dev/null
}

# ---------------------------------------------------------------------------
# Non-git CWD guard — verify-push must skip-with-warning, never halt.
# ---------------------------------------------------------------------------
@test "verify-push: skip-with-warning when CWD is not a git work tree" {
  rm -rf .git
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Ei "skipped \(non-git CWD\)" >/dev/null
}

# ---------------------------------------------------------------------------
# CI / audit fixture path — detached HEAD (default GitHub PR check-out
# state) and empty repos must skip exit 0, not halt. Regression for
# audit-v2-migration + cluster-7-chain CI failures observed during
# E55-S10 dev.
# ---------------------------------------------------------------------------
@test "verify-push: skip exit 0 when HEAD is detached (CI PR check-out)" {
  _install_git_shim
  # Detach HEAD to a sha — git reports rev-parse --abbrev-ref HEAD as "HEAD"
  "$REAL_GIT" checkout -q --detach HEAD
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Ei "detached HEAD|no branch to verify" >/dev/null
}
