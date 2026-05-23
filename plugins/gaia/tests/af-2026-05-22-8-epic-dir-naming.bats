#!/usr/bin/env bats
# AF-2026-05-22-8: epic-dir naming convergence (Bug 18 HIGH from YARA report).
#
# Bug: gaia-create-story SKILL.md wrote story .md files to
#   ${IMPLEMENTATION_ARTIFACTS}/epic-${EPIC_SLUG}/stories/...
# where ${EPIC_SLUG} was resolve_epic_slug's output (e.g., `epic-E1-foo`).
# That double-prefixed the path: epic-epic-E1-foo/stories/...
# In practice the LLM author bypassed the formula and wrote `epic-1/`
# (numeric-only), while transition-story-status.sh wrote story-index.yaml
# to `epic-E1-foo/`. Result: two directories per epic with split state.
#
# Fix: drop the redundant `epic-` prefix in SKILL.md (resolver output is
# the COMPLETE directory name); document the naming contract in gaia-
# create-story + gaia-create-epics Critical Rules so bulk-authoring
# follows the resolver convention.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# --- gaia-create-story SKILL.md uses ${EPIC_DIR} verbatim (no redundant epic- prefix) ---

@test "AF-22-8 Bug-18: gaia-create-story SKILL.md uses EPIC_DIR (resolver output) verbatim" {
  # The new variable is EPIC_DIR; the construction is ${IMPLEMENTATION_ARTIFACTS}/${EPIC_DIR}/stories/...
  grep -qF '${IMPLEMENTATION_ARTIFACTS}/${EPIC_DIR}/stories' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
}

@test "AF-22-8 Bug-18: gaia-create-story SKILL.md does NOT prepend redundant 'epic-' before EPIC_SLUG / EPIC_DIR" {
  # The buggy form was: epic-${EPIC_SLUG}/stories/... (resolver already prefixes with epic-).
  ! grep -qF 'epic-${EPIC_SLUG}/stories' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  ! grep -qF 'epic-${EPIC_DIR}/stories' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
}

@test "AF-22-8 Bug-18: gaia-create-story SKILL.md Critical Rules document the naming contract" {
  grep -qF 'AF-2026-05-22-8 Bug-18' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  grep -qF 'epic-{N}/stories/' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
  grep -qF 'SPLIT STATE' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md" \
    || grep -qF 'split state' "$PLUGIN_ROOT/skills/gaia-create-story/SKILL.md"
}

@test "AF-22-8 Bug-18: gaia-create-epics SKILL.md Critical Rules document the naming contract" {
  grep -qF 'AF-2026-05-22-8 Bug-18' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  grep -qF 'epic-{N}/stories/' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
}

# --- transition-story-status.sh uses resolver output verbatim (no redundant prefix) ---

@test "AF-22-8 Bug-18: transition-story-status.sh uses \${epic_slug}/stories/ (no extra epic- prefix)" {
  grep -qF '${IMPLEMENTATION_ARTIFACTS}/${epic_slug}/stories/story-index.yaml' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
  # Negative: ensure the buggy double-prefix form isn't present.
  ! grep -qF 'epic-${epic_slug}/stories/story-index' "$PLUGIN_ROOT/scripts/transition-story-status.sh"
}

# --- resolve-epic-slug.sh outputs the COMPLETE directory name (includes epic- prefix) ---

@test "AF-22-8 Bug-18: resolve-epic-slug.sh output starts with 'epic-' (the full directory basename)" {
  local epics_file="$BATS_TEST_TMPDIR/epics-a.md"
  printf '## E1 — Core Brain Vault\n' > "$epics_file"
  run bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E1 '$epics_file'"
  [ "$status" -eq 0 ]
  [[ "$output" == epic-* ]]
}

@test "AF-22-8 Bug-18: a path built from resolver output + IMPLEMENTATION_ARTIFACTS matches the canonical shape" {
  local epics_file="$BATS_TEST_TMPDIR/epics-b.md"
  printf '## Epic 7: Sprint Engine Pro\n' > "$epics_file"
  local epic_dir
  epic_dir=$(bash -c "source '$PLUGIN_ROOT/scripts/lib/resolve-epic-slug.sh' && resolve_epic_slug E7 '$epics_file'")
  [ "$epic_dir" = "epic-E7-sprint-engine-pro" ]
  # Simulated full path matches `epic-E{N}-{slug}/stories/...` — NOT `epic-epic-...` or `epic-{N}/...`.
  local full_path=".gaia/artifacts/implementation-artifacts/${epic_dir}/stories/E7-S1-foo.md"
  [[ "$full_path" == *"/epic-E7-sprint-engine-pro/stories/"* ]]
  [[ "$full_path" != *"/epic-epic-"* ]]
  [[ "$full_path" != *"/epic-7/"* ]]
}
