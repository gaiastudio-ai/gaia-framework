---
name: gaia-memory-management
description: Core memory operations used by every GAIA agent — session load/save, decision-log formatting (ADR-016), context summarization, stale detection, deduplication, and budget monitoring. Cross-agent extensions (cross-reference loading, shared budget monitoring) live in the companion skill gaia-memory-management-cross-agent.
version: '1.1'
applicable_agents: [all]
sections: [decision-formatting, session-load, session-save, context-summarization, stale-detection, deduplication, budget-monitoring]
allowed-tools: [Read, Write, Edit, Grep]
orchestration_class: light-procedural
---

<!-- Converted under ADR-041 (Native Execution Model). Source: _gaia/lifecycle/skills/memory-management.md. -->

## Mission

Provide the canonical read/write operations over per-agent memory sidecars (`decision-log.md`, `conversation-context.md`, and the optional third file — typically `ground-truth.md` for Tier 1 agents). This is the most-referenced lifecycle skill: the workflow-engine session-save path and `gaia-create-story` Step 4b both load specific sections of this skill by ID.

Every section marker below is part of the public JIT contract consumed by callers such as:

- The session-save path in the native Claude Code skill runtime (loads `decision-formatting`, `context-summarization`, and `session-save` JIT when a workflow ends)
- Tier-based session load invoked by the skill runtime when an agent is adopted (loads `session-load`)
- Memory-hygiene skills (load `stale-detection` and `deduplication`)
- Budget-sensitive save paths (load `budget-monitoring`, which is also replicated in the companion cross-agent skill)

Sections are resolved by scanning for `<!-- SECTION: {id} -->` and `<!-- END SECTION -->` markers in this file — there is no external engine or Step number to consult. This is the ADR-041 native execution contract (introduced when the legacy XML-engine workflow layer was retired under E28-S126).

Section IDs MUST match exactly. Renaming or merging sections is a breaking change.

## Critical Rules

- **Decision entries follow ADR-016.** Every write through `session-save` formats entries per the `decision-formatting` section — never invent a new shape.
- **Missing sidecars are not errors.** `session-load` returns empty structures when the directory or files are absent. Never create empty sidecar files eagerly.
- **Full-file read/write only.** Decision logs use read-entire → append-in-memory → write-entire. Never stream-append or partially write; last-writer-wins is the documented concurrency model.
- **Budget is config-driven.** All thresholds (`budget_warn_at`, `budget_alert_at`, `budget_archive_at`, `token_approximation`, `archive_subdir`) come from `.gaia/memory/config.yaml`. Never hardcode.
- **Untiered / Tier-3 agents skip budget enforcement.** Return no-op, never error.
- **Companion skill:** cross-reference loading across agent sidecars (read-only) lives in `gaia-memory-management-cross-agent` — load that skill when a caller needs `<memory-reads>` resolution.

<!-- SECTION: decision-formatting -->
## Decision Entry Format (ADR-016)

All decision-log entries use this standardized format:

```markdown
### [YYYY-MM-DD] Decision Title

- **Agent:** {agent ID}
- **Workflow:** {workflow name}
- **Sprint:** {sprint ID}
- **Type:** architectural | implementation | validation | process
- **Status:** active | superseded | archived
- **Related:** {artifact paths, story keys}

{Decision body — free-form markdown with no structural constraints}
```

**Required vs optional fields:**
- **Required:** Agent, Status — a warning should be logged if these are absent
- **Optional:** Workflow, Sprint, Type, Related — these default gracefully (empty/null) when missing; the entry remains parseable

**Decision types:**
- `architectural` — system structure, technology choices, ADR-level decisions
- `implementation` — coding patterns, library usage, algorithm choices
- `validation` — test strategies, quality thresholds, coverage decisions
- `process` — workflow changes, ceremony adjustments, team agreements

**Status values:**
- `active` — current, in effect
- `superseded` — replaced by a newer decision (link to replacement)
- `archived` — no longer applies, retained for history

**Field constraints:**
- Date: ISO 8601 strict (YYYY-MM-DD). Malformed dates (e.g., `[2026-3-5]`) should trigger a warning and best-effort parsing rather than silently dropping the entry. Entries with unrecoverable dates use `[YYYY-MM-DD-UNKNOWN]` as placeholder.
- Agent: must match an agent ID from the agent manifest
- Sprint: sprint ID from sprint-status.yaml, or "pre-sprint" if decided outside a sprint
- Related: comma-separated list of artifact paths or story keys (e.g., `.gaia/artifacts/planning-artifacts/architecture.md, E3-S1`)
<!-- END SECTION -->

<!-- SECTION: session-load -->
## Session Load

Load agent memory from a sidecar directory. Agent-agnostic — takes sidecar path and tier config as inputs.

**Parameters:**
- `sidecar_path` — absolute path to the agent's sidecar directory
- `tier_budget` — session token budget (Tier 1: 300K, Tier 2: 100K, Tier 3: no explicit budget)
- `recent_n` — number of recent decision entries to load (default: 20)

**Procedure:**
1. Check if `sidecar_path` directory exists
2. If directory does not exist: return empty data structures (empty decision log, empty conversation context, empty third file) without errors and do not create any files or directories
3. If directory exists, read up to 3 files:
   - `decision-log.md` — parse entries using the ADR-016 standard format (date, agent ID, workflow, sprint, type, status, related, body). Load the most recent `recent_n` entries that fit within the tier token budget
   - `conversation-context.md` — load full content (Tier 1 and Tier 2 only)
   - Third file (agent-specific, e.g., `ground-truth.md`) — load if present, treat as opaque content
4. If any file is missing or empty: return an empty data structure for that file — no error, no file creation
5. Calculate total loaded tokens (approximate: character count / 4). If total exceeds `tier_budget`, trim oldest decision entries first

**Empty-state guarantees:**
- Missing directory → empty structures, no errors, no file creation
- Missing files → empty structures per file, no errors
- Empty files (0 bytes) → empty structures, graceful handling
<!-- END SECTION -->

<!-- SECTION: session-save -->
## Session Save

Persist agent session data to sidecar files. Agent-agnostic — takes sidecar path and tier config as inputs.

**Parameters:**
- `sidecar_path` — absolute path to the agent's sidecar directory
- `tier_budget` — session token budget for this agent's tier
- `new_entries` — list of decision entries to append (using ADR-016 standard format: date, agent ID, workflow, sprint, type, status, related, body)
- `context_summary` — compressed session summary for conversation-context.md
- `third_file_content` — updated content for agent-specific third file (optional)

**Procedure:**
1. Ensure `sidecar_path` directory exists (create if needed via `mkdir -p`)
2. **decision-log.md** — append new entries:
   - Read the entire file into memory (full-file read)
   - Append `new_entries` in memory
   - Write the entire file back (full-file write). Last writer wins for concurrent access
   - Never use partial writes or stream appends
3. **conversation-context.md** — replace (rolling summary, not append):
   - Write `context_summary` as the full file content (overwrites previous)
4. **Third file** — update if `third_file_content` provided:
   - Read entire file, replace in memory, write entire file back

**Token budget enforcement (before write):**
- Before writing, invoke the `budget-monitoring` section (from `memory-management-cross-agent.md`) to check projected usage against tier budget
- Pass: sidecar_path, tier_budget, projected_size (current size + new entries size)
- `budget-monitoring` returns the threshold status: ok, warn, alert, or archive_needed
- If `archive_needed`: move oldest N entries to `{sidecar_path}/{archive_subdir}/` subdirectory to make room, then re-check
- If user declines archival: force save anyway, exceeding the budget
- Never silently truncate or block a save operation
- See `budget-monitoring` section in `memory-management-cross-agent.md` for threshold definitions and config source
<!-- END SECTION -->

<!-- SECTION: context-summarization -->
## Context Summarization

Compress a full session into a concise summary for `conversation-context.md`. Runs at session save time.

**Output structure (2K token limit):**

```markdown
## Session Summary — [YYYY-MM-DD]

### What Was Discussed
- {bullet list of topics discussed during the session}

### Decisions Made
- {bullet list of decisions, each with brief rationale}

### Artifacts Modified
- {bullet list of files created, modified, or deleted with change summary}

### Pending / Next Steps
- {bullet list of unresolved items, open questions, follow-up work}
```

**Constraints:**
- Total summary must not exceed 2K tokens (~8,000 characters)
- Prioritize decisions and pending items over discussion topics when space is tight
- Each bullet should be one concise sentence
- Artifacts list includes file paths for traceability
- If the session had no decisions, omit that section rather than writing "None"
<!-- END SECTION -->

<!-- SECTION: stale-detection -->
## Stale Detection

Scan a decision log to identify entries that are stale, contradicted, or orphaned.

**Detection categories:**

1. **Stale entries** — decision references an artifact path that no longer exists on the filesystem
   - Check each path in the `Related` field against the filesystem
   - If the artifact is not found: flag as stale
   - Reason: "Referenced artifact not found: {path}"
   - Suggested action: `review` (may need update or removal)

2. **Contradicted entries** — two active decisions in the same sidecar that conflict
   - Compare active entries that reference the same artifact or topic
   - If decisions conflict (e.g., "use PostgreSQL" vs. "use MongoDB" for the same component): flag both
   - Reason: "Contradicts entry [{date}] {title}"
   - Suggested action: `review` (resolve which decision is current)

3. **Orphaned entries** — decision references a story or epic that has been removed from epics-and-stories.md
   - Extract story/epic keys from `Related` field
   - Check each key against `.gaia/artifacts/planning-artifacts/epics-and-stories.md`
   - If the key is not found: flag as orphaned
   - Reason: "Referenced story/epic {key} not found in epics-and-stories.md"
   - Suggested action: `archive` (decision is likely outdated)

**Output format:**

| # | Entry | Category | Reason | Suggested Action |
|---|-------|----------|--------|-----------------|
| 1 | [2026-03-01] Use PostgreSQL | stale | Referenced artifact not found: docs/old-schema.md | review |
| 2 | [2026-03-05] Use MongoDB | contradicted | Contradicts entry [2026-03-01] Use PostgreSQL | review |
| 3 | [2026-02-15] E99-S1 auth flow | orphaned | Referenced story/epic E99-S1 not found in epics-and-stories.md | archive |
<!-- END SECTION -->

<!-- SECTION: deduplication -->
## Deduplication

Detect and merge duplicate decision entries within a decision log.

**Duplicate detection:**

1. **Exact duplicates** — entries with the same artifact and same topic that address the same decision
   - Match on: same artifact path in `Related` + same topic keywords in title
   - If both are `active`: the newer entry supersedes the older

2. **Near-duplicates** — entries with different wording but identical decision substance
   - Match on: same artifact path + overlapping topic (>70% keyword overlap in title and body)
   - Near-duplicates require confirmation before merging — flag for review

**Merge protocol:**
- Newer entry is kept with status `active`
- Older entry is archived: set status to `superseded`, add note "Superseded by [{date}] {title}"
- Move archived entry to the `archive/` subdirectory if one exists
- If supersession is ambiguous (e.g., entries are from the same date, or address subtly different aspects): flag both for manual review rather than auto-merging

**Output:** List of duplicate pairs with recommended action (auto-archive or review).
<!-- END SECTION -->

<!-- Cross-agent extensions (cross-reference-loading) are in memory-management-cross-agent.md -->

<!-- SECTION: budget-monitoring -->
## Budget Monitoring

Calculate and report token budget usage per agent sidecar. Reusable by any workflow that needs budget status. All thresholds are config-driven — read from `.gaia/memory/config.yaml` archival block at runtime.

**Input:**
- Agent sidecar file sizes (bytes) from filesystem scan
- Tier budgets from `.gaia/memory/config.yaml`: `tiers.tier_1.session_budget` (300K), `tiers.tier_2.session_budget` (100K)
- Per-agent ground truth budgets: `agents.{agent-id}.ground_truth_budget` (Tier 1 only)

**Token calculation:**
- Approximate tokens = file size in bytes / 4 (chars-per-token convention)
- Sum across all sidecar files per agent (decision-log.md + conversation-context.md + ground-truth.md)

**Threshold classification (config-driven from `.gaia/memory/config.yaml`):**
- `budget_warn_at` — **warning:** at or above this fraction of budget (default: 0.8 = 80%)
- `budget_alert_at` — **critical:** at or above this fraction (default: 0.9 = 90%)
- `budget_archive_at` — **over-budget:** at or above this fraction (default: 1.0 = 100%) — triggers archival

When usage reaches `budget_archive_at`, archival is triggered: oldest entries are moved to `{sidecar_path}/archive/` to free budget.

**Tier handling:**
- Tier 1: report session budget usage and ground truth budget usage separately
- Tier 2: report session budget usage only (no ground truth file)
- Tier 3 / untiered: skip all budget enforcement — no threshold checks, no archival trigger. Return no-op status with no error. Untiered agents proceed without any budget constraint.

**Output format (Token Budget Table):**

| Agent | Tier | Files Scanned | Token Usage | Session Budget | GT Budget | % Used | Status |
|-------|------|---------------|-------------|----------------|-----------|--------|--------|

For Tier 3 and untiered agents, budget columns show "no budget enforced" with actual token count.
<!-- END SECTION -->
