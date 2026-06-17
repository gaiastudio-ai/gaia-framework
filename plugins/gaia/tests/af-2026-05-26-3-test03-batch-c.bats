#!/usr/bin/env bats
# AF-2026-05-26-3: Batch C — sprint-state + frontmatter contract (Test03).
#
# F-7:  gaia-sprint-plan SKILL.md Step 6 bootstraps sprint-status.yaml via
#       `sprint-state.sh init` (guarded on yaml absence) before the first
#       `inject`, so the first-ever sprint on a fresh project no longer halts.
# F-9:  generate-frontmatter.sh extract_array strips surrounding [ ] so the
#       bracketed flow-sequence form ([A,B] / [A] / []) — the production form —
#       parses correctly instead of embedding literal brackets.
# F-10: gaia-sprint-plan SKILL.md Step 6a documents --goals as PIPE-DELIMITED
#       (the form cmd_set_goals actually parses), not JSON.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GF="$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  FIXTURES="$BATS_TEST_DIRNAME/cluster-7/fixtures"
}

teardown() { common_teardown; }

# --- F-7: SKILL.md Step 6 absence-guarded init ---

@test "sprint-plan Step 6 calls sprint-state.sh init guarded on yaml absence" {
  local skill="$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
  run grep -F 'sprint-state.sh init --sprint-id' "$skill"
  [ "$status" -eq 0 ]
  # Guard must be an absence check, not an unconditional call / error swallow.
  run grep -F '[ -e "$SPRINT_YAML" ] ||' "$skill"
  [ "$status" -eq 0 ]
}

@test "sprint-state.sh init seeds the canonical shape on a fresh tree" {
  local out="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$out"
  ( cd "$out" && CLAUDE_PROJECT_ROOT="$out" bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-1 )
  # Resolver may land the yaml under .gaia/ or the legacy docs/ tree (the docs/
  # default is the separate F-1 bug, fixed in AF-2026-05-26-4); locate it
  # wherever it was written and assert the canonical seed shape.
  local yaml
  yaml="$(find "$out" -name sprint-status.yaml | head -1)"
  [ -n "$yaml" ]
  grep -q 'total_points: 0' "$yaml"
  grep -q 'items: \[\]' "$yaml"
  grep -q 'goals: \[\]' "$yaml"
}

@test "sprint-state.sh init refuses to overwrite an existing yaml (guard is required)" {
  local out="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$out"
  ( cd "$out" && CLAUDE_PROJECT_ROOT="$out" bash "$PLUGIN_ROOT/scripts/sprint-state.sh" init --sprint-id sprint-1 )
  run bash -c "cd '$out' && CLAUDE_PROJECT_ROOT='$out' bash '$PLUGIN_ROOT/scripts/sprint-state.sh' init --sprint-id sprint-1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

# --- F-9: bracketed-form array parsing ---

@test "multi-element bracketed depends_on parses without embedded brackets" {
  run "$GF" --story-key E50-S2 \
    --epics-file "$FIXTURES/epics-frontmatter-bracketed.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'depends_on: ["E50-S1", "E50-S3"]'* ]]
  [[ "$output" == *'blocks: ["E50-S4"]'* ]]
  [[ "$output" == *'traces_to: ["FR-001", "FR-002"]'* ]]
  # No literal bracket leaked into any element.
  ! [[ "$output" == *'"[E50'* ]]
  ! [[ "$output" == *'S3]"'* ]]
}

@test "single-element bracketed dep + empty bracketed blocks parse correctly" {
  run "$GF" --story-key E50-S5 \
    --epics-file "$FIXTURES/epics-frontmatter-bracketed.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'depends_on: ["E50-S2"]'* ]]
  # Empty [] must NOT become a phantom dependency ["[]"] / ["]"].
  [[ "$output" == *'blocks: []'* ]]
  [[ "$output" == *'traces_to: []'* ]]
  ! [[ "$output" == *'"[]"'* ]]
}

@test "unbracketed comma form still parses (no regression)" {
  run "$GF" --story-key E99-S1 \
    --epics-file "$FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$FIXTURES/project-config-frontmatter-default.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'depends_on: ["E99-S0", "E10-S2"]'* ]]
  [[ "$output" == *'blocks: ["E99-S2"]'* ]]
}

# --- F-10: SKILL.md goals doc is pipe-delimited ---

@test "sprint-plan Step 6a documents --goals as pipe-delimited (not JSON)" {
  local skill="$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
  run grep -F 'PIPE-DELIMITED' "$skill"
  [ "$status" -eq 0 ]
  # The stale `--goals <json>` token on the user-direct lane is gone.
  run grep -F 'set-goals --sprint <id> --goals <json>' "$skill"
  [ "$status" -ne 0 ]
}
