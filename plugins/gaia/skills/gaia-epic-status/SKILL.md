---
name: gaia-epic-status
description: "Display an epic completion dashboard showing per-epic completion percentages and per-status story counts. Reads epics-and-stories.md and sprint-status.yaml (read-only). Falls back to scanning individual story files when sprint-status.yaml is missing. GAIA-native replacement for the legacy epic-status XML engine workflow."
argument-hint: "[epic-key?]"
allowed-tools: [Read, Bash]
version: "1.0.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-epic-status/scripts/setup.sh

## Mission

Display an epic completion dashboard by reading `.gaia/artifacts/planning-artifacts/epics-and-stories.md` and `.gaia/state/sprint-status.yaml`. When an optional epic key argument is provided (e.g., `E28`), filter the dashboard to show only that epic. This skill is read-only — it NEVER writes to any artifact file.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/epic-status/` XML engine workflow (brief Cluster 8, story E28-S62). Follows ADR-042 (scripts-over-LLM) where applicable, but dashboard rendering uses LLM-layer markdown table output per the story's technical notes.

## Critical Rules

- NEVER write to `sprint-status.yaml`, `epics-and-stories.md`, or any story file. This skill is strictly read-only.
- If `sprint-status.yaml` is missing or unreadable, fall back to scanning individual story files in `.gaia/artifacts/implementation-artifacts/` to derive per-story status. Do NOT crash or error — the story file is the source of truth per CLAUDE.md Sprint-Status Write Safety.
- Percentage rounding: use integer percentages (floor) to avoid noisy decimals.
- Empty-epic handling: epics with zero stories render as `0 / 0 (---)` to make the placeholder obvious.
- When an epic key filter is provided, render only the matching epic row. If the key does not match any epic, inform the user and list available epic keys.

## Steps

### Step 0 — Delegate rendering to the formatter (preferred, ADR-042)

> **Test10 F-30:** This skill now has a deterministic formatter (`epic-status-dashboard.sh`), aligning with ADR-042 (scripts-over-LLM) — the same shape as `sprint-status-dashboard.sh`.

Preferred invocation:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/epic-status-dashboard.sh [--epic "$EPIC_KEY"]
```

The formatter handles parsing (accepting `## E{N} — Title`, `## E{N} - Title`, and `## Epic {N}: Title` heading forms — Test10 F-30 em-dash drift fix), reads `sprint-status.yaml`, falls back to story-file scan, computes per-epic metrics, and renders the markdown dashboard to stdout. If the script exits non-zero, surface stderr verbatim — do NOT fall back to inline LLM rendering.

Steps 1–4 below remain documented for fallback use when the script is unavailable or for emergency manual inspection — they MUST NOT be the default path.

### Step 1 --- Parse Epics from epics-and-stories.md

Read `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/epics-and-stories.md`.

Parse the "Epic Overview" table to extract:
- Epic key (e.g., `E1`, `E28`)
- Epic name
- Story count per epic

Then scan the document body for each epic's story list. For each epic section (headed `## Epic {key}` or similar), extract all story keys (pattern: `{epic_key}-S{number}`).

### Step 2 --- Resolve Per-Story Status

**Primary path:** Read `${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-status.yaml`.
- Parse the `stories:` array
- Map each story key to its `status` field

**Fallback path (sprint-status.yaml missing or unreadable):**
- Scan `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/` for files matching `E*-S*-*.md`
- For each story file, read the YAML frontmatter and extract the `status` field
- Display a notice: "sprint-status.yaml not found --- deriving status from individual story files."

For stories that exist in epics-and-stories.md but have no status in either source, treat them as `backlog` (implicit default).

### Step 3 --- Compute Per-Epic Metrics

For each epic, compute:
- **Total stories**: count of all stories belonging to the epic
- **Done stories**: count of stories with status `done`
- **Completion percentage**: `floor(done / total * 100)` --- use `0 / 0 (---)` for epics with zero stories
- **Per-status counts**: count stories in each status bucket: `backlog`, `ready-for-dev`, `in-progress`, `review`, `done`, `blocked`

If an epic key filter was provided, compute metrics only for the matching epic.

### Step 4 --- Render Dashboard

Render a markdown dashboard table with the following columns:

```
| Epic | Name | Done | Total | % | Backlog | Ready | In-Prog | Review | Done | Blocked |
```

Sort epics by their numeric key (E1 before E2 before E28).

After the table, render a summary line:
```
Overall: {total_done} / {total_stories} stories done ({overall_pct}%)
```

Present the dashboard output to the user.

### Step 5 --- Suggest Next Actions

Based on the dashboard:

- If any epic has stories in `ready-for-dev`: suggest `/gaia-dev-story {story_key}` for the highest-priority story.
- If any epic has stories in `review`: suggest `/gaia-run-all-reviews {story_key}`.
- If all stories across all epics are `done`: suggest `/gaia-retro` for a retrospective.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-epic-status/scripts/finalize.sh
