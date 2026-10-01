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
  grep -c -- '--required' "$TEST_TMP/gh-calls.log" 2>/dev/null || printf '0'
}

# _count_pr_checks_calls — count 'pr checks' appearances in gh call log
_count_pr_checks_calls() {
  grep -c 'pr checks' "$TEST_TMP/gh-calls.log" 2>/dev/null || printf '0'
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

  # Init call log and counter
  : > "$TEST_TMP/gh-calls.log"
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
  local rc
  rc=$(_count_required_calls)
  [ "$rc" -ge 2 ]
}

# --- 3: failed check names the specific check and its bucket ---
@test "failed check names the check and bucket" {
  _write_fixture required 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"}]'
  _write_fixture all 0 '[{"name":"bats-tests","bucket":"fail","state":"FAILURE"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"bats-tests (fail)"* ]]
  grep -q -- '--required' "$TEST_TMP/gh-calls.log"
}

# --- 4: cancelled check reported with name and cancel bucket ---
@test "cancelled check reports failure with name" {
  _write_fixture required 0 '[{"name":"deploy","bucket":"cancel","state":"CANCELLED"}]'
  _write_fixture all 0 '[{"name":"deploy","bucket":"cancel","state":"CANCELLED"}]'

  run --separate-stderr "$CI_WAIT" 1234
  [ "$status" -ne 0 ]
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

# --- 28: config discovered by walk-up from PWD ---
@test "config found by walk-up from working directory" {
  # Build a nested repo: parent has config, child is the git repo
  local parent="$TEST_TMP/walkup-parent"
  local child="$parent/child"
  mkdir -p "$child"
  git -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    init "$child" >/dev/null 2>&1
  git -C "$child" -c user.email=t@e -c user.name=t -c commit.gpgsign=false \
    commit --allow-empty -m init >/dev/null 2>&1
  _write_config_at "$parent" "ci_cd:
  ci_wait_timeout_minutes: 3"

  # Unset everything so only walk-up can find config
  unset GAIA_SHARED_CONFIG PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_NO_PROJECT_WALKUP
  export PROJECT_PATH="$child"

  _write_fixture required 0 "" 1 "no checks reported on the 'main' branch"
  _write_fixture all 0 "" 1 "no checks reported on the 'main' branch"
  _write_prview '{"baseRefName":"main"}'
  _write_config_at "$parent" "ci_cd:
  ci_wait_timeout_minutes: 3
  promotion_chain:
    - branch: main
      ci_provider: github_actions"
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
  [[ "$stderr" == *"grace expired"* ]] || [[ "$stderr" == *"no CI checks configured"* ]]
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
