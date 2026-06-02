#!/usr/bin/env bats
# gaia-resume.bats — tests for the gaia-resume skill (E28-S173)
# Validates AC1 (SKILL.md frontmatter + procedural steps), AC2-AC4 (list/read/
# validate wrapping checkpoint.sh and the Proceed/Start fresh/Review prompt),
# and AC5 (discoverability via gaia-help.csv).

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-resume"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
}

teardown() { common_teardown; }

# ---------- AC1: SKILL.md exists with required frontmatter and steps ----------

@test "AC1: SKILL.md exists at plugins/gaia/skills/gaia-resume/SKILL.md" {
  [ -f "$SKILL_FILE" ]
}

@test "AC1: SKILL.md frontmatter contains required 'name' field equal to gaia-resume" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^name: gaia-resume'
}

@test "AC1: SKILL.md frontmatter contains 'description' field" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^description:'
}

@test "AC1: SKILL.md body documents when_to_use guidance" {
  # The SKILL.md must describe when the user should invoke /gaia-resume
  grep -qiE 'when[[:space:]]*to[[:space:]]*use|context[[:space:]]*loss|session[[:space:]]*break' "$SKILL_FILE"
}

@test "AC1: SKILL.md frontmatter contains 'allowed-tools' field" {
  frontmatter=$(awk 'BEGIN{in_fm=0;seen=0}/^---[[:space:]]*$/{if(seen==0){in_fm=1;seen=1;next}else if(in_fm==1){exit}}in_fm==1{print}' "$SKILL_FILE")
  echo "$frontmatter" | grep -q '^allowed-tools:'
}

@test "AC1: SKILL.md body contains procedural Steps section" {
  grep -qE '^## Steps|^### Step 1' "$SKILL_FILE"
}

# ---------- AC2: list checkpoints from _memory/checkpoints/ ----------

@test "AC2: SKILL.md documents listing checkpoints from .gaia/memory/checkpoints/" {
  grep -q '.gaia/memory/checkpoints' "$SKILL_FILE"
}

@test "AC2: SKILL.md excludes completed/ subdirectory from listing" {
  grep -q 'completed/' "$SKILL_FILE"
}

# ---------- AC3: invoke checkpoint.sh read to load state ----------

@test "AC3: SKILL.md invokes checkpoint.sh read" {
  grep -qE 'checkpoint\.sh[[:space:]]+read' "$SKILL_FILE"
}

# ---------- AC4: checkpoint.sh validate + Proceed/Start fresh/Review prompt ----------

@test "AC4: SKILL.md invokes checkpoint.sh validate" {
  grep -qE 'checkpoint\.sh[[:space:]]+validate' "$SKILL_FILE"
}

@test "AC4: SKILL.md documents validate exit 1 (drift) handling" {
  grep -qE 'exit[[:space:]]+1|exits?[[:space:]]*1|drift' "$SKILL_FILE"
}

@test "AC4: SKILL.md documents validate exit 2 (missing file) handling" {
  grep -qE 'exit[[:space:]]+2|exits?[[:space:]]*2|missing[[:space:]]+file' "$SKILL_FILE"
}

@test "AC4: SKILL.md surfaces Proceed / Start fresh / Review prompt on validation failure" {
  grep -q 'Proceed' "$SKILL_FILE"
  grep -qE 'Start[[:space:]]+fresh' "$SKILL_FILE"
  grep -q 'Review' "$SKILL_FILE"
}

# ---------- AC5: /gaia-resume discoverable via gaia-help ----------

@test "AC5: /gaia-resume is registered in gaia-help.csv" {
  # gaia-help.csv lives in the developer's project-root _gaia/_config/
  # directory, which sits outside the gaia-framework plugin checkout. In CI
  # the plugin repo is checked out standalone, so this file is not present
  # — skip rather than fail.
  GAIA_HELP_CSV="$BATS_TEST_DIRNAME/../../../../_gaia/_config/gaia-help.csv"
  if [ ! -f "$GAIA_HELP_CSV" ]; then
    skip "gaia-help.csv not present in this checkout (lives in project-root workspace)"
  fi
  grep -q 'gaia-resume' "$GAIA_HELP_CSV"
}
