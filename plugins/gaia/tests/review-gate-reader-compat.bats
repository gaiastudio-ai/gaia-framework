#!/usr/bin/env bats
# review-gate-reader-compat.bats — column-compatibility tests for Review Gate
# table readers.
#
# The Review Gate table was extended from 3 columns (| Review | Status | Report |)
# to 4 columns (| Review | Status | Report | Reviewed SHA |). Every non-test
# reader must handle BOTH shapes without crashing or misreading verdicts.
#
# Fixture taxonomy:
#   3-col  — legacy three-column table (no Reviewed SHA)
#   4-col  — current four-column table (with Reviewed SHA)
#   writer — real writer output (init-review-gate.sh + review-gate.sh update)
#
# Story keys: E900-* synthetic range only.

load 'test_helper.bash'

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
  common_setup
  export PROJECT_PATH="$TEST_TMP"
  export REVIEW_GATE_PROOF_OF_EXECUTION=off
  # Flat implementation-artifacts layout.
  ART="$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$ART"
  # Ensure .gaia layout exists for scripts that prefer it.
  GAIA_ART="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$GAIA_ART"
  mkdir -p "$TEST_TMP/.gaia/state"
  mkdir -p "$TEST_TMP/.gaia/config"
  # Seed a minimal project-config.yaml for scripts that require it.
  cat > "$TEST_TMP/.gaia/config/project-config.yaml" <<'YAML'
project:
  name: compat-test
stacks:
  - id: shell
    path: "."
YAML
  export PROJECT_ROOT="$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$ART"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture generators
# ---------------------------------------------------------------------------

# Three-column (legacy) story fixture.
_seed_3col() {
  local key="$1" verdict="${2:-UNVERIFIED}"
  cat > "$ART/${key}-compat.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Compat test ${key}"
status: "in-progress"
priority: "medium"
size: "M"
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
epic_id: "E900"
points: 3
dependencies: []
---

# Story: Compat test ${key}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | ${verdict} | --- |
| QA Tests | ${verdict} | --- |
| Security Review | ${verdict} | --- |
| Test Automation | ${verdict} | --- |
| Test Review | ${verdict} | --- |
| Performance Review | ${verdict} | --- |

> Story moves to \`done\` only when ALL reviews show PASSED.
EOF
}

# Four-column (current) story fixture.
_seed_4col() {
  local key="$1" verdict="${2:-UNVERIFIED}" sha="${3:-abc1234}"
  cat > "$ART/${key}-compat.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Compat test ${key}"
status: "in-progress"
priority: "medium"
size: "M"
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
epic_id: "E900"
points: 3
dependencies: []
---

# Story: Compat test ${key}

## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | ${verdict} | --- | ${sha} |
| QA Tests | ${verdict} | --- | ${sha} |
| Security Review | ${verdict} | --- | ${sha} |
| Test Automation | ${verdict} | --- | ${sha} |
| Test Review | ${verdict} | --- | ${sha} |
| Performance Review | ${verdict} | --- | ${sha} |

> Story moves to \`done\` only when ALL reviews show PASSED.
EOF
}

# Mixed-verdict fixture with both PASSED and FAILED rows (4-col).
_seed_4col_mixed() {
  local key="$1" sha="${2:-abc1234}"
  cat > "$ART/${key}-compat.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Compat test ${key}"
status: "in-progress"
priority: "medium"
size: "M"
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
epic_id: "E900"
points: 3
dependencies: []
---

# Story: Compat test ${key}

## Review Gate

| Review | Status | Report | Reviewed SHA |
|--------|--------|--------|--------------|
| Code Review | PASSED | cr-report.md | ${sha} |
| QA Tests | FAILED | qa-report.md | ${sha} |
| Security Review | PASSED | sec-report.md | ${sha} |
| Test Automation | UNVERIFIED | --- |  |
| Test Review | PASSED | tr-report.md | ${sha} |
| Performance Review | UNVERIFIED | --- |  |

> Story moves to \`done\` only when ALL reviews show PASSED.
EOF
}

# Writer-produced fixture: seed via init-review-gate.sh, then optionally
# update one gate via review-gate.sh.
_seed_writer() {
  local key="$1"
  local init_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/init-review-gate.sh"
  # Create a bare story file without a Review Gate section.
  cat > "$ART/${key}-compat.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Compat test ${key}"
status: "in-progress"
priority: "medium"
size: "M"
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
epic_id: "E900"
points: 3
dependencies: []
---

# Story: Compat test ${key}
EOF
  # Seed via the real init-review-gate.sh writer.
  "$init_script" "$ART/${key}-compat.md"
}

# ---------------------------------------------------------------------------
# 1. Shared library: review-gate-table.sh (parse_review_gate_row)
# ---------------------------------------------------------------------------

@test "review-gate-table.sh parse_review_gate_row: parses 3-col row" {
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED | report.md |"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate=Code Review"* ]]
  [[ "$output" == *"status=PASSED"* ]]
  [[ "$output" == *"report=report.md"* ]]
  [[ "$output" == *"reviewed_sha=absent"* ]]
}

@test "review-gate-table.sh parse_review_gate_row: parses 4-col row" {
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED | report.md | abc1234 |"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate=Code Review"* ]]
  [[ "$output" == *"status=PASSED"* ]]
  [[ "$output" == *"report=report.md"* ]]
  [[ "$output" == *"reviewed_sha=abc1234"* ]]
}

@test "review-gate-table.sh parse_review_gate_row: 4-col with empty SHA reads as absent" {
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | UNVERIFIED | --- |  |"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reviewed_sha=absent"* ]]
}

@test "review-gate-table.sh parse_review_gate_row: rejects 2-col row" {
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_row "| Code Review | PASSED |"
  [ "$status" -eq 1 ]
}

@test "review-gate-table.sh parse_review_gate_row: rejects 5-col row" {
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_row "| a | b | c | d | e |"
  [ "$status" -eq 1 ]
}

@test "review-gate-table.sh parse_review_gate_table: reads 3-col story" {
  _seed_3col E900-S1 PASSED
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_table "$ART/E900-S1-compat.md"
  [ "$status" -eq 0 ]
  # Should have 6 lines of TSV output.
  local line_count
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 6 ]
  # Every SHA should be "absent" for 3-col.
  [[ "$output" != *"abc1234"* ]]
  # First row should be Code Review.
  printf '%s\n' "$output" | head -1 | grep -qF 'Code Review'
}

@test "review-gate-table.sh parse_review_gate_table: reads 4-col story" {
  _seed_4col E900-S2 PASSED abc1234
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_table "$ART/E900-S2-compat.md"
  [ "$status" -eq 0 ]
  local line_count
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 6 ]
  # SHA should be present.
  [[ "$output" == *"abc1234"* ]]
}

@test "review-gate-table.sh parse_review_gate_table: reads writer-produced story" {
  _seed_writer E900-S3
  source "$SCRIPTS_DIR/lib/review-gate-table.sh"
  run parse_review_gate_table "$ART/E900-S3-compat.md"
  [ "$status" -eq 0 ]
  local line_count
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 6 ]
}

# ---------------------------------------------------------------------------
# 2. review-gate.sh status subcommand
# ---------------------------------------------------------------------------

@test "review-gate.sh status: reads 3-col story" {
  _seed_3col E900-S10 PASSED
  run "$SCRIPTS_DIR/review-gate.sh" status --story E900-S10
  [ "$status" -eq 0 ]
  # Output is JSON; verify it includes all six gates.
  printf '%s\n' "$output" | jq -e '.gates["Code Review"]' >/dev/null
  printf '%s\n' "$output" | jq -e '.gates["Performance Review"]' >/dev/null
  local cr
  cr="$(printf '%s\n' "$output" | jq -r '.gates["Code Review"]')"
  [ "$cr" = "PASSED" ]
}

@test "review-gate.sh status: reads 4-col story" {
  _seed_4col E900-S11 PASSED abc1234
  run "$SCRIPTS_DIR/review-gate.sh" status --story E900-S11
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.gates["Code Review"]' >/dev/null
  local cr
  cr="$(printf '%s\n' "$output" | jq -r '.gates["Code Review"]')"
  [ "$cr" = "PASSED" ]
}

@test "review-gate.sh status: reads writer-produced story" {
  _seed_writer E900-S12
  run "$SCRIPTS_DIR/review-gate.sh" status --story E900-S12
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.gates' >/dev/null
  local cr
  cr="$(printf '%s\n' "$output" | jq -r '.gates["Code Review"]')"
  [ "$cr" = "UNVERIFIED" ]
}

# ---------------------------------------------------------------------------
# 3. review-gate.sh check subcommand
# ---------------------------------------------------------------------------

@test "review-gate.sh check: all-PASSED 3-col returns 0" {
  _seed_3col E900-S20 PASSED
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S20
  [ "$status" -eq 0 ]
}

@test "review-gate.sh check: all-PASSED 4-col returns 0" {
  _seed_4col E900-S21 PASSED abc1234
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S21
  [ "$status" -eq 0 ]
}

@test "review-gate.sh check: all-PASSED writer-produced returns 0 after updates" {
  _seed_writer E900-S22
  # Update all six gates to PASSED via the real writer.
  local gates=("Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review")
  local g
  for g in "${gates[@]}"; do
    "$SCRIPTS_DIR/review-gate.sh" update --story E900-S22 --gate "$g" --verdict PASSED
  done
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S22
  [ "$status" -eq 0 ]
}

@test "review-gate.sh check: UNVERIFIED 3-col returns 1" {
  _seed_3col E900-S23 UNVERIFIED
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S23
  [ "$status" -eq 1 ]
}

@test "review-gate.sh check: UNVERIFIED 4-col returns 1" {
  _seed_4col E900-S24 UNVERIFIED abc1234
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S24
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 4. review-gate.sh review-gate-check subcommand
# ---------------------------------------------------------------------------

@test "review-gate.sh review-gate-check: COMPLETE on 3-col all-PASSED" {
  _seed_3col E900-S30 PASSED
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story E900-S30
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate: COMPLETE"* ]]
}

@test "review-gate.sh review-gate-check: COMPLETE on 4-col all-PASSED" {
  _seed_4col E900-S31 PASSED abc1234
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story E900-S31
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate: COMPLETE"* ]]
}

@test "review-gate.sh review-gate-check: PENDING on 3-col all-UNVERIFIED" {
  _seed_3col E900-S32 UNVERIFIED
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story E900-S32
  [ "$status" -eq 2 ]
  [[ "$output" == *"Review Gate: PENDING"* ]]
}

@test "review-gate.sh review-gate-check: BLOCKED on 4-col mixed verdicts" {
  _seed_4col_mixed E900-S33
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story E900-S33
  [ "$status" -eq 1 ]
  [[ "$output" == *"Review Gate: BLOCKED"* ]]
  [[ "$output" == *"QA Tests"* ]]
}

@test "review-gate.sh review-gate-check: COMPLETE on writer-produced after full update" {
  _seed_writer E900-S34
  local gates=("Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review")
  local g
  for g in "${gates[@]}"; do
    "$SCRIPTS_DIR/review-gate.sh" update --story E900-S34 --gate "$g" --verdict PASSED
  done
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story E900-S34
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate: COMPLETE"* ]]
}

# ---------------------------------------------------------------------------
# 5. review-gate.sh update: round-trip through both table shapes
# ---------------------------------------------------------------------------

@test "review-gate.sh update: writes to 3-col story, re-read via status" {
  _seed_3col E900-S40 UNVERIFIED
  "$SCRIPTS_DIR/review-gate.sh" update --story E900-S40 --gate "Code Review" --verdict PASSED
  run "$SCRIPTS_DIR/review-gate.sh" status --story E900-S40
  [ "$status" -eq 0 ]
  local cr
  cr="$(printf '%s\n' "$output" | jq -r '.gates["Code Review"]')"
  [ "$cr" = "PASSED" ]
  # Other gates remain UNVERIFIED.
  local qa
  qa="$(printf '%s\n' "$output" | jq -r '.gates["QA Tests"]')"
  [ "$qa" = "UNVERIFIED" ]
}

@test "review-gate.sh update: writes to 4-col story, re-read via status" {
  _seed_4col E900-S41 UNVERIFIED abc1234
  "$SCRIPTS_DIR/review-gate.sh" update --story E900-S41 --gate "QA Tests" --verdict FAILED
  run "$SCRIPTS_DIR/review-gate.sh" status --story E900-S41
  [ "$status" -eq 0 ]
  local qa
  qa="$(printf '%s\n' "$output" | jq -r '.gates["QA Tests"]')"
  [ "$qa" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# 6. review-gate-check.sh (commit-bound checker)
# ---------------------------------------------------------------------------

@test "review-gate-check.sh: reads 3-col all-PASSED, exits PENDING (no SHA binding)" {
  _seed_3col E900-S50 PASSED
  # 3-col has no SHA, so every row is stale relative to bind-head -> PENDING.
  run "$SCRIPTS_DIR/review-gate-check.sh" \
    --bind-head abcd1234 --ci-sha none --story "$ART/E900-S50-compat.md"
  # Should be exit 2 (PENDING) because SHAs are absent.
  [ "$status" -eq 2 ]
}

@test "review-gate-check.sh: reads 4-col all-PASSED with matching SHA, exits COMPLETE" {
  _seed_4col E900-S51 PASSED abcd1234
  run "$SCRIPTS_DIR/review-gate-check.sh" \
    --bind-head abcd1234 --ci-sha none --story "$ART/E900-S51-compat.md"
  [ "$status" -eq 0 ]
}

@test "review-gate-check.sh: reads 4-col mixed, exits BLOCKED" {
  _seed_4col_mixed E900-S52
  run "$SCRIPTS_DIR/review-gate-check.sh" \
    --bind-head abc1234 --ci-sha none --story "$ART/E900-S52-compat.md"
  [ "$status" -eq 1 ]
}

@test "review-gate-check.sh: reads writer-produced story without crash" {
  _seed_writer E900-S53
  run "$SCRIPTS_DIR/review-gate-check.sh" \
    --bind-head abcd1234 --ci-sha none --story "$ART/E900-S53-compat.md"
  # Writer seeds UNVERIFIED with (possibly) SHA -> PENDING.
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 7. review-summary-gen.sh
# ---------------------------------------------------------------------------

@test "review-summary-gen.sh: generates summary from 3-col story" {
  _seed_3col E900-S60 PASSED
  run "$SCRIPTS_DIR/review-summary-gen.sh" --story E900-S60
  [ "$status" -eq 0 ]
  # Verify a summary file was created (exact path varies by config).
  local found
  found="$(find "$PROJECT_PATH" -name 'E900-S60*review-summary*' 2>/dev/null | head -1)"
  [ -n "$found" ]
}

@test "review-summary-gen.sh: generates summary from 4-col story" {
  _seed_4col E900-S61 PASSED abc1234
  run "$SCRIPTS_DIR/review-summary-gen.sh" --story E900-S61
  [ "$status" -eq 0 ]
  local found
  found="$(find "$PROJECT_PATH" -name 'E900-S61*review-summary*' 2>/dev/null | head -1)"
  [ -n "$found" ]
}

@test "review-summary-gen.sh: generates summary from writer-produced story" {
  _seed_writer E900-S62
  run "$SCRIPTS_DIR/review-summary-gen.sh" --story E900-S62
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. review-skip-check.sh
# ---------------------------------------------------------------------------

@test "review-skip-check.sh: partitions 3-col all-PASSED as all skip" {
  _seed_3col E900-S70 PASSED
  run "$SCRIPTS_DIR/review-skip-check.sh" --story E900-S70
  [ "$status" -eq 0 ]
  # JSON output: all 6 in skip, 0 in run.
  local skip_count
  skip_count="$(printf '%s\n' "$output" | jq '.skip | length')"
  [ "$skip_count" -eq 6 ]
}

@test "review-skip-check.sh: partitions 4-col all-PASSED as all skip" {
  _seed_4col E900-S71 PASSED abc1234
  run "$SCRIPTS_DIR/review-skip-check.sh" --story E900-S71
  [ "$status" -eq 0 ]
  local skip_count
  skip_count="$(printf '%s\n' "$output" | jq '.skip | length')"
  [ "$skip_count" -eq 6 ]
}

@test "review-skip-check.sh: partitions 4-col mixed correctly" {
  _seed_4col_mixed E900-S72
  run "$SCRIPTS_DIR/review-skip-check.sh" --story E900-S72
  [ "$status" -eq 0 ]
  # Mixed: 3 PASSED (Code Review, Security Review, Test Review) -> skip.
  # 1 FAILED (QA Tests) + 2 UNVERIFIED -> run.
  local skip_count run_count
  skip_count="$(printf '%s\n' "$output" | jq '.skip | length')"
  run_count="$(printf '%s\n' "$output" | jq '.run | length')"
  [ "$skip_count" -eq 3 ]
  [ "$run_count" -eq 3 ]
}

@test "review-skip-check.sh: reads writer-produced story without crash" {
  _seed_writer E900-S73
  run "$SCRIPTS_DIR/review-skip-check.sh" --story E900-S73
  [ "$status" -eq 0 ]
  # All UNVERIFIED -> all in run.
  local run_count
  run_count="$(printf '%s\n' "$output" | jq '.run | length')"
  [ "$run_count" -eq 6 ]
}

# ---------------------------------------------------------------------------
# 9. review-nudge.sh
# ---------------------------------------------------------------------------

@test "review-nudge.sh: renders nudge from 3-col story" {
  _seed_3col E900-S80 PASSED
  run "$SCRIPTS_DIR/review-nudge.sh" --story E900-S80
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate Nudge"* ]]
  [[ "$output" == *"ALL PASSED"* ]]
}

@test "review-nudge.sh: renders nudge from 4-col story" {
  _seed_4col E900-S81 PASSED abc1234
  run "$SCRIPTS_DIR/review-nudge.sh" --story E900-S81
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate Nudge"* ]]
  [[ "$output" == *"ALL PASSED"* ]]
}

@test "review-nudge.sh: renders nudge from 4-col mixed" {
  _seed_4col_mixed E900-S82
  run "$SCRIPTS_DIR/review-nudge.sh" --story E900-S82
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate Nudge"* ]]
  [[ "$output" == *"FAILED"* ]]
}

@test "review-nudge.sh: renders nudge from writer-produced story" {
  _seed_writer E900-S83
  run "$SCRIPTS_DIR/review-nudge.sh" --story E900-S83
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review Gate Nudge"* ]]
}

# ---------------------------------------------------------------------------
# 10. init-review-gate.sh
# ---------------------------------------------------------------------------

@test "init-review-gate.sh: seeds fresh story with 4-col table" {
  local key="E900-S90"
  cat > "$ART/${key}-compat.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Compat test ${key}"
status: "in-progress"
priority: "medium"
size: "M"
risk: "medium"
sprint_id: null
priority_flag: null
origin: null
origin_ref: null
epic_id: "E900"
points: 3
dependencies: []
---

# Story: Compat test ${key}
EOF
  local init_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/init-review-gate.sh"
  run "$init_script" "$ART/${key}-compat.md"
  [ "$status" -eq 0 ]
  # Verify the table was seeded.
  grep -q '## Review Gate' "$ART/${key}-compat.md"
  grep -q 'Code Review' "$ART/${key}-compat.md"
  grep -q 'Performance Review' "$ART/${key}-compat.md"
}

@test "init-review-gate.sh: is idempotent on 3-col story" {
  _seed_3col E900-S91 PASSED
  local init_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/init-review-gate.sh"
  run "$init_script" "$ART/E900-S91-compat.md"
  [ "$status" -eq 0 ]
  # Existing PASSED verdicts must not be overwritten.
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S91
  [ "$status" -eq 0 ]
}

@test "init-review-gate.sh: is idempotent on 4-col story" {
  _seed_4col E900-S92 PASSED abc1234
  local init_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/init-review-gate.sh"
  run "$init_script" "$ART/E900-S92-compat.md"
  [ "$status" -eq 0 ]
  # Existing PASSED verdicts must not be overwritten.
  run "$SCRIPTS_DIR/review-gate.sh" check --story E900-S92
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 11. validate-frontmatter.sh — reads story files but does NOT parse the
#     Review Gate table. It validates YAML frontmatter only. Including it
#     here verifies it does not crash when a 4-col table is present.
# ---------------------------------------------------------------------------

@test "validate-frontmatter.sh: does not crash on 3-col story" {
  _seed_3col E900-S100 PASSED
  local vf_script="$SCRIPTS_DIR/../skills/gaia-create-story/scripts/validate-frontmatter.sh"
  run "$vf_script" --file "$ART/E900-S100-compat.md"
  # Exit 0 (clean) or 1 (findings) — not 2 (crash).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "validate-frontmatter.sh: does not crash on 4-col story" {
  _seed_4col E900-S101 PASSED abc1234
  local vf_script="$SCRIPTS_DIR/../skills/gaia-create-story/scripts/validate-frontmatter.sh"
  run "$vf_script" --file "$ART/E900-S101-compat.md"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "validate-frontmatter.sh: does not crash on writer-produced story" {
  _seed_writer E900-S102
  local vf_script="$SCRIPTS_DIR/../skills/gaia-create-story/scripts/validate-frontmatter.sh"
  run "$vf_script" --file "$ART/E900-S102-compat.md"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 12. verdict-normalizer.sh — pure mapping, table-shape-agnostic. Verify it
#     handles the canonical vocabulary without crash.
# ---------------------------------------------------------------------------

@test "verdict-normalizer.sh: normalizes PASSED" {
  run "$SCRIPTS_DIR/lib/verdict-normalizer.sh" PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

@test "verdict-normalizer.sh: normalizes APPROVE to PASSED" {
  run "$SCRIPTS_DIR/lib/verdict-normalizer.sh" APPROVE
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

@test "verdict-normalizer.sh: normalizes REQUEST_CHANGES to FAILED" {
  run "$SCRIPTS_DIR/lib/verdict-normalizer.sh" REQUEST_CHANGES
  [ "$status" -eq 0 ]
  [ "$output" = "FAILED" ]
}

# ---------------------------------------------------------------------------
# 13. detect-mode.sh — reads Review Gate via inline awk (| FAILED |).
#     Must work with both 3-col and 4-col shapes.
# ---------------------------------------------------------------------------

@test "detect-mode.sh: RESUME on 3-col all-UNVERIFIED in-progress story" {
  _seed_3col E900-S110 UNVERIFIED
  local dm_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/detect-mode.sh"
  # detect-mode.sh takes a single positional arg: <story_path>.
  # It reads status from the YAML frontmatter.
  run "$dm_script" "$ART/E900-S110-compat.md"
  [ "$status" -eq 0 ]
  [ "$output" = "RESUME" ]
}

@test "detect-mode.sh: REWORK on 4-col mixed in-progress story" {
  _seed_4col_mixed E900-S111
  local dm_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/detect-mode.sh"
  run "$dm_script" "$ART/E900-S111-compat.md"
  [ "$status" -eq 0 ]
  [ "$output" = "REWORK" ]
}

@test "detect-mode.sh: FRESH on backlog status regardless of table shape" {
  _seed_4col E900-S112 PASSED abc1234
  # Override status in frontmatter to backlog.
  sed -i.bak 's/status: "in-progress"/status: "backlog"/' "$ART/E900-S112-compat.md"
  local dm_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/detect-mode.sh"
  run "$dm_script" "$ART/E900-S112-compat.md"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

# ---------------------------------------------------------------------------
# 14. gating-flip-guard.sh --scan — inline awk parser must handle 4-col.
#     The awk uses awk -F'|' which naturally handles extra columns.
# ---------------------------------------------------------------------------

@test "gating-flip-guard.sh --scan: no offenders on 3-col all-PASSED" {
  _seed_3col E900-S120 PASSED
  # Set status to "review" in frontmatter.
  sed -i.bak 's/status: "in-progress"/status: "review"/' "$ART/E900-S120-compat.md"
  run "$SCRIPTS_DIR/review-common/gating-flip-guard.sh" --scan --impl-dir "$ART"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no stories require resolution"* ]]
}

@test "gating-flip-guard.sh --scan: no offenders on 4-col all-PASSED" {
  _seed_4col E900-S121 PASSED abc1234
  sed -i.bak 's/status: "in-progress"/status: "review"/' "$ART/E900-S121-compat.md"
  run "$SCRIPTS_DIR/review-common/gating-flip-guard.sh" --scan --impl-dir "$ART"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no stories require resolution"* ]]
}

@test "gating-flip-guard.sh --scan: finds offenders on 4-col mixed" {
  _seed_4col_mixed E900-S122
  sed -i.bak 's/status: "in-progress"/status: "review"/' "$ART/E900-S122-compat.md"
  run "$SCRIPTS_DIR/review-common/gating-flip-guard.sh" --scan --impl-dir "$ART"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E900-S122"* ]]
  [[ "$output" == *"FAILED"* ]]
}

@test "gating-flip-guard.sh --scan: reads writer-produced story" {
  _seed_writer E900-S123
  sed -i.bak 's/status: "in-progress"/status: "review"/' "$ART/E900-S123-compat.md"
  run "$SCRIPTS_DIR/review-common/gating-flip-guard.sh" --scan --impl-dir "$ART"
  [ "$status" -eq 0 ]
  # Writer seeds UNVERIFIED — should be listed as offender.
  [[ "$output" == *"E900-S123"* ]]
}

# ---------------------------------------------------------------------------
# 15. sprint-state.sh check_review_gate_all_passed — inline awk that splits
#     on pipe. Must handle both 3-col and 4-col rows.
#     This function is called during transition-story-status.sh on -> done.
#     We test it by calling sprint-state.sh with a story whose Review Gate
#     is already PASSED/not-PASSED and verifying the transition guard.
# ---------------------------------------------------------------------------
# NOTE: sprint-state.sh requires a full sprint-status.yaml fixture and the
# story to be registered. Testing the inline awk parser in isolation is
# simpler — we source the parser from sprint-state.sh's own awk block.

@test "sprint-state.sh inline awk parser: 3-col all-PASSED produces no output" {
  _seed_3col E900-S130 PASSED
  local result
  result="$(awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }
    { sub(/\r$/, "", $0) }
    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0; next }
      next
    }
    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 2) next
      gate = cells[1]; status = cells[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (status != "PASSED") {
        printf "%s=%s\n", gate, status
      }
    }
  ' "$ART/E900-S130-compat.md")"
  [ -z "$result" ]
}

@test "sprint-state.sh inline awk parser: 4-col all-PASSED produces no output" {
  _seed_4col E900-S131 PASSED abc1234
  local result
  result="$(awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }
    { sub(/\r$/, "", $0) }
    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0; next }
      next
    }
    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 2) next
      gate = cells[1]; status = cells[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (status != "PASSED") {
        printf "%s=%s\n", gate, status
      }
    }
  ' "$ART/E900-S131-compat.md")"
  [ -z "$result" ]
}

@test "sprint-state.sh inline awk parser: 4-col mixed lists non-PASSED gates" {
  _seed_4col_mixed E900-S132
  local result
  result="$(awk '
    BEGIN { in_section = 0; in_table = 0; saw_sep = 0 }
    /^## Review Gate[[:space:]]*$/ { in_section = 1; in_table = 0; saw_sep = 0; next }
    in_section && /^## / { in_section = 0; in_table = 0; next }
    !in_section { next }
    { sub(/\r$/, "", $0) }
    in_section && !in_table {
      if ($0 ~ /^[[:space:]]*\|/) { in_table = 1; saw_sep = 0; next }
      next
    }
    in_table {
      if ($0 !~ /^[[:space:]]*\|/) { in_table = 0; in_section = 0; next }
      if (!saw_sep && $0 ~ /^[[:space:]]*\|[[:space:]]*-+/) { saw_sep = 1; next }
      line = $0
      sub(/^[[:space:]]*\|/, "", line)
      sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, /\|/)
      if (n < 2) next
      gate = cells[1]; status = cells[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (status != "PASSED") {
        printf "%s=%s\n", gate, status
      }
    }
  ' "$ART/E900-S132-compat.md")"
  [ -n "$result" ]
  [[ "$result" == *"QA Tests=FAILED"* ]]
  [[ "$result" == *"Test Automation=UNVERIFIED"* ]]
  [[ "$result" == *"Performance Review=UNVERIFIED"* ]]
}

# ---------------------------------------------------------------------------
# 16. transition-story-status.sh inline pipe parser — the awk that reads
#     the Review Gate table via | delimited fields to find PASSED reviews.
#     Verify the parser handles both column counts.
# ---------------------------------------------------------------------------

@test "transition inline parser: extracts PASSED gates from 3-col" {
  _seed_3col E900-S140 PASSED
  local result
  result="$(awk '/^## Review Gate[[:space:]]*$/ { found=1; next } found && /^## / { exit } found' \
    "$ART/E900-S140-compat.md" | grep '^|' | tail -n +3)"
  [ -n "$result" ]
  # Should have 6 data rows.
  local row_count
  row_count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
  [ "$row_count" -eq 6 ]
}

@test "transition inline parser: extracts PASSED gates from 4-col" {
  _seed_4col E900-S141 PASSED abc1234
  local result
  result="$(awk '/^## Review Gate[[:space:]]*$/ { found=1; next } found && /^## / { exit } found' \
    "$ART/E900-S141-compat.md" | grep '^|' | tail -n +3)"
  [ -n "$result" ]
  local row_count
  row_count="$(printf '%s\n' "$result" | wc -l | tr -d ' ')"
  [ "$row_count" -eq 6 ]
  # The awk -F'|' read of $2 (gate) and $3 (status) must work regardless
  # of whether $4 and $5 exist (SHA col).
  local gate status
  while IFS='|' read -r _ gate status _; do
    gate="$(printf '%s' "$gate" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    status="$(printf '%s' "$status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$gate" ] || continue
    [ "$status" = "PASSED" ]
  done <<< "$result"
}

# ---------------------------------------------------------------------------
# 17. sprint-progress-snapshot.sh inline awk — splits Review Gate rows on
#     pipe, reads cells[1] (gate) and cells[2] (status). Extra columns
#     are ignored because split(line, c, /\|/) returns n>=2 which is all
#     the parser needs.
# ---------------------------------------------------------------------------

@test "sprint-progress-snapshot awk: 3-col Review Gate rows parsed" {
  _seed_3col E900-S150 PASSED
  # Extract the awk-relevant rows.
  local gate_rows
  gate_rows="$(awk '
    /^## Review Gate/ { in_gate=1; gsep=0; next }
    in_gate && /^## / { in_gate=0 }
    in_gate && /^\|.*\|.*\|/ {
      if ($0 ~ /Review.*Status.*Report/) next
      if ($0 ~ /^[[:space:]]*\|[-]+/) { gsep=1; next }
      if (!gsep) next
      l = $0; gsub(/^[[:space:]]*\|[[:space:]]*/, "", l)
      cn = split(l, c, /[[:space:]]*\|[[:space:]]*/)
      if (cn >= 2) {
        gn = c[1]; gs = c[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gn)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gs)
        printf "%s\t%s\n", gn, gs
      }
    }
  ' "$ART/E900-S150-compat.md")"
  [ -n "$gate_rows" ]
  local line_count
  line_count="$(printf '%s\n' "$gate_rows" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 6 ]
}

@test "sprint-progress-snapshot awk: 4-col Review Gate rows parsed" {
  _seed_4col E900-S151 PASSED abc1234
  local gate_rows
  gate_rows="$(awk '
    /^## Review Gate/ { in_gate=1; gsep=0; next }
    in_gate && /^## / { in_gate=0 }
    in_gate && /^\|.*\|.*\|/ {
      if ($0 ~ /Review.*Status.*Report/) next
      if ($0 ~ /^[[:space:]]*\|[-]+/) { gsep=1; next }
      if (!gsep) next
      l = $0; gsub(/^[[:space:]]*\|[[:space:]]*/, "", l)
      cn = split(l, c, /[[:space:]]*\|[[:space:]]*/)
      if (cn >= 2) {
        gn = c[1]; gs = c[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gn)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", gs)
        printf "%s\t%s\n", gn, gs
      }
    }
  ' "$ART/E900-S151-compat.md")"
  [ -n "$gate_rows" ]
  local line_count
  line_count="$(printf '%s\n' "$gate_rows" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 6 ]
  # All statuses should be PASSED.
  while IFS=$'\t' read -r gn gs; do
    [ "$gs" = "PASSED" ]
  done <<< "$gate_rows"
}

# ---------------------------------------------------------------------------
# 18. verify-cluster-gates.sh extract_review_rows — inline awk that reads
#     the Review Gate section and greps for | <gate name> |. The awk -F'|'
#     parser reads $3 as the verdict. With a 4-col table, $3 is still the
#     status and $4 is the report (shifted by one); however the script
#     uses grep -F "| <gate> |" first, then awk -F'|' '{print $3}' for
#     the verdict. This is column-count-safe because the verdict is always
#     in column 3.
# ---------------------------------------------------------------------------

@test "verify-cluster-gates extract_review_rows awk: reads 3-col" {
  _seed_3col E900-S160 PASSED
  local rows
  rows="$(awk '
    /^## Review Gate/ { in_gate=1; next }
    in_gate && /^## / { in_gate=0 }
    in_gate { print }
  ' "$ART/E900-S160-compat.md" | grep -E '^\| [A-Za-z]' || true)"
  [ -n "$rows" ]
  # The pattern picks up the header row (| Review |) plus 6 data rows = 7.
  # The real script further filters by grep -F "| <gate name> |" per gate.
  # Verify the per-gate filter works.
  local cr_row
  cr_row="$(printf '%s\n' "$rows" | grep -F '| Code Review |' | head -1 || true)"
  [ -n "$cr_row" ]
  local verdict
  verdict="$(printf '%s' "$cr_row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')"
  [ "$verdict" = "PASSED" ]
}

@test "verify-cluster-gates extract_review_rows awk: reads 4-col" {
  _seed_4col E900-S161 PASSED abc1234
  local rows
  rows="$(awk '
    /^## Review Gate/ { in_gate=1; next }
    in_gate && /^## / { in_gate=0 }
    in_gate { print }
  ' "$ART/E900-S161-compat.md" | grep -E '^\| [A-Za-z]' || true)"
  [ -n "$rows" ]
  # Per-gate extraction: awk -F'|' reads $3 as Status regardless of col count.
  local verdict
  verdict="$(printf '%s\n' "$rows" | grep -F '| Code Review |' | head -1 | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')"
  [ "$verdict" = "PASSED" ]
  # Performance Review should also be extractable.
  local pr_verdict
  pr_verdict="$(printf '%s\n' "$rows" | grep -F '| Performance Review |' | head -1 | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')"
  [ "$pr_verdict" = "PASSED" ]
}

# ---------------------------------------------------------------------------
# 19. detect-mode.sh inline awk: /\| FAILED \|/ pattern. With a 4-col table
#     the pipe-delimited row has an extra | sha | at the end. The pattern
#     "| FAILED |" still matches because the Status cell is still flanked
#     by pipes.
# ---------------------------------------------------------------------------

@test "detect-mode.sh awk pattern matches FAILED in 3-col" {
  _seed_3col E900-S170 UNVERIFIED
  # Manually set one gate to FAILED.
  sed -i.bak 's/| QA Tests | UNVERIFIED/| QA Tests | FAILED/' "$ART/E900-S170-compat.md"
  local found
  found="$(awk '
    BEGIN { in_gate = 0 }
    $0 == "## Review Gate" { in_gate = 1; next }
    in_gate && /^## / { in_gate = 0 }
    in_gate && /\| FAILED \|/ { print "yes"; exit }
  ' "$ART/E900-S170-compat.md")"
  [ "$found" = "yes" ]
}

@test "detect-mode.sh awk pattern matches FAILED in 4-col" {
  _seed_4col E900-S171 UNVERIFIED abc1234
  sed -i.bak 's/| QA Tests | UNVERIFIED/| QA Tests | FAILED/' "$ART/E900-S171-compat.md"
  local found
  found="$(awk '
    BEGIN { in_gate = 0 }
    $0 == "## Review Gate" { in_gate = 1; next }
    in_gate && /^## / { in_gate = 0 }
    in_gate && /\| FAILED \|/ { print "yes"; exit }
  ' "$ART/E900-S171-compat.md")"
  [ "$found" = "yes" ]
}

# ---------------------------------------------------------------------------
# 20. composite-verdict-aggregator.sh — does NOT read the table directly.
#     It consumes pre-mapped verdict flags. Verify it still works (smoke).
# ---------------------------------------------------------------------------

@test "composite-verdict-aggregator.sh: all-APPROVE produces PASSED" {
  run "$SCRIPTS_DIR/review-common/composite-verdict-aggregator.sh" \
    --code APPROVE --qa APPROVE --test APPROVE \
    --security APPROVE --perf APPROVE \
    --skip-a11y "no UI" --skip-mobile "no mobile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=APPROVE"* ]]
  [[ "$output" == *"review_gate=PASSED"* ]]
}

@test "composite-verdict-aggregator.sh: one REQUEST_CHANGES produces FAILED" {
  run "$SCRIPTS_DIR/review-common/composite-verdict-aggregator.sh" \
    --code REQUEST_CHANGES --qa APPROVE --test APPROVE \
    --security APPROVE --perf APPROVE \
    --skip-a11y "no UI" --skip-mobile "no mobile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"composite=REQUEST_CHANGES"* ]]
  [[ "$output" == *"review_gate=FAILED"* ]]
}

# ---------------------------------------------------------------------------
# 21. conditional-trigger-eval.sh — does NOT read the Review Gate table.
#     Reads project-config.yaml for conditional gate inclusion. Smoke test.
# ---------------------------------------------------------------------------

@test "conditional-trigger-eval.sh: runs without crash on minimal config" {
  run "$SCRIPTS_DIR/review-common/conditional-trigger-eval.sh" \
    --shared "$TEST_TMP/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 22. tdd-review-gate.sh — reads story frontmatter risk, not the Review
#     Gate table. Verify it does not crash when a 4-col table is present.
# ---------------------------------------------------------------------------
# NOTE: tdd-review-gate.sh requires resolve-config.sh to be reachable and
# a properly configured project config. We test only that it does not crash
# with both table shapes.

@test "tdd-review-gate.sh: does not crash on 3-col story" {
  _seed_3col E900-S180 UNVERIFIED
  local tdd_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/tdd-review-gate.sh"
  # The script requires a phase argument and reads from the story file.
  run "$tdd_script" E900-S180 red
  # Exit 0 (SKIP/PROMPT/QA_AUTO) or 2 (usage) — not a crash.
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

@test "tdd-review-gate.sh: does not crash on 4-col story" {
  _seed_4col E900-S181 UNVERIFIED abc1234
  local tdd_script="$SCRIPTS_DIR/../skills/gaia-dev-story/scripts/tdd-review-gate.sh"
  run "$tdd_script" E900-S181 red
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 23. review-runner.sh — delegates to review-gate.sh for table writes.
#     Smoke test: --help must not crash.
# ---------------------------------------------------------------------------

@test "review-runner.sh: --help exits 0" {
  run "$SCRIPTS_DIR/review-runner.sh" --help
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 24. load-story.sh (gaia-check-review-gate) — delegates to sprint-state.sh
#     get. Does not parse the Review Gate table directly. Smoke test only.
#     NOTE: Requires a sprint-status.yaml with the story registered. We skip
#     the full integration and just verify the script does not crash on --help
#     or missing-story.
# ---------------------------------------------------------------------------
# load-story.sh does not have a --help flag. It requires <story_key>.
# With no sprint-status.yaml it will fail, which is expected — we just
# verify it exits cleanly (non-crash) on a missing story.

@test "load-story.sh: exits non-zero on missing story (not a crash)" {
  local ls_script="$SCRIPTS_DIR/../skills/gaia-check-review-gate/scripts/load-story.sh"
  run "$ls_script" E900-S999
  # Non-zero exit is expected (story not in sprint), but it should be 1, not segfault.
  [ "$status" -ne 0 ]
  [ "$status" -lt 128 ]
}

# ---------------------------------------------------------------------------
# 25. sprint-progress-audit.sh — calls review-gate.sh review-gate-check.
#     Does not parse the table itself. Verify --help works.
# ---------------------------------------------------------------------------

@test "sprint-progress-audit.sh: --help exits 0" {
  run "$SCRIPTS_DIR/sprint-progress-audit.sh" --help
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 26. validate-gate.sh — checks file existence, not Review Gate table.
#     Smoke test.
# ---------------------------------------------------------------------------

@test "validate-gate.sh: --help exits 0" {
  run "$SCRIPTS_DIR/validate-gate.sh" --help
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 27. End-to-end round-trip: writer (init + update) -> reader (all shapes)
# ---------------------------------------------------------------------------

@test "round-trip: init + update + status + check + review-gate-check all agree" {
  local key="E900-S200"
  _seed_writer "$key"
  # Verify initial state: all UNVERIFIED.
  run "$SCRIPTS_DIR/review-gate.sh" status --story "$key"
  [ "$status" -eq 0 ]
  local cr
  cr="$(printf '%s\n' "$output" | jq -r '.gates["Code Review"]')"
  [ "$cr" = "UNVERIFIED" ]

  # check should fail (not all PASSED).
  run "$SCRIPTS_DIR/review-gate.sh" check --story "$key"
  [ "$status" -eq 1 ]

  # review-gate-check should be PENDING.
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story "$key"
  [ "$status" -eq 2 ]
  [[ "$output" == *"PENDING"* ]]

  # Update all gates to PASSED.
  local gates=("Code Review" "QA Tests" "Security Review" "Test Automation" "Test Review" "Performance Review")
  local g
  for g in "${gates[@]}"; do
    "$SCRIPTS_DIR/review-gate.sh" update --story "$key" --gate "$g" --verdict PASSED
  done

  # Now check should pass.
  run "$SCRIPTS_DIR/review-gate.sh" check --story "$key"
  [ "$status" -eq 0 ]

  # review-gate-check should be COMPLETE.
  run "$SCRIPTS_DIR/review-gate.sh" review-gate-check --story "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETE"* ]]

  # skip-check should put all 6 in skip.
  run "$SCRIPTS_DIR/review-skip-check.sh" --story "$key"
  [ "$status" -eq 0 ]
  local skip_count
  skip_count="$(printf '%s\n' "$output" | jq '.skip | length')"
  [ "$skip_count" -eq 6 ]
}
