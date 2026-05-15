#!/usr/bin/env bats
# dev-story-step14b-cache-refresh-advisory.bats — E92-S4 / AI-RETRO-S46-4.
#
# Step 14b advisory: after Step 14 confirms the merge landed, emit ONE
# advisory line to stderr if the PR diff touched any
# `plugins/gaia/skills/*/SKILL.md` or `plugins/gaia/skills/*/scripts/*.sh`
# file. Mirrors Step 6b's non-blocking advisory contract.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

ADVISORY="$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts/cache-refresh-advisory.sh"

setup() {
  common_setup
  cd "$TEST_TMP"
}
teardown() { common_teardown; }

@test "TC-DCR-1: diff touches a SKILL.md -> advisory line emitted to stderr" {
  cat > diff.txt <<EOF
plugins/gaia/skills/gaia-dev-story/SKILL.md
plugins/gaia/skills/gaia-dev-story/scripts/checkpoint.sh
EOF
  run --separate-stderr "$ADVISORY" --diff-files diff.txt
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"step14b_advisory: plugin-cache refresh recommended"* ]]
  [[ "$stderr" == *"plugins/gaia/skills/gaia-dev-story/SKILL.md"* ]]
}

@test "TC-DCR-2: diff touches only docs/**/*.md -> no advisory" {
  cat > diff.txt <<EOF
docs/planning-artifacts/architecture.md
docs/implementation-artifacts/some-story.md
EOF
  run --separate-stderr "$ADVISORY" --diff-files diff.txt
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "TC-DCR-3: diff touches both SKILL.md and tests/*.bats -> advisory fires once" {
  cat > diff.txt <<EOF
plugins/gaia/skills/gaia-add-feature/SKILL.md
plugins/gaia/tests/example.bats
plugins/gaia/skills/gaia-add-feature/scripts/finalize.sh
EOF
  run --separate-stderr "$ADVISORY" --diff-files diff.txt
  [ "$status" -eq 0 ]
  # Exactly one advisory line — bats/, docs/, etc. excluded.
  advisory_lines=$(printf '%s\n' "$stderr" | grep -c 'step14b_advisory:' || true)
  [ "$advisory_lines" = "1" ]
  [[ "$stderr" == *"plugins/gaia/skills/gaia-add-feature/SKILL.md"* ]]
  [[ "$stderr" == *"plugins/gaia/skills/gaia-add-feature/scripts/finalize.sh"* ]]
  # tests/*.bats must NOT appear in the touched-files list.
  [[ "$stderr" != *"plugins/gaia/tests/example.bats"* ]]
}

@test "TC-DCR-4: empty diff file -> no advisory, exit 0" {
  : > diff.txt
  run --separate-stderr "$ADVISORY" --diff-files diff.txt
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "TC-DCR-5: diff touches plugins/gaia/agents/*.md -> advisory fires (agents also need refresh)" {
  cat > diff.txt <<EOF
plugins/gaia/agents/validator.md
EOF
  run --separate-stderr "$ADVISORY" --diff-files diff.txt
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"step14b_advisory: plugin-cache refresh recommended"* ]]
  [[ "$stderr" == *"plugins/gaia/agents/validator.md"* ]]
}
