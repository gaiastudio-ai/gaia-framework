#!/usr/bin/env bats
# atdd-gate.bats — coverage for skills/gaia-dev-story/scripts/atdd-gate.sh
#
# Exercises the full risk matrix for the dev-story Step 2b ATDD gate:
#   - medium / low / unset risk: pass unconditionally
#   - high risk + exact flat atdd-{key}.md present: pass
#   - high risk + exact flat atdd-{epic}.md present: pass (epic-level)
#   - high risk + nested per-story atdd.md present: pass (resolver)
#   - high risk + suffix-named flat file present: HALT (exact match only)
#   - high risk + sibling flat file present: HALT (no false-pass)
#   - high risk + no ATDD file: HALT (exit 1) with expected paths
#   - invalid story_key shape: usage error (exit 2)
#   - missing story file: usage error (exit 2)

load 'test_helper.bash'

setup_file() {
  _litter_snapshot_before
  printf 'BASH_VERSION=%s\n' "$BASH_VERSION" >&3
}

setup() {
  common_setup
  ATDD_GATE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/atdd-gate.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts docs/test-artifacts
  export PROJECT_PATH="$TEST_TMP"
}

teardown() { common_teardown; }

_write_story() {
  local key="$1" risk="$2"
  cat > "docs/implementation-artifacts/${key}-test.md" <<EOF
---
key: "$key"
risk: "$risk"
status: in-progress
---

# Story: Test
EOF
}

# ---------------------------------------------------------------------------
# Non-high risk
# ---------------------------------------------------------------------------

@test "atdd-gate: medium risk passes with no ATDD file" {
  _write_story "E10-S1" "medium"
  run "$ATDD_GATE" "E10-S1"
  [ "$status" -eq 0 ]
}

@test "atdd-gate: low risk passes with no ATDD file" {
  _write_story "E10-S2" "low"
  run "$ATDD_GATE" "E10-S2"
  [ "$status" -eq 0 ]
}

@test "atdd-gate: unset risk passes with no ATDD file" {
  cat > "docs/implementation-artifacts/E10-S3-test.md" <<'EOF'
---
key: "E10-S3"
status: in-progress
---

# Story: Test
EOF
  run "$ATDD_GATE" "E10-S3"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — suffix-named flat files must NOT satisfy the gate (exact match)
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk rejects suffix-named epic ATDD file" {
  _write_story "E20-S5" "high"
  : > "docs/test-artifacts/atdd-E20-coverage.md"
  run "$ATDD_GATE" "E20-S5"
  [ "$status" -eq 1 ] \
    || { echo "suffix-named epic file should not satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

@test "atdd-gate: high risk rejects suffix-named story ATDD file" {
  _write_story "E20-S6" "high"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  : > "docs/test-artifacts/atdd-E20-S6-scenarios.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run "$ATDD_GATE" "E20-S6"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 1 ] \
    || { echo "suffix-named story file should not satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

# ---------------------------------------------------------------------------
# High risk — exact flat atdd-{key}.md present: pass (backward compat)
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when exact flat atdd-{key}.md is present" {
  _write_story "E20-S5" "high"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  : > "docs/test-artifacts/atdd-E20-S5.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run "$ATDD_GATE" "E20-S5"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — exact flat atdd-{epic}.md present: pass (epic-level shared)
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when exact flat atdd-{epic}.md is present" {
  _write_story "E20-S9" "high"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  : > "docs/test-artifacts/atdd-E20.md"
  run "$ATDD_GATE" "E20-S9"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — present at the canonical NESTED per-story home
# The resolver writes test-artifacts/epic-{EPIC}/{KEY}/atdd.md;
# the gate must accept it, not only the legacy flat paths.
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk passes when nested per-story atdd.md is present" {
  _write_story "E20-S7" "high"
  # The resolver's nested home for a story with no per-story dir is
  # test-artifacts/epic-{EPIC}/{KEY}/atdd.md (stories/ level dropped).
  # Create it where /gaia-atdd would write.
  mkdir -p "docs/test-artifacts/epic-E20/E20-S7"
  : > "docs/test-artifacts/epic-E20/E20-S7/atdd.md"
  # No flat atdd-E20-S7*.md exists — only the nested file.
  run "$ATDD_GATE" "E20-S7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "epic-E20/E20-S7/atdd.md"
}

@test "atdd-gate: high risk passes when nested atdd.md under stories/ legacy level is present" {
  _write_story "E20-S8" "high"
  # Legacy nested form with the stories/ middle level (read-compat fallback).
  mkdir -p "docs/test-artifacts/epic-E20/stories/E20-S8"
  : > "docs/test-artifacts/epic-E20/stories/E20-S8/atdd.md"
  run "$ATDD_GATE" "E20-S8"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# High risk — sibling false-pass blocked (key-prefix boundary)
# ---------------------------------------------------------------------------

@test "atdd-gate: sibling flat file does not false-pass for another story" {
  _write_story "E20-S5" "high"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  # Sibling E20-S50 has a flat ATDD file; E20-S5 has none.  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  : > "docs/test-artifacts/atdd-E20-S50.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  run "$ATDD_GATE" "E20-S5"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 1 ] \
    || { echo "sibling file should not satisfy the gate, got exit $status" >&2; echo "$output" >&2; false; }
}

@test "atdd-gate: key-prefix boundary prevents sibling from satisfying another story" {
  _write_story "E20-S5" "high"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  # Both a sibling's flat file and an epic-suffixed file present — neither exact.
  : > "docs/test-artifacts/atdd-E20-S50.md"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  : > "docs/test-artifacts/atdd-E20-coverage.md"
  run "$ATDD_GATE" "E20-S5"  # lint-pack:allow leaked-identifiers — synthetic fixture story key
  [ "$status" -eq 1 ] \
    || { echo "key-prefix boundary violated, got exit $status" >&2; echo "$output" >&2; false; }
}

# ---------------------------------------------------------------------------
# High risk — missing -> HALT
# ---------------------------------------------------------------------------

@test "atdd-gate: high risk with no ATDD file HALTs (exit 1) and names expected paths" {
  _write_story "E30-S1" "high"
  run "$ATDD_GATE" "E30-S1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HALT"* ]]
  [[ "$output" == *"atdd-E30"* ]]
  [[ "$output" == *"atdd-E30-S1"* ]]
  # HALT text must not contain residual glob syntax
  [[ "$output" != *'*'* ]] \
    || { echo "HALT message should not contain glob wildcards, got:" >&2; echo "$output" >&2; false; }
}

# ---------------------------------------------------------------------------
# Usage errors — exit 2
# ---------------------------------------------------------------------------

@test "atdd-gate: invalid story_key shape -> usage error (exit 2)" {
  run "$ATDD_GATE" "not-a-story"
  [ "$status" -eq 2 ]
}

@test "atdd-gate: missing story file -> usage error (exit 2)" {
  run "$ATDD_GATE" "E99-S99"
  [ "$status" -eq 2 ]
}

@test "atdd-gate: no args -> usage error (exit 2)" {
  run "$ATDD_GATE"
  [ "$status" -eq 2 ]
}
