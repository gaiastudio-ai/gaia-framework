#!/usr/bin/env bats
# tag-conformance-detector.bats — unit tests for plugins/gaia/scripts/review-common/tag-conformance-detector.sh (E67-S1)
# Covers AC4, AC6, AC7 and TC-RSV2-TESTREVIEW-4.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/tag-conformance-detector.sh"
}
teardown() { common_teardown; }

assert_json_check_status() {
  printf '%s\n' "$1" | grep -F "\"status\":\"$2\"" >/dev/null
}
assert_json_finding_rule() {
  printf '%s\n' "$1" | grep -F "\"rule\":\"$2\"" >/dev/null
}

# --- ts-dev (Vitest/Jest) ---

@test "TC-RSV2-TESTREVIEW-4.1: ts-dev untagged it() flagged as missing-tag" {
  local f="$TEST_TMP/no.test.ts"
  printf 'it("works", () => { expect(1).toBe(1); });\n' > "$f"
  run "$SCRIPT" --stack ts-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
}

@test "TC-RSV2-TESTREVIEW-4.2: ts-dev describe.each test passes" {
  local f="$TEST_TMP/yes.test.ts"
  printf 'describe.each([[1],[2]])("w %%i", (x) => { it("does", () => expect(x).toBe(x)); });\n' > "$f"
  run "$SCRIPT" --stack ts-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- java-dev (JUnit) ---

@test "TC-RSV2-TESTREVIEW-4.3: java-dev untagged @Test flagged" {
  local f="$TEST_TMP/PlainTest.java"
  printf 'public class PlainTest { @Test void foo() {} }\n' > "$f"
  run "$SCRIPT" --stack java-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
}

@test "TC-RSV2-TESTREVIEW-4.4: java-dev @Tag annotation passes" {
  local f="$TEST_TMP/TaggedTest.java"
  printf '@Tag("slow")\npublic class TaggedTest { @Test void foo() {} }\n' > "$f"
  run "$SCRIPT" --stack java-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- python-dev (pytest) ---

@test "TC-RSV2-TESTREVIEW-4.5: python-dev untagged def test_ flagged" {
  local f="$TEST_TMP/test_x.py"
  printf 'def test_a():\n    assert True\n' > "$f"
  run "$SCRIPT" --stack python-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
}

@test "TC-RSV2-TESTREVIEW-4.6: python-dev @pytest.mark.<name> passes" {
  local f="$TEST_TMP/test_y.py"
  printf 'import pytest\n@pytest.mark.smoke\ndef test_a():\n    assert True\n' > "$f"
  run "$SCRIPT" --stack python-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- go-dev (build tags) ---

@test "TC-RSV2-TESTREVIEW-4.7: go-dev test without //go:build flagged" {
  local f="$TEST_TMP/foo_test.go"
  printf 'package foo\nimport "testing"\nfunc TestA(t *testing.T) {}\n' > "$f"
  run "$SCRIPT" --stack go-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
}

@test "TC-RSV2-TESTREVIEW-4.8: go-dev test with //go:build passes" {
  local f="$TEST_TMP/bar_test.go"
  printf '//go:build integration\n\npackage foo\nimport "testing"\nfunc TestA(t *testing.T) {}\n' > "$f"
  run "$SCRIPT" --stack go-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- mobile-dev (Maestro front-matter) ---

@test "TC-RSV2-TESTREVIEW-4.9: mobile-dev Maestro flow without tags: flagged" {
  local f="$TEST_TMP/flow_no.yaml"
  printf 'appId: com.example\n---\n- launchApp\n' > "$f"
  run "$SCRIPT" --stack mobile-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
}

@test "TC-RSV2-TESTREVIEW-4.10: mobile-dev Maestro flow with tags: passes" {
  local f="$TEST_TMP/flow_yes.yaml"
  printf 'appId: com.example\ntags:\n  - smoke\n---\n- launchApp\n' > "$f"
  run "$SCRIPT" --stack mobile-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

# --- error / arg parsing ---

@test "TC-RSV2-TESTREVIEW-4.11: missing --stack exits 1" {
  run "$SCRIPT" "$TEST_TMP"
  [ "$status" -eq 1 ]
}

@test "TC-RSV2-TESTREVIEW-4.12: unknown stack exits 1" {
  run "$SCRIPT" --stack foo-dev "$TEST_TMP"
  [ "$status" -eq 1 ]
}

@test "TC-RSV2-TESTREVIEW-4.13: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "TC-RSV2-TESTREVIEW-4.14: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}
