---
name: gaia-add-stories
description: Add new stories to existing epics or create new epics with stories. Enforces story protection (in-progress/review/done stories are read-only), auto-increments IDs, and validates via inline Val integration. Use when "add stories".
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-stories/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm all
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all

## Mission

You are adding new stories to the project's epics-and-stories document. Stories may be added to existing epics or new epics may be created. Story protection is strictly enforced -- stories with status in-progress, review, ready-for-dev, or done are read-only and must never be modified.

**Path resolution (AF-2026-05-21-13).** All path references in this SKILL.md use the canonical post-ADR-111 location `.gaia/artifacts/planning-artifacts/epics-and-stories.md` and `.gaia/artifacts/test-artifacts/test-plan.md` (with strategy/ fallback per ADR-072). Pre-ADR-111 projects continue to work via canonical-first two-tier resolution at the script layer (`scripts/setup.sh` already implements the E96-S7 partial-4c smart-fallback). When writing artifacts via the Write tool, target the canonical paths named in this SKILL.md; the pre-ADR-111 fallback is read-side only.

This skill is the native Claude Code conversion of the legacy add-stories workflow (E28-S57). The step ordering, protection model, and output paths are preserved from the legacy instructions.

## Critical Rules

- Story protection is ENFORCED -- stories with status in-progress, review, ready-for-dev, or done are READ-ONLY. Never modify them.
- New stories MUST follow the exact format used in existing epics-and-stories.md.
- Story and epic IDs must not collide with existing IDs -- auto-increment from highest existing.
- Append to existing content -- never overwrite or reorder existing stories or epics.
- The epics-and-stories document MUST exist at `.gaia/artifacts/planning-artifacts/epics-and-stories.md` before starting. If missing, fail fast with "epics-and-stories.md not found -- run /gaia-create-epics first."
- The `sprint-status.yaml` MUST be re-read immediately before writing (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Load and Analyze Existing State

- Read `.gaia/artifacts/planning-artifacts/epics-and-stories.md` in full.
- Read `.gaia/state/sprint-status.yaml` in full.
- Parse all existing epic IDs and names.
- Parse all existing story IDs per epic -- identify highest ID per epic and overall.
- Build protection map for each story based on its current status:
  - LOCKED: done, review, in-progress, ready-for-dev -- cannot be modified
  - PROTECTED: invalid -- cannot be modified by default
  - CAUTIOUS: validating, backlog -- modification requires explicit user confirmation
  - OPEN: new stories not yet in sprint-status -- full read/write
- Display summary: total epics, total stories, stories by protection level (locked/protected/cautious/open).

### Step 2 -- Identify New Requirements

- If triggered by orchestrator (e.g., from add-feature cascade): inherit feature_description, prd_diff (new FR/NFR IDs), arch_diff (architecture changes), and cr_id from triggering workflow context. Skip user questions and proceed to Step 3.
- Otherwise ask: What new stories need to be added? Describe the feature or requirements.
- Ask: Do these belong to an existing epic, or is a new epic needed?
- Ask: Is this linked to a change request? If so, provide the CR ID.
- Read relevant sections of the PRD for context — resolve via the sharded-fallback rule (ADR-069 / FR-396..402): first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, read `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). Focus on NEW requirements if prd_diff is available.
- Read relevant sections of `.gaia/artifacts/planning-artifacts/architecture.md` for technical context -- focus on changes if arch_diff is available.

### Step 3 -- Epic Decision

- Analyze the new requirements against existing epics.
- For each requirement cluster, determine fit:
  - Extends existing epic: new stories naturally belong under an existing epic's theme/goal
  - New epic needed: the feature is a distinct capability that doesn't fit any existing epic
  - Mixed: some stories extend existing epics, others need a new epic
- Present recommendation and ask for user confirmation.

### Step 4 -- Create New Epic (if needed)

- Skip if all new stories fit into existing epics.
- Auto-increment epic ID from highest existing (e.g., if E2 exists, new epic is E3).
- Define epic with: name, description, goal, success criteria, estimated story count.
- Present epic definition to user for confirmation.

### Step 5 -- Define New Stories

- For each new story:
  - Title using "As a [user], I want to [action] so that [benefit]"
  - Description with context
  - Acceptance criteria (AC1, AC2, etc.)
  - Size: S/M/L/XL
  - Priority: P0/P1/P2
  - Assign to correct epic (existing or newly created)
  - Auto-increment story ID within the epic
- Resolve the test-plan via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): try `.gaia/artifacts/test-artifacts/test-plan.md` (flat layout); fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` (strategy/ placement). If the resolved file exists: apply risk levels (high/medium/low) based on architectural complexity and test coverage.
- Declare depends_on and blocks against ALL existing stories.
- ENFORCE PROTECTION: dependency links FROM new stories TO locked/protected stories are allowed (read-only reference). But locked/protected stories themselves are NEVER modified.
- Verify no circular dependencies introduced.
- If CR ID provided, add Source: CR-{cr_id} to each story.

### Step 6 -- Protection Validation

- Scan all proposed changes against the protection map from Step 1.
- Verify: ZERO modifications to stories with status in-progress, review, ready-for-dev, done, or invalid.
- If any backlog or validating story would be modified: present the specific change and ask for explicit user confirmation with documented reason.
- Display protection report.
- If any protection violation detected: HALT -- do not proceed until resolved.

### Step 7 -- Append to Epics and Stories

- If new epic created: append entire epic section at end of document with all new stories.
- If adding to existing epic: append new stories after the last story in that epic.
- Add change log entry: date, feature name, CR ID (if applicable), epics affected, stories added.
- Write the updated `.gaia/artifacts/planning-artifacts/epics-and-stories.md`.
- Recount epic overview table story counts and update in-place.

### Step 8 -- Inline Validation

- Check Val prerequisites (validator.md and validator-sidecar/ must exist).
- For each newly created story, run inline validation (up to 3 attempts per story).
- Separate findings by severity: CRITICAL/WARNING trigger fix loop, INFO is non-blocking.
- Report batch validation summary.

### Step 9 -- Next Steps

- Report summary: new epic(s) created (if any), stories added with IDs and epic assignments.
- For each new story: "Run /gaia-create-story {story_key} to elaborate before development."
- If stories should enter current sprint: "Run /gaia-correct-course to inject into sprint."
- If stories should wait: "Stories are in backlog. Include in next /gaia-sprint-plan."
- Recommend: "Run /gaia-trace to update traceability matrix with new stories."

### Step 10 -- Re-shard touched documents (E53-S244, ADR-070)

Appending stories to the epics-and-stories monolith MUST be followed by a re-shard so the per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` stay aligned with the monolith. This step honours the monolith-vs-shard sync contract in ADR-070 (extended in E53-S243) — it is not optional unless the user passes `--monolith-only` for an explicit atomic same-PR edit.

- If `$ARGUMENTS` contains `--monolith-only`: skip this step entirely. The user takes responsibility for re-running `/gaia-shard-doc` (or merging shards back to the monolith) before commit. Record `reshard: skipped (--monolith-only)` in the cascade summary.
- Otherwise, invoke `/gaia-shard-doc .gaia/artifacts/planning-artifacts/epics-and-stories.md` (or the canonical monolith path resolved at runtime). The skill writes to `.gaia/artifacts/planning-artifacts/epics/` — `01-change-log.md` and per-epic `NN-eNN-...md` shards.
- After the re-shard returns, run `${CLAUDE_PLUGIN_ROOT}/scripts/check-monolith-shard-sync.sh` against the project root. The check is advisory (always exits 0). If it emits any `WARNING` lines naming `epics-and-stories.md`, surface those WARNINGs to the user — they indicate the re-shard did not converge and the user must investigate before commit.
- Record `reshard: invoked (gaia-shard-doc)` in the cascade summary so the audit trail captures the invocation.

This step runs in YOLO mode automatically — re-sharding is deterministic per ADR-042 and needs no user prompt. It is purely additive: skills that did not previously include this step continue to function for backwards compatibility (AC8 of E53-S244).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-stories/scripts/finalize.sh
