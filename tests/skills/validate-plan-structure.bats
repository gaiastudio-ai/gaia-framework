#!/usr/bin/env bats
# validate-plan-structure.bats — plan-structure validator regression guard
#
# Validates the canonical plan-structure section list in gaia-dev-story SKILL.md.
#
# Validates the validate-plan-structure.sh script:
#
#   AC3 — Test 1: Helper script is shipped and executable.
#   AC3 — Test 2: Happy path — all 9 canonical sections present (REWORK)
#                 returns exit 0.
#   AC3 — Test 3: Happy path — new-feature plan (8 sections, no Root Cause)
#                 returns exit 0 when --rework is NOT passed.
#   AC3 — Test 4-12: Each individual missing section is reported with its
#                 name and exit non-zero. (Context, Implementation Steps,
#                 Files to Modify, Architecture Refs, UX Refs, Testing
#                 Strategy, Risks, Verification Plan, Root Cause REWORK).
#   AC4 — Test 13: Cyrillic homoglyph "Сontext" (U+0421) is treated as
#                 MISSING when the plan otherwise has no ASCII "Context".
#   DoD — Test 14: Script header carries usage comment listing all 9
#                 canonical sections.
#
# Usage:
#   bats tests/skills/validate-plan-structure.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VALIDATOR="$REPO_ROOT/plugins/gaia/skills/gaia-dev-story/scripts/validate-plan-structure.sh"
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Render a complete REWORK plan with all 9 canonical sections.
write_complete_rework_plan() {
  local out="$1"
  cat > "$out" <<'EOF'
# Plan

## Context
Some context goes here.

## Root Cause
Why this needed rework.

## Implementation Steps
- Step A
- Step B

## Files to Modify
- foo.sh
- bar.md

## Architecture Refs
ADR-073 applies.

## UX Refs
N/A.

## Testing Strategy
TDD red/green/refactor.

## Risks
None significant.

## Verification Plan
Run bats locally.
EOF
}

# Render a complete new-feature plan (no Root Cause section).
write_complete_feature_plan() {
  local out="$1"
  cat > "$out" <<'EOF'
# Plan

## Context
Fresh feature context.

## Implementation Steps
- Step A

## Files to Modify
- baz.sh

## Architecture Refs
ADR-073 applies.

## UX Refs
N/A.

## Testing Strategy
TDD red/green/refactor.

## Risks
Low.

## Verification Plan
Run bats locally.
EOF
}

# ---------- AC3 — script presence ----------

@test "AC3 Test 1: validate-plan-structure.sh is shipped and executable" {
  [ -x "$VALIDATOR" ]
}

# ---------- AC3 — happy path ----------

@test "AC3 Test 2: complete REWORK plan with all 9 sections passes" {
  plan="$TEST_TMPDIR/plan.md"
  write_complete_rework_plan "$plan"
  run "$VALIDATOR" --rework "$plan"
  [ "$status" -eq 0 ]
}

@test "AC3 Test 3: complete new-feature plan (8 sections, no Root Cause) passes without --rework" {
  plan="$TEST_TMPDIR/plan.md"
  write_complete_feature_plan "$plan"
  run "$VALIDATOR" "$plan"
  [ "$status" -eq 0 ]
}

# ---------- AC3 — each missing section is rejected ----------

# Helper to drop one section from a complete REWORK plan and assert miss.
assert_missing_section_rejects() {
  local section="$1"
  local plan="$TEST_TMPDIR/plan.md"
  write_complete_rework_plan "$plan"
  # Strip the "## $section" heading line (and its body until next heading or EOF).
  python3 - "$plan" "$section" <<'PYEOF'
import sys, re
path, target = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    lines = f.read().splitlines(keepends=True)
out = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('## '):
        # Match exact section name (after "## ")
        if stripped[3:].strip() == target:
            skip = True
            continue
        else:
            skip = False
    if not skip:
        out.append(line)
with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)
PYEOF
  run "$VALIDATOR" --rework "$plan"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$section"
}

@test "AC3 Test 4: missing 'Context' section rejected" {
  assert_missing_section_rejects "Context"
}

@test "AC3 Test 5: missing 'Root Cause' section rejected (REWORK only)" {
  assert_missing_section_rejects "Root Cause"
}

@test "AC3 Test 6: missing 'Implementation Steps' section rejected" {
  assert_missing_section_rejects "Implementation Steps"
}

@test "AC3 Test 7: missing 'Files to Modify' section rejected (TC-DSH-10)" {
  assert_missing_section_rejects "Files to Modify"
}

@test "AC3 Test 8: missing 'Architecture Refs' section rejected" {
  assert_missing_section_rejects "Architecture Refs"
}

@test "AC3 Test 9: missing 'UX Refs' section rejected" {
  assert_missing_section_rejects "UX Refs"
}

@test "AC3 Test 10: missing 'Testing Strategy' section rejected" {
  assert_missing_section_rejects "Testing Strategy"
}

@test "AC3 Test 11: missing 'Risks' section rejected" {
  assert_missing_section_rejects "Risks"
}

@test "AC3 Test 12: missing 'Verification Plan' section rejected" {
  assert_missing_section_rejects "Verification Plan"
}

# ---------- AC4 — Cyrillic homoglyph (T-38 mitigation) ----------

@test "AC4 Test 13: Cyrillic 'Сontext' homoglyph is treated as MISSING" {
  # Build a plan where the Context heading uses Cyrillic С (U+0421) instead
  # of ASCII C (U+0043). The validator MUST reject this as MISSING because
  # grep -F with literal ASCII "Context" cannot match the homoglyph.
  plan="$TEST_TMPDIR/plan.md"
  cat > "$plan" <<'EOF'
# Plan

## Сontext
This heading uses Cyrillic С (U+0421) — the section must NOT be matched
because the validator is looking for the ASCII spelling.

## Root Cause
Why.

## Implementation Steps
- A

## Files to Modify
- foo.sh

## Architecture Refs
ADR-073.

## UX Refs
N/A.

## Testing Strategy
TDD.

## Risks
None.

## Verification Plan
bats.
EOF
  run "$VALIDATOR" --rework "$plan"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "Context"
}

# ---------- DoD — script header ----------

@test "DoD Test 14: script header lists all 9 canonical sections in a usage comment" {
  for section in "Context" "Root Cause" "Implementation Steps" "Files to Modify" \
                 "Architecture Refs" "UX Refs" "Testing Strategy" "Risks" \
                 "Verification Plan"; do
    grep -qF "$section" "$VALIDATOR"
  done
}

# ---------- Bonus: shebang + strict mode ----------

@test "Bonus Test 15: script uses bash shebang and strict-mode flags" {
  head -1 "$VALIDATOR" | grep -qE "^#!/usr/bin/env bash$"
  grep -qE "^set -euo pipefail" "$VALIDATOR"
}

# ---------- Bonus: stdin input mode ----------

@test "Bonus Test 16: validator accepts plan content on stdin" {
  plan="$TEST_TMPDIR/plan.md"
  write_complete_feature_plan "$plan"
  run bash -c "cat \"$plan\" | \"$VALIDATOR\""
  [ "$status" -eq 0 ]
}
