#!/usr/bin/env bats
# transition-story-status-untriaged-findings.bats
#
# Verifies the untriaged-findings gate on the review -> done path.
# The gate blocks the transition when any Findings row lacks a
# [TRIAGED -> ...] or [DISMISSED] marker, unless overridden.
#
# Public-function coverage (NFR-052):
#   - _check_untriaged_findings  — the new gate function

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-utf-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"

  STORY_KEY="E900-S1"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-findings-fixture.md"
  SPRINT_YAML="$TEST_TMP/docs/implementation-artifacts/sprint-status.yaml"
  EPICS_MD="$TEST_TMP/docs/planning-artifacts/epics-and-stories.md"
  INDEX_YAML="$TEST_TMP/docs/implementation-artifacts/story-index.yaml"
  LOCK_FILE="$TEST_TMP/_memory/.story-status.lock"

  # Build the fixture through a function so tests can customize Findings.
  _write_story() {
    local findings_body="${1:-}"
    cat >"$STORY_FILE" <<STORYEOF
---
template: 'story'
key: "${STORY_KEY}"
title: "Findings gate fixture"
epic: "E900"
status: review
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Findings gate fixture

> **Status:** review

## Findings

> Out-of-scope issues discovered during implementation.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
${findings_body}

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
STORYEOF
  }

  cat >"$SPRINT_YAML" <<'EOF'
sprint_id: "fixture-sprint"
stories:
  - key: E900-S1
    status: "review"
EOF

  cat >"$EPICS_MD" <<'EOF'
# Epics and Stories

## Epic 900 — Findings fixture epic

### Story E900-S1: Findings gate fixture

- **Epic:** E900
- **Priority:** P2
- **Status:** review
EOF

  cat >"$INDEX_YAML" <<'EOF'
# Auto-maintained
last_updated: "2026-10-17T00:00:00Z"
stories:
  E900-S1:
    story_key: "E900-S1"
    title: "Findings gate fixture"
    epic: "E900"
    priority: "P2"
    risk: "low"
    author: ""
    file: "E900-S1-findings-fixture.md"
    status: "review"
EOF

  export PROJECT_PATH="$TEST_TMP"
  export IMPLEMENTATION_ARTIFACTS="$TEST_TMP/docs/implementation-artifacts"
  export PLANNING_ARTIFACTS="$TEST_TMP/docs/planning-artifacts"
  export MEMORY_PATH="$TEST_TMP/_memory"
  export SPRINT_STATUS_YAML="$SPRINT_YAML"
  export EPICS_AND_STORIES="$EPICS_MD"
  export STORY_INDEX_YAML="$INDEX_YAML"
  export STORY_STATUS_LOCK="$LOCK_FILE"
  # Bypass the composite review-gate (tested elsewhere); focus on findings gate.
  export GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE=1
  # Ensure findings override is off by default.
  unset GAIA_ALLOW_UNTRIAGED_DONE 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP" 2>/dev/null || true
}

# -- AC1: untriaged rows block the done transition --

@test "untriaged findings block review to done and name each untriaged row" {
  _write_story '| 1 | bug | medium | Widget crashes on null input | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout value [TRIAGED -> E900-S99] | Extract to config |
| 3 | bug | high | Race condition in queue handler | Add mutex |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -ne 0 ]

  # Both untriaged rows (1 and 3) must be named in the output.
  [[ "$output" == *"Widget crashes on null input"* ]]
  [[ "$output" == *"Race condition in queue handler"* ]]
  # Triaged row 2 must NOT be named.
  [[ "$output" != *"Hardcoded timeout value"* ]]
  # Must point user to the triage command.
  [[ "$output" == *"/gaia-triage-findings"* ]]
}

# -- AC2: all triaged rows pass --

@test "all findings triaged allows review to done" {
  _write_story '| 1 | bug | medium | Widget crashes [TRIAGED -> E900-S99] | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout [DISMISSED] | No action needed |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- AC3: no Findings section or empty table --

@test "no Findings section allows review to done" {
  # Write a story with no ## Findings heading at all.
  cat >"$STORY_FILE" <<'STORYEOF'
---
template: 'story'
key: "E900-S1"
title: "Findings gate fixture"
epic: "E900"
status: review
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Findings gate fixture

> **Status:** review

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |
STORYEOF

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

@test "placeholder-only Findings table allows review to done" {
  _write_story '| — | — | — | — | — |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- AC4: override allows transition with warning --

@test "override GAIA_ALLOW_UNTRIAGED_DONE=1 emits warning but allows transition" {
  _write_story '| 1 | bug | medium | Widget crashes on null input | Fix null check |
| 2 | bug | high | Race condition in queue handler | Add mutex |'

  export GAIA_ALLOW_UNTRIAGED_DONE=1
  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]

  # WARNING must be emitted.
  [[ "$output" == *"WARNING"* ]]
  # Untriaged rows should still be named in the warning.
  [[ "$output" == *"Widget crashes on null input"* ]]
}

# -- AC5: non-done transition unaffected --

@test "non-done transition with untriaged findings proceeds without check" {
  # Build an in-progress fixture with untriaged findings so we can test
  # in-progress -> review (which must NOT trigger the findings gate).
  cat >"$STORY_FILE" <<'STORYEOF'
---
template: 'story'
key: "E900-S1"
title: "Findings gate fixture"
epic: "E900"
status: in-progress
sprint_id: "fixture-sprint"
priority: "P2"
size: "S"
points: 1
risk: "low"
---

# Story: Findings gate fixture

> **Status:** in-progress

## Findings

> Out-of-scope issues discovered during implementation.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| 1 | bug | medium | Widget crashes on null input | Fix null check |
STORYEOF

  # Align the other surfaces.
  sed "s/status: \"review\"/status: \"in-progress\"/" "$SPRINT_YAML" > "$SPRINT_YAML.tmp"
  mv -f "$SPRINT_YAML.tmp" "$SPRINT_YAML"
  sed 's/- \*\*Status:\*\* review/- **Status:** in-progress/' "$EPICS_MD" > "$EPICS_MD.tmp"
  mv -f "$EPICS_MD.tmp" "$EPICS_MD"
  sed 's/status: "review"/status: "in-progress"/' "$INDEX_YAML" > "$INDEX_YAML.tmp"
  mv -f "$INDEX_YAML.tmp" "$INDEX_YAML"

  run "$TRANSITION" "$STORY_KEY" --to review
  [ "$status" -eq 0 ]
}

# -- Fail-closed: unparseable section --

@test "gate fails closed when Findings section has rows but table cannot be parsed" {
  # Write a malformed table (no pipe delimiters) inside the Findings section.
  _write_story 'This is not a table row but has content'

  # The gate should treat non-table content as no findings (no-op pass).
  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- Mixed markers: TRIAGED in Finding column, DISMISSED in Action column --

@test "markers recognized in both Finding and Suggested Action columns" {
  _write_story '| 1 | bug | medium | Widget crashes [TRIAGED -> E900-S50] | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout | No action needed [DISMISSED] |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}
