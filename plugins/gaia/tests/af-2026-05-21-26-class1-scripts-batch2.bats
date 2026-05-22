#!/usr/bin/env bats
# AF-21-26: second batch of Class-1 script-side canonical-first migrations.
# Covers 6 additional executable bare-legacy hits found in the AF-21-25 final
# audit that weren't in scope of AF-21-25.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

@test "AF-21-26: phase2-execute.sh EVIDENCE_DIR canonical-first" {
  grep -qF '.gaia/artifacts/test-artifacts/test-results' "$PLUGIN_ROOT/skills/gaia-test-automate/scripts/phase2-execute.sh"
}

@test "AF-21-26: phase2-execute.sh STORY_GLOB canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts/${STORY_KEY}-*.md' "$PLUGIN_ROOT/skills/gaia-test-automate/scripts/phase2-execute.sh"
}

@test "AF-21-26: infer-parent-epic.sh EPICS_FILE canonical-first" {
  grep -qF '.gaia/artifacts/planning-artifacts/epics-and-stories.md' "$PLUGIN_ROOT/skills/gaia-add-feature/scripts/lib/infer-parent-epic.sh"
}

@test "AF-21-26: skill-proposal.sh tech-debt-dashboard canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md' "$PLUGIN_ROOT/skills/gaia-retro/scripts/skill-proposal.sh"
}

@test "AF-21-26: load-spec.sh SPEC_PATH canonical-first" {
  grep -qF '.gaia/artifacts/implementation-artifacts/quick-spec-' "$PLUGIN_ROOT/skills/gaia-quick-dev/scripts/load-spec.sh"
}

@test "AF-21-26: validate-canonical-filename.sh resolve_impl_dir recognizes canonical .gaia/" {
  grep -qE '\*/\.gaia/artifacts/implementation-artifacts\)' "$PLUGIN_ROOT/skills/gaia-create-story/scripts/validate-canonical-filename.sh"
}
