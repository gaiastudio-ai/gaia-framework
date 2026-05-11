---
name: gaia-check-review-gate
description: Check the composite Review Gate status for a story file. Invokes review-gate.sh to read each review row and reports per-row status using the canonical vocabulary PASSED / FAILED / UNVERIFIED.
argument-hint: "[story-key]"
allowed-tools: [Read, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-check-review-gate/scripts/setup.sh

## Mission

You are checking the composite Review Gate status for a story file. The story is resolved by `{story_key}` via the canonical glob `{story_key}-*.md` in `docs/implementation-artifacts/`. This is a read-only verification -- you report the state of each Review Gate row but do not modify the story file.

This skill is the native Claude Code conversion of the legacy check-review-gate workflow (brief Cluster 7, story E28-S56, ADR-042 "mostly scripted"). LLM involvement is minimal -- the skill shells out to `review-gate.sh`, formats the verdict, and returns.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-check-review-gate [story-key]".
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- This skill is READ-ONLY. Do NOT modify the story file.
- Invoke `review-gate.sh status --story {story_key}` to read the Review Gate table from the story file.
- Report each review row using exactly the canonical vocabulary: `PASSED`, `FAILED`, `UNVERIFIED`. No other values are permitted.
- If `review-gate.sh` encounters a non-canonical value in the table, it normalizes to `UNVERIFIED` and emits a warning to stderr -- this skill must surface that warning.

## Steps

### Step 1 -- Resolve Story File

- If no story key was provided as an argument, fail with: "usage: /gaia-check-review-gate [story-key]"
- Resolve the story file path using the canonical glob: `docs/implementation-artifacts/{story_key}-*.md`
- If zero matches: fail with "story file not found for key {story_key} -- searched docs/implementation-artifacts/{story_key}-*.md"
- If multiple matches: fail with "multiple story files matched key {story_key} -- resolve ambiguity"
- Read the resolved story file and confirm it has a `## Review Gate` section.

### Step 2 -- Invoke review-gate.sh

- Run the shared `review-gate.sh` script to read all gate statuses:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh status --story "{story_key}"
  ```
- Parse the JSON output. The response contains a `gates` object with six canonical review names and their status values.
- If `review-gate.sh` exits non-zero, report the error and fail.

### Step 3 -- Generate Composite Verdict

- Evaluate the six canonical review rows:
  - **Code Review**, **QA Tests**, **Security Review**, **Test Automation**, **Test Review**, **Performance Review**
- Composite verdict:
  - All six PASSED: `READY` -- "All reviews passed. Story is ready to transition to done."
  - Any FAILED: `BLOCKED` -- "Story is blocked by failed reviews."
  - All UNVERIFIED (no reviews run): `PENDING` -- "No reviews have been run yet."
  - Mixed (some PASSED, some UNVERIFIED, none FAILED): `IN_PROGRESS` -- "Reviews in progress."

### Step 4 -- Report Results

- Print a structured report:
  ```
  ## Review Gate Check: {story_key}

  **Composite Verdict:** READY | BLOCKED | PENDING | IN_PROGRESS
  **Reviews:** {passed_count}/6 passed, {failed_count} failed, {unverified_count} unverified

  | Review | Status |
  |--------|--------|
  | Code Review | PASSED/FAILED/UNVERIFIED |
  | QA Tests | PASSED/FAILED/UNVERIFIED |
  | Security Review | PASSED/FAILED/UNVERIFIED |
  | Test Automation | PASSED/FAILED/UNVERIFIED |
  | Test Review | PASSED/FAILED/UNVERIFIED |
  | Performance Review | PASSED/FAILED/UNVERIFIED |
  ```
- Exit with code 0 for READY, non-zero for BLOCKED/PENDING/IN_PROGRESS.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-check-review-gate/scripts/finalize.sh
