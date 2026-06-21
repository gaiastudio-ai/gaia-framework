#!/usr/bin/env bats
# component-test-partition.bats — guards the component-level test partition.
#
# The repo's tracked CI config slice (.gaia/ci-config.yaml) declares component
# stacks (a broad core stack plus narrow carved-out stacks) so a change confined
# to a carved-out component runs ONLY that component's tests on the
# feature->staging PR, while the staging->main promotion still runs the full
# suite. These tests pin:
#   - the narrowing resolution for each component (detect-affected per scenario),
#   - the cross-component dependency fan-out (cross_refs),
#   - the promotion->full-suite escalation,
#   - a drift-guard that fails if a new documentation/-touching bats is added
#     without being wired into the docs stack's test command.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CFG="$REPO_ROOT/.gaia/ci-config.yaml"
  DETECT="$REPO_ROOT/plugins/gaia/scripts/detect-affected.sh"
  CROSS="$REPO_ROOT/plugins/gaia/scripts/cross-refs-walk.sh"
  TESTS_DIR="$REPO_ROOT/plugins/gaia/tests"
}

# ---------------------------------------------------------------------------
# AC1: the slice declares the component stacks (not the old single stack)
# ---------------------------------------------------------------------------

@test "the CI slice declares component stacks, not the retired single stack (AC1)" {
  grep -q 'name: gaia-core' "$CFG"
  grep -q 'name: gaia-docs' "$CFG"
  grep -q 'name: gaia-ci' "$CFG"
  # The retired single-stack name must be gone from the slice.
  ! grep -q 'name: gaia-plugin' "$CFG"
}

@test "every component stack carries an explicit test_cmd (AC1)" {
  # One test_cmd per declared stack — assert equality, not a loose floor, so a
  # stack added without its own test_cmd fails the guard.
  local stacks test_cmds
  stacks="$(grep -c '^  - name:' "$CFG")"
  test_cmds="$(grep -c '^    test_cmd:' "$CFG")"
  [ "$stacks" -eq "$test_cmds" ]
}

# ---------------------------------------------------------------------------
# AC4: single-component changes narrow to that component only
# ---------------------------------------------------------------------------

@test "a docs-only change resolves to gaia-docs only (AC4)" {
  run "$DETECT" --config "$CFG" --files documentation/index.html
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-docs"]' ]
}

@test "a CI workflow change resolves to gaia-ci only (AC4)" {
  run "$DETECT" --config "$CFG" --files .github/workflows/plugin-ci.yml
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-ci"]' ]
}

@test "a core source change resolves to gaia-core (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/sprint-state.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "a shared-lib change resolves to gaia-core (the broad stack) (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/lib/resolve-file-to-stack.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

# ---------------------------------------------------------------------------
# AC4 (no false-green on orphan paths): a change to a repo-root functional
# surface that the carved-out stacks do not own (the repo-root test tree,
# build/CI helper scripts, git hooks, commit-lint config) must resolve to
# gaia-core and run the full suite — never to [] (which would run zero tests).
# ---------------------------------------------------------------------------

@test "a repo-root tests/ change resolves to gaia-core, not [] (AC4)" {
  run "$DETECT" --config "$CFG" --files tests/skills/some-skill.bats
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "a repo-root build script change resolves to gaia-core, not [] (AC4)" {
  run "$DETECT" --config "$CFG" --files scripts/version-bump.js
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "the commit-lint config change resolves to gaia-core, not [] (AC4)" {
  run "$DETECT" --config "$CFG" --files commitlint.config.mjs
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "a mixed core+docs change resolves to both stacks (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/sprint-state.sh documentation/index.html
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia-core"'* ]]
  [[ "$output" == *'"gaia-docs"'* ]]
}

# ---------------------------------------------------------------------------
# AC3: cross_refs honoured — no spurious expansion when no edge is declared,
# and a declared dependency edge fans out. The current stack set declares no
# cross_refs (the carved-out stacks are independent of the core tree), so a
# core change must NOT pull in the narrow stacks; the edge-fan-out behaviour is
# pinned against a synthetic config so the capability is regression-covered for
# the next component carve-out that does declare a dependency.
# ---------------------------------------------------------------------------

@test "no spurious fan-out: a core change does not pull in the independent narrow stacks (AC3)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-core"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-core"]' ]
}

@test "a declared cross_refs dependency edge fans out to the dependency (AC3)" {
  # Synthetic config: stack 'leaf' depends on 'base'. A change to 'base' must
  # transitively pull in 'leaf' (its consumer), proving the fan-out machinery
  # the next component carve-out will rely on.
  cat > "$BATS_TEST_TMPDIR/xref.yaml" <<'EOF'
stacks:
  - name: base
    language: bash
    paths:
      - lib/**
  - name: leaf
    language: bash
    paths:
      - app/**
    cross_refs:
      - base
EOF
  run "$CROSS" --config "$BATS_TEST_TMPDIR/xref.yaml" --stacks '["base"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"base"'* ]]
  [[ "$output" == *'"leaf"'* ]]
}

# ---------------------------------------------------------------------------
# AC5: the staging->main promotion still runs the full suite
# ---------------------------------------------------------------------------

@test "a promotion-push escalates to the full-suite wildcard (AC5)" {
  run "$DETECT" --config "$CFG" --event promotion-push --files documentation/index.html
  [ "$status" -eq 0 ]
  [ "$output" = '["*"]' ]
}

# ---------------------------------------------------------------------------
# AC2 drift-guard: the docs stack must DERIVE its bats at run time (not pin a
# static list that drifts silently). The test_cmd must route through
# run-docs-stack-tests.sh, and that resolver must actually resolve a non-empty
# set. A static list would let a new docs-page test added without re-pinning
# silently never run on a docs-only PR (a false-green); deriving from the
# canonical signal closes that gap by construction.
# ---------------------------------------------------------------------------

@test "the docs stack test_cmd derives its bats via the resolver, not a static list (AC2)" {
  # The gaia-docs test_cmd must invoke run-docs-stack-tests.sh.
  local docs_cmd
  docs_cmd="$(awk '/name: gaia-docs/{f=1} f&&/test_cmd:/{print; exit}' "$CFG")"
  [[ "$docs_cmd" == *"run-docs-stack-tests.sh"* ]]
  # It must NOT pin individual .bats paths (the drift-prone anti-pattern).
  [[ "$docs_cmd" != *".bats"* ]]
}

@test "the docs-test resolver resolves a non-empty set of documentation-site bats (AC2)" {
  local resolver="$REPO_ROOT/plugins/gaia/scripts/run-docs-stack-tests.sh"
  [ -x "$resolver" ] || [ -f "$resolver" ]
  run bash "$resolver" --list
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Sanity: the canonical docs-page test is in the resolved set.
  [[ "$output" == *"test07-docs.bats"* ]]
}
