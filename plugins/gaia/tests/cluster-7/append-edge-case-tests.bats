#!/usr/bin/env bats
# append-edge-case-tests.bats — E63-S8 / Work Item 6.8
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/append-edge-case-tests.sh.
#
# Test scenarios trace 1:1 to the story Test Scenarios table:
#   #1  Within-batch dedup on identical scenario        (AC1)
#   #2  Cross-run dedup against existing row            (AC1)
#   #3  Strictly increasing TC IDs with gap             (AC2)
#   #4  Missing test-plan.md, non-blocking              (AC3)
#   #5  Missing story section, append-and-create       (AC4)
#   #6  Empty edge-cases array                          (no-op)
#   #7  Malformed JSON                                  (script-level guard)
#   #8  Idempotent re-run                               (AC1 over runs)
#   #9  Cross-section isolation (TC-IDs scoped)         (AC2 scope)
#   #10 Heading depth match for new section             (AC4)
#   #11 Default severity injection                      (medium fallback)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/append-edge-case-tests.sh"
  FIX_DIR="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# Portable sha256 helper for byte-identity assertions.
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}

# Helper: extract TC rows for a target story section.
_extract_tc_rows() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^##\\??\\? *"key"([[:space:]]|$)" { in_sec = 1; next }
    in_sec && /^##\??\? / { in_sec = 0 }
    in_sec && /^\| TC-/ { print }
  ' "$file"
}

# Simpler helper using a flag + heading regex.
_rows_for_key() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_sec = 0 }
    /^##+ / {
      # Strip leading hashes + space; compare heading text.
      heading = $0
      sub(/^##+[[:space:]]+/, "", heading)
      if (heading == key) { in_sec = 1; next }
      if (in_sec) { in_sec = 0 }
    }
    in_sec && /^\| TC-[0-9]+ \|/ { print }
  ' "$file"
}

# ---------------------------------------------------------------------------
# AC1 — within-batch dedup on identical scenario
# ---------------------------------------------------------------------------

@test "AC1: within-batch dedup -> exit 0, stdout '1', one new row appended (Scenario 1)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"

  edge_cases='[
    {"id":"1","scenario":"new dup scenario","input":"i1","expected":"e1","category":"x","severity":"medium"},
    {"id":"2","scenario":"new dup scenario","input":"i2","expected":"e2","category":"x","severity":"medium"}
  ]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # Section now has exactly 4 TC rows (3 pre-existing + 1 new).
  rows="$(_rows_for_key "$TEST_TMP/test-plan.md" "E99-S1" | wc -l | tr -d ' ')"
  [ "$rows" = "4" ]
}

# ---------------------------------------------------------------------------
# AC1 — cross-run dedup against existing row
# ---------------------------------------------------------------------------

@test "AC1: cross-run dedup against existing scenario -> stdout '2', skip 1 (Scenario 2)" {
  cp "$FIX_DIR/test-plan-with-duplicate-scenario.md" "$TEST_TMP/test-plan.md"

  edge_cases='[
    {"id":"1","scenario":"empty input handled","input":"i1","expected":"e1","category":"input"},
    {"id":"2","scenario":"oversized input rejected","input":"10MB","expected":"413","category":"boundary"},
    {"id":"3","scenario":"unicode in name","input":"emoji","expected":"saved","category":"i18n"}
  ]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  # Verify the duplicate scenario only appears once in the section.
  dup_count="$(_rows_for_key "$TEST_TMP/test-plan.md" "E99-S1" | grep -c 'empty input handled' || true)"
  [ "$dup_count" = "1" ]
}

# ---------------------------------------------------------------------------
# AC2 — strictly increasing TC IDs with gap (no backfill)
# ---------------------------------------------------------------------------

@test "AC2: strictly increasing TC IDs, gap not backfilled (Scenario 3)" {
  cp "$FIX_DIR/test-plan-with-gap.md" "$TEST_TMP/test-plan.md"

  edge_cases='[
    {"id":"1","scenario":"new scenario alpha","input":"a","expected":"x","category":"x"},
    {"id":"2","scenario":"new scenario beta","input":"b","expected":"y","category":"x"}
  ]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  # TC-3..TC-6 were never present and remain absent.
  ! grep -q '^| TC-3 |' "$TEST_TMP/test-plan.md"
  ! grep -q '^| TC-4 |' "$TEST_TMP/test-plan.md"
  ! grep -q '^| TC-5 |' "$TEST_TMP/test-plan.md"
  ! grep -q '^| TC-6 |' "$TEST_TMP/test-plan.md"

  # New rows are TC-8 and TC-9.
  grep -q '^| TC-8 | new scenario alpha' "$TEST_TMP/test-plan.md"
  grep -q '^| TC-9 | new scenario beta' "$TEST_TMP/test-plan.md"
}

# ---------------------------------------------------------------------------
# AC3 — missing test-plan.md (non-blocking)
# ---------------------------------------------------------------------------

@test "AC3: missing test-plan -> exit 0, stderr WARNING, no file created (Scenario 4)" {
  missing_path="$TEST_TMP/does/not/exist.md"
  run bash -c "'$SCRIPT' --test-plan '$missing_path' --story-key 'E99-S1' --edge-cases '[]' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"test-plan.md not found"* ]]
  [ ! -e "$missing_path" ]
}

# ---------------------------------------------------------------------------
# AC4 — missing story section, append-and-create
# ---------------------------------------------------------------------------

@test "AC4: missing section -> append new section at EOF with header + rows (Scenario 5)" {
  cp "$FIX_DIR/test-plan-no-target-section.md" "$TEST_TMP/test-plan.md"

  edge_cases='[
    {"id":"1","scenario":"alpha","input":"a","expected":"x","category":"x"},
    {"id":"2","scenario":"beta","input":"b","expected":"y","category":"x"}
  ]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  # New `## E99-S1` heading exists at EOF.
  grep -q '^## E99-S1$' "$TEST_TMP/test-plan.md"

  # Column header + alignment row appear after the heading.
  grep -q '^| TC ID | Scenario | Type | Severity | Story Key |$' "$TEST_TMP/test-plan.md"
  grep -q '^|-------|----------|------|----------|-----------|$' "$TEST_TMP/test-plan.md"

  # New rows numbered from TC-1.
  grep -q '^| TC-1 | alpha | edge-case | medium | E99-S1 |$' "$TEST_TMP/test-plan.md"
  grep -q '^| TC-2 | beta | edge-case | medium | E99-S1 |$' "$TEST_TMP/test-plan.md"
}

# ---------------------------------------------------------------------------
# Empty edge-cases array — no-op
# ---------------------------------------------------------------------------

@test "Empty edge-cases array -> exit 0, stdout '0', byte-identical (Scenario 6)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  pre_hash="$(_sha256 "$TEST_TMP/test-plan.md")"

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  post_hash="$(_sha256 "$TEST_TMP/test-plan.md")"
  [ "$pre_hash" = "$post_hash" ]
}

# ---------------------------------------------------------------------------
# Malformed JSON
# ---------------------------------------------------------------------------

@test "Malformed JSON -> non-zero, file unchanged (Scenario 7)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  pre_hash="$(_sha256 "$TEST_TMP/test-plan.md")"

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases 'not-json'
  [ "$status" -ne 0 ]

  post_hash="$(_sha256 "$TEST_TMP/test-plan.md")"
  [ "$pre_hash" = "$post_hash" ]
}

@test "Non-array JSON -> non-zero, file unchanged" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  pre_hash="$(_sha256 "$TEST_TMP/test-plan.md")"

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases '{"not":"array"}'
  [ "$status" -ne 0 ]

  post_hash="$(_sha256 "$TEST_TMP/test-plan.md")"
  [ "$pre_hash" = "$post_hash" ]
}

# ---------------------------------------------------------------------------
# Idempotent re-run
# ---------------------------------------------------------------------------

@test "Idempotent: second run with same input -> stdout '0', byte-identical (Scenario 8)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"

  edge_cases='[
    {"id":"1","scenario":"alpha","input":"a","expected":"x","category":"x"},
    {"id":"2","scenario":"beta","input":"b","expected":"y","category":"x"},
    {"id":"3","scenario":"gamma","input":"c","expected":"z","category":"x"}
  ]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  post1_hash="$(_sha256 "$TEST_TMP/test-plan.md")"

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  post2_hash="$(_sha256 "$TEST_TMP/test-plan.md")"
  [ "$post1_hash" = "$post2_hash" ]
}

# ---------------------------------------------------------------------------
# Cross-section isolation (TC-IDs scoped to target story's section)
# ---------------------------------------------------------------------------

@test "Cross-section isolation: TC-99 in another section does not shift target (Scenario 9)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"

  edge_cases='[{"id":"1","scenario":"alpha","input":"a","expected":"x","category":"x"}]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # Target section's max was TC-3, so new row is TC-4 (NOT TC-100).
  grep -q '^| TC-4 | alpha |' "$TEST_TMP/test-plan.md"
  ! grep -q '^| TC-100 |' "$TEST_TMP/test-plan.md"

  # E99-S2 section's TC-99 row is untouched.
  grep -q '^| TC-99 | other story scenario | unit | medium | E99-S2 |$' "$TEST_TMP/test-plan.md"
}

# ---------------------------------------------------------------------------
# Heading depth match for new section
# ---------------------------------------------------------------------------

@test "Heading depth match: file uses '### ' for stories -> new section uses '### ' (Scenario 10)" {
  cp "$FIX_DIR/test-plan-h3-style.md" "$TEST_TMP/test-plan.md"

  edge_cases='[{"id":"1","scenario":"alpha","input":"a","expected":"x","category":"x"}]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # New section heading uses `### ` to match existing depth.
  grep -q '^### E99-S1$' "$TEST_TMP/test-plan.md"
  ! grep -q '^## E99-S1$' "$TEST_TMP/test-plan.md"
}

# ---------------------------------------------------------------------------
# Default severity injection (medium fallback)
# ---------------------------------------------------------------------------

@test "Default severity: entry omitting severity -> 'medium' in row (Scenario 11)" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"

  edge_cases='[{"id":"1","scenario":"no severity here","input":"a","expected":"x","category":"x"}]'

  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  grep -q '^| TC-4 | no severity here | edge-case | medium | E99-S1 |$' "$TEST_TMP/test-plan.md"
}

# ---------------------------------------------------------------------------
# Script header invariants & shellcheck cleanliness
# ---------------------------------------------------------------------------

@test "Header: shebang, set -euo pipefail, LC_ALL=C, executable" {
  head1="$(head -n 1 "$SCRIPT")"
  [ "$head1" = "#!/usr/bin/env bash" ]
  grep -q 'set -euo pipefail' "$SCRIPT"
  grep -q 'LC_ALL=C' "$SCRIPT"
  [ -x "$SCRIPT" ]
}

@test "shellcheck: clean (warning-or-better)" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --severity=warning "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Help: --help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--test-plan"* ]]
  [[ "$output" == *"--story-key"* ]]
  [[ "$output" == *"--edge-cases"* ]]
}

@test "Unknown flag -> non-zero with usage" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1" --bogus value --edge-cases '[]'
  [ "$status" -ne 0 ]
}

@test "Missing --test-plan flag -> non-zero" {
  run "$SCRIPT" --story-key "E99-S1" --edge-cases '[]'
  [ "$status" -ne 0 ]
}

@test "Missing --story-key flag -> non-zero" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --edge-cases '[]'
  [ "$status" -ne 0 ]
}

@test "Missing --edge-cases flag -> non-zero" {
  cp "$FIX_DIR/test-plan-with-section.md" "$TEST_TMP/test-plan.md"
  run "$SCRIPT" --test-plan "$TEST_TMP/test-plan.md" --story-key "E99-S1"
  [ "$status" -ne 0 ]
}
