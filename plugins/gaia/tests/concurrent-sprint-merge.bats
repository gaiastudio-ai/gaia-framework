#!/usr/bin/env bats
# concurrent-sprint-merge.bats — serialized promotion-merge tests.
#
# Covers: lock acquisition in concurrent mode, timeout exit 3 with holder-PID
# diagnostic, lock release on every exit path, single-sprint back-compat,
# project-root anchoring, flock/fallback parity, strict-mode exit codes (4/5/7),
# post-merge verification inside the critical section, guard-before-lock
# ordering, deferred outcome in the orchestrator, and SKILL.md assertions.
#
# Test isolation: merge.sh and its dependencies are copied into $TEST_TMP so
# no tracked file is ever overwritten. Tests that need a custom acquire-lock or
# verify-pr-merged replace the copy.

setup() {
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  LOCK_LIB="${PLUGIN_ROOT}/scripts/lib/acquire-lock.sh"
  PPO_SH="${PLUGIN_ROOT}/scripts/phase-parallel-orchestrator.sh"

  TEST_TMP="${BATS_TEST_TMPDIR}/merge-test-$$-${BATS_TEST_NUMBER}"
  mkdir -p "$TEST_TMP/.gaia/state"
  mkdir -p "$TEST_TMP/.gaia/config"
  mkdir -p "$TEST_TMP/worktree-a"
  mkdir -p "$TEST_TMP/worktree-b"
  mkdir -p "$TEST_TMP/bin"

  # Source the lock library for direct assertions.
  source "$LOCK_LIB"
  set +u

  # -- Copy the plugin script subtree so merge.sh resolves its deps from
  #    the copy, and no tracked file is ever overwritten. --
  local pt="$TEST_TMP/plugin-tree"
  mkdir -p "$pt/scripts/lib"
  mkdir -p "$pt/skills/gaia-dev-story/scripts/lib"
  cp "$PLUGIN_ROOT/scripts/lib/acquire-lock.sh" "$pt/scripts/lib/"
  cp "$PLUGIN_ROOT/scripts/lib/dev-story-security-invariants.sh" "$pt/scripts/lib/"
  cp "$PLUGIN_ROOT/scripts/lib/non-git-cwd-guard.sh" "$pt/scripts/lib/"
  # shell-idioms.sh is sourced by verify-pr-merged.sh.
  [ -f "$PLUGIN_ROOT/scripts/lib/shell-idioms.sh" ] && \
    cp "$PLUGIN_ROOT/scripts/lib/shell-idioms.sh" "$pt/scripts/lib/"
  cp "$PLUGIN_ROOT/skills/gaia-dev-story/scripts/merge.sh" \
     "$pt/skills/gaia-dev-story/scripts/"
  # Mirror of acquire-lock.sh (merge.sh sources from scripts/lib/).
  cp "$PLUGIN_ROOT/scripts/lib/acquire-lock.sh" \
     "$pt/skills/gaia-dev-story/scripts/lib/"
  # Default verify-pr-merged.sh stub (success).
  cat > "$pt/skills/gaia-dev-story/scripts/verify-pr-merged.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$pt/skills/gaia-dev-story/scripts/verify-pr-merged.sh"

  MERGE_SH="$pt/skills/gaia-dev-story/scripts/merge.sh"
  PLUGIN_TREE="$pt"

  # Default config: concurrent mode enabled.
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 2
ci_cd:
  promotion_chain:
    - branch: staging
      checks_required: true
YAML

  # Init real git repos on feature branches.
  (cd "$TEST_TMP/worktree-a" && git init --quiet && git commit --allow-empty -m "init" --quiet && git checkout -b feat/test-branch --quiet) 2>/dev/null || true
  (cd "$TEST_TMP/worktree-b" && git init --quiet && git commit --allow-empty -m "init" --quiet && git checkout -b feat/test-branch --quiet) 2>/dev/null || true

  # Wrap git: intercept remote-requiring commands, delegate everything else.
  REAL_GIT="$(command -v git)"
  export REAL_GIT
  cat > "$TEST_TMP/bin/git" <<GITSTUB
#!/usr/bin/env bash
case "\$1" in
  fetch)
    [ "\${2:-}" = "origin" ] && exit 0
    ;;
  merge-base)
    [ "\${2:-}" = "--is-ancestor" ] && exit 0
    ;;
  rev-parse)
    if [ "\${2:-}" = "--verify" ] && [[ "\${3:-}" == origin/* ]]; then
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      exit 0
    fi
    ;;
  log)
    if [ "\${2:-}" = "--format=%H" ]; then
      # Return a fake commit hash so the trailer scan has a non-empty range.
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      exit 0
    fi
    if [ "\${2:-}" = "-1" ]; then
      # git log -1 --format=%B <hash> — return an empty body (no trailer).
      exit 0
    fi
    ;;
  check-ref-format)
    [ "\${2:-}" = "--branch" ] && { echo "\${3:-}"; exit 0; }
    ;;
esac
exec "$REAL_GIT" "\$@"
GITSTUB
  chmod +x "$TEST_TMP/bin/git"

  # Stub gh: merge succeeds, PR is OPEN.
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr checks"*)
    echo '[{"bucket":"pass","name":"ci"}]'
    ;;
  *"pr view"*"baseRefName"*)
    echo "staging"
    ;;
  *"pr view"*"headRefName"*)
    echo "feat/test"
    ;;
  *"pr view"*"mergeCommit"*)
    echo "OPEN"
    ;;
  *"pr view"*"--jq"*)
    echo "OPEN"
    ;;
  *"pr merge"*)
    echo "merged"
    ;;
  *"repo view"*)
    echo "test/repo"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"

  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export PROJECT_PATH="$TEST_TMP/worktree-a"
  export PROJECT_CONFIG="$TEST_TMP/.gaia/config/project-config.yaml"
  export PATH="$TEST_TMP/bin:$PATH"

  _BG_PIDS=()
}

teardown() {
  for p in "${_BG_PIDS[@]:-}"; do
    [ -n "${p:-}" ] && kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  rm -rf "${TEST_TMP:-}" 2>/dev/null || true
}

# Helper: run merge.sh. Extra positional args are env KEY=VALUE pairs.
_run_merge() {
  local exit_rc=0
  local stdout_file="$TEST_TMP/merge-stdout"
  local stderr_file="$TEST_TMP/merge-stderr"
  local env_args=()
  while [ $# -gt 0 ]; do env_args+=("$1"); shift; done

  if [ ${#env_args[@]} -gt 0 ]; then
    env "${env_args[@]}" bash "$MERGE_SH" 42 E900-S1 > "$stdout_file" 2> "$stderr_file" || exit_rc=$?
  else
    bash "$MERGE_SH" 42 E900-S1 > "$stdout_file" 2> "$stderr_file" || exit_rc=$?
  fi
  MERGE_STDOUT="$(cat "$stdout_file" 2>/dev/null)"
  MERGE_STDERR="$(cat "$stderr_file" 2>/dev/null)"
  return "$exit_rc"
}

# Helper: hold a lock to simulate another session.
_hold_lock() {
  local lock_file="$1" duration="${2:-30}" fallback="${3:-0}"
  (
    export GAIA_LOCK_FORCE_FALLBACK="$fallback"
    source "$LOCK_LIB"
    set +u
    acquire_lock "$lock_file" 60 201 --strict || exit 1
    sleep "$duration"
    release_lock 201
  ) &
  _BG_PIDS+=($!)
  sleep 0.5
}

# ──────────────────────────────────────────────────────────────
# Single-sprint mode — no lock acquired
# ──────────────────────────────────────────────────────────────

@test "single-sprint mode: no lock file created when limit absent" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint: {}
ci_cd:
  promotion_chain:
    - branch: staging
YAML
  _run_merge || true
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.lock" ]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

@test "single-sprint mode: no lock file created when limit is 1 and no per-sprint files" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 1
ci_cd:
  promotion_chain:
    - branch: staging
YAML
  _run_merge || true
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.lock" ]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

# ──────────────────────────────────────────────────────────────
# Transitional state: per-sprint files with limit 1
# ──────────────────────────────────────────────────────────────

@test "transitional state: lock acquired when per-sprint files exist with limit 1" {
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
sprint:
  max_concurrent_active: 1
ci_cd:
  promotion_chain:
    - branch: staging
YAML
  touch "$TEST_TMP/.gaia/state/sprint-status-sprint-99.yaml"

  # Wrap verify to record it was called (proves lock was acquired first).
  cat > "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh" <<STUB
#!/usr/bin/env bash
echo "verify_called" > "$TEST_TMP/verify-marker"
exit 0
STUB
  chmod +x "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh"

  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
  [[ ! "${MERGE_STDERR:-}" =~ "merge_deferred:" ]]
  # Verify was called (only runs inside the critical section in concurrent mode).
  [ -f "$TEST_TMP/verify-marker" ]
}

# ──────────────────────────────────────────────────────────────
# Concurrent mode: lock acquired and merge succeeds
# ──────────────────────────────────────────────────────────────

@test "concurrent mode: merge succeeds with lock and sidecar cleaned up" {
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
  [[ "${MERGE_STDOUT:-}" =~ "merged:squash" ]]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

# ──────────────────────────────────────────────────────────────
# Timeout exit 3 with holder-PID diagnostic and waiting message
# ──────────────────────────────────────────────────────────────

_run_timeout_test() {
  local fallback="$1"
  local lock_file="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  local holder_file="$TEST_TMP/.gaia/state/.promotion-merge.holder"

  _hold_lock "$lock_file" 30 "$fallback"
  local holder_pid="${_BG_PIDS[${#_BG_PIDS[@]}-1]}"
  printf '%s %s\n' "$holder_pid" "$(date +%s)" > "$holder_file"

  local rc=0
  _run_merge \
    "GAIA_MERGE_LOCK_TIMEOUT=2" \
    "GAIA_LOCK_FORCE_FALLBACK=$fallback" \
    || rc=$?

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  [ "$rc" -eq 3 ]
  [[ "$MERGE_STDERR" =~ "merge_deferred:" ]]
  [[ "$MERGE_STDERR" =~ "holder_pid=" ]]
  [[ "$MERGE_STDERR" =~ "waiting for promotion lock" ]]
}

@test "timeout exit 3 with holder-PID diagnostic and waiting message (flock)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  _run_timeout_test 0
}

@test "timeout exit 3 with holder-PID diagnostic and waiting message (fallback)" {
  _run_timeout_test 1
}

# ──────────────────────────────────────────────────────────────
# Lock release on success, failure, signal
# ──────────────────────────────────────────────────────────────

@test "lock released after successful merge: holder sidecar gone" {
  _run_merge || true
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

@test "lock released on merge failure: holder sidecar gone" {
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr checks"*) echo '[{"bucket":"pass","name":"ci"}]' ;;
  *"pr view"*"baseRefName"*) echo "staging" ;;
  *"pr view"*"mergeCommit"*) echo "OPEN" ;;
  *"pr view"*"--jq"*) echo "OPEN" ;;
  *"pr merge"*) echo "merge conflict" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

@test "lock released on SIGTERM: holder sidecar gone" {
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr checks"*) echo '[{"bucket":"pass","name":"ci"}]' ;;
  *"pr view"*"baseRefName"*) echo "staging" ;;
  *"pr view"*"--jq"*) echo "OPEN" ;;
  *"pr merge"*) sleep 30 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"

  bash "$MERGE_SH" 42 E900-S1 > /dev/null 2>&1 &
  local merge_pid=$!
  _BG_PIDS+=($merge_pid)
  sleep 1.5
  kill -TERM "$merge_pid" 2>/dev/null || true
  wait "$merge_pid" 2>/dev/null || true
  sleep 0.3
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

# ──────────────────────────────────────────────────────────────
# Blocked merge waits then proceeds
# ──────────────────────────────────────────────────────────────

_run_serialization_test() {
  local fallback="$1"
  local lock_file="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  _hold_lock "$lock_file" 3 "$fallback"
  local rc=0
  _run_merge \
    "GAIA_MERGE_LOCK_TIMEOUT=10" \
    "GAIA_LOCK_FORCE_FALLBACK=$fallback" \
    || rc=$?
  [ "$rc" -eq 0 ]
}

@test "blocked merge waits then proceeds (flock)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  _run_serialization_test 0
}

@test "blocked merge waits then proceeds (fallback)" {
  _run_serialization_test 1
}

# ──────────────────────────────────────────────────────────────
# Sidecar survives contender timeout
# ──────────────────────────────────────────────────────────────

_run_sidecar_survives_test() {
  local fallback="$1"
  local lock_file="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  local holder_file="$TEST_TMP/.gaia/state/.promotion-merge.holder"

  _hold_lock "$lock_file" 30 "$fallback"
  local session_a_pid="${_BG_PIDS[${#_BG_PIDS[@]}-1]}"
  printf '%s %s\n' "$session_a_pid" "$(date +%s)" > "$holder_file"

  local rc=0
  _run_merge \
    "GAIA_MERGE_LOCK_TIMEOUT=2" \
    "GAIA_LOCK_FORCE_FALLBACK=$fallback" \
    || rc=$?

  [ "$rc" -eq 3 ]
  [ -f "$holder_file" ]
  local sidecar_pid=""
  read -r sidecar_pid _ < "$holder_file"
  [ "$sidecar_pid" = "$session_a_pid" ]

  kill "$session_a_pid" 2>/dev/null || true
  wait "$session_a_pid" 2>/dev/null || true
}

@test "sidecar survives contender timeout (flock)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  _run_sidecar_survives_test 0
}

@test "sidecar survives contender timeout (fallback)" {
  _run_sidecar_survives_test 1
}

# ──────────────────────────────────────────────────────────────
# Project-root anchoring: decoy .gaia/state ignored
# ──────────────────────────────────────────────────────────────

@test "two contenders with different worktree dirs share one lock at the shared root" {
  local lock_file="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  mkdir -p "$TEST_TMP/worktree-a/.gaia/state"
  _hold_lock "$lock_file" 3 0
  local rc=0
  _run_merge \
    "PROJECT_PATH=$TEST_TMP/worktree-b" \
    "GAIA_MERGE_LOCK_TIMEOUT=10" \
    || rc=$?
  [ "$rc" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# Guard failure in concurrent mode: lock never taken
# ──────────────────────────────────────────────────────────────

@test "guard failure in concurrent mode: no lock or sidecar created" {
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr checks"*)
    echo '[{"bucket":"fail","name":"lint"}]'
    ;;
  *"pr view"*"baseRefName"*) echo "staging" ;;
  *"pr view"*"--jq"*) echo "OPEN" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"

  local rc=0
  _run_merge || rc=$?

  [ "$rc" -eq 1 ]
  # Guards run BEFORE lock acquisition — neither artifact should exist.
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.lock" ]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
  [[ "$MERGE_STDERR" =~ "lint" ]]
}

# ──────────────────────────────────────────────────────────────
# Verify exit mapping
# ──────────────────────────────────────────────────────────────

@test "verify exit 3 (no-chain skip) maps to merge exit 0" {
  cat > "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
  chmod +x "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
}

@test "stale worktree verify succeeds via refreshed remote-tracking ref" {
  # verify-pr-merged.sh receives origin/<branch> (refreshed by git fetch).
  # Record what ref was passed to verify.
  cat > "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh" <<STUB
#!/usr/bin/env bash
echo "\$2" > "$TEST_TMP/verify-ref-arg"
exit 0
STUB
  chmod +x "$PLUGIN_TREE/skills/gaia-dev-story/scripts/verify-pr-merged.sh"

  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
  # The ref passed to verify must be the remote-tracking form.
  [ -f "$TEST_TMP/verify-ref-arg" ]
  local ref_arg
  ref_arg="$(cat "$TEST_TMP/verify-ref-arg")"
  [[ "$ref_arg" == origin/* ]]
}

# ──────────────────────────────────────────────────────────────
# Failed git fetch inside the critical section
# ──────────────────────────────────────────────────────────────

@test "failed git fetch inside critical section maps to merge exit 1" {
  local fetch_counter="$TEST_TMP/git-fetch-count"
  echo "0" > "$fetch_counter"

  cat > "$TEST_TMP/bin/git" <<STUB
#!/usr/bin/env bash
case "\$1" in
  fetch)
    if [ "\${2:-}" = "origin" ]; then
      count=\$(cat "$fetch_counter" 2>/dev/null || echo "0")
      echo "\$((count + 1))" > "$fetch_counter"
      # Allow pre-merge fetches (base + PR head); fail the post-merge one.
      [ "\$count" -ge 2 ] && exit 1
      exit 0
    fi
    ;;
  merge-base) [ "\${2:-}" = "--is-ancestor" ] && exit 0 ;;
  rev-parse)
    if [ "\${2:-}" = "--verify" ] && [[ "\${3:-}" == origin/* ]]; then
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; exit 0
    fi
    ;;
  log)
    if [ "\${2:-}" = "--format=%H" ]; then
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; exit 0
    fi
    [ "\${2:-}" = "-1" ] && exit 0
    ;;
  check-ref-format) [ "\${2:-}" = "--branch" ] && { echo "\${3:-}"; exit 0; } ;;
esac
exec "$REAL_GIT" "\$@"
STUB
  chmod +x "$TEST_TMP/bin/git"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$MERGE_STDERR" =~ "merged but unverified" ]]
}

# ──────────────────────────────────────────────────────────────
# Re-run after already merged: lock-free idempotency path
# ──────────────────────────────────────────────────────────────

@test "re-run after merged takes already-merged exit 0 (lock-free)" {
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*"--jq"*) echo "MERGED" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$MERGE_STDOUT" =~ "already_merged" ]]
  [ ! -f "$TEST_TMP/.gaia/state/.promotion-merge.holder" ]
}

# ──────────────────────────────────────────────────────────────
# Recovery path: remote reports MERGED after local failure
# ──────────────────────────────────────────────────────────────

@test "recovery path runs verification inside critical section" {
  local call_counter="$TEST_TMP/gh-call-count"
  echo "0" > "$call_counter"

  cat > "$TEST_TMP/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"pr checks"*)
    echo '[{"bucket":"pass","name":"ci"}]'
    ;;
  *"pr view"*"mergeCommit"*"--jq"*)
    echo "MERGED"
    ;;
  *"pr view"*"--jq .state"*|*"pr view"*"--jq '.state'"*)
    count=\$(cat "$call_counter" 2>/dev/null || echo "0")
    echo "\$((count + 1))" > "$call_counter"
    if [ "\$count" -eq 0 ]; then echo "OPEN"; else echo "MERGED"; fi
    ;;
  *"pr view"*"baseRefName"*) echo "staging" ;;
  *"pr view"*"headRefName"*) echo "feat/test" ;;
  *"pr merge"*) echo "already used by worktree" >&2; exit 1 ;;
  *"repo view"*"--jq"*) echo "test/repo" ;;
  *"api -X DELETE"*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$MERGE_STDOUT" =~ "merged:squash" ]]
}

# ──────────────────────────────────────────────────────────────
# Strict-mode exit codes
# ──────────────────────────────────────────────────────────────

@test "symlink lock path exits 4" {
  ln -sf /dev/null "$TEST_TMP/.gaia/state/.promotion-merge.lock"
  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 4 ]
}

@test "directory with unrelated contents at lock path exits 4" {
  local lp="$TEST_TMP/.gaia/state/.promotion-merge.lock"
  mkdir -p "$lp/subdir"
  echo "not-our-file" > "$lp/subdir/something"
  local rc=0
  _run_merge || rc=$?
  rm -rf "$lp" 2>/dev/null || true
  [ "$rc" -eq 4 ]
}

@test "identity mismatch exits 5" {
  # Replace acquire-lock.sh in the copied tree with a version that returns
  # exit 5 (identity mismatch) for the promotion-merge lock path.
  local real_lib="$PLUGIN_TREE/scripts/lib/acquire-lock.sh"
  cat > "$real_lib" <<'LOCKSTUB'
#!/usr/bin/env bash
set -euo pipefail; LC_ALL=C; export LC_ALL
export GAIA_LOCK_L3_PATH=".promotion-merge.lock"
export GAIA_LOCK_L3_TIMEOUT="${GAIA_MERGE_LOCK_TIMEOUT:-120}"
export ACQUIRE_LOCK_EXIT_TIMEOUT=3
export ACQUIRE_LOCK_EXIT_SYMLINK=4
export ACQUIRE_LOCK_EXIT_IDENTITY=5
acquire_lock() {
  local lock_file="$1"
  case "$lock_file" in
    *".promotion-merge.lock")
      printf 'lock_identity_unstable: identity re-check mismatch: %s\n' "$lock_file" >&2
      return 5 ;;
  esac
  return 0
}
release_lock() { :; }
acquire_lock_is_concurrent_mode() {
  local limit="${1:-}"
  [ -n "$limit" ] && [ "$limit" -gt 1 ] 2>/dev/null && return 0
  local _psf=""
  if [ -n "${2:-}" ] && [ -d "${2:-}" ]; then
    _psf="$(find "${2:-}" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || _psf=""
  fi
  [ -n "$_psf" ] && return 0
  return 1
}
LOCKSTUB
  # Also update the mirror.
  cp "$real_lib" "$PLUGIN_TREE/skills/gaia-dev-story/scripts/lib/acquire-lock.sh"

  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 5 ]
}

@test "generic lock failure exits 7" {
  # Replace acquire-lock.sh to return exit 1 (generic refusal) for the
  # promotion-merge lock path. merge.sh maps this to exit 7.
  local real_lib="$PLUGIN_TREE/scripts/lib/acquire-lock.sh"
  cat > "$real_lib" <<'LOCKSTUB'
#!/usr/bin/env bash
set -euo pipefail; LC_ALL=C; export LC_ALL
export GAIA_LOCK_L3_PATH=".promotion-merge.lock"
export GAIA_LOCK_L3_TIMEOUT="${GAIA_MERGE_LOCK_TIMEOUT:-120}"
export ACQUIRE_LOCK_EXIT_TIMEOUT=3
export ACQUIRE_LOCK_EXIT_SYMLINK=4
export ACQUIRE_LOCK_EXIT_IDENTITY=5
acquire_lock() {
  local lock_file="$1"
  case "$lock_file" in
    *".promotion-merge.lock")
      printf 'acquire-lock: cannot create lock directory\n' >&2
      return 1 ;;
  esac
  return 0
}
release_lock() { :; }
acquire_lock_is_concurrent_mode() {
  local limit="${1:-}"
  [ -n "$limit" ] && [ "$limit" -gt 1 ] 2>/dev/null && return 0
  local _psf=""
  if [ -n "${2:-}" ] && [ -d "${2:-}" ]; then
    _psf="$(find "${2:-}" -maxdepth 1 -name 'sprint-status-*.yaml' ! -name '*.lock' ! -name '*.result' 2>/dev/null | head -1)" || _psf=""
  fi
  [ -n "$_psf" ] && return 0
  return 1
}
LOCKSTUB
  cp "$real_lib" "$PLUGIN_TREE/skills/gaia-dev-story/scripts/lib/acquire-lock.sh"

  local rc=0
  _run_merge || rc=$?
  [ "$rc" -eq 7 ]
}

# ──────────────────────────────────────────────────────────────
# Deferred outcome in phase-parallel orchestrator
# ──────────────────────────────────────────────────────────────

@test "ppo_record_outcome deferred: releases slot and logs event" {
  source "$PPO_SH"
  set +u

  export GAIA_SESSION_DIR="$TEST_TMP/session"
  mkdir -p "$GAIA_SESSION_DIR"

  local engine_dir="$GAIA_SESSION_DIR/ppo"
  mkdir -p "$engine_dir/running"
  echo "mode=parallel reason=none" > "$engine_dir/mode"
  echo "2" > "$engine_dir/slots"
  echo "1" > "$engine_dir/current_phase"

  cat > "$engine_dir/running/E900-S1" <<'ENTRY'
phase:1
persona:bash-dev
worktree:/tmp/test-wt
handle:test-handle
ENTRY

  local output=""
  output="$(ppo_record_outcome E900-S1 deferred 2>&1)" || true

  [ ! -f "$engine_dir/running/E900-S1" ]
  [[ "$output" =~ "story_merge_deferred" ]]
  [[ "$output" =~ "outcome=deferred" ]]
}

# ──────────────────────────────────────────────────────────────
# SKILL.md per-line assertions
# ──────────────────────────────────────────────────────────────

@test "dev-story SKILL.md Step 13: exit 3 documented as deferred" {
  grep -q 'Exit 3.*deferred' "${PLUGIN_ROOT}/skills/gaia-dev-story/SKILL.md"
}

@test "dev-story SKILL.md Step 13: exits 4, 5, 7 documented as lock errors" {
  grep -q 'Exit 4.*5.*7' "${PLUGIN_ROOT}/skills/gaia-dev-story/SKILL.md"
}

@test "dev-story SKILL.md Step 14 skipped when deferred" {
  grep -q 'Step 14 is skipped when Step 13 returns exit 3' "${PLUGIN_ROOT}/skills/gaia-dev-story/SKILL.md"
}

@test "run-sprint SKILL.md documents deferred in record vocabulary" {
  local f="${PLUGIN_ROOT}/skills/gaia-run-sprint/SKILL.md"
  grep -q 'deferred' "$f"
  grep -q 'done|failed|timeout|merged|deferred' "$f"
}

# ──────────────────────────────────────────────────────────────
# acquire_lock_is_concurrent_mode helper
# ──────────────────────────────────────────────────────────────

@test "is_concurrent_mode: returns 0 when limit > 1" {
  acquire_lock_is_concurrent_mode 2 "$TEST_TMP/.gaia/state"
}

@test "is_concurrent_mode: returns 1 when limit 1 and no per-sprint files" {
  local rc=0
  acquire_lock_is_concurrent_mode 1 "$TEST_TMP/.gaia/state" || rc=$?
  [ "$rc" -eq 1 ]
}

@test "is_concurrent_mode: returns 0 when limit 1 but per-sprint files exist" {
  touch "$TEST_TMP/.gaia/state/sprint-status-sprint-99.yaml"
  acquire_lock_is_concurrent_mode 1 "$TEST_TMP/.gaia/state"
}

@test "is_concurrent_mode: returns 1 when limit absent and no per-sprint files" {
  local rc=0
  acquire_lock_is_concurrent_mode "" "$TEST_TMP/.gaia/state" || rc=$?
  [ "$rc" -eq 1 ]
}
