#!/usr/bin/env bats
# infer-parent-epic.bats — E89-S3 deterministic parent-epic inference.
#
# Covers TC-AFE-9..12.

load 'test_helper.bash'

setup() {
  common_setup
  HELPER="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts/lib" && pwd)/infer-parent-epic.sh"
  export HELPER

  FIXTURE_EPICS="$TEST_TMP/epics.md"
  cat > "$FIXTURE_EPICS" <<'EOF'
# Epics & Stories Fixture

## E63: gaia-create-story Hardening Bundle

**Status:** open

Touches gaia-create-story, gaia-validate-story.

## E70: Mobile Test Framework

**Status:** open

Touches gaia-test-strategy, gaia-test-framework.

## E80: Closed Epic

**Status: closed**

Touches gaia-create-story.

## E89: gaia-add-feature ergonomics

**Status:** open

Touches gaia-add-feature, gaia-create-story.
EOF
  export FIXTURE_EPICS
}

teardown() {
  common_teardown
}

# ---------------- TC-AFE-9: single match -> deterministic ----------------
@test "single-match -> 'deterministic <epic_key>'" {
  run "$HELPER" --affected-skills gaia-test-strategy --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == "deterministic E70" ]]
}

# ---------------- TC-AFE-10: two matches -> ambiguous ----------------
@test "two-match -> 'ambiguous: E63,E89' (closed epic E80 excluded)" {
  run "$HELPER" --affected-skills gaia-create-story --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == ambiguous:* ]]
  [[ "$output" == *"E63"* ]]
  [[ "$output" == *"E89"* ]]
  # E80 is closed; MUST NOT appear in output.
  [[ "$output" != *"E80"* ]]
}

# ---------------- TC-AFE-11: zero matches -> no-match ----------------
@test "no-match for nonexistent skill" {
  run "$HELPER" --affected-skills gaia-nonexistent-skill --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == "no-match" ]]
}

# ---------------- TC-AFE-12: empty affected-skills -> no-match ----------------
@test "empty --affected-skills value -> no-match" {
  run "$HELPER" --affected-skills "" --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == "no-match" ]]
}

@test "affected-skills flag omitted entirely -> no-match" {
  run "$HELPER" --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == "no-match" ]]
}

# ---------------- TC-AFE-13: missing epics file -> no-match (advisory) ----------------
@test "missing epics-file -> no-match (advisory contract)" {
  run "$HELPER" --affected-skills gaia-create-story --epics-file "$TEST_TMP/nonexistent.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "no-match" ]]
}

# ---------------- TC-AFE-14: multi-skill list -> any match wins ----------------
@test "comma-separated skills — any match counts the epic" {
  run "$HELPER" --affected-skills "gaia-test-framework,gaia-nonexistent" --epics-file "$FIXTURE_EPICS"
  [ "$status" -eq 0 ]
  [[ "$output" == "deterministic E70" ]]
}
