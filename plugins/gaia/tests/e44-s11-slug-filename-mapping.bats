#!/usr/bin/env bats
# e44-s11-slug-filename-mapping.bats
#
# E44-S11 (TD-62) — Align tech-research artifact_type slug with the on-disk
# `technical-research.md` filename. Asserts unambiguous slug ↔ filename
# mapping in /gaia-tech-research SKILL.md and the canonical enum in
# /gaia-val-validate SKILL.md.
#
# Acceptance criteria covered:
#   AC1 — slug-to-filename mapping is unambiguous in the val-validate enum
#   AC2 — no `artifact_type=tech-research` references remain (post-rename)
#   AC3 — slug renamed to `technical-research` (default direction)

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export SKILLS_DIR
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC3 — slug renamed to `technical-research` in the producer skill
# ---------------------------------------------------------------------------

@test "gaia-tech-research SKILL.md uses artifact_type=technical-research" {
  grep -q 'artifact_type[[:space:]]*=[[:space:]]*technical-research' \
    "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

@test "gaia-tech-research SKILL.md references technical-research.md" {
  grep -q 'technical-research\.md' \
    "$SKILLS_DIR/gaia-tech-research/SKILL.md"
}

# ---------------------------------------------------------------------------
# AC2 — no `artifact_type=tech-research` references remain in any SKILL.md
# (the bare slug `tech-research` may still appear in prose / command names
# like `/gaia-tech-research`; only the artifact_type assignment is renamed.)
# ---------------------------------------------------------------------------

@test "no artifact_type=tech-research assignments remain in any SKILL.md" {
  ! grep -rEq 'artifact_type[[:space:]]*=[[:space:]]*tech-research([^-]|$)' \
    "$SKILLS_DIR"
}

# ---------------------------------------------------------------------------
# AC1 — slug-to-filename mapping is unambiguous in the canonical enum
# ---------------------------------------------------------------------------

@test "gaia-val-validate enum lists technical-research" {
  grep -qF '`technical-research`' \
    "$SKILLS_DIR/gaia-val-validate/SKILL.md"
}

@test "gaia-val-validate enum documents slug↔filename alignment" {
  grep -q 'technical-research.md' \
    "$SKILLS_DIR/gaia-val-validate/SKILL.md"
}
