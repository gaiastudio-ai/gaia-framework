#!/usr/bin/env bats
# safe-grep-log.bats — regression coverage for the safe_grep_log helper at
# plugins/gaia/scripts/lib/shell-idioms.sh.
#
# Story: E57-S10 — Fix safe_grep_log SIGPIPE rc=141 false-negative under pipefail.
#
# The helper's contract:
#   safe_grep_log [grep_flags...] <pattern> [git_log_args...]
#   exit 0 — at least one matching line was found
#   exit 1 — no matching lines (clean no-match)
#   exit 2 — usage error
#
# The defect being fixed: when the caller invokes with `-q` under
# `set -o pipefail`, grep matches early and closes the pipe; the upstream
# `printf` subprocess receives SIGPIPE; pipefail surfaces 141 as the
# pipeline status; the function captures 141 instead of grep's actual 0,
# returning a false-negative no-match to the caller.
#
# Coverage:
#   TC-1 — `-q` invocation, pattern matches early: exit 0 (NOT 141).
#   TC-2 — `-q` invocation, pattern does not match: exit 1 (NOT 141).
#   TC-3 — pipeline-error case (unknown git ref): exit 1 (graceful), NOT 141.
#   TC-4 — long-stream regression: ≥50 commits, pattern matches at top,
#          `-q` invocation: exit 0 (mirrors the in-the-wild E83-S6 / E87-S1
#          reproduction).

load 'test_helper.bash'

HELPER_LIB="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/shell-idioms.sh"

setup() {
  common_setup
  # Build a tiny disposable git repo under $TEST_TMP.
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
}

teardown() { common_teardown; }

# ---------------- TC-1: -q invocation, pattern matches early ----------------
@test "TC-1: safe_grep_log -q returns 0 (NOT 141) when pattern matches under pipefail" {
  cd "$REPO"
  git commit -q --allow-empty -m "match-this-pattern at the top"
  git commit -q --allow-empty -m "filler 1"
  git commit -q --allow-empty -m "filler 2"
  # Invoke under set -o pipefail + the helper.
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q -E 'match-this-pattern' --oneline main
  "
  [ "$status" -eq 0 ]
}

# ---------------- TC-2: -q invocation, no match ----------------
@test "TC-2: safe_grep_log -q returns 1 (NOT 141) when pattern does not match under pipefail" {
  cd "$REPO"
  git commit -q --allow-empty -m "only filler commits here"
  git commit -q --allow-empty -m "still no match"
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q -E 'absent-pattern' --oneline main
  "
  [ "$status" -eq 1 ]
}

# ---------------- TC-3: unknown git ref ----------------
@test "TC-3: safe_grep_log returns 1 (NOT 141) on unknown git ref under pipefail" {
  cd "$REPO"
  git commit -q --allow-empty -m "single commit"
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q -E 'anything' --oneline does-not-exist-branch
  "
  [ "$status" -eq 1 ]
}

# ---------------- TC-4: long-stream regression (E83-S6 / E87-S1) ----------------
@test "TC-4: safe_grep_log -q returns 0 on long log stream when match is near the top under pipefail" {
  cd "$REPO"
  # Match commit at the TOP (newest) of a ≥50-commit log — exactly mirrors
  # the E87-S1 in-the-wild reproduction: pattern present in newest commit
  # but `safe_grep_log -i -q` returned 141 because grep exited early on
  # match and the upstream printf got SIGPIPE'd.
  git commit -q --allow-empty -m "needle-MARKER-needle in the top commit"
  for i in $(seq 1 60); do
    git commit -q --allow-empty -m "filler commit $i"
  done
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q -E 'needle-MARKER-needle' --oneline main
  "
  [ "$status" -eq 0 ]
}

# ---------------- TC-SIGPIPE: canonical SIGPIPE-under-pipefail trigger ----------------
@test "TC-SIGPIPE: bare 'seq | grep -q' under pipefail surfaces either rc=141 (SIGPIPE) or rc=0 (pipe buffer absorbed) — never something else" {
  # The underlying bash defect `safe_grep_log` must paper over: `seq |
  # grep -q '5'` under pipefail can surface rc=141 when grep exits early
  # and the upstream `seq` is still streaming bytes — pipefail then takes
  # the SIGPIPE'd seq's exit as pipeline status.
  #
  # Cross-platform reality: macOS bash 3.2 reliably surfaces 141; GNU
  # Linux bash 5.x may surface 0 if the pipe buffer absorbed all of seq's
  # output before grep exited (Linux pipe buffer is 64KB; seq 1..100000 is
  # ~588KB, but the kernel's pipe-flush timing means SIGPIPE delivery is
  # racy). The test therefore accepts EITHER 141 (SIGPIPE fired — the
  # documented bug class) OR 0 (pipe buffer absorbed — the helper still
  # needs the fix because the LARGER, real-world streams from
  # `git log staging` consistently fire SIGPIPE in production).
  #
  # The load-bearing assertion is TC-SIGPIPE-fix below — it proves the
  # PIPESTATUS approach yields grep's actual exit code (0 = match)
  # regardless of whether SIGPIPE fired or not.
  #
  # This test does NOT exercise safe_grep_log directly — it documents the
  # underlying bash behavior.
  run bash -c "
    set -o pipefail
    seq 1 100000 | grep -q '5'
  "
  # Accept 141 (SIGPIPE manifested) OR 0 (pipe buffer absorbed seq output
  # before grep exited). Any other rc indicates an unexpected pipeline state.
  [ "$status" -eq 141 ] || [ "$status" -eq 0 ]
}

# ---------------- TC-SIGPIPE-fix: helper-shape pipeline survives SIGPIPE via PIPESTATUS ----------------
@test "TC-SIGPIPE-fix: pipeline using PIPESTATUS[1] returns grep's actual exit (NOT 141)" {
  # Mirrors the corrected safe_grep_log internal pipeline shape:
  #   printf '%s\n' "$captured_output" | grep -q PATTERN
  # Under pipefail, the trailing `|| rc=$?` captures pipeline status (141
  # from SIGPIPE'd printf). The fix uses ${PIPESTATUS[1]} to capture grep's
  # actual exit (0 = match). This test confirms the PIPESTATUS approach
  # works.
  run bash -c '
    set -o pipefail
    big=$(seq 1 100000)
    printf "%s\n" "$big" | grep -q "5"
    rc=${PIPESTATUS[1]}
    exit "$rc"
  '
  [ "$status" -eq 0 ]
}

# ---------------- TC-5: usage error (missing pattern) ----------------
@test "TC-5: safe_grep_log exits 2 on missing pattern" {
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q
  "
  [ "$status" -eq 2 ]
}
