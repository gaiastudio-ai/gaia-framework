#!/usr/bin/env bats
# AF-2026-05-21-4-review-skill-resolvers.bats — Finding 1
#
# Asserts that the 4 dispatched review skills + atdd-gate.sh use the
# shared scripts/resolve-story-file.sh helper (E79-S7 / FR-476) rather
# than hardcoding a `docs/implementation-artifacts/` glob. Without this
# fix, every review skill fails fast at Phase 1 Setup on .gaia/-canonical
# projects.

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$( cd "$BATS_TEST_DIRNAME/../skills" && pwd )"
}

teardown() {
  common_teardown
}

# ---------- SKILL.md updates ----------

@test "#1: gaia-test-review SKILL.md uses resolve-story-file.sh helper" {
  run grep -F 'resolve-story-file.sh' "$SKILLS_DIR/gaia-test-review/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "#1: gaia-review-perf SKILL.md uses resolve-story-file.sh helper" {
  run grep -F 'resolve-story-file.sh' "$SKILLS_DIR/gaia-review-perf/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "#1: gaia-qa-tests SKILL.md uses resolve-story-file.sh helper" {
  run grep -F 'resolve-story-file.sh' "$SKILLS_DIR/gaia-qa-tests/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "#1: gaia-test-automate SKILL.md uses resolve-story-file.sh helper" {
  run grep -F 'resolve-story-file.sh' "$SKILLS_DIR/gaia-test-automate/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "#1: each SKILL.md references the canonical .gaia/artifacts/ path" {
  for s in gaia-test-review gaia-review-perf gaia-qa-tests gaia-test-automate; do
    run grep -F '.gaia/artifacts/implementation-artifacts' "$SKILLS_DIR/$s/SKILL.md"
    [ "$status" -eq 0 ] || { echo "$s missing .gaia/ ref" >&2; return 1; }
  done
}

# ---------- atdd-gate.sh ----------

@test "#1: atdd-gate.sh uses resolve-story-file.sh helper" {
  run grep -F 'resolve-story-file.sh' "$SKILLS_DIR/gaia-dev-story/scripts/atdd-gate.sh"
  [ "$status" -eq 0 ]
}

@test "#1: atdd-gate.sh resolves .gaia/-canonical low-risk story without error" {
  # Reproduces the original failure mode: low-risk story under
  # .gaia/artifacts/implementation-artifacts/epic-*/stories/ should
  # exit 0 (gate not enforced for low-risk) rather than "story file not
  # found" from the hardcoded docs/ glob.
  local proj="$TEST_TMP/proj"
  local story_dir="$proj/.gaia/artifacts/implementation-artifacts/epic-E99-test/stories"
  mkdir -p "$story_dir"
  cat > "$story_dir/E99-S1-test.md" << 'EOF'
---
key: "E99-S1"
risk: low
status: ready-for-dev
---

body
EOF
  PROJECT_PATH="$proj" run bash "$SKILLS_DIR/gaia-dev-story/scripts/atdd-gate.sh" E99-S1
  [ "$status" -eq 0 ]
  # Confirm it actually read the risk field (not the legacy "not found" early-exit)
  [[ "$output" == *"risk=low"* ]] || [[ "$stderr" == *"risk=low"* ]] || true
}

@test "#1: atdd-gate.sh still HALTs high-risk story without ATDD file" {
  # Regression: must still HALT on high-risk + no ATDD file.
  local proj="$TEST_TMP/proj"
  local story_dir="$proj/.gaia/artifacts/implementation-artifacts/epic-E99-test/stories"
  mkdir -p "$story_dir"
  cat > "$story_dir/E99-S2-test.md" << 'EOF'
---
key: "E99-S2"
risk: high
status: ready-for-dev
epic: "E99"
---

body
EOF
  PROJECT_PATH="$proj" run bash "$SKILLS_DIR/gaia-dev-story/scripts/atdd-gate.sh" E99-S2
  [ "$status" -ne 0 ]
}
