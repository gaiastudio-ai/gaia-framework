#!/usr/bin/env bats
# review-summary-gen-canonical-relpaths.bats — E97-S4
#
# Asserts review-summary-gen.sh derives CANONICAL_REPORT_RELPATHS from resolved
# variables (impl_artifacts / test_artifacts) so that on a .gaia/-canonical
# project the proof-of-execution check finds reports under
# .gaia/artifacts/implementation-artifacts/ and .gaia/artifacts/test-artifacts/,
# NOT the hardcoded docs/ prefix.

load 'test_helper.bash'

setup() {
  common_setup
  GEN="$SCRIPTS_DIR/review-summary-gen.sh"
  PROJECT_ROOT="$( cd "$TEST_TMP" && pwd -P )"
  export PROJECT_PATH="$PROJECT_ROOT"
  cd "$PROJECT_ROOT"
}

teardown() {
  unset PROJECT_PATH IMPLEMENTATION_ARTIFACTS TEST_ARTIFACTS
  common_teardown
}

# Seed a .gaia/-canonical project with a story in review status + all 6
# review reports under the canonical .gaia/artifacts/ tree.
seed_gaia_canonical() {
  local key="$1"
  mkdir -p \
    "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts/epic-Etest/stories" \
    "$PROJECT_ROOT/.gaia/artifacts/test-artifacts" \
    "$PROJECT_ROOT/.gaia/state"

  # Story file
  cat > "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts/epic-Etest/stories/${key}-test.md" << EOF
---
template: 'story'
key: "$key"
title: "test"
status: review
---

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
EOF

  # Six reports at the .gaia/artifacts/ canonical locations. F-28
  # (AF-2026-05-26-6): seed the FR-402 type-prefix-FIRST form under
  # implementation-artifacts/ — the form the reviewers actually write and the
  # corrected CANONICAL_REPORT_RELPATHS now expects.
  for r in \
    "implementation-artifacts/code-review-${key}.md" \
    "implementation-artifacts/qa-tests-${key}.md" \
    "implementation-artifacts/security-review-${key}.md" \
    "implementation-artifacts/test-automate-review-${key}.md" \
    "implementation-artifacts/test-review-${key}.md" \
    "implementation-artifacts/performance-review-${key}.md"; do
    mkdir -p "$(dirname "$PROJECT_ROOT/.gaia/artifacts/$r")"
    printf 'stub report\n' > "$PROJECT_ROOT/.gaia/artifacts/$r"
  done
}

@test ".gaia/-canonical fixture — summary writes to .gaia/artifacts/implementation-artifacts/" {
  seed_gaia_canonical "E99-S1"
  STORY_KEY=E99-S1 bash "$GEN" --story E99-S1 2>&1
  # Output is the review-summary; it MUST land under .gaia/artifacts/implementation-artifacts/
  [ -f "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts/E99-S1-review-summary.md" ]
  # NOT under the legacy docs/ tree
  [ ! -f "$PROJECT_ROOT/docs/implementation-artifacts/E99-S1-review-summary.md" ]
}

@test ".gaia/-canonical fixture — proof-of-execution finds reports without MISSING flags" {
  seed_gaia_canonical "E99-S2"
  STORY_KEY=E99-S2 bash "$GEN" --story E99-S2 2>&1
  # The summary body must NOT contain "MISSING" markers since all 6 reports
  # exist under .gaia/artifacts/.
  # Match the canonical MISSING markers emitted by review-summary-gen.sh
  # (script lines 497-532): "**Report:** MISSING — `path`...", "— MISSING:"
  # and "| MISSING |". Narrow grep avoids false positives from bats temp-dir
  # paths that embed the test name (which can contain "MISSING").
  run grep -E '\*\*Report:\*\* MISSING|— MISSING:|\| MISSING \|' "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts/E99-S2-review-summary.md"
  [ "$status" -ne 0 ]
}

@test "legacy-only-baseline — summary still writes to docs/implementation-artifacts/" {
  # Pre-migration install where only legacy docs/ exists.
  mkdir -p "$PROJECT_ROOT/docs/implementation-artifacts/epic-Etest/stories"
  mkdir -p "$PROJECT_ROOT/docs/test-artifacts"
  local key="E99-S3"
  cat > "$PROJECT_ROOT/docs/implementation-artifacts/epic-Etest/stories/${key}-test.md" << EOF
---
template: 'story'
key: "$key"
title: "test"
status: review
---

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
EOF
  # F-28 (AF-2026-05-26-6): type-first form under the legacy docs/ tree too.
  for r in \
    "docs/implementation-artifacts/code-review-${key}.md" \
    "docs/implementation-artifacts/qa-tests-${key}.md" \
    "docs/implementation-artifacts/security-review-${key}.md" \
    "docs/implementation-artifacts/test-automate-review-${key}.md" \
    "docs/implementation-artifacts/test-review-${key}.md" \
    "docs/implementation-artifacts/performance-review-${key}.md"; do
    mkdir -p "$(dirname "$PROJECT_ROOT/$r")"
    printf 'stub report\n' > "$PROJECT_ROOT/$r"
  done
  STORY_KEY=$key bash "$GEN" --story "$key" 2>&1
  # Legacy install: summary lands under docs/
  [ -f "$PROJECT_ROOT/docs/implementation-artifacts/${key}-review-summary.md" ]
  # Proof-of-execution clean on legacy install
  run grep -E 'MISSING' "$PROJECT_ROOT/docs/implementation-artifacts/${key}-review-summary.md"
  [ "$status" -ne 0 ]
}
