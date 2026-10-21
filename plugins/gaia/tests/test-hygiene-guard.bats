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

# 159 pre-existing suites do not load test_helper.bash. Those suites predate
# this guard and are a documented gap (filed as a Finding). The guard ensures
# the gap does not GROW: any new .bats file must load test_helper.bash.
_LEGACY_NO_LOAD_CAP=159

@test "no new bats file omits test_helper (litter detection coverage)" {
  local missing=()
  local scanned=0

  while IFS= read -r f; do
    scanned=$((scanned + 1))
    if ! /usr/bin/grep -qE "^load ['\"]?test_helper" "$f"; then
      missing+=("$(basename "$f")")
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)

  [ "$scanned" -gt 0 ] || {
    printf 'no .bats files found (expected >0)\n' >&2
    return 1
  }

  local count="${#missing[@]}"
  if [ "$count" -gt "$_LEGACY_NO_LOAD_CAP" ]; then
    # Only show the files ABOVE the cap (the new violators).
    printf 'FAIL: %d file(s) do not load test_helper.bash (cap=%d, count=%d — new files added without test_helper):\n' \
      "$((count - _LEGACY_NO_LOAD_CAP))" "$_LEGACY_NO_LOAD_CAP" "$count" >&2
    # Print the last N entries (newest = most likely the new ones).
    local i=0
    for v in "${missing[@]}"; do
      i=$((i + 1))
      [ "$i" -gt "$_LEGACY_NO_LOAD_CAP" ] && printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: add `load '\''test_helper.bash'\''` near the top of each new file.\n' >&2
    return 1
  fi

  printf 'test_helper coverage: %d/%d files load it (%d legacy gap, cap=%d)\n' \
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

@test "no teardown removes BATS_RUN_TMPDIR or BATS_SUITE_TMPDIR" {
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

    if /usr/bin/grep -qE 'rm[[:space:]].*(\$\{?BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR\}?)' <<<"$body"; then
      violations+=("$(basename "$f")")
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)

  [ "$scanned" -gt 0 ] || {
    printf 'no .bats files found (expected >0)\n' >&2
    return 1
  }

  if [ "${#violations[@]}" -gt 0 ]; then
    printf 'FAIL: %d file(s) remove shared bats runtime tmp dirs in teardown:\n' "${#violations[@]}" >&2
    for v in "${violations[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf '\nFix: teardown should only remove TEST_TMP or BATS_TEST_TMPDIR, never the shared runtime dirs.\n' >&2
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

@test "teardown guard detects removal of BATS_RUN_TMPDIR" {
  local d="$BATS_TEST_TMPDIR/teardown-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() { rm -rf "$BATS_RUN_TMPDIR"; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/violator.bats"

  local body
  body="$(awk '
    /^teardown(_file)?\s*\(\)/ { inside=1 }
    inside { print }
    inside && /^}/ { inside=0 }
  ' "$d/violator.bats")"

  /usr/bin/grep -qE 'rm[[:space:]].*(\$\{?BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR\}?)' <<<"$body"
}

@test "teardown guard accepts removal of TEST_TMP only" {
  local d="$BATS_TEST_TMPDIR/safe-$$"
  mkdir -p "$d"
  {
    printf '#!/usr/bin/env bats\n'
    printf 'teardown() { rm -rf "$TEST_TMP"; }\n'
    printf '%s "%s" { true; }\n' '@test' 'x'
  } > "$d/safe.bats"

  local body
  body="$(awk '
    /^teardown(_file)?\s*\(\)/ { inside=1 }
    inside { print }
    inside && /^}/ { inside=0 }
  ' "$d/safe.bats")"

  if /usr/bin/grep -qE 'rm[[:space:]].*(\$\{?BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR\}?)' <<<"$body"; then
    printf 'False positive: safe teardown incorrectly matched\n' >&2
    return 1
  fi
}
