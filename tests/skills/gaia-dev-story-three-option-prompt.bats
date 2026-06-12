#!/usr/bin/env bats
# gaia-dev-story-three-option-prompt.bats — TC-DSH-02/03/04 regression guard for E55-S3
#
# Story: E55-S3 (Non-YOLO three-option prompt: approve/revise/validate)
# ADR: ADR-073 (/gaia-dev-story Planning-Gate Halt + Val Auto-Validation Loop)
#
# Validates the three-option prompt body inside the non-YOLO branch of the
# Step 4 planning gate region in
# `plugins/gaia/skills/gaia-dev-story/SKILL.md`:
#
#   AC1 — Test 1-3: exactly three labels `approve`, `revise`, `validate`
#                   present in the gate region (TC-DSH-02).
#   AC1 — Test 4:   no extra options (e.g., `skip`, `verify`, `cancel`)
#                   appear in the gate region's three-option block.
#   AC2 — Test 5:   `revise` branch instructs feedback collection +
#                   regeneration + re-ask (TC-DSH-03).
#   AC3 — Test 6:   `validate` branch routes to `gaia-val-validate` and
#                   re-asks the three-option question (TC-DSH-04).
#   AC3 — Test 7:   `validate` branch is unbounded (no iteration cap).
#   AC4 — Test 8:   `approve` advances to Step 5 TDD Red.
#   DoD — Test 9:   inline comment naming the three labels is present.
#
# The gate region is the contiguous block bounded by the literal markers:
#   <!-- planning gate begin -->
#   <!-- planning gate end -->
#
# The three-option prompt body is the segment that replaces the
# `<!-- three-option prompt body -->` placeholder marker.
#
# Usage:
#   bats tests/skills/gaia-dev-story-three-option-prompt.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILL_FILE="$SKILLS_DIR/gaia-dev-story/SKILL.md"

  GATE_BEGIN='<!-- planning gate begin -->'
  GATE_END='<!-- planning gate end -->'
}

# Extract the gate region (inclusive of markers) from SKILL.md to stdout.
extract_gate_region() {
  awk -v b="$GATE_BEGIN" -v e="$GATE_END" '
    index($0, b) { in_region = 1 }
    in_region    { print }
    index($0, e) { in_region = 0 }
  ' "$SKILL_FILE"
}

# Extract the non-YOLO sub-region from the gate region. The non-YOLO branch
# starts at the line containing 'is_yolo` returns non-zero' and ends at the
# line containing 'is_yolo` returns zero' (which begins the YOLO branch).
extract_non_yolo_region() {
  extract_gate_region | awk '
    /is_yolo` returns non-zero/ { in_region = 1 }
    /is_yolo` returns zero/     { in_region = 0 }
    in_region                    { print }
  '
}

# ---------- Preconditions ----------

@test "SKILL.md exists at gaia-dev-story skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "Gate region markers are present" {
  grep -qF "$GATE_BEGIN" "$SKILL_FILE"
  grep -qF "$GATE_END" "$SKILL_FILE"
}

@test "Non-YOLO sub-region is non-empty" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
}

# ---------- Test 1-3: three labels present (AC1, TC-DSH-02) ----------

@test "Test 1: non-YOLO region contains exact label \`approve\`" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE '\bapprove\b'
}

@test "Test 2: non-YOLO region contains exact label \`revise\`" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE '\brevise\b'
}

@test "Test 3: non-YOLO region contains exact label \`validate\`" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qE '\bvalidate\b'
}

# ---------- Test 4: no extra options (AC1) ----------

@test "Test 4a: non-YOLO region does NOT define a \`skip\` option handler" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  # The on-handler pattern documents what each labeled option does:
  # `  - On \`approve\`:`, `  - On \`revise\`:`, `  - On \`validate\`:`.
  # A fourth handler line for skip/verify/cancel would mean a fourth option.
  ! echo "$region" | grep -qE '^[[:space:]]*-[[:space:]]*On[[:space:]]+`skip`'
}

@test "Test 4b: non-YOLO region does NOT define a \`verify\` option handler" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  ! echo "$region" | grep -qE '^[[:space:]]*-[[:space:]]*On[[:space:]]+`verify`'
}

@test "Test 4c: non-YOLO region does NOT define a \`cancel\` option handler" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  ! echo "$region" | grep -qE '^[[:space:]]*-[[:space:]]*On[[:space:]]+`cancel`'
}

@test "Test 4d: non-YOLO region defines exactly three On-<label> handlers" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  count="$(echo "$region" | grep -cE '^[[:space:]]*-[[:space:]]*On[[:space:]]+`[a-z]+`:')"
  [ "$count" -eq 3 ]
}

# ---------- Test 5: revise branch behavior (AC2, TC-DSH-03) ----------

@test "Test 5a: non-YOLO region instructs feedback collection on \`revise\`" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 'revise.*feedback|feedback.*revise'
}

@test "Test 5b: non-YOLO region instructs plan regeneration on \`revise\`" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 'regenerate'
}

@test "Test 5c: non-YOLO region instructs re-ask of three-option question after revise" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 're-ask|re-asked|ask the three-option|ask the same three-option'
}

# ---------- Test 6: validate branch behavior (AC3, TC-DSH-04) ----------

@test "Test 6a: non-YOLO region routes \`validate\` to gaia-val-validate" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qF 'gaia-val-validate'
}

@test "Test 6b: non-YOLO region dispatches Val via the main-turn Agent tool" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 'main-turn Agent|gaia-val-validate|assert_agent_envelope'
}

@test "Test 6c: non-YOLO region renders findings on validate" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 'findings'
}

# ---------- Test 7: validate / revise are unbounded (AC3) ----------

@test "Test 7: non-YOLO region documents NO iteration cap on validate/revise" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  # The non-YOLO branch must NOT impose a 3-iteration cap (that's the YOLO
  # branch). It MUST explicitly note the loop is user-driven / unbounded.
  echo "$region" | grep -qiE 'no.*(iteration )?cap|unbounded|user-driven|loop indefinitely|indefinitely'
}

# ---------- Test 8: approve advances to Step 5 (AC4) ----------

@test "Test 8: non-YOLO region documents \`approve\` advances to Step 5 TDD Red" {
  region="$(extract_non_yolo_region)"
  [ -n "$region" ]
  echo "$region" | grep -qiE 'approve.*Step 5|approve.*TDD Red'
}

# ---------- Test 9: inline comment naming the three labels (DoD) ----------

@test "Test 9: gate region carries inline comment naming approve/revise/validate" {
  region="$(extract_gate_region)"
  [ -n "$region" ]
  # Inline comment must explicitly enumerate all three labels.
  echo "$region" | grep -qE '<!--[^>]*approve[^>]*revise[^>]*validate[^>]*-->'
}
