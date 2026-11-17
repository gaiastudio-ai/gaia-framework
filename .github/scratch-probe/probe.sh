#!/bin/bash
# Throwaway macOS /bin/bash 3.2 probe (scratch evidence job; never merged).
# Usage: probe.sh <candidate-head> <expected-lib-blob> <expected-test-blob>
set -u
CAND="$1"; WANT_LIB="$2"; WANT_T="$3"
LIBP=plugins/gaia/scripts/lib/lifecycle-overrides.sh
T=plugins/gaia/tests/lifecycle-overrides-bash32-fd.bats
OUT="${RUNNER_TEMP:-/tmp}/probe-out"; mkdir -p "$OUT"; FAIL=0
pass() { echo "PROBE-PASS: $*"; }; fail() { echo "PROBE-FAIL: $*"; FAIL=1; }
echo "probe_head=$(git rev-parse HEAD) candidate_head=$CAND lib_blob=$(git rev-parse HEAD:$LIBP) test_blob=$(git rev-parse HEAD:$T)"
[ "$(git rev-parse HEAD^1)" = "$CAND" ] && pass "probe parent is the candidate head" || fail "probe parent differs"
[ "$(git rev-parse HEAD:$LIBP)" = "$WANT_LIB" ] && pass "lib blob matches candidate" || fail "lib blob differs"
[ "$(git rev-parse HEAD:$T)" = "$WANT_T" ] && pass "test blob matches candidate" || fail "test blob differs"
git diff --name-only "$CAND" HEAD | sed 's/^/probe-only file: /'
uname -s; /bin/bash --version | head -1
case "$(/bin/bash -c 'printf %s "$BASH_VERSION"')" in 3.2.*) pass "/bin/bash is 3.2" ;; *) fail "/bin/bash not 3.2"; echo "=== result: FAIL=1"; exit 1 ;; esac
bats --version
echo "=== $T (bats itself on PATH bash; the tests force /bin/bash for the lib)"
bats --tap "$T" > "$OUT/t.tap" 2>&1; rc=$?; cat "$OUT/t.tap"; echo "bats_exit=$rc"
ok=$(grep -c '^ok' "$OUT/t.tap"); nok=$(grep -c '^not ok' "$OUT/t.tap"); sk=$(grep -c '# skip' "$OUT/t.tap"); plan=$(grep -m1 '^1\.\.' "$OUT/t.tap")
echo "counts: plan=$plan ok=$ok not_ok=$nok skip=$sk"
[ "$rc" -eq 0 ] && pass "bats exit 0" || fail "bats exit $rc"
[ "$nok" -eq 0 ] && pass "0 not ok" || fail "$nok not ok"
[ "$sk" -eq 0 ] && pass "0 skips" || fail "$sk skips"
[ "$plan" = "1..$ok" ] && pass "TAP complete" || fail "TAP incomplete"
for n in "flock path under bash 3.2 exits 0 and appends bypass" "mkdir fallback under bash 3.2 without flock" "flock path under bash 3.2 with caller holding fd 8" "middle-step failure in design-gate caller shape under bash 3.2"; do
  l=$(grep -F "$n" "$OUT/t.tap"); case "$l" in "ok "*"# skip"*) fail "skipped: $n" ;; "ok "*) pass "ran and passed: $n" ;; *) fail "missing/failed: $n" ;; esac
done
echo "=== mkdir lock observation assertions present in the tested blob"
grep -q "mkdir lock directory was not held during entry build" "$T" && grep -q "mkdir lock directory was not held during file write" "$T" && grep -q "mkdir lock directory still exists after append returned" "$T" && pass "lock-observation assertions present" || fail "lock-observation assertions missing"
echo "=== negative control: a non-3.2 interpreter must FAIL (not skip) on macOS"
if command -v brew >/dev/null 2>&1; then brew list bash >/dev/null 2>&1 || brew install bash >/dev/null 2>&1; fi
NB="$(brew --prefix 2>/dev/null)/bin/bash"; "$NB" --version | head -1
LIFECYCLE_BASH32="$NB" bats --tap -f 'flock path under bash 3.2 exits 0' "$T" > "$OUT/neg.tap" 2>&1; nrc=$?; cat "$OUT/neg.tap"; echo "neg_exit=$nrc"
grep -q '^not ok' "$OUT/neg.tap" && ! grep -q '# skip' "$OUT/neg.tap" && pass "non-3.2 interpreter fails, does not skip" || fail "negative control did not fail as required"
echo "=== result: FAIL=$FAIL"; exit "$FAIL"
