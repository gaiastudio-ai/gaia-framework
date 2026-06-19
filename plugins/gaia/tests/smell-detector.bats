#!/usr/bin/env bats
# smell-detector.bats — unit tests for plugins/gaia/scripts/review-common/smell-detector.sh (E67-S1)
# Covers AC1, AC6, AC7 and TC-RSV2-TESTREVIEW-1.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/smell-detector.sh"
}
teardown() { common_teardown; }

# --- helpers ---

mkfile() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

assert_json_check_status() {
  # assert_json_check_status <output> <expected>
  printf '%s\n' "$1" | grep -F "\"status\":\"$2\"" >/dev/null
}

assert_json_finding_rule() {
  # assert_json_finding_rule <output> <rule>
  printf '%s\n' "$1" | grep -F "\"rule\":\"$2\"" >/dev/null
}

assert_json_finding_category() {
  # assert_json_finding_category <output> <category>
  printf '%s\n' "$1" | grep -F "\"category\":\"$2\"" >/dev/null
}

# --- happy-path detection ---

@test ".1: test-name-says-too-much detected" {
  local f="$TEST_TMP/too-much.test.ts"
  mkfile "$f" 'it("should call API and return 200 and parse JSON and set state", () => { expect(1).toBe(1); });'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "test-name-says-too-much"
  assert_json_finding_category "$output" "test-quality"
}

@test ".2: mystery-guest detected (fixture path no setup)" {
  local f="$TEST_TMP/mystery.test.ts"
  mkfile "$f" 'it("uses fixture", () => { const path = "../../fixtures/users.json"; expect(true).toBe(true); });'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "mystery-guest"
}

@test ".3: conditional-assertion detected" {
  local f="$TEST_TMP/cond.test.ts"
  printf 'it("c", () => {\n  if (env === "ci") {\n    expect(x).toBe(1);\n  }\n});\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "conditional-assertion"
}

@test ".4: clean test file produces empty findings + status passed" {
  local f="$TEST_TMP/clean.test.ts"
  mkfile "$f" 'it("clean", () => { expect(1).toBe(1); });'
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
  printf '%s\n' "$output" | grep -F '"findings":[]' >/dev/null
}

# --- mystery-guest negative case (require/import present -> not flagged) ---

@test ".5: mystery-guest NOT flagged when require is present" {
  local f="$TEST_TMP/with-setup.test.ts"
  printf 'const data = require("./fixtures/users.json");\nit("c", () => { const p = "../fixtures/x.json"; expect(true).toBe(true); });\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- conditional-assertion exclusion: parameterized patterns ---

@test ".6: parameterized it.each does not trigger conditional-assertion" {
  local f="$TEST_TMP/param.test.ts"
  printf 'it.each([[1],[2]])("works %%i", (x) => {\n  expect(x).toBe(x);\n});\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  # Either no finding at all, or no conditional-assertion finding.
  ! printf '%s\n' "$output" | grep -F '"rule":"conditional-assertion"' >/dev/null
}

# --- python def test_..._and_..._and_... ---

@test ".7: python def test_x_and_y_and_z flagged" {
  local f="$TEST_TMP/test_long.py"
  printf 'def test_call_api_and_check_and_persist(self):\n    assert True\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_finding_rule "$output" "test-name-says-too-much"
}

# --- POSIX / shell discipline ---

@test ".8: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test ".9: script does not invoke jq as a runtime command" {
  # Only forbid invocations like `jq ...` or `| jq ...` outside comment lines.
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test ".10: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F "Usage:" >/dev/null
}

@test ".11: unknown flag exits 1" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
}

# --- directory walking ---

@test ".12: directory input walks test files" {
  mkdir -p "$TEST_TMP/dir/sub"
  mkfile "$TEST_TMP/dir/sub/a.test.ts" 'it("clean", () => { expect(1).toBe(1); });'
  mkfile "$TEST_TMP/dir/sub/b.test.ts" 'it("a and b and c", () => { expect(1).toBe(1); });'
  run "$SCRIPT" "$TEST_TMP/dir"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "test-name-says-too-much"
}
