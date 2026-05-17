#!/usr/bin/env bats
# sister-skills-strategy-test-artifact-fallback.bats — AF-2026-05-16-4 regression guard
#
# Asserts that all skills referencing docs/test-artifacts/test-plan.md or
# docs/test-artifacts/traceability-matrix.md describe the strategy-fallback
# rule (flat -> strategy/ placement per ADR-072 / AF-2026-05-08-5).
#
# Covers 9 SKILL.md files (test-plan readers + traceability-matrix readers +
# gap-analysis-report readers, the last added by AF-2026-05-17-8):
#   - gaia-trace (primary patch — AF-2026-05-16-4)
#   - gaia-add-stories, gaia-create-epics, gaia-edit-test-plan,
#     gaia-memory-hygiene, gaia-readiness-check, gaia-sprint-plan,
#     gaia-test-gap-analysis (sibling test-plan readers — AF-2026-05-16-4)
#   - gaia-fill-test-gaps (gap-analysis-report reader — AF-2026-05-17-8)
#
# Positive assertion: each SKILL.md that mentions test-plan.md or
# traceability-matrix.md ALSO mentions the strategy/ placement on the same
# line or in the same Critical Rules / Step prose, OR references ADR-072.
#
# Negative assertion: no SKILL.md retains a HALT/fail-fast message that
# names ONLY the flat path without also mentioning the strategy/ form.
#
# Exemptions (descriptive prose, not runtime resolution — documented per
# Val finding F3/F4):
#   - gaia-trace/SKILL.md:L119 (Step 6b dispatch-verb HALT template)
#   - gaia-trace/SKILL.md:L131 (E88-S6 changelog entry — byte-stable)
#   - gaia-test-gap-analysis/SKILL.md:L149 (explanatory prose)
#   - gaia-add-feature/SKILL.md cascade matrix entries (already mention strategy/ at L487)
#   - gaia-ci-setup/SKILL.md doc cross-reference to test-plan §

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SKILLS=(
    gaia-trace
    gaia-add-stories
    gaia-create-epics
    gaia-edit-test-plan
    gaia-memory-hygiene
    gaia-readiness-check
    gaia-sprint-plan
    gaia-test-gap-analysis
    gaia-fill-test-gaps
  )
  export LC_ALL=C
}

@test "every in-scope SKILL.md exists" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
  done
}

@test "every in-scope SKILL.md mentions strategy/{test-plan,traceability-matrix,test-gap-analysis} placement" {
  # Regex widened in AF-2026-05-17-8 to admit `test-gap-analysis-*` for the
  # gaia-fill-test-gaps glob; pre-existing skills are unaffected.
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    if ! grep -qE 'strategy/(test-plan|traceability-matrix|test-gap-analysis)' "$f"; then
      echo "FAIL: $skill SKILL.md does not mention strategy/ placement"
      return 1
    fi
  done
}

@test "every in-scope SKILL.md references ADR-072 in its fallback rule" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    if ! grep -q 'ADR-072' "$f"; then
      echo "FAIL: $skill SKILL.md does not reference ADR-072"
      return 1
    fi
  done
}

@test "no SKILL.md retains a flat-only HALT/fail-fast for missing test-plan.md" {
  # A flat-only HALT is one that mentions docs/test-artifacts/test-plan.md
  # in a HALT/halt/fail-fast quoted message but NOT prd/prd.md or strategy/.
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    matches=$(grep -nE '(HALT|halt|fail fast|fail-fast).*"[^"]*docs/test-artifacts/test-plan\.md[^"]*"' "$f" 2>/dev/null \
              | grep -v 'strategy/' || true)
    if [ -n "$matches" ]; then
      echo "FAIL: $skill SKILL.md still contains flat-only HALT/fail-fast for test-plan.md:"
      echo "$matches"
      return 1
    fi
  done
}

@test "no SKILL.md retains a flat-only HALT/fail-fast for missing traceability-matrix.md" {
  for skill in "${SKILLS[@]}"; do
    f="$SKILLS_DIR/$skill/SKILL.md"
    matches=$(grep -nE '(HALT|halt|fail fast|fail-fast).*"[^"]*docs/test-artifacts/traceability-matrix\.md[^"]*"' "$f" 2>/dev/null \
              | grep -v 'strategy/' || true)
    if [ -n "$matches" ]; then
      echo "FAIL: $skill SKILL.md still contains flat-only HALT/fail-fast for traceability-matrix.md:"
      echo "$matches"
      return 1
    fi
  done
}
