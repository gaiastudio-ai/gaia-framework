#!/usr/bin/env bats
# e38-s7-reconcile-template-filter.bats
#
# ATDD failing acceptance tests for E38-S7 — Tighten sprint-state.sh reconcile
# glob to require `template: 'story'` frontmatter.
#
# PHASE: RED — these tests FAIL until reconcile_locate_story_file filters
# candidates by `template: 'story'` frontmatter and emits a structured
# per-candidate warning to stderr for each skipped file.
#
# Refs: FR-SPQG-4, NFR-SPQG-1, ADR-055
# Origin: sprint-27 development finding E42-S10 / F1
# Script (canonical): gaia-public/plugins/gaia/scripts/sprint-state.sh
# Script (wrapper):   gaia-public/plugins/gaia/skills/gaia-dev-story/scripts/sprint-state.sh

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

CANONICAL_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"
WRAPPER_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"

# Build a fixture sprint with one canonical story file plus a review report
# that shares the {key}-* glob. Returns the impl dir via stdout.
mk_fixture() {
  local key="$1" status="$2"
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"

  # Review report — sorts BEFORE the story file alphabetically (a < s) so the
  # bug surfaces: the unfiltered glob picks the review, not the canonical story.
  # No template: 'story' frontmatter on the review.
  cat > "$dir/${key}-aaa-code-review.md" <<EOF
---
template: 'review'
title: "Code review for ${key}"
verdict: PASSED
---

# Code Review for ${key}
EOF

  # Canonical story file with template: 'story' frontmatter
  cat > "$dir/${key}-story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Real story"
status: ${status}
---

# Story: Real

> **Status:** ${status}
EOF

  printf '%s' "$dir"
}

mk_yaml() {
  local yaml="$1" key="$2" status="$3"
  cat > "$yaml" <<EOF
sprint_id: "sprint-test"
stories:
  - key: "${key}"
    title: "Real story"
    status: "${status}"
EOF
}

# ---------------------------------------------------------------------------
# AC1: when a story file (template: story) and a review report co-exist for the
# same key, reconcile reads ONLY the story file. No parse error. No drift.
# ---------------------------------------------------------------------------
@test "E38-S7 AC1: reconcile uses the canonical story file when a review report co-exists (canonical script)" {
  local dir
  dir="$(mk_fixture "E99-S1" "in-progress")"
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S1" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]
  # No parse-error spam in output
  [[ "$output" != *"malformed frontmatter"* ]]
  [[ "$output" != *"parse error"* ]]
}

# ---------------------------------------------------------------------------
# AC1 (drift case): if the story file says "review" and yaml says "in-progress",
# reconcile MUST pick the canonical story (review) — not the review report —
# and correctly detect drift to "review", not error out.
# ---------------------------------------------------------------------------
@test "E38-S7 AC1: reconcile picks canonical story for drift detection, ignoring review sibling (canonical script)" {
  local dir
  dir="$(mk_fixture "E99-S2" "review")"
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S2" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]
  # Drift was detected and yaml updated to match the story file (review)
  grep -q 'status: "review"' "$yaml"
}

# ---------------------------------------------------------------------------
# AC2 / Val WARNING #1: per-candidate structured warning to stderr naming each
# skipped file. Format: `RECONCILE: {key} candidate {file} skipped — no \`template: 'story'\` frontmatter`
# ---------------------------------------------------------------------------
@test "E38-S7 AC2: reconcile emits structured stderr warning for each skipped non-story candidate" {
  local dir
  dir="$(mk_fixture "E99-S3" "in-progress")"
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S3" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]
  # The warning names the review file and references the missing template
  [[ "$output" == *"RECONCILE: E99-S3 candidate"* ]]
  [[ "$output" == *"E99-S3-aaa-code-review.md"* ]]
  [[ "$output" == *"template: 'story'"* ]]
  [[ "$output" == *"skipped"* ]]
}

# ---------------------------------------------------------------------------
# AC2 (continued): a .md file that is missing the template: field entirely is
# also skipped silently from the candidate set, with the same structured warning.
# ---------------------------------------------------------------------------
@test "E38-S7 AC2: reconcile warns and skips a .md file missing the template: field" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  # Canonical story
  cat > "$dir/E99-S4-story.md" <<'EOF'
---
template: 'story'
key: "E99-S4"
status: in-progress
---
# Story
> **Status:** in-progress
EOF
  # No-template sibling — note absence of template: in frontmatter
  cat > "$dir/E99-S4-orphan.md" <<'EOF'
---
key: "E99-S4"
title: "Sibling artifact with no template field"
---
# Orphan
EOF
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S4" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECONCILE: E99-S4 candidate"* ]]
  [[ "$output" == *"E99-S4-orphan.md"* ]]
  [[ "$output" == *"skipped"* ]]
}

# ---------------------------------------------------------------------------
# AC3: wrapper copy at skills/gaia-dev-story/scripts/sprint-state.sh behaves
# identically to the canonical on the same input set.
# ---------------------------------------------------------------------------
@test "E38-S7 AC3: wrapper copy produces same reconcile output as canonical (in-sync)" {
  local dir
  dir="$(mk_fixture "E99-S5" "review")"
  local yaml_a="$TEST_TMP/yaml-a.yaml"
  local yaml_b="$TEST_TMP/yaml-b.yaml"
  mk_yaml "$yaml_a" "E99-S5" "in-progress"
  mk_yaml "$yaml_b" "E99-S5" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml_a" \
    "$CANONICAL_SH" reconcile
  local canonical_status="$status"
  local canonical_yaml
  canonical_yaml="$(cat "$yaml_a")"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml_b" \
    "$WRAPPER_SH" reconcile
  local wrapper_status="$status"
  local wrapper_yaml
  wrapper_yaml="$(cat "$yaml_b")"

  [ "$canonical_status" -eq "$wrapper_status" ]
  [ "$canonical_yaml" = "$wrapper_yaml" ]
}

# ---------------------------------------------------------------------------
# AC4: idempotency — second run reports "no drift" once the first applied it.
# ---------------------------------------------------------------------------
@test "E38-S7 AC4: reconcile is idempotent — second run reports no drift" {
  local dir
  dir="$(mk_fixture "E99-S6" "review")"
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S6" "in-progress"

  # First run: drift detected and corrected
  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]

  # Second run: no drift
  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 divergences"* ]]
}

# ---------------------------------------------------------------------------
# Regression: when ONLY review siblings exist (no canonical story), reconcile
# must report a missing-story error (not silently dispatch to the review file).
# ---------------------------------------------------------------------------
@test "E38-S7 regression: reconcile errors when only review siblings exist (no canonical story)" {
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  cat > "$dir/E99-S7-review.md" <<'EOF'
---
template: 'review'
title: "Review for E99-S7"
---
# Review
EOF
  local yaml="$TEST_TMP/sprint-status.yaml"
  mk_yaml "$yaml" "E99-S7" "in-progress"

  run env \
    PROJECT_PATH="$TEST_TMP" \
    IMPLEMENTATION_ARTIFACTS="$dir" \
    SPRINT_STATUS_YAML="$yaml" \
    "$CANONICAL_SH" reconcile
  # cmd_reconcile exits 1 when story file lookup errors occur
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing story file"* ]] || [[ "$output" == *"not found"* ]]
}
