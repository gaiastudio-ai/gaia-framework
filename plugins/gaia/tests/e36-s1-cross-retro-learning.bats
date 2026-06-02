#!/usr/bin/env bats
# e36-s1-cross-retro-learning.bats
#
# ATDD failing acceptance tests for E36-S1 — Cross-retro learning loop
# (Epic E36, Retro Institutional Memory).
#
# PHASE: RED — all tests FAIL because the cross-retro detection + review
# extraction helpers do not yet exist (see Tasks 1-6 in E36-S1 story file).
#
# Refs: FR-RIM-1, FR-RIM-2, GR-RT-1, GR-RT-7, ADR-052, TC-RIM-1, TC-RIM-2
# Scripts under test (to be created in GREEN):
#   gaia-public/plugins/gaia/skills/gaia-retro/scripts/review-extract.sh
#   gaia-public/plugins/gaia/skills/gaia-retro/scripts/cross-retro-detect.sh
#   gaia-public/plugins/gaia/skills/gaia-retro/scripts/action-items-increment.sh

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

# Resolve the gaia-retro scripts dir relative to this bats file.
RETRO_SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts" && pwd)"
REVIEW_EXTRACT="$RETRO_SCRIPTS/review-extract.sh"
CROSS_RETRO="$RETRO_SCRIPTS/cross-retro-detect.sh"
AI_INCREMENT="$RETRO_SCRIPTS/action-items-increment.sh"

# ---------------------------------------------------------------------------
# Helper: compute expected theme hash the same way the implementation will.
# SHA-256(lowercase(trim(text))) — NFC normalization is a no-op for pure ASCII.
# ---------------------------------------------------------------------------
expected_hash() {
  local text="$1"
  # lowercase + trim leading/trailing whitespace
  local norm
  norm="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1;print}')"
  printf '%s' "$norm" | shasum -a 256 | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

mk_retro_with_actions() {
  local path="$1" sprint_id="$2"; shift 2
  mkdir -p "$(dirname "$path")"
  {
    printf -- "---\nsprint_id: \"%s\"\n---\n\n# Retrospective %s\n\n## Action Items\n\n" "$sprint_id" "$sprint_id"
    for text in "$@"; do
      printf -- "- %s\n" "$text"
    done
  } > "$path"
}

mk_review_artifact() {
  local path="$1" verdict="$2" title="$3"
  mkdir -p "$(dirname "$path")"
  {
    printf -- "---\nsprint_id: \"sprint-test\"\n---\n\n# %s\n\n" "$title"
    printf -- "**Verdict:** %s\n\n" "$verdict"
    printf -- "## Key Findings\n\n- finding-1\n- finding-2\n"
  } > "$path"
}

mk_action_items_yaml() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  {
    printf -- "# Action Items\n"
    printf -- "items:\n"
    while [ $# -ge 3 ]; do
      local id="$1" text="$2" hash="$3"; shift 3
      printf -- "  - id: %s\n    sprint_id: \"sprint-1\"\n    text: \"%s\"\n    theme_hash: \"sha256:%s\"\n    escalation_count: 0\n" \
        "$id" "$text" "$hash"
    done
  } > "$path"
}

# ===========================================================================
# AC1 — systemic theme detection + escalation_count increment (TC-RIM-1, FR-RIM-1)
# ===========================================================================

@test "AC1: 2+ prior retros sharing theme flagged systemic and escalation_count increments" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist — RED phase expected to fail here"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"

  mk_retro_with_actions "$retros_dir/retrospective-sprint-1.md" "sprint-1" "Flaky E2E tests"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-2.md" "sprint-2" "Flaky E2E tests"

  local hash
  hash="$(expected_hash "Flaky E2E tests")"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Flaky E2E tests" "$hash"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-3"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "systemic"
  grep -q "escalation_count: 1" "$ai_yaml"
}

# ===========================================================================
# AC2 — review artifact verdicts appear in data-driven findings block (TC-RIM-2)
# ===========================================================================

@test "AC2: review verdicts surfaced in data-driven findings block" {
  [ -x "$REVIEW_EXTRACT" ] || skip "GUARD: review-extract.sh does not exist — RED phase expected to fail here"

  local sprint_dir="$TEST_TMP/impl"
  mk_review_artifact "$sprint_dir/code-review-sprint-test.md"        "PASSED"   "Code Review"
  mk_review_artifact "$sprint_dir/security-review-sprint-test.md"    "FAILED"   "Security Review"
  mk_review_artifact "$sprint_dir/qa-tests-sprint-test.md"           "PASSED"   "QA Tests"
  mk_review_artifact "$sprint_dir/performance-review-sprint-test.md" "PARTIAL"  "Performance Review"

  run "$REVIEW_EXTRACT" --impl-dir "$sprint_dir" --sprint-id "sprint-test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "code-review"
  echo "$output" | grep -q "PASSED"
  echo "$output" | grep -q "FAILED"
  echo "$output" | grep -q "PARTIAL"
}

# ===========================================================================
# AC3 — no prior retros → zero escalations, no error
# ===========================================================================

@test "AC3: no prior retros — detection completes with zero escalations" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist — RED phase expected to fail here"

  local retros_dir="$TEST_TMP/empty-retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mkdir -p "$retros_dir"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Any theme" "$(expected_hash "Any theme")"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-3"
  [ "$status" -eq 0 ]
  # escalation_count unchanged
  grep -q "escalation_count: 0" "$ai_yaml"
}

# ===========================================================================
# AC-EC1 — prior retro with no Action Items section contributes zero themes
# ===========================================================================

@test "AC-EC1: retro file missing Action Items section contributes zero themes" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mkdir -p "$retros_dir"
  printf -- "---\nsprint_id: \"sprint-1\"\n---\n\n# Retro sprint-1\n\n(no action items section)\n" \
    > "$retros_dir/retrospective-sprint-1.md"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Anything" "$(expected_hash "Anything")"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-2"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 0" "$ai_yaml"
}

# ===========================================================================
# AC-EC2 — missing action-items.yaml → warning logged, retro continues
# ===========================================================================

@test "AC-EC2: missing action-items.yaml — non-blocking warning, exit 0" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-1.md" "sprint-1" "Flaky tests"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-2.md" "sprint-2" "Flaky tests"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$TEST_TMP/does-not-exist.yaml" --current-sprint "sprint-3"
  [ "$status" -eq 0 ]
  # combined output should include a warning token
  echo "$output" | grep -qiE "warn|skip"
}

# ===========================================================================
# AC-EC3 — same sprint, same theme hash → increment exactly once
# ===========================================================================

@test "AC-EC3: same sprint + same hash increments once, not twice" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  # Prior sprint 1 has the theme twice.
  mk_retro_with_actions "$retros_dir/retrospective-sprint-1.md" "sprint-1" "Flaky tests" "flaky tests"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-2.md" "sprint-2" "Flaky tests"

  local hash
  hash="$(expected_hash "Flaky tests")"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Flaky tests" "$hash"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-3"
  [ "$status" -eq 0 ]
  # Systemic across 2 distinct sprints → exactly one increment.
  grep -q "escalation_count: 1" "$ai_yaml"
}

# ===========================================================================
# AC-EC4 — malformed review artifact → UNKNOWN verdict + parse-warning
# ===========================================================================

@test "AC-EC4: malformed review artifact yields UNKNOWN verdict" {
  [ -x "$REVIEW_EXTRACT" ] || skip "GUARD: review-extract.sh does not exist"

  local sprint_dir="$TEST_TMP/impl"
  mkdir -p "$sprint_dir"
  # no Verdict line
  printf -- "---\nsprint_id: \"sprint-test\"\n---\n\n# Code Review\n\n(truncated)\n" \
    > "$sprint_dir/code-review-sprint-test.md"

  run "$REVIEW_EXTRACT" --impl-dir "$sprint_dir" --sprint-id "sprint-test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "UNKNOWN"
}

# ===========================================================================
# AC-EC5 — only prior-sprint review artifacts present → empty findings
# ===========================================================================

@test "AC-EC5: prior-sprint reviews do not leak into current-sprint findings" {
  [ -x "$REVIEW_EXTRACT" ] || skip "GUARD: review-extract.sh does not exist"

  local sprint_dir="$TEST_TMP/impl"
  mk_review_artifact "$sprint_dir/code-review-sprint-99.md" "PASSED" "Code Review"
  # the current sprint is sprint-test; artifact above carries sprint-99 in frontmatter
  # rewrite its sprint_id to sprint-99 to model prior-sprint leakage:
  sed -i.bak 's/sprint-test/sprint-99/' "$sprint_dir/code-review-sprint-99.md" || true
  rm -f "$sprint_dir/code-review-sprint-99.md.bak"

  run "$REVIEW_EXTRACT" --impl-dir "$sprint_dir" --sprint-id "sprint-test"
  [ "$status" -eq 0 ]
  # No current-sprint review artifacts found.
  echo "$output" | grep -qiE "no review artifacts|empty"
}

# ===========================================================================
# AC-EC6 — orphan AI-{n} reference → logged, skipped, no crash
# ===========================================================================

@test "AC-EC6: orphan AI-{n} reference does not crash the scanner" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mkdir -p "$retros_dir"
  # Retro references AI-42 which does not exist in action-items.yaml.
  {
    printf -- "---\nsprint_id: \"sprint-1\"\n---\n\n## Action Items\n\n- AI-42 : nonexistent ref\n"
  } > "$retros_dir/retrospective-sprint-1.md"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Some theme" "$(expected_hash "Some theme")"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-2"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# AC-EC9 — empty / zero-byte retro file contributes zero themes
# ===========================================================================

@test "AC-EC9: empty retro file does not produce a parse error" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mkdir -p "$retros_dir"
  : > "$retros_dir/retrospective-sprint-1.md"   # zero-byte
  mk_action_items_yaml "$ai_yaml" "AI-1" "Something" "$(expected_hash "Something")"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-2"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 0" "$ai_yaml"
}

# ===========================================================================
# AC-EC10 — mixed-case / whitespace themes normalize to the same hash
# ===========================================================================

@test "AC-EC10: mixed-case and whitespace variants hash identically" {
  [ -x "$CROSS_RETRO" ] || skip "GUARD: cross-retro-detect.sh does not exist"

  local retros_dir="$TEST_TMP/retros"
  local ai_yaml="$TEST_TMP/action-items.yaml"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-1.md" "sprint-1" "Flaky tests"
  mk_retro_with_actions "$retros_dir/retrospective-sprint-2.md" "sprint-2" " FLAKY TESTS "
  mk_retro_with_actions "$retros_dir/retrospective-sprint-3.md" "sprint-3" "flaky tests"

  local hash
  hash="$(expected_hash "Flaky tests")"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Flaky tests" "$hash"

  run "$CROSS_RETRO" --retros-dir "$retros_dir" --action-items "$ai_yaml" --current-sprint "sprint-4"
  [ "$status" -eq 0 ]
  # Three distinct sprints share the same normalized hash → one increment.
  grep -q "escalation_count: 1" "$ai_yaml"
}

# ===========================================================================
# action-items-increment.sh — unit test for the writer (AC1, EC-8)
# ===========================================================================

@test "writer: increment is idempotent per (sprint_id, theme_hash)" {
  [ -x "$AI_INCREMENT" ] || skip "GUARD: action-items-increment.sh does not exist"

  local ai_yaml="$TEST_TMP/action-items.yaml"
  local hash; hash="$(expected_hash "Shared theme")"
  mk_action_items_yaml "$ai_yaml" "AI-1" "Shared theme" "$hash"

  # First increment should succeed.
  run "$AI_INCREMENT" --file "$ai_yaml" --theme-hash "$hash" --sprint-id "sprint-9"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 1" "$ai_yaml"

  # Second invocation for the SAME (sprint_id, theme_hash) is a no-op.
  run "$AI_INCREMENT" --file "$ai_yaml" --theme-hash "$hash" --sprint-id "sprint-9"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 1" "$ai_yaml"

  # Different sprint_id → increments again.
  run "$AI_INCREMENT" --file "$ai_yaml" --theme-hash "$hash" --sprint-id "sprint-10"
  [ "$status" -eq 0 ]
  grep -q "escalation_count: 2" "$ai_yaml"
}

# ===========================================================================
# SKILL.md integration — Step 1b and Step 5b must be present
# ===========================================================================

@test "SKILL.md declares Step 1b (Review Report Extraction)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -qE "Step 1b.*Review Report Extraction" "$skill"
}

@test "SKILL.md declares Step 5b (Cross-Retro Pattern Detection)" {
  local skill="$BATS_TEST_DIRNAME/../skills/gaia-retro/SKILL.md"
  [ -f "$skill" ]
  grep -qE "Step 5b.*Cross-Retro Pattern Detection" "$skill"
}
