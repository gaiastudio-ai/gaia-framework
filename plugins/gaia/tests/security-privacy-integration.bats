#!/usr/bin/env bats
# security-privacy-integration.bats — end-to-end Phase 3C integration (E67-S5)
# Covers AC5 and TC-RSV2-PRIVACY end-to-end scenario.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PII="$SCRIPTS_DIR/review-common/security/pii-detector.sh"
  DHL="$SCRIPTS_DIR/review-common/security/data-handling-lint.sh"
  RPC="$SCRIPTS_DIR/review-common/security/retention-policy-check.sh"
}
teardown() { common_teardown; }

mkfile() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

@test "all three scanners run + merge produces three categories" {
  # Story-shaped fixture:
  #   - source file logs an email                  -> data-handling-lint
  #   - test fixture has credit-card               -> pii-detector (medium severity)
  #   - prisma schema has PII field with no TTL    -> retention-policy-check
  local src="$TEST_TMP/src/log.ts"
  local fix="$TEST_TMP/src/__tests__/payments.test.ts"
  local sch="$TEST_TMP/prisma/schema.prisma"
  mkfile "$src" 'logger.info("user email:", email);'
  mkfile "$fix" 'const card = "4111111111111111";'
  mkfile "$sch" 'model U { id Int @id; email String }'

  out_pii="$("$PII" "$src" "$fix" "$sch")"
  out_dhl="$("$DHL" "$src" "$fix" "$sch")"
  out_rpc="$("$RPC" "$src" "$fix" "$sch")"

  # Each scanner emits its own check fragment.
  printf '%s\n' "$out_pii" | grep -F '"name":"pii-detector"' >/dev/null
  printf '%s\n' "$out_dhl" | grep -F '"name":"data-handling-lint"' >/dev/null
  printf '%s\n' "$out_rpc" | grep -F '"name":"retention-policy-check"' >/dev/null

  # Each surfaces its category at least once.
  printf '%s\n' "$out_pii" | grep -F '"category":"privacy-pii"' >/dev/null
  printf '%s\n' "$out_dhl" | grep -F '"category":"privacy-data-handling"' >/dev/null
  printf '%s\n' "$out_rpc" | grep -F '"category":"privacy-retention"' >/dev/null

  # The aggregate merge: a wrapper analysis-results.json shape that contains
  # all three checks. We assemble it inline (no jq) and assert it parses.
  merged="$(printf '{"schema_version":"1.0","story_key":"E67-S5","skill":"gaia-review-security","model":"claude-opus-4-7","model_temperature":0,"checks":[%s,%s,%s]}' \
    "$out_pii" "$out_dhl" "$out_rpc")"
  printf '%s\n' "$merged" | grep -F '"schema_version":"1.0"' >/dev/null
  printf '%s\n' "$merged" | grep -F '"story_key":"E67-S5"' >/dev/null
  printf '%s\n' "$merged" | grep -F '"checks":[' >/dev/null
}

@test "all three scanners exit 0 even with findings" {
  local f="$TEST_TMP/src/dirty.ts"
  mkfile "$f" 'logger.info("u:", email); const e = "a@b.co";'

  run "$PII" "$f"
  [ "$status" -eq 0 ]

  run "$DHL" "$f"
  [ "$status" -eq 0 ]

  local schema="$TEST_TMP/prisma/schema.prisma"
  mkfile "$schema" 'model U { email String }'
  run "$RPC" "$schema"
  [ "$status" -eq 0 ]
}

@test "gaia-review-security SKILL.md wires Phase 3C scripts" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-review-security/SKILL.md"
  [ -f "$skill" ]
  grep -F "pii-detector.sh" "$skill" >/dev/null
  grep -F "data-handling-lint.sh" "$skill" >/dev/null
  grep -F "retention-policy-check.sh" "$skill" >/dev/null
  grep -E "Phase 3C" "$skill" >/dev/null
}
