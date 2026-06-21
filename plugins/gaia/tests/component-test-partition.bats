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
  grep -q 'name: gaia-statusline' "$CFG"
  grep -q 'name: gaia-docs' "$CFG"
  grep -q 'name: gaia-ci' "$CFG"
  # The retired single-stack name must be gone from the slice.
  ! grep -q 'name: gaia-plugin' "$CFG"
}

@test "every component stack carries an explicit test_cmd (AC1)" {
  # Four stacks, four test_cmd lines.
  run grep -c '^    test_cmd:' "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

# ---------------------------------------------------------------------------
# AC4: single-component changes narrow to that component only
# ---------------------------------------------------------------------------

@test "a docs-only change resolves to gaia-docs only (AC4)" {
  run "$DETECT" --config "$CFG" --files documentation/index.html
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-docs"]' ]
}

@test "a statusline source change resolves to gaia-statusline only (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/statusline.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-statusline"]' ]
}

@test "a statusline lib change resolves to gaia-statusline only (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/lib/statusline-glyphs.sh
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-statusline"]' ]
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

@test "a non-statusline shared-lib change resolves to gaia-core (the broad stack) (AC4)" {
  run "$DETECT" --config "$CFG" --files plugins/gaia/scripts/lib/resolve-file-to-stack.sh
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
# AC3: cross_refs fan-out — a core change pulls in its dependents; a
# narrow-only change does not over-expand.
# ---------------------------------------------------------------------------

@test "a core change fans out to gaia-statusline via cross_refs (AC3)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-core"]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia-core"'* ]]
  [[ "$output" == *'"gaia-statusline"'* ]]
}

@test "a statusline-only change does NOT expand to gaia-core (AC3)" {
  run "$CROSS" --config "$CFG" --stacks '["gaia-statusline"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["gaia-statusline"]' ]
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
# AC2 drift-guard: the docs stack's pinned bats list must equal exactly the set
# of bats that reference documentation/. A new docs-touching bats added without
# wiring it into the docs test_cmd would be a silent narrowing gap (false-green
# for docs changes), so this fails CI until the list is updated.
# ---------------------------------------------------------------------------

@test "the docs stack test_cmd lists exactly the bats that reference documentation/ (AC2)" {
  # The bats that actually exercise the documentation site (by referencing the
  # documentation/ path). This guard file itself names documentation/ in its
  # own grep pattern, so exclude it — it tests the partition, it does not test
  # the docs site.
  local actual
  actual="$(grep -lE 'documentation/' "$TESTS_DIR"/*.bats \
            | xargs -n1 basename \
            | grep -vx 'component-test-partition.bats' \
            | sort -u)"

  # The bats pinned into the gaia-docs stack's test_cmd in the CI slice.
  local pinned
  pinned="$(grep -A1 'name: gaia-docs' "$CFG" >/dev/null; \
            awk '/name: gaia-docs/{f=1} f&&/test_cmd:/{print; exit}' "$CFG" \
            | grep -oE 'tests/[a-zA-Z0-9._-]+\.bats' | xargs -n1 basename | sort -u)"

  if [ "$actual" != "$pinned" ]; then
    echo "documentation/-referencing bats (actual):"; echo "$actual"
    echo "--- pinned in gaia-docs test_cmd:"; echo "$pinned"
    echo "--- the docs stack test_cmd in .gaia/ci-config.yaml is out of sync;"
    echo "    add/remove the drifted bats so the pinned list matches exactly."
    return 1
  fi
}
