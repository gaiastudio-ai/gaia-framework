#!/usr/bin/env bats
# defensive-shell-coding-sweep.bats — tests for argument separators,
# fixed-string matching, input validation, and byte-identical mirror pairs.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPTS_LIB="$SCRIPTS_DIR/lib"
}

# ---------------------------------------------------------------------------
# AC1: -- separator in transcript-writer.sh git check-ignore
# ---------------------------------------------------------------------------

@test "transcript-writer: git check-ignore uses -- before user-derived pattern" {
  local tw="$SCRIPTS_LIB/transcript-writer.sh"
  [ -f "$tw" ] || skip "transcript-writer.sh not found"
  # The function assert_gitignored must include -- before the pattern argument.
  # Grep for the functional call site (not a comment).
  run /usr/bin/grep 'check-ignore' "$tw"
  # Every non-comment check-ignore invocation must contain ' -- '
  local line
  while IFS= read -r line; do
    case "$line" in
      '#'*|*'#'*check-ignore*) continue ;;
    esac
    if printf '%s' "$line" | /usr/bin/grep -q 'check-ignore'; then
      printf '%s' "$line" | /usr/bin/grep -Fq ' -- ' || {
        echo "FAIL: check-ignore call missing '--': $line"
        return 1
      }
    fi
  done < "$tw"
}

@test "transcript-writer: assert_gitignored treats dash-prefixed pattern as path" {
  local tw="$SCRIPTS_LIB/transcript-writer.sh"
  [ -f "$tw" ] || skip "transcript-writer.sh not found"
  # Set up a minimal git repo with a .gitignore that ignores --version*
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf -- '--version*\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m init
  # Source transcript-writer and call assert_gitignored with a dash-prefixed
  # pattern. Without --, git misinterprets it as a flag.
  run bash -c "
    set -euo pipefail
    export PROJECT_ROOT='$repo'
    source '$tw'
    assert_gitignored '--version'
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2a: _ic_is_known_key uses grep -Fw (fixed-string, whole-word)
# ---------------------------------------------------------------------------

@test "independence-check: _ic_is_known_key uses grep -Fw for epics file" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # Extract the function body and check each grep call uses -F, -w, and --.
  local in_func=0 line
  while IFS= read -r line; do
    case "$line" in
      *'_ic_is_known_key()'*) in_func=1 ;;
    esac
    if [ "$in_func" = "1" ]; then
      if printf '%s' "$line" | /usr/bin/grep -q '/usr/bin/grep'; then
        # Must contain -F flag (fixed-string)
        printf '%s' "$line" | /usr/bin/grep -q -- '-[a-zA-Z]*F' || {
          echo "FAIL: grep call in _ic_is_known_key missing -F: $line"
          return 1
        }
        # Must contain -w flag (whole-word)
        printf '%s' "$line" | /usr/bin/grep -q -- '-[a-zA-Z]*w' || {
          echo "FAIL: grep call in _ic_is_known_key missing -w: $line"
          return 1
        }
        # Must contain -- separator
        printf '%s' "$line" | /usr/bin/grep -Fq -- '-- ' || {
          echo "FAIL: grep call in _ic_is_known_key missing --: $line"
          return 1
        }
      fi
      # End of function
      case "$line" in
        '}') [ "$in_func" = "1" ] && in_func=2 ;;
      esac
    fi
  done < "$ic"
  [ "$in_func" = "2" ]
}

@test "independence-check: _ic_is_known_key rejects regex metacharacter false match" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # Create a mock epics file that contains E28-S1 but NOT E.8-S1.
  local epics_file="$TEST_TMP/epics.md"
  printf 'E28-S1 story title\n' > "$epics_file"
  # Extract the function body to a temp file for sourcing.
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    resolve_story_file() { return 1; }
    source '$func_file'
    if _ic_is_known_key 'E.8-S1' '$epics_file' ''; then
      echo 'FAIL: regex metacharacter matched when it should not'
      exit 1
    fi
    echo 'PASS: metacharacter correctly rejected'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "independence-check: _ic_is_known_key matches exact key" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  local epics_file="$TEST_TMP/epics.md"
  printf 'E28-S1 story title\n' > "$epics_file"
  local func_file="$TEST_TMP/ic_known_key.sh"
  sed -n '/_ic_is_known_key()/,/^}/p' "$ic" > "$func_file"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    resolve_story_file() { return 1; }
    source '$func_file'
    if _ic_is_known_key 'E28-S1' '$epics_file' ''; then
      echo 'PASS: exact match found'
      exit 0
    fi
    echo 'FAIL: exact match not found'
    exit 1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# AC2b: _ic_run_rules_cd uses awk for exact first-field matching
# ---------------------------------------------------------------------------

@test "independence-check: cache-write uses awk for exact first-field matching" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # The fresh_parsed lookup must use awk, not grep with a spliced regex.
  # Verify the source no longer uses grep on fresh_parsed.
  if /usr/bin/grep -q 'grep.*fresh_parsed' "$ic"; then
    echo "FAIL: grep still used on fresh_parsed (should be awk)"
    return 1
  fi
  # Confirm awk with first-field equality is present.
  # Use single quotes to avoid shell expansion of $1.
  /usr/bin/grep -q 'awk.*\$1==k' "$ic" || {
    echo "FAIL: awk first-field equality check not found"
    return 1
  }
}

@test "independence-check: awk first-field match rejects dot metacharacter" {
  # Simulate the fresh_parsed lookup: a TSV file with E28-S10\tTS\tpath
  # must not match a lookup for E28-S1. (with dot, the old grep matched).
  local tsv="$TEST_TMP/fresh_parsed.tsv"
  printf 'E28-S10\tTS\tsome/path\n' > "$tsv"
  # Old grep would match E28-S1. because . matches 0 and tab:
  run bash -c "
    result=\"\$(awk -F'\t' -v k='E28-S1.' '\$1==k' '$tsv')\"
    if [ -n \"\$result\" ]; then
      echo 'FAIL: awk matched E28-S1. against E28-S10'
      exit 1
    fi
    echo 'PASS: awk correctly rejected dot metacharacter'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# AC3: validate fd parameter in acquire-lock.sh
# ---------------------------------------------------------------------------

@test "acquire-lock: rejects non-numeric fd with exit 1" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local lock_file="$TEST_TMP/test.lock"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$lock_file' 1 '9;echo INJECTED'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: rejects alphabetic fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local lock_file="$TEST_TMP/test.lock"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$lock_file' 1 'abc'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: rejects empty fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local lock_file="$TEST_TMP/test.lock"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$lock_file' 1 ''
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"fd must be a positive integer"* ]]
}

@test "acquire-lock: accepts valid numeric fd" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local lock_file="$TEST_TMP/test.lock"
  # fd 9 is a common test descriptor; unset parallel execution so
  # the fallback path does not require flock.
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    unset GAIA_PARALLEL_EXECUTION
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$al'
    acquire_lock '$lock_file' 2 9
    release_lock 9
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4: trailing-slash state_dir in close_predicate
# ---------------------------------------------------------------------------

@test "acquire-lock: close_predicate no double slash with trailing-slash state_dir" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local state_dir="$TEST_TMP/state/"
  mkdir -p "$state_dir"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    source '$al'
    acquire_lock_close_predicate 1 '$state_dir'
  "
  [ "$status" -eq 0 ]
  # Output must not contain //
  if printf '%s' "$output" | /usr/bin/grep -Fq '//'; then
    echo "FAIL: double slash found in output: $output"
    return 1
  fi
}

@test "acquire-lock: close_predicate works without trailing slash" {
  local al="$SCRIPTS_LIB/acquire-lock.sh"
  [ -f "$al" ] || skip "acquire-lock.sh not found"
  local state_dir="$TEST_TMP/state"
  mkdir -p "$state_dir"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    source '$al'
    acquire_lock_close_predicate 1 '$state_dir'
  "
  [ "$status" -eq 0 ]
  # Still no double slash
  if printf '%s' "$output" | /usr/bin/grep -Fq '//'; then
    echo "FAIL: double slash found in output: $output"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# AC5: -C "$repo" in PPO admission-failure git worktree calls
# ---------------------------------------------------------------------------

@test "phase-parallel-orchestrator: admission-failure cleanup uses git -C repo" {
  local ppo="$SCRIPTS_DIR/phase-parallel-orchestrator.sh"
  [ -f "$ppo" ] || skip "phase-parallel-orchestrator.sh not found"
  # Find the admission-failure cleanup block and check each git worktree call.
  local in_cleanup=0 found_unlock=0 found_remove=0 found_prune=0
  while IFS= read -r line; do
    case "$line" in
      *"Clean up orphaned worktree"*) in_cleanup=1 ;;
    esac
    if [ "$in_cleanup" = "1" ]; then
      case "$line" in
        *"git -C"*worktree*unlock*) found_unlock=1 ;;
        *"git -C"*worktree*remove*) found_remove=1 ;;
        *"git -C"*worktree*prune*)  found_prune=1 ;;
        *"Clean up the slot"*) break ;;
      esac
    fi
  done < "$ppo"
  [ "$found_unlock" = "1" ] || { echo "FAIL: unlock missing -C"; return 1; }
  [ "$found_remove" = "1" ] || { echo "FAIL: remove missing -C"; return 1; }
  [ "$found_prune" = "1" ]  || { echo "FAIL: prune missing -C"; return 1; }
}

# ---------------------------------------------------------------------------
# AC6: session-binding provision_binding_dir post-check
# ---------------------------------------------------------------------------

@test "session-binding: provision_binding_dir detects mkdir failure" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # Create a read-only parent so mkdir -p fails.
  local base="$TEST_TMP/ro-parent"
  mkdir -p "$base/.gaia/state/sessions"
  chmod 000 "$base/.gaia/state/sessions"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    export GAIA_BINDING_DIR=''
    export GAIA_SESSION_ID='test-session-001'
    source '$sb'
    provision_binding_dir --session-id 'test-session-001' --project-root '$base'
  "
  # Restore permissions for cleanup
  chmod 755 "$base/.gaia/state/sessions"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to create binding directory"* ]]
}

@test "session-binding: provision_binding_dir source contains post-check" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # The function must have a [ ! -d ] post-check after mkdir + chmod.
  /usr/bin/grep -A5 'mkdir -p.*derived_dir' "$sb" | /usr/bin/grep -q '\[ ! -d' || {
    echo "FAIL: post-check for directory existence not found after mkdir"
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC8: session-binding length cap on session IDs
# ---------------------------------------------------------------------------

@test "session-binding: rejects session ID over 64 characters" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  # Generate a 200-char session ID
  local long_id
  long_id="$(printf 'a%.0s' $(seq 1 200))"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    source '$sb'
    _sb_validate_session_id '$long_id'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds 64-character limit"* ]]
}

@test "session-binding: accepts session ID at exactly 64 characters" {
  local sb="$SCRIPTS_LIB/session-binding.sh"
  [ -f "$sb" ] || skip "session-binding.sh not found"
  local ok_id
  ok_id="$(printf 'a%.0s' $(seq 1 64))"
  run bash -c "
    set -euo pipefail
    export LC_ALL=C
    source '$sb'
    _sb_validate_session_id '$ok_id'
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC8: independence-check cache refuses symlinked cache files
# ---------------------------------------------------------------------------

@test "independence-check: source contains symlink guard for cache files" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  /usr/bin/grep -q '\[ -L "\$_cache_file" \]' "$ic" || {
    echo "FAIL: symlink guard for cache files not found"
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC8: independence-check inline denylist checks backslash
# ---------------------------------------------------------------------------

@test "independence-check: inline denylist rejects bare backslash" {
  local ic="$SCRIPTS_DIR/independence-check.sh"
  [ -f "$ic" ] || skip "independence-check.sh not found"
  # The inline awk denylist must have a backslash check.
  /usr/bin/grep -q 'index(entry, "\\\\")' "$ic" || {
    echo "FAIL: backslash check not found in inline denylist"
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC8: cost-select-tests.sh rejects leading-zero costs
# ---------------------------------------------------------------------------

@test "cost-select-tests: is_uint rejects leading-zero values" {
  local cs="$BATS_TEST_DIRNAME/../../../.github/scripts/cost-select-tests.sh"
  [ -f "$cs" ] || skip "cost-select-tests.sh not found"
  # Extract is_uint and test it.
  run bash -c "
    set -euo pipefail
    # Source just is_uint
    eval \"\$(sed -n '/^is_uint()/,/^}/p' '$cs')\"
    # 08 must be rejected (octal in bash arithmetic)
    if is_uint '08'; then
      echo 'FAIL: 08 accepted'
      exit 1
    fi
    if is_uint '09'; then
      echo 'FAIL: 09 accepted'
      exit 1
    fi
    if is_uint '007'; then
      echo 'FAIL: 007 accepted'
      exit 1
    fi
    # 0 (bare) must be accepted
    if ! is_uint '0'; then
      echo 'FAIL: bare 0 rejected'
      exit 1
    fi
    # Normal number must be accepted
    if ! is_uint '42'; then
      echo 'FAIL: 42 rejected'
      exit 1
    fi
    echo 'PASS'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "cost-select-tests: awk pattern rejects leading-zero costs in baseline" {
  local cs="$BATS_TEST_DIRNAME/../../../.github/scripts/cost-select-tests.sh"
  [ -f "$cs" ] || skip "cost-select-tests.sh not found"
  # Create a baseline with a leading-zero cost
  local baseline="$TEST_TMP/baseline.tsv"
  printf 'file\twall_seconds\n' > "$baseline"
  printf 'foo.bats\t08\n' >> "$baseline"
  printf 'bar.bats\t5\n' >> "$baseline"
  # Run via a bash wrapper to handle stdin piping.
  run bash -c "printf 'foo.bats\nbar.bats\n' | bash '$cs' '$baseline' 240"
  [ "$status" -eq 0 ]
  # bar.bats with cost 5 should be selected; foo.bats with 08 gets fallback.
  [[ "$output" == *"bar.bats"* ]]
}

# ---------------------------------------------------------------------------
# Byte-identical mirror pairs
# ---------------------------------------------------------------------------

@test "byte-identical: acquire-lock.sh mirrors match" {
  local a="$SCRIPTS_LIB/acquire-lock.sh"
  local b="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/acquire-lock.sh"
  [ -f "$a" ] || skip "scripts/lib/acquire-lock.sh not found"
  [ -f "$b" ] || skip "skills mirror not found"
  diff -q "$a" "$b"
}

@test "byte-identical: session-binding.sh mirrors match" {
  local a="$SCRIPTS_LIB/session-binding.sh"
  local b="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/lib/session-binding.sh"
  [ -f "$a" ] || skip "scripts/lib/session-binding.sh not found"
  [ -f "$b" ] || skip "skills mirror not found"
  diff -q "$a" "$b"
}

# ---------------------------------------------------------------------------
# AC7: no leaked internal identifiers
# ---------------------------------------------------------------------------

@test "no leaked internal identifiers in changed files" {
  # Check each file this story touches for leaked internal IDs.
  local files=(
    "$SCRIPTS_LIB/transcript-writer.sh"
    "$SCRIPTS_LIB/acquire-lock.sh"
    "$SCRIPTS_LIB/session-binding.sh"
    "$SCRIPTS_DIR/independence-check.sh"
    "$SCRIPTS_DIR/phase-parallel-orchestrator.sh"
  )
  local f
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Check for leaked requirement/story/ADR IDs (not in comments about
    # functional regex patterns).
    if /usr/bin/grep -Pn '(?<![_a-zA-Z0-9/.-])(?:FR-|NFR-|SR-|ADR-|TC-|AF-20|AI-20)\d' "$f" 2>/dev/null; then
      echo "FAIL: leaked internal ID found in $f"
      return 1
    fi
  done
}
