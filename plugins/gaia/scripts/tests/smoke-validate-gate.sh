#!/usr/bin/env bash
# smoke-validate-gate.sh — manual smoke test harness for validate-gate.sh (E28-S15)
#
# Covers every AC (AC1–AC7) and the test scenarios enumerated in the story.
# The full bats-core suite lands in E28-S17 — this harness is sufficient for
# the RED → GREEN cycle on E28-S15 only.
#
# Usage: bash plugins/gaia/scripts/tests/smoke-validate-gate.sh
# Exit 0 when all assertions pass, 1 on first failure.

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VG="$SCRIPT_DIR/validate-gate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { printf "  ok  %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL %s\n     %s\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

run() {
  # run <expected_exit> <stdout_match|-> <stderr_match|-> <desc> -- <cmd...>
  local expected="$1"; shift
  local out_match="$1"; shift
  local err_match="$1"; shift
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  "$@" >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected" ]; then
    fail "$desc" "exit $rc, expected $expected. stderr: $(cat "$err")"
    rm -f "$out" "$err"; return
  fi
  if [ "$out_match" != "-" ] && ! grep -q -- "$out_match" "$out"; then
    fail "$desc" "stdout missing '$out_match'. got: $(cat "$out")"
    rm -f "$out" "$err"; return
  fi
  if [ "$err_match" != "-" ] && ! grep -q -- "$err_match" "$err"; then
    fail "$desc" "stderr missing '$err_match'. got: $(cat "$err")"
    rm -f "$out" "$err"; return
  fi
  ok "$desc"
  rm -f "$out" "$err"
}

TA="$TMP/test-artifacts"
mkdir -p "$TA"

# Scenario 1 — happy: test_plan_exists
echo "# Test Plan" > "$TA/test-plan.md"
TEST_ARTIFACTS="$TA" run 0 - - "AC1/AC3 #1: test_plan_exists happy" -- "$VG" test_plan_exists

# Scenario 2 — happy: traceability_exists
echo "# Traceability" > "$TA/traceability-matrix.md"
TEST_ARTIFACTS="$TA" run 0 - - "AC1/AC3 #2: traceability_exists happy" -- "$VG" traceability_exists

# Scenario 3 — missing file fails with stable error format
rm -f "$TA/test-plan.md"
TEST_ARTIFACTS="$TA" run 1 - "validate-gate: test_plan_exists failed — expected:" \
  "#3: test_plan_exists missing fails with stable error" -- "$VG" test_plan_exists
echo "# Test Plan" > "$TA/test-plan.md"

# Scenario 4 — atdd_exists resolves story key
echo "# ATDD" > "$TA/atdd-E1-S1.md"
TEST_ARTIFACTS="$TA" run 0 - - "AC3 #4: atdd_exists --story resolves" -- "$VG" atdd_exists --story E1-S1

# Scenario 5 — atdd_exists missing --story
TEST_ARTIFACTS="$TA" run 1 - "atdd_exists requires --story" \
  "AC3 #5: atdd_exists without --story" -- "$VG" atdd_exists

# Scenario 6 — file_exists multi-file happy
echo "a" > "$TMP/a.md"; echo "b" > "$TMP/b.md"
run 0 - - "AC6 #6: file_exists happy multi" -- "$VG" file_exists --file "$TMP/a.md" --file "$TMP/b.md"

# Scenario 7 — file_exists first missing
run 1 - "missing.md" "AC6 #7: file_exists first missing" -- "$VG" file_exists --file "$TMP/a.md" --file "$TMP/missing.md"

# Scenario 8 — --multi happy
echo "# CI" > "$TA/ci-setup.md"
TEST_ARTIFACTS="$TA" run 0 - "all 3 gates passed" "AC4 #8: --multi happy" -- \
  "$VG" --multi "test_plan_exists,traceability_exists,ci_setup_exists"

# Scenario 9 — --multi first-gate fail
rm -f "$TA/traceability-matrix.md"
TEST_ARTIFACTS="$TA" run 1 - "traceability_exists" "AC4 #9: --multi first-gate fail" -- \
  "$VG" --multi "test_plan_exists,traceability_exists"
echo "# Traceability" > "$TA/traceability-matrix.md"

# Scenario 10 — --list enumerates gates
run 0 "test_plan_exists" - "AC5 #10: --list enumerates" -- "$VG" --list
run 0 "atdd_exists" - "AC5 #10b: --list includes atdd_exists" -- "$VG" --list

# Scenario 11 — unknown gate type
run 1 - "unknown gate type: bogus_gate" "AC7 #11: unknown gate type" -- "$VG" bogus_gate

# Scenario 12 — --help prints to stdout, exit 0
run 0 "Usage:" - "AC7 #12: --help prints usage to stdout" -- "$VG" --help

# AC2 — missing file error names absolute path
# E28-S152: readiness_report_exists resolves against PLANNING_ARTIFACTS
PA="$TMP/planning-artifacts"
mkdir -p "$PA"
rm -f "$PA/readiness-report.md"
ABSPA=$(cd "$PA" && pwd)
PLANNING_ARTIFACTS="$PA" run 1 - "$ABSPA/readiness-report.md" \
  "AC2: error message names absolute path" -- "$VG" readiness_report_exists

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
