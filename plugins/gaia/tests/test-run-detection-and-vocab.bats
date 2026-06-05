#!/usr/bin/env bats
# test-run-detection-and-vocab.bats — AF-2026-05-17-3 regression guard
#
# Two findings closed by this AF:
#
# A) Cross-skill vocabulary drift. /gaia-test-run reads
#    tools.test_runner.provider but /gaia-config-tool's canonical
#    adapter-category list rejected test_runner. Now the SKILL.md prose
#    documents test_runner as a prose-only category (no adapter file).
#
# B) Narrow detection fallback. run-tests.sh L148-157 used only top-level
#    CWD globs for runner detection, missing 411+ bats files nested at
#    plugins/gaia/tests/*.bats. Now a maxdepth-4 find scan covers nested
#    layouts AND each recursive candidate is gated by `command -v` so a
#    leftover vitest.config.js in a vendor dir cannot trump a real bats
#    suite when only bats is installed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CONFIG_TOOL_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-config-tool/SKILL.md"
  TEST_RUN_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-test-run/SKILL.md"
  TEST_RUN_SCRIPT="$REPO_ROOT/plugins/gaia/skills/gaia-test-run/scripts/run-tests.sh"
  export LC_ALL=C
}

# Finding A — vocab alignment
@test "config-tool SKILL.md canonical category list mentions test_runner" {
  run grep -E 'test_runner' "$CONFIG_TOOL_SKILL"
  [ "$status" -eq 0 ]
  # The reference should be in the orphan-rejection rule context (line ~24)
  run grep -E 'prose-only category.*test_runner|test_runner.*prose-only|test_runner.*consumed by' "$CONFIG_TOOL_SKILL"
  [ "$status" -eq 0 ]
}

@test "config-tool default-scaffold mentions test_runner" {
  run grep -E '^[[:space:]]*#.*test_runner' "$CONFIG_TOOL_SKILL"
  [ "$status" -eq 0 ]
}

@test "test-run SKILL.md and script reference the same vocab" {
  run grep -E 'tools\.test_runner\.provider' "$TEST_RUN_SKILL"
  [ "$status" -eq 0 ]
  run grep -E 'tools\.test_runner\.provider' "$TEST_RUN_SCRIPT"
  [ "$status" -eq 0 ]
}

# Finding B — detection breadth
@test "run-tests.sh detection uses maxdepth-bounded find" {
  run grep -E 'find \. -maxdepth' "$TEST_RUN_SCRIPT"
  [ "$status" -eq 0 ]
  # Three recursive candidates (bats, vitest, pytest, go) — exact count
  # is 4 but allow >=3 for resilience to future re-orderings.
  count=$(grep -c 'find \. -maxdepth' "$TEST_RUN_SCRIPT")
  [ "$count" -ge 3 ]
}

@test "recursive detection guards each candidate with command -v" {
  # Each recursive elif must AND with `command -v <runner>` so a leftover
  # vendor config cannot select a runner that isn't actually installed.
  count=$(grep -cE 'maxdepth 4.*command -v' "$TEST_RUN_SCRIPT")
  [ "$count" -ge 3 ]
}

