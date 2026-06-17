#!/usr/bin/env bats
# e39-s1-triage-guard-integration.bats
#
# Integration tests for E39-S1 (Done-story guard in triage-findings).
# Maps to TC-FITP-1, TC-FITP-2, TC-FITP-3 from test-plan.md §11.44.
#
# These tests exercise the CLI entry points of triage-guard.sh end-to-end,
# simulating the ADD TO EXISTING classification pathway that triage-findings
# SKILL.md now routes through the guard.
#
# CLI contract:
#   triage-guard.sh check <story_file>
#       exit 0 → proceed (status in [in-progress, review, ready-for-dev,
#                                    validating, backlog])
#       exit 2 → HALT with done-story guidance emitted on stdout
#       exit 1 → error (missing file, malformed frontmatter)
#
#   triage-guard.sh check --override --user <u> --date <d> --finding <fid> \
#       --reason <r> --report <path> <story_file>
#       exit 0 → override recorded; proceed
#       exit 1 → error (missing required flags, write failure)

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

TRIAGE_GUARD_SH="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/triage-guard.sh"

_make_story() {
  local dir="$1" key="$2" status="$3" sprint="${4:-sprint-26}"
  local file="${dir}/${key}-story.md"
  cat > "$file" <<EOF
---
template: 'story'
key: "${key}"
status: ${status}
sprint_id: "${sprint}"
---

# Story: ${key}
EOF
  printf '%s' "$file"
}

# ===========================================================================
# TC-FITP-1 — Done-story guard fires on ADD TO EXISTING against done story
# ===========================================================================

@test "guard halts on done target with guidance" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "done" "sprint-20")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "E1-S1"
  echo "$output" | grep -q "sprint-20"
  echo "$output" | grep -q "/gaia-create-story"
  echo "$output" | grep -q "/gaia-add-feature"
}

@test "guard emits retrospective-linkage sentence" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "done")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi "retro"
}

@test "guard performs NO mutation to story file on halt" {
  local file
  file="$(_make_story "$TEST_TMP" "E1-S1" "done")"
  local before_sha
  before_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 2 ]
  local after_sha
  after_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  [ "$before_sha" = "$after_sha" ]
}

# ===========================================================================
# TC-FITP-2 — Guard allows ADD TO EXISTING against in-progress or review
# ===========================================================================

@test "guard passes through in-progress target" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "in-progress")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 0 ]
}

@test "guard passes through review target" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "review")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 0 ]
}

@test "guard passes through ready-for-dev target" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "ready-for-dev")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 0 ]
}

@test "guard passes through backlog target" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "backlog")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 0 ]
}

@test "guard passes through validating target" {
  local file
  file="$(_make_story "$TEST_TMP" "E2-S1" "validating")"
  run "$TRIAGE_GUARD_SH" check "$file"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TC-FITP-3 — Guard override is recorded with flag in triage report
# ===========================================================================

@test "override flag bypasses guard and records entry" {
  local file
  file="$(_make_story "$TEST_TMP" "E3-S1" "done")"
  local report="$TEST_TMP/triage-report.md"
  run "$TRIAGE_GUARD_SH" check \
    --override \
    --user "julien" \
    --date "2026-04-22" \
    --finding "F-777" \
    --reason "urgent hotfix that cannot wait" \
    --report "$report" \
    "$file"
  [ "$status" -eq 0 ]
  [ -f "$report" ]
  grep -q "julien" "$report"
  grep -q "2026-04-22" "$report"
  grep -q "F-777" "$report"
  grep -q "E3-S1" "$report"
  grep -q "urgent hotfix that cannot wait" "$report"
  grep -q "retro_flag: true" "$report"
}

@test "override without --report flag fails" {
  local file
  file="$(_make_story "$TEST_TMP" "E3-S1" "done")"
  run "$TRIAGE_GUARD_SH" check \
    --override \
    --user "julien" \
    --date "2026-04-22" \
    --finding "F-777" \
    --reason "reason" \
    "$file"
  [ "$status" -ne 0 ]
}

@test "override still NO mutation to story file" {
  local file
  file="$(_make_story "$TEST_TMP" "E3-S1" "done")"
  local before_sha
  before_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  local report="$TEST_TMP/triage-report.md"
  run "$TRIAGE_GUARD_SH" check \
    --override \
    --user "julien" \
    --date "2026-04-22" \
    --finding "F-777" \
    --reason "urgent" \
    --report "$report" \
    "$file"
  [ "$status" -eq 0 ]
  local after_sha
  after_sha="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  [ "$before_sha" = "$after_sha" ]
}

# ===========================================================================
# Edge cases
# ===========================================================================

@test "guard: exits 1 on missing story file" {
  run "$TRIAGE_GUARD_SH" check "$TEST_TMP/does-not-exist.md"
  [ "$status" -eq 1 ]
}

@test "guard: usage on no arguments" {
  run "$TRIAGE_GUARD_SH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage"
}
