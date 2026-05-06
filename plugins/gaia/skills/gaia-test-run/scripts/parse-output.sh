#!/usr/bin/env bash
# parse-output.sh — Parse test runner output into pass/fail/skip counts.
#
# Reads runner stdout/stderr from STDIN. Emits four KEY=VALUE lines to STDOUT:
#   pass_count=<N>
#   fail_count=<N>
#   skip_count=<N>
#   test_count=<N>   (sum of pass+fail+skip when no explicit total found)
#
# Recognised patterns (loose, case-insensitive):
#   - "Tests:   3 passed | 1 failed | 2 skipped"   (gaia/vitest-style summary)
#   - vitest: "Test Files  N passed", "Tests  N passed"
#   - pytest: "= 3 passed, 1 failed, 2 skipped in 0.5s ="
#   - bats:   "ok N", "not ok N"
#
# When no pattern matches, all counts default to 0.

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT="$(cat)"

PASS=0
FAIL=0
SKIP=0

# 1) Canonical "Tests: N passed | N failed | N skipped" line.
canon_line="$(printf '%s\n' "$INPUT" | grep -i -E 'passed[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*failed' | head -1 || true)"
if [ -n "$canon_line" ]; then
  PASS="$(printf '%s' "$canon_line" | grep -oiE '[0-9]+[[:space:]]+passed' | head -1 | grep -oE '^[0-9]+' || echo 0)"
  FAIL="$(printf '%s' "$canon_line" | grep -oiE '[0-9]+[[:space:]]+failed' | head -1 | grep -oE '^[0-9]+' || echo 0)"
  SKIP="$(printf '%s' "$canon_line" | grep -oiE '[0-9]+[[:space:]]+skipped' | head -1 | grep -oE '^[0-9]+' || echo 0)"
else
  # 2) pytest-style "= 3 passed, 1 failed, 2 skipped in 0.5s ="
  pytest_line="$(printf '%s\n' "$INPUT" | grep -E '^=+.*passed.*=+$|=+.*passed.*in[[:space:]]' | head -1 || true)"
  if [ -n "$pytest_line" ]; then
    PASS="$(printf '%s' "$pytest_line" | grep -oE '[0-9]+[[:space:]]+passed' | head -1 | grep -oE '^[0-9]+' || echo 0)"
    FAIL="$(printf '%s' "$pytest_line" | grep -oE '[0-9]+[[:space:]]+failed' | head -1 | grep -oE '^[0-9]+' || echo 0)"
    SKIP="$(printf '%s' "$pytest_line" | grep -oE '[0-9]+[[:space:]]+skipped' | head -1 | grep -oE '^[0-9]+' || echo 0)"
  else
    # 3) bats "ok N" / "not ok N" line counting.
    PASS="$(printf '%s\n' "$INPUT" | grep -cE '^ok [0-9]' || true)"
    FAIL="$(printf '%s\n' "$INPUT" | grep -cE '^not ok [0-9]' || true)"
    SKIP="$(printf '%s\n' "$INPUT" | grep -ciE '# skip' || true)"
  fi
fi

PASS="${PASS:-0}"
FAIL="${FAIL:-0}"
SKIP="${SKIP:-0}"
TOTAL=$((PASS + FAIL + SKIP))

printf 'pass_count=%s\n' "$PASS"
printf 'fail_count=%s\n' "$FAIL"
printf 'skip_count=%s\n' "$SKIP"
printf 'test_count=%s\n' "$TOTAL"
