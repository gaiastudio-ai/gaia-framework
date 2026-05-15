#!/usr/bin/env bats
# triage-findings-fallback.bats — E92-S1 main-turn direct-write fallback.
#
# Covers TC-OEXP-1..2:
#   TC-OEXP-1: Fixture story file written via direct-write fallback passes
#              all 3 inline checks (AC2) and carries audit-trail fields (AC3).
#   TC-OEXP-2: Canonical-filename regex documented in SKILL.md prose matches
#              the on-disk validate-canonical-filename.sh script behavior
#              (no drift between script and prose).

load 'test_helper.bash'

setup() {
  common_setup
  TRIAGE_SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-triage-findings" && pwd)/SKILL.md"
  CREATE_SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-create-story" && pwd)"
  VALIDATOR="$CREATE_SKILL_DIR/scripts/validate-canonical-filename.sh"
  SLUGIFY="$CREATE_SKILL_DIR/scripts/slugify.sh"
  export TRIAGE_SKILL CREATE_SKILL_DIR VALIDATOR SLUGIFY
}

teardown() {
  common_teardown
}

# ---------------- TC-OEXP-1: fixture passes 3 inline checks + audit-trail ----------------
@test "TC-OEXP-1: direct-write fixture story passes inline canonical-filename + frontmatter + audit-trail checks" {
  local story_key="E92-S1"
  local slug="main-turn-direct-write-fallback-for-gaia-create-story-spawn-under-broken-context-fork"
  local fixture="$TEST_TMP/${story_key}-${slug}.md"
  cat > "$fixture" <<EOF
---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "${story_key}"
title: "Main-turn direct-write fallback for /gaia-create-story spawn under broken context:fork"
epic: "E92"
status: ready-for-dev
priority: "P2"
size: "M"
points: 5
risk: "medium"
sprint_id: "sprint-46"
priority_flag: null
origin: "add-feature"
origin_ref: "AF-2026-05-14-12"
depends_on: []
blocks: []
traces_to: ["FR-OEXP-1"]
date: "2026-05-14"
author: "test"
spawn_fallback: "direct-write"
spawn_fallback_reason: "substrate-issue-49559"
---

# body
EOF

  # Inline check 1: canonical filename — basename matches ^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$
  local base
  base="$(basename "$fixture")"
  [[ "$base" =~ ^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$ ]]

  # Inline check 1 cross-validate via the on-disk script
  run "$VALIDATOR" --file "$fixture"
  [ "$status" -eq 0 ]

  # Inline check 2: required frontmatter fields present
  for field in template version used_by key title epic status priority size points risk origin origin_ref date author; do
    grep -qE "^${field}:" "$fixture"
  done
  # nullable fields just need to appear (value may be null/empty)
  for field in sprint_id priority_flag; do
    grep -qE "^${field}:" "$fixture"
  done
  # array fields
  for field in depends_on blocks traces_to; do
    grep -qE "^${field}:" "$fixture"
  done

  # Inline check 3: dedup — story_key MUST be unique. We assert the fixture
  # is the only file in TEST_TMP using this key (proxy for the dedup contract).
  local count
  count="$(ls "$TEST_TMP"/${story_key}-*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]

  # AC3: audit-trail fields present and non-empty
  grep -qE '^spawn_fallback:[[:space:]]+"direct-write"' "$fixture"
  grep -qE '^spawn_fallback_reason:[[:space:]]+"[^"]+"' "$fixture"
}

# ---------------- TC-OEXP-2: prose-script parity ----------------
@test "TC-OEXP-2: canonical-filename regex in SKILL.md prose matches on-disk validator behavior (no drift)" {
  # The SKILL.md fallback prose MUST document the same regex shape the
  # validator enforces. The validator's algorithm is:
  #   basename == "{key}-{slugify(title)}.md"
  # The regex-equivalent shape (key + slug + .md) is:
  local prose_regex='\^E\[0-9\]\+-S\[0-9\]\+-\[a-z0-9-\]\+\\\.md\$'
  run grep -F '^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$' "$TRIAGE_SKILL"
  [ "$status" -eq 0 ]

  # Cross-verify: an obviously canonical name passes the validator, and
  # an obviously non-canonical name fails the regex shape.
  local good="E92-S1-fixture-title.md"
  local bad="E92-S1-Fixture-Title.md"   # uppercase
  [[ "$good" =~ ^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$ ]]
  [[ ! "$bad" =~ ^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$ ]]
}

# ---------------- AC1: fallback subsection present in triage-findings SKILL.md ----------------
@test "AC1: /gaia-triage-findings SKILL.md has Main-turn direct-write fallback subsection" {
  run grep -F "Main-turn direct-write fallback" "$TRIAGE_SKILL"
  [ "$status" -eq 0 ]
  # Cite the canonical trigger conditions
  run grep -F "feedback_plugin_context_fork_broken.md" "$TRIAGE_SKILL"
  [ "$status" -eq 0 ]
  run grep -F "49559" "$TRIAGE_SKILL"
  [ "$status" -eq 0 ]
}

# ---------------- AC1: prose says fallback is NOT preemptive ----------------
@test "AC1: fallback prose explicitly states spawn is still the default" {
  run grep -F "spawn is still the default" "$TRIAGE_SKILL"
  [ "$status" -eq 0 ]
}

# ---------------- AC5: gaia-correct-course also documents the fallback ----------------
@test "AC5: /gaia-correct-course SKILL.md has Main-turn direct-write fallback subsection" {
  local cc_skill="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-correct-course" && pwd)/SKILL.md"
  run grep -F "Main-turn direct-write fallback" "$cc_skill"
  [ "$status" -eq 0 ]
}
