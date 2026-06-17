#!/usr/bin/env bats
# gating-flip-guard.bats — E66-S3 ADR-082 sprint-boundary deployment guard
#
# Tests for gating-flip-guard.sh, which (a) refuses to deploy the GATING flip
# mid-sprint, and (b) provides a one-time pre-flip review-status scan that
# enumerates `status: review` stories with non-PASSED Review Gate rows.
#
# Refs: ADR-082, NFR-RSV2-6.
# Story: E66-S3 — covers AC4, AC5.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/review-common/gating-flip-guard.sh"
}
teardown() { common_teardown; }

# Helper — write a minimal sprint-status.yaml with the supplied story rows.
write_sprint_status() {
  local path="$1"; shift
  cat > "$path" <<'EOF'
sprint_id: "sprint-test"
duration: "2 days"
velocity_capacity: 10
team_size: 1
total_points: 10
capacity_utilization: "100%"
started: "2026-05-05"
end_date: "2026-05-07"
EOF
  echo "stories:" >> "$path"
  for row in "$@"; do
    cat >> "$path" <<EOF
  - key: "$(echo "$row" | cut -d: -f1)"
    title: "test story"
    status: "$(echo "$row" | cut -d: -f2)"
    points: 1
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-05-05"
EOF
  done
}

# Helper — write a minimal story file with frontmatter status + a Review Gate table.
write_story_file() {
  local path="$1" story_status="$2" code="$3" qa="$4" sec="$5" ta="$6" tr="$7" pr="$8"
  cat > "$path" <<EOF
---
key: "$(basename "$path" .md | cut -d- -f1-2)"
status: $story_status
---

# Story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | $code | — |
| QA Tests | $qa | — |
| Security Review | $sec | — |
| Test Automation | $ta | — |
| Test Review | $tr | — |
| Performance Review | $pr | — |
EOF
}

# ---------- AC4: sprint-boundary deployment guard ----------

@test "mid-sprint flip rejected (any in-progress story)" {
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "E1-S1:in-progress" "E1-S2:done"
  run --separate-stderr "$SCRIPT" --check-boundary --sprint-status "$yaml"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"sprint-boundary"* ]] || [[ "$stderr" == *"in-progress"* ]]
}

@test "sprint-boundary deploy allowed when no story is in-progress" {
  local yaml="$TEST_TMP/sprint-status.yaml"
  write_sprint_status "$yaml" "E1-S1:done" "E1-S2:done"
  run --separate-stderr "$SCRIPT" --check-boundary --sprint-status "$yaml"
  [ "$status" -eq 0 ]
}

@test "missing sprint-status.yaml -> exit 1 with clear message" {
  run --separate-stderr "$SCRIPT" --check-boundary --sprint-status "$TEST_TMP/nonexistent.yaml"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not found"* ]] || [[ "$stderr" == *"missing"* ]]
}

# ---------- AC5: one-time pre-flip review-status scan ----------

@test "scan enumerates status:review stories with non-PASSED rows" {
  local impl="$TEST_TMP/impl"
  mkdir -p "$impl"
  # Story A in review, all PASSED (should NOT appear in the scan)
  write_story_file "$impl/E2-S1-clean.md" review PASSED PASSED PASSED PASSED PASSED PASSED
  # Story B in review, one FAILED (should appear)
  write_story_file "$impl/E2-S2-fail.md" review PASSED FAILED PASSED PASSED PASSED PASSED
  # Story C in review, one UNVERIFIED (should appear)
  write_story_file "$impl/E2-S3-unv.md" review PASSED PASSED UNVERIFIED PASSED PASSED PASSED
  # Story D in done (should NOT appear regardless of rows)
  write_story_file "$impl/E2-S4-done.md" done FAILED FAILED FAILED FAILED FAILED FAILED

  run --separate-stderr "$SCRIPT" --scan --impl-dir "$impl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E2-S2"* ]]
  [[ "$output" == *"E2-S3"* ]]
  [[ "$output" != *"E2-S1"* ]]
  [[ "$output" != *"E2-S4"* ]]
}

@test "scan with no problem stories prints empty enumeration" {
  local impl="$TEST_TMP/impl"
  mkdir -p "$impl"
  write_story_file "$impl/E3-S1-clean.md" review PASSED PASSED PASSED PASSED PASSED PASSED
  run --separate-stderr "$SCRIPT" --scan --impl-dir "$impl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no stories require resolution"* ]] || [[ "$output" == *"0 stories"* ]]
}

@test "scan output includes which gate failed for each story" {
  local impl="$TEST_TMP/impl"
  mkdir -p "$impl"
  write_story_file "$impl/E4-S1-mix.md" review PASSED FAILED PASSED PASSED PASSED PASSED
  run --separate-stderr "$SCRIPT" --scan --impl-dir "$impl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QA Tests"* ]]
  [[ "$output" == *"FAILED"* ]]
}

# ---------- usage ----------

@test "usage: --help exits 0 with usage" {
  run --separate-stderr "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"gating-flip-guard"* ]]
}

@test "usage: missing subcommand -> exit 1" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
}
