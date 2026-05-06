#!/usr/bin/env bats
# e64-s3-transition-script-path-refs.bats — regression guard for E64-S3 (AC1-AC3)
#
# Story: E64-S3 (Fix transition-story-status.sh skill-local path references)
# Origin: triage-findings E53-S224#2
#
# Validates:
#   AC1 — gaia-dev-story/SKILL.md references to transition-story-status.sh use
#         the plugin-global path (${CLAUDE_PLUGIN_ROOT}/scripts/...) — no
#         skill-local `scripts/transition-story-status.sh` form remains.
#   AC2 — AC1 holds for the three call sites: Step 2 (FRESH-mode in-progress
#         transition), Step 10 (review transition after gates), Step 15
#         (Update Review Gate review transition).
#   AC3 — Cross-skill audit: every other gaia-* SKILL.md that references
#         transition-story-status.sh as a runnable command also uses the
#         plugin-global path form.
#
# Usage:
#   bats tests/skills/e64-s3-transition-script-path-refs.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_ROOT="$REPO_ROOT/plugins/gaia/skills"
  DEV_STORY_SKILL="$SKILLS_ROOT/gaia-dev-story/SKILL.md"
  CREATE_STORY_SKILL="$SKILLS_ROOT/gaia-create-story/SKILL.md"
}

# ---------- Preconditions ----------

@test "gaia-dev-story SKILL.md exists" {
  [ -f "$DEV_STORY_SKILL" ]
}

@test "gaia-create-story SKILL.md exists" {
  [ -f "$CREATE_STORY_SKILL" ]
}

# ---------- AC1 / AC2 — gaia-dev-story SKILL.md ----------

@test "AC1: gaia-dev-story SKILL.md has zero skill-local transition-story-status.sh references" {
  # Match `scripts/transition-story-status.sh` NOT preceded by `${CLAUDE_PLUGIN_ROOT}/`.
  # Use grep -E with a negative-lookbehind workaround: list all matches, then exclude
  # the plugin-global form.
  run bash -c "grep -nE 'scripts/transition-story-status\\.sh' '$DEV_STORY_SKILL' | grep -vE '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh' || true"
  [ "$status" -eq 0 ]
  # Expected: zero output lines (no skill-local refs remaining).
  [ -z "$output" ]
}

@test "AC2: gaia-dev-story Step 2 references plugin-global transition-story-status.sh" {
  # Step 2 fires the FRESH-mode in-progress transition.
  run bash -c "awk '/^### Step 2 -- Update Status/,/^### Step 2b/' '$DEV_STORY_SKILL' | grep -E '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh.*--to in-progress'"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-dev-story Step 10 references plugin-global transition-story-status.sh" {
  # Step 10 fires the review transition after gates pass.
  run bash -c "awk '/^### Step 10 -- Commit and Push/,/^### Step 11/' '$DEV_STORY_SKILL' | grep -E '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh.*--to review'"
  [ "$status" -eq 0 ]
}

@test "AC2: gaia-dev-story Step 15 references plugin-global transition-story-status.sh" {
  # Step 15 (Update Review Gate) fires the review transition.
  run bash -c "awk '/^### Step 15 -- Update Review Gate/,/^### Step 16/' '$DEV_STORY_SKILL' | grep -E '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh.*--to review'"
  [ "$status" -eq 0 ]
}

# ---------- AC3 — Cross-skill audit ----------

@test "AC3: gaia-create-story SKILL.md has zero skill-local transition-story-status.sh references" {
  run bash -c "grep -nE 'scripts/transition-story-status\\.sh' '$CREATE_STORY_SKILL' | grep -vE '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC3: every gaia-* SKILL.md uses the plugin-global path form" {
  # Walk every SKILL.md under skills/. For each line that mentions
  # `scripts/transition-story-status.sh` as a runnable command (i.e. not in
  # a sentence like "via transition-story-status.sh"), confirm the plugin-global
  # prefix is present.
  run bash -c "
    set -e
    found=0
    for skill_md in \"$SKILLS_ROOT\"/*/SKILL.md; do
      hits=\$(grep -nE 'scripts/transition-story-status\\.sh' \"\$skill_md\" | grep -vE '\\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/transition-story-status\\.sh' || true)
      if [ -n \"\$hits\" ]; then
        echo \"\$skill_md:\"
        echo \"\$hits\"
        found=1
      fi
    done
    exit \$found
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
