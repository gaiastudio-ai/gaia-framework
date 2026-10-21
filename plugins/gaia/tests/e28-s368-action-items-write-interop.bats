#!/usr/bin/env bats
# e28-s368-action-items-write-interop.bats
#
# Tests for action-items-write.sh fixes: id allocation handles both
# quoted and unquoted ids, dedup handles any indent, and new entries
# match the existing indent style. Round-trip retro-then-triage
# produces valid YAML with no duplicate ids.
#
# All fixtures use BATS_TEST_TMPDIR — never touches the real plugin tree.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

ACTION_ITEMS_WRITE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/action-items-write.sh"

# ---------------------------------------------------------------------------
# Helper: source the script under test
# ---------------------------------------------------------------------------
_load_aiw() {
  # shellcheck disable=SC1090
  source "$ACTION_ITEMS_WRITE_SH"
}

# ---------------------------------------------------------------------------
# Fixture helper: create a retro-style action-items.yaml (unquoted ids,
# 2-space indent under items: mapping — matches what /gaia-retro writes).
# Uses the real aiw_bootstrap_file for the header, then appends entries
# in retro format (unquoted ids).
# ---------------------------------------------------------------------------
_make_retro_fixture() {
  local file="$1"; shift
  _load_aiw
  aiw_bootstrap_file "$file"
  for entry in "$@"; do
    local id="" sprint="" cls="" text="" ref_key="" ref_val=""
    IFS='|' read -r id sprint cls text ref_key ref_val <<<"$entry"
    {
      printf '  - id: %s\n' "$id"
      printf '    sprint_id: "%s"\n' "$sprint"
      printf '    text: "%s"\n' "$text"
      printf '    classification: %s\n' "$cls"
      printf '    status: open\n'
      printf '    escalation_count: 0\n'
      printf '    created_at: "2026-10-21T00:00:00Z"\n'
      printf '    theme_hash: "sha256:abc"\n'
      if [ -n "${ref_key:-}" ]; then
        printf '    %s: "%s"\n' "$ref_key" "${ref_val:-}"
      fi
    } >> "$file"
  done
}

# ---------------------------------------------------------------------------
# Fixture helper: create a 0-indent bare-list action-items file
# (simulates the corruption where entries are outside the items: mapping).
# ---------------------------------------------------------------------------
_make_zero_indent_fixture() {
  local file="$1"; shift
  printf '# Action Items\n' > "$file"
  for entry in "$@"; do
    local id="" sprint="" cls="" text="" ref_key="" ref_val=""
    IFS='|' read -r id sprint cls text ref_key ref_val <<<"$entry"
    {
      printf -- '- id: %s\n' "$id"
      printf '  sprint_id: "%s"\n' "$sprint"
      printf '  text: "%s"\n' "$text"
      printf '  classification: %s\n' "$cls"
      printf '  status: open\n'
      printf '  escalation_count: 0\n'
      printf '  created_at: "2026-10-21T00:00:00Z"\n'
      printf '  theme_hash: "sha256:abc"\n'
      if [ -n "${ref_key:-}" ]; then
        printf '  %s: "%s"\n' "$ref_key" "${ref_val:-}"
      fi
    } >> "$file"
  done
}

# ===========================================================================
# aiw_next_id — unquoted and quoted id handling
# ===========================================================================

@test "aiw_next_id returns correct id from unquoted retro-style entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|first item|story_key|E900-S1" \
    "AI-6|sprint-50|process|sixth item|story_key|E900-S2"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-7" ]
}

@test "aiw_next_id returns correct id from quoted triage-style entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Use the real writer to create quoted entries
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "item one" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "item two" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-3" ]
}

@test "aiw_next_id returns correct id from mixed quoted and unquoted entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|retro item|story_key|E900-S1" \
    "AI-5|sprint-50|process|retro item five|story_key|E900-S2"
  # Now append a triage entry via the real writer (will be quoted)
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-7" ]
}

@test "aiw_next_id returns AI-1 for file with no entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-1" ]
}

# ===========================================================================
# aiw_check_dedup — 0-indent entry handling
# ===========================================================================

@test "aiw_check_dedup detects existing entry in 0-indent file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_zero_indent_fixture "$target" \
    "AI-1|sprint-50|process|some item|story_key|E900-S1"
  run aiw_check_dedup "$target" "sprint-50" "process" "story_key" "E900-S1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup returns no-match for different sprint in 0-indent file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_zero_indent_fixture "$target" \
    "AI-1|sprint-50|process|some item|story_key|E900-S1"
  run aiw_check_dedup "$target" "sprint-51" "process" "story_key" "E900-S1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup detects existing entry in retro-style 2-space-indent file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|some item|story_key|E900-S1"
  run aiw_check_dedup "$target" "sprint-50" "process" "story_key" "E900-S1"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# aiw_detect_indent — indent detection
# ===========================================================================

@test "aiw_detect_indent returns 2-space for items-mapping entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|item|story_key|E900-S1"
  local got
  got="$(aiw_detect_indent "$target")"
  [ "$got" = "  " ]
}

@test "aiw_detect_indent returns empty string for 0-indent entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_zero_indent_fixture "$target" \
    "AI-1|sprint-50|process|item|story_key|E900-S1"
  local got
  got="$(aiw_detect_indent "$target")"
  [ "$got" = "" ]
}

@test "aiw_detect_indent returns 2-space for empty bootstrapped file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  local got
  got="$(aiw_detect_indent "$target")"
  [ "$got" = "  " ]
}

# ===========================================================================
# aiw_build_entry — indent-aware output
# ===========================================================================

@test "aiw_build_entry with 2-space prefix produces standard indented entry" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-50" "process" "test text" "story_key" "E900-S1" "  ")"
  # List item at 2-space indent
  printf '%s\n' "$got" | grep -q '^  - id: "AI-5"'
  # Fields at 4-space indent
  printf '%s\n' "$got" | grep -q '^    sprint_id: "sprint-50"'
}

@test "aiw_build_entry with empty prefix produces 0-indent entry" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-50" "process" "test text" "story_key" "E900-S1" "")"
  # List item at column 0
  printf '%s\n' "$got" | grep -q '^- id: "AI-5"'
  # Fields at 2-space indent
  printf '%s\n' "$got" | grep -q '^  sprint_id: "sprint-50"'
}

@test "aiw_build_entry defaults to 2-space prefix when no 7th arg" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-50" "process" "test text" "story_key" "E900-S1")"
  printf '%s\n' "$got" | grep -q '^  - id: "AI-5"'
}

# ===========================================================================
# aiw_write — indent preservation on append
# ===========================================================================

@test "aiw_write appends 0-indent entry to 0-indent file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_zero_indent_fixture "$target" \
    "AI-1|sprint-50|process|existing item|story_key|E900-S1"
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # The new entry should be at 0-indent
  grep -q '^- id: "AI-2"' "$target"
  # Fields at 2-space indent
  grep -q '^  sprint_id: "sprint-51"' "$target"
}

@test "aiw_write appends 2-space entry to items-mapping file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|existing item|story_key|E900-S1"
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # The new entry should be at 2-space indent
  grep -q '^  - id: "AI-2"' "$target"
  # Fields at 4-space indent
  grep -q '^    sprint_id: "sprint-51"' "$target"
}

@test "aiw_write allocates correct id after retro-written unquoted entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|first|story_key|E900-S1" \
    "AI-6|sprint-50|process|sixth|story_key|E900-S2"
  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new item" \
    --ref-key "finding_id" --ref-value "F-900")"
  grep -q 'id=AI-7' <<<"$got"
}

# ===========================================================================
# Round-trip: retro writes then triage appends — valid YAML, no dupes
# ===========================================================================

@test "round-trip retro-then-triage produces valid YAML with no duplicate ids" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Retro-style entries
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|retro item one|story_key|E900-S1" \
    "AI-2|sprint-50|process|retro item two|story_key|E900-S2"
  # Triage append via the real writer
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null

  # Must parse as valid YAML
  run yq '.' "$target"
  [ "$status" -eq 0 ]

  # No duplicate ids — each id value should appear exactly once.
  # Use a tight pattern that matches entry id lines, not schema comments.
  local id_count
  id_count="$(grep -cE '^[[:space:]]*-[[:space:]]+id:' "$target")"
  local unique_count
  unique_count="$(grep -E '^[[:space:]]*-[[:space:]]+id:' "$target" | grep -oE 'AI-[0-9]+' | sort -u | wc -l | tr -d ' ')"
  [ "$id_count" -eq "$unique_count" ]

  # The triage entry should be AI-3 (after AI-1, AI-2)
  grep -q 'AI-3' "$target"
}

@test "round-trip 0-indent retro then triage produces valid YAML" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_zero_indent_fixture "$target" \
    "AI-1|sprint-50|process|retro item|story_key|E900-S1"
  # Triage append
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null

  # Must parse as valid YAML
  run yq '.' "$target"
  [ "$status" -eq 0 ]

  # New entry at 0-indent (not 2-space)
  grep -q '^- id: "AI-2"' "$target"
}

@test "round-trip dedup works after retro entries with unquoted ids" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  _make_retro_fixture "$target" \
    "AI-1|sprint-50|process|retro item|story_key|E900-S1"
  # First triage write
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # Duplicate attempt
  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item again" \
    --ref-key "finding_id" --ref-value "F-900")"
  grep -q 'status=skipped_idempotent' <<<"$got"
}

# ===========================================================================
# Safety: tests use only temp dirs
# ===========================================================================

@test "all test fixtures are created in BATS_TEST_TMPDIR" {
  # This test verifies the test suite itself uses temp dirs.
  # The TEST_TMP var from test_helper.bash is under BATS_TEST_TMPDIR.
  [[ "$TEST_TMP" == *"$BATS_TEST_TMPDIR"* ]] || [[ "$TEST_TMP" == "$BATS_TEST_TMPDIR"* ]]
}
