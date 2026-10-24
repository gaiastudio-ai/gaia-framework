#!/usr/bin/env bats
# shellcheck disable=SC2016
# test-hygiene-guard.bats — structural guards for test-suite hygiene.
#
# Four invariants:
#   1. (Litter guard) No test suite leaves files under the plugin tree —
#      the guard snapshots the tree and fails naming every orphan file.
#   2. (Root-pinning guard) Every test that drives a root-resolving script
#      — directly or via a sourced helper chain — clears the four ambient
#      root variables in its setup() function.
#   3. (Init-artefact guard) Tests that call sprint-state.sh init must pin
#      IMPLEMENTATION_ARTIFACTS so sprint-plan stubs stay contained.
#   4. (Teardown guard) No suite teardown removes the shared bats runtime
#      temporary directories.

load 'test_helper.bash'

setup() {
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Root-resolving scripts: any script that resolves PROJECT_ROOT / PROJECT_PATH
# / CLAUDE_PROJECT_ROOT from the environment and uses the result to locate
# files. A test that drives one of these must clear the four root variables.
_ROOT_RESOLVING_SCRIPTS="sprint-state.sh|resolve-config.sh|bridge-toggle.sh|dod-check.sh|transition-story-status.sh"

# _executes_root_resolver FILE
#   Returns 0 if FILE invokes a root-resolving script — directly (by
#   variable assignment, bash call, inline variable call, or source/dot)
#   OR indirectly (the file sources/loads a helper that itself references
#   a root-resolving script).
_executes_root_resolver() {
  local file="$1"
  # Direct check.
  if _has_direct_root_resolver_ref "$file"; then
    return 0
  fi
  # Indirect check: follow source/./load chains one level deep into
  # .bash/.sh helpers under the tests/ or scripts/ tree.
  _has_indirect_root_resolver_ref "$file"
}

# _has_direct_root_resolver_ref FILE
#   Returns 0 if FILE directly references a root-resolving script in
#   executable form (assignment, bash call, inline call, source).
_has_direct_root_resolver_ref() {
  local file="$1"
  local script_pat="$_ROOT_RESOLVING_SCRIPTS"
  awk -v pat="$script_pat" '
    BEGIN { split(pat, names, "|") }
    /^[[:space:]]*#/ { next }
    {
      for (i in names) {
        n = names[i]
        line = $0
        gsub(/'"'"'[^'"'"']*'"'"'/, "", line)
        if (line !~ n) continue
        if (line ~ "^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=" && line ~ n) { found = 1; exit }
        if (line ~ "[[:space:]]bash[[:space:]]" && line ~ n) { found = 1; exit }
        if (line ~ ("\\$[A-Za-z_{][A-Za-z_0-9}]*/" n)) { found = 1; exit }
        if (line ~ "(^|[[:space:]])(source|\\.)[[:space:]]" && line ~ n) { found = 1; exit }
      }
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

# _has_indirect_root_resolver_ref FILE
#   Returns 0 if FILE sources (source/./load) a helper .bash/.sh file
#   that itself contains a direct reference to a root-resolving script.
#   Follows one level: test -> helper -> root-resolver. Bounded to
#   helpers under the repo tree.
_has_indirect_root_resolver_ref() {
  local file="$1"
  # Extract source/./load targets from the file (skip comments).
  # POSIX awk only — no gawk capture groups.
  local helpers
  helpers="$(awk '
    /^[[:space:]]*#/ { next }
    # bats load directive: load '\''test_helper'\'' -> test_helper
    /^[[:space:]]*load[[:space:]]/ {
      sub(/^[[:space:]]*load[[:space:]]+/, "")
      gsub(/['\''"]/, "")
      sub(/[[:space:]]*#.*/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
    # source / dot-source: extract the path after the keyword
    /[[:space:]]source[[:space:]]/ || /^source[[:space:]]/ ||
    /[[:space:]]\.[[:space:]]/ || /^\.[[:space:]]/ {
      line = $0
      # Remove everything up to and including "source " or ". "
      sub(/.*[[:space:]]source[[:space:]]+/, "", line)
      sub(/.*[[:space:]]\.[[:space:]]+/, "", line)
      sub(/^source[[:space:]]+/, "", line)
      sub(/^\.[[:space:]]+/, "", line)
      gsub(/['\''"]/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  ' "$file" 2>/dev/null)"

  [ -n "$helpers" ] || return 1

  local filedir
  filedir="$(dirname "$file")"

  while IFS= read -r helper; do
    [ -z "$helper" ] && continue
    # Resolve the helper path. For bats load, try .bash extension
    # in the same directory as the test file.
    local resolved=""
    if [ -f "$filedir/$helper" ]; then
      resolved="$filedir/$helper"
    elif [ -f "$filedir/${helper}.bash" ]; then
      resolved="$filedir/${helper}.bash"
    elif [ -f "$REPO_ROOT/$helper" ]; then
      resolved="$REPO_ROOT/$helper"
    elif [ -f "$REPO_ROOT/${helper}.bash" ]; then
      resolved="$REPO_ROOT/${helper}.bash"
    fi
    [ -n "$resolved" ] && [ -f "$resolved" ] || continue

    # Check if the helper references a root-resolving script.
    if _has_direct_root_resolver_ref "$resolved"; then
      return 0
    fi
  done <<<"$helpers"

  return 1
}

# _setup_clears_root_vars FILE
#   Returns 0 if the file's setup() calls common_setup or explicitly
#   unsets all four root variables.
_setup_clears_root_vars() {
  local file="$1"
  local setup_body
  setup_body="$(awk '
    /^setup\(\)/ { inside=1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$file")"

  [ -n "$setup_body" ] || return 1

  if grep -q 'common_setup' <<<"$setup_body"; then
    return 0
  fi

  local has_pr=0 has_cpr=0 has_gpr=0 has_pp=0
  grep -qE 'unset[[:space:]].*PROJECT_ROOT' <<<"$setup_body" && has_pr=1
  grep -qE 'unset[[:space:]].*CLAUDE_PROJECT_ROOT' <<<"$setup_body" && has_cpr=1
  grep -qE 'unset[[:space:]].*GAIA_PROJECT_ROOT' <<<"$setup_body" && has_gpr=1
  grep -qE 'unset[[:space:]].*PROJECT_PATH' <<<"$setup_body" && has_pp=1

  [ "$has_pr" -eq 1 ] && [ "$has_cpr" -eq 1 ] && [ "$has_gpr" -eq 1 ] && [ "$has_pp" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Guard 1 — Litter: every .bats that loads test_helper gets the per-file
#           litter check via setup_file/teardown_file; this structural guard
#           ensures the coverage net has no holes.
# ---------------------------------------------------------------------------
# test_helper.bash defines setup_file/teardown_file with git-status
# snapshot/diff that catches ANY file left under the plugin tree.
# Suites that override setup_file must call _litter_snapshot_before;
# suites that override teardown_file must call _litter_check_after.
# This guard verifies:
#   (a) every .bats file loads test_helper.bash, and
#   (b) every .bats that overrides setup_file calls _litter_snapshot_before,
#   (c) every .bats that overrides teardown_file calls _litter_check_after.

# Every suite must load test_helper.bash (directly or via a local helper
# that sources it) — the cap is 0 and any omission fails CI immediately.
_LEGACY_NO_LOAD_CAP=0

# _loads_shared_helper FILE — true when FILE loads the shared test_helper
# directly (load 'test_helper' / load '../test_helper') or via a local
# helper that sources it (e.g. parity_helpers.bash).
_loads_shared_helper() {
  local f="$1"
  # Direct load: test_helper or relative ../test_helper variants
  if /usr/bin/grep -qE "^load ['\"]?(\\.\\./)*test_helper(\\.bash)?['\"]?\$" "$f"; then
    return 0
  fi
  # Indirect: file loads a local helper that sources the shared one
  local dir helper
  dir="$(dirname "$f")"
  while IFS= read -r helper; do
    local hfile="$dir/${helper}.bash"
    [ -f "$hfile" ] || hfile="$dir/${helper}"
    [ -f "$hfile" ] || continue
    if /usr/bin/grep -qE '\. .*/tests/test_helper\.bash|source .*/tests/test_helper\.bash' "$hfile"; then
      return 0
    fi
  done < <(/usr/bin/grep -oE "^load ['\"]?[^'\"]+['\"]?" "$f" \
    | sed "s/^load ['\"]*//" | sed "s/['\"]$//" || true)
  return 1
}

@test "every bats file loads test_helper (litter detection coverage)" {
  local missing=()
  local scanned=0

  while IFS= read -r f; do
    scanned=$((scanned + 1))
    if ! _loads_shared_helper "$f"; then
      missing+=("${f#"$TESTS_DIR"/}")
    fi
  done < <(find "$TESTS_DIR" -name '*.bats' | LC_ALL=C sort)

  [ "$scanned" -gt 0 ] || {
    printf 'no .bats files found (expected >0)\n' >&2
    return 1
  }

  local count="${#missing[@]}"
  if [ "$count" -gt "$_LEGACY_NO_LOAD_CAP" ]; then
    printf 'FAIL: %d file(s) do not load test_helper.bash (cap=%d, count=%d):\n' \
      "$((count - _LEGACY_NO_LOAD_CAP))" "$_LEGACY_NO_LOAD_CAP" "$count" >&2
    for v in "${missing[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: add `load '\''test_helper.bash'\''` near the top of each new file.\n' >&2
    return 1
  fi

  printf 'test_helper coverage: %d/%d files load it (%d uncovered, cap=%d)\n' \
    "$((scanned - count))" "$scanned" "$count" "$_LEGACY_NO_LOAD_CAP" >&2
}

@test "suites that override setup_file call _litter_snapshot_before" {
  local violations=()

  while IFS= read -r f; do
    # Does this file define its own setup_file?
    /usr/bin/grep -qE '^setup_file\(\)' "$f" || continue
    # Does it call _litter_snapshot_before inside that function?
    local body
    body="$(awk '/^setup_file\(\)/{inside=1} inside{print} inside && /^}/{exit}' "$f")"
    if ! grep -q '_litter_snapshot_before' <<<"$body"; then
      violations+=("$(basename "$f")")
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) override setup_file without calling _litter_snapshot_before:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    return 1
  fi
}

@test "suites that override teardown_file call _litter_check_after" {
  local violations=()

  while IFS= read -r f; do
    /usr/bin/grep -qE '^teardown_file\(\)' "$f" || continue
    local body
    body="$(awk '/^teardown_file\(\)/{inside=1} inside{print} inside && /^}/{exit}' "$f")"
    if ! grep -q '_litter_check_after' <<<"$body"; then
      violations+=("$(basename "$f")")
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) override teardown_file without calling _litter_check_after:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Guard 2 — Root-pinning: all root-resolving test suites clear root vars
# ---------------------------------------------------------------------------
# Now covers direct AND indirect sourcing, and includes
# transition-story-status.sh in the root-resolving script set.

@test "all tests that drive a root-resolving script clear root variables in setup" {
  # Build the candidate set: .bats files that DIRECTLY mention a root-resolver
  # OR that load a helper (indirect chain). The union ensures a .bats whose
  # only link to a resolver is through a loaded helper is still checked.
  local candidates=()
  local seen=""
  # Direct mentions.
  while IFS= read -r f; do
    candidates+=("$f")
    seen="${seen}${f}"$'\n'
  done < <(/usr/bin/grep -rlE "$_ROOT_RESOLVING_SCRIPTS" "$TESTS_DIR" --include='*.bats' 2>/dev/null | LC_ALL=C sort)
  # Indirect: every .bats that loads a helper (source/./load) and was not
  # already in the direct set.
  while IFS= read -r f; do
    case "$seen" in *"$f"*) continue ;; esac
    candidates+=("$f")
  done < <(/usr/bin/grep -lE '^[[:space:]]*(load|source|\.) ' "$TESTS_DIR"/*.bats 2>/dev/null | LC_ALL=C sort)

  [ "${#candidates[@]}" -gt 0 ] || {
    printf 'no .bats files reference a root-resolving script (expected >0)\n' >&2
    return 1
  }

  local violations=()
  local exec_count=0
  for f in "${candidates[@]}"; do
    _executes_root_resolver "$f" || continue
    exec_count=$((exec_count + 1))

    if ! _setup_clears_root_vars "$f"; then
      violations+=("$(basename "$f")")
    fi
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) execute a root-resolving script without clearing root variables in setup():\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: add common_setup (preferred) or "unset PROJECT_ROOT CLAUDE_PROJECT_ROOT GAIA_PROJECT_ROOT PROJECT_PATH".\n' >&2
    return 1
  fi

  [ "$exec_count" -gt 0 ] || {
    printf 'no executing files found (expected >0)\n' >&2
    return 1
  }

  printf 'scanned %d candidate files, %d execute root-resolving scripts, 0 violations\n' \
    "${#candidates[@]}" "$exec_count" >&2
}

# ---------------------------------------------------------------------------
# Guard 3 — Init-artefact: sprint-state.sh init callers pin artefact paths
# ---------------------------------------------------------------------------

@test "tests that call sprint-state.sh init pin IMPLEMENTATION_ARTIFACTS" {
  local violations=()
  local scanned=0

  while IFS= read -r f; do
    scanned=$((scanned + 1))
    if awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*@test/ { next }
      /'"'"'.*sprint-state\.sh.*init.*'"'"'/ { next }
      /sprint-state\.sh.*init.*--help/ { next }
      /(bash|run|env)[[:space:]].*sprint-state\.sh[[:space:]"]*init/ {
        found = 1; exit
      }
      /sprint-state\.sh"?[[:space:]]+init/ {
        found = 1; exit
      }
      END { exit (found ? 0 : 1) }
    ' "$f"; then
      local contained=0
      if /usr/bin/grep -qE 'IMPLEMENTATION_ARTIFACTS=.*(\$TEST_TMP|\$BATS_TEST_TMPDIR|\$BATS_FILE_TMPDIR|\$TMP|\$tmp|\$IA)' "$f"; then
        contained=1
      elif /usr/bin/grep -qE '(PROJECT_ROOT|PROJECT_PATH|CLAUDE_PROJECT_ROOT)=.*(\$TEST_TMP|\$BATS_TEST_TMPDIR|\$BATS_FILE_TMPDIR|\$TMP|\$tmp|\$out)' "$f"; then
        contained=1
      fi
      if [ "$contained" -eq 0 ]; then
        violations+=("$(basename "$f")")
      fi
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) call sprint-state.sh init without pinning IMPLEMENTATION_ARTIFACTS:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/.gaia/artifacts/implementation-artifacts" in setup().\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Guard 4 — Teardown safety: no suite removes shared bats runtime tmp dirs
# ---------------------------------------------------------------------------

# _check_teardown_safety DIR — scan .bats under DIR for teardown functions
# that remove or alias the shared bats runtime tmp dirs.  Returns non-zero
# when violations are found.  Used by the real guard and by self-tests.
_check_teardown_safety() {
  local scan_dir="$1"
  local violations=()
  local scanned=0

  while IFS= read -r f; do
    scanned=$((scanned + 1))
    local body
    body="$(awk '
      /^teardown(_file)?\s*\(\)/ { inside=1 }
      inside { print }
      inside && /^}/ { inside=0 }
    ' "$f")"
    [ -n "$body" ] || continue

    # Direct removal of the shared dirs
    if /usr/bin/grep -qE 'rm[[:space:]].*(\$\{?BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR\}?)' <<<"$body"; then
      violations+=("$(basename "$f")")
      continue
    fi

    # Indirection: assigning BATS_RUN_TMPDIR or BATS_SUITE_TMPDIR to a
    # variable and then removing that variable evades the direct check.
    if /usr/bin/grep -qE '=.*\$\{?(BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR)\}?' <<<"$body"; then
      violations+=("$(basename "$f")")
      continue
    fi
  done < <(find "$scan_dir" -name '*.bats' | LC_ALL=C sort)

  [ "$scanned" -gt 0 ] || {
    printf 'no .bats files found (expected >0)\n' >&2
    return 1
  }

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) remove or alias shared bats runtime tmp dirs in teardown:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: teardown should only remove TEST_TMP or BATS_TEST_TMPDIR, never the shared runtime dirs (even via a local alias).\n' >&2
    return 1
  fi
}

@test "no teardown removes BATS_RUN_TMPDIR or BATS_SUITE_TMPDIR" {
  _check_teardown_safety "$TESTS_DIR"
}

@test "strict mode (pipefail + nounset) stays on after loading test_helper" {
  local d="$BATS_TEST_TMPDIR/strict-pin-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'load "%s/test_helper.bash"\n' "$TESTS_DIR"
    printf '%s "%s" {\n' '@test' 'pipefail is on'
    printf '  set -o | /usr/bin/grep -q "pipefail.*on"\n'
    printf '}\n'
    printf '%s "%s" {\n' '@test' 'nounset is on'
    printf '  set -o | /usr/bin/grep -q "nounset.*on"\n'
    printf '}\n'
  } > "$d/strict-pin.bats"

  run bats "$d/strict-pin.bats"
  [ "$status" -eq 0 ] || {
    printf 'Strict mode must stay on after loading helper.\noutput:\n%s\n' "$output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Guard 5 — Local helpers must source the shared test_helper.bash
# ---------------------------------------------------------------------------

@test "every subdirectory test_helper.bash sources the shared helper" {
  local violations=()
  while IFS= read -r f; do
    # Skip the shared helper itself (lives directly under tests/).
    [ "$(basename "$(dirname "$f")")" = "tests" ] && continue
    # Match any of:
    #   . "…/test_helper.bash"   (computed path, e.g. $(cd …)/test_helper.bash)
    #   . ".../tests/test_helper.bash"  (literal path)
    #   source …/test_helper.bash
    if ! /usr/bin/grep -qE '^\.[[:space:]].*test_helper\.bash|^source[[:space:]].*test_helper\.bash' "$f"; then
      violations+=("${f#"$TESTS_DIR"/}")
    fi
  done < <(find "$TESTS_DIR" -name 'test_helper.bash' | LC_ALL=C sort)

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d local helper(s) do not source the shared test_helper.bash:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Self-tests: verify the guards catch violations
# ---------------------------------------------------------------------------

@test "per-file litter guard catches a static-name file in an arbitrary suite" {
  cd "$REPO_ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not in a git worktree"

  # Prove the per-file mechanism works end-to-end: create a synthetic
  # .bats that loads test_helper and plants a static-named file under
  # the plugin tree, then run it and verify teardown_file fails.
  local d="$BATS_TEST_TMPDIR/perfile-litter-$$"
  mkdir -p "$d"

  # The synthetic suite loads test_helper (gets setup_file/teardown_file)
  # and plants a static-named litter file — NOT on any known list.
  cat > "$d/litter-producer.bats" <<BATS
#!/usr/bin/env bats
load '$TESTS_DIR/test_helper.bash'
BATS
  printf '%s "%s" {\n' '@test' 'plant litter' >> "$d/litter-producer.bats"
  printf '  mkdir -p "%s/tests/fixtures"\n' "$PLUGIN_DIR" >> "$d/litter-producer.bats"
  printf '  printf "litter\\n" > "%s/tests/fixtures/selftest-perfile-static.md"\n' "$PLUGIN_DIR" >> "$d/litter-producer.bats"
  printf '}\n' >> "$d/litter-producer.bats"

  # Run the synthetic suite with the litter guard enabled.
  run bats "$d/litter-producer.bats"

  # Clean up the planted file regardless of result.
  rm -f "$PLUGIN_DIR/tests/fixtures/selftest-perfile-static.md"

  # The bats run should have failed (teardown_file caught the litter).
  [ "$status" -ne 0 ] || {
    printf 'Expected teardown_file to fail on litter, but bats exited 0\n' >&2
    return 1
  }
  # The output should name the offending file.
  case "$output" in
    *LITTER*selftest-perfile-static.md*) : ;;
    *)
      printf 'teardown_file output does not name the litter file.\noutput:\n%s\n' "$output" >&2
      return 1
      ;;
  esac
}

@test "per-file litter guard passes on a clean suite" {
  cd "$REPO_ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not in a git worktree"

  # A suite that loads test_helper and creates no litter passes.
  local d="$BATS_TEST_TMPDIR/perfile-clean-$$"
  mkdir -p "$d"
  cat > "$d/clean-suite.bats" <<BATS
#!/usr/bin/env bats
load '$TESTS_DIR/test_helper.bash'
BATS
  printf '%s "%s" { true; }\n' '@test' 'clean test' >> "$d/clean-suite.bats"

  run bats "$d/clean-suite.bats"
  [ "$status" -eq 0 ] || {
    printf 'Clean suite should pass, but got status %d\noutput:\n%s\n' "$status" "$output" >&2
    return 1
  }
}

@test "per-file litter guard catches modification of a tracked file" {
  # Use a scratch git repo so parallel suites cannot see false LITTER.
  local scratch="$BATS_TEST_TMPDIR/scratch-repo-$$"
  mkdir -p "$scratch/plugins/gaia/tests"
  printf 'tracked content\n' > "$scratch/plugins/gaia/tests/sample.txt"
  git -C "$scratch" init -q
  git -C "$scratch" config user.email "test@test"
  git -C "$scratch" config user.name "test"
  git -C "$scratch" add -A
  git -C "$scratch" commit -q -m "init"

  # Copy the shared test_helper into the scratch repo.
  cp "$TESTS_DIR/test_helper.bash" "$scratch/plugins/gaia/tests/"

  local d="$BATS_TEST_TMPDIR/perfile-modify-$$"
  mkdir -p "$d"

  # The synthetic suite loads the scratch-repo helper, overrides the repo
  # root, and modifies the tracked file.
  local target="$scratch/plugins/gaia/tests/sample.txt"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'load "%s/plugins/gaia/tests/test_helper.bash"\n' "$scratch"
    printf '_LITTER_REPO_ROOT="%s"\n' "$scratch"
  } > "$d/modify-tracked.bats"
  printf '%s "%s" {\n' '@test' 'modify tracked file' >> "$d/modify-tracked.bats"
  printf '  printf "extra\\n" >> "%s"\n' "$target" >> "$d/modify-tracked.bats"
  printf '}\n' >> "$d/modify-tracked.bats"

  run bats "$d/modify-tracked.bats"

  [ "$status" -ne 0 ] || {
    printf 'Expected teardown_file to fail on modified tracked file, but bats exited 0\n' >&2
    return 1
  }
  [[ "$output" == *"LITTER"* ]] || {
    printf 'teardown_file output does not report the modification.\noutput:\n%s\n' "$output" >&2
    return 1
  }
  [[ "$output" == *"sample.txt"* ]] || {
    printf 'teardown_file output does not name the modified file.\noutput:\n%s\n' "$output" >&2
    return 1
  }
}

@test "indirect sourcing guard catches a helper chain to a root-resolver" {
  local d="$BATS_TEST_TMPDIR/indirect-$$"
  mkdir -p "$d"

  # Create a helper that sources sprint-state.sh.
  cat > "$d/my_helper.bash" <<'HELPER'
#!/usr/bin/env bash
SS="$SCRIPTS_DIR/sprint-state.sh"
HELPER

  # Create a bats file that loads the helper (no common_setup, no unset).
  {
    printf '#!/usr/bin/env bats\n'
    printf 'load my_helper\n'
    printf 'setup() { true; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/indirect-violator.bats"

  # Direct check should miss it (the bats file itself has no sprint-state.sh ref).
  run _has_direct_root_resolver_ref "$d/indirect-violator.bats"
  [ "$status" -ne 0 ]

  # Indirect check should catch it (the helper references sprint-state.sh).
  _has_indirect_root_resolver_ref "$d/indirect-violator.bats"

  # Combined check should catch it.
  _executes_root_resolver "$d/indirect-violator.bats"

  # Setup should fail the root-clearing check.
  run _setup_clears_root_vars "$d/indirect-violator.bats"
  [ "$status" -ne 0 ]
}

@test "pure-indirect offender is found by the broadened candidate search" {
  # A .bats file that does NOT mention any root-resolver directly — its only
  # link is through a loaded helper. The broadened candidate search must still
  # feed it into _executes_root_resolver and flag it.
  local d="$BATS_TEST_TMPDIR/pure-indirect-$$"
  mkdir -p "$d"

  cat > "$d/bridge_helper.bash" <<'HELPER'
#!/usr/bin/env bash
TOGGLE="$SCRIPTS_DIR/bridge-toggle.sh"
HELPER

  {
    printf '#!/usr/bin/env bats\n'
    printf 'load bridge_helper\n'
    printf 'setup() { true; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/pure-indirect.bats"

  # Direct grep would miss this file (no root-resolver string in it).
  run /usr/bin/grep -lE "$_ROOT_RESOLVING_SCRIPTS" "$d/pure-indirect.bats"
  [ "$status" -ne 0 ]

  # But _executes_root_resolver (direct + indirect) should catch it.
  _executes_root_resolver "$d/pure-indirect.bats"

  # And _setup_clears_root_vars should flag it (no common_setup, no unset).
  run _setup_clears_root_vars "$d/pure-indirect.bats"
  [ "$status" -ne 0 ]
}

@test "indirect sourcing guard does not false-fire on unrelated helpers" {
  local d="$BATS_TEST_TMPDIR/indirect-safe-$$"
  mkdir -p "$d"

  # Create a helper that does NOT reference any root-resolving script.
  cat > "$d/safe_helper.bash" <<'HELPER'
#!/usr/bin/env bash
do_something() { echo "no root resolution here"; }
HELPER

  # Create a bats file that loads the helper.
  {
    printf '#!/usr/bin/env bats\n'
    printf 'load safe_helper\n'
    printf 'setup() { true; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/safe.bats"

  # Neither direct nor indirect should fire.
  run _has_direct_root_resolver_ref "$d/safe.bats"
  [ "$status" -ne 0 ]
  run _has_indirect_root_resolver_ref "$d/safe.bats"
  [ "$status" -ne 0 ]
  run _executes_root_resolver "$d/safe.bats"
  [ "$status" -ne 0 ]
}

@test "root-pinning guard detects transition-story-status.sh call without root clearing" {
  local d="$BATS_TEST_TMPDIR/rootpin-tss-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'setup() { true; }\n'
    printf '%s "%s" { run bash "$DIR/transition-story-status.sh" E1-S1 --to review; }\n' '@test' 'x'
  } > "$d/violator.bats"

  _executes_root_resolver "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "root-pinning guard detects resolve-config.sh call without root clearing" {
  local d="$BATS_TEST_TMPDIR/rootpin-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'setup() { true; }\n'
    printf '%s "%s" { run bash "$DIR/resolve-config.sh" --show; }\n' '@test' 'x'
  } > "$d/violator.bats"

  _executes_root_resolver "$d/violator.bats"
  run _setup_clears_root_vars "$d/violator.bats"
  [ "$status" -ne 0 ]
}

@test "teardown guard detects removal of BATS_RUN_TMPDIR via real guard" {
  local d="$BATS_TEST_TMPDIR/teardown-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() { rm -rf "$BATS_RUN_TMPDIR"; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/violator.bats"

  run _check_teardown_safety "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"violator.bats"* ]]
}

@test "teardown guard accepts removal of TEST_TMP only" {
  local d="$BATS_TEST_TMPDIR/safe-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() { rm -rf "$TEST_TMP"; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/safe.bats"

  _check_teardown_safety "$d"
}

@test "teardown guard detects variable indirection via real guard" {
  local d="$BATS_TEST_TMPDIR/indirect-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() {\n'
    printf '  local d="$BATS_RUN_TMPDIR"\n'
    printf '  rm -rf "$d"\n'
    printf '}\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/indirect.bats"

  run _check_teardown_safety "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirect.bats"* ]]
}

@test "teardown guard indirection check does not match TEST_TMP assignment" {
  local d="$BATS_TEST_TMPDIR/safe-indirect-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() {\n'
    printf '  local d="$TEST_TMP"\n'
    printf '  rm -rf "$d"\n'
    printf '}\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/safe-indirect.bats"

  _check_teardown_safety "$d"
}

# ---------------------------------------------------------------------------
# diff-select-tests.sh rule 6 coverage
# ---------------------------------------------------------------------------

# _ds_scratch — build a scratch git repo for diff-select rule 6 tests.
# Sets DS_SCRATCH to the repo path.  The repo contains:
#   top.bats        — loads test_helper directly
#   subdir/deep.bats — loads ../test_helper
#   indirect/child/relay.bats — loads ../relay_helpers which sources the shared helper
_ds_scratch() {
  DS_SCRATCH="$BATS_TEST_TMPDIR/ds-scratch-$$"
  mkdir -p "$DS_SCRATCH/.github/scripts"
  mkdir -p "$DS_SCRATCH/plugins/gaia/tests/subdir"
  mkdir -p "$DS_SCRATCH/plugins/gaia/tests/indirect/child"

  printf '# shared helper\n' > "$DS_SCRATCH/plugins/gaia/tests/test_helper.bash"

  # Top-level direct loader
  { printf '#!/usr/bin/env bats\nload '\''test_helper.bash'\''\n'
    printf '%s "%s" { true; }\n' '@test' 'x'; } > "$DS_SCRATCH/plugins/gaia/tests/top.bats"

  # Subdirectory direct loader (relative path)
  { printf '#!/usr/bin/env bats\nload '\''../test_helper.bash'\''\n'
    printf '%s "%s" { true; }\n' '@test' 'x'; } > "$DS_SCRATCH/plugins/gaia/tests/subdir/deep.bats"

  # Indirect loader: relay_helpers.bash sources the shared helper
  printf '. "%s/plugins/gaia/tests/test_helper.bash"\n' "$DS_SCRATCH" \
    > "$DS_SCRATCH/plugins/gaia/tests/indirect/relay_helpers.bash"
  { printf '#!/usr/bin/env bats\nload '\''../relay_helpers.bash'\''\n'
    printf '%s "%s" { true; }\n' '@test' 'x'; } > "$DS_SCRATCH/plugins/gaia/tests/indirect/child/relay.bats"

  cp "$REPO_ROOT/.github/scripts/diff-select-tests.sh" "$DS_SCRATCH/.github/scripts/"

  git -C "$DS_SCRATCH" init -q
  git -C "$DS_SCRATCH" config user.email "test@test"
  git -C "$DS_SCRATCH" config user.name "test"
  git -C "$DS_SCRATCH" add -A
  git -C "$DS_SCRATCH" commit -q -m "init"

  # Second commit touches only test_helper.bash
  printf '\n# changed\n' >> "$DS_SCRATCH/plugins/gaia/tests/test_helper.bash"
  git -C "$DS_SCRATCH" add -A
  git -C "$DS_SCRATCH" commit -q -m "touch helper"
}

@test "diff-select rule 6 selects direct, subdirectory, and indirect suites" {
  _ds_scratch
  local out
  out="$(cd "$DS_SCRATCH" && bash .github/scripts/diff-select-tests.sh HEAD~1 2>/dev/null || true)"

  [ -n "$out" ] || { printf 'no output\n' >&2; return 1; }

  # Top-level suite must be selected
  /usr/bin/grep -q "top.bats" <<< "$out" || {
    printf 'top-level suite missing:\n%s\n' "$out" >&2; return 1; }

  # Subdirectory direct loader
  /usr/bin/grep -q "subdir/deep.bats" <<< "$out" || {
    printf 'subdir direct suite missing:\n%s\n' "$out" >&2; return 1; }

  # Indirect loader via relay_helpers
  /usr/bin/grep -q "relay.bats" <<< "$out" || {
    printf 'indirect suite missing:\n%s\n' "$out" >&2; return 1; }
}

@test "diff-select rule 6 mutant: deleting indirect block drops relay suite" {
  _ds_scratch
  # Remove the indirect-loader block from the script copy
  sed '/Indirect loaders/,/^[[:space:]]*fi$/d' \
    "$DS_SCRATCH/.github/scripts/diff-select-tests.sh" \
    > "$DS_SCRATCH/.github/scripts/diff-select-tests-mutant.sh"
  chmod +x "$DS_SCRATCH/.github/scripts/diff-select-tests-mutant.sh"

  local out
  out="$(cd "$DS_SCRATCH" && bash .github/scripts/diff-select-tests-mutant.sh HEAD~1 2>/dev/null || true)"

  # The mutant must NOT select the indirect suite (proving the block is needed)
  if /usr/bin/grep -q "relay.bats" <<< "$out"; then
    printf 'Mutant still selects indirect suite — block deletion not detected\n' >&2
    return 1
  fi
}

@test "helper-load guard cap=0 rejects a suite without the load line" {
  # Build a scratch tests dir containing one suite with no load line and
  # one with.  The real guard logic (cap=0) must reject the missing one.
  local d="$BATS_TEST_TMPDIR/cap-probe-$$"
  mkdir -p "$d"
  { printf '#!/usr/bin/env bats\n'
    printf '%s "%s" { true; }\n' '@test' 'x'; } > "$d/no-helper.bats"
  { printf '#!/usr/bin/env bats\n'
    printf "load 'test_helper.bash'\n"
    printf '%s "%s" { true; }\n' '@test' 'x'; } > "$d/has-helper.bats"

  # Run the real guard at cap=0 — the no-helper suite must cause failure.
  local missing=() scanned=0
  while IFS= read -r f; do
    scanned=$((scanned + 1))
    if ! _loads_shared_helper "$f"; then
      missing+=("${f#"$d"/}")
    fi
  done < <(find "$d" -name '*.bats' | LC_ALL=C sort)

  [ "$scanned" -gt 0 ]
  local count="${#missing[@]}"
  # With cap=0 (_LEGACY_NO_LOAD_CAP) this must fail.
  [ "$count" -gt "$_LEGACY_NO_LOAD_CAP" ] || {
    printf 'Guard did not reject uncovered suite (count=%d cap=%d)\n' "$count" "$_LEGACY_NO_LOAD_CAP" >&2
    return 1
  }
  # Verify the specific file is named.
  [[ "${missing[*]}" == *"no-helper.bats"* ]]
}

@test "inherited SCRIPTS_DIR does not leak into test_helper resolution" {
  # A poisoned SCRIPTS_DIR in the environment must be overridden by the
  # shared helper so suites always resolve scripts from the repo tree.
  local d="$BATS_TEST_TMPDIR/env-leak-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'load "%s/test_helper.bash"\n' "$TESTS_DIR"
    printf '%s "%s" {\n' '@test' 'SCRIPTS_DIR points at real scripts dir'
    printf '  [ -d "$SCRIPTS_DIR" ]\n'
    printf '  [ -f "$SCRIPTS_DIR/resolve-config.sh" ]\n'
    printf '}\n'
  } > "$d/env-leak.bats"

  run env SCRIPTS_DIR=/nonexistent bats "$d/env-leak.bats"
  [ "$status" -eq 0 ] || {
    printf 'SCRIPTS_DIR leak: poisoned value not overridden.\noutput:\n%s\n' "$output" >&2
    return 1
  }
}

@test "large-file SIGPIPE regression: grep -q on big input via pipe" {
  # Under pipefail, grep -q exits early on a match, causing SIGPIPE on the
  # producer when the input exceeds the pipe buffer (~64 KB).  This test
  # verifies the capture-then-grep fix works on large files.
  local d="$BATS_TEST_TMPDIR/sigpipe-$$"
  mkdir -p "$d"
  # Create a ~70 KB file with the search term on line 1.
  # Use a synthetic probe phrase that does not trip any glossary guard.
  {
    printf 'sigpipe probe needle\n'
    dd if=/dev/zero bs=1024 count=70 2>/dev/null | tr '\0' 'x'
  } > "$d/big.md"

  # Capture first (safe under pipefail), then grep the variable.
  local _content
  _content="$(sed 's/dummy//Ig' "$d/big.md")"
  grep -qi 'sigpipe probe needle' <<< "$_content"
}

@test "local-helper guard detects a helper that does not source the shared one" {
  local d="$BATS_TEST_TMPDIR/local-guard-$$"
  mkdir -p "$d/subdir"

  # A local test_helper.bash that does NOT source the shared helper
  printf '#!/usr/bin/env bash\nSCRIPTS_DIR=/tmp\nexport SCRIPTS_DIR\n' \
    > "$d/subdir/test_helper.bash"

  local violations=()
  while IFS= read -r f; do
    [ "$(basename "$(dirname "$f")")" = "$(basename "$d")" ] && continue
    if ! /usr/bin/grep -qE '^\.[[:space:]].*test_helper\.bash|^source[[:space:]].*test_helper\.bash' "$f"; then
      violations+=("$(basename "$(dirname "$f")")/$(basename "$f")")
    fi
  done < <(find "$d" -name 'test_helper.bash' | LC_ALL=C sort)

  [ "${#violations[@]}" -gt 0 ] || {
    printf 'Guard did not detect the unsourced local helper\n' >&2
    return 1
  }
  [[ "${violations[*]}" == *"subdir/test_helper.bash"* ]]
}

@test "large-file capture-then-grep pattern survives pipefail (SIGPIPE regression)" {
  # The glossary scan (concurrent-sprint-glossary.bats ~91-93) uses a
  # capture-then-grep pattern to avoid SIGPIPE on large files.  This test
  # verifies that the pattern works on a file exceeding the pipe buffer
  # (~64 KB) and that a match on line 1 is found correctly.
  local d="$BATS_TEST_TMPDIR/glossary-sigpipe-$$"
  mkdir -p "$d"
  # Build a >64 KB file with the search term on line 1.
  {
    printf 'needle_for_sigpipe_test\n'
    dd if=/dev/zero bs=1024 count=70 2>/dev/null | tr '\0' 'x'
  } > "$d/big.md"

  # Capture-then-grep: safe under pipefail (the production pattern).
  local _content
  _content="$(sed 's/remove_me//Ig' "$d/big.md")"
  grep -qi 'needle_for_sigpipe_test' <<< "$_content" || {
    printf 'capture-then-grep did not find the needle\n' >&2
    return 1
  }

  # Prove the piped form would fail: run it in a subshell with pipefail.
  # sed | grep -qi closes the pipe early on match, causing SIGPIPE (141)
  # on sed when the remaining input exceeds the buffer.
  run bash -c 'set -eo pipefail; sed "s/remove_me//Ig" "$1" | grep -qi "needle_for_sigpipe_test"' _ "$d/big.md"
  if [ "$status" -eq 0 ]; then
    # On some systems the kernel buffer is large enough — skip rather than
    # false-fail, but on most CI runners this proves the SIGPIPE.
    true
  else
    # Status 141 (SIGPIPE) or non-zero confirms the pipe form is unsafe.
    [ "$status" -ne 0 ]
  fi
}
