#!/usr/bin/env bats
# dual-schema-routing.bats — /gaia-action-items dual-schema branch documentation gate (E76-S3)
#
# AC4 / FR-MTG-22 / TC-MTG-AI-5
#
# Routing is performed by the LLM following SKILL.md instructions, but the
# contract that must be present in the SKILL is verifiable via static checks
# on the document. These tests assert the SKILL.md contains the canonical
# dual-schema routing language so that drift does not silently bypass it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-action-items/SKILL.md"
}

@test "Pre-flight: gaia-action-items/SKILL.md exists" {
  [ -f "$SKILL" ]
}

@test "AC4: SKILL.md documents the schema_version detection contract" {
  grep -q 'schema_version' "$SKILL"
  grep -q 'v1\|v2' "$SKILL"
}

@test "AC4: SKILL.md documents the v2 type -> target_command resolver branch" {
  grep -q 'type.*target_command\|type → target_command' "$SKILL"
}

@test "AC4: SKILL.md documents the legacy v1 classification -> assignee branch" {
  grep -qE 'classification.*assignee|classification → assignee' "$SKILL"
}

@test "AC4: SKILL.md documents that v1 entries MUST NOT be auto-converted to v2" {
  grep -qiE 'no auto-conversion|MUST NOT.+auto.+convert|never.+auto.*convert' "$SKILL"
}

@test "AC4: SKILL.md preserves the classification-confirmation gate (ADR-052 / AC-EC7)" {
  grep -q 'AC-EC7\|classification.confirmation' "$SKILL"
}

@test "AC4: SKILL.md enumerates the eleven canonical action-item types" {
  for t in feature prd-edit ux-edit arch-edit test-edit new-story sprint-correction sprint-plan brainstorm-followup adr-draft discussion-only; do
    grep -q "$t" "$SKILL" || { echo "missing type: $t"; return 1; }
  done
}
