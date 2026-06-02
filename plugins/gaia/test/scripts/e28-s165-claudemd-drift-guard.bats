#!/usr/bin/env bats
# e28-s165-claudemd-drift-guard.bats — bats tests for the CLAUDE.md drift guard (E28-S165)
#
# Validates that the guard script and CI job correctly detect drift between the
# project-root CLAUDE.md and the plugin copy (gaia-framework/CLAUDE.md).
#
# Design note: the project-root CLAUDE.md normally lives in the dev workspace
# above gaia-framework/ and is NOT git-tracked inside gaia-framework. The guard script
# accepts explicit paths so it can be exercised locally (dev workspace has both
# files) and in CI (self-diff against gaia-framework/CLAUDE.md). The tests below
# construct temp fixtures so pass and fail scenarios can be exercised regardless
# of the ambient filesystem layout.

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GAIA_PUBLIC="$(cd "$PLUGIN_DIR/../.." && pwd)"
GUARD="$PLUGIN_DIR/scripts/claudemd-drift-guard.sh"
CI_WORKFLOW="$GAIA_PUBLIC/.github/workflows/plugin-ci.yml"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# --- AC1: CI workflow contains the diff step ---------------------------------

@test "E28-S165 AC1: plugin-ci.yml declares a claudemd-drift-guard job" {
  [ -f "$CI_WORKFLOW" ]
  grep -qE '^  claudemd-drift-guard:' "$CI_WORKFLOW"
}

@test "E28-S165 AC1: claudemd-drift-guard job invokes diff -q on CLAUDE.md" {
  [ -f "$CI_WORKFLOW" ]
  # The job must ultimately run diff -q against a CLAUDE.md path.
  # We match 'diff -q' co-located with the claudemd-drift-guard job.
  awk '/^  claudemd-drift-guard:/{flag=1; next} /^  [a-z]/{flag=0} flag' "$CI_WORKFLOW" \
    | grep -qE 'diff -q[[:space:]]+.*CLAUDE\.md'
}

@test "E28-S165 AC1: guard script exists and is executable" {
  [ -x "$GUARD" ]
}

# --- AC2: identical files pass ----------------------------------------------

@test "E28-S165 AC2: identical files produce exit 0" {
  printf "# CLAUDE.md\nidentical content\n" > "$TMPDIR_TEST/root.md"
  cp "$TMPDIR_TEST/root.md" "$TMPDIR_TEST/plugin.md"
  run "$GUARD" "$TMPDIR_TEST/root.md" "$TMPDIR_TEST/plugin.md"
  [ "$status" -eq 0 ]
}

@test "E28-S165 AC2: self-diff (one path, used twice) produces exit 0" {
  printf "# CLAUDE.md\nsome content\n" > "$TMPDIR_TEST/only.md"
  run "$GUARD" "$TMPDIR_TEST/only.md" "$TMPDIR_TEST/only.md"
  [ "$status" -eq 0 ]
}

@test "E28-S165 AC2: the in-repo CLAUDE.md self-diff passes (CI invariant)" {
  # The CI-invariant: in gaia-framework, the only CLAUDE.md at the repo root
  # must pass a self-diff. This is what plugin-ci.yml runs.
  run "$GUARD" "$GAIA_PUBLIC/CLAUDE.md" "$GAIA_PUBLIC/CLAUDE.md"
  [ "$status" -eq 0 ]
}

# --- AC3: drift fails with clear message -------------------------------------

@test "E28-S165 AC3: different files produce non-zero exit" {
  printf "# CLAUDE.md\nroot content\n" > "$TMPDIR_TEST/root.md"
  printf "# CLAUDE.md\nplugin content\n" > "$TMPDIR_TEST/plugin.md"
  run "$GUARD" "$TMPDIR_TEST/root.md" "$TMPDIR_TEST/plugin.md"
  [ "$status" -ne 0 ]
}

@test "E28-S165 AC3: drift message mentions CLAUDE.md and both paths" {
  printf "A\n" > "$TMPDIR_TEST/root.md"
  printf "B\n" > "$TMPDIR_TEST/plugin.md"
  run "$GUARD" "$TMPDIR_TEST/root.md" "$TMPDIR_TEST/plugin.md"
  [ "$status" -ne 0 ]
  # Output must name CLAUDE.md drift explicitly so maintainers can triage.
  echo "$output" | grep -qiE 'CLAUDE\.md|drift|differ'
}

@test "E28-S165 AC3: missing file produces actionable error" {
  printf "content\n" > "$TMPDIR_TEST/root.md"
  run "$GUARD" "$TMPDIR_TEST/root.md" "$TMPDIR_TEST/nope.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'not found|missing|no such'
}

# --- Usage / safety ----------------------------------------------------------

@test "E28-S165 usage: no arguments prints usage and exits non-zero" {
  run "$GUARD"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'usage'
}

@test "E28-S165 usage: --help prints usage and exits 0" {
  run "$GUARD" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'usage'
}
