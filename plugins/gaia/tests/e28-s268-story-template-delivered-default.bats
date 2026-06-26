#!/usr/bin/env bats
# Story-template `delivered:` default.
#
# A freshly scaffolded story has not shipped, so the story template's
# frontmatter default for `delivered:` must be `false` (not `true`). The
# create-story frontmatter generator already defaults `false`; this pins the
# template default to match so the two never drift, and confirms the
# frontmatter validator accepts `delivered: false`.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$PLUGIN_ROOT/skills/gaia-create-story/story-template.md"
  VALIDATE="$PLUGIN_ROOT/skills/gaia-create-story/scripts/validate-frontmatter.sh"
}

@test "story template defaults delivered to false (AC1)" {
  [ -f "$TEMPLATE" ]
  run grep -E '^delivered:[[:space:]]*false[[:space:]]*$' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "story template never defaults delivered to true (AC1)" {
  run grep -E '^delivered:[[:space:]]*true[[:space:]]*$' "$TEMPLATE"
  [ "$status" -ne 0 ]
}

@test "template comment explains delivered is true only after shipping (AC3)" {
  run grep -E '^# delivered:.*true ONLY when.*shipped' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "validator does not flag a delivered false story on the delivered field (AC4)" {
  [ -x "$VALIDATE" ]
  mkdir -p "$BATS_TEST_TMPDIR/E1-sample"
  story="$BATS_TEST_TMPDIR/E1-sample/E1-S1-sample.md"
  cat > "$story" <<'FM'
---
key: "E1-S1"
title: "Sample"
epic: "E1 — Sample"
status: backlog
priority: "P1"
size: "S"
points: 2
risk: "low"
sprint_id: null
priority_flag: null
depends_on: []
blocks: []
traces_to: []
date: "2026-06-26"
author: "tester"
delivered: false
deferred_implementation: false
---

# Story: Sample

## Acceptance Criteria

- [ ] **AC1:** Given a thing, when acted on, then a result.

## Review Gate

| Review | Status |
|--------|--------|
| code-review | UNVERIFIED |
FM
  # The validator must NOT emit any finding scoped to the `delivered` field
  # for a well-formed story carrying delivered: false.
  run "$VALIDATE" --file "$story"
  ! printf '%s\n' "$output" | grep -qiE '(^|\|)[^|]*deliver'
}
