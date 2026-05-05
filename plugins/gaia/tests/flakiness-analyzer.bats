#!/usr/bin/env bats
# flakiness-analyzer.bats — unit tests for plugins/gaia/scripts/review-common/flakiness-analyzer.sh (E67-S1)
# Covers AC2, AC6, AC7 and TC-RSV2-TESTREVIEW-2.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/flakiness-analyzer.sh"
}
teardown() { common_teardown; }

assert_json_check_status() {
  printf '%s\n' "$1" | grep -F "\"status\":\"$2\"" >/dev/null
}
assert_json_finding_rule() {
  printf '%s\n' "$1" | grep -F "\"rule\":\"$2\"" >/dev/null
}
assert_json_finding_category() {
  printf '%s\n' "$1" | grep -F "\"category\":\"$2\"" >/dev/null
}

@test "TC-RSV2-TESTREVIEW-2.1: retry-heuristic detected (.retry / retries:)" {
  local f="$TEST_TMP/r.test.ts"
  printf 'it("flaky", { retries: 3 }, () => { expect(1).toBe(1); });\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "retry-heuristic"
  assert_json_finding_category "$output" "flakiness"
}

@test "TC-RSV2-TESTREVIEW-2.2: time-dependent assertion detected" {
  local f="$TEST_TMP/t.test.ts"
  printf 'it("times", () => {\n  const start = Date.now();\n  doWork();\n  expect(Date.now() - start).toBeLessThan(100);\n});\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "time-dependent-assertion"
}

@test "TC-RSV2-TESTREVIEW-2.3: shared-state mutation in beforeAll without teardown" {
  local f="$TEST_TMP/s.test.ts"
  cat > "$f" <<'EOF'
let userStore = [];
beforeAll(() => {
  userStore.push({ id: 1 });
});
it("uses store", () => {
  expect(userStore.length).toBe(1);
});
EOF
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "shared-state-mutation"
}

@test "TC-RSV2-TESTREVIEW-2.4: clean test file produces empty findings + status passed" {
  local f="$TEST_TMP/clean.test.ts"
  printf 'it("clean", () => { expect(1).toBe(1); });\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
  printf '%s\n' "$output" | grep -F '"findings":[]' >/dev/null
}

@test "TC-RSV2-TESTREVIEW-2.5: pytest @pytest.mark.flaky detected" {
  local f="$TEST_TMP/test_p.py"
  printf 'import pytest\n@pytest.mark.flaky\ndef test_a():\n    assert True\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_finding_rule "$output" "retry-heuristic"
}

@test "TC-RSV2-TESTREVIEW-2.6: JUnit @RepeatedTest detected" {
  local f="$TEST_TMP/MyTest.java"
  printf '@RepeatedTest(5)\nvoid foo() {}\n' > "$f"
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  assert_json_finding_rule "$output" "retry-heuristic"
}

@test "TC-RSV2-TESTREVIEW-2.7: time-API not flagged when far from any assertion" {
  local f="$TEST_TMP/notime.test.ts"
  cat > "$f" <<'EOF'
const start = Date.now();
function helper() { return Date.now(); }
// many lines later...
function unrelated() {
  return 1;
}
function other() {
  return 2;
}
function more() {
  return 3;
}
function evenMore() {
  return 4;
}
it("clean", () => { expect(1).toBe(1); });
EOF
  run "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  # No time-dependent-assertion finding
  ! printf '%s\n' "$output" | grep -F '"rule":"time-dependent-assertion"' >/dev/null
}

@test "TC-RSV2-TESTREVIEW-2.8: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test "TC-RSV2-TESTREVIEW-2.9: script does not invoke jq as a runtime command" {
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test "TC-RSV2-TESTREVIEW-2.10: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "TC-RSV2-TESTREVIEW-2.11: unknown flag exits 1" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
}
