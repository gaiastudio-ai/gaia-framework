#!/bin/bash
# Throwaway macOS /bin/bash 3.2 probe (scratch evidence job; never merged).
# Usage: probe.sh <candidate-head> <script-blob> <test-blob>
set -u
CAND="$1"; WS="$2"; WT="$3"
SC=plugins/gaia/scripts/independence-check.sh; T=plugins/gaia/tests/concurrent-sprint-independence-cd.bats
OUT="${RUNNER_TEMP:-/tmp}/probe-out"; mkdir -p "$OUT"; FAIL=0
pass() { echo "PROBE-PASS: $*"; }; fail() { echo "PROBE-FAIL: $*"; FAIL=1; }
echo "probe_head=$(git rev-parse HEAD) candidate=$CAND script_blob=$(git rev-parse HEAD:$SC) test_blob=$(git rev-parse HEAD:$T)"
[ "$(git rev-parse HEAD^1)" = "$CAND" ] && pass "probe parent is the candidate" || fail "probe parent differs"
[ "$(git rev-parse HEAD:$SC)" = "$WS" ] && pass "script blob matches" || fail "script blob differs"
[ "$(git rev-parse HEAD:$T)" = "$WT" ] && pass "test blob matches" || fail "test blob differs"
git diff --name-only "$CAND" HEAD | sed 's/^/probe-only file: /'
uname -s; /bin/bash --version | head -1
case "$(/bin/bash -c 'printf %s "$BASH_VERSION"')" in 3.2.*) pass "/bin/bash is 3.2" ;; *) fail "/bin/bash not 3.2"; echo "=== result: FAIL=1"; exit 1 ;; esac
SHIM="$OUT/shim"; mkdir -p "$SHIM"; ln -sf /bin/bash "$SHIM/bash"
echo "=== $T with bats and every bash lookup forced to /bin/bash 3.2"
PATH="$SHIM:$PATH" /bin/bash "$(command -v bats)" --tap "$T" > "$OUT/t.tap" 2>&1; rc=$?; cat "$OUT/t.tap"; echo "bats_exit=$rc"
ok=$(grep -c '^ok' "$OUT/t.tap"); nok=$(grep -c '^not ok' "$OUT/t.tap"); sk=$(grep -c '# skip' "$OUT/t.tap"); plan=$(grep -m1 '^1\.\.' "$OUT/t.tap")
echo "counts: plan=$plan ok=$ok not_ok=$nok skip=$sk"
[ "$rc" -eq 0 ] && pass "bats exit 0" || fail "bats exit $rc"
[ "$nok" -eq 0 ] && pass "0 not ok" || fail "$nok not ok"
[ "$plan" = "1..$ok" ] && pass "TAP complete" || fail "TAP incomplete"
for n in "intra-active duplicate path does not block disjoint candidate" "intra-candidate duplicate path does not block disjoint active" "extracted realpath owner lookup returns side-filtered owner" "extracted realpath owner lookup with reversed entry order returns side-filtered owner"; do
  l=$(grep -F "$n" "$OUT/t.tap"); case "$l" in "ok "*"# skip"*) fail "skipped: $n" ;; "ok "*) pass "ran and passed: $n" ;; *) fail "missing/failed: $n" ;; esac
done
echo "=== result: FAIL=$FAIL"; exit "$FAIL"
