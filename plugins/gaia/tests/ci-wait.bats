#!/usr/bin/env bats
# ci-wait.bats — behavioural tests for ci-wait.sh
#
# Covers: jq-based bucket counting, --required check filtering, cancel
# handling, named-check error messages, config-driven timeout, grace window
# for late-registering checks, two-poll stability rule, non-git guard
# ordering, and schema/SKILL.md documentation wiring.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

CI_WAIT_REL="../skills/gaia-dev-story/scripts/ci-wait.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ci_wait_path() {
  printf '%s' "$(cd "$BATS_TEST_DIRNAME/$(dirname "$CI_WAIT_REL")" && pwd)/$(basename "$CI_WAIT_REL")"
}

# _write_fixture TYPE INDEX JSON [EXIT_CODE] [STDERR]
# Writes a gh stub fixture file.
_write_fixture() {
  local type="$1" idx="$2" json="$3" ec="${4:-0}" stderr="${5:-}"
  local f="$TEST_TMP/gh-fixture-${type}-${idx}"
  printf '%s\n' "$json" > "$f"
  printf '%s\n' "$ec" >> "$f"
  if [ -n "$stderr" ]; then
    printf '%s\n' "$stderr" >> "$f"
  fi
}

# _write_prview JSON [EXIT_CODE] [STDERR]
_write_prview() {
  local json="$1" ec="${2:-0}" stderr="${3:-}"
  local f="$TEST_TMP/gh-fixture-prview"
  printf '%s\n' "$json" > "$f"
  printf '%s\n' "$ec" >> "$f"
  if [ -n "$stderr" ]; then
    printf '%s\n' "$stderr" >> "$f"
  fi
}

# _write_config CONTENT — write a minimal resolver-compatible project config
_write_config() {
  local content="$1"
  local cfg="$TEST_TMP/project-config.yaml"
  cat > "$cfg" <<CFGEOF
date: 2026-01-01
framework_version: 1.200.0
installed_path: /tmp/gaia
project_path: /tmp/proj
project_root: /tmp/proj
${content}
CFGEOF
  export GAIA_SHARED_CONFIG="$cfg"
}

# _write_config_at DIR CONTENT — write config at a given root
_write_config_at() {
  local dir="$1" content="$2"
  mkdir -p "$dir/.gaia/config"
  cat > "$dir/.gaia/config/project-config.yaml" <<CFGEOF
date: 2026-01-01
framework_version: 1.200.0
installed_path: /tmp/gaia
project_path: $dir
project_root: $dir
${content}
CFGEOF
}

# _count_required_calls — count --required appearances in gh call log
_count_required_calls() {
  local c=0
  c=$(grep -c -- '--required' "$TEST_TMP/gh-calls.log" 2>/dev/null) || true
  printf '%s' "$c"
}

# _count_pr_checks_calls — count 'pr checks' appearances in gh call log
_count_pr_checks_calls() {
  local c=0
  c=$(grep -c 'pr checks' "$TEST_TMP/gh-calls.log" 2>/dev/null) || true
  printf '%s' "$c"
}

# All-pass JSON with an optional failing check (for all-checks fixture)
_ALL_PASS='[{"name":"build","bucket":"pass","state":"SUCCESS"},{"name":"lint","bucket":"skipping","state":"NEUTRAL"}]'
_ALL_PASS_WITH_OPT_FAIL='[{"name":"build","bucket":"pass","state":"SUCCESS"},{"name":"lint","bucket":"skipping","state":"NEUTRAL"},{"name":"optional-lint","bucket":"fail","state":"FAILURE"}]'

# _install_sleep_shim — write a sleep shim that counts calls and terminates
# the parent process past a call budget. The shim's $PPID is ci-wait.sh
# because sleep is a direct child of the script process.
_install_sleep_shim() {
  local budget="${CI_WAIT_SLEEP_BUDGET:-10}"
  cat > "$TEST_TMP/bin/sleep" <<SHIMEOF
#!/usr/bin/env bash
# Log the argument so tests can assert on the actual poll/grace interval used
printf '%s\n' "\$1" >> "\${TEST_TMP:-/tmp}/sleep-args.log"
count_file="\${TEST_TMP:-/tmp}/sleep-count"
if [ ! -f "\$count_file" ]; then printf '0' > "\$count_file"; fi
n=\$(cat "\$count_file")
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
if [ "\$n" -gt ${budget} ]; then
  kill -TERM \$PPID 2>/dev/null || true
  exit 1
fi
exit 0
SHIMEOF
  chmod +x "$TEST_TMP/bin/sleep"
}

# _install_gh_stub — write the argument-aware gh stub
_install_gh_stub() {
  cat > "$TEST_TMP/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Log every call
printf '%s\n' "$*" >> "${TEST_TMP}/gh-calls.log"

# --- pr view ---
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  f="${TEST_TMP}/gh-fixture-prview"
  if [ -f "$f" ]; then
    stdout=$(sed -n '1p' "$f")
    ec=$(sed -n '2p' "$f")
    stderr=$(sed -n '3p' "$f")
    [ -n "$stderr" ] && printf '%s\n' "$stderr" >&2
    printf '%s\n' "$stdout"
    exit "${ec:-0}"
  fi
  printf '{"baseRefName":"main"}\n'
  exit 0
fi

# --- pr checks ---
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  has_required=0
  for arg in "$@"; do
    [ "$arg" = "--required" ] && has_required=1
  done

  # Read counter (advances ONLY on --required calls)
  counter_file="${TEST_TMP}/gh-poll-counter"
  snapshot_file="${TEST_TMP}/gh-poll-snapshot"
  if [ ! -f "$counter_file" ]; then printf '0' > "$counter_file"; fi
  idx=$(cat "$counter_file")

  if [ "$has_required" -eq 1 ]; then
    # Snapshot the index BEFORE advancing so all-checks in the same
    # poll iteration reads the same fixture index as --required.
    printf '%s' "$idx" > "$snapshot_file"
    # Advance counter for the next poll iteration
    printf '%s' "$((idx + 1))" > "$counter_file"
    ftype="required"
  else
    # All-checks reads the snapshot left by the preceding --required call
    if [ -f "$snapshot_file" ]; then
      idx=$(cat "$snapshot_file")
    fi
    ftype="all"
  fi

  # Find fixture; past last → repeat last
  f="${TEST_TMP}/gh-fixture-${ftype}-${idx}"
  if [ ! -f "$f" ]; then
    # Find highest available index
    local_idx=$((idx - 1))
    while [ "$local_idx" -ge 0 ]; do
      f="${TEST_TMP}/gh-fixture-${ftype}-${local_idx}"
      [ -f "$f" ] && break
      local_idx=$((local_idx - 1))
    done
    if [ ! -f "$f" ]; then
      # No fixture at all — return empty array
      printf '[]\n'
      exit 0
    fi
  fi

  stdout=$(sed -n '1p' "$f")
  ec=$(sed -n '2p' "$f")
  stderr=$(sed -n '3,$p' "$f")
  [ -n "$stderr" ] && printf '%s' "$stderr" >&2
  printf '%s\n' "$stdout"
  exit "${ec:-0}"
fi

# default
exit 0
STUBEOF
  chmod +x "$TEST_TMP/bin/gh"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup

  # Save the full PATH so teardown always has system tools
  ORIG_PATH="$PATH"

  # Isolate from real configs
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_SHARED_CONFIG GAIA_LOCAL_CONFIG
  unset CLAUDE_SKILL_DIR GAIA_PROJECT_ROOT
  export GAIA_NO_PROJECT_WALKUP=1
  export CI_WAIT_POLL_INTERVAL=0

  CI_WAIT="$(_ci_wait_path)"

  # jq must be available (never skip)
  command -v jq >/dev/null 2>&1 || { echo "jq required"; return 1; }

  # Build stub directory
  mkdir -p "$TEST_TMP/bin"
  _install_gh_stub
  _install_sleep_shim
  printf '0' > "$TEST_TMP/sleep-count"

  # Put stubs first on PATH
  export PATH="$TEST_TMP/bin:$PATH"

  # Init a git repo for PROJECT_PATH
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$TEST_TMP/repo" >/dev/null 2>&1
  git -C "$TEST_TMP/repo" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  export PROJECT_PATH="$TEST_TMP/repo"

  # Init call log, counter, and sleep-args log
  : > "$TEST_TMP/gh-calls.log"
  : > "$TEST_TMP/sleep-args.log"
  printf '0' > "$TEST_TMP/gh-poll-counter"
}

teardown() {
  # Restore full PATH so system rm is available for cleanup
  export PATH="${ORIG_PATH:-$PATH}"
  # Fix unreadable files so cleanup can remove them (portable: no GNU find flags)
  chmod -R u+rw "$TEST_TMP" 2>/dev/null || true
  common_teardown
}

# ===========================================================================
# Tests
# ===========================================================================

# --- 1: all required checks pass with pass+skipping buckets ---
@test "all checks pass with pass and skipping buckets" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$stderr" == *"all CI checks passed"* ]]
  # Exact poll count: 2 polls for two-poll stability rule
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -eq 2 ]
}

# --- 2: pending checks resolve to pass after multiple polls ---
@test "pending checks resolve to pass after polling" {
  local pending_mix='[{"name":"a","bucket":"pass","state":"SUCCESS"},{"name":"b","bucket":"skipping","state":"NEUTRAL"},{"name":"c","bucket":"pending","state":"IN_PROGRESS"}]'
  local all_pass_3='[{"name":"a","bucket":"pass","state":"SUCCESS"},{"name":"b","bucket":"skipping","state":"NEUTRAL"},{"name":"c","bucket":"pass","state":"SUCCESS"}]'
  _write_fixture required 0 "$pending_mix"
  _write_fixture required 1 "$all_pass_3"
  _write_fixture required 2 "$all_pass_3"
  _write_fixture required 3 "$all_pass_3"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # Exact poll count: 1 pending + 2 all-terminal (two-poll rule) = 3 polls
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -eq 3 ]
}

# --- 3: failed check names the specific check and its bucket ---
@test "failed check names the check and bucket" {
  _write_fixture required 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"}]'
  _write_fixture all 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bats-tests (fail)"* ]]
  grep -q -- '--required' "$TEST_TMP/gh-calls.log"
}

# --- 4: cancelled check reported with name and cancel bucket ---
@test "cancelled check reports failure with name" {
  _write_fixture required 0 '[{"name":"deploy","bucket":"cancel","state":"CANCELLED"}]'
  _write_fixture all 0 '[{"name":"deploy","bucket":"cancel","state":"CANCELLED"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"deploy (cancel)"* ]]
  grep -q -- '--required' "$TEST_TMP/gh-calls.log"
}

# --- 5: wall-clock timeout fires before any poll ---
@test "timeout fires before first poll" {
  run --separate-stderr "$CI_WAIT" 1234 --timeout 0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"timed out"* ]]
}

# --- 6: config-driven timeout read via resolver ---
@test "config-driven timeout from resolver" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 2"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 2m)"* ]]
}

# --- 7: config discovered via PROJECT_ROOT (no GAIA_SHARED_CONFIG) ---
@test "config found via PROJECT_ROOT without GAIA_SHARED_CONFIG" {
  # Write config at a SEPARATE directory so only PROJECT_ROOT finds it
  local config_root="$TEST_TMP/config-root"
  mkdir -p "$config_root"
  _write_config_at "$config_root" "ci_cd:
  ci_wait_timeout_minutes: 2"
  unset GAIA_SHARED_CONFIG
  export PROJECT_ROOT="$config_root"

  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 2m)"* ]]
}

# --- 8: CLI --timeout overrides config value ---
@test "CLI timeout overrides config value" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 60"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234 --timeout 1
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 1m)"* ]]
}

# --- 9: default 30 minutes when no config or CLI flag ---
@test "default timeout is 30 minutes without config" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 30m)"* ]]
}

# --- 10: zero config falls back to 30 with out-of-range warning ---
@test "out-of-range config falls back to 30 with warning" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 0"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"out of range"* ]]
  [[ "$stderr" == *"(timeout: 30m)"* ]]
}

# --- 11: 361 is out of range ---
@test "config value 361 falls back to 30 with warning" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 361"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"out of range"* ]]
  [[ "$stderr" == *"(timeout: 30m)"* ]]
}

# --- 12: leading-zero config (08, 010) rejected as not a whole number ---
@test "leading-zero config value falls back to 30 with warning" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 08"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a whole number"* ]]
  [[ "$stderr" == *"(timeout: 30m)"* ]]
}

# --- 13: no required checks logs note and falls back to all checks ---
@test "no required checks falls back to all checks" {
  _write_fixture required 0 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture required 1 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture all 0 "$_ALL_PASS"
  _write_fixture all 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no required checks configured, using all checks"* ]]
  # Must NOT contain retry-path text
  if [[ "$stderr" == *"polling error"* ]]; then echo "stderr unexpectedly contained 'polling error'" >&2; return 1; fi
}

# --- 14: no required checks with pending all-checks resolves ---
@test "no required checks with pending all-checks resolves" {
  local pending='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
  _write_fixture required 0 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture required 1 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture required 2 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture all 0 "$pending"
  _write_fixture all 1 "$_ALL_PASS"
  _write_fixture all 2 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 3 ]
}

# --- 15: unknown flag warning, fallback, then stops retrying --required ---
@test "gh without required flag falls back with warning" {
  _write_fixture required 0 "" 1 "unknown flag: --required"
  _write_fixture all 0 "$_ALL_PASS"
  _write_fixture all 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING"* ]]
  [[ "$stderr" == *"--required"* ]]
  [[ "$stderr" == *"falling back"* ]]
  # Must NOT contain retry-path text
  if [[ "$stderr" == *"polling error"* ]]; then echo "stderr unexpectedly contained 'polling error'" >&2; return 1; fi
  # After the first failure, --required should NOT be retried; count must be 1
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -eq 1 ]
}

# --- 16: required checks pass while optional fails ---
@test "required checks pass while optional check fails" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  grep -q -- '--required' "$TEST_TMP/gh-calls.log"
  # Must NOT contain retry-path text
  if [[ "$stderr" == *"polling error"* ]]; then echo "stderr unexpectedly contained 'polling error'" >&2; return 1; fi
}

# --- 17: no checks then they appear after grace window starts ---
@test "checks appear after initial absence" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture required 1 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 1 "" 1 "no checks reported on the 'main' branch"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture required 3 "$_ALL_PASS"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 3 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # Must NOT contain retry-path text
  if [[ "$stderr" == *"polling error"* ]]; then echo "stderr unexpectedly contained 'polling error'" >&2; return 1; fi
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 3 ]
}

# --- 18: timeout beats grace window ---
@test "timeout wins when shorter than grace window" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=300

  run --separate-stderr "$CI_WAIT" 1234 --timeout 0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"timed out"* ]]
}

# --- 19: grace expiry with no CI configured → exit 0 with no-CI note ---
@test "grace expiry with no CI configured exits 0" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$stderr" == *"no CI checks configured"* ]]
}

# --- 20: grace expiry with CI expected → exit 1 naming check names ---
@test "grace expiry with CI configured exits 1 naming checks" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions
      ci_checks:
        - bats-tests"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bats-tests"* ]]
  [[ "$stderr" == *"expected checks never appeared"* ]]
}

# --- 21: grace expiry, yq not on PATH → exit 1 naming yq ---
@test "grace expiry without yq exits 1 naming yq" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_checks:
        - plugin-ci"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  # Build yq-free restricted dir
  local yqfree="$TEST_TMP/yqfree-bin"
  mkdir -p "$yqfree"
  local tool
  for tool in bash git env sed awk grep sort head tail cut dirname cat rm mktemp tr stat wc; do
    local tp
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tp" ] && ln -sf "$tp" "$yqfree/$tool"
  done
  ln -sf "$(command -v jq)" "$yqfree/jq"
  ln -sf "$TEST_TMP/bin/gh" "$yqfree/gh"
  ln -sf "$TEST_TMP/bin/sleep" "$yqfree/sleep"
  local kp
  kp="$(command -v kill 2>/dev/null || true)"
  [ -n "$kp" ] && [ -f "$kp" ] && ln -sf "$kp" "$yqfree/kill"

  export PATH="$yqfree"
  if command -v yq >/dev/null 2>&1; then echo "yq unexpectedly found on restricted PATH" >&2; return 1; fi

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"yq not found"* ]]
}

# --- 22: grace expiry, config path is a directory → exit 1 naming cause ---
@test "grace expiry with config directory exits 1 naming config cause" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  mkdir -p "$TEST_TMP/fake-config-dir"
  export GAIA_SHARED_CONFIG="$TEST_TMP/fake-config-dir"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"config"* ]]
  [[ "$stderr" == *"directory"* ]]
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured'" >&2; return 1; fi
}

# --- 23: grace expiry, unreadable config → exit 1 naming cause ---
@test "grace expiry with unreadable config exits 1 naming config cause" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  local unreadable="$TEST_TMP/unreadable-config.yaml"
  printf 'ci_cd: {}\n' > "$unreadable"
  chmod 000 "$unreadable"
  export GAIA_SHARED_CONFIG="$unreadable"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"config"* ]]
  [[ "$stderr" == *"not readable"* ]]
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured'" >&2; return 1; fi
}

# --- 24: grace expiry, pr view fails → exit 1 naming base branch ---
@test "grace expiry when pr view fails exits 1 naming base branch cause" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview "" 1 "not found"
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_checks:
        - plugin-ci"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not determine base branch"* ]]
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured'" >&2; return 1; fi
}

# --- 25: grace expiry, empty baseRefName → exit 1 naming base branch ---
@test "grace expiry with empty baseRefName exits 1 naming base branch cause" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":""}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_checks:
        - plugin-ci"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not determine base branch"* ]]
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured'" >&2; return 1; fi
}

# --- 26: malformed config during grace → exit 1 naming config cause ---
@test "grace expiry with malformed config exits 1 naming config cause" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  local bad_cfg="$TEST_TMP/bad-config.yaml"
  printf '{{invalid yaml\n' > "$bad_cfg"
  export GAIA_SHARED_CONFIG="$bad_cfg"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"failed to read config"* ]]
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured'" >&2; return 1; fi
}

# --- 27: grace decision discovers config via PROJECT_ROOT, no ci_checks → 0 ---
@test "grace expiry discovers config without GAIA_SHARED_CONFIG exits 0 when no ci_checks" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  # Write config at a SEPARATE directory, not at PROJECT_PATH or PWD
  local config_root="$TEST_TMP/config-root"
  mkdir -p "$config_root"
  _write_config_at "$config_root" "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"
  unset GAIA_SHARED_CONFIG
  export PROJECT_ROOT="$config_root"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$stderr" == *"no CI checks configured"* ]]
}

# --- 28: config discovered by walk-up within git repo ---
@test "config found by walk-up from working directory" {
  # Build a repo with config at its root, and PROJECT_PATH at a subdirectory.
  # Canonicalize TEST_TMP so macOS /tmp→/private/tmp doesn't cause a vacuous pass.
  local canon_tmp
  canon_tmp="$(cd "$TEST_TMP" && pwd -P)"
  local repo_root="$canon_tmp/walkup-repo"
  local subdir="$repo_root/subdir"
  mkdir -p "$subdir"
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$repo_root" >/dev/null 2>&1
  git -C "$repo_root" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  _write_config_at "$repo_root" "ci_cd:
  ci_wait_timeout_minutes: 3
  promotion_chain:
    - branch: main
      ci_provider: github_actions"

  # Unset everything so only walk-up can find config
  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_NO_PROJECT_WALKUP
  export PROJECT_PATH="$subdir"

  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # Timeout came from walk-up config AND grace decision found the config
  [[ "$stderr" == *"(timeout: 3m)"* ]]
  [[ "$stderr" == *"no CI checks configured"* ]]
}

# --- 29: late required check prevents early exit ---
@test "late required check prevents early exit" {
  local one_pass='[{"name":"a","bucket":"pass","state":"SUCCESS"}]'
  local two_mixed='[{"name":"a","bucket":"pass","state":"SUCCESS"},{"name":"b","bucket":"pending","state":"IN_PROGRESS"}]'
  local two_pass='[{"name":"a","bucket":"pass","state":"SUCCESS"},{"name":"b","bucket":"pass","state":"SUCCESS"}]'
  _write_fixture required 0 "$one_pass"
  _write_fixture required 1 "$two_mixed"
  _write_fixture required 2 "$two_pass"
  _write_fixture required 3 "$two_pass"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 3 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 4 ]
}

# --- 30: pending interruption resets two-poll stability ---
@test "two-poll reset after pending interruption" {
  local a_pass='[{"name":"a","bucket":"pass","state":"SUCCESS"}]'
  local a_pending='[{"name":"a","bucket":"pending","state":"IN_PROGRESS"}]'
  _write_fixture required 0 "$a_pass"
  _write_fixture required 1 "$a_pending"
  _write_fixture required 2 "$a_pass"
  _write_fixture required 3 "$a_pass"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 3 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 4 ]
}

# --- 31: new terminal check resets two-poll counter ---
@test "new already-terminal check resets two-poll counter" {
  local a_pass='[{"name":"a","bucket":"pass","state":"SUCCESS"}]'
  local ab_pass='[{"name":"a","bucket":"pass","state":"SUCCESS"},{"name":"b","bucket":"pass","state":"SUCCESS"}]'
  _write_fixture required 0 "$a_pass"
  _write_fixture required 1 "$ab_pass"
  _write_fixture required 2 "$ab_pass"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 3 ]
}

# --- 32: non-JSON retries as transient error with attempt counter ---
@test "non-JSON output retries as transient error" {
  _write_fixture required 0 "oops"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture all 0 "oops"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"polling error: invalid JSON (attempt 1/"* ]]
  local pc
  pc=$(_count_pr_checks_calls)
  [ "$pc" -ge 2 ]
}

# --- 33: persistent non-JSON ends in exit 1 after 5 failures ---
@test "persistent non-JSON exits 1 after max failures" {
  # All polls return non-JSON, never recovers
  local i
  for i in 0 1 2 3 4 5 6; do
    _write_fixture required "$i" "oops"
    _write_fixture all "$i" "oops"
  done

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Invalid JSON output"* ]]
  # Verify gh-calls.log is not empty (calls were made)
  local pc
  pc=$(_count_pr_checks_calls)
  [ "$pc" -gt 0 ]
}

# --- 34: persistent all-checks error reaches max failures ---
@test "persistent fallback error exits 1 after 5 failures" {
  # --required says "no required checks", falling back every time.
  # all-checks persistently fails with a non-"no checks reported" error.
  local i
  for i in 0 1 2 3 4 5 6; do
    _write_fixture required "$i" "" 1 "no required checks reported on the 'main' branch"
    _write_fixture all "$i" "" 1 "internal server error"
  done

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"CI polling failed 5 consecutive times"* ]]
}

# --- 35: valid JSON with stderr notice still succeeds ---
@test "valid JSON with stderr notice still succeeds" {
  _write_fixture required 0 "$_ALL_PASS" 0 "notice: rate limit approaching"
  _write_fixture required 1 "$_ALL_PASS" 0 "notice: rate limit approaching"
  _write_fixture all 0 "$_ALL_PASS" 0 "notice: rate limit"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# --- 36: jq missing → exit 1 naming jq ---
@test "jq missing exits 1 naming jq" {
  local jqfree="$TEST_TMP/jqfree-bin"
  mkdir -p "$jqfree"
  local tool
  for tool in bash git env sed awk grep sort head tail cut dirname cat rm mktemp tr stat wc; do
    local tp
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tp" ] && ln -sf "$tp" "$jqfree/$tool"
  done
  local yp
  yp="$(command -v yq 2>/dev/null || true)"
  [ -n "$yp" ] && ln -sf "$yp" "$jqfree/yq"
  ln -sf "$TEST_TMP/bin/gh" "$jqfree/gh"
  ln -sf "$TEST_TMP/bin/sleep" "$jqfree/sleep"

  export PATH="$jqfree"
  if command -v jq >/dev/null 2>&1; then echo "jq unexpectedly found on restricted PATH" >&2; return 1; fi

  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"jq not found"* ]]
}

# --- 37: non-git mode skips and prints warning ---
@test "non-git mode skips without jq" {
  local jqfree="$TEST_TMP/jqfree-bin"
  mkdir -p "$jqfree"
  local tool
  for tool in bash git env sed awk grep sort head tail cut dirname cat rm mktemp tr stat wc; do
    local tp
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tp" ] && ln -sf "$tp" "$jqfree/$tool"
  done
  ln -sf "$TEST_TMP/bin/gh" "$jqfree/gh"
  ln -sf "$TEST_TMP/bin/sleep" "$jqfree/sleep"

  export PATH="$jqfree"
  if command -v jq >/dev/null 2>&1; then echo "jq unexpectedly found on restricted PATH" >&2; return 1; fi

  export PROJECT_PATH="$TEST_TMP"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped"* ]]
}

# --- 38: schema documents ci_wait_timeout_minutes ---
@test "schema documents ci-wait timeout key" {
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  local json_schema="$repo_root/plugins/gaia/schemas/project-config.schema.json"
  local yaml_schema="$repo_root/plugins/gaia/config/project-config.schema.yaml"

  run jq -e '.properties.ci_cd.properties.ci_wait_timeout_minutes | .type == "integer" and .minimum == 1 and .maximum == 360' "$json_schema"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  assert_file_contains "$yaml_schema" "ci_wait_timeout_minutes"
}

# --- 39: Step 12 background+foreground, completion-wait, halt-on-timeout ---
@test "Step 12 waits for completion before Step 13 and halts on timeout" {
  local skill_md
  skill_md="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/skills/gaia-dev-story/SKILL.md"
  [ -f "$skill_md" ] || { echo "SKILL.md not found"; return 1; }

  local step12
  step12=$(sed -n '/^### Step 12/,/^### Step 13/p' "$skill_md")
  [ -n "$step12" ] || { echo "Step 12 block not found"; return 1; }

  # Background command present, explicitly says no --timeout
  echo "$step12" | grep -qi 'background'
  echo "$step12" | grep -q 'ci-wait.sh.*no.*--timeout\|no.*--timeout.*ci-wait.sh'
  # Must wait for background completion before Step 13
  echo "$step12" | grep -qi 'wait.*completion\|completion.*notice'
  echo "$step12" | grep -qi 'never start Step 13 before'
  # Foreground fallback with --timeout and 600000
  echo "$step12" | grep -q -- '--timeout'
  echo "$step12" | grep -qE '600.?000|10.min'
  # Outcome rules apply to both paths
  echo "$step12" | grep -qi 'both paths'
  # Anchored halt assertions: timed-out-no-budget → HALT, other-failure → HALT
  # A mutant changing HALT to "Proceed to Step 13" on these lines must go red.
  echo "$step12" | grep -q 'no budget remaining.*HALT'
  echo "$step12" | grep -q 'CI check failed.*HALT'
  # Only exit 0 with "passed" should proceed to Step 13
  echo "$step12" | grep -q 'Exit 0.*passed.*Step 13'
  # Must NOT claim merge script will re-check
  if echo "$step12" | grep -qi 'merge.*re-check\|re-check.*merge'; then
    echo "Step 12 unexpectedly claims merge script re-checks" >&2
    return 1
  fi
}

# --- 40: CLI --timeout skips config read ---
@test "config read skipped when CLI timeout is passed" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 99"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234 --timeout 5
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 5m)"* ]]
  if [[ "$stderr" == *"99"* ]]; then echo "stderr unexpectedly contained config value '99'" >&2; return 1; fi
}

# --- 41: invalid poll interval falls back to 30 with warning ---
@test "invalid poll interval falls back to 30 with warning" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_POLL_INTERVAL="abc"
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a non-negative integer"* ]]
}

# --- 42: invalid grace seconds falls back to 300 with warning ---
@test "invalid grace seconds falls back to 300 with warning" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_NO_CHECKS_GRACE_SECONDS="xyz"
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a non-negative integer"* ]]
}

# --- 43: empty required array enters grace path not success ---
@test "empty required array enters grace path not success" {
  _write_fixture required 0 "[]"
  _write_fixture required 1 "[]"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 1 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no CI checks configured"* ]]
  if [[ "$stderr" == *"all CI checks passed"* ]]; then echo "stderr unexpectedly contained 'all CI checks passed'" >&2; return 1; fi
}

# --- 44: non-integer --timeout rejected ---
@test "non-integer --timeout exits 1 with clear error" {
  run --separate-stderr "$CI_WAIT" 1234 --timeout abc
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--timeout must be an integer"* ]]
}

# --- 45: leading-zero --timeout rejected ---
@test "leading zero --timeout like 08 exits 1" {
  run --separate-stderr "$CI_WAIT" 1234 --timeout 08
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--timeout must be an integer"* ]]
}

# --- 46: missing --timeout value rejected ---
@test "missing --timeout value exits 1" {
  run --separate-stderr "$CI_WAIT" 1234 --timeout
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--timeout requires a value"* ]]
}

# --- 47: --timeout over maximum rejected ---
@test "excessive --timeout rejected" {
  run --separate-stderr "$CI_WAIT" 1234 --timeout 1441
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"at most 1440"* ]]
}

# --- 48: "no checks reported" uses distinct wording from "no required checks" ---
@test "no-checks-reported wording is distinct from no-required-checks" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "$_ALL_PASS"
  _write_fixture all 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # The message should say "no checks reported" (not "no required checks configured")
  [[ "$stderr" == *"no checks reported, using all checks"* ]]
}

# --- 49: no config anywhere, grace 0 → exit 1 "no config available" (fail-closed) ---
@test "no config anywhere with grace 0 exits 1 naming missing config" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  # Ensure no config is reachable: GAIA_SHARED_CONFIG unset, PROJECT_ROOT unset,
  # CLAUDE_PROJECT_ROOT unset, walk-up disabled, and no config under PROJECT_PATH
  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT
  export GAIA_NO_PROJECT_WALKUP=1
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no config available"* ]]
  # Must NOT fail open with "no CI checks configured"
  if [[ "$stderr" == *"no CI checks configured"* ]]; then echo "stderr unexpectedly contained 'no CI checks configured' — fail-open mutant alive" >&2; return 1; fi
}

# --- 50: multi-entry promotion chain, base branch main → exit 1 naming plugin-ci ---
@test "multi-entry promotion chain selects correct branch entry" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: staging
      ci_provider: github_actions
    - branch: main
      ci_provider: github_actions
      ci_checks:
        - plugin-ci"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"plugin-ci"* ]]
  [[ "$stderr" == *"expected checks never appeared"* ]]
}

# --- 51: multi-entry chain, baseRefName staging (no ci_checks) → exit 0 ---
@test "multi-entry promotion chain with staging base exits 0 when no ci_checks" {
  _write_fixture required 0 "" 1 "no checks reported on the 'staging' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'staging' branch"
  _write_prview '{"baseRefName":"staging"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: staging
      ci_provider: github_actions
    - branch: main
      ci_provider: github_actions
      ci_checks:
        - plugin-ci"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$stderr" == *"no CI checks configured"* ]]
}

# ===========================================================================
# Bucket-allowlist, validation, and edge-case tests
# ===========================================================================

# Checks with non-terminal buckets must keep polling, not exit early.
# A check whose bucket is queued, missing or null is not done — the script
# must continue until the bucket becomes pass or skipping.
@test "unknown bucket keeps polling instead of passing" {
  local queued='[{"name":"build","bucket":"queued","state":"QUEUED"}]'
  # Poll 0: queued (should keep polling)
  # Poll 1: queued (should keep polling)
  # Poll 2+3: all pass (two-poll rule)
  _write_fixture required 0 "$queued"
  _write_fixture required 1 "$queued"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture required 3 "$_ALL_PASS"
  _write_fixture all 0 "$queued"
  _write_fixture all 1 "$queued"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # Must have polled at least 4 times (2 queued + 2 pass for stability)
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 4 ]
}

@test "missing bucket field keeps polling instead of passing" {
  local no_bucket='[{"name":"build","state":"SUCCESS"}]'
  _write_fixture required 0 "$no_bucket"
  _write_fixture required 1 "$no_bucket"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture required 3 "$_ALL_PASS"
  _write_fixture all 0 "$no_bucket"
  _write_fixture all 1 "$no_bucket"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 4 ]
}

@test "null bucket keeps polling instead of passing" {
  local null_bucket='[{"name":"build","bucket":null,"state":"SUCCESS"}]'
  _write_fixture required 0 "$null_bucket"
  _write_fixture required 1 "$null_bucket"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture required 3 "$_ALL_PASS"
  _write_fixture all 0 "$null_bucket"
  _write_fixture all 1 "$null_bucket"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 4 ]
}

# --- Distinct "no CI configured" wording ---
@test "no-CI-configured exit 0 uses distinct passed line" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$output" == *"no CI"* ]]
}

# --- Walk-up discovers config above the git repo (matches resolve-config.sh) ---
@test "grace walk-up finds config above the git repo" {
  # Config sits ABOVE the git repo. The walk-up must find it (matches the
  # resolver's discovery order, which stops only at $HOME).
  # Canonicalize so macOS /tmp→/private/tmp doesn't cause a vacuous pass.
  local canon_tmp
  canon_tmp="$(cd "$TEST_TMP" && pwd -P)"
  local grandparent="$canon_tmp/walkup-above"
  local repo_root="$grandparent/repo-root"
  local child="$repo_root/sub"
  mkdir -p "$child"
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$repo_root" >/dev/null 2>&1
  git -C "$repo_root" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  # Config above the repo with NO ci_checks — should produce exit 0
  _write_config_at "$grandparent" "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"

  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_NO_PROJECT_WALKUP
  export PROJECT_PATH="$child"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$stderr" == *"no CI checks configured"* ]]
}

# --- Multi-line poll interval / grace seconds rejected ---
@test "multi-line poll interval is rejected" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  CI_WAIT_POLL_INTERVAL="$(printf '5\nevil')"
  export CI_WAIT_POLL_INTERVAL
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a non-negative integer"* ]]
  [[ "$stderr" == *"using default 30"* ]]
}

@test "multi-line grace seconds is rejected" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"

  CI_WAIT_NO_CHECKS_GRACE_SECONDS="$(printf '5\nevil')"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a non-negative integer"* ]]
  [[ "$stderr" == *"using default 300"* ]]
}

# --- Consecutive-error counter reset on no-checks polls ---
@test "error counter resets on successful no-checks poll" {
  # Pattern: 4 consecutive errors, then a no-checks poll (should reset counter),
  # then 4 more errors, then no-checks, then success. Without the reset,
  # the 5th error (poll 5) would hit MAX_CONSECUTIVE_FAILURES and die.
  # With the reset, the no-checks poll at poll 4 resets and we survive.
  # Required: poll 0-3 = error, poll 4 = "no checks reported",
  #           poll 5-8 = error, poll 9 = "no checks reported",
  #           poll 10+11 = all-pass
  local i
  for i in 0 1 2 3; do
    _write_fixture required "$i" "" 1 "internal server error"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  _write_fixture required 4 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 4 "" 1 "no checks reported on the 'main' branch"
  for i in 5 6 7 8; do
    _write_fixture required "$i" "" 1 "internal server error"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  _write_fixture required 9 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 9 "" 1 "no checks reported on the 'main' branch"
  _write_fixture required 10 "$_ALL_PASS"
  _write_fixture required 11 "$_ALL_PASS"
  _write_fixture all 10 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 11 "$_ALL_PASS_WITH_OPT_FAIL"
  # Rebuild the sleep shim with a higher call budget: 4+1+4+1+1 = 11 sleeps
  # needed, so budget of 15 gives headroom
  export CI_WAIT_SLEEP_BUDGET=15
  _install_sleep_shim

  run --separate-stderr "$CI_WAIT" 1234
  # Without the reset fix, this exits 1 at the 5th consecutive error.
  # With the fix, no-checks polls reset the counter and we reach success.
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# --- PR number validation ---
@test "leading-dash PR number is rejected" {
  run --separate-stderr "$CI_WAIT" -- --evil
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PR number"* ]]
}

@test "non-numeric PR number is rejected" {
  run --separate-stderr "$CI_WAIT" abc
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PR number"* ]]
}

@test "zero PR number is rejected" {
  run --separate-stderr "$CI_WAIT" 0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PR number"* ]]
}

@test "negative PR number is rejected" {
  run --separate-stderr "$CI_WAIT" -1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PR number"* ]]
}

# --- Resolver failure prints warning about default timeout ---
@test "resolver failure prints warning about default timeout" {
  export GAIA_SHARED_CONFIG="$TEST_TMP/nonexistent.yaml"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 30m)"* ]]
  [[ "$stderr" == *"no configured timeout found"*"using default"* ]]
}

# --- Invalid-JSON check on --required call retries before falling back ---
@test "invalid JSON on required call retries without falling to all-checks" {
  _write_fixture required 0 "oops"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture all 0 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 2 "$_ALL_PASS_WITH_OPT_FAIL"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"polling error: invalid JSON"* ]]
}

# --- Boundary values ---
@test "config value 1 is accepted" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 1"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 1m)"* ]]
}

@test "config value 360 is accepted" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 360"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 360m)"* ]]
}

@test "CLI timeout 1440 is accepted" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234 --timeout 1440
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 1440m)"* ]]
}

@test "CLI timeout 361 is accepted" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234 --timeout 361
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 361m)"* ]]
}

# --- Config not read when CLI provides timeout ---
@test "out-of-range config ignored when CLI timeout is passed" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 0"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234 --timeout 5
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 5m)"* ]]
  if [[ "$stderr" == *"out of range"* ]]; then echo "FAIL: config was read despite CLI --timeout" >&2; return 1; fi
}

# --- Two failed checks both reported ---
@test "two failed checks both reported by name" {
  _write_fixture required 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"},{"name":"lint","bucket":"fail","state":"FAILURE"}]'
  _write_fixture all 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"},{"name":"lint","bucket":"fail","state":"FAILURE"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bats-tests (fail)"* ]]
  [[ "$stderr" == *"lint (fail)"* ]]
}

# --- Fail exits immediately even with pending checks ---
@test "fail exits immediately even with pending checks" {
  _write_fixture required 0 '[{"name":"build","bucket":"fail","state":"FAILURE"},{"name":"tests","bucket":"pending","state":"IN_PROGRESS"}]'
  _write_fixture all 0 '[{"name":"build","bucket":"fail","state":"FAILURE"},{"name":"tests","bucket":"pending","state":"IN_PROGRESS"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"build (fail)"* ]]
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -eq 1 ]
}

# --- PR number > 6 digits accepted ---
@test "large PR number is accepted" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234567
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# --- Resolver warning absent when config resolves successfully ---
@test "resolver warning absent when config resolves" {
  _write_config "ci_cd:
  ci_wait_timeout_minutes: 5"
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"(timeout: 5m)"* ]]
  if [[ "$stderr" == *"no configured timeout found"* ]]; then echo "FAIL: resolver warning emitted despite valid config" >&2; return 1; fi
}

# --- Error counter reset survives interleaved pending polls ---
@test "error counter resets across interleaved pending polls" {
  # Pattern: 4 errors → pending poll (should reset) → 4 errors → pending →
  # pass. Without the counter reset, the 5th error (poll 5) would die.
  local pending='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
  local i
  for i in 0 1 2 3; do
    _write_fixture required "$i" "" 1 "internal server error"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  _write_fixture required 4 "$pending"
  _write_fixture all 4 "$pending"
  for i in 5 6 7 8; do
    _write_fixture required "$i" "" 1 "internal server error"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  _write_fixture required 9 "$_ALL_PASS"
  _write_fixture required 10 "$_ALL_PASS"
  _write_fixture all 9 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 10 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_SLEEP_BUDGET=15
  _install_sleep_shim

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# --- Grace window resets when checks appear then disappear ---
@test "grace window re-entered when checks disappear again" {
  # no-checks → pending → no-checks: must log "entering grace window" twice.
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  local pending='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
  _write_fixture required 1 "$pending"
  _write_fixture all 1 "$pending"
  _write_fixture required 2 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 2 "" 1 "no checks reported on the 'main' branch"
  _write_fixture required 3 "$_ALL_PASS"
  _write_fixture required 4 "$_ALL_PASS"
  _write_fixture all 3 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 4 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_SLEEP_BUDGET=15
  _install_sleep_shim

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # "entering grace window" must appear twice (first entry + re-entry)
  local grace_count=0
  grace_count=$(printf '%s' "$stderr" | grep -c 'entering grace window') || true
  [ "$grace_count" -ge 2 ]
}

# --- Invalid poll interval actually falls back to sleep 30 ---
@test "invalid poll interval sleeps 30 seconds" {
  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  export CI_WAIT_POLL_INTERVAL="abc"
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # Sleep shim logged its argument: must be "30"
  grep -qx '30' "$TEST_TMP/sleep-args.log"
}

# --- Invalid grace seconds actually falls back to 300 ---
@test "invalid grace seconds defaults to 300 window" {
  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture required 1 "$_ALL_PASS"
  _write_fixture required 2 "$_ALL_PASS"
  _write_fixture all 1 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_NO_CHECKS_GRACE_SECONDS="xyz"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # The grace window message must say 300s
  [[ "$stderr" == *"grace window (300s)"* ]]
}

# --- Pending checks keep polling until budget exhausted ---
@test "pending checks keep polling until killed by budget" {
  # Checks stay pending forever. The sleep-shim budget kills ci-wait after
  # a few polls, proving the script keeps polling (not exiting early).
  local pending='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
  local i
  for i in 0 1 2 3 4 5 6; do
    _write_fixture required "$i" "$pending"
    _write_fixture all "$i" "$pending"
  done

  export CI_WAIT_SLEEP_BUDGET=4
  _install_sleep_shim

  run --separate-stderr "$CI_WAIT" 1234 --timeout 1440
  # Killed by sleep shim: status is non-zero (143/SIGTERM or shim exit 1)
  [ "$status" -ne 0 ]
  # Must have polled multiple times with pending checks
  local pc=0
  pc=$(_count_pr_checks_calls)
  [ "$pc" -ge 3 ]
  # Must have seen "in progress" messages
  [[ "$stderr" == *"in progress"* ]]
}

# --- TMPDIR with spaces does not break cleanup ---
@test "space in TMPDIR cleans up temp files" {
  local spacedir="$TEST_TMP/has space"
  mkdir -p "$spacedir"
  export TMPDIR="$spacedir"

  _write_fixture required 0 "$_ALL_PASS"
  _write_fixture required 1 "$_ALL_PASS"

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  # No ci-wait temp files should remain
  local leftover=0
  leftover=$(find "$spacedir" -name 'ci-wait-*' -type f 2>/dev/null | wc -l)
  [ "$leftover" -eq 0 ]
}

# --- Error counter resets on empty all-checks array ---
@test "error counter resets on empty all-checks array polls" {
  # Like the no-checks-reported counter reset test, but the all-checks call
  # succeeds with an empty array instead of failing with "no checks reported".
  local i
  for i in 0 1 2 3; do
    _write_fixture required "$i" "" 1 "no required checks reported on the 'main' branch"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  # Poll 4: required says no required, all-checks returns empty array (grace path)
  _write_fixture required 4 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture all 4 "[]"
  for i in 5 6 7 8; do
    _write_fixture required "$i" "" 1 "no required checks reported on the 'main' branch"
    _write_fixture all "$i" "" 1 "internal server error"
  done
  _write_fixture required 9 "" 1 "no required checks reported on the 'main' branch"
  _write_fixture all 9 "[]"
  _write_fixture required 10 "$_ALL_PASS"
  _write_fixture required 11 "$_ALL_PASS"
  _write_fixture all 10 "$_ALL_PASS_WITH_OPT_FAIL"
  _write_fixture all 11 "$_ALL_PASS_WITH_OPT_FAIL"

  export CI_WAIT_SLEEP_BUDGET=15
  _install_sleep_shim

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# --- Timeout reached during active polling via seconds override ---
@test "timeout during polling via CI_WAIT_TIMEOUT_SECONDS" {
  # Checks stay pending. The sleep shim really sleeps ~1s per call so that
  # SECONDS (reset to 0 after all setup) advances past the budget after ≥2 polls.
  local pending='[{"name":"build","bucket":"pending","state":"IN_PROGRESS"}]'
  local i
  for i in 0 1 2 3 4 5 6 7 8 9; do
    _write_fixture required "$i" "$pending"
    _write_fixture all "$i" "$pending"
  done

  # Replace the sleep shim with one that really sleeps ~1s but still has a
  # call limit matching the default shim. Without the limit a regression in
  # timeout logic would make this test hang instead of fail fast.
  # Must call /bin/sleep directly to avoid infinite recursion via PATH.
  cat > "$TEST_TMP/bin/sleep" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${TEST_TMP:-/tmp}/sleep-args.log"
count_file="${TEST_TMP:-/tmp}/sleep-count"
if [ ! -f "$count_file" ]; then printf '0' > "$count_file"; fi
n=$(cat "$count_file")
n=$((n + 1))
printf '%s' "$n" > "$count_file"
if [ "$n" -gt 10 ]; then
  kill -TERM $PPID 2>/dev/null || true
  exit 1
fi
/bin/sleep 1
exit 0
SHIMEOF
  chmod +x "$TEST_TMP/bin/sleep"

  # Budget of 5 s gives margin: SECONDS=0 is reset after setup, so each
  # poll+sleep iteration consumes ~1 s of wall clock.
  export CI_WAIT_TIMEOUT_SECONDS=5

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"timed out"* ]]
  # The timeout message must report the seconds budget, not minutes
  [[ "$stderr" == *"5 seconds"* ]]
  # Must have polled at least twice before the timeout fired
  local pc=0
  pc=$(_count_pr_checks_calls)
  [ "$pc" -ge 2 ]
}

# --- GAIA_NO_PROJECT_WALKUP skips the grace walk-up ---
@test "GAIA_NO_PROJECT_WALKUP prevents grace walk-up" {
  local canon_tmp
  canon_tmp="$(cd "$TEST_TMP" && pwd -P)"
  local grandparent="$canon_tmp/walkup-blocked"
  local repo_root="$grandparent/repo-root"
  local child="$repo_root/sub"
  mkdir -p "$child"
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$repo_root" >/dev/null 2>&1
  git -C "$repo_root" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  _write_config_at "$grandparent" "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"

  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT
  export GAIA_NO_PROJECT_WALKUP=1
  export PROJECT_PATH="$child"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no config available"* ]]
}

# --- CLAUDE_SKILL_DIR skips the grace walk-up ---
@test "CLAUDE_SKILL_DIR prevents grace walk-up" {
  local canon_tmp
  canon_tmp="$(cd "$TEST_TMP" && pwd -P)"
  local grandparent="$canon_tmp/walkup-skill"
  local repo_root="$grandparent/repo-root"
  local child="$repo_root/sub"
  mkdir -p "$child"
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$repo_root" >/dev/null 2>&1
  git -C "$repo_root" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  _write_config_at "$grandparent" "ci_cd:
  promotion_chain:
    - branch: main
      ci_provider: github_actions"

  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_NO_PROJECT_WALKUP
  export CLAUDE_SKILL_DIR="$TEST_TMP/fake-skill"
  export PROJECT_PATH="$child"
  export CI_WAIT_NO_CHECKS_GRACE_SECONDS=0

  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no config available"* ]]
}

# --- CI_WAIT_TIMEOUT_SECONDS rejection: non-integer ---
@test "CI_WAIT_TIMEOUT_SECONDS rejects non-integer value" {
  export CI_WAIT_TIMEOUT_SECONDS="abc"
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"CI_WAIT_TIMEOUT_SECONDS"* ]]
  [[ "$stderr" == *"non-negative integer"* ]]
}

# --- CI_WAIT_TIMEOUT_SECONDS rejection: over-cap ---
@test "CI_WAIT_TIMEOUT_SECONDS rejects value above 86400" {
  export CI_WAIT_TIMEOUT_SECONDS=86401
  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"CI_WAIT_TIMEOUT_SECONDS"* ]]
  [[ "$stderr" == *"86400"* ]]
}

# --- Leading-zero PR number rejected ---
@test "leading-zero PR number is rejected" {
  run --separate-stderr "$CI_WAIT" 01234
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PR number"* ]]
}
