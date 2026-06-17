#!/usr/bin/env bats
# fixture-analyzer.bats — unit tests for plugins/gaia/scripts/review-common/fixture-analyzer.sh (E67-S1)
# Covers AC3, AC6, AC7 and TC-RSV2-TESTREVIEW-3.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/fixture-analyzer.sh"
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

@test ".1: oversized fixture flagged at default threshold (500 lines)" {
  mkdir -p "$TEST_TMP/fixtures"
  awk 'BEGIN{ for (i=0; i<600; i++) print "{}" }' > "$TEST_TMP/fixtures/big.json"
  run "$SCRIPT" "$TEST_TMP"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "failed"
  assert_json_finding_rule "$output" "oversized-fixture"
  assert_json_finding_category "$output" "fixture-quality"
}

@test ".2: oversized fixture NOT flagged with custom --max-lines 700" {
  mkdir -p "$TEST_TMP/fixtures"
  awk 'BEGIN{ for (i=0; i<600; i++) print "{}" }' > "$TEST_TMP/fixtures/big.json"
  run "$SCRIPT" --max-lines 700 "$TEST_TMP"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"oversized-fixture"' >/dev/null
}

@test ".3: mutation-during-run flagged for fs.writeFileSync to fixture path" {
  mkdir -p "$TEST_TMP/tests"
  cat > "$TEST_TMP/tests/m.test.ts" <<'EOF'
import fs from "fs";
fs.writeFileSync("./fixtures/users.json", JSON.stringify({}));
EOF
  run "$SCRIPT" "$TEST_TMP/tests/m.test.ts"
  [ "$status" -eq 0 ]
  assert_json_finding_rule "$output" "mutation-during-run"
}

@test ".4: pytest fixture cycle detected" {
  cat > "$TEST_TMP/conftest.py" <<'EOF'
import pytest

@pytest.fixture
def a(b):
    return 1

@pytest.fixture
def b(a):
    return 2
EOF
  run "$SCRIPT" "$TEST_TMP/conftest.py"
  [ "$status" -eq 0 ]
  assert_json_finding_rule "$output" "fixture-cycle"
}

@test ".5: clean fixture and test produce status passed" {
  mkdir -p "$TEST_TMP/fixtures"
  awk 'BEGIN{ for (i=0; i<50; i++) print "{}" }' > "$TEST_TMP/fixtures/small.json"
  cat > "$TEST_TMP/clean.test.ts" <<'EOF'
import fixture from "./fixtures/small.json";
it("clean", () => { expect(fixture).toBeDefined(); });
EOF
  run "$SCRIPT" "$TEST_TMP"
  [ "$status" -eq 0 ]
  assert_json_check_status "$output" "passed"
}

@test ".6: --max-lines rejects non-numeric value" {
  run "$SCRIPT" --max-lines abc /tmp/nope
  [ "$status" -eq 1 ]
}

@test ".7: pytest fixture without cycle does not trigger fixture-cycle" {
  cat > "$TEST_TMP/conftest.py" <<'EOF'
import pytest

@pytest.fixture
def a():
    return 1

@pytest.fixture
def b(a):
    return 2
EOF
  run "$SCRIPT" "$TEST_TMP/conftest.py"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -F '"rule":"fixture-cycle"' >/dev/null
}

@test ".8: script uses set -euo pipefail and LC_ALL=C" {
  grep -Fq "set -euo pipefail" "$SCRIPT"
  grep -Fq "LC_ALL=C" "$SCRIPT"
}

@test ".9: script does not invoke jq as runtime command" {
  ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -E '(^|[[:space:]\|;])jq([[:space:]]|$)' >/dev/null
}

@test ".10: --help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
}
