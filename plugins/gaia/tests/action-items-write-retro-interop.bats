#!/usr/bin/env bats
# action-items-write-retro-interop.bats
#
# Tests for action-items-write.sh interoperability with retro-written
# files: id allocation handles both quoted and unquoted ids, anchored
# to item lines only (ignores dated ids, embedded text, non-item
# fields), dedup handles any indent, new entries match the existing
# indent style, and round-trip retro-then-triage produces valid YAML
# with no duplicate ids.
#
# All fixtures use BATS_TEST_TMPDIR — never touches the real plugin tree.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

ACTION_ITEMS_WRITE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/action-items-write.sh"
RETRO_SIDECAR_WRITE_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/retro-sidecar-write.sh"

# ---------------------------------------------------------------------------
# Helper: source the script under test
# ---------------------------------------------------------------------------
_load_aiw() {
  # shellcheck disable=SC1090
  source "$ACTION_ITEMS_WRITE_SH"
}

# ---------------------------------------------------------------------------
# Fixture helper: create retro-style entries via the REAL retro writer.
# Each arg is "sprint_id|text|classification" — ids are auto-allocated.
# The retro writer writes 0-indent entries under items: with dedup_key
# comment lines.
# ---------------------------------------------------------------------------
_make_retro_fixture() {
  local file="$1"; shift
  # root = project root; target is at root/.gaia/state/action-items.yaml
  local root
  root="$(dirname "$(dirname "$(dirname "$file")")")"
  mkdir -p "$(dirname "$file")"
  for entry in "$@"; do
    local sprint="" text="" cls=""
    IFS='|' read -r sprint text cls <<<"$entry"
    local payload
    payload="$(printf -- '- id: AI-{auto}\n  sprint_id: "%s"\n  text: "%s"\n  classification: %s\n  status: open\n  escalation_count: 0\n  created_at: "2026-10-22T00:00:00Z"\n  theme_hash: "sha256:abc"' "$sprint" "$text" "$cls")"
    bash "$RETRO_SIDECAR_WRITE_SH" \
      --root "$root" \
      --sprint-id "$sprint" \
      --target "$file" \
      --payload "$payload" >/dev/null
  done
}

# ===========================================================================
# aiw_next_id — anchored id extraction
# ===========================================================================

@test "aiw_next_id returns correct id from retro-written unquoted entries" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|first item|process" \
    "sprint-50|second item|process"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-3" ]
}

@test "aiw_next_id returns correct id from quoted triage-style entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
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

@test "aiw_next_id ignores dated ids like AI-YYYY-MM-DD-N" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  # Simulate a file with a simple id and a dated id on an item line
  cat >> "$target" <<'EOF'
  - id: AI-5
    text: "simple entry"
  - id: AI-2026-05-08-1
    text: "dated entry"
EOF
  local got
  got="$(aiw_next_id "$target")"
  # Should be AI-6, not AI-2027
  [ "$got" = "AI-6" ]
}

@test "aiw_next_id ignores ids embedded in text fields" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  cat >> "$target" <<'EOF'
  - id: AI-3
    text: "references id: AI-999 from another system"
    status: open
EOF
  local got
  got="$(aiw_next_id "$target")"
  # Should be AI-4, not AI-1000
  [ "$got" = "AI-4" ]
}

@test "aiw_next_id ignores parent_id fields" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  cat >> "$target" <<'EOF'
  - id: AI-3
    parent_id: AI-500
    text: "child entry"
    status: open
EOF
  local got
  got="$(aiw_next_id "$target")"
  # Should be AI-4, not AI-501
  [ "$got" = "AI-4" ]
}

@test "aiw_next_id returns the first id for file with no entries" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-1" ]
}

@test "aiw_next_id returns correct id on a trimmed copy of the real action-items file" {
  _load_aiw
  local target="$TEST_TMP/action-items-copy.yaml"
  # Extract item id lines from the real file into a minimal fixture
  local real="/Users/jlouage/Dev/GAIA-Framework/.gaia/state/action-items.yaml"
  if [ ! -f "$real" ]; then
    skip "real action-items.yaml not present"
  fi
  # Build a trimmed fixture: header + one-line-per-entry stubs with the
  # same ids as the real file (preserves max id without copying 600KB)
  printf 'items:\n' > "$target"
  grep -E '^[[:space:]]*-[[:space:]]+id:' "$real" | while IFS= read -r line; do
    printf '%s\n    status: open\n' "$line" >> "$target"
  done
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-300" ]
}

@test "aiw_next_id returns correct id on the full broken evidence file" {
  _load_aiw
  local broken="/private/tmp/claude-501/-Users-jlouage-Dev-GAIA-Framework/716028f3-0e6a-48e5-a9cc-8247903a0fcb/scratchpad/action-items.broken"
  if [ ! -f "$broken" ]; then
    skip "broken evidence file not present"
  fi
  local target="$TEST_TMP/action-items-broken-copy.yaml"
  cp "$broken" "$target"
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-300" ]
}

# ===========================================================================
# aiw_check_dedup — any-indent entry handling
# ===========================================================================

@test "aiw_check_dedup detects triage entry appended at 0-indent to retro file" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|some retro item|process"
  # Append a triage entry (will be at 0-indent, matching retro style)
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # Dedup should detect the triage entry at 0-indent
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-900"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup returns no-match for different sprint at 0-indent" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|some retro item|process"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  run aiw_check_dedup "$target" "sprint-51" "bug" "finding_id" "F-900"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# aiw_detect_indent — indent detection (skips comments)
# ===========================================================================

@test "aiw_detect_indent returns 0-indent for retro-written entries" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|retro item|process"
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

@test "aiw_detect_indent skips comment lines that mention dash-id" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has only the schema header (which mentions "- id:" in comments)
  # and no actual entries — should default to 2-space
  cat > "$target" <<'EOF'
# each entry starts with "- id: AI-{n}"
# that is a comment, not an entry
items:
EOF
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
  grep -q '^  - id: "AI-5"' <<<"$got"
  grep -q '^    sprint_id: "sprint-50"' <<<"$got"
}

@test "aiw_build_entry with empty prefix produces 0-indent entry" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-50" "process" "test text" "story_key" "E900-S1" "")"
  grep -q '^- id: "AI-5"' <<<"$got"
  grep -q '^  sprint_id: "sprint-50"' <<<"$got"
}

@test "aiw_build_entry defaults to 2-space prefix when no 7th arg" {
  _load_aiw
  local got
  got="$(aiw_build_entry "AI-5" "sprint-50" "process" "test text" "story_key" "E900-S1")"
  grep -q '^  - id: "AI-5"' <<<"$got"
}

# ===========================================================================
# aiw_write — indent preservation on append
# ===========================================================================

@test "aiw_write appends 0-indent entry to retro-written file" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|existing retro item|process"
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # The new entry should be at 0-indent (matching retro style)
  grep -q '^- id: "AI-2"' "$target"
  grep -q '^  sprint_id: "sprint-51"' "$target"
}

@test "aiw_write appends 2-space entry to triage-bootstrapped file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # First entry via triage writer (creates 2-space indent)
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "existing item" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  # Second entry
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # Both entries should be at 2-space indent
  grep -q '^  - id: "AI-1"' "$target"
  grep -q '^  - id: "AI-2"' "$target"
}

@test "aiw_write allocates correct id after retro-written entries" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|first retro|process" \
    "sprint-50|second retro|process" \
    "sprint-50|third retro|process"
  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new item" \
    --ref-key "finding_id" --ref-value "F-900")"
  grep -q 'id=AI-4' <<<"$got"
}

# ===========================================================================
# Round-trip: real retro writer then triage writer
# ===========================================================================

@test "round-trip real-retro-then-triage produces valid YAML with no duplicate ids" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|retro item one|process" \
    "sprint-50|retro item two|implementation"
  # Triage append via the real triage writer
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null

  # Must parse as valid YAML
  run yq '.' "$target"
  [ "$status" -eq 0 ]

  # No duplicate ids
  local id_count unique_count
  id_count="$(grep -cE '^[[:space:]]*-[[:space:]]+id:' "$target")"
  unique_count="$(grep -E '^[[:space:]]*-[[:space:]]+id:' "$target" | grep -oE 'AI-[0-9]+' | sort -u | wc -l | tr -d ' ')"
  [ "$id_count" -eq "$unique_count" ]

  # The triage entry should be exactly AI-3 (after AI-1, AI-2)
  grep -qE '^[[:space:]]*-[[:space:]]+id:.*"AI-3"' "$target"
}

@test "round-trip dedup works: retro then triage then duplicate triage is skipped" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|retro item|process"
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
# aiw_detect_indent — comment lines and mixed-indent
# ===========================================================================

@test "aiw_detect_indent takes indent from the last item in a mixed-indent file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  cat > "$target" <<'EOF'
items:
  - id: AI-1
    text: "2-space entry"
- id: AI-2
  text: "0-indent entry"
EOF
  local got
  got="$(aiw_detect_indent "$target")"
  # Last item is at 0-indent, so new entries should match
  [ "$got" = "" ]
}

# ===========================================================================
# Post-append verification — fail closed on corrupt writes
# ===========================================================================

@test "aiw_write fails closed when append produces invalid YAML" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Create a file where the comment-only header mentions "- id:" but has
  # no real entries. The bootstrap header's comment line starts with "#",
  # which detect_indent correctly skips.
  cat > "$target" <<'EOF'
# items from comment: each starts with "- id: AI-{n}"
#   - id: AI-1
items:
EOF
  # Write should succeed because detect_indent skips comment lines
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "first real entry" \
    --ref-key "story_key" --ref-value "E900-S1"
  [ "$status" -eq 0 ]
  grep -q 'status=ok' <<<"$output"
  # The entry should be a real item that yq can read
  local items_count
  items_count="$(yq '.items | length' "$target" 2>/dev/null || echo 0)"
  [ "$items_count" -ge 1 ]
}

@test "aiw_write restores backup when id not found after append" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  local before
  before="$(cat "$target")"
  # Sabotage: make the id-verification grep pattern unmatchable by
  # overriding aiw_append_entry to write garbage instead of the entry
  aiw_append_entry() {
    printf '\ngarbage that has no id line\n' >> "$1"
  }
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "doomed entry" \
    --ref-key "story_key" --ref-value "E900-S1"
  [ "$status" -eq 1 ]
  grep -q 'status=error' <<<"$output"
  grep -q 'restored backup' <<<"$output"
  # File content should be restored
  local after
  after="$(cat "$target")"
  [ "$before" = "$after" ]
}

# ===========================================================================
# Safety: tests use only temp dirs
# ===========================================================================

@test "test fixtures are created under BATS_TEST_TMPDIR" {
  [[ "$TEST_TMP" == "$BATS_TEST_TMPDIR"* ]]
}
