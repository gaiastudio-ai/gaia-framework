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
    printf '\n  - id: "AI-90001"\n    sprint_id: "sprint-147"\n    text: "triage entry"\n    status: "open"\n'
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
  # Max simple numeric id is 90001; dated/embedded/parent_id/text-line all ignored
  [ "$got" = "AI-90002" ]
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

@test "aiw_check_dedup matches the first of several entries at 0-indent" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  _make_retro_fixture "$target" \
    "sprint-50|retro item one|process" \
    "sprint-50|retro item two|implementation"
  # Append two triage entries; dedup should find the FIRST one
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "first triage" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "process" --text "second triage" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  # The first triage entry (not the last) must be found
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-900"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup matches entry at 2-space indent when it is the first entry" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Two triage entries at 2-space indent; match the first
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "first entry" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  aiw_write --target "$target" --sprint-id "sprint-51" \
    --classification "process" --text "second entry" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-900"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup handles retro-writer dedup_key comment lines between entries" {
  _load_aiw
  local target="$TEST_TMP/.gaia/state/action-items.yaml"
  # Retro writer puts # dedup_key: lines between entries at column 0
  _make_retro_fixture "$target" \
    "sprint-50|retro item|process"
  # Append a triage entry after the retro entries (with dedup_key comments)
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "triage after retro" \
    --ref-key "finding_id" --ref-value "F-900" >/dev/null
  # The triage entry follows a # dedup_key: comment; dedup must still find it
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
# aiw_check_dedup — exact field matching (no regex, no prefix collisions)
# ===========================================================================

@test "aiw_check_dedup does not prefix-match ref values" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has E900-S368; query E900-S36 must NOT match
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "process"\n  story_key: "E900-S368"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "process" "story_key" "E900-S36"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup does not prefix-match short ref values" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has F-10; query F-1 must NOT match
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "F-10"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup does not match a longer key name" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has xfinding_id; query finding_id must NOT match
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  xfinding_id: "F-1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup does not regex-match metacharacters in ref value" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has FX1; query F.1 must NOT match (dot is not a wildcard)
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "FX1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F.1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup does not crash on regex metacharacters in ref value" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "FX1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-[1"
  [ "$status" -eq 1 ]
  # No awk error in output
  ! grep -qi 'error\|unterminated' <<<"$output"
}

@test "aiw_check_dedup ignores ref key embedded in a text line" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  text: "see finding_id: F-1"\n  finding_id: "F-2"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup matches entries with CRLF line endings" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  printf -- '- id: AI-1\r\n  sprint_id: "sprint-50"\r\n  classification: bug\r\n  finding_id: "F-1"\r\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup matches entry followed by column-0 comment line" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Entry followed by a column-0 comment (retro dedup_key), then another entry.
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "F-1"\n# dedup_key: abc\n- id: AI-2\n  sprint_id: "sprint-51"\n  classification: "process"\n  story_key: "E900-S1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup column-0 flush prevents false positive from stray field" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Entry 1 has sprint_id + classification match but finding_id is F-99.
  # A column-0 line follows with finding_id: F-1 (not part of any entry).
  # Without the column-0 flush, awk stays in_entry and the stray field
  # sets r_match -> false positive.
  {
    printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "F-99"\n'
    printf 'finding_id: "F-1"\n'
  } > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# aiw_check_dedup — nested-map immunity (AC4)
# ===========================================================================

@test "aiw_check_dedup ignores sprint_id inside nested map (no false match)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # Entry where sprint_id appears as a nested field under metadata,
  # not as the entry's own sprint_id
  {
    printf -- '  - id: AI-1\n'
    printf '    sprint_id: "sprint-49"\n'
    printf '    classification: "process"\n'
    printf '    metadata:\n'
    printf '      sprint_id: "sprint-100"\n'
    printf '      note: "nested value"\n'
    printf '    story_key: "E900-S1"\n'
  } > "$target"
  # Query sprint-100: must NOT match (it is nested, not the entry's own sprint_id)
  run aiw_check_dedup "$target" "sprint-100" "process" "story_key" "E900-S1"
  [ "$status" -eq 1 ]
  # Query sprint-49: must match (the entry's actual sprint_id)
  run aiw_check_dedup "$target" "sprint-49" "process" "story_key" "E900-S1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup ignores classification inside nested block" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  {
    printf -- '  - id: AI-1\n'
    printf '    sprint_id: "sprint-50"\n'
    printf '    classification: "bug"\n'
    printf '    context:\n'
    printf '      classification: "process"\n'
    printf '    finding_id: "F-1"\n'
  } > "$target"
  # The nested classification is "process" but entry-level is "bug"
  run aiw_check_dedup "$target" "sprint-50" "process" "finding_id" "F-1"
  [ "$status" -eq 1 ]
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# aiw_check_dedup — inline YAML comment stripping (AC5)
# ===========================================================================

@test "aiw_check_dedup matches entry with trailing inline comment on sprint_id" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  {
    printf -- '- id: AI-1\n'
    printf '  sprint_id: "sprint-99" # was sprint-98\n'
    printf '  classification: bug\n'
    printf '  finding_id: "F-1"\n'
  } > "$target"
  run aiw_check_dedup "$target" "sprint-99" "bug" "finding_id" "F-1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup matches entry with trailing inline comment on unquoted value" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  {
    printf -- '- id: AI-1\n'
    printf '  sprint_id: sprint-99 # comment\n'
    printf '  classification: bug # type\n'
    printf '  finding_id: F-1 # ref\n'
  } > "$target"
  run aiw_check_dedup "$target" "sprint-99" "bug" "finding_id" "F-1"
  [ "$status" -eq 0 ]
}

@test "aiw_check_dedup does not false-match when comment text contains query value" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  {
    printf -- '- id: AI-1\n'
    printf '  sprint_id: sprint-49 # should be sprint-50\n'
    printf '  classification: bug\n'
    printf '  finding_id: "F-1"\n'
  } > "$target"
  # sprint-50 appears in the comment but the actual value is sprint-49
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# YAML escaping — prevents entry forging via newline/quote injection
# ===========================================================================

@test "aiw_write escapes quotes and newlines in text to prevent entry forging" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "legit" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  local forge_text
  forge_text="$(printf 'innocent"\n  - id: "AI-500"\n    text: "forged')"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "$forge_text" \
    --ref-key "finding_id" --ref-value "F-3" >/dev/null
  run yq '.' "$target"
  [ "$status" -eq 0 ]
  local next
  next="$(aiw_next_id "$target")"
  [ "$next" = "AI-3" ]
  # A later F-2 write must succeed (not blocked by a forged entry)
  local r2
  r2="$(aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "real F-2" \
    --ref-key "finding_id" --ref-value "F-2")"
  grep -q 'status=ok' <<<"$r2"
}

@test "aiw_write produces no duplicate ids when text contains injection" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "legit" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  local inject_text
  inject_text="$(printf 'summary"\n  - id: "AI-1"\n    note: "x')"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "$inject_text" \
    --ref-key "finding_id" --ref-value "F-2" >/dev/null
  local dupes
  dupes="$(grep -E '^[[:space:]]*-[[:space:]]+id:' "$target" | grep -oE 'AI-[0-9]+' | sort | uniq -d)"
  [ -z "$dupes" ]
}

@test "aiw_write round-trips backslash and quote through yq" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local input='has a \ backslash and a " quote'
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "$input" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  run yq '.' "$target"
  [ "$status" -eq 0 ]
  local decoded
  decoded="$(yq '.items[0].text' "$target")"
  [ "$decoded" = "$input" ]
}

@test "aiw_write rejects ref-key with newline (prevents entry forging)" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "legit" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  local bad_key
  bad_key="$(printf 'finding_id: "F-3"\n  - id: "AI-500"\n    note')"
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "$bad_key" --ref-value "x"
  [ "$status" -eq 1 ]
  grep -q 'status=error' <<<"$output"
  # Next id must still be 2
  local next
  next="$(aiw_next_id "$target")"
  [ "$next" = "AI-2" ]
  # A later F-2 write must succeed
  local r2
  r2="$(aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "real F-2" \
    --ref-key "finding_id" --ref-value "F-2")"
  grep -q 'status=ok' <<<"$r2"
}

@test "aiw_write escapes ref-value with quote and newline; yq sees one item" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local bad_val
  bad_val="$(printf 'F"1\nforged')"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "$bad_val" >/dev/null
  local n
  n="$(yq '.items | length' "$target")"
  [ "$n" -eq 1 ]
}

@test "aiw_write escapes sprint-id with quote and newline; yq sees one item" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local bad_sprint
  bad_sprint="$(printf 'sp"1\nforged')"
  aiw_write --target "$target" --sprint-id "$bad_sprint" \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  local n
  n="$(yq '.items | length' "$target")"
  [ "$n" -eq 1 ]
}

@test "aiw_write dedup works for ref-value with quote and backslash" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local val='F"1\x'
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "$val" >/dev/null
  local r2
  r2="$(aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "$val")"
  grep -q 'status=skipped_idempotent' <<<"$r2"
  local n
  n="$(yq '.items | length' "$target")"
  [ "$n" -eq 1 ]
}

@test "aiw_write dedup works for sprint-id with quote" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  aiw_write --target "$target" --sprint-id 'sp"1' \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  local r2
  r2="$(aiw_write --target "$target" --sprint-id 'sp"1' \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "F-1")"
  grep -q 'status=skipped_idempotent' <<<"$r2"
}

@test "aiw_write escapes carriage return in text" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local val=$'cr\rx'
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "$val" \
    --ref-key "finding_id" --ref-value "F-1" >/dev/null
  run yq '.' "$target"
  [ "$status" -eq 0 ]
  # The raw file must contain the \r escape, not a literal CR
  grep -q '\\r' "$target"
}

@test "aiw_check_dedup matches sprint_id field by exact name" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has xsprint_id instead of sprint_id
  printf -- '- id: AI-1\n  xsprint_id: "sprint-50"\n  classification: "bug"\n  finding_id: "F-1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

@test "aiw_check_dedup matches classification field by exact name" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  # File has xclassification instead of classification
  printf -- '- id: AI-1\n  sprint_id: "sprint-50"\n  xclassification: "bug"\n  finding_id: "F-1"\n' > "$target"
  run aiw_check_dedup "$target" "sprint-50" "bug" "finding_id" "F-1"
  [ "$status" -eq 1 ]
}

@test "aiw_write rejects control characters in text" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local bel_text
  bel_text="$(printf 'has a \007 bell')"
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "$bel_text" \
    --ref-key "finding_id" --ref-value "F-1"
  [ "$status" -eq 1 ]
  grep -q 'control characters' <<<"$output"
}

@test "aiw_write rejects control characters in ref-value" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local bel_val
  bel_val="$(printf 'F-\007-1')"
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "clean" \
    --ref-key "finding_id" --ref-value "$bel_val"
  [ "$status" -eq 1 ]
  grep -q 'control characters' <<<"$output"
  [ ! -e "$target" ] || ! grep -q 'clean' "$target"
}

@test "aiw_write rejects control characters in sprint-id" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  local bel_sprint
  bel_sprint="$(printf 'sprint-\007-50')"
  run aiw_write --target "$target" --sprint-id "$bel_sprint" \
    --classification "bug" --text "clean" \
    --ref-key "finding_id" --ref-value "F-1"
  [ "$status" -eq 1 ]
  grep -q 'control characters' <<<"$output"
}

@test "aiw_write accepts and round-trips non-ASCII text through yq" {
  _load_aiw
  for input in "café résumé" "emoji 🎉 here" "dash — here" "漢字テスト"; do
    local target="$TEST_TMP/unicode-text.yaml"
    rm -f "$target"
    aiw_write --target "$target" --sprint-id "sprint-50" \
      --classification "bug" --text "$input" \
      --ref-key "finding_id" --ref-value "F-1" >/dev/null
    run yq '.' "$target"
    [ "$status" -eq 0 ]
    local decoded
    decoded="$(yq '.items[0].text' "$target")"
    [ "$decoded" = "$input" ]
  done
}

@test "aiw_write accepts and round-trips non-ASCII ref-value through yq" {
  _load_aiw
  local target="$TEST_TMP/unicode-refval.yaml"
  local input="résumé—done"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "finding_id" --ref-value "$input" >/dev/null
  local decoded
  decoded="$(yq '.items[0].finding_id' "$target")"
  [ "$decoded" = "$input" ]
}

@test "aiw_write rejects ref-key with space or colon" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "bad key" --ref-value "v"
  [ "$status" -eq 1 ]
  run aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "bug" --text "t" \
    --ref-key "bad:key" --ref-value "v"
  [ "$status" -eq 1 ]
}

@test "aiw_write rejects ref-key that is a built-in field name" {
  _load_aiw
  local target="$TEST_TMP/action-items.yaml"
  for key in id status sprint_id classification text created_at escalation_count theme_hash; do
    run aiw_write --target "$target" --sprint-id "sprint-50" \
      --classification "bug" --text "t" \
      --ref-key "$key" --ref-value "v"
    [ "$status" -eq 1 ]
    grep -q 'built-in field' <<<"$output"
  done
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

@test "no test in this file writes outside its temp directory (plugin tree unchanged)" {
  _load_aiw
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # Snapshot the plugin scripts directory state before a representative write
  local before after
  before="$(git -C "$repo_root" status --porcelain -- plugins/gaia/scripts/ 2>/dev/null || echo "NOGIT")"
  local target="$TEST_TMP/litter-check.yaml"
  aiw_write --target "$target" --sprint-id "sprint-50" \
    --classification "process" --text "litter test" \
    --ref-key "story_key" --ref-value "E900-S1" >/dev/null
  after="$(git -C "$repo_root" status --porcelain -- plugins/gaia/scripts/ 2>/dev/null || echo "NOGIT")"
  [ "$before" = "$after" ]
  # Verify the write went to the temp dir, not the plugin tree
  [ -f "$target" ]
  grep -q 'litter test' "$target"
}

@test "no machine-specific paths leak into this test file" {
  local pat
  pat="/""Users/[a-z]|/""home/[a-z]|claude""-501"
  ! grep -qE "$pat" "$BATS_TEST_DIRNAME/action-items-write-retro-interop.bats"
}
