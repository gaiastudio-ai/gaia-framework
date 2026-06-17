#!/usr/bin/env bats
# e38-s2-escalation-halt.bats
#
# Integration tests for E38-S2 Action-item escalation halt.
# Exercises the escalation-halt.sh predicate + the sprint-state.sh
# record-escalation-override subcommand as a system. Covers the four
# acceptance criteria and the 8 Test Scenarios in the story file.
#
# Test Scenarios (from E38-S2 story):
#   1. Happy path — no blocking items (AC1)
#   2. Halt fires (AC2, TC-SPQG-5)
#   3. Override proceeds and records (AC3, TC-SPQG-6)
#   4. Override idempotency (AC3)
#   5. Missing-file fallback (AC4)
#   6. Empty-file fallback (AC4)
#   7. Non-matching items (AC1)
#   8. Mixed matching + non-matching items

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

ESCALATION_HALT_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/escalation-halt.sh"
SPRINT_STATE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_sprint_status_yaml() {
  local file="$1"
  cat > "$file" <<'EOF'
sprint_id: "sprint-99"
duration: "2 weeks"
velocity_capacity: 21
total_points: 10
started: "2026-04-22"
end_date: "2026-05-06"
stories:
  - key: "E1-S1"
    title: "Example"
    status: "ready-for-dev"
    points: 3
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-04-22"
EOF
}

_write_action_items() {
  # $1 = target file
  # $2+ = entries: "id|title|priority|status|esc_count"
  local file="$1"; shift
  {
    printf 'action_items:\n'
    local e
    for e in "$@"; do
      IFS='|' read -r id title priority status esc <<<"$e"
      printf '  - id: "%s"\n' "$id"
      printf '    title: "%s"\n' "$title"
      printf '    classification: process\n'
      printf '    priority: %s\n' "$priority"
      printf '    status: %s\n' "$status"
      printf '    escalation_count: %s\n' "$esc"
    done
  } > "$file"
}

# Exercise the SKILL Step 1.5 contract as a shell pipeline.
# Returns $status=0 (proceed) or non-zero (halt) with halt message on stdout.
_run_escalation_halt() {
  local ai="$1" ss="$2"
  bash -c "source '$ESCALATION_HALT_SH' && esch_check_blocking '$ai' '$ss'"
}

# ===========================================================================
# Scenario 1 — Happy path: no blocking items (AC1)
# ===========================================================================
@test "integration: happy path — no blocking items (AC1)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai"
  _make_sprint_status_yaml "$ss"
  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
  # No halt message should be emitted
  ! echo "$output" | grep -q "BLOCKING"
}

# ===========================================================================
# Scenario 2 — Halt fires (AC2, TC-SPQG-5)
# ===========================================================================
@test "integration: halt fires with blocking list" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-42|Long-running|HIGH|open|2"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "AI-42"
  echo "$output" | grep -q "Long-running"
  echo "$output" | grep -q "HIGH"
  echo "$output" | grep -q "/gaia-action-items"
  echo "$output" | grep -q "override-escalation-halt"

  # No sprint-status.yaml mutation from the halt itself (only record-override writes)
  local before after
  before="$(_make_sprint_status_yaml "$ss"; shasum -a 256 "$ss" | cut -d' ' -f1)"
  _run_escalation_halt "$ai" "$ss" || true
  after="$(shasum -a 256 "$ss" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}

# ===========================================================================
# Scenario 3 — Override proceeds + records (AC3, TC-SPQG-6)
# ===========================================================================
@test "integration: override flag proceeds and records override" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-42|Long-running|HIGH|open|2"
  _make_sprint_status_yaml "$ss"

  # Simulate the override path: record the override via sprint-state.sh,
  # then re-run the halt check — it must now proceed.
  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "Acknowledged in planning"
  [ $? -eq 0 ]

  # overrides block should include the exact payload fields (AC3)
  grep -q "overrides:" "$ss"
  grep -q "AI-42" "$ss"
  grep -q "alice" "$ss"
  grep -q "escalation_halt" "$ss"
  grep -q "Acknowledged in planning" "$ss"
  grep -qE "date:[[:space:]]*\"?[0-9]{4}-[0-9]{2}-[0-9]{2}" "$ss"

  # Re-running the halt check after the override must now proceed (exit 0)
  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Scenario 4 — Override idempotency (AC3)
# ===========================================================================
@test "integration: override idempotency — same items do not re-halt, no duplicate entry (AC3)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-42|Long-running|HIGH|open|2"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "first"
  local lines1
  lines1="$(wc -l < "$ss")"

  # Re-run with the same still-open items + prior override recorded
  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "second"
  local lines2
  lines2="$(wc -l < "$ss")"

  [ "$lines1" = "$lines2" ]

  # Halt check still proceeds on re-run (no duplicate halt)
  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Scenario 5 — Missing file fallback (AC4)
# ===========================================================================
@test "integration: missing action-items.yaml proceeds with one-line warning (AC4)" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$TEST_TMP/no-such-file.yaml" "$ss"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "action-items.yaml not found"

  # File must NOT be created by escalation-halt (AC4: creation is E36-S2's job)
  [ ! -e "$TEST_TMP/no-such-file.yaml" ]
}

# ===========================================================================
# Scenario 6 — Empty file fallback (AC4)
# ===========================================================================
@test "integration: empty action-items.yaml proceeds silently (AC4)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  : > "$ai"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

@test "integration: action-items.yaml with empty list proceeds silently (AC4)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  printf 'action_items: []\n' > "$ai"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Scenario 7 — Non-matching items (AC1)
# ===========================================================================
@test "integration: MEDIUM priority items don't halt (AC1)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-1|x|MEDIUM|open|5"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

@test "integration: resolved items don't halt (AC1)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-1|x|HIGH|resolved|5"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

@test "integration: escalation_count=1 items don't halt (AC1)" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" "AI-1|x|HIGH|open|1"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Scenario 8 — Mixed matching + non-matching
# ===========================================================================
@test "integration: mixed items — blocking list contains only the matching one" {
  local ai="$TEST_TMP/action-items.yaml"
  local ss="$TEST_TMP/sprint-status.yaml"
  _write_action_items "$ai" \
    "AI-42|Matcher|HIGH|open|2" \
    "AI-01|Not me|MEDIUM|open|9" \
    "AI-02|Me neither|HIGH|resolved|9"
  _make_sprint_status_yaml "$ss"

  run _run_escalation_halt "$ai" "$ss"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "AI-42"
  ! echo "$output" | grep -q "AI-01"
  ! echo "$output" | grep -q "AI-02"
}
