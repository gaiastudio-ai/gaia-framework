#!/usr/bin/env bats
# check-deps.bats — coverage for skills/gaia-dev-story/scripts/check-deps.sh
#
# Story: E57-S6 — promotion-chain-guard.sh (P0-3) + check-deps.sh (P1-1)
# Refs:  TC-DSS-05, FR-DSS-4, AC3, AC4, AC5

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  CHECK_DEPS="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/check-deps.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
}

teardown() { common_teardown; }

# Helper — write a story file with the given key, status, and depends_on list.
# $1 key, $2 status, $3 depends_on inline list (e.g. '["E1-S1"]' or '[]')
_write_story() {
  local key="$1" status="$2" deps="$3"
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
title: "Test"
status: $status
depends_on: $deps
---

# Story: Test
EOF
}

# ---------------------------------------------------------------------------
# AC3 — all deps done -> exit 0, no stderr noise
# ---------------------------------------------------------------------------

@test "check-deps: exits 0 when all deps are done, stderr quiet" {
  _write_story "E1-S1" "done" '[]'
  _write_story "E1-S2" "done" '[]'
  _write_story "E1-S3" "in-progress" '["E1-S1", "E1-S2"]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E1-S3-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "check-deps: exits 0 when depends_on is empty" {
  _write_story "E1-S1" "in-progress" '[]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E1-S1-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# AC4 — at least one dep not done -> exit 1, stderr lists offending dep + status
# ---------------------------------------------------------------------------

@test "check-deps: exits 1 when one dep is in-progress, names the dep + status" {
  _write_story "E2-S1" "done" '[]'
  _write_story "E2-S2" "in-progress" '[]'
  _write_story "E2-S3" "in-progress" '["E2-S1", "E2-S2"]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E2-S3-test.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"E2-S2"* ]]
  [[ "$stderr" == *"in-progress"* ]]
  # The done dep should NOT be listed
  [[ "$stderr" != *"E2-S1"* ]]
}

@test "check-deps: exits 1 when multiple deps not done, lists all of them" {
  _write_story "E3-S1" "review" '[]'
  _write_story "E3-S2" "backlog" '[]'
  _write_story "E3-S3" "in-progress" '["E3-S1", "E3-S2"]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E3-S3-test.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"E3-S1"* ]]
  [[ "$stderr" == *"review"* ]]
  [[ "$stderr" == *"E3-S2"* ]]
  [[ "$stderr" == *"backlog"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — referenced dep file missing -> exit 2, stderr names missing path
# ---------------------------------------------------------------------------

@test "check-deps: exits 2 when a depends_on key has no story file on disk" {
  _write_story "E4-S1" "in-progress" '["E4-S99"]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E4-S1-test.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"E4-S99"* ]]
}

@test "check-deps: exit 2 (missing file) takes precedence over exit 1 (status mismatch)" {
  _write_story "E5-S1" "in-progress" '[]'  # not done
  _write_story "E5-S2" "in-progress" '["E5-S1", "E5-S99"]'  # E5-S99 missing AND E5-S1 not done
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E5-S2-test.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"E5-S99"* ]]
}

# ---------------------------------------------------------------------------
# Usage errors
# ---------------------------------------------------------------------------

@test "check-deps: usage error when no story_path arg" {
  run "$CHECK_DEPS"
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [ "$status" -ne 2 ]
}

@test "check-deps: usage error when story file does not exist" {
  run "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/nope.md"
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [ "$status" -ne 2 ]
}

# ---------------------------------------------------------------------------
# Integration: cluster-7-chain shared fixture (Story Task 3 — fixture reuse).
# The fixture seeds E99-S1 in backlog. We layer two implementation-artifact
# story files onto a copy of the fixture and exercise the canonical
# happy-path: child story depends_on E99-S1; status=done -> exit 0.
# ---------------------------------------------------------------------------

@test "check-deps: cluster-7-chain fixture happy-path exits 0 with done deps" {
  local src
  src="$(cd "$BATS_TEST_DIRNAME/../../../tests/fixtures/cluster-7-chain" && pwd)"
  [ -d "$src" ]
  # Copy fixture into per-test temp so we never mutate the source fixture.
  cp -R "$src/." "$TEST_TMP/cluster-7-chain/"
  mkdir -p "$TEST_TMP/cluster-7-chain/docs/implementation-artifacts"
  cd "$TEST_TMP/cluster-7-chain"
  cat > "docs/implementation-artifacts/E99-S1-fixture-parent.md" <<'EOF'
---
template: 'story'
key: "E99-S1"
title: "Fixture parent"
status: done
depends_on: []
---

# Story: Fixture parent
EOF
  cat > "docs/implementation-artifacts/E99-S2-fixture-child.md" <<'EOF'
---
template: 'story'
key: "E99-S2"
title: "Fixture child"
status: in-progress
depends_on: ["E99-S1"]
---

# Story: Fixture child
EOF
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/cluster-7-chain/docs/implementation-artifacts/E99-S2-fixture-child.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# E57-S14 — cross-epic lookup (ADR-070 nested layout)
# ---------------------------------------------------------------------------

# Helper — write a nested-layout story file under epic-{epic}/stories/.
_write_nested_story() {
  local key="$1" status="$2" deps="$3" epic="$4"
  local dir="docs/implementation-artifacts/epic-${epic}/stories"
  mkdir -p "$dir"
  cat > "$dir/${key}-test.md" <<EOF
---
template: 'story'
key: "$key"
title: "Test"
status: $status
depends_on: $deps
---

# Story: Test
EOF
}

@test "TC-CDX-1: cross-epic dep (story in epic-E90, depends_on points at done story in epic-E87)" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  _write_nested_story "E87-S7" "done" '[]' "E87"
  _write_nested_story "E90-S99" "in-progress" '["E87-S7"]' "E90"
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E90/stories/E90-S99-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "TC-CDX-2: same-epic dep (depends_on points at sibling in epic-E88) — regression" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  _write_nested_story "E88-S1" "done" '[]' "E88"
  _write_nested_story "E88-S2" "in-progress" '["E88-S1"]' "E88"
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E88/stories/E88-S2-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "TC-CDX-3: truly-missing dep — exit 2 with stderr naming the missing key" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  _write_nested_story "E90-S99" "in-progress" '["E99-S99"]' "E90"
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E90/stories/E90-S99-test.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"E99-S99"* ]]
}

@test "TC-CDX-4: IMPLEMENTATION_ARTIFACTS_DIR env-var explicitly set — search constrained" {
  _write_nested_story "E87-S7" "done" '[]' "E87"
  _write_nested_story "E90-S99" "in-progress" '["E87-S7"]' "E90"
  # Point env-var at E90's stories/ only — dep in E87 must NOT be found.
  IMPLEMENTATION_ARTIFACTS_DIR="$TEST_TMP/docs/implementation-artifacts/epic-E90/stories" \
    run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E90/stories/E90-S99-test.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"E87-S7"* ]]
}

@test "TC-CDX-5: legacy flat-layout fixture (one-level deep) — exit 0 for matching dep" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  _write_story "E1-S1" "done" '[]'
  _write_story "E1-S2" "in-progress" '["E1-S1"]'
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/E1-S2-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# TC-CDX-6: regression — *-review-summary.md sibling MUST NOT match the
# dep glob and shadow the real nested story file.
#
# Scenario: a dep (E93-S1) lives at the nested per-epic layout
# (epic-E93/stories/E93-S1-*.md, status: done), AND a sibling file named
# E93-S1-review-summary.md sits flat under docs/implementation-artifacts/
# (review-output emitted by /gaia-run-all-reviews; no story frontmatter).
# Before the fix, check-deps.sh matched the flat review-summary.md FIRST
# and story-parse.sh returned `<unparseable>` on it, causing a false
# dependency-not-done HALT at exit 1. After the fix, the review-summary.md
# is skipped and the nested story file is matched, returning exit 0 with
# the dep correctly resolved to `status: done`.
# ---------------------------------------------------------------------------

@test "TC-CDX-6: regression — *-review-summary.md sibling does not shadow nested story file" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  # Real story at the nested per-epic path, status: done.
  _write_nested_story "E93-S1" "done" '[]' "E93"
  # Sibling review-summary.md file at the flat root with no story frontmatter
  # (mimics the artifact emitted by /gaia-run-all-reviews).
  cat > "docs/implementation-artifacts/E93-S1-review-summary.md" <<'EOF'
# Review summary for E93-S1

This is a /gaia-run-all-reviews artifact; it has no story frontmatter.
EOF
  # Consumer story depends_on the real E93-S1.
  _write_nested_story "E93-S3" "in-progress" '["E93-S1"]' "E93"
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E93/stories/E93-S3-test.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "TC-CDX-6b: regression — only review-summary.md exists for a key (no real story) — exit 2 missing" {
  unset IMPLEMENTATION_ARTIFACTS_DIR
  # Sibling review-summary.md ONLY — no real story file anywhere.
  cat > "docs/implementation-artifacts/E99-S99-review-summary.md" <<'EOF'
# Review summary for E99-S99 — but no real story file exists.
EOF
  _write_nested_story "E93-S3" "in-progress" '["E99-S99"]' "E93"
  run --separate-stderr "$CHECK_DEPS" "$TEST_TMP/docs/implementation-artifacts/epic-E93/stories/E93-S3-test.md"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"E99-S99"* ]]
}
