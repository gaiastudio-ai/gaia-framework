#!/usr/bin/env bats
# gaia-dev-story-step2b-atdd.bats — TC-DSH-13/14 regression guard for E55-S5 (AC1, AC2)
#
# Story: E55-S5 (ATDD gate (Step 2b) + plan-structure validator + Figma graceful-degrade)
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
# PRD: FR-DSH-6 (high-risk stories MUST have an ATDD file)
#
# Validates:
#   AC1 — Test 1: Step 2b region is present in SKILL.md, bounded by
#                 begin/end markers `<!-- E55-S5: step 2b atdd gate begin/end -->`.
#   AC1 — Test 2: Step 2b invokes `atdd-gate.sh {story_key}`.
#   AC1 — Test 3: Step 2b instructs HALT on non-zero exit.
#   AC1 — Test 4: Step 2b mentions the expected glob pattern
#                 (`atdd-{epic_key}*.md` or `atdd-{story_key}*.md`) under
#                 `docs/test-artifacts/`.
#   AC1 — Test 5: Step 2b sits between Step 2 (Update Status) and Step 3
#                 (Create Feature Branch).
#   AC1 — Test 6: atdd-gate.sh helper script is shipped with the plugin and
#                 is executable.
#   AC1 — Test 7: atdd-gate.sh exits non-zero on high-risk story with no
#                 atdd-* file (HALT condition).
#   AC2 — Test 8: atdd-gate.sh exits 0 on medium-risk story (proceeds).
#   AC2 — Test 9: atdd-gate.sh exits 0 on low-risk story (proceeds).
#   AC2 — Test 10: atdd-gate.sh exits 0 on unset risk (proceeds).
#   AC1 boundary — Test 11: atdd-gate.sh exits 0 on high-risk story with an
#                  atdd-{epic_key}-*.md file present.
#   AC1 boundary — Test 12: atdd-gate.sh exits 0 on high-risk story with an
#                  atdd-{story_key}-*.md file present.
#
# Usage:
#   bats tests/skills/gaia-dev-story-step2b-atdd.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/SKILL.md"
  ATDD_GATE="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/atdd-gate.sh"

  GATE_BEGIN='<!-- E55-S5: step 2b atdd gate begin -->'
  GATE_END='<!-- E55-S5: step 2b atdd gate end -->'

  # Per-test working dir for fixtures.
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

extract_step2b_region() {
  awk -v b="$GATE_BEGIN" -v e="$GATE_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Build a fixture project root for atdd-gate.sh runs. The script must accept
# a project-root override (PROJECT_PATH or first-arg-derived) so tests can
# point it at a temp dir.
make_fixture_project() {
  local risk="$1"
  local story_key="$2"
  local epic_key="${story_key%-S*}"
  local proj="$TEST_TMPDIR/proj"
  mkdir -p "$proj/docs/implementation-artifacts"
  mkdir -p "$proj/docs/test-artifacts"
  cat > "$proj/docs/implementation-artifacts/${story_key}-fixture.md" <<EOF
---
key: "$story_key"
title: "Fixture story"
epic: "$epic_key"
status: in-progress
risk: $risk
---
# Story: Fixture story
EOF
  printf '%s\n' "$proj"
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

# ---------- AC1 — Step 2b region in SKILL.md ----------

@test "AC1 Test 1: Step 2b region markers are present in SKILL.md" {
  grep -qF "$GATE_BEGIN" "$SKILL_FILE"
  grep -qF "$GATE_END" "$SKILL_FILE"
}

@test "AC1 Test 2: Step 2b region invokes atdd-gate.sh with story_key" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE "atdd-gate\.sh"
}

@test "AC1 Test 3: Step 2b region instructs HALT on non-zero exit" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE "HALT"
}

@test "AC1 Test 4: Step 2b region documents the canonical ATDD glob patterns (canonical post-AF-21-23)" {
  region="$(extract_step2b_region)"
  [ -n "$region" ]
  # Must reference both the epic_key glob and the story_key glob and the
  # test-artifacts directory (canonical .gaia/artifacts/ or legacy docs/).
  echo "$region" | grep -qF "atdd-"
  echo "$region" | grep -qF "epic_key"
  echo "$region" | grep -qF "story_key"
  echo "$region" | grep -qE "(docs|\.gaia/artifacts)/test-artifacts"
}

@test "AC1 Test 5: Step 2b sits between Step 2 (Update Status) and Step 3 (Create Feature Branch)" {
  # Find line numbers for Step 2 header, Step 2b begin, Step 3 header.
  step2_line=$(grep -nF "### Step 2 -- Update Status" "$SKILL_FILE" | head -1 | cut -d: -f1)
  s2b_line=$(grep -nF "$GATE_BEGIN" "$SKILL_FILE" | head -1 | cut -d: -f1)
  step3_line=$(grep -nF "### Step 3 -- Create Feature Branch" "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$step2_line" ]
  [ -n "$s2b_line" ]
  [ -n "$step3_line" ]
  [ "$s2b_line" -gt "$step2_line" ]
  [ "$s2b_line" -lt "$step3_line" ]
}

# ---------- AC1 — atdd-gate.sh helper ----------

@test "AC1 Test 6: atdd-gate.sh helper is shipped and executable" {
  [ -x "$ATDD_GATE" ]
}

@test "AC1 Test 7: atdd-gate.sh exits non-zero on high-risk story with no atdd-* file" {
  proj="$(make_fixture_project high E99-S1)"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S1
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "atdd-"
}

# ---------- AC2 — non-high risk paths ----------

@test "AC2 Test 8: atdd-gate.sh exits 0 on medium-risk story even with no atdd-* file" {
  proj="$(make_fixture_project medium E99-S2)"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S2
  [ "$status" -eq 0 ]
}

@test "AC2 Test 9: atdd-gate.sh exits 0 on low-risk story" {
  proj="$(make_fixture_project low E99-S3)"
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S3
  [ "$status" -eq 0 ]
}

@test "AC2 Test 10: atdd-gate.sh exits 0 when risk frontmatter is unset" {
  # Build a story file without a risk: line.
  proj="$TEST_TMPDIR/proj-norisk"
  mkdir -p "$proj/docs/implementation-artifacts"
  mkdir -p "$proj/docs/test-artifacts"
  cat > "$proj/docs/implementation-artifacts/E99-S4-norisk.md" <<'EOF'
---
key: "E99-S4"
title: "No risk fixture"
epic: "E99"
status: in-progress
---
# Story: no risk
EOF
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S4
  [ "$status" -eq 0 ]
}

# ---------- AC1 boundary — high-risk WITH atdd file present ----------

@test "AC1 boundary Test 11: high-risk story with atdd-{epic_key}-*.md present passes" {
  proj="$(make_fixture_project high E99-S5)"
  cat > "$proj/docs/test-artifacts/atdd-E99-something.md" <<'EOF'
# ATDD: Epic-level scenarios for E99
EOF
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S5
  [ "$status" -eq 0 ]
}

@test "AC1 boundary Test 12: high-risk story with atdd-{story_key}-*.md present passes" {
  proj="$(make_fixture_project high E99-S6)"
  cat > "$proj/docs/test-artifacts/atdd-E99-S6-some-scenario.md" <<'EOF'
# ATDD: story-level scenarios for E99-S6
EOF
  run env PROJECT_PATH="$proj" "$ATDD_GATE" E99-S6
  [ "$status" -eq 0 ]
}
