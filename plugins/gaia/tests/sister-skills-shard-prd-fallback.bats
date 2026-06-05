#!/usr/bin/env bats
# sister-skills-shard-prd-fallback.bats — AF-2026-05-16-3 regression guard
#
# Asserts that all PRD-reader skills describe the sharded-PRD fallback rule
# (flat docs/planning-artifacts/prd.md → sharded docs/planning-artifacts/prd/prd.md → HALT).
#
# Covers 13 skills:
#   - gaia-trace (sibling AF-2026-05-16-2 patch)
#   - gaia-add-stories, gaia-create-arch, gaia-create-epics, gaia-create-ux,
#     gaia-edit-prd, gaia-edit-test-plan, gaia-memory-hygiene, gaia-nfr,
#     gaia-readiness-check, gaia-test-design, gaia-test-strategy,
#     gaia-validate-prd (AF-2026-05-16-3 patches)
#
# Positive assertion: each SKILL.md mentions the sharded path `prd/prd.md`
# at least once.
#
# Negative assertion: no SKILL.md still contains a flat-only HALT message
# (a "PRD not found at docs/planning-artifacts/prd.md" string that does NOT
# also mention `prd/prd.md` on the same line).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILLS=(
    gaia-trace
    gaia-add-stories
    gaia-create-arch
    gaia-create-epics
    gaia-create-ux
    gaia-edit-prd
    gaia-edit-test-plan
    gaia-memory-hygiene
    gaia-nfr
    gaia-readiness-check
    gaia-test-design
    gaia-test-strategy
    gaia-validate-prd
  )
  export LC_ALL=C
}

@test "every in-scope SKILL.md exists" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
  done
}

@test "every in-scope SKILL.md mentions the sharded path prd/prd.md" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    if ! grep -q 'prd/prd.md' "$f"; then
      echo "FAIL: $skill SKILL.md does not mention prd/prd.md"
      return 1
    fi
  done
}

@test "no SKILL.md contains a flat-only HALT or fail-fast message for missing prd.md" {
  # A flat-only line is one that (a) is a HALT/fail-fast verb and (b) names
  # docs/planning-artifacts/prd.md but NOT prd/prd.md on the same line.
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    # Lines that look like a HALT/fail-fast message naming the flat path
    matches=$(grep -nE '(HALT|fail fast|fail-fast|fail with).*"[^"]*docs/planning-artifacts/prd\.md[^"]*"' "$f" \
              | grep -v 'prd/prd.md' || true)
    if [ -n "$matches" ]; then
      echo "FAIL: $skill SKILL.md still contains flat-only HALT/fail-fast:"
      echo "$matches"
      return 1
    fi
  done
}

@test "every in-scope SKILL.md names the sharded-fallback rule for prd/prd.md" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    if ! grep -qE '(sharded-fallback rule|fall back to.*prd/prd\.md)' "$f"; then
      echo "FAIL: $skill SKILL.md does not document the sharded-fallback rule (sharded-fallback rule / fall back to .../prd/prd.md)"
      return 1
    fi
  done
}
