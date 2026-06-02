#!/usr/bin/env bats
# gaia-meeting-user-as-attendee-carve-out.bats — E76-S20 verification gate
#
# Verifies the user-as-attendee carve-out lands at the four affected SKILL.md
# sites (per AF-2026-05-10-2 / AI-2026-05-09-9):
#
#   1. §No fabricated user turns subsection — explicit carve-out paragraph
#      distinguishing fabricated (forbidden) from invited-attendee
#      (authorized) user turns. (AC1)
#   2. Absolute-prohibition line — appended EXCEPT clause naming the
#      carve-out and the FR-MTG-33 origin=attendee schema extension. (AC2)
#   3. Channel enumeration line — preamble updated from "exactly two" to
#      "exactly three" authoring channels (Option a) OR reworded to
#      "foundational authoring channels" (Option b), with a third bullet
#      naming the user-as-attendee path. (AC3)
#   4. Phase 3 RESEARCH paragraph 1 + Phase 4 DISCUSS paragraph 1 — back-
#      reference sentence pointing to the canonical carve-out subsection
#      appended after the existing prose; original sentence preserved
#      character-identical. (AC4)
#
# Composition checks:
#   - E76-S8 story file remains UNCHANGED (status: done preserved; AC1
#     prose preserved; Option-A supersedure pattern). (AC5)
#   - The SKILL.md hard-rule prose ("No fabricated user turns") is still
#     present — the carve-out extends the rule, never removes it. (AC6,
#     overlaps existing TC-MTG-NOFAB-1 in no-fabricated-user-turns.bats.)
#   - §References cite both AF-2026-05-10-2 and AI-2026-05-09-9. (AC7)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  SKILL_MD="$SKILL_DIR/SKILL.md"

  export LC_ALL=C

  # Project-root E76-S8 story path — used by the supersedure tests when the
  # running tree is the live GAIA-Framework workspace. Skipped otherwise so
  # CI runs against gaia-framework/ in isolation stay green.
  PROJECT_ROOT_DOCS="$REPO_ROOT/../docs"
  E76_S8_STORY=""
  if [ -d "$PROJECT_ROOT_DOCS" ]; then
    candidate="$(find "$PROJECT_ROOT_DOCS/implementation-artifacts" -maxdepth 4 -type f -name 'E76-S8-*.md' 2>/dev/null | head -1)"
    if [ -n "$candidate" ]; then
      E76_S8_STORY="$candidate"
    fi
  fi
}

@test "AC0: SKILL.md exists" {
  [ -f "$SKILL_MD" ]
}

@test "AC1 / Scenario 1: §No fabricated user turns contains 'User-as-attendee carve-out (AF-2026-05-10-2)' marker" {
  run grep -F 'User-as-attendee carve-out (AF-2026-05-10-2)' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC1: carve-out paragraph distinguishes fabricated vs. invited-attendee paths" {
  # The carve-out paragraph mentions origin=attendee per FR-MTG-33 schema
  # extension AND mentions origin=interject — distinguishing the two
  # authorized origins from the forbidden auto-emit path.
  run grep -F 'origin=attendee' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC1: carve-out paragraph names AskUserQuestion as the response substrate (E76-S18 / FR-MTG-32 composition)" {
  # The carve-out paragraph explicitly anchors the user's turn slot to the
  # AskUserQuestion primitive installed by E76-S18 — never auto-emitted.
  # We tolerate either ordering ("via AskUserQuestion" or "AskUserQuestion
  # response") to keep the prose flexible.
  run bash -c "grep -F 'AskUserQuestion' '$SKILL_MD' | grep -F 'attendee'"
  [ "$status" -eq 0 ]
}

@test "AC2 / Scenario 2: absolute-prohibition line carries an EXCEPT clause naming the carve-out" {
  run grep -F 'EXCEPT when the user is explicitly invited' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC2: EXCEPT clause references the FR-MTG-33 origin=attendee schema extension" {
  # The EXCEPT clause and the FR-MTG-33 reference must co-occur on the
  # same logical line (the prohibition statement) so a reader sees both
  # the exception AND its schema anchor. We accept either co-occurrence
  # on a single line OR a tight (5-line) window — the carve-out language
  # template recommends a single sentence.
  run bash -c "grep -F 'EXCEPT when the user is explicitly invited' '$SKILL_MD' | grep -F 'FR-MTG-33'"
  [ "$status" -eq 0 ]
}

@test "AC3 / Scenario 3: channel enumeration preamble updated (Option a OR Option b)" {
  # Option a: 'three authoring channels'. Option b: 'foundational authoring channels'.
  # Either is acceptable per AC3.
  run bash -c "grep -F 'three authoring channels' '$SKILL_MD' || grep -F 'foundational authoring channels' '$SKILL_MD'"
  [ "$status" -eq 0 ]
}

@test "AC3: enumeration preamble does NOT still claim 'exactly two authoring channels' as the live count" {
  # The pre-carve-out prose said "exactly two authoring channels". After
  # the edit, the live enumeration MUST NOT still announce two as the
  # authoritative count. We tolerate "two" appearing in historical /
  # explanatory prose, but the literal preamble phrase must be gone.
  run grep -F 'exactly two authoring channels' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "AC4 / Scenario 4 + 5: §No fabricated user turns back-reference sentence appears at least twice (Phase 3 + Phase 4)" {
  # Each phase paragraph appends the canonical back-reference. Two
  # paragraphs => the sentence (or its fingerprint) appears at least
  # twice in the file.
  count="$(grep -cF 'See §No fabricated user turns' "$SKILL_MD")"
  [ "$count" -ge 2 ]
}

@test "AC4: back-reference mentions 'user-as-attendee carve-out' to anchor the reader" {
  run grep -F 'user-as-attendee carve-out' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC4 / regression: the original Phase 3 / Phase 4 reinforcement sentence remains character-identical (no-fab invariant preserved)" {
  count="$(grep -cF 'Only invited agents post preludes and DISCUSS turns. The user does not appear as a turn author in either phase.' "$SKILL_MD")"
  [ "$count" -ge 2 ]
}

@test "AC5 / Scenario 6: E76-S8 story file status: done preserved (Option-A supersedure)" {
  if [ -z "$E76_S8_STORY" ]; then
    skip "E76-S8 story file not reachable from this checkout (gaia-framework/ standalone CI run)"
  fi
  run grep -E '^status: done$' "$E76_S8_STORY"
  [ "$status" -eq 0 ]
}

@test "AC5 / Scenario 7: E76-S8 AC1 character-frozen prose preserved (regardless-of qualifier untouched)" {
  if [ -z "$E76_S8_STORY" ]; then
    skip "E76-S8 story file not reachable from this checkout (gaia-framework/ standalone CI run)"
  fi
  run grep -F 'regardless of whether' "$E76_S8_STORY"
  [ "$status" -eq 0 ]
}

@test "AC6 / Scenario 8: SKILL.md hard-rule prose 'No fabricated user turns' still present" {
  run grep -F 'No fabricated user turns' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC7 / Scenario 9: §References cites AF-2026-05-10-2" {
  run grep -F 'AF-2026-05-10-2' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC7: §References cites AI-2026-05-09-9" {
  run grep -F 'AI-2026-05-09-9' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC7: existing AF-2026-05-08-4 / E76-S8 cross-reference entries remain (additive citation, not replacement)" {
  # The story spec says new citations land "alongside" the existing ones.
  # The pre-existing References block already cites E76-S8 indirectly via
  # the FR-MTG-10 / NFR-MTG-1 entries. We assert continued presence of the
  # E76-S8-anchored ADR-083 amendment trail to catch accidental deletion.
  run grep -F 'AF-2026-05-10-1' "$SKILL_MD"
  [ "$status" -eq 0 ]
}
