---
name: gaia-correct-course
description: "Manage mid-sprint scope changes by updating story files (source of truth) and reconciling sprint-status.yaml via sprint-state.sh. Supports scope changes, priority shifts, blocker resolution, resource changes, and story injection. GAIA-native replacement for the legacy correct-course XML engine workflow."
argument-hint: "[story-key] [change-type]"
allowed-tools: [Read, Edit, Bash]
version: "1.0.0"
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-correct-course/scripts/setup.sh

## Mission

Manage mid-sprint course corrections by applying scope changes to story files and reconciling `sprint-status.yaml` via the canonical `sprint-state.sh` helper. The story file is always the source of truth -- this skill edits story files directly and delegates all sprint-status reconciliation to `sprint-state.sh`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/correct-course/` XML engine workflow (brief Cluster 8, story E28-S63). Follows ADR-042 (scripts-over-LLM) for state transitions via `sprint-state.sh`.

## Critical Rules

- The story file is the source of truth per CLAUDE.md Sprint-Status Write Safety. All changes start in the story file.
- NEVER write to `sprint-status.yaml` directly. NEVER modify `sprint-status.yaml` by hand or via Edit/Write tools. All sprint-status reconciliation MUST go through `sprint-state.sh`.
- New stories injected into the sprint MUST already exist in `epics-and-stories.md`. If they do not, recommend running `/gaia-add-stories` first.
- Document the reason for every course correction in the sprint plan.
- Preserve existing story data -- only modify the fields relevant to the scope change.

## Steps

### Step 1 --- Load Sprint Context

Read the current sprint context:

1. Read `${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/sprint-status.yaml` to understand current sprint state.
2. Read `${CLAUDE_PROJECT_ROOT}/docs/planning-artifacts/epics-and-stories.md` to identify stories not yet in any sprint (candidates for injection).
3. Scan `${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/retro-*.md` files if available -- check if the current issue matches a known pattern from past retrospectives. If a match is found, note it: "This issue was flagged in retro-{sprint_id}: {finding}. Previous recommendation: {recommendation}."

### Step 2 --- Identify Change

Ask the user: "What needs to change and why?"

Classify the change into one of these types:
- **Scope change** -- adding, removing, or modifying story scope within the sprint
- **Priority shift** -- reordering story priorities without adding/removing stories
- **Blocker resolution** -- unblocking a story by resolving a dependency or impediment
- **Resource change** -- reassigning stories due to team capacity changes
- **Story injection** -- pulling a new story into the sprint from the backlog
- **Composite-verdict escape hatch (ADR-082, E66-S3)** -- a story is blocked at `review` because the `/gaia-review-all` composite verdict is `REQUEST_CHANGES` or `BLOCKED` past the seven-day grace window, AND the underlying issue cannot be resolved within the sprint due to a legitimate edge case (third-party dependency block, infrastructure outage, scope-debate-in-flight). This path moves the story OFF `review` to a remediation track without bypassing the gating contract; an audit-trail entry is recorded per Step 5b.

Ask if this is linked to a change request (CR ID).

> **Composite-verdict escape hatch — when to choose it.** Per ADR-082 (E66-S3) the composite verdict is GATING after the 7-day grace window: a `REQUEST_CHANGES` or `BLOCKED` composite hard-blocks transition to `done`. The `/gaia-correct-course` escape hatch is the ONLY supported way to unblock a story without satisfying every gate — and only for the legitimate edge cases listed above. The escape hatch does NOT bypass the gating contract; it transitions the story off `review` (typically back to `in-progress` or to `backlog`) so the underlying gate can be re-resolved on its own track. Every escape-hatch invocation MUST record an audit-trail entry via Step 5b, naming the failing gate(s), the blocking edge case, and the remediation plan. Do not use this path to silence a legitimate review failure.

### Step 3 --- Impact Analysis

For each affected story:

1. Identify which stories are impacted by the change.
2. Assess dependency implications -- check `depends_on` and `blocks` fields in affected story files.
3. Estimate impact on sprint timeline and velocity.
4. If story injection: verify the story exists in `epics-and-stories.md`. If not, recommend `/gaia-add-stories` first.

### Step 4 --- Propose Adjustment

Present the proposed changes:

1. Re-scope sprint: list stories to add, remove, or reprioritize.
2. If injecting stories: show velocity impact -- what must be removed to fit within capacity.
3. Propose updated timeline.
4. Get user approval for changes.

### Step 5 --- Apply Changes

For each approved change, apply it to the story file (source of truth):

1. Edit the story file to update status, tasks, acceptance criteria, or priority as needed.
2. Invoke `sprint-state.sh` to reconcile `sprint-status.yaml`:

For stories **removed** from the sprint (moved back to backlog):
```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" transition --story {story_key} --to backlog
```

For stories **injected** into the sprint that **already have a story file** (the story file's `frontmatter.sprint_id` MUST match the active sprint):
```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" inject --story {story_key} [--sprint-id {sprint_id}]
```

The `inject` subcommand (E38-S10, AF-2026-05-01-4, ADR-055 §10.29) appends the story's metadata to `sprint-status.yaml`'s `stories:` block, bumps `total_points`, recomputes `capacity_utilization`, and emits a `story_injected` lifecycle event. It is idempotent — re-running on an already-injected key is a no-op. `--sprint-id` is optional and defaults to the active sprint (the yaml's `sprint_id`).

For an **in-sprint status change** of a story already present in `sprint-status.yaml` (e.g., escalating from `ready-for-dev` to `in-progress` mid-sprint), use `transition` instead — `inject` is for adding new entries, not for re-stating existing ones:
```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" transition --story {story_key} --to {target_status}
```

For stories **injected** into the sprint that **need a new story file** (Skill-to-Skill Delegation, FR-FITP-2):

Story creation is delegated to `/gaia-create-story` via subagent spawn. This replaces all inline story-creation logic -- delegation is authoritative.

1. **Pre-spawn validation:** validate `origin_ref` using `spawn-guard.sh`:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" validate-ref "${sprint_id}"
```
If validation fails, halt with guidance. Do not spawn the subagent.

2. **Collision check:** verify no story file already exists at the canonical path:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" check-collision "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts" "${story_key}"
```
If collision detected, halt with guidance to delete or rename before retry. Do not spawn the subagent.

3. **Spawn `/gaia-create-story`:** invoke as a subagent with origin context:
```
/gaia-create-story {story_key} with origin="correct-course" origin_ref="{sprint_id}"
```
The spawned `/gaia-create-story` populates the story frontmatter with `origin: "correct-course"` and `origin_ref: "{sprint_id}"` and produces the full elaboration (AC, tasks, test scenarios).

4. **Post-spawn verification:** after the subagent completes, verify the story file exists and frontmatter is correct:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" verify "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/${story_key}-*.md" "correct-course" "${sprint_id}"
```
If verification fails (schema drift), halt with actionable guidance referencing NFR-FITP-1.

5. **On subagent failure** (timeout, context overflow, crash): halt with actionable guidance (failure reason, retry instructions). Clean up any partial file:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" cleanup "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/${story_key}-*.md"
```
No partial story stubs may persist on disk after a failed spawn.

For stories that **changed status** but remain in the sprint:
```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" transition --story {story_key} --to {new_status}
```

### Step 5b --- Record Action Items for Drop/Defer Decisions (E39-S3, FR-FITP-3)

After the sprint-state mutation in Step 5, for every story that was **dropped** or **deferred** (moved back to backlog), persist a structured action-items entry so retrospectives and `/gaia-action-items` have a complete record. Both drop and defer are process-class decisions per FR-FITP-3.

1. Source the action-items writer:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/action-items-write.sh"
```

2. For each dropped or deferred story, invoke the writer:
```bash
aiw_write \
  --target "${CLAUDE_PROJECT_ROOT}/docs/planning-artifacts/action-items.yaml" \
  --sprint-id "{current_sprint_id}" \
  --classification "process" \
  --text "Dropped/deferred {story_key}: {reason}" \
  --ref-key "story_key" \
  --ref-value "{story_key}"
```

The writer handles:
- **Bootstrap:** creates `action-items.yaml` with the architecture §10.28.6 schema header if the file does not exist.
- **Auto-increment:** computes the next `AI-{n}` id from existing entries.
- **Idempotency:** dedup key is `(story_key, sprint_id, classification=process)` -- re-running the same drop/defer does not duplicate.
- **Schema compliance:** entry fields match architecture §10.28.6 exactly (`id`, `sprint_id`, `text`, `classification`, `status: open`, `escalation_count: 0`, `created_at`, `theme_hash`, `story_key`).

### Step 6 --- Log Course Correction

Format the change summary with a standard header in the sprint plan:

```
## Course Correction -- {date}
Change Type: {type} | Stories Affected: {count} | Velocity Impact: {delta} points
Reason: {reason}
CR ID: {cr_id or N/A}
```

Log the correction reason, CR ID (if applicable), and all changes made.

### Step 7 --- Suggest Next Actions

Based on the changes applied:

- If stories were injected: suggest `/gaia-dev-story {story_key}` for newly injected stories.
- If stories were removed: note that removed stories return to backlog for future sprint planning.
- If a CR was referenced: suggest checking the change request status.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-correct-course/scripts/finalize.sh
