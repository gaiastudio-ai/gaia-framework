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
@test "safe_grep_log -q returns 0 (NOT 141) when pattern matches under pipefail" {
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
@test "safe_grep_log -q returns 1 (NOT 141) when pattern does not match under pipefail" {
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
@test "safe_grep_log returns 1 (NOT 141) on unknown git ref under pipefail" {
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
@test "safe_grep_log -q returns 0 on long log stream when match is near the top under pipefail" {
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

# ---------------- SIGPIPE reproduction: old form fails, new form passes --------
@test "here-string eliminates SIGPIPE under pipefail with large input" {
  # Build a 1 MB string with the match on the first line.
  # Under pipefail, the old pipe form (printf | grep -q) can fail because
  # grep exits early and printf receives SIGPIPE (exit 141).  The here-string
  # form avoids the race: bash writes the variable to a temp file that grep
  # reads after the write completes.
  run bash -c '
    set -euo pipefail
    big="match-sentinel-XYZ"
    big="$big"$'"'"'\n'"'"'"$(head -c 1048576 < /dev/zero | tr "\0" "x")"
    grep -qF "match-sentinel-XYZ" <<<"$big"
  '
  [ "$status" -eq 0 ]

  # The equivalent pipe form — printf "%s\n" "$big" | grep -qF "..." — is
  # unsafe under pipefail: grep -q exits on first match, the still-writing
  # printf receives SIGPIPE (exit 141), and pipefail surfaces that 141 as
  # the pipeline status.  The race is nondeterministic (fires reliably on
  # Linux CI, rarely on macOS) so it cannot be asserted portably.
}

# ---------------- Lint: no racy printf/echo | grep -q pipelines ---------------
@test "no racy printf/echo piped to grep -q in bats test files" {
  # Scan all bats files for the pattern:  printf/echo VAR | grep -q
  # These are racy under pipefail because grep -q exits on first match,
  # causing SIGPIPE to the writer.  The fix is to use a here-string.
  #
  # Exempt patterns:
  #   - Comments (lines starting with #)
  #   - Lines inside run bash -c (single-line, intentional)
  #   - Lines that already use <<<
  #   - printf piped to non-grep commands (jq, yq, awk without exit, sed, etc.)
  #   - grep searching a FILE, not a pipe
  #   - echo/printf piped to tail (tail reads all input, no early exit)
  #   - Array expansions ${arr[@]} (can't use here-string)
  #   - The safe_grep_log PIPESTATUS test (intentionally racy)
  #   - Lines without pipefail (e.g., inside run bash -c without set -o pipefail)

  local test_dir
  test_dir="$(cd "$BATS_TEST_DIRNAME" && pwd)"

  local file_count=0
  local hits=""

  while IFS= read -r -d '' f; do
    file_count=$((file_count + 1))
    # Find lines where printf/echo pipes directly to grep -q (racy shape)
    local matches
    # The racy shape: writer (printf/echo) piped DIRECTLY to grep -q.
    # We look for:  printf FORMAT "$var" | grep -qFLAGS
    #           or: echo "$var" | grep -qFLAGS
    # The variable must be a $-prefixed expression in double quotes.
    # Exemptions:
    #   - This file itself (SIGPIPE demo + lint own commentary)
    #   - grep searching a FILE for a literal printf string
    #   - Lines inside run bash -c (separate process)
    #   - Array expansions (can't use here-string)
    #   - Pipes through non-early-exiting readers (jq, yq, tail)
    [ "$f" = "$test_dir/safe-grep-log.bats" ] && continue
    matches="$(grep -n 'printf .*"\$.*|.*grep  *-[a-zA-Z]*q' "$f" 2>/dev/null \
      | grep -v '#.*printf' \
      | grep -v '<<<' \
      | grep -v 'run bash -c' \
      | grep -v '@\]' \
      | grep -v 'jq ' \
      | grep -v "grep -qF.*'printf" \
      || true)"
    local echo_matches
    echo_matches="$(grep -n 'echo  *"\$.*|.*grep  *-[a-zA-Z]*q' "$f" 2>/dev/null \
      | grep -v '#.*echo' \
      | grep -v '<<<' \
      | grep -v 'run bash -c' \
      | grep -v '@\]' \
      | grep -v '| *tail ' \
      | grep -v '| *yq ' \
      || true)"
    [ -n "$echo_matches" ] && matches="${matches}${matches:+
}${echo_matches}"
    if [ -n "$matches" ]; then
      hits="${hits}${f}:
${matches}
"
    fi
  done < <(find "$test_dir" -name '*.bats' -print0)

  [ "$file_count" -gt 0 ] || fail "scanned 0 bats files"

  if [ -n "$hits" ]; then
    printf 'Racy printf/echo | grep -q pipelines found:\n%s\n' "$hits" >&2
    return 1
  fi
}

# ---------------- TC-5: usage error (missing pattern) ----------------
@test "safe_grep_log exits 2 on missing pattern" {
  run bash -c "
    set -o pipefail
    source '$HELPER_LIB'
    safe_grep_log -i -q
  "
  [ "$status" -eq 2 ]
}
