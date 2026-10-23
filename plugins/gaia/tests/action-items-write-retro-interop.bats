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
# All fixtures are self-contained in BATS_TEST_TMPDIR.

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
# ---------------------------------------------------------------------------
_make_retro_fixture() {
  local file="$1"; shift
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

# ---------------------------------------------------------------------------
# Fixture helper: build a realistic mixed-format action-items file
# entirely in BATS_TEST_TMPDIR. Uses synthetic dated ids (AI-2099-*).
# ---------------------------------------------------------------------------
_make_realistic_fixture() {
  local file="$1"
  {
    cat <<'HEADER'
# Action Items
# Written by /gaia-retro. Each entry:
#   id: AI-{n}            # auto-incremented
items:
HEADER
    # 2-space block (retro-style, unquoted ids) — ids up to 295
    local i
    for i in 1 50 100 150 200 250 295; do
      printf '  - id: AI-%d\n    text: "entry %d"\n    status: open\n' "$i" "$i"
    done
    # Synthetic dated ids (must be ignored by the anchored regex)
    printf '  - id: AI-2099-01-01-1\n    text: "dated entry"\n    status: open\n'
    printf '  - id: AI-2099-01-01-2\n    text: "another dated"\n    status: open\n'
    # 0-indent block (retro-writer after yq re-indent) — ids 296-299
    for i in 296 297 298 299; do
      printf -- '- id: AI-%d\n  sprint_id: "sprint-148"\n  text: "retro item %d"\n  classification: process\n  status: open\n' "$i" "$i"
      printf '# dedup_key: fake%d\n' "$i"
    done
    # Quoted triage entry (written by aiw_write)
    printf '\n  - id: "AI-290"\n    sprint_id: "sprint-147"\n    text: "triage entry"\n    status: "open"\n'
    # Embedded id in text (must NOT inflate max)
    printf '  - id: AI-5\n    text: "see also id: AI-9999 in tracker"\n    status: open\n'
    # parent_id field (must NOT inflate max)
    printf '  - id: AI-6\n    parent_id: AI-5000\n    status: open\n'
    # Text line that looks like an id line but is not (no leading dash)
    printf '    copied from tracker - id: AI-888\n'
  } > "$file"
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

@test "aiw_next_id ignores dated ids" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  cat >> "$target" <<'EOF'
  - id: AI-5
    text: "simple entry"
  - id: AI-2099-01-01-1
    text: "dated entry"
EOF
  local got
  got="$(aiw_next_id "$target")"
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

@test "aiw_next_id returns correct id on a realistic mixed-format fixture" {
  _load_aiw
  local target="$TEST_TMP/action-items-realistic.yaml"
  _make_realistic_fixture "$target"
  local got
  got="$(aiw_next_id "$target")"
  # Max simple numeric id is 299; dated/embedded/parent_id/text-line all ignored
  [ "$got" = "AI-300" ]
}

@test "aiw_next_id exact id check does not prefix-match dated ids" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  cat >> "$target" <<'EOF'
  - id: AI-2099-01-01-1
    text: "dated only"
  - id: AI-2099-09-21-3
    text: "another dated"
EOF
  local got
  got="$(aiw_next_id "$target")"
  [ "$got" = "AI-1" ]
}

@test "aiw_next_id ignores text lines that resemble id lines but lack a leading dash" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_bootstrap_file "$target"
  cat >> "$target" <<'EOF'
  - id: AI-3
    text: "real entry"
    status: open
    copied from tracker - id: AI-888
EOF
  local got
  got="$(aiw_next_id "$target")"
  # AI-888 is on a text line without a leading "- ", must be ignored
  [ "$got" = "AI-4" ]
}

# ===========================================================================
# aiw_check_dedup — any-indent entry handling
# ===========================================================================

@test "aiw_check_dedup detects triage entry appended at 0-indent to retro file" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|some retro item|process"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
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
# aiw_detect_indent — indent detection (skips comments, uses last entry)
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
  cat > "$target" <<'EOF'
# each entry starts with "- id: AI-{n}"
# that is a comment, not an entry
items:
EOF
  local got
  got="$(aiw_detect_indent "$target")"
  [ "$got" = "  " ]
}

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
  [ "$got" = "" ]
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
  grep -q '^- id: "AI-2"' "$target"
  grep -q '^  sprint_id: "sprint-51"' "$target"
}

@test "aiw_write appends 2-space entry to triage-bootstrapped file" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "existing item" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "new triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
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

@test "aiw_write refuses a symlink target" {
  _load_aiw
  local real="$TEST_TMP/real-action-items.yaml"
  local symlink="$TEST_TMP/symlink-action-items.yaml"
  aiw_bootstrap_file "$real"
  ln -s "$real" "$symlink"
  run aiw_write --target "$symlink" --sprint-id "sprint-50" \
    --classification "process" --text "symlink attempt" \
    --ref-key "story_key" --ref-value "E900-S1"
  [ "$status" -eq 1 ]
  grep -q 'symlink' <<<"$output"
  ! grep -q 'symlink attempt' "$real"
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
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null

  run yq '.' "$target"
  [ "$status" -eq 0 ]

  local id_count unique_count
  id_count="$(grep -cE '^[[:space:]]*-[[:space:]]+id:' "$target")"
  unique_count="$(grep -E '^[[:space:]]*-[[:space:]]+id:' "$target" | grep -oE 'AI-[0-9]+' | sort -u | wc -l | tr -d ' ')"
  [ "$id_count" -eq "$unique_count" ]

  grep -qE '^[[:space:]]*-[[:space:]]+id:.*"AI-3"' "$target"
}

@test "round-trip dedup works: retro then triage then duplicate triage is skipped" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|retro item|process"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  local got
  got="$(aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage item again" \
    --ref-key "finding_id" --ref-value "F-900")"
  grep -q 'status=skipped_idempotent' <<<"$got"
}

# ===========================================================================
# Safety: tests use only temp dirs, no machine-specific paths
# ===========================================================================

@test "test fixtures are created under BATS_TEST_TMPDIR" {
  [[ "$TEST_TMP" == "$BATS_TEST_TMPDIR"* ]]
}

@test "no machine-specific paths leak into this test file" {
  local pat
  pat="/""Users/[a-z]|/""home/[a-z]|claude""-501"
  ! grep -qE "$pat" "$BATS_TEST_DIRNAME/action-items-write-retro-interop.bats"
}
