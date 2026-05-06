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

@test "TC-RSV2-TESTREVIEW-4.11: missing --stack auto-detects per file (E72-S4 AC9)" {
  # E72-S4 AC9: when --stack is omitted, auto-detect stack per-file by
  # extension. A bare invocation against a directory of mixed test files
  # therefore succeeds (exit 0) — not the legacy E67-S1 exit 1 behavior.
  local f="$TEST_TMP/foo.test.ts"
  printf 'it("works", () => { expect(1).toBe(1); });\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "missing-tag"
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

# --- E72-S4 additions: strict mode, --files glob, multi-stack auto-detect ---

assert_json_finding_severity() {
  printf '%s\n' "$1" | grep -F "\"severity\":\"$2\"" >/dev/null
}

@test "TC-RSV2-TESTREVIEW-4.15: --strict flag emits warning severity (E72-S4 AC7)" {
  local f="$TEST_TMP/strict.test.ts"
  printf 'it("a", () => {});\n' > "$f"
  run "$SCRIPT" --stack ts-dev --strict "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_severity "$output" "warning"
}

@test "TC-RSV2-TESTREVIEW-4.16: non-strict emits info (Suggestion) severity (E72-S4 AC6)" {
  local f="$TEST_TMP/lax.test.ts"
  printf 'it("a", () => {});\n' > "$f"
  run "$SCRIPT" --stack ts-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  # Default mode is non-strict — severity drops to info per AC6.
  assert_json_finding_severity "$output" "info"
}

@test "TC-RSV2-TESTREVIEW-4.17: --files glob expands and scans matching files (E72-S4 AC10)" {
  mkdir -p "$TEST_TMP/sub"
  printf 'it("a", () => {});\n' > "$TEST_TMP/sub/a.test.ts"
  printf 'it("b", () => {});\n' > "$TEST_TMP/sub/b.test.ts"
  run "$SCRIPT" --stack ts-dev --strict --files "$TEST_TMP/sub/*.test.ts"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  # Both files should appear in findings.
  printf '%s\n' "$output" | grep -F 'a.test.ts' >/dev/null
  printf '%s\n' "$output" | grep -F 'b.test.ts' >/dev/null
}

@test "TC-RSV2-TESTREVIEW-4.18: multi-stack auto-detect routes per file extension (E72-S4 AC9)" {
  # Mixed monorepo: a Vitest file (untagged → flagged) and a pytest file
  # WITH a @pytest.mark decorator (NOT flagged). Verify the auto-detect
  # path applies the right detector to each file.
  mkdir -p "$TEST_TMP/js" "$TEST_TMP/py"
  printf 'it("a", () => {});\n' > "$TEST_TMP/js/a.test.ts"
  printf 'import pytest\n@pytest.mark.unit\ndef test_a(): assert True\n' > "$TEST_TMP/py/test_a.py"
  run "$SCRIPT" --strict "$TEST_TMP/js/a.test.ts" "$TEST_TMP/py/test_a.py"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  printf '%s\n' "$output" | grep -F 'a.test.ts' >/dev/null
  # The pytest file must NOT appear in findings.
  if printf '%s\n' "$output" | grep -F 'test_a.py' >/dev/null; then
    printf 'pytest file should not be flagged when @pytest.mark present\n' >&2
    return 1
  fi
}

@test "TC-RSV2-TESTREVIEW-4.19: GAIA_TEST_TAGGING_STRICT=1 env upgrades severity to warning (E72-S4 AC7)" {
  local f="$TEST_TMP/envstrict.test.ts"
  printf 'it("a", () => {});\n' > "$f"
  GAIA_TEST_TAGGING_STRICT=1 run "$SCRIPT" --stack ts-dev "$f"
  [ "$status" -eq 0 ]
  assert_json_finding_severity "$output" "warning"
}

@test "TC-RSV2-TESTREVIEW-4.20: --files combined with --strict produces JSON-valid output (E72-S4 AC8, AC10)" {
  mkdir -p "$TEST_TMP/m"
  printf 'it("a", () => {});\n' > "$TEST_TMP/m/x.test.ts"
  run "$SCRIPT" --stack ts-dev --strict --files "$TEST_TMP/m/*.test.ts"
  [ "$status" -eq 0 ]
  # Output must contain canonical Phase 3A check-fragment keys.
  printf '%s\n' "$output" | grep -F '"name":"tag-conformance-detector"' >/dev/null
  printf '%s\n' "$output" | grep -F '"findings":[' >/dev/null
  printf '%s\n' "$output" | grep -F '"file":' >/dev/null
  printf '%s\n' "$output" | grep -F '"line":' >/dev/null
  printf '%s\n' "$output" | grep -F '"severity":' >/dev/null
  printf '%s\n' "$output" | grep -F '"rule":' >/dev/null
  printf '%s\n' "$output" | grep -F '"message":' >/dev/null
}
