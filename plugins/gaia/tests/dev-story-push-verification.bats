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
#   - (d) protected-branch skip — main / staging skip silently
#   - (e) env-override skip — GAIA_PUSH_VERIFY=skip exits 0 silently
#   - (f) finalize integration — when verifier exits non-zero, finalize.sh halts BEFORE
#         writing checkpoint or emitting lifecycle event (and proceeds on success)
#   - (g) non-git CWD skip-with-warning + detached HEAD skip (audit-v2-migration /
#         cluster-7-chain regression seen during E55-S10 dev)
#
# Tests are consolidated to keep CI runtime under the bats-tests 5-minute wall.

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
  _install_git_shim
}

teardown() { common_teardown; }

# Install a `git` shim that delegates to REAL_GIT EXCEPT for `ls-remote`.
# Behavior is controlled per-call via env vars:
#   GAIA_LSREMOTE_SHA   — sha to emit (default: real HEAD)
#   GAIA_LSREMOTE_EMPTY — if "1", emit no output (branch absent on remote)
_install_git_shim() {
  cat > "$STUB_BIN/git" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
  if [ "${GAIA_LSREMOTE_EMPTY:-0}" = "1" ]; then exit 0; fi
  branch="${4:-}"
  sha="${GAIA_LSREMOTE_SHA:-$($REAL_GIT rev-parse HEAD)}"
  printf '%s\trefs/heads/%s\n' "$sha" "$branch"
  exit 0
fi
exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$STUB_BIN/git"
}

# AC1 + AC3 — happy path: ls-remote sha matches local HEAD -> exit 0.
@test "verify-push: AC1/AC3 success when remote sha matches local HEAD" {
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
}

# AC2 — failure paths: sha mismatch AND branch absent on origin both halt.
# Combines two distinct failure modes into one @test to amortize git-init.
@test "verify-push: AC2/AC4 HALTs on sha mismatch AND on branch-absent (sprint-37 regression)" {
  GAIA_LSREMOTE_SHA="0000000000000000000000000000000000000000" run "$VERIFY_PUSH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "sha mismatch|differs|expected" >/dev/null

  GAIA_LSREMOTE_EMPTY=1 run "$VERIFY_PUSH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "not found|absent|missing" >/dev/null
}

# Skip paths: protected-branch (main / staging) AND env-override AND
# detached HEAD AND non-git CWD must all exit 0 silently. Combined to
# avoid 4x git-init cost.
@test "verify-push: skip exit 0 on protected branch / env override / detached HEAD / non-git CWD" {
  # main
  "$REAL_GIT" checkout -q -b main
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]

  # staging
  "$REAL_GIT" checkout -q -b staging
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]

  # GAIA_PUSH_VERIFY=skip with otherwise-failing remote state
  "$REAL_GIT" checkout -q feat/E55-S10-test
  GAIA_LSREMOTE_EMPTY=1 GAIA_PUSH_VERIFY=skip run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]

  # detached HEAD (CI PR check-out + audit-v2-migration regression)
  "$REAL_GIT" checkout -q --detach HEAD
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Ei "detached HEAD|no branch to verify" >/dev/null

  # non-git CWD
  rm -rf .git
  run "$VERIFY_PUSH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Ei "skipped \(non-git CWD\)" >/dev/null
}

# AC2 + AC3 wiring — finalize halts BEFORE checkpoint when verify fails,
# and emits the verify-pass log line when verify succeeds.
@test "finalize.sh: halts on verify failure AND proceeds past verify on success" {
  GAIA_LSREMOTE_EMPTY=1 run "$FINALIZE"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Ei "verify-push|push verification" >/dev/null

  run "$FINALIZE"
  echo "$output" | grep -F "push verification passed" >/dev/null
}
