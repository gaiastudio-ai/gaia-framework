#!/usr/bin/env bats
# transition-story-status-untriaged-findings.bats
#
# Verifies the untriaged-findings gate on the review -> done path.
# The gate blocks the transition when any Findings row lacks a
# [TRIAGED -> ...] or [DISMISSED] marker, unless overridden.
#
# Public-function coverage:
#   - _check_untriaged_findings  — the untriaged-findings gate function

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  TRANSITION="$SCRIPTS_DIR/transition-story-status.sh"
  TRIAGED_MARKER_SH="$REPO_ROOT/plugins/gaia/skills/gaia-triage-findings/scripts/triaged-marker.sh"

  TEST_TMP="$BATS_TEST_TMPDIR/tss-utf-$$"
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  mkdir -p "$TEST_TMP/docs/planning-artifacts"
  mkdir -p "$TEST_TMP/_memory"

  # Source the canonical marker helper for fixture construction.
  # shellcheck source=/dev/null
  . "$TRIAGED_MARKER_SH"

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

@test "untriaged findings block review to done with exit 8 and name each untriaged row" {
  local triaged_row="| 2 | tech-debt | low | Hardcoded timeout value $(triaged_marker E900-S99) | Extract to config |"
  _write_story "| 1 | bug | medium | Widget crashes on null input | Fix null check |
${triaged_row}
| 3 | bug | high | Race condition in queue handler | Add mutex |"

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 8 ]

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
  _write_story "| 1 | bug | medium | Widget crashes $(triaged_marker E900-S99) | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout [DISMISSED] | No action needed |"

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

# -- Non-table content passes (no pipe-delimited rows to check) --

@test "non-table content in Findings section is treated as no findings" {
  # Write prose (no pipe delimiters) inside the Findings section.
  _write_story 'This is not a table row but has content'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- Markers recognized regardless of which column they appear in --

@test "markers recognized in both Finding and Suggested Action columns" {
  _write_story "| 1 | bug | medium | Widget crashes $(triaged_marker E900-S50) | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout | No action needed [DISMISSED] |"

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- Pipe characters inside finding text do not break marker detection --

@test "pipes in finding text do not prevent marker detection" {
  # Real-world pattern from story findings: escaped pipes in code snippets.
  # The column split would push the marker past column 5 without whole-row scanning.
  _write_story "| 1 | bug | medium | Test hangs when stdin not redirected (the \`timeout 1s cat \|\| cat\` pattern reads from stdin); filed as GitHub #1982 $(triaged_marker '#1982') | Fix the stdin dependency |
| 2 | tech-debt | low | Function uses \`a | b | c\` pipeline $(triaged_marker E900-S50) | Simplify |"

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- Real marker variants from closed-sprint stories --

@test "bare TRIAGED marker (legacy form) is accepted" {
  # 18 rows across the project use [TRIAGED] without an arrow or target.
  _write_story '| 1 | bug | medium | Widget issue [TRIAGED] | Fix it |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

@test "TRIAGED with unicode arrow is accepted" {
  # 8 rows use the unicode right arrow instead of ASCII ->.
  _write_story '| 1 | bug | medium | Widget issue [TRIAGED → E900-S50] | Fix it |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

@test "DISMISSED with explanation is accepted" {
  # ~69 rows carry a colon-delimited reason after DISMISSED.
  _write_story '| 1 | bug | medium | Widget issue [DISMISSED: tracked as GitHub #1953] | Filed upstream |
| 2 | tech-debt | low | Pipeline flaw [DISMISSED: fixed in PR #1992] | Resolved |
| 3 | documentation | low | Missing note [DISMISSED: internal planning artifact] | N/A |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

@test "TRIAGED with multi-issue target is accepted" {
  # Real form: [TRIAGED -> #2175, #2205]
  _write_story '| 1 | bug | medium | Widget issue [TRIAGED -> #2175, #2205] | Split across issues |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

@test "mixed real marker forms all pass in one table" {
  _write_story "| 1 | bug | medium | Crash on null $(triaged_marker E900-S99) | Fix null check |
| 2 | tech-debt | low | Hardcoded timeout [TRIAGED] | Extract to config |
| 3 | bug | low | Unicode issue [TRIAGED → E900-S50] | Fix encoding |
| 4 | documentation | low | Missing docs [DISMISSED: tracked as GitHub #1953] | Filed upstream |
| 5 | bug | medium | Race condition [DISMISSED] | Known limitation |
| 6 | tech-debt | low | Multi-target [TRIAGED -> #2175, #2205] | Split |"

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}

# -- Partial or unclosed markers must NOT count as triaged --

@test "partial TRIAGED marker without closing bracket is untriaged" {
  _write_story '| 1 | bug | medium | Widget issue [TRIAGED -> but never closed | Fix it |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 8 ]
  [[ "$output" == *"Widget issue"* ]]
}

@test "partial DISMISSED marker without closing bracket is untriaged" {
  _write_story '| 1 | bug | medium | Widget issue [DISMISSED prematurely by bot | Fix it |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 8 ]
  [[ "$output" == *"Widget issue"* ]]
}

# -- Separator detection must not swallow data rows containing dashes --

@test "finding text containing triple dashes is not skipped as separator" {
  # A row whose finding text includes "---" must not be treated as a table
  # separator. The real separator row has dashes-only cells.
  _write_story '|---|------|----------|---------|-----------------|
| 1 | bug | medium | Config parser crashes on --- delimiter | Fix parser |'

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 8 ]
  [[ "$output" == *"Config parser crashes"* ]]
}

@test "real table separator row is still skipped" {
  # The actual separator row (dashes-only cells) must not be counted as a
  # finding, while the triaged data row below it passes.
  _write_story "| 1 | bug | medium | Widget crashes $(triaged_marker E900-S99) | Fix null check |"

  run "$TRANSITION" "$STORY_KEY" --to done
  [ "$status" -eq 0 ]
}
