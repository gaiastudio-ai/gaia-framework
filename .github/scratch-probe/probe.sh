#!/bin/bash
# Throwaway macOS /bin/bash 3.2 probe (scratch evidence job; never merged).
# Usage: probe.sh <candidate-head> <expected-script-blob> <expected-test-blob>
set -u
CAND="$1"; WANT_SH="$2"; WANT_BATS="$3"
SH=plugins/gaia/skills/gaia-dev-story/scripts/ci-wait.sh
BATS=plugins/gaia/tests/ci-wait.bats
OUT="${RUNNER_TEMP:-/tmp}/probe-out"; mkdir -p "$OUT"
FAIL=0
pass() { echo "PROBE-PASS: $*"; }
fail() { echo "PROBE-FAIL: $*"; FAIL=1; }
echo "=== environment"
echo "probe_head=$(git rev-parse HEAD) candidate_head=$CAND"
echo "script_blob=$(git rev-parse HEAD:$SH) test_blob=$(git rev-parse HEAD:$BATS)"
[ "$(git rev-parse HEAD^1)" = "$CAND" ] && pass "probe commit's parent is the candidate head" || fail "probe parent $(git rev-parse HEAD^1) != candidate $CAND"
[ "$(git rev-parse HEAD:$SH)" = "$WANT_SH" ] && pass "ci-wait.sh blob matches candidate" || fail "ci-wait.sh blob differs"
[ "$(git rev-parse HEAD:$BATS)" = "$WANT_BATS" ] && pass "ci-wait.bats blob matches candidate" || fail "ci-wait.bats blob differs"
git diff --name-only "$CAND" HEAD | sed 's/^/probe-only file: /'
/bin/bash --version | head -1
echo "which -a bash:"; which -a bash
case "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" in
  3.2) pass "/bin/bash is 3.2" ;;
  *) fail "/bin/bash is not 3.2"; echo "=== result: FAIL=1"; exit 1 ;;
esac
bats --version
# Run the whole file with bats itself and every `bash` lookup on /bin/bash 3.2.
SHIM="$OUT/shim"; mkdir -p "$SHIM"; ln -sf /bin/bash "$SHIM/bash"
echo "=== ci-wait.bats under /bin/bash 3.2 (PATH shim; bats interpreter forced to /bin/bash)"
PATH="$SHIM:$PATH" /bin/bash "$(command -v bats)" --tap "$BATS" > "$OUT/ci-wait.tap" 2>&1; rc=$?
cat "$OUT/ci-wait.tap"
echo "bats_exit=$rc"
nok=$(grep -c '^not ok' "$OUT/ci-wait.tap"); ok=$(grep -c '^ok' "$OUT/ci-wait.tap"); sk=$(grep -c '# skip' "$OUT/ci-wait.tap")
plan=$(grep -m1 '^1\.\.' "$OUT/ci-wait.tap")
echo "counts: plan=$plan ok=$ok not_ok=$nok skip=$sk"
[ "$rc" -eq 0 ] && pass "bats exit 0" || fail "bats exit $rc"
[ "$nok" -eq 0 ] && pass "0 not ok" || fail "$nok not ok"
[ "$plan" = "1..$ok" ] && pass "TAP complete ($ok of $plan)" || fail "TAP incomplete"
line=$(grep 'cross-check scenario runs under bash 3.2 interpreter when available' "$OUT/ci-wait.tap")
echo "required test line: $line"
case "$line" in
  "ok "*"# skip"*) fail "bash 3.2 test SKIPPED" ;;
  "ok "*) pass "bash 3.2 test ran and passed (not skipped)" ;;
  *) fail "bash 3.2 test missing or failed" ;;
esac
[ "$sk" -eq 0 ] && pass "no skips in the file" || echo "NOTE: $sk skip(s) elsewhere in the file"
echo "=== result: FAIL=$FAIL"
exit "$FAIL"
