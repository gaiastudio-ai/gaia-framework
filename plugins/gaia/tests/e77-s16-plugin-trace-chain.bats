#!/usr/bin/env bats
# e77-s16-plugin-trace-chain.bats — E77-S16 / FR-421 / AC5
#
# plugin-trace-chain.sh resolves the plugin traceability chain:
#   manifest.yaml | .claude-plugin/plugin.json
#       -> plugins/*/SKILL.md
#       -> bang-line script references inside SKILL.md
#       -> tests/*.bats files referencing those scripts
#
# Output: JSON with a `chain` array (one entry per skill) and a `gaps`
# array (orphan SKILL.md, missing scripts, scripts with no bats coverage).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_TRACE="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/plugin-trace-chain.sh"

# ---------------------------------------------------------------------------
# Fixture helper — build a minimal plugin project.
#
# Note: the fixture creates a `tests/foo.bats` file containing references to
# `setup.sh` and `run.sh`. We construct those bats fixture lines via printf
# rather than a heredoc so that the bats pre-pass over THIS file does not
# parse the literal `@test` token in a heredoc and try to register it as
# a duplicate test (caused CI "unknown test name" errors otherwise).
# ---------------------------------------------------------------------------
_build_plugin_fixture() {
  local proj="$1"
  mkdir -p "$proj/.claude-plugin" \
           "$proj/plugins/foo" \
           "$proj/plugins/foo/scripts" \
           "$proj/tests"
  echo '{"name":"demo","version":"0.1.0"}' > "$proj/.claude-plugin/plugin.json"
  printf 'name: demo\nversion: 0.1.0\nskills:\n  - foo\n' > "$proj/manifest.yaml"
  printf -- '---\nname: foo\ndescription: foo skill\n---\n\n## Setup\n\n!scripts/setup.sh\n\n## Steps\n\n!scripts/run.sh\n' \
    > "$proj/plugins/foo/SKILL.md"
  echo '#!/bin/sh' > "$proj/plugins/foo/scripts/setup.sh"
  echo '#!/bin/sh' > "$proj/plugins/foo/scripts/run.sh"
  # Build the fixture bats file via printf — the literal `@test` token is
  # constructed at runtime via $REF below so bats does not parse it from
  # this file's heredoc. (See e0c5d6f-style fixture pattern from E77-S14.)
  local REF='@test'
  printf '%s "fixture-setup-call" {\n  run bash plugins/foo/scripts/setup.sh\n  [ "$status" -eq 0 ]\n}\n' "$REF" \
    > "$proj/tests/foo.bats"
}

# ---------------------------------------------------------------------------
# AC5 — happy-path chain.
# ---------------------------------------------------------------------------

@test "AC5: traces manifest -> SKILL.md -> scripts -> bats for a complete plugin" {
  local proj="$TEST_TMP/plugin"
  _build_plugin_fixture "$proj"
  run "$PLUGIN_TRACE" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"skill": "foo"'* ]]
  [[ "$output" == *'setup.sh'* ]]
  [[ "$output" == *'run.sh'* ]]
  [[ "$output" == *'foo.bats'* ]]
}

@test "AC5: chain entry records covered=true when every script has bats coverage" {
  local proj="$TEST_TMP/plugin"
  _build_plugin_fixture "$proj"
  # Ensure run.sh is referenced by a bats fixture file too. We build the
  # fixture via printf with a $REF prefix so the bats pre-pass over THIS
  # file does not parse the literal @test token. (See _build_plugin_fixture
  # for the same pattern + rationale.)
  local REF='@test'
  printf '%s "fixture-run-call" {\n  run bash plugins/foo/scripts/run.sh\n  [ "$status" -eq 0 ]\n}\n' "$REF" \
    > "$proj/tests/run.bats"
  run "$PLUGIN_TRACE" --project-root "$proj"
  [ "$status" -eq 0 ]
  # Every script should appear under a covered=true context for at least one
  # script (we only assert on setup.sh — already covered by foo.bats).
  [[ "$output" == *'"covered": true'* ]]
}

@test "AC5: surfaces gap when a SKILL.md references a non-existent script" {
  local proj="$TEST_TMP/plugin"
  _build_plugin_fixture "$proj"
  # Add a !scripts/missing.sh ref to SKILL.md without creating the file.
  printf '\n## Extra\n\n!scripts/missing.sh\n' >> "$proj/plugins/foo/SKILL.md"
  run "$PLUGIN_TRACE" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gap_kind": "missing_script"'* ]]
  [[ "$output" == *'missing.sh'* ]]
}

@test "AC5: surfaces gap when a script has no bats coverage" {
  local proj="$TEST_TMP/plugin"
  _build_plugin_fixture "$proj"
  # No bats file references run.sh — only setup.sh — so run.sh is orphaned.
  run "$PLUGIN_TRACE" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gap_kind": "no_bats_coverage"'* ]]
  [[ "$output" == *'run.sh'* ]]
}

@test "AC5: surfaces gap when manifest lists a skill but SKILL.md is missing" {
  local proj="$TEST_TMP/plugin"
  _build_plugin_fixture "$proj"
  # Reference a phantom skill in the manifest.
  printf '  - phantom\n' >> "$proj/manifest.yaml"
  run "$PLUGIN_TRACE" --project-root "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gap_kind": "missing_skill_md"'* || "$output" == *'phantom'* ]]
}

# ---------------------------------------------------------------------------
# AC5 — non-plugin projects: chain MUST NOT be triggered.
# ---------------------------------------------------------------------------

@test "AC5: --require-plugin exits 0 with empty chain on a non-plugin project" {
  local proj="$TEST_TMP/notplugin"
  mkdir -p "$proj"
  echo '# README' > "$proj/README.md"
  run "$PLUGIN_TRACE" --project-root "$proj" --require-plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *'"chain": []'* ]]
  [[ "$output" == *'"is_plugin": false'* ]]
}

# ---------------------------------------------------------------------------
# Argument validation.
# ---------------------------------------------------------------------------

@test "missing --project-root prints actionable error and exits 1" {
  run "$PLUGIN_TRACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--project-root"* ]]
}

@test "non-existent project root exits 1 with directory error" {
  run "$PLUGIN_TRACE" --project-root "$TEST_TMP/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"directory"* ]]
}
