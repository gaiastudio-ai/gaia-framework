#!/usr/bin/env bats
# data-handling-lint.bats — unit tests for plugins/gaia/scripts/review-common/security/data-handling-lint.sh (E67-S5)
# Covers AC2, AC6, AC7, AC8 and TC-RSV2-PRIVACY-1.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/security/data-handling-lint.sh"
}
teardown() { common_teardown; }

mkfile() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

assert_status() {
  printf '%s\n' "$1" | grep -F "\"status\":\"$2\"" >/dev/null
}

assert_rule() {
  printf '%s\n' "$1" | grep -F "\"rule\":\"$2\"" >/dev/null
}

assert_category() {
  printf '%s\n' "$1" | grep -F "\"category\":\"$2\"" >/dev/null
}

assert_severity() {
  printf '%s\n' "$1" | grep -F "\"severity\":\"$2\"" >/dev/null
}

# --- AC2 happy path ---

@test ".16: logging-pii detected (console.log + email)" {
  local f="$TEST_TMP/src/log.ts"
  mkfile "$f" 'console.log("User email:", email);'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "failed"
  assert_rule "$output" "logging-pii"
  assert_category "$output" "privacy-data-handling"
}

@test ".17: pii-in-url detected (query string with email)" {
  local f="$TEST_TMP/src/api.ts"
  mkfile "$f" 'fetch(`/api/lookup?email=${userEmail}`);'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "pii-in-url"
}

@test ".18: unmasked-pii-error detected" {
  local f="$TEST_TMP/src/err.ts"
  mkfile "$f" 'throw new Error(`Invalid email: ${email}`);'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "unmasked-pii-error"
}

@test ".19: pii-in-analytics detected" {
  local f="$TEST_TMP/src/track.ts"
  mkfile "$f" 'analytics.track("user", { email: email });'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "pii-in-analytics"
}

# --- AC8 severity ---

@test ".20: data-handling-lint findings -> High severity" {
  local f="$TEST_TMP/src/log.ts"
  mkfile "$f" 'logger.info("user:", email);'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_severity "$output" "high"
}

# --- AC2 clean pass ---

@test ".21: clean file -> status passed" {
  local f="$TEST_TMP/src/clean.ts"
  mkfile "$f" 'console.log("system started");'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "passed"
  printf '%s\n' "$output" | grep -F '"findings":[]' >/dev/null
}

# --- AC6 POSIX discipline ---

@test ".22: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test ".23: script does not invoke jq" {
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test ".24: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "Usage:" >/dev/null
}

# --- AC7 schema-shape sanity ---

@test ".25: output emits required check fields" {
  local f="$TEST_TMP/src/log.ts"
  mkfile "$f" 'logger.info("u:", email);'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"name":"data-handling-lint"' >/dev/null
  printf '%s\n' "$output" | grep -F '"findings":[' >/dev/null
}
