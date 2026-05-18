#!/usr/bin/env bats
# e40-s3-hotfix-priority-flag.bats — coverage for the "hotfix" priority_flag enum value
#
# Story: E40-S3 — Add hotfix value to priority_flag enum and active-sprint injection
# Traces: AC1, AC2, AC3, AC4(a-f), AC5
# Origin: docs/creative-artifacts/meeting-2026-05-15-ci-review-section-deploy-versioning-redesign.md
#
# Validates: the new `pflag_scan_active_hotfix` function in priority-flag.sh,
# the shared `_pflag_scan_by_flag` helper, and validate-frontmatter.sh's new
# check_enum call for priority_flag.

load 'test_helper.bash'

setup() {
  common_setup
  PRIORITY_FLAG_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/priority-flag.sh"
  VALIDATE_FM_SH="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-create-story/scripts" && pwd)/validate-frontmatter.sh"
}

teardown() { common_teardown; }

# Load priority-flag.sh helper functions into the bats process.
_load_pflag_helpers() {
  local tmp
  tmp="$(mktemp -t pflag-helpers.XXXXXX)"
  printf 'SCRIPT_NAME="priority-flag.sh"\n' > "$tmp"
  awk '
    /^_pflag_fm_field\(\) \{/,/^\}/ { print; next }
    /^pflag_read\(\) \{/,/^\}/ { print; next }
    /^_pflag_scan_by_flag\(\) \{/,/^\}/ { print; next }
    /^pflag_scan_backlog\(\) \{/,/^\}/ { print; next }
    /^pflag_scan_active_hotfix\(\) \{/,/^\}/ { print; next }
  ' "$PRIORITY_FLAG_SH" >> "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# Fixture builder — write a story file with given key, status, and flag.
# Uses canonical filename '<key>-test-story.md' (matches title "test story"
# per validate-canonical-filename.sh) and includes a minimal Review Gate
# section so validate-frontmatter.sh passes when only the frontmatter is
# under test.
_make_flagged_story() {
  local dir="$1" key="$2" status="$3" flag="$4"
  local file="${dir}/${key}-test-story.md"
  mkdir -p "$dir"
  cat > "$file" <<EOF
---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "${key}"
title: "test story"
epic: "E0 — test"
status: ${status}
priority: "P1"
size: "S"
points: 3
risk: "low"
sprint_id: null
priority_flag: ${flag}
delivered: true
depends_on: []
blocks: []
traces_to: []
date: "2026-05-18"
author: "Test"
---

# Story: test story

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
EOF
  printf '%s' "$file"
}

# ============================================================================
# AC4(a) — hotfix story creation validates clean via check_enum
# ============================================================================
@test "AC4a: validate-frontmatter accepts priority_flag: hotfix" {
  local dir="$TEST_TMP/impl"
  local file
  file="$(_make_flagged_story "$dir" "E1-S1" "backlog" '"hotfix"')"

  run bash "$VALIDATE_FM_SH" --file "$file"
  [ "$status" -eq 0 ]
}

# ============================================================================
# AC4(b) — pflag_scan_active_hotfix returns ALL hotfix stories regardless of status
# ============================================================================
@test "AC4b: pflag_scan_active_hotfix returns hotfix stories in backlog, in-progress, ready-for-dev" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E1-S1" "backlog"        '"hotfix"' > /dev/null
  _make_flagged_story "$dir" "E1-S2" "in-progress"    '"hotfix"' > /dev/null
  _make_flagged_story "$dir" "E1-S3" "ready-for-dev"  '"hotfix"' > /dev/null
  _make_flagged_story "$dir" "E1-S4" "backlog"        '"next-sprint"' > /dev/null
  _make_flagged_story "$dir" "E1-S5" "backlog"        "null" > /dev/null

  local got
  got="$(pflag_scan_active_hotfix "$dir" | sort)"
  expected="$(printf 'E1-S1\nE1-S2\nE1-S3')"
  [ "$got" = "$expected" ]
}

# ============================================================================
# AC4(c) — pflag_scan_active_hotfix excludes non-hotfix stories
# ============================================================================
@test "AC4c: pflag_scan_active_hotfix excludes next-sprint and null flagged stories" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E2-S1" "backlog" '"next-sprint"' > /dev/null
  _make_flagged_story "$dir" "E2-S2" "backlog" "null" > /dev/null

  local got
  got="$(pflag_scan_active_hotfix "$dir")"
  [ -z "$got" ]
}

# ============================================================================
# AC4(d) — empty directory returns empty (no spurious matches)
# ============================================================================
@test "AC4d: pflag_scan_active_hotfix returns empty on empty directory" {
  _load_pflag_helpers
  local dir="$TEST_TMP/empty"
  mkdir -p "$dir"

  local got
  got="$(pflag_scan_active_hotfix "$dir")"
  [ -z "$got" ]
}

# ============================================================================
# AC4(e) — validate-frontmatter rejects invalid priority_flag values
# ============================================================================
@test "AC4e: validate-frontmatter rejects priority_flag: invalid-value" {
  local dir="$TEST_TMP/impl"
  local file
  file="$(_make_flagged_story "$dir" "E1-S1" "backlog" '"invalid-value"')"

  run bash "$VALIDATE_FM_SH" --file "$file"
  [ "$status" -ne 0 ]
  # Verify the error message mentions priority_flag.
  [[ "$output" =~ priority_flag ]]
}

# ============================================================================
# AC5 — anti-regression: pflag_scan_backlog still returns next-sprint stories
# (the existing E38-S4 contract is preserved bit-identical)
# ============================================================================
@test "AC5: pflag_scan_backlog still returns next-sprint backlog stories" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E3-S1" "backlog"     '"next-sprint"' > /dev/null
  _make_flagged_story "$dir" "E3-S2" "in-progress" '"next-sprint"' > /dev/null
  _make_flagged_story "$dir" "E3-S3" "backlog"     '"hotfix"' > /dev/null

  local got
  got="$(pflag_scan_backlog "$dir")"
  # Only E3-S1 (backlog + next-sprint) should match.
  [ "$got" = "E3-S1" ]
}

# ============================================================================
# AC5 extension — shared _pflag_scan_by_flag helper exists and parameterizes
# both status filter and flag value
# ============================================================================
@test "AC5: _pflag_scan_by_flag delegates correctly for arbitrary status/flag pairs" {
  _load_pflag_helpers
  local dir="$TEST_TMP/impl"
  mkdir -p "$dir"
  _make_flagged_story "$dir" "E4-S1" "review" '"hotfix"' > /dev/null
  _make_flagged_story "$dir" "E4-S2" "review" '"next-sprint"' > /dev/null

  # Direct invocation with explicit filter pair
  local got
  got="$(_pflag_scan_by_flag "$dir" "review" "hotfix")"
  [ "$got" = "E4-S1" ]
}
