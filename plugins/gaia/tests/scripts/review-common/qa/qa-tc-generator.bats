#!/usr/bin/env bats
# qa-tc-generator.bats — E67-S8 deterministic boilerplate-TC generator coverage.
#
# Validates `review-common/qa-tc-generator.sh`:
#   AC1 — N-AC happy path: N ACs in the story produce N TC scaffolds (1:1).
#   AC2 — idempotent re-run: subsequent runs do not duplicate entries.
#   AC3 — bats coverage of (a) happy path, (b) idempotent re-run, (c) malformed frontmatter.
#
# Refs: E67-S8 AC1, AC2, AC3.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  GENERATOR="${REVIEW_COMMON_DIR}/qa-tc-generator.sh"
  SCHEMA="${SCHEMAS_DIR}/qa-test-cases.schema.json"
  STORY_FILE="${TEST_TMP}/story-E99-S1.md"
  OUTPUT="${TEST_TMP}/qa-test-cases-E99-S1.json"
}
teardown() { common_teardown; }

write_story_with_n_acs() {
  local n="$1"
  local key="${2:-E99-S1}"
  {
    printf -- '---\n'
    printf -- 'key: "%s"\n' "$key"
    printf -- 'title: "Sample story"\n'
    printf -- 'status: in-progress\n'
    printf -- '---\n\n'
    printf -- '## Acceptance Criteria\n\n'
    local i
    for i in $(seq 1 "$n"); do
      printf -- '- **AC%d:** Given input %d, when action %d, then outcome %d.\n' "$i" "$i" "$i" "$i"
    done
    printf -- '\n## Tasks / Subtasks\n\n- [ ] T1: do the thing\n'
  } > "$STORY_FILE"
}

write_story_no_key() {
  {
    printf -- '---\n'
    printf -- 'title: "Story without key"\n'
    printf -- 'status: in-progress\n'
    printf -- '---\n\n'
    printf -- '## Acceptance Criteria\n\n'
    printf -- '- **AC1:** Given a, when b, then c.\n'
  } > "$STORY_FILE"
}

@test "generator script exists and is executable" {
  [ -x "$GENERATOR" ]
}

@test "AC1: N-AC story produces N TC scaffolds with 1:1 mapping" {
  write_story_with_n_acs 4 "E99-S1"

  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT" ]

  # Array length matches N.
  run jq 'length' "$OUTPUT"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]

  # Each entry's tc_id is TC-E99-S1-{N} and ac_ref is AC{N}.
  for i in 1 2 3 4; do
    run jq -r --arg i "$i" '.[$i|tonumber - 1] | .tc_id + "|" + .ac_ref' "$OUTPUT"
    [ "$status" -eq 0 ]
    [ "$output" = "TC-E99-S1-${i}|AC${i}" ]
  done
}

@test "AC1: emitted entries default type to Unit" {
  write_story_with_n_acs 2 "E99-S1"
  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]
  run jq -r '.[0].type, .[1].type' "$OUTPUT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^Unit$'
  printf '%s\n' "$output" | grep -vq 'null'
}

@test "AC1: emitted JSON validates against the schema (when ajv installed)" {
  command -v ajv >/dev/null 2>&1 || skip "ajv-cli not installed"
  write_story_with_n_acs 3 "E99-S1"
  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]
  ajv validate -s "$SCHEMA" -d "$OUTPUT"
}

@test "AC2/AC3b: idempotent re-run does not duplicate entries" {
  write_story_with_n_acs 3 "E99-S1"

  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]
  local first_hash
  first_hash="$(jq -S '.' "$OUTPUT" | shasum -a 256 | awk '{print $1}')"

  # Second run, same inputs.
  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]

  local second_hash
  second_hash="$(jq -S '.' "$OUTPUT" | shasum -a 256 | awk '{print $1}')"
  [ "$first_hash" = "$second_hash" ]

  run jq 'length' "$OUTPUT"
  [ "$output" = "3" ]
}

@test "AC2: partial existing file appends only missing ACs (dedup by ac_ref)" {
  write_story_with_n_acs 3 "E99-S1"

  # Seed output with only AC1.
  cat > "$OUTPUT" <<'EOF'
[
  {
    "tc_id": "TC-E99-S1-1",
    "ac_ref": "AC1",
    "description": "preexisting AC1 entry",
    "given": "g", "when": "w", "then": "t",
    "type": "Unit"
  }
]
EOF

  run "$GENERATOR" --story "$STORY_FILE" --output "$OUTPUT"
  [ "$status" -eq 0 ]

  # Expect 3 entries total.
  run jq 'length' "$OUTPUT"
  [ "$output" = "3" ]

  # AC1 preexisting entry preserved (description unchanged).
  run jq -r '.[] | select(.ac_ref=="AC1") | .description' "$OUTPUT"
  [ "$output" = "preexisting AC1 entry" ]

  # AC2 and AC3 added.
  run jq -r '[.[].ac_ref] | sort | join(",")' "$OUTPUT"
  [ "$output" = "AC1,AC2,AC3" ]

  # New tc_ids continue from N+1.
  run jq -r '.[] | select(.ac_ref=="AC2") | .tc_id' "$OUTPUT"
  [ "$output" = "TC-E99-S1-2" ]
  run jq -r '.[] | select(.ac_ref=="AC3") | .tc_id' "$OUTPUT"
  [ "$output" = "TC-E99-S1-3" ]
}

@test "AC3c: malformed frontmatter (missing key:) rejected with exit 2" {
  write_story_no_key
  # Combine stderr into stdout so we can inspect the diagnostic.
  run bash -c '"$1" --story "$2" --output "$3" 2>&1' _ "$GENERATOR" "$STORY_FILE" "$OUTPUT"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'missing key:'
}

@test "missing --story flag returns exit 2 with usage message" {
  run "$GENERATOR" --output "$OUTPUT"
  [ "$status" -eq 2 ]
}

@test "missing --output flag returns exit 2" {
  write_story_with_n_acs 1 "E99-S1"
  run "$GENERATOR" --story "$STORY_FILE"
  [ "$status" -eq 2 ]
}

@test "nonexistent story file returns exit 2" {
  run "$GENERATOR" --story "${TEST_TMP}/does-not-exist.md" --output "$OUTPUT"
  [ "$status" -eq 2 ]
}
