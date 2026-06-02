#!/usr/bin/env bats
# append-edge-case-acs.bats — E63-S7 / Work Items 6.7 + 4
#
# Verifies the deterministic contract of
# gaia-public/plugins/gaia/skills/gaia-create-story/scripts/append-edge-case-acs.sh.
#
# Test scenarios trace 1:1 to the story Test Scenarios table:
#   #1  Clean append, hashes preserved              (AC1)
#   #2  Mutation-detected revert                    (AC2)
#   #3  Idempotent re-run dedup (3+3 -> 0 new)      (AC5)
#   #4  Idempotent with one new (3+4 -> 1 new)      (AC5)
#   #5  Missing target file (non-blocking)          (AC4)
#   #6  Empty edge-cases array (no-op)
#   #7  Malformed JSON                              (script-level guard)
#   #8  Mixed primary + existing AC-EC partition    (AC1, AC5)
#   #10 shellcheck cleanliness                      (Subtask 5.2)

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SKILLS_DIR/gaia-create-story/scripts/append-edge-case-acs.sh"
  FIX_DIR="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# Helper: portable sha256 — used by the tests for INDEPENDENT verification of
# the script's hash invariants. We deliberately do NOT reuse the script's
# internal hashing; the test computes its own hash so a script-side bug
# cannot mask itself.
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}

# Helper: extract primary AC lines (lines matching `^- \[ \] AC` and NOT
# matching `^- \[ \] AC-EC`) using awk state-machine on `## Acceptance
# Criteria` -> next `## ` heading.
_extract_primary_acs() {
  awk '
    /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
    /^## / && in_ac { in_ac = 0 }
    in_ac && /^- \[ \] AC/ && !/^- \[ \] AC-EC/ { print }
  ' "$1"
}

# Helper: extract AC-EC lines.
_extract_ec_acs() {
  awk '
    /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
    /^## / && in_ac { in_ac = 0 }
    in_ac && /^- \[ \] AC-EC/ { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# AC1 — clean append, primary AC bytes preserved
# ---------------------------------------------------------------------------

@test "AC1: clean append -> exit 0, stdout '3', primary ACs byte-identical (Scenario 1)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  pre_hash="$(_extract_primary_acs "$TEST_TMP/story.md" | _sha256 -)"

  edge_cases='[
    {"id":"1","scenario":"empty input handled","input":"empty payload","expected":"400 returned","category":"input","severity":"medium"},
    {"id":"2","scenario":"oversized input rejected","input":"10MB payload","expected":"413 returned","category":"boundary","severity":"medium"},
    {"id":"3","scenario":"unicode in name","input":"emoji name","expected":"saved verbatim","category":"i18n","severity":"low"}
  ]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  post_hash="$(_extract_primary_acs "$TEST_TMP/story.md" | _sha256 -)"
  [ "$pre_hash" = "$post_hash" ]
}

@test "AC1: appended AC-EC lines match canonical FR-229 row format" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  edge_cases='[{"id":"1","scenario":"foo","input":"bar","expected":"baz","category":"x"}]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]

  ec="$(_extract_ec_acs "$TEST_TMP/story.md")"
  [[ "$ec" == *"- [ ] AC-EC1: Given bar, when foo, then baz"* ]]
}

@test "AC1: AC-EC tail is appended after the last primary AC" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  edge_cases='[{"id":"1","scenario":"s1","input":"i1","expected":"e1","category":"x"}]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]

  # Last primary AC (AC3) appears before the first AC-EC line.
  ac3_line="$(grep -n '^- \[ \] AC3:' "$TEST_TMP/story.md" | awk -F: '{print $1}')"
  ec1_line="$(grep -n '^- \[ \] AC-EC1:' "$TEST_TMP/story.md" | awk -F: '{print $1}')"
  [ "$ac3_line" -lt "$ec1_line" ]

  # AC-EC tail is still inside the AC section (before the next `## ` heading).
  next_heading_line="$(grep -n '^## ' "$TEST_TMP/story.md" | awk -F: '$2 != ""' | tail -n 1 | awk -F: '{print $1}')"
  [ "$ec1_line" -lt "$next_heading_line" ]
}

# ---------------------------------------------------------------------------
# AC2 — mutation-detected revert
# ---------------------------------------------------------------------------

@test "AC2: mutated primary AC during append -> non-zero, file reverted (Scenario 2)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  pre_snapshot="$TEST_TMP/story.pre.md"
  cp "$TEST_TMP/story.md" "$pre_snapshot"

  edge_cases='[{"id":"1","scenario":"s","input":"i","expected":"e","category":"x"}]'

  # Fault injection: the script honors GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY=1
  # to mutate a primary AC AFTER pre-hashing but BEFORE post-hashing. This
  # simulates a parsing/regex bug in the appender.
  # bats `run` merges stderr into $output by default; we check $output.
  run env GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY=1 \
    "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases" 2>&1

  [ "$status" -ne 0 ]
  [[ "$output" == *"drift"* ]]

  # On-disk file MUST be byte-identical to the pre-append snapshot.
  cmp "$TEST_TMP/story.md" "$pre_snapshot"
}

@test "AC2: stderr names a primary AC line on drift" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  edge_cases='[{"id":"1","scenario":"s","input":"i","expected":"e","category":"x"}]'

  run env GAIA_APPEND_EC_FAULT_INJECT_MUTATE_PRIMARY=1 \
    "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases" 2>&1

  [ "$status" -ne 0 ]
  # Output should mention "AC" and a line/index reference.
  [[ "$output" == *"AC"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — idempotent re-run dedup
# ---------------------------------------------------------------------------

@test "AC5: idempotent re-run with identical edge cases -> 0 new appended (Scenario 3)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  edge_cases='[
    {"id":"1","scenario":"s1","input":"i1","expected":"e1","category":"x"},
    {"id":"2","scenario":"s2","input":"i2","expected":"e2","category":"x"},
    {"id":"3","scenario":"s3","input":"i3","expected":"e3","category":"x"}
  ]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  post1_hash="$(_sha256 "$TEST_TMP/story.md")"

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  post2_hash="$(_sha256 "$TEST_TMP/story.md")"
  [ "$post1_hash" = "$post2_hash" ]
}

@test "AC5: re-run with one new entry -> stdout '1' (Scenario 4)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  ec3='[
    {"id":"1","scenario":"s1","input":"i1","expected":"e1","category":"x"},
    {"id":"2","scenario":"s2","input":"i2","expected":"e2","category":"x"},
    {"id":"3","scenario":"s3","input":"i3","expected":"e3","category":"x"}
  ]'
  ec4='[
    {"id":"1","scenario":"s1","input":"i1","expected":"e1","category":"x"},
    {"id":"2","scenario":"s2","input":"i2","expected":"e2","category":"x"},
    {"id":"3","scenario":"s3","input":"i3","expected":"e3","category":"x"},
    {"id":"4","scenario":"s4-new","input":"i4","expected":"e4","category":"x"}
  ]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$ec3"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$ec4"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  ec_count="$(_extract_ec_acs "$TEST_TMP/story.md" | wc -l | tr -d ' ')"
  [ "$ec_count" = "4" ]
}

# ---------------------------------------------------------------------------
# AC4 — missing target file (non-blocking)
# ---------------------------------------------------------------------------

@test "AC4: missing target file -> exit 0, stderr WARNING, no file created (Scenario 5)" {
  missing_path="$TEST_TMP/does/not/exist.md"
  run bash -c "'$SCRIPT' --file '$missing_path' --edge-cases '[]' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"file not found"* ]]
  [ ! -e "$missing_path" ]
}

# ---------------------------------------------------------------------------
# Empty array — no-op
# ---------------------------------------------------------------------------

@test "Empty edge-cases array -> exit 0, stdout '0', file byte-identical (Scenario 6)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  pre_hash="$(_sha256 "$TEST_TMP/story.md")"

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  post_hash="$(_sha256 "$TEST_TMP/story.md")"
  [ "$pre_hash" = "$post_hash" ]
}

# ---------------------------------------------------------------------------
# Malformed JSON
# ---------------------------------------------------------------------------

@test "Malformed JSON -> non-zero, file unchanged (Scenario 7)" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  pre_hash="$(_sha256 "$TEST_TMP/story.md")"

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases 'not-json'
  [ "$status" -ne 0 ]

  post_hash="$(_sha256 "$TEST_TMP/story.md")"
  [ "$pre_hash" = "$post_hash" ]
}

@test "Non-array JSON -> non-zero, file unchanged" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  pre_hash="$(_sha256 "$TEST_TMP/story.md")"

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases '{"not":"an array"}'
  [ "$status" -ne 0 ]

  post_hash="$(_sha256 "$TEST_TMP/story.md")"
  [ "$pre_hash" = "$post_hash" ]
}

# ---------------------------------------------------------------------------
# Mixed primary + existing AC-EC partition
# ---------------------------------------------------------------------------

@test "Mixed primary + existing AC-EC -> primary preserved, existing EC kept, 1 new added (Scenario 8)" {
  cp "$FIX_DIR/story-ec-with-existing-ec.md" "$TEST_TMP/story.md"
  pre_primary_hash="$(_extract_primary_acs "$TEST_TMP/story.md" | _sha256 -)"

  edge_cases='[{"id":"3","scenario":"unicode in name","input":"emoji name","expected":"saved verbatim","category":"i18n"}]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # Primary AC bytes preserved.
  post_primary_hash="$(_extract_primary_acs "$TEST_TMP/story.md" | _sha256 -)"
  [ "$pre_primary_hash" = "$post_primary_hash" ]

  # Existing AC-EC entries preserved + 1 new = 3 total AC-EC entries.
  ec_count="$(_extract_ec_acs "$TEST_TMP/story.md" | wc -l | tr -d ' ')"
  [ "$ec_count" = "3" ]
}

@test "Existing AC-EC scenario string dedups even if input/expected differ" {
  cp "$FIX_DIR/story-ec-with-existing-ec.md" "$TEST_TMP/story.md"
  # Existing AC-EC1 scenario is "the user submits" (substring after `, when `,
  # before `, then`). The fixture line is:
  #   - [ ] AC-EC1: Given empty input, when the user submits, then a 400 is returned.
  edge_cases='[{"id":"99","scenario":"the user submits","input":"different input","expected":"different expected","category":"x"}]'

  run "$SCRIPT" --file "$TEST_TMP/story.md" --edge-cases "$edge_cases"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Script header invariants & shellcheck cleanliness
# ---------------------------------------------------------------------------

@test "Header: shebang, set -euo pipefail, LC_ALL=C, mode 0755" {
  head1="$(head -n 1 "$SCRIPT")"
  [ "$head1" = "#!/usr/bin/env bash" ]
  grep -q 'set -euo pipefail' "$SCRIPT"
  grep -q 'LC_ALL=C' "$SCRIPT"
  [ -x "$SCRIPT" ]
}

@test "shellcheck: clean (info-or-better)" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck --severity=warning "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Help: --help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--file"* ]]
  [[ "$output" == *"--edge-cases"* ]]
}

@test "Unknown flag -> non-zero with usage" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  run "$SCRIPT" --file "$TEST_TMP/story.md" --bogus value --edge-cases '[]'
  [ "$status" -ne 0 ]
}

@test "Missing --file flag -> non-zero" {
  run "$SCRIPT" --edge-cases '[]'
  [ "$status" -ne 0 ]
}

@test "Missing --edge-cases flag -> non-zero" {
  cp "$FIX_DIR/story-ec-three-primary.md" "$TEST_TMP/story.md"
  run "$SCRIPT" --file "$TEST_TMP/story.md"
  [ "$status" -ne 0 ]
}
