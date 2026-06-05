#!/usr/bin/env bats
# AF-2026-05-26-1: Batch A — six deterministic Test03 script/path/arg-shape fixes.
#
# F-8:  check-monolith-shard-sync.sh accepts a positional project-root arg as an
#       alias for --root (previously exited 64 on any positional token).
# F-11: gaia-create-story/SKILL.md references its skill-local scripts via the
#       ${CLAUDE_PLUGIN_ROOT}/skills/.../scripts/ prefix, not the bare global
#       !scripts/ prefix (which misresolved to plugins/gaia/scripts/).
# F-14: transition-story-status.sh per-epic-shard-absent log is reworded to a
#       non-alarming "info:" note (the status IS written to monolith + index).
# F-15: gaia-test-strategy/finalize.sh calls checkpoint.sh with --step and
#       lifecycle-event.sh with --type (no `emit` subcommand, no --event/--status).
# F-21: gaia-retro/finalize.sh sentinel marker uses retrospective.yaml (the
#       extension checkpoint.sh actually writes), not retrospective.json.
# F-23: resolve-config.sh recognizes project_kind=application (gaia-init's
#       default) and reworded the residual non-canonical note.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- F-8: positional arg alias for --root ---

@test "AF-26-1 F-8: check-monolith-shard-sync.sh accepts a positional project-root" {
  run bash "$PLUGIN_ROOT/scripts/check-monolith-shard-sync.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "AF-26-1 F-8: unknown --flag still exits 64 (positional alias did not weaken flag validation)" {
  run bash "$PLUGIN_ROOT/scripts/check-monolith-shard-sync.sh" --bogus-flag
  [ "$status" -eq 64 ]
}

@test "AF-26-1 F-8: --root still works (no regression)" {
  run bash "$PLUGIN_ROOT/scripts/check-monolith-shard-sync.sh" --root "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

# --- F-11: skill-local script references in gaia-create-story/SKILL.md ---

@test "AF-26-1 F-11: no skill-local script is referenced via the bare !scripts/ prefix" {
  local skill="$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  for s in slugify generate-frontmatter scaffold-story validate-canonical-filename \
           validate-frontmatter append-edge-case-acs append-edge-case-tests; do
    run grep -E "!scripts/${s}\.sh" "$skill"
    [ "$status" -ne 0 ] || { echo "stale bare !scripts/${s}.sh ref found"; false; }
  done
}

@test "AF-26-1 F-11: each skill-local script is referenced via CLAUDE_PLUGIN_ROOT/skills/.../scripts/" {
  local skill="$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  for s in slugify generate-frontmatter scaffold-story validate-canonical-filename \
           validate-frontmatter append-edge-case-acs append-edge-case-tests; do
    run grep -F "\${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-story/scripts/${s}.sh" "$skill"
    [ "$status" -eq 0 ] || { echo "missing canonical ref for ${s}.sh"; false; }
  done
}

@test "AF-26-1 F-11: every referenced skill-local script actually exists on disk" {
  for s in slugify generate-frontmatter scaffold-story validate-canonical-filename \
           validate-frontmatter append-edge-case-acs append-edge-case-tests; do
    [ -f "$PLUGIN_ROOT/skills/gaia-create-story/scripts/${s}.sh" ] \
      || { echo "skill-local script ${s}.sh not found"; false; }
  done
}

# --- F-14: reworded per-epic-shard log ---

@test "AF-26-1 F-14: per-epic-shard-absent log is a non-alarming info note" {
  run grep -F 'has no optional per-epic shard' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  [ "$status" -eq 0 ]
}

@test "AF-26-1 F-14: the old misleading 'no per-epic shard entry found' wording is gone" {
  run grep -F 'no per-epic shard entry found for' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  [ "$status" -ne 0 ]
}

# --- F-15: corrected checkpoint + lifecycle-event arg shapes ---

@test "AF-26-1 F-15: test-strategy finalize calls checkpoint.sh write with --step" {
  run grep -E '"\$CHECKPOINT" write --workflow "\$WORKFLOW_NAME" --step' \
    "$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

@test "AF-26-1 F-15: test-strategy finalize uses --type (no emit subcommand, no --event/--status)" {
  local f="$PLUGIN_ROOT/skills/gaia-test-strategy/scripts/finalize.sh"
  run grep -E '"\$LIFECYCLE_EVENT" \\' "$f"
  [ "$status" -eq 0 ]
  run grep -E -- '--type workflow_complete' "$f"
  [ "$status" -eq 0 ]
  run grep -E -- '--event finalize-complete|"\$LIFECYCLE_EVENT" emit' "$f"
  [ "$status" -ne 0 ]
}

@test "AF-26-1 F-15: the corrected lifecycle-event call shape exits 0 against the real script" {
  run bash "$PLUGIN_ROOT/scripts/lifecycle-event.sh" \
    --type workflow_complete --workflow gaia-test-strategy --data '{"checklist":"pass"}'
  [ "$status" -eq 0 ]
}

# --- F-21: retro finalize sentinel marker extension ---

@test "AF-26-1 F-21: retro finalize sentinel marker uses retrospective.yaml" {
  run grep -F 'retrospective.yaml' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  [ "$status" -eq 0 ]
}

@test "AF-26-1 F-21: the dead retrospective.json marker is gone" {
  run grep -F 'retrospective.json' "$PLUGIN_ROOT/skills/gaia-retro/scripts/finalize.sh"
  [ "$status" -ne 0 ]
}

# --- F-23: project_kind=application recognized + reworded note ---

@test "AF-26-1 F-23: project_kind=application emits no warning on resolve" {
  mkdir -p "$BATS_TEST_TMPDIR/.gaia/config"
  printf 'project_name: X\nproject_kind: application\n' \
    > "$BATS_TEST_TMPDIR/.gaia/config/project-config.yaml"
  CLAUDE_PROJECT_ROOT="$BATS_TEST_TMPDIR" \
    run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" project_kind
  # The project_kind validation runs as a side effect; assert no warning/note
  # text about project_kind appears on stderr for the canonical value.
  [[ "$output" != *'non-canonical'* ]]
  [[ "$output" != *'unknown project_kind'* ]]
}

@test "AF-26-1 F-23: a genuinely non-canonical project_kind emits the reworded note (not 'unknown')" {
  mkdir -p "$BATS_TEST_TMPDIR/.gaia/config"
  printf 'project_name: X\nproject_kind: weird-thing\n' \
    > "$BATS_TEST_TMPDIR/.gaia/config/project-config.yaml"
  CLAUDE_PROJECT_ROOT="$BATS_TEST_TMPDIR" \
    run bash "$PLUGIN_ROOT/scripts/resolve-config.sh" implementation_artifacts
  [[ "$output" == *'non-canonical (accepted'* ]]
  [[ "$output" != *'unknown project_kind'* ]]
}
