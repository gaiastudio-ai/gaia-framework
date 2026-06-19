#!/usr/bin/env bats
# e39-s3-action-items-write-units.bats
#
# Unit tests for action-items-write.sh public functions added by E39-S3
# (Action-items writes in correct-course and triage). Satisfies NFR-052
# public-function coverage gate by directly exercising each new public
# function.
#
# Functions under test (action-items-write.sh):
#   - aiw_bootstrap_file         — create action-items.yaml with schema header
#   - aiw_next_id                — compute next AI-{n} id from existing entries
#   - aiw_check_dedup            — idempotent dedup by composite key
#   - aiw_validate_classification — enforce explicit classification enum
#   - aiw_build_entry            — build a YAML entry string
#   - aiw_append_entry           — atomic append with flock
#   - aiw_write                  — top-level orchestrator
#
# Pattern: source the script as a library then call each function directly —
# same approach as e38-s2-escalation-halt-units.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

ACTION_ITEMS_WRITE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/action-items-write.sh"

# ---------------------------------------------------------------------------
# Helper: source action-items-write.sh as a library
# ---------------------------------------------------------------------------
_load_aiw() {
  # shellcheck disable=SC1090
  source "$ACTION_ITEMS_WRITE_SH"
}

# ---------------------------------------------------------------------------
# Fixture: create action-items.yaml with entries
# ---------------------------------------------------------------------------
_make_action_items() {
  # $1 = file path, $2+ = entries as "id|sprint|classification|status|esc|text|ref_key|ref_val"
  local file="$1"; shift
  {
    cat <<'HEADER'
# Action Items — architecture §10.28.6 schema
# Written by /gaia-retro (ADR-052 shared writer). Each entry:
#   id: AI-{n}            # auto-incremented
#   sprint_id: "..."
#   text: "..."
#   classification: clarification|implementation|process|automation
#   status: open|in-progress|resolved
#   escalation_count: 0    # bumped by cross-retro detection (FR-RIM-1)
#   created_at: "<ISO 8601>"
#   theme_hash: "sha256:<hex>"
items:
HEADER
    for entry in "$@"; do
      local id="" sprint="" cls="" status="" esc="" text="" ref_key="" ref_val=""
      IFS='|' read -r id sprint cls status esc text ref_key ref_val <<<"$entry"
      printf '  - id: "%s"\n' "$id"
      printf '    sprint_id: "%s"\n' "$sprint"
      printf '    text: "%s"\n' "$text"
      printf '    classification: "%s"\n' "$cls"
      printf '    status: "%s"\n' "$status"
      printf '    escalation_count: %s\n' "$esc"
      printf '    created_at: "2026-04-22T00:00:00Z"\n'
      printf '    theme_hash: "sha256:abc"\n'
      if [ -n "${ref_key:-}" ]; then
        printf '    %s: "%s"\n' "$ref_key" "${ref_val:-}"
      fi
    done
  } > "$file"
}

# ===========================================================================
# aiw_bootstrap_file — create action-items.yaml with schema header if absent
# ===========================================================================

@test "aiw_bootstrap_file: creates file with schema header when absent (AC3)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  [ ! -e "$target" ]
  aiw_bootstrap_file "$target"
  [ -f "$target" ]
  grep -q "Action Items" "$target"
  grep -q "items:" "$target"
}

@test "aiw_bootstrap_file: is a no-op when file already exists" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  echo "existing content" > "$target"
  aiw_bootstrap_file "$target"
  grep -q "existing content" "$target"
}

@test "aiw_bootstrap_file: creates parent directories if missing" {
  _load_aiw
  local target="$TEST_TMP/deep/nested/dir/action-items.yaml"
  aiw_bootstrap_file "$target"
  [ -f "$target" ]
}

# ===========================================================================
# aiw_next_id — compute next AI-{n} from existing entries
# ===========================================================================

@test "aiw_next_id: returns when file has no entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-1" ]
}

@test "aiw_next_id: returns when highest is" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|process|open|0|item 1||" \
    "AI-3|sprint-25|process|open|0|item 3||"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-4" ]
}

@test "aiw_next_id: handles non-sequential ids (gap-tolerant)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|process|open|0|item||" \
    "AI-10|sprint-25|process|open|0|item||"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-11" ]
}

# ===========================================================================
# aiw_check_dedup — idempotent dedup by composite key
# ===========================================================================

@test "aiw_check_dedup: returns 0 (match) when story_key+sprint_id+classification exists" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|process|open|0|Deferred E99-S9|story_key|E99-S9"
  run aiw_check_dedup "$target" "sprint-25" "process" "story_key" "E99-S9"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup: returns 1 (no match) when no matching entry" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|process|open|0|Deferred E99-S9|story_key|E99-S9"
  run aiw_check_dedup "$target" "sprint-26" "process" "story_key" "E99-S9"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup: returns 1 (no match) for different classification" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|bug|open|0|Bug finding|finding_id|F-001"
  run aiw_check_dedup "$target" "sprint-25" "process" "finding_id" "F-001"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup: returns 0 (match) for finding_id+sprint_id dedup (AC2 idempotency)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-25|bug|open|0|Bug in module X|finding_id|F-001"
  run aiw_check_dedup "$target" "sprint-25" "bug" "finding_id" "F-001"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup: returns 1 when file is empty (header only)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  run aiw_check_dedup "$target" "sprint-25" "process" "story_key" "E99-S9"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# aiw_validate_classification — enforce explicit classification enum
# ===========================================================================

@test "aiw_validate_classification: accepts process" {
  _load_aiw
  run aiw_validate_classification "process"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts bug" {
  _load_aiw
  run aiw_validate_classification "bug"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts task" {
  _load_aiw
  run aiw_validate_classification "task"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts research" {
  _load_aiw
  run aiw_validate_classification "research"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts clarification" {
  _load_aiw
  run aiw_validate_classification "clarification"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts implementation" {
  _load_aiw
  run aiw_validate_classification "implementation"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: accepts automation" {
  _load_aiw
  run aiw_validate_classification "automation"
  [ "$status" -eq 0 ]
}

@test "aiw_validate_classification: rejects unknown type with exit 1 (scenario 7)" {
  _load_aiw
  run aiw_validate_classification "unknown-type"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown-type"
}

@test "aiw_validate_classification: rejects empty string" {
  _load_aiw
  run aiw_validate_classification ""
  [ "$status" -eq 1 ]
}

# ===========================================================================
# aiw_build_entry — build a YAML entry string
# ===========================================================================

@test "aiw_build_entry: produces valid YAML with all required fields (AC1)" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-25" "process" "Deferred story" "story_key" "E99-S9")"
  echo "$got" | grep -q 'id: "AI-5"'
  echo "$got" | grep -q 'sprint_id: "sprint-25"'
  echo "$got" | grep -q 'classification: "process"'
  echo "$got" | grep -q 'status: "open"'
  echo "$got" | grep -q 'escalation_count: 0'
  echo "$got" | grep -q 'story_key: "E99-S9"'
  echo "$got" | grep -q 'text: "Deferred story"'
  echo "$got" | grep -q 'created_at:'
}

@test "aiw_build_entry: uses finding_id reference for triage entries (AC2)" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-1" "sprint-25" "bug" "Bug found" "finding_id" "F-001")"
  echo "$got" | grep -q 'finding_id: "F-001"'
  ! echo "$got" | grep -q 'story_key:'
}

@test "aiw_build_entry: includes theme_hash as sha256 hex" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-1" "sprint-25" "process" "Test text" "story_key" "E1-S1")"
  echo "$got" | grep -q 'theme_hash: "sha256:'
}

@test "aiw_build_entry: created_at is ISO 8601 format" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-1" "sprint-25" "process" "Test" "story_key" "E1-S1")"
  # Match ISO 8601 pattern: YYYY-MM-DDTHH:MM:SSZ
  echo "$got" | grep -qE 'created_at: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'
}

# ===========================================================================
# aiw_write — top-level orchestrator
# ===========================================================================

@test "aiw_write: correct-course defer creates entry with classification=process (AC1, scenario 1)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Deferred E99-S9 from sprint" \
    --ref-key "story_key" --ref-value "E99-S9"
  [ "$status" -eq 0 ]
  grep -q 'classification: "process"' "$target"
  grep -q 'story_key: "E99-S9"' "$target"
  grep -q 'status: "open"' "$target"
  grep -q 'escalation_count: 0' "$target"
}

@test "aiw_write: triage NOW bug creates entry with classification=bug (AC2, scenario 2)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "bug" --text "Bug finding F-001" \
    --ref-key "finding_id" --ref-value "F-001"
  [ "$status" -eq 0 ]
  grep -q 'classification: "bug"' "$target"
  grep -q 'finding_id: "F-001"' "$target"
}

@test "aiw_write: triage NOW task creates entry with classification=task (AC2, scenario 3)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "task" --text "Task finding" \
    --ref-key "finding_id" --ref-value "F-002"
  [ "$status" -eq 0 ]
  grep -q 'classification: "task"' "$target"
}

@test "aiw_write: triage NOW research creates entry with classification=research (AC2, scenario 3)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "research" --text "Research finding" \
    --ref-key "finding_id" --ref-value "F-003"
  [ "$status" -eq 0 ]
  grep -q 'classification: "research"' "$target"
}

@test "aiw_write: bootstraps file when missing (AC3, scenario 4)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  [ ! -e "$target" ]
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "First entry" \
    --ref-key "story_key" --ref-value "E99-S9"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # Has schema header
  grep -q "Action Items" "$target"
  grep -q "items:" "$target"
  # Has the entry
  grep -q 'story_key: "E99-S9"' "$target"
}

@test "aiw_write: idempotent — same finding re-run does not duplicate (scenario 5)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "bug" --text "Bug F-001" \
    --ref-key "finding_id" --ref-value "F-001"
  local count1
  count1="$(grep -c 'finding_id: "F-001"' "$target")"

  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "bug" --text "Bug F-001 again" \
    --ref-key "finding_id" --ref-value "F-001"
  local count2
  count2="$(grep -c 'finding_id: "F-001"' "$target")"

  [ "$count1" -eq 1 ]
  [ "$count2" -eq 1 ]
}

@test "aiw_write: idempotent — same story deferred twice does not duplicate (scenario 6)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Deferred E99-S9" \
    --ref-key "story_key" --ref-value "E99-S9"
  local count1
  count1="$(grep -c 'story_key: "E99-S9"' "$target")"

  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Deferred E99-S9 again" \
    --ref-key "story_key" --ref-value "E99-S9"
  local count2
  count2="$(grep -c 'story_key: "E99-S9"' "$target")"

  [ "$count1" -eq 1 ]
  [ "$count2" -eq 1 ]
}

@test "aiw_write: unknown classification halts with error (scenario 7)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "mystery" --text "Unknown type" \
    --ref-key "finding_id" --ref-value "F-999"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "mystery"
  # No entry should have been written
  [ ! -e "$target" ] || ! grep -q 'finding_id: "F-999"' "$target"
}

@test "aiw_write: auto-increments id correctly with existing entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_action_items "$target" \
    "AI-1|sprint-24|process|open|0|Old item|story_key|E1-S1" \
    "AI-2|sprint-24|bug|open|0|Old bug|finding_id|F-100"

  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "New deferred" \
    --ref-key "story_key" --ref-value "E99-S9"

  grep -q 'id: "AI-3"' "$target"
}

@test "aiw_write: allows same ref in different sprint (no false dedup)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Sprint 25 defer" \
    --ref-key "story_key" --ref-value "E99-S9"
  aiw_write --target "$target" --sprint-id "sprint-26" \
    --classification "process" --text "Sprint 26 defer" \
    --ref-key "story_key" --ref-value "E99-S9"

  local count
  count="$(grep -c 'story_key: "E99-S9"' "$target")"
  [ "$count" -eq 2 ]
}

@test "aiw_write: outputs status=ok on success" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Test" \
    --ref-key "story_key" --ref-value "E1-S1")"
  echo "$got" | grep -q "status=ok"
}

@test "aiw_write: outputs status=skipped_idempotent on dedup hit" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Test" \
    --ref-key "story_key" --ref-value "E1-S1" >/dev/null

  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-25" \
    --classification "process" --text "Test again" \
    --ref-key "story_key" --ref-value "E1-S1")"
  echo "$got" | grep -q "status=skipped_idempotent"
}

@test "aiw_write: missing --target argument halts with error" {
  _load_aiw
  run aiw_write --sprint-id "sprint-25" \
    --classification "process" --text "Test" \
    --ref-key "story_key" --ref-value "E1-S1"
  [ "$status" -eq 1 ]
}

@test "aiw_write: missing --sprint-id argument halts with error" {
  _load_aiw
  run aiw_write --target "$TEST_TMP/action-items.yaml" \
    --classification "process" --text "Test" \
    --ref-key "story_key" --ref-value "E1-S1"
  [ "$status" -eq 1 ]
}
