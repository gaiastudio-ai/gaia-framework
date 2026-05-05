#!/usr/bin/env bats
# retention-policy-check.bats — unit tests for plugins/gaia/scripts/review-common/security/retention-policy-check.sh (E67-S5)
# Covers AC3, AC6, AC7, AC8 and TC-RSV2-PRIVACY-2.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/security/retention-policy-check.sh"
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

assert_severity() {
  printf '%s\n' "$1" | grep -F "\"severity\":\"$2\"" >/dev/null
}

# --- AC3 happy path: PII field without TTL ---

@test "TC-RSV2-PRIVACY-2.1: Prisma PII field without TTL flagged" {
  local f="$TEST_TMP/prisma/schema.prisma"
  mkfile "$f" 'model User {
  id    Int    @id
  email String
  name  String
}'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "failed"
  assert_rule "$output" "pii-field-no-ttl"
}

@test "TC-RSV2-PRIVACY-2.2: SQLAlchemy/Django PII column without expiry flagged" {
  local f="$TEST_TMP/models/user.py"
  mkfile "$f" 'class User(Model):
    email = CharField(max_length=255)
    phone = CharField(max_length=32)
'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "pii-field-no-ttl"
}

# --- AC3 session/token store ---

@test "TC-RSV2-PRIVACY-2.3: Redis session config missing TTL flagged" {
  local f="$TEST_TMP/config/session.json"
  mkfile "$f" '{
  "store": "redis",
  "host": "localhost",
  "session": true
}'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "session-no-ttl"
}

# --- AC3 retention threshold ---

@test "TC-RSV2-PRIVACY-2.4: --max-retention-days flag overrides default" {
  local f="$TEST_TMP/config/retention.yaml"
  mkfile "$f" 'retention:
  default_days: 90
  email: 90
'
  run "$SCRIPT" --max-retention-days 30 "$f"
  [ "$status" -eq 0 ]
  assert_rule "$output" "retention-exceeds-threshold"
}

@test "TC-RSV2-PRIVACY-2.5: default threshold (365) does not flag short retention" {
  local f="$TEST_TMP/config/retention.yaml"
  mkfile "$f" 'retention:
  default_days: 90
'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"retention-exceeds-threshold"' >/dev/null
}

# --- AC3 clean pass ---

@test "TC-RSV2-PRIVACY-2.6: PII field with @ttl annotation -> not flagged" {
  local f="$TEST_TMP/prisma/schema.prisma"
  mkfile "$f" 'model User {
  id    Int    @id
  email String @ttl(days: 30)
}'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"pii-field-no-ttl"' >/dev/null
}

@test "TC-RSV2-PRIVACY-2.7: clean config -> status passed" {
  local f="$TEST_TMP/config/non-pii.json"
  mkfile "$f" '{"feature":"enabled","limit":100}'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_status "$output" "passed"
}

# --- AC8 severity ---

@test "TC-RSV2-PRIVACY-2.8: retention findings -> Medium severity" {
  local f="$TEST_TMP/prisma/schema.prisma"
  mkfile "$f" 'model U { email String }'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_severity "$output" "medium"
}

# --- AC6 POSIX discipline ---

@test "TC-RSV2-PRIVACY-2.9: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test "TC-RSV2-PRIVACY-2.10: script does not invoke jq" {
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test "TC-RSV2-PRIVACY-2.11: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "Usage:" >/dev/null
}

# --- AC7 schema-shape ---

@test "TC-RSV2-PRIVACY-2.12: output emits required check fields" {
  local f="$TEST_TMP/prisma/schema.prisma"
  mkfile "$f" 'model U { email String }'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F '"name":"retention-policy-check"' >/dev/null
  printf '%s\n' "$output" | grep -F '"findings":[' >/dev/null
}
