#!/usr/bin/env bats
# sprint-state-root-isolation-lint.bats
#
# Repo-wide lint: every .bats file that executes sprint-state.sh must
# clear the ambient root variables (PROJECT_ROOT, CLAUDE_PROJECT_ROOT,
# GAIA_PROJECT_ROOT) in its setup() function — either via common_setup
# (the shared test helper) or an explicit unset.
#
# Without this, a caller's real project tree can be silently mutated when
# bats inherits PROJECT_ROOT or CLAUDE_PROJECT_ROOT from the environment.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
}

# _executes_sprint_state FILE
#   Returns 0 if the file assigns a variable to a sprint-state.sh path
#   (the reliable signal that the file will invoke the script).
#   Returns 1 otherwise (reference is in a comment, string literal, or
#   argument to another command).
_executes_sprint_state() {
  local file="$1"
  # Match bare variable assignments whose value ends in sprint-state.sh,
  # excluding lines inside single-quoted strings (e.g. body='...').
  # The pattern: start of line (optional whitespace), VARNAME=, then a
  # value containing sprint-state.sh that is NOT enclosed in single quotes.
  awk '
    /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=/ && /sprint-state\.sh/ {
      # Skip if the RHS is inside single quotes (fixture bodies)
      if ($0 ~ /='"'"'.*sprint-state\.sh.*'"'"'/) next
      found = 1
      exit
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

# _setup_clears_root_vars FILE
#   Returns 0 if the file's setup() function calls common_setup or
#   explicitly unsets the three root variables.
_setup_clears_root_vars() {
  local file="$1"
  # Extract the setup() function body (from "setup() {" to the matching "}")
  local setup_body
  setup_body="$(awk '
    /^setup\(\)/ { inside=1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$file")"

  [ -n "$setup_body" ] || return 1

  # Accept common_setup (the shared helper already clears the root vars)
  if grep -q 'common_setup' <<<"$setup_body"; then
    return 0
  fi

  # Accept explicit unset of at least PROJECT_ROOT and CLAUDE_PROJECT_ROOT
  # (GAIA_PROJECT_ROOT is also required for full isolation)
  local has_project_root=0 has_claude_root=0 has_gaia_root=0
  if grep -qE 'unset[[:space:]].*PROJECT_ROOT' <<<"$setup_body"; then
    has_project_root=1
  fi
  if grep -qE 'unset[[:space:]].*CLAUDE_PROJECT_ROOT' <<<"$setup_body"; then
    has_claude_root=1
  fi
  if grep -qE 'unset[[:space:]].*GAIA_PROJECT_ROOT' <<<"$setup_body"; then
    has_gaia_root=1
  fi

  [ "$has_project_root" -eq 1 ] && [ "$has_claude_root" -eq 1 ] && [ "$has_gaia_root" -eq 1 ]
}

@test "all bats files that execute sprint-state.sh clear root variables in setup()" {
  # Collect candidate files: any .bats under tests/ referencing sprint-state.sh
  local candidates=()
  while IFS= read -r f; do
    candidates+=("$f")
  done < <(/usr/bin/grep -rl 'sprint-state\.sh' "$TESTS_DIR" --include='*.bats' 2>/dev/null | LC_ALL=C sort)

  [ "${#candidates[@]}" -gt 0 ] || {
    printf 'no .bats files reference sprint-state.sh (expected >0)\n' >&2
    return 1
  }

  local violations=()
  for f in "${candidates[@]}"; do
    # Skip files that merely reference sprint-state.sh without executing it
    _executes_sprint_state "$f" || continue

    if ! _setup_clears_root_vars "$f"; then
      violations+=("$(basename "$f")")
    fi
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) execute sprint-state.sh without clearing root variables in setup():\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: add "unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT" to setup(),\n' >&2
    printf 'or call common_setup which handles root variable clearing.\n' >&2
    return 1
  fi

  # Report scan statistics
  local exec_count=0
  for f in "${candidates[@]}"; do
    _executes_sprint_state "$f" && exec_count=$((exec_count + 1))
  done
  printf 'scanned %d candidate files, %d execute sprint-state.sh, 0 violations\n' \
    "${#candidates[@]}" "$exec_count"
}
