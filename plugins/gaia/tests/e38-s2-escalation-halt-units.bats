#!/usr/bin/env bats
# e38-s2-escalation-halt-units.bats
#
# Unit tests for escalation-halt.sh public functions added by E38-S2
# (Action-item escalation halt). Satisfies NFR-052 public-function
# coverage gate by directly exercising each new public function.
#
# Functions under test (escalation-halt.sh):
#   - esch_scan                      — read action-items.yaml, emit records
#   - esch_filter_blocking           — filter to HIGH + esc>=2 + open
#   - esch_format_halt_message       — format blocking list + exit guidance
#   - esch_check_override_recorded   — detect prior override for idempotency
#   - esch_check_blocking            — top-level predicate (proceed/halt)
#
# Functions under test (sprint-state.sh record-escalation-override):
#   - do_record_override_locked      — inner logic sans flock wrapper
#   - cmd_record_escalation_override — atomic append to overrides: block
#
# Pattern: source the script as a library (extract function definitions
# via awk) then call each function directly — same approach as
# e38-s4-priority-flag-units.bats and e38-s3-lint-dependencies-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

ESCALATION_HALT_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/escalation-halt.sh"
SPRINT_STATE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/sprint-state.sh"

# ---------------------------------------------------------------------------
# Helper: source escalation-halt.sh directly as a library. The script is
# library-only (no main entrypoint), so direct `source` is safe.
# ---------------------------------------------------------------------------
_load_esch_helpers() {
  # shellcheck disable=SC1090
  source "$ESCALATION_HALT_SH"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
_make_action_items_yaml() {
  # $1 = target file path
  # $2+ = each entry as "id|title|priority|status|esc_count"
  local file="$1"; shift
  {
    printf 'action_items:\n'
    local entry
    for entry in "$@"; do
      IFS='|' read -r id title priority status esc_count <<<"$entry"
      printf '  - id: "%s"\n' "$id"
      printf '    title: "%s"\n' "$title"
      printf '    classification: process\n'
      printf '    priority: %s\n' "$priority"
      printf '    status: %s\n' "$status"
      printf '    escalation_count: %s\n' "$esc_count"
    done
  } > "$file"
}

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
    title: "Example story"
    status: "ready-for-dev"
    points: 3
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-04-22"
EOF
}

# ===========================================================================
# esch_scan — read action-items.yaml and emit pipe-delimited records
# ===========================================================================

@test "esch_scan: emits one record per action item" {
  _load_esch_helpers
  local yaml="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$yaml" \
    "AI-1|First item|HIGH|open|2" \
    "AI-2|Second item|MEDIUM|open|1"
  local got
  got="$(esch_scan "$yaml")"
  local count
  count="$(printf '%s\n' "$got" | grep -c .)"
  [ "$count" -eq 2 ]
  grep -q "AI-1" <<<"$got"
  grep -q "AI-2" <<<"$got"
}

@test "esch_scan: returns empty on missing file (AC4)" {
  _load_esch_helpers
  local got
  got="$(esch_scan "$TEST_TMP/nonexistent.yaml" 2>/dev/null)"
  [ -z "$got" ]
}

@test "esch_scan: emits one-line stderr warning on missing file (AC4)" {
  _load_esch_helpers
  local err
  err="$(esch_scan "$TEST_TMP/nonexistent.yaml" 2>&1 >/dev/null)"
  grep -q "action-items.yaml not found" <<<"$err"
}

@test "esch_scan: returns empty on empty file (AC4)" {
  _load_esch_helpers
  local yaml="$TEST_TMP/action-items.yaml"
  : > "$yaml"
  local got
  got="$(esch_scan "$yaml" 2>/dev/null)"
  [ -z "$got" ]
}

@test "esch_scan: returns empty when action_items: is empty list" {
  _load_esch_helpers
  local yaml="$TEST_TMP/action-items.yaml"
  printf 'action_items: []\n' > "$yaml"
  local got
  got="$(esch_scan "$yaml" 2>/dev/null)"
  [ -z "$got" ]
}

@test "esch_scan: record shape is id|title|priority|status|escalation_count" {
  _load_esch_helpers
  local yaml="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$yaml" "AI-42|My title|HIGH|open|3"
  local got
  got="$(esch_scan "$yaml")"
  # Expected: AI-42|My title|HIGH|open|3
  grep -q "^AI-42|My title|HIGH|open|3$" <<<"$got"
}

# ===========================================================================
# esch_filter_blocking — HIGH + escalation_count >= 2 + open
# ===========================================================================

@test "esch_filter_blocking: keeps HIGH/esc>=2/open (AC2)" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' \
    "AI-1|First|HIGH|open|2" \
    "AI-2|Second|MEDIUM|open|2" \
    "AI-3|Third|HIGH|resolved|3" \
    "AI-4|Fourth|HIGH|open|1" \
    "AI-5|Fifth|HIGH|open|3")
  local got
  got="$(printf '%s\n' "$records" | esch_filter_blocking)"
  grep -q "AI-1" <<<"$got"
  grep -q "AI-5" <<<"$got"
  ! grep -q "AI-2" <<<"$got"
  ! grep -q "AI-3" <<<"$got"
  ! grep -q "AI-4" <<<"$got"
}

@test "esch_filter_blocking: empty input produces empty output" {
  _load_esch_helpers
  local got
  got="$(printf '' | esch_filter_blocking)"
  [ -z "$got" ]
}

@test "esch_filter_blocking: zero matches = empty output (AC1)" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' \
    "AI-1|First|MEDIUM|open|5" \
    "AI-2|Second|HIGH|resolved|5" \
    "AI-3|Third|HIGH|open|1")
  local got
  got="$(printf '%s\n' "$records" | esch_filter_blocking)"
  [ -z "$got" ]
}

@test "esch_filter_blocking: case-sensitive on HIGH and open" {
  _load_esch_helpers
  # 'high' lowercase should NOT match
  local got
  got="$(printf '%s\n' "AI-1|First|high|open|2" | esch_filter_blocking)"
  [ -z "$got" ]
  # 'OPEN' uppercase should NOT match
  got="$(printf '%s\n' "AI-1|First|HIGH|OPEN|2" | esch_filter_blocking)"
  [ -z "$got" ]
}

# ===========================================================================
# esch_format_halt_message — formatted blocking list + exit guidance
# ===========================================================================

@test "esch_format_halt_message: lists each blocking item with id/title/count" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' \
    "AI-42|Long-running item|HIGH|open|2" \
    "AI-77|Another item|HIGH|open|3")
  local got
  got="$(printf '%s\n' "$records" | esch_format_halt_message)"
  grep -q "AI-42" <<<"$got"
  grep -q "Long-running item" <<<"$got"
  grep -q "AI-77" <<<"$got"
  # escalation_count visible
  grep -q "2" <<<"$got"
  grep -q "3" <<<"$got"
}

@test "esch_format_halt_message: includes exit guidance referencing /gaia-action-items" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' "AI-42|Long-running item|HIGH|open|2")
  local got
  got="$(printf '%s\n' "$records" | esch_format_halt_message)"
  grep -q "/gaia-action-items" <<<"$got"
}

@test "esch_format_halt_message: mentions override flag" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' "AI-42|Long-running item|HIGH|open|2")
  local got
  got="$(printf '%s\n' "$records" | esch_format_halt_message)"
  grep -q "override-escalation-halt" <<<"$got"
}

@test "esch_format_halt_message: shows priority: HIGH in each row (AC2)" {
  _load_esch_helpers
  local records
  records=$(printf '%s\n' "AI-42|T|HIGH|open|2")
  local got
  got="$(printf '%s\n' "$records" | esch_format_halt_message)"
  grep -q "HIGH" <<<"$got"
}

# ===========================================================================
# esch_check_override_recorded — idempotency predicate
# ===========================================================================

@test "esch_check_override_recorded: exit 0 when override present with matching item_ids" {
  _load_esch_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
stories: []
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: escalation_halt
    overridden_item_ids:
      - "AI-42"
    reason: "Acknowledged by lead"
EOF
  run esch_check_override_recorded "$yaml" "AI-42"
  [ "$status" -eq 0 ]
}

@test "esch_check_override_recorded: exit 1 when no override block exists" {
  _load_esch_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$yaml"
  run esch_check_override_recorded "$yaml" "AI-42"
  [ "$status" -ne 0 ]
}

@test "esch_check_override_recorded: exit 1 when override exists but ids differ" {
  _load_esch_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
stories: []
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: escalation_halt
    overridden_item_ids:
      - "AI-99"
    reason: "Different item"
EOF
  run esch_check_override_recorded "$yaml" "AI-42"
  [ "$status" -ne 0 ]
}

@test "esch_check_override_recorded: order-insensitive match (AC3 dedup key)" {
  _load_esch_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
stories: []
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: escalation_halt
    overridden_item_ids:
      - "AI-7"
      - "AI-42"
    reason: "ok"
EOF
  # Query with ids reversed; should still match (sorted dedup key).
  run esch_check_override_recorded "$yaml" "AI-42,AI-7"
  [ "$status" -eq 0 ]
}

@test "esch_check_override_recorded: only counts escalation_halt type" {
  _load_esch_helpers
  local yaml="$TEST_TMP/sprint-status.yaml"
  cat > "$yaml" <<'EOF'
sprint_id: "sprint-99"
stories: []
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: dependency_inversion
    overridden_item_ids:
      - "AI-42"
    reason: "other"
EOF
  run esch_check_override_recorded "$yaml" "AI-42"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# esch_check_blocking — top-level predicate (used by SKILL Step 1.5)
# ===========================================================================

@test "esch_check_blocking: exit 0 when no matching items (AC1)" {
  _load_esch_helpers
  local ai="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$ai" "AI-1|x|MEDIUM|open|5"
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  run esch_check_blocking "$ai" "$ss"
  [ "$status" -eq 0 ]
}

@test "esch_check_blocking: exit 1 + halt msg when blocking items present (AC2)" {
  _load_esch_helpers
  local ai="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$ai" "AI-42|Long-running|HIGH|open|2"
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  run esch_check_blocking "$ai" "$ss"
  [ "$status" -ne 0 ]
  grep -q "AI-42" <<<"$output"
  grep -q "/gaia-action-items" <<<"$output"
}

@test "esch_check_blocking: exit 0 when blocking items have recorded override (AC3 idempotency)" {
  _load_esch_helpers
  local ai="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$ai" "AI-42|Long-running|HIGH|open|2"
  local ss="$TEST_TMP/sprint-status.yaml"
  cat > "$ss" <<'EOF'
sprint_id: "sprint-99"
stories: []
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: escalation_halt
    overridden_item_ids:
      - "AI-42"
    reason: "ack"
EOF
  run esch_check_blocking "$ai" "$ss"
  [ "$status" -eq 0 ]
}

@test "esch_check_blocking: exit 0 + warning when action-items.yaml missing (AC4)" {
  _load_esch_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  run esch_check_blocking "$TEST_TMP/missing.yaml" "$ss"
  [ "$status" -eq 0 ]
  # Warning surfaces on stderr (captured into $output by bats run)
  grep -q "action-items.yaml not found" <<<"$output"
}

@test "esch_check_blocking: GAIA_ESCALATION_HALT=off kill switch bypasses halt" {
  _load_esch_helpers
  local ai="$TEST_TMP/action-items.yaml"
  _make_action_items_yaml "$ai" "AI-42|Long-running|HIGH|open|2"
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  GAIA_ESCALATION_HALT=off run esch_check_blocking "$ai" "$ss"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# sprint-state.sh record-escalation-override — override recording
# ===========================================================================

@test "record-escalation-override: appends overrides entry to sprint-status.yaml (AC3)" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  SPRINT_STATUS_YAML="$ss" run "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "Acknowledged"
  [ "$status" -eq 0 ]
  grep -q "overrides:" "$ss"
  grep -q "AI-42" "$ss"
  grep -q "alice" "$ss"
  grep -q "escalation_halt" "$ss"
  grep -q "Acknowledged" "$ss"
}

@test "record-escalation-override: idempotent — re-run with same ids does not append duplicate (AC3)" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "first"
  local count1
  count1="$(grep -c "AI-42" "$ss" || true)"

  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "second"
  local count2
  count2="$(grep -c "AI-42" "$ss" || true)"

  [ "$count1" = "$count2" ]
}

@test "record-escalation-override: idempotent with out-of-order ids (AC3 dedup key sort)" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-7,AI-42" --user "alice" --reason "first"
  local before_lines
  before_lines="$(wc -l < "$ss")"

  # Same ids, reversed order — must not append a second entry
  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42,AI-7" --user "alice" --reason "second"
  local after_lines
  after_lines="$(wc -l < "$ss")"

  [ "$before_lines" = "$after_lines" ]
}

@test "record-escalation-override: appends a new entry for DIFFERENT item_ids" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice" --reason "first"
  SPRINT_STATUS_YAML="$ss" "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-99" --user "alice" --reason "second"

  grep -q "AI-42" "$ss"
  grep -q "AI-99" "$ss"
}

@test "record-escalation-override: rejects call without --reason" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  SPRINT_STATUS_YAML="$ss" run "$SPRINT_STATE_SH" record-escalation-override \
    --item-ids "AI-42" --user "alice"
  [ "$status" -ne 0 ]
}

@test "record-escalation-override: rejects call without --item-ids" {
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"
  SPRINT_STATUS_YAML="$ss" run "$SPRINT_STATE_SH" record-escalation-override \
    --user "alice" --reason "ack"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# do_record_override_locked — inner logic sans flock wrapper (NFR-052)
#
# Directly exercises the public function that cmd_record_escalation_override
# delegates to after acquiring a lock. Sourced via awk extraction so we can
# call it in-process without the flock/spin-lock wrapper.
# ===========================================================================

_load_sprint_state_override_helpers() {
  local tmp
  tmp="$(mktemp -t sprint-state-override-helpers.XXXXXX)"
  awk '
    /^die\(\) \{/,/^\}/ { print; next }
    /^_override_normalize_ids\(\) \{/,/^\}/ { print; next }
    /^_override_load_esch\(\) \{/,/^\}/ { print; next }
    /^_override_append_entry\(\) \{/,/^\}/ { print; next }
    /^do_record_override_locked\(\) \{/,/^\}/ { print; next }
  ' "$SPRINT_STATE_SH" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

@test "do_record_override_locked: appends override entry to sprint-status.yaml" {
  _load_sprint_state_override_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss"
  SPRINT_STATE_SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT_NAME="sprint-state.sh"
  export SPRINT_STATUS_YAML SPRINT_STATE_SCRIPT_DIR SCRIPT_NAME

  do_record_override_locked "AI-42" "alice" "Acknowledged by lead"

  grep -q "overrides:" "$ss"
  grep -q "AI-42" "$ss"
  grep -q "alice" "$ss"
  grep -q "escalation_halt" "$ss"
  grep -q "Acknowledged by lead" "$ss"
}

@test "do_record_override_locked: idempotent — second call with same ids is a no-op" {
  _load_sprint_state_override_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss"
  SPRINT_STATE_SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT_NAME="sprint-state.sh"
  export SPRINT_STATUS_YAML SPRINT_STATE_SCRIPT_DIR SCRIPT_NAME

  do_record_override_locked "AI-42" "alice" "first"
  local lines_after_first
  lines_after_first="$(wc -l < "$ss")"

  do_record_override_locked "AI-42" "bob" "second"
  local lines_after_second
  lines_after_second="$(wc -l < "$ss")"

  [ "$lines_after_first" = "$lines_after_second" ]
}

@test "do_record_override_locked: normalizes and sorts comma-separated ids" {
  _load_sprint_state_override_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss"
  SPRINT_STATE_SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT_NAME="sprint-state.sh"
  export SPRINT_STATUS_YAML SPRINT_STATE_SCRIPT_DIR SCRIPT_NAME

  do_record_override_locked "AI-99,AI-7" "alice" "multi"

  # The ids should be sorted: AI-7 before AI-99 in the yaml
  grep -q "AI-7" "$ss"
  grep -q "AI-99" "$ss"
}

@test "do_record_override_locked: dies on empty sprint-status.yaml" {
  _load_sprint_state_override_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  : > "$ss"

  SPRINT_STATUS_YAML="$ss"
  SPRINT_STATE_SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT_NAME="sprint-state.sh"
  export SPRINT_STATUS_YAML SPRINT_STATE_SCRIPT_DIR SCRIPT_NAME

  run do_record_override_locked "AI-42" "alice" "ack"
  [ "$status" -ne 0 ]
  grep -q "missing or empty" <<<"$output"
}

@test "do_record_override_locked: dies on empty ids after normalization" {
  _load_sprint_state_override_helpers
  local ss="$TEST_TMP/sprint-status.yaml"
  _make_sprint_status_yaml "$ss"

  SPRINT_STATUS_YAML="$ss"
  SPRINT_STATE_SCRIPT_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SCRIPT_NAME="sprint-state.sh"
  export SPRINT_STATUS_YAML SPRINT_STATE_SCRIPT_DIR SCRIPT_NAME

  run do_record_override_locked ",," "alice" "ack"
  [ "$status" -ne 0 ]
  grep -q "empty list" <<<"$output"
}
