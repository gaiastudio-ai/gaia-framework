#!/usr/bin/env bats
# sprint-state-root-isolation-lint.bats
#
# Repo-wide lint: every .bats file that executes sprint-state.sh must
# clear the four ambient root variables (PROJECT_ROOT, CLAUDE_PROJECT_ROOT,
# GAIA_PROJECT_ROOT, PROJECT_PATH) in its setup() function — either via
# common_setup (the shared test helper) or an explicit unset.
#
# Without this, a caller's real project tree can be silently mutated when
# bats inherits any of these variables from the environment.

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
}

# _executes_sprint_state FILE
#   Returns 0 if the file sources, invokes, or assigns a variable to
#   sprint-state.sh. Catches:
#     - variable assignment:  SS="$DIR/sprint-state.sh"
#     - direct bash call:     bash .../sprint-state.sh  or  run bash .../sprint-state.sh
#     - inline call:          "$VAR/sprint-state.sh" get
#     - source / dot:         source .../sprint-state.sh  or  . .../sprint-state.sh
#   Skips references that are purely in comments or single-quoted strings
#   (e.g. body='@test ... sprint-state.sh').
_executes_sprint_state() {
  local file="$1"
  awk '
    # Skip comment-only lines
    /^[[:space:]]*#/ { next }

    # Skip lines where sprint-state.sh is entirely inside single quotes
    # (fixture bodies like body='"'"'...sprint-state.sh...'"'"')
    {
      line = $0
      # Remove all single-quoted segments to see if sprint-state.sh remains
      gsub(/'"'"'[^'"'"']*'"'"'/, "", line)
      if (line !~ /sprint-state\.sh/) next
    }

    # Form 1: variable assignment  VARNAME="...sprint-state.sh"
    /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=/ && /sprint-state\.sh/ {
      found = 1; exit
    }

    # Form 2: bash/run invocation  bash .../sprint-state.sh  or  run bash .../sprint-state.sh
    /[[:space:]]bash[[:space:]]/ && /sprint-state\.sh/ {
      found = 1; exit
    }

    # Form 3: inline call via variable  "$VAR/sprint-state.sh" subcmd
    # The variable expansion must immediately precede /sprint-state.sh
    # (the script is the command, not an argument to another command).
    /\$[A-Za-z_{][A-Za-z_0-9}]*\/sprint-state\.sh/ {
      found = 1; exit
    }

    # Form 4: source / dot-source
    /(^|[[:space:]])(source|\.)([[:space:]])/ && /sprint-state\.sh/ {
      found = 1; exit
    }

    END { exit (found ? 0 : 1) }
  ' "$file"
}

# _setup_clears_root_vars FILE
#   Returns 0 if the file's setup() function calls common_setup or
#   explicitly unsets all four root variables.
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

  # Accept common_setup (the shared helper clears all four root vars)
  if grep -q 'common_setup' <<<"$setup_body"; then
    return 0
  fi

  # Accept explicit unset of all four root variables
  local has_pr=0 has_cpr=0 has_gpr=0 has_pp=0
  if grep -qE 'unset[[:space:]].*PROJECT_ROOT' <<<"$setup_body"; then
    has_pr=1
  fi
  if grep -qE 'unset[[:space:]].*CLAUDE_PROJECT_ROOT' <<<"$setup_body"; then
    has_cpr=1
  fi
  if grep -qE 'unset[[:space:]].*GAIA_PROJECT_ROOT' <<<"$setup_body"; then
    has_gpr=1
  fi
  if grep -qE 'unset[[:space:]].*PROJECT_PATH' <<<"$setup_body"; then
    has_pp=1
  fi

  [ "$has_pr" -eq 1 ] && [ "$has_cpr" -eq 1 ] && [ "$has_gpr" -eq 1 ] && [ "$has_pp" -eq 1 ]
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
  local exec_count=0
  for f in "${candidates[@]}"; do
    # Skip files that merely reference sprint-state.sh without executing it
    _executes_sprint_state "$f" || continue
    exec_count=$((exec_count + 1))

    if ! _setup_clears_root_vars "$f"; then
      violations+=("$(basename "$f")")
    fi
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) execute sprint-state.sh without clearing root variables in setup():\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: add "unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH"\n' >&2
    printf 'to setup(), or call common_setup which handles root variable clearing.\n' >&2
    return 1
  fi

  [ "$exec_count" -gt 0 ] || {
    printf 'no executing files found (expected >0)\n' >&2
    return 1
  }

  printf 'scanned %d candidate files, %d execute sprint-state.sh, 0 violations\n' \
    "${#candidates[@]}" "$exec_count" >&2
}

# ---------- self-tests: synthetic fixtures in tmpdir ----------

# _make_fixture DIR NAME SETUP_BODY TEST_BODY
#   Writes a synthetic .bats file. The @test line is assembled from parts
#   so that no literal '@test' appears at column 0 in THIS source file —
#   bats' preprocessor counts every column-0 '@test' toward the TAP plan,
#   which inflates the expected count and causes a plan-mismatch failure.
_make_fixture() {
  local dir="$1" name="$2" setup_body="$3" test_body="$4"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'setup() {\n%s\n}\n' "$setup_body"
    # shellcheck disable=SC2016
    printf '%s "%s" { %s; }\n' '@test' 'x' "$test_body"
  } > "$dir/$name"
}

@test "lint detects Form 1 (variable assignment) without root clearing" {
  local d="$BATS_TEST_TMPDIR/form1-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "violator.bats" \
    '  SS="$REPO_ROOT/plugins/gaia/scripts/sprint-state.sh"' 'true'
  _executes_sprint_state "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "lint detects Form 2 (bash invocation) without root clearing" {
  local d="$BATS_TEST_TMPDIR/form2-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "violator.bats" \
    '  REPO_ROOT="$(pwd)"' 'run bash "$REPO_ROOT/scripts/sprint-state.sh" init'
  _executes_sprint_state "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "lint detects Form 3 (inline variable call) without root clearing" {
  local d="$BATS_TEST_TMPDIR/form3-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "violator.bats" \
    '  SCRIPTS_DIR="$(pwd)/scripts"' 'run "$SCRIPTS_DIR/sprint-state.sh" get --story S1'
  _executes_sprint_state "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "lint detects Form 4 (source) without root clearing" {
  local d="$BATS_TEST_TMPDIR/form4-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "violator.bats" \
    '  true' 'source "$DIR/sprint-state.sh"'
  _executes_sprint_state "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "lint accepts common_setup as sufficient isolation" {
  local d="$BATS_TEST_TMPDIR/common-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "compliant.bats" \
    '  common_setup
  SS="$REPO_ROOT/scripts/sprint-state.sh"' 'true'
  _executes_sprint_state "$d/compliant.bats"
  _setup_clears_root_vars "$d/compliant.bats"
}

@test "lint accepts explicit unset of all four root variables" {
  local d="$BATS_TEST_TMPDIR/explicit-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "compliant.bats" \
    '  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  SS="$REPO_ROOT/scripts/sprint-state.sh"' 'true'
  _executes_sprint_state "$d/compliant.bats"
  _setup_clears_root_vars "$d/compliant.bats"
}

@test "lint flags partial unset (missing PROJECT_PATH)" {
  local d="$BATS_TEST_TMPDIR/partial-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "partial.bats" \
    '  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT
  SS="$REPO_ROOT/scripts/sprint-state.sh"' 'true'
  _executes_sprint_state "$d/partial.bats"
  run _setup_clears_root_vars "$d/partial.bats"
  [ "$status" -ne 0 ]
}

@test "lint flags partial unset (missing GAIA_PROJECT_ROOT)" {
  local d="$BATS_TEST_TMPDIR/partial2-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "partial.bats" \
    '  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH
  SS="$REPO_ROOT/scripts/sprint-state.sh"' 'true'
  _executes_sprint_state "$d/partial.bats"
  run _setup_clears_root_vars "$d/partial.bats"
  [ "$status" -ne 0 ]
}

@test "lint ignores sprint-state.sh in comments" {
  local d="$BATS_TEST_TMPDIR/comment-$$"
  mkdir -p "$d"
  _make_fixture "$d" "commented.bats" \
    '  true' 'true'
  # Inject a comment referencing sprint-state.sh (not via _make_fixture)
  sed -i '' '1a\
# This file mentions sprint-state.sh only in comments' "$d/commented.bats"
  run _executes_sprint_state "$d/commented.bats"
  [ "$status" -ne 0 ]
}

@test "lint ignores sprint-state.sh passed as argument (not as command)" {
  local d="$BATS_TEST_TMPDIR/argonly-$$"
  mkdir -p "$d"
  # shellcheck disable=SC2016
  _make_fixture "$d" "argonly.bats" \
    '  true' 'run "$DETECT" --files plugins/gaia/scripts/sprint-state.sh'
  run _executes_sprint_state "$d/argonly.bats"
  [ "$status" -ne 0 ]
}
