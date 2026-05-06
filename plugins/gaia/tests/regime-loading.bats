#!/usr/bin/env bats
# regime-loading.bats — regime-aware pattern loading for security/pii-detector.sh (E67-S5)
# Covers AC4 and the GDPR rubric reference (rubrics/regimes/gdpr.json).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/security/pii-detector.sh"
  GDPR_RUBRIC="$(cd "$BATS_TEST_DIRNAME/../rubrics/regimes" && pwd)/gdpr.json"
}
teardown() { common_teardown; }

mkfile() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

@test "TC-RSV2-PRIVACY-1.26: GDPR rubric file exists and contains privacy section" {
  [ -f "$GDPR_RUBRIC" ]
  grep -F '"privacy"' "$GDPR_RUBRIC" >/dev/null
  grep -F '"patterns"' "$GDPR_RUBRIC" >/dev/null
}

@test "TC-RSV2-PRIVACY-1.27: regime declared via env -> IBAN active" {
  local f="$TEST_TMP/src/iban.ts"
  mkfile "$f" 'const iban = "DE89370400440532013000";'
  GAIA_COMPLIANCE_REGIMES="gdpr" run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"rule":"iban"' >/dev/null
}

@test "TC-RSV2-PRIVACY-1.28: no regime declared -> IBAN not active" {
  local f="$TEST_TMP/src/iban.ts"
  mkfile "$f" 'const iban = "DE89370400440532013000";'
  unset GAIA_COMPLIANCE_REGIMES
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"iban"' >/dev/null
}

@test "TC-RSV2-PRIVACY-1.29: regime is additive — base patterns still run with regime" {
  local f="$TEST_TMP/src/multi.ts"
  mkfile "$f" 'const e = "alice@example.com"; const i = "DE89370400440532013000";'
  GAIA_COMPLIANCE_REGIMES="gdpr" run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"rule":"email"' >/dev/null
  printf '%s\n' "$output" | grep -F '"rule":"iban"' >/dev/null
}

@test "TC-RSV2-PRIVACY-1.30: graceful degrade — missing rubric file does not fail script" {
  local f="$TEST_TMP/src/clean.ts"
  mkfile "$f" 'const x = 1;'
  GAIA_COMPLIANCE_REGIMES="nonexistent-regime" run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"name":"pii-detector"' >/dev/null
}
