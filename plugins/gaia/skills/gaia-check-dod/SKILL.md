---
name: gaia-check-dod
description: Check the Definition of Done checklist for a story file. Parses the DoD section and reports per-item checked/unchecked state. Mostly scripted -- delegates to review-gate.sh for gate-state reads and directly parses the DoD markdown section.
argument-hint: "[story-key]"
allowed-tools: [Read, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-check-dod/scripts/setup.sh

## Mission

You are checking the Definition of Done (DoD) checklist for a story file. The story is resolved by `{story_key}` via the canonical glob `{story_key}-*.md` in `.gaia/artifacts/implementation-artifacts/`. This is a read-only verification -- you report the state of each DoD item but do not modify the story file.

This skill is the native Claude Code conversion of the legacy check-dod workflow. LLM involvement is minimal -- the skill parses the DoD markdown section, emits a structured verdict, and returns.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-check-dod [story-key]".
- The story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- This skill is READ-ONLY. Do NOT modify the story file.
- Parse the `## Definition of Done` section from the story file. Each checklist item is a markdown checkbox line (`- [x]` or `- [ ]`).
- Report per-item state: checked (done) or unchecked (not done).
- The composite verdict is: all items checked = `COMPLETE`, any unchecked = `INCOMPLETE`.

## Steps

### Step 1 -- Resolve Story File

- If no story key was provided as an argument, fail with: "usage: /gaia-check-dod [story-key]"
- Resolve the story file path using the canonical glob: `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`
- If zero matches: fail with "story file not found for key {story_key} -- searched .gaia/artifacts/implementation-artifacts/{story_key}-*.md"
- If multiple matches: fail with "multiple story files matched key {story_key} -- resolve ambiguity"
- Read the resolved story file.

### Step 2 -- Parse Definition of Done Section

- Locate the `## Definition of Done` section in the story file.
- If the section is missing, fail with "story file has no '## Definition of Done' section".
- Parse each checkbox line within the section (and any subsections like `### Acceptance`, `### Testing`, `### Code Quality & CI`, `### Documentation`):
  - `- [x]` items are **checked** (done)
  - `- [ ]` items are **unchecked** (not done)
- Build a structured report with each item's label and checked/unchecked state.

### Step 3 -- Generate Verdict

- Count total items, checked items, and unchecked items.
- Composite verdict:
  - All items checked: `COMPLETE` -- "All {N} Definition of Done items are satisfied."
  - Any unchecked: `INCOMPLETE` -- "{M} of {N} items unchecked."
- List each unchecked item explicitly so the developer knows what remains.

### Step 4 -- Report Results

- Print a structured report:
  ```
  ## DoD Check: {story_key}

  **Verdict:** COMPLETE | INCOMPLETE
  **Items:** {checked}/{total} checked

  ### Checked
  - [x] item description ...

  ### Unchecked
  - [ ] item description ...
  ```
- Exit with code 0 for COMPLETE, non-zero for INCOMPLETE.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-check-dod/scripts/finalize.sh
