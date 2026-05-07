---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "{story_key}"
title: "{story_title}"
epic: "{epic_key}"
status: backlog
priority: "{P0/P1/P2}"
size: "{S/M/L/XL}"
points: {story_points}
risk: "{high/medium/low}"
sprint_id: null
priority_flag: null
origin: {origin}
origin_ref: {origin_ref}
depends_on: {depends_on}
blocks: {blocks}
traces_to: {traces_to}
date: "{creation_date}"
author: "{agent_name}"
# Optional: Figma design metadata — enables dev agents to extract design tokens and component specs via MCP.
# Omit this block entirely if the story does not reference Figma designs.
# figma:
#   file_key: "{figma_file_key}"       # Figma file identifier (from URL)
#   pages: ["{page_name}"]             # List of page names to extract from
#   node_ids: ["{node_id}"]            # List of specific Figma node IDs
#   design_version: null               # Populated by dev agent after first consumption (lastModified hash)
---

# Story: {story_title}

> **Epic:** {epic_key}
> **Priority:** {P0/P1/P2}
> **Status:** backlog
> **Date:** {creation_date}
> **Author:** {agent_name}

## User Story

As a {role}, I want to {action}, so that {benefit}.

## Acceptance Criteria

- [ ] Given {context}, when {action}, then {expected result}
- [ ] Given {context}, when {action}, then {expected result}

## Tasks / Subtasks

- [ ] Task 1 (AC: #)
  - [ ] Subtask 1.1
- [ ] Task 2 (AC: #)
  - [ ] Subtask 2.1

## Dev Notes

- Relevant architecture patterns and constraints
- Source tree components to touch
- Testing standards summary

## Technical Notes

{Implementation guidance, architecture constraints, relevant patterns.}

## Dependencies

- {Dependency on other story or system}

## Test Scenarios

| # | Scenario | Input | Expected |
|---|----------|-------|----------|
| 1 | {happy path} | {input} | {output} |
| 2 | {edge case} | {input} | {output} |

### Project Structure Notes

- Alignment with unified project structure (paths, modules, naming)
- Detected conflicts or variances (with rationale)

### References

- Cite all technical details with source paths and sections, e.g. [Source: docs/<file>.md#Section]
- For ADR lookups, reference the inline decision log in `docs/planning-artifacts/architecture.md §Decision Log` — ADRs live inline in that table rather than in a separate ADR directory.

## Dev Agent Record

### Agent Model Used

{agent_model_name_version}

### Debug Log References

### Completion Notes List

### File List

## Findings

> Out-of-scope issues discovered during implementation. Each finding becomes a candidate for a backlog story.

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| — | — | — | — | — |

> **Types:** bug, tech-debt, enhancement, missing-setup, documentation
> **Severity:** critical, high, medium, low

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | UNVERIFIED | — |
| QA Tests | UNVERIFIED | — |
| Security Review | UNVERIFIED | — |
| Test Automation | UNVERIFIED | — |
| Test Review | UNVERIFIED | — |
| Performance Review | UNVERIFIED | — |

> Story moves to `done` only when ALL reviews show PASSED.

## Estimate

- **Points:** {story points}
- **Developer:** {assigned agent}

## Definition of Done

### Acceptance

- [ ] All acceptance criteria verified and checked off
- [ ] All subtasks marked complete

### Testing

- [ ] All tests pass (unit, integration, e2e as applicable)
- [ ] No linting or formatting errors

### Code Quality & CI

- [ ] Code compiles / builds without errors
- [ ] Code follows project conventions
- [ ] No hardcoded secrets or credentials
- [ ] PR merged to staging with all CI checks passing

### Documentation

- [ ] Documentation updated (if applicable)
