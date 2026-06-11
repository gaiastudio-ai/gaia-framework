#!/usr/bin/env bats
# af-2026-05-21-16-meeting-canonical.bats
#
# Regression coverage for AF-2026-05-21-16: /gaia-meeting hardcoded legacy
# docs/creative-artifacts/ paths (primary write target: meeting-{date}-{slug}.md)
# and docs/planning-artifacts/action-items.yaml (CROSS-FAMILY relocation to
# .gaia/state/action-items.yaml). Approach: canonical-unconditional
# (no three-tier idiom) because write-boundary.sh post-E96-S8 enforces
# canonical-only — legacy docs/ prefix is REJECTED at runtime.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MEETING_SKILL="$PLUGIN_ROOT/skills/gaia-meeting/SKILL.md"
  NOTES_WRITER="$PLUGIN_ROOT/skills/gaia-meeting/scripts/meeting-notes-writer.sh"
  SCRATCHPAD_RESOLVER="$PLUGIN_ROOT/skills/gaia-meeting/scripts/scratchpad-resolve-path.sh"
  WRITE_BOUNDARY="$PLUGIN_ROOT/skills/gaia-meeting/scripts/write-boundary.sh"
}

teardown() { common_teardown; }

# --- SKILL.md canonical assertions ---

@test "AF-21-16: gaia-meeting/SKILL.md write-path prose uses canonical .gaia/ paths" {
  grep -qF '.gaia/artifacts/creative-artifacts/meeting-' "$MEETING_SKILL"
}

@test "AF-21-16: gaia-meeting/SKILL.md uses canonical action-items.yaml (cross-family relocation)" {
  # action-items.yaml moved from docs/planning-artifacts/ to .gaia/state/
  grep -qF '.gaia/state/action-items.yaml' "$MEETING_SKILL"
}

@test "AF-21-16: gaia-meeting/SKILL.md has no remaining legacy docs/creative-artifacts or docs/planning-artifacts/action-items refs" {
  ! grep -qE 'docs/creative-artifacts' "$MEETING_SKILL"
  ! grep -qE 'docs/planning-artifacts/action-items' "$MEETING_SKILL"
}

# --- Executable script canonical assertions ---

@test "AF-21-16: meeting-notes-writer.sh out_dir is canonical-unconditional" {
  # Notes write under the canonical .gaia/ creative-artifacts/meeting-notes/
  # subdir (E76-S24 moved notes into the meeting-notes/ subdir); the assertion
  # is that the out_dir is canonical .gaia/, never the legacy docs/ tree.
  grep -qE 'out_dir="\$ROOT/\.gaia/artifacts/creative-artifacts/meeting-notes"' "$NOTES_WRITER"
  ! grep -qE 'out_dir="\$ROOT/docs/creative-artifacts"' "$NOTES_WRITER"
}

@test "AF-21-16: scratchpad-resolve-path.sh printf is canonical-unconditional" {
  grep -qF '.gaia/artifacts/creative-artifacts/meeting-scratchpad/' "$SCRATCHPAD_RESOLVER"
  ! grep -qE "printf 'docs/creative-artifacts/" "$SCRATCHPAD_RESOLVER"
}

# --- scratchpad-resolve-path.sh runtime smoke ---

@test "AF-21-16: scratchpad-resolve-path.sh emits canonical .gaia/ path at runtime" {
  result=$(bash "$SCRATCHPAD_RESOLVER" \
    --date "2026-05-22" \
    --slug "test-meeting" \
    --sp-n "SP-1" \
    --content "Test content for scratchpad" \
    --intent "test scratchpad" \
    --content-type "md" 2>&1 || true)
  # Output should begin with .gaia/artifacts/creative-artifacts/meeting-scratchpad/
  echo "$result" | grep -qE '^\.gaia/artifacts/creative-artifacts/meeting-scratchpad/'
}

# --- write-boundary.sh runtime contract: accepts canonical, rejects legacy ---

@test "AF-21-16: write-boundary.sh accepts canonical .gaia/artifacts/creative-artifacts/ writes (E96-S8 post-canonical-only)" {
  # write-boundary.sh accepts <path> as positional arg
  cd "$TEST_TMP"
  bash "$WRITE_BOUNDARY" ".gaia/artifacts/creative-artifacts/meeting-2026-05-22-test.md"
}

@test "AF-21-16: write-boundary.sh rejects legacy docs/ writes (E96-S8 post-canonical-only)" {
  # Legacy docs/ prefix MUST be rejected post-E96-S8
  cd "$TEST_TMP"
  ! bash "$WRITE_BOUNDARY" "docs/creative-artifacts/meeting-2026-05-22-test.md" 2>/dev/null
}

# --- Sibling docstring canonicalization ---

@test "AF-21-16: charter-gate.sh user-facing heredoc uses canonical paths" {
  grep -qF '.gaia/artifacts/creative-artifacts/' "$PLUGIN_ROOT/skills/gaia-meeting/scripts/charter-gate.sh"
  grep -qF '.gaia/state/action-items.yaml' "$PLUGIN_ROOT/skills/gaia-meeting/scripts/charter-gate.sh"
}

@test "AF-21-16: action-items-writer.sh docstring uses canonical path" {
  grep -qF '.gaia/state/action-items.yaml' "$PLUGIN_ROOT/skills/gaia-meeting/scripts/action-items-writer.sh"
}

@test "AF-21-16: lifecycle-marker.sh docstring uses canonical path" {
  grep -qF '.gaia/artifacts/creative-artifacts/meeting-' "$PLUGIN_ROOT/skills/gaia-meeting/scripts/lifecycle-marker.sh"
}

# --- Regression guard: smart-fallback siblings MUST stay smart-fallback (AF-21-7 discipline) ---

@test "AF-21-16: memory-writethrough.sh preserves smart-fallback runtime branch (AF-21-7 discipline)" {
  # Smart-fallback runtime branches (memory/checkpoints style) are intentional
  # for _memory/ layout back-compat. They must NOT be touched by this AF.
  # File exists and has the canonical-first branch.
  grep -qF '.gaia' "$PLUGIN_ROOT/skills/gaia-meeting/scripts/memory-writethrough.sh"
}
