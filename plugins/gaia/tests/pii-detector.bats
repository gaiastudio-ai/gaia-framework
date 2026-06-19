#!/usr/bin/env bats
# pii-detector.bats — unit tests for plugins/gaia/scripts/review-common/security/pii-detector.sh (E67-S5)
# Covers AC1, AC4, AC6, AC7, AC8 and TC-RSV2-PRIVACY-1.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/security/pii-detector.sh"
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

# --- AC1 happy path: each PII type ---

@test ".1: email pattern detected" {
  local f="$TEST_TMP/src/user.ts"
  mkfile "$f" 'const email = "alice@example.com";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "failed"
  assert_rule "$output" "email"
  assert_category "$output" "privacy-pii"
}

@test ".2: SSN pattern detected" {
  local f="$TEST_TMP/src/user.ts"
  mkfile "$f" 'const ssn = "123-45-6789";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "failed"
  assert_rule "$output" "ssn"
}

@test ".3: credit-card pattern detected (Luhn-plausible)" {
  local f="$TEST_TMP/src/pay.ts"
  # 4111111111111111 is the canonical Luhn-valid Visa test number
  mkfile "$f" 'const card = "4111111111111111";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "failed"
  assert_rule "$output" "credit-card"
}

@test ".4: phone-number pattern detected (E.164)" {
  local f="$TEST_TMP/src/user.ts"
  mkfile "$f" 'const phone = "+14155551234";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "phone"
}

@test ".5: IPv4 literal detected" {
  local f="$TEST_TMP/src/net.ts"
  mkfile "$f" 'const host = "192.168.1.42";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "ip-address"
}

# --- AC8 severity differentiation ---

@test ".6: source file PII -> Critical severity" {
  local f="$TEST_TMP/src/user.ts"
  mkfile "$f" 'const email = "alice@example.com";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_severity "$output" "critical"
}

@test ".7: test file PII -> Medium severity" {
  local f="$TEST_TMP/src/__tests__/user.test.ts"
  mkfile "$f" 'const email = "alice@example.com";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_severity "$output" "medium"
}

@test ".8: .spec file PII -> Medium severity" {
  local f="$TEST_TMP/src/user.spec.ts"
  mkfile "$f" 'const email = "alice@example.com";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_severity "$output" "medium"
}

# --- AC1 clean pass ---

@test ".9: clean source file -> status passed" {
  local f="$TEST_TMP/src/clean.ts"
  mkfile "$f" 'const x = 1; const y = "hello";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "passed"
  printf '%s\n' "$output" | grep -F '"findings":[]' >/dev/null
}

# --- AC6 POSIX discipline ---

@test ".10: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test ".11: script does not invoke jq" {
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test ".12: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "Usage:" >/dev/null
}

# --- AC4 regime-aware loading ---

@test ".13: GDPR regime loads IBAN pattern" {
  local f="$TEST_TMP/src/iban.ts"
  mkfile "$f" 'const iban = "DE89370400440532013000";'
  # Without regime: no IBAN finding
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"iban"' >/dev/null
  # With regime declared: IBAN finding present
  GAIA_COMPLIANCE_REGIMES="gdpr" run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "iban"
}

@test ".14: graceful degradation when resolve-config.sh unavailable" {
  local f="$TEST_TMP/src/clean.ts"
  mkfile "$f" 'const x = 1;'
  # PATH stripped + GAIA_RESOLVE_CONFIG=/nonexistent -> base patterns only, exit 0
  GAIA_RESOLVE_CONFIG="/nonexistent" run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "passed"
}

# --- AC7 schema-shape sanity ---

@test ".15: output emits required check fields" {
  local f="$TEST_TMP/src/user.ts"
  mkfile "$f" 'const email = "a@b.co";'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"name":"pii-detector"' >/dev/null
  printf '%s\n' "$output" | grep -F '"scope":' >/dev/null
  printf '%s\n' "$output" | grep -F '"findings":[' >/dev/null
}
