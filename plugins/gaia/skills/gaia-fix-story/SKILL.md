---
name: gaia-fix-story
description: Apply Val validation findings to a story file and re-run validation to iterate from validating back to ready-for-dev. Native Claude Code conversion of the legacy fix-story workflow (Cluster 7, E28-S55).
argument-hint: "[story-key]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-fix-story/scripts/setup.sh

## Mission

You are fixing a story file that has open validation findings. The story is resolved by `{story_key}` via the shared `resolve-story-file.sh` helper (E79-S7 / FR-476), which honors the E79-S4 nested-over-flat precedence rule across `docs/implementation-artifacts/epic-*/stories/{story_key}-*.md` (canonical) and `docs/implementation-artifacts/{story_key}-*.md` (legacy-flat fallback). After applying fixes, you re-invoke validation to confirm the story is clean and transition it to `ready-for-dev`.

This skill is the native Claude Code conversion of the legacy fix-story workflow (brief Cluster 7, story E28-S55). It reads Val findings, rewrites affected sections, and re-validates via the `gaia-val-validate` skill.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-fix-story [story-key]".
- The story file MUST be resolvable by `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh {story_key}` (E79-S7 / FR-476). The helper searches the canonical nested path first (`docs/implementation-artifacts/epic-*/stories/{story_key}-*.md`), then the legacy-flat path (`docs/implementation-artifacts/{story_key}-*.md`) with a stderr WARNING. If the helper exits 1 (zero matches), fail with "story file not found for key {story_key}".
- The story MUST be in `validating` status. Any other status is a hard gate -- exit with guidance: "story not in validating state -- use /gaia-validate-story first".
- NEVER drop required YAML frontmatter fields during a fix pass. Preserve all 15 required fields: key, title, epic, status, priority, size, points, risk, sprint_id, depends_on, blocks, traces_to, date, author, priority_flag (plus optional: origin, origin_ref, figma).
- Do NOT loop infinitely. If re-validation still reports findings after applying fixes, exit non-zero with a summary and leave status at `validating`.
- Sprint-Status Write Safety: re-read `sprint-status.yaml` immediately before writing the new `ready-for-dev` state.
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, sprint-status.yaml, epics-and-stories.md, story-index.yaml, or per-epic shards under `docs/planning-artifacts/epics/` are FORBIDDEN.

## Steps

### Step 1 -- Resolve Story File

- If no story key was provided as an argument, fail with: "usage: /gaia-fix-story [story-key]"
- Resolve the story file path via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh {story_key}` (E79-S7 / FR-476). The helper honors the E79-S4 nested-over-flat precedence rule and emits stderr WARNINGs for legacy-flat fallback or shadowed flat siblings.
- If the helper exits 1 (zero matches): fail with "story file not found for key {story_key}". The helper's stderr lists the searched paths.
- If the helper exits 2 (multiple matches — ambiguity): fail with "multiple story files matched key {story_key} -- resolve ambiguity". The helper's stderr lists each match.
- Read the resolved story file.

### Step 2 -- Gate Check: Status Must Be Validating

- Parse the YAML frontmatter `status` field from the story file.
- If status is NOT `validating`: exit non-zero with guidance:
  "Story {story_key} is in '{status}' status -- expected 'validating'. Run /gaia-validate-story {story_key} first to produce findings, then re-run /gaia-fix-story."
- If status IS `validating`: proceed.

### Step 3 -- Load Findings

- Check for a `## Validation Findings` section in the story file body.
- Also check the validator-sidecar at `_memory/validator-sidecar/` for findings referencing this story key.
- Parse each finding: extract severity (CRITICAL, WARNING, INFO), affected section/field, and description.
- If no findings found anywhere: exit with "No findings to fix for {story_key}. Story is already clean -- transition to ready-for-dev manually or re-validate."

### Step 4 -- Apply Fixes

For each finding, apply the appropriate fix:

- **Frontmatter drift**: reconcile the body `**Status:**` line with the frontmatter `status` field. Ensure all 15 required fields are present and correctly typed.
- **Missing sections**: draft the missing section following the story template structure.
- **Unclear acceptance criteria**: rewrite in Given/When/Then format, ensure each is testable.
- **Unlinked subtasks**: add AC references to each subtask.
- **Empty test scenarios**: draft test scenario rows.
- **Missing DoD items**: draft specific, measurable Definition of Done items.
- **Other issues**: apply fix per the finding description.

Preserve all existing valid content -- only modify sections flagged by findings.

### Step 5 -- Re-Validate

- Invoke the `gaia-val-validate` skill (NOT the legacy workflow) against the updated story file to confirm clean state. The story file path was resolved in Step 1 via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh` (E79-S7 / FR-476) and may live at either the canonical nested path (`docs/implementation-artifacts/epic-*/stories/{story_key}-{slug}.md`) or the legacy-flat fallback (`docs/implementation-artifacts/{story_key}-{slug}.md`) — pass the resolved path:
  ```
  /gaia-val-validate <resolved_story_path>
  ```
- Parse the re-validation result:
  - If zero CRITICAL/WARNING findings: validation is clean -- proceed to Step 6.
  - If CRITICAL/WARNING findings remain: do NOT loop. Exit non-zero with a summary listing each remaining finding. Leave status at `validating`.

### Step 6 -- Transition Status

- On clean re-validation only:
  - Update the story file frontmatter `status` from `validating` to `ready-for-dev`.
  - Update the body `**Status:**` line to match.
  - Re-read `docs/implementation-artifacts/sprint-status.yaml` immediately before writing (Sprint-Status Write Safety).
  - Call `scripts/load-story.sh {story_key}` to verify the story is registered.
  - Report: "Story {story_key} fixed and transitioned to ready-for-dev."

### Step 7 -- Report Results

- If status transitioned to `ready-for-dev`: report success with list of sections modified.
- If findings remain after fixes: report failure with list of unresolved findings.
- Exit with code 0 for success, non-zero for remaining findings.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-fix-story/scripts/finalize.sh
