#!/usr/bin/env bats
# lint-bats-script-refs.bats — unit tests for plugins/gaia/scripts/lint-bats-script-refs.sh
#
# Story: E28-S221 — sweep linter that flags any bats test referencing a
# deleted/deprecated script across BOTH gaia-public/tests/ and
# gaia-public/plugins/gaia/tests/ trees.
#
# Public functions covered: extract_script_refs, lint_one_bats, is_ignored,
# main.
#
# is_ignored is exercised end-to-end through the --ignore-pattern CLI flag
# (see "--ignore-pattern" tests below); the helper has no separate CLI
# surface, so its behaviour is asserted via the linter's exit code and
# STALE-line output rather than a direct function call.
#
# AC mapping:
#   AC3 — sweep linter exists; fails when any bats file references a script
#         that no longer exists in plugins/gaia/scripts/ or
#         plugins/gaia/skills/*/scripts/.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/lint-bats-script-refs.sh"
  # Heredocs below build fixture .bats files containing dummy @test
  # blocks. We splice the @ at write-time via $AT so the literal @test
  # never appears at column 0 in this source file — bats's plan counter
  # (1.10 on CI) globs for ^@test across all files in the suite and
  # would otherwise inflate the suite plan by 6 phantom tests, leaving
  # an "expected N, executed M" warning that fails the suite. (E28-S221)
  AT='@'
  # Build a fixture repo root with both tree shapes.
  FIXTURE_ROOT="$TEST_TMP/repo"
  mkdir -p "$FIXTURE_ROOT/plugins/gaia/scripts"
  mkdir -p "$FIXTURE_ROOT/plugins/gaia/skills/example-skill/scripts"
  mkdir -p "$FIXTURE_ROOT/plugins/gaia/tests"
  mkdir -p "$FIXTURE_ROOT/tests/cluster-x-parity"
  # Plant a couple of real scripts to satisfy clean-tree references.
  cat > "$FIXTURE_ROOT/plugins/gaia/scripts/real-script.sh" <<'EOS'
#!/bin/bash
echo real
EOS
  cat > "$FIXTURE_ROOT/plugins/gaia/skills/example-skill/scripts/skill-script.sh" <<'EOS'
#!/bin/bash
echo skill
EOS
  # NOTE: chmod targets are spelled with the $FIXTURE_ROOT prefix on the
  # same physical line (no newline before the path) so that any future
  # linter pattern that anchors on a variable prefix can recognise these
  # as fixture-local rather than repo-canonical references.
  chmod +x "$FIXTURE_ROOT/plugins/gaia/scripts/real-script.sh" || true
  chmod +x "$FIXTURE_ROOT/plugins/gaia/skills/example-skill/scripts/skill-script.sh" || true
}
teardown() { common_teardown; }

@test "lint-bats-script-refs.sh: --help exits 0 and lists usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"--root"* ]]
}

@test "lint-bats-script-refs.sh: clean tree exits 0 with no STALE lines" {
  # A clean .bats in each tree referencing existing scripts only.
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/clean.bats" <<EOS
#!/usr/bin/env bats
${AT}test "clean reference" {
  run bash plugins/gaia/scripts/real-script.sh
  [ "\$status" -eq 0 ]
}
EOS
  cat > "$FIXTURE_ROOT/tests/cluster-x-parity/clean-legacy.bats" <<EOS
#!/usr/bin/env bats
${AT}test "clean legacy reference" {
  bash "plugins/gaia/skills/example-skill/scripts/skill-script.sh"
}
EOS

  run "$SCRIPT" --root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE:"* ]]
}

@test "lint-bats-script-refs.sh: planted stale reference -> exit 1 with STALE: line" {
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/stale.bats" <<EOS
#!/usr/bin/env bats
${AT}test "stale reference" {
  run bash plugins/gaia/scripts/deleted-script.sh
  [ "\$status" -eq 0 ]
}
EOS

  run "$SCRIPT" --root "$FIXTURE_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE:"* ]]
  [[ "$output" == *"deleted-script.sh"* ]]
  [[ "$output" == *"stale.bats"* ]]
}

@test "lint-bats-script-refs.sh: stale reference in legacy tree also flagged" {
  cat > "$FIXTURE_ROOT/tests/cluster-x-parity/stale-legacy.bats" <<EOS
#!/usr/bin/env bats
${AT}test "legacy stale" {
  bash "plugins/gaia/skills/example-skill/scripts/missing-skill-script.sh"
}
EOS

  run "$SCRIPT" --root "$FIXTURE_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE:"* ]]
  [[ "$output" == *"missing-skill-script.sh"* ]]
  [[ "$output" == *"stale-legacy.bats"* ]]
}

@test "lint-bats-script-refs.sh: commented-out references are ignored" {
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/commented.bats" <<EOS
#!/usr/bin/env bats
# bash plugins/gaia/scripts/deleted-script.sh  -- legacy comment, do not flag
${AT}test "no-op" {
  :
}
EOS

  run "$SCRIPT" --root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE:"* ]]
}

@test "lint-bats-script-refs.sh: --ignore-pattern suppresses matching stale ref" {
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/stale-but-allowlisted.bats" <<EOS
#!/usr/bin/env bats
${AT}test "allowlisted stale" {
  bash plugins/gaia/scripts/intentional-fixture.sh
}
EOS

  # Without --ignore-pattern: should fail.
  run "$SCRIPT" --root "$FIXTURE_ROOT"
  [ "$status" -eq 1 ]

  # With --ignore-pattern matching the script name: should pass.
  run "$SCRIPT" --root "$FIXTURE_ROOT" --ignore-pattern "intentional-fixture"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE:"* ]]
}

@test "lint-bats-script-refs.sh: is_ignored — multiple --ignore-pattern flags compose" {
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/two-stale.bats" <<EOS
#!/usr/bin/env bats
${AT}test "two stale" {
  bash plugins/gaia/scripts/fixture-a.sh
  bash plugins/gaia/scripts/fixture-b.sh
}
EOS

  # Both patterns must apply for the linter to exit 0; without the second
  # pattern, fixture-b remains stale. This exercises the loop body of
  # is_ignored for the second iteration (RSTART/RLENGTH-style globals are
  # not at risk here, but loop coverage matters).
  run "$SCRIPT" --root "$FIXTURE_ROOT" --ignore-pattern "fixture-a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fixture-b.sh"* ]]
  [[ "$output" != *"fixture-a.sh"* ]]

  run "$SCRIPT" --root "$FIXTURE_ROOT" \
    --ignore-pattern "fixture-a" --ignore-pattern "fixture-b"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE:"* ]]
}

@test "lint-bats-script-refs.sh: is_ignored — regex pattern matches multiple paths" {
  cat > "$FIXTURE_ROOT/plugins/gaia/tests/regex-stale.bats" <<EOS
#!/usr/bin/env bats
${AT}test "regex stale" {
  bash plugins/gaia/scripts/fake-one.sh
  bash plugins/gaia/scripts/fake-two.sh
}
EOS

  # A single regex pattern (^.*fake-.*\\.sh$) covers both stale references
  # via is_ignored; the linter must exit 0 when every stale ref matches.
  run "$SCRIPT" --root "$FIXTURE_ROOT" --ignore-pattern "fake-.*\\.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE:"* ]]
}

@test "lint-bats-script-refs.sh: missing --root errors out gracefully" {
  run "$SCRIPT" --root "$TEST_TMP/does-not-exist"
  [ "$status" -ne 0 ]
}
