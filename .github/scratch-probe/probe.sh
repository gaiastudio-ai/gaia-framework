#!/bin/bash
# Throwaway macOS /bin/bash 3.2 probe (scratch evidence job; never merged).
# Runs from the repo root of a full checkout of the candidate commit.
# Usage: probe.sh <old-sha> <pre-repair-test-sha>
set -u
OLD_SHA="$1"
PRE_RF1_SHA="$2"
LIBP=plugins/gaia/scripts/lib/lifecycle-overrides.sh
OUT="${RUNNER_TEMP:-/tmp}/probe-out"; mkdir -p "$OUT"
FAIL=0
pass() { echo "PROBE-PASS: $*"; }
fail() { echo "PROBE-FAIL: $*"; FAIL=1; }

echo "=== environment"
echo "candidate_head=$(git rev-parse HEAD)"
echo "candidate_lib_blob=$(git rev-parse HEAD:$LIBP)"
echo "old_sha=$OLD_SHA old_lib_blob=$(git rev-parse "$OLD_SHA:$LIBP")"
/bin/bash --version | head -1
echo "which -a bash:"; which -a bash
case "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" in
  3.2) pass "/bin/bash is 3.2" ;;
  *) fail "/bin/bash is not 3.2"; exit 1 ;;
esac

# PATH shim: `bash` resolves to /bin/bash; optional flock stub.
SHIM="$OUT/shim"; mkdir -p "$SHIM"
ln -sf /bin/bash "$SHIM/bash"
FLOCKSHIM="$OUT/flockshim"; mkdir -p "$FLOCKSHIM"
printf '#!/bin/sh\nexit 0\n' > "$FLOCKSHIM/flock"; chmod +x "$FLOCKSHIM/flock"

echo "=== Task 1a: raw exec {VAR} syntax under /bin/bash 3.2"
cd "$OUT"
/bin/bash -c 'exec {LOCK_FD}>./lk; echo after' >t1a.out 2>t1a.err; rc=$?
echo "rc=$rc"; echo "stdout:"; cat t1a.out; echo "stderr:"; cat t1a.err
[ "$rc" -eq 127 ] && pass "1a exit 127" || fail "1a exit $rc (want 127)"
grep -q '{LOCK_FD}: not found' t1a.err && pass "1a stderr names {LOCK_FD}: not found" || fail "1a stderr lacks '{LOCK_FD}: not found'"
grep -q after t1a.out && fail "1a reached 'echo after'" || pass "1a never reached 'echo after'"
cd - >/dev/null

echo "=== Task 1b: OLD lifecycle-overrides.sh sourced under /bin/bash 3.2 with flock stub"
OLDLIB="$OUT/old-lifecycle-overrides.sh"; git show "$OLD_SHA:$LIBP" > "$OLDLIB"
echo "old lib sha256=$(shasum -a 256 "$OLDLIB" | cut -d' ' -f1) (blob $(git hash-object "$OLDLIB"))"
ST="$OUT/t1b-state"; mkdir -p "$ST"
PATH="$FLOCKSHIM:$SHIM:$PATH" LIFECYCLE_OVERRIDES_FILE="$ST/lifecycle-overrides.yaml" LIFECYCLE_OVERRIDES_LOCK="$ST/lifecycle-overrides.yaml.lock" \
  /bin/bash -c 'set -euo pipefail; echo "BASH_VERSION=$BASH_VERSION"; source "$1"; lifecycle_append_bypass --skill /gaia-trace --reason "probe reason" --sprint-id sprint-probe; echo REACHED_AFTER' _ "$OLDLIB" >"$OUT/t1b.out" 2>"$OUT/t1b.err"; rc=$?
echo "rc=$rc"; echo "stdout:"; cat "$OUT/t1b.out"; echo "stderr:"; cat "$OUT/t1b.err"; echo "state dir:"; ls -la "$ST"
[ "$rc" -eq 127 ] && pass "1b exit 127" || fail "1b exit $rc (want 127)"
grep -q 'not found' "$OUT/t1b.err" && pass "1b stderr has 'not found'" || fail "1b stderr lacks 'not found'"
grep -q REACHED_AFTER "$OUT/t1b.out" && fail "1b continued after the call" || pass "1b aborted at the call"
ls "$ST"/.lifecycle-overrides.tmp.* >/dev/null 2>&1 && pass "1b RETURN trap never fired (tmp file left behind)" || fail "1b no leftover tmp file"
grep -q 'probe reason' "$ST/lifecycle-overrides.yaml" 2>/dev/null && fail "1b record was written" || pass "1b no record written"

echo "=== Candidate lib under the same conditions (control)"
ST2="$OUT/t1c-state"; mkdir -p "$ST2"
PATH="$FLOCKSHIM:$SHIM:$PATH" LIFECYCLE_OVERRIDES_FILE="$ST2/lifecycle-overrides.yaml" LIFECYCLE_OVERRIDES_LOCK="$ST2/lifecycle-overrides.yaml.lock" \
  /bin/bash -c 'set -euo pipefail; source "$1"; lifecycle_append_bypass --skill /gaia-trace --reason "probe reason" --sprint-id sprint-probe; echo REACHED_AFTER' _ "$PWD/$LIBP" >"$OUT/t1c.out" 2>"$OUT/t1c.err"; rc=$?
echo "rc=$rc"; cat "$OUT/t1c.out" "$OUT/t1c.err"
[ "$rc" -eq 0 ] && grep -q REACHED_AFTER "$OUT/t1c.out" && grep -q 'probe reason' "$ST2/lifecycle-overrides.yaml" && ! grep -q 'not found' "$OUT/t1c.err" \
  && pass "candidate appends under bash 3.2 (flock path)" || fail "candidate control failed"

echo "=== Task 8b: real create-arch setup.sh --bypass caller path under /bin/bash 3.2 (isolated fixture)"
for mode in flock mkdir; do
  FX="$OUT/fixture-$mode"; mkdir -p "$FX/.gaia/state" "$FX/.gaia/config"
  printf 'sprint_id: "sprint-probe"\nstatus: active\nstories: []\n' > "$FX/.gaia/state/sprint-status.yaml"
  printf 'project_name: probe\n' > "$FX/.gaia/config/project-config.yaml"
  if [ "$mode" = flock ]; then P="$FLOCKSHIM:$SHIM:$PATH"; else P="$SHIM:$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/flock" ] || printf '%s:' "$d"; done)"; fi
  echo "-- mode=$mode flock resolves to: $(PATH="$P" command -v flock || echo none); bash resolves to: $(PATH="$P" command -v bash)"
  ( cd "$FX" && PATH="$P" PROJECT_ROOT="$FX" /bin/bash "$OLDPWD/plugins/gaia/skills/gaia-create-arch/scripts/setup.sh" --bypass gaia-threat-model --reason "probe bypass $mode" ) >"$OUT/t8b-$mode.out" 2>"$OUT/t8b-$mode.err"; rc=$?
  echo "setup.sh rc=$rc (later gates may halt; only the bypass append is under test)"
  echo "stderr (bypass-related lines):"; grep -E 'lifecycle|bypass|not found|WARNING' "$OUT/t8b-$mode.err" || true
  echo "overrides file:"; cat "$FX/.gaia/state/lifecycle-overrides.yaml" 2>&1
  grep -q "probe bypass $mode" "$FX/.gaia/state/lifecycle-overrides.yaml" 2>/dev/null && pass "8b[$mode] bypass record appended" || fail "8b[$mode] no record"
  grep -q 'not found' "$OUT/t8b-$mode.err" && fail "8b[$mode] 'not found' on stderr" || pass "8b[$mode] no 'not found'"
  grep -q 'append failed' "$OUT/t8b-$mode.err" && fail "8b[$mode] append-failed warning" || pass "8b[$mode] no append-failed warning"
done

echo "=== RF-1: repaired bats assertions gate their tests under bash 3.2"
command -v bats >/dev/null || brew install bats-core >/dev/null 2>&1
BATS_BIN="$(command -v bats)"; echo "bats=$BATS_BIN $($BATS_BIN --version)"
runbats() { PATH="$SHIM:$PATH" LIFECYCLE_BASH32=/bin/bash /bin/bash "$BATS_BIN" "$@"; }
echo "-- candidate (expect all pass, 0 skip)"
runbats plugins/gaia/tests/lifecycle-overrides-bash32-fd.bats >"$OUT/rf1-candidate.tap" 2>&1; rc=$?; cat "$OUT/rf1-candidate.tap"
[ "$rc" -eq 0 ] && ! grep -q '# skip' "$OUT/rf1-candidate.tap" && pass "candidate bats green under bash 3.2, no skips" || fail "candidate bats not green"
# Each mutant runs in a throwaway copy of the checkout. Mutant A/C patch the lib
# so that every earlier assertion (status, record) still passes and ONLY the
# repaired stderr assertion can catch the defect. The same mutant is also run
# against the pre-repair bats file (old [[ ]] form) to show it was inert there.
BATS_REL=plugins/gaia/tests/lifecycle-overrides-bash32-fd.bats
mutant_run() { # <name> <perl-expr> <bats-version: repaired|unrepaired> <test-filter>
  local name="$1" expr="$2" ver="$3" filt="$4" dir="$OUT/mut-$1-$3"
  rm -rf "$dir"; mkdir -p "$dir"; git archive HEAD | tar -x -C "$dir"
  perl -0pi -e "$expr" "$dir/$LIBP"
  if cmp -s "$dir/$LIBP" "$LIBP"; then echo "mutant $name: patch did not apply"; return 2; fi
  [ "$ver" = unrepaired ] && git show "$PRE_RF1_SHA:$BATS_REL" > "$dir/$BATS_REL"
  ( cd "$dir" && PATH="$SHIM:$PATH" LIFECYCLE_BASH32=/bin/bash /bin/bash "$BATS_BIN" -f "$filt" "$BATS_REL" ) >"$dir.tap" 2>&1
  local rc=$?; echo "--- mutant $name / $ver bats (filter: $filt) rc=$rc"; cat "$dir.tap"; return $rc
}
# Mutant A: flock path also prints a spurious "not found" line, still appends and exits 0.
MUT_A='s/(\(\n\s*flock -w 5 9 \|\|)/(\n      printf "lifecycle_append_bypass: flock: not found\\n" >&2\n      flock -w 5 9 ||/'
mutant_run A "$MUT_A" repaired 'flock path under bash 3.2 exits 0 and appends bypass'
rc=$?; [ "$rc" -ne 0 ] && grep -q "unexpected 'not found' on stderr" "$OUT/mut-A-repaired.tap" && pass "RF-1 test 1: repaired stderr assertion catches mutant A" || fail "RF-1 test 1: mutant A not caught by the repaired assertion"
mutant_run A "$MUT_A" unrepaired 'flock path under bash 3.2 exits 0 and appends bypass'
rc=$?; [ "$rc" -eq 0 ] && pass "RF-1 test 1: old [[ ]] form was inert under bash 3.2 (mutant A passed)" || echo "NOTE: old form caught mutant A (rc=$rc)"
# Mutant C: _do_append prints a spurious lock diagnostic first, behaviour otherwise unchanged.
MUT_C='s/(_do_append\(\) \{\n)/$1    printf "lifecycle_append_bypass: failed to acquire lock at X\\n" >&2\n/'
mutant_run C "$MUT_C" repaired 'do-append failure does not print lock diagnostic'
rc=$?; [ "$rc" -ne 0 ] && grep -q "unexpected lock diagnostic on stderr" "$OUT/mut-C-repaired.tap" && pass "RF-1 test 6: repaired assertion catches mutant C" || fail "RF-1 test 6: mutant C not caught"
mutant_run C "$MUT_C" unrepaired 'do-append failure does not print lock diagnostic'
rc=$?; [ "$rc" -eq 0 ] && pass "RF-1 test 6: old [[ ]] form was inert under bash 3.2 (mutant C passed)" || echo "NOTE: old form caught mutant C (rc=$rc)"
mutant_run C "$MUT_C" repaired 'failing jq step in design-gate caller shape aborts before yq'
rc=$?; [ "$rc" -ne 0 ] && grep -q "unexpected lock diagnostic on stderr" "$OUT/mut-C-repaired.tap" && pass "RF-1 test 10: repaired assertion catches mutant C" || fail "RF-1 test 10: mutant C not caught"
# FD8_OK (tests 5, 7): a lib mutant that closes fd 8 makes the wrapper exit non-zero, so the
# status assertion fires first; the FD8_OK assertion is proven in isolation with a minimal
# bats file under /bin/bash 3.2: output lacks FD8_OK, status 0, assertion NOT the last line.
H="$OUT/fd8-harness"; mkdir -p "$H"
cat > "$H/repaired.bats" <<'BATS'
@test "repaired FD8_OK assertion gates a non-final position" {
  run /bin/bash -c 'echo nothing-here'
  [ "$status" -eq 0 ]
  case "$output" in *FD8_OK*) ;; *) echo "FD8_OK missing from output: $output" >&2; return 1 ;; esac
  [ 1 -eq 1 ]
}
BATS
cat > "$H/unrepaired.bats" <<'BATS'
@test "old FD8_OK assertion in a non-final position" {
  run /bin/bash -c 'echo nothing-here'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FD8_OK"* ]]
  [ 1 -eq 1 ]
}
BATS
PATH="$SHIM:$PATH" /bin/bash "$BATS_BIN" "$H/repaired.bats" >"$H/repaired.tap" 2>&1; rr=$?
PATH="$SHIM:$PATH" /bin/bash "$BATS_BIN" "$H/unrepaired.bats" >"$H/unrepaired.tap" 2>&1; ru=$?
cat "$H/repaired.tap" "$H/unrepaired.tap"
[ "$rr" -ne 0 ] && grep -q "FD8_OK missing" "$H/repaired.tap" && pass "RF-1 FD8_OK: repaired form fails when FD8_OK is absent" || fail "RF-1 FD8_OK: repaired form did not fail"
[ "$ru" -eq 0 ] && pass "RF-1 FD8_OK: old [[ ]] form inert under bash 3.2 (passed despite missing FD8_OK)" || echo "NOTE: old form failed (rc=$ru)"
grep -c 'case "$output" in \*FD8_OK\*' "$BATS_REL" | sed 's/^/repaired FD8_OK lines in candidate bats file: /'
echo "=== result: FAIL=$FAIL"
exit "$FAIL"
