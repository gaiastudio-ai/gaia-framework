#!/usr/bin/env bats
# lifecycle-markers.bats — gaia-meeting seven-phase lifecycle markers (E76-S1)
#
# AC3 / TC-MTG-CHARTER-3: saved transcript contains phase markers in order

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/lifecycle-marker.sh"
}

@test "Pre-flight: lifecycle-marker.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC3: lifecycle-marker emits the marker for each phase" {
  for phase in INVITE CHARTER RESEARCH DISCUSS CLOSE REVIEW SAVE; do
    run "$HELPER" --phase "$phase"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$phase"* ]]
  done
}

@test "AC3: lifecycle-marker rejects unknown phases" {
  [ -x "$HELPER" ]
  run "$HELPER" --phase BOGUS
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC3: SKILL.md documents all seven phases in order" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  [ -f "$SKILL_FILE" ]
  # Find first occurrence of each phase as an "### Phase N — <PHASE>" Procedure
  # heading. This scopes the AC3 check to the canonical Procedure ordering
  # and avoids matching the frontmatter description line which lists them all.
  invite_line=$(grep -n -m1 "^### Phase 1 — INVITE" "$SKILL_FILE" | cut -d: -f1)
  charter_line=$(grep -n -m1 "^### Phase 2 — CHARTER" "$SKILL_FILE" | cut -d: -f1)
  research_line=$(grep -n -m1 "^### Phase 3 — RESEARCH" "$SKILL_FILE" | cut -d: -f1)
  discuss_line=$(grep -n -m1 "^### Phase 4 — DISCUSS" "$SKILL_FILE" | cut -d: -f1)
  close_line=$(grep -n -m1 "^### Phase 5 — CLOSE" "$SKILL_FILE" | cut -d: -f1)
  review_line=$(grep -n -m1 "^### Phase 6 — REVIEW" "$SKILL_FILE" | cut -d: -f1)
  save_line=$(grep -n -m1 "^### Phase 7 — SAVE" "$SKILL_FILE" | cut -d: -f1)
  [ -n "$invite_line" ]
  [ -n "$charter_line" ]
  [ -n "$research_line" ]
  [ -n "$discuss_line" ]
  [ -n "$close_line" ]
  [ -n "$review_line" ]
  [ -n "$save_line" ]
  [ "$invite_line" -lt "$charter_line" ]
  [ "$charter_line" -lt "$research_line" ]
  [ "$research_line" -lt "$discuss_line" ]
  [ "$discuss_line" -lt "$close_line" ]
  [ "$close_line" -lt "$review_line" ]
  [ "$review_line" -lt "$save_line" ]
}

@test "AC3: SKILL.md notes RESEARCH is a skip placeholder in S1" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/SKILL.md"
  grep -qiE "research.*(skip|placeholder|no-op|S2)" "$SKILL_FILE"
}
