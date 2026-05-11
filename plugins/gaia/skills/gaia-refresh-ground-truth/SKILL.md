---
name: gaia-refresh-ground-truth
description: Rescan the filesystem and update ground-truth.md in the validator sidecar -- discovers project structure, file inventory, and key metadata, then writes a diff report of what changed. Use when "refresh ground truth" or /gaia-refresh-ground-truth.
argument-hint: "[--agent val|theo|derek|nate|all] [--incremental]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-refresh-ground-truth/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh validator all

## Mission

You are **Val**, the GAIA Ground Truth Manager, performing a filesystem rescan to update ground-truth.md. Your job is to discover the current project structure, file inventory, and key metadata using Glob and Read tools, compare against the prior ground-truth snapshot, and write an updated ground-truth file with a diff report of what changed.

This skill is the native Claude Code conversion of the legacy val-refresh-ground-truth workflow (E28-S79, Cluster 10 Val Cluster). The scanner runs with ground-truth loaded via `memory-loader.sh` (ADR-046 hybrid memory loading).

## Critical Rules

- Ground truth accuracy is foundational -- every other Val workflow depends on it
- Never silently delete entries -- mark removed files with REMOVED status and detection date
- Always verify claims against the filesystem using Glob and Read tools -- no trust, no assumptions
- Write ground-truth.md to `_memory/validator-sidecar/ground-truth.md` in the format expected by `memory-loader.sh` (ADR-046)
- The ground-truth format MUST include: `# Ground Truth` header, `<!-- last-refresh: ... -->` timestamp, `<!-- mode: full|incremental -->`, `<!-- entry-count: N -->` metadata comments, and structured `**[category]**` entries with `Source:` and `Verified:` lines
- On first scan when no prior ground-truth exists: create ground-truth.md from scratch with full scan results and report "initial scan -- no prior baseline" in the diff report
- On empty or minimal project (no scannable files): complete with an empty or minimal ground-truth, diff shows no meaningful content, no error
- On write failure (locked or unwritable ground-truth file): report write error with a clear error message including the path and OS error, do not silently drop updates
- When rescan finds no changes from last ground-truth snapshot: diff report explicitly states "No changes detected since last scan", ground-truth timestamp updated but content unchanged
- On legacy or incompatible ground-truth format: overwrite with correctly formatted output matching the memory-loader.sh schema, log warning about format migration
- Apply scan depth limits for large projects: cap file scanning at 500 files per Glob pattern. If a pattern returns more than 500 results, sample the first 500 and log a warning about truncation. This prevents token budget exhaustion during rescan
- If validator-sidecar directory does not exist: Create the directory and ground-truth.md, proceed normally
- If setup.sh exits with non-zero status: abort before rescan runs; error message includes setup.sh exit code and stderr. If setup.sh or finalize.sh is missing, log warning and fall back to inline logic -- do not halt on missing shared scripts alone
- Dual-refresh: when `{project-path}` differs from `{project-root}`, BOTH the runtime sidecar and the committed seed MUST be refreshed. The committed seed MUST preserve the empty-seed invariant (entry_count: 0, estimated_tokens: 0) per E28-S31
- Show section-by-section progress during scanning
- Behavior must be identical whether called standalone or as sub-step from another workflow

## Steps

### Step 1 -- Resolve Agent Target

- Parse arguments for `--agent` value. If `--agent` is absent, default to "val" for backward compatibility.
- Validate agent name against allowed values: val, theo, derek, nate, all.
  If the agent name is not in the allowed values list: fail with "Unknown agent '{agent_name}'. Valid values: val, theo, derek, nate, all."
- Resolve target sidecar path based on agent:
  - val: `_memory/validator-sidecar/`
  - theo: `_memory/architect-sidecar/`
  - derek: `_memory/pm-sidecar/`
  - nate: `_memory/sm-sidecar/`
  - all: run sequentially for val, theo, derek, nate (see Step 10)
- Check if `--incremental` flag was passed. If yes, set mode to incremental (only scan files modified since last-refresh timestamp). If no, set mode to full.

### Step 2 -- Initialize Sidecar Directory

- Check if the resolved target sidecar directory exists (e.g., `_memory/validator-sidecar/` for val).
- If the directory does not exist: Create the sidecar directory. This handles AC-EC7 -- missing validator-sidecar.
- If `ground-truth.md` does not exist in the sidecar: this is a first scan (AC-EC1). Create an empty ground-truth.md with header containing `last-refresh: never`.
- If `decision-log.md` does not exist: create with header `# {agent_display_name} Decision Log`.
- If `conversation-context.md` does not exist: create with header `# {agent_display_name} Conversation Context`.

### Step 3 -- Parse Previous State

- Read existing `ground-truth.md` from the resolved target sidecar directory.
- Extract `last-refresh` timestamp from header comment.
- Parse all existing entries into a lookup map keyed by category tag (e.g., `[file-inventory]`, `[planning-baseline]`) for diff comparison.
- If the existing file has no prior entries or is a first scan (last-refresh: never): note that diff report will show "initial scan -- no prior baseline".
- If incremental mode: filter scan targets to only files modified after last-refresh timestamp.

### Step 3a -- Load entry structure (canonical schema)

Before any scanning runs, load the canonical ground-truth entry schema. Every entry produced by Step 4 (Scan Inventory Targets) and every entry preserved or rewritten by Step 6 (Write Ground Truth) MUST conform to this schema. Centralising the schema here prevents drift between agents and between full / incremental refresh modes.

Canonical entry shape (memory-loader.sh compatible):

- `id` -- stable identifier for the entry within its category (e.g., file path, ADR id, story key). Required.
- `category` -- bracketed category tag rendered in ground-truth.md as `**[<category>]**` (e.g., `[file-inventory]`, `[planning-baseline]`, `[adr-baseline]`). Required.
- `source` -- path or reference where the entry was discovered (rendered as `Source: <path>` in ground-truth.md). Required.
- `verified` -- ISO-8601 date the entry was verified during this refresh (rendered as `Verified: <date>`). Required.
- `status` -- one of ACTIVE | UPDATED | REMOVED. Required. REMOVED entries also carry a `detected: <date>` line per Step 5.
- `metadata` -- optional category-specific fields (file size, language, dependency version, ADR id, etc.). Optional, free-form, must be deterministic so diffs are reproducible.

Hold this schema in working memory for the remainder of the refresh. Subsequent steps reference it as the single source of truth -- Step 4 emits entries shaped by this schema, Step 5 classifies them by `status`, Step 6 serialises them with the documented field labels, and Step 8 diffs entries by `id` within `category`.

### Step 4 -- Scan Inventory Targets

Use Glob to discover project structure and Read to extract metadata from key files.

**Exclusion list** -- ALWAYS exclude these directories and files from scanning:
`_gaia/`, `.claude/`, `bin/`, `_memory/`, `node_modules/`, `.git/`, `build/`, `dist/`, `.DS_Store`, `*.lock`

**For agent = val** (6-target scan):

1. **Project Source Files**: Glob `{project-path}/**/*` (excluding exclusion list). Extract file inventory, directory structure, languages used. Report: "Scanning project source files... found N files across N directories."
2. **Project Config Files**: Glob `{project-path}/*.{json,yaml,yml,toml,xml}` (root-level). Extract config keys, settings. Report: "Scanning project config files... found N config files."
3. **Package Manifests**: Glob for `package.json`, `pubspec.yaml`, `pom.xml`, `build.gradle`, `requirements.txt`, `Cargo.toml`, `go.mod`. Extract dependencies, versions. Report: "Scanning package manifests... found N manifests."
4. **Planning Artifacts**: Glob `docs/planning-artifacts/*.md`. Extract artifact names, types. Report: "Scanning planning artifacts... found N artifacts."
5. **Implementation Artifacts**: Glob `docs/implementation-artifacts/epic-*/stories/**/*.md` (canonical nested layout per E79) AND `docs/implementation-artifacts/*.md` (legacy flat fallback until E79-S6 backfill completes). Extract artifact names, story keys. Report: "Scanning implementation artifacts... found N artifacts."
6. **Test Artifacts**: Glob `docs/test-artifacts/*.md`. Extract artifact names, coverage areas. Report: "Scanning test artifacts... found N artifacts."

**For agent = theo**: Filesystem structure scan + architecture.md ADR extraction.
**For agent = derek**: PRD + epics-and-stories + sprint-status scan.
**For agent = nate**: Sprint-status + story files scan.

**Scan depth limit** (AC-EC6): Cap each Glob pattern at 500 results. If truncated, log: "Scan truncated at 500 files for pattern {pattern}. Results may be incomplete."

### Step 5 -- Compare and Detect Changes

- Compare scan results against previous state from Step 3.
- Classify each entry as:
  - **ADDED**: new file/entry not in previous state
  - **UPDATED**: file exists but metadata changed (count, version, structure)
  - **UNCHANGED**: no changes detected
- In full mode: for entries in previous state not found in scan results, mark as REMOVED with detection date. Do NOT silently delete entries.
- In incremental mode: skip deletion detection (documented limitation).

### Step 6 -- Write Ground Truth

- Write updated `ground-truth.md` to the resolved target agent's sidecar directory.
- Format MUST match memory-loader.sh expectations:
  ```
  # Ground Truth
  <!-- last-refresh: {ISO-8601-timestamp} -->
  <!-- mode: {full|incremental} -->
  <!-- entry-count: {N} -->
  <!-- refreshed-by: gaia-refresh-ground-truth -->
  ```
- Organize entries by category with `**[category]** description` format.
- Each entry includes `Source:` path and `Verified:` date.
- Preserve REMOVED entries with their detection dates.
- If write fails (AC-EC3): report error with path and OS error detail. Do not silently drop.

### Step 7 -- Dual-Write Committed Seed (if applicable)

- Resolve committed seed path: `{project-path}/_memory/{agent-sidecar}/ground-truth.md`.
- If `{project-path}` resolves to `{project-root}` (single-location layout): SKIP -- no mirror to refresh.
- If committed seed file is missing: HALT with error about missing committed seed.
- Update only the `last_refresh` timestamp in the committed seed frontmatter.
- ENFORCE empty-seed invariant: `entry_count: 0` and `estimated_tokens: 0` MUST be preserved. Never copy runtime entries into the committed seed.
- Post-write verification: assert entry_count == 0 and estimated_tokens == 0.

### Step 8 -- Generate Diff Report

- Generate a structured diff report summarizing changes since last refresh.
- Include counts by category: added, removed, updated entries.
- Include total entry-count across all categories.
- Format: "Added: N new entries. Removed: N entries. Updated: N entries. Total entries: N."
- If no changes detected (AC-EC4): report "No changes detected since last scan."
- If first scan (AC-EC1): report "initial scan -- no prior baseline. Total entries: N."
- Present the full diff report to the user.

### Step 8a -- Post-refresh token-budget check (archival guidance)

After Step 6 has written the updated ground-truth.md, perform an explicit post-refresh token-budget check. This step MUST run for every refreshed agent so each refresh emits one budget line per agent and surfaces archival guidance when a Tier 1 agent approaches the configured threshold.

Inputs (read from `_memory/config.yaml`):

- `tiers.tier_1.session_budget` -- canonical session-token budget for the agent's tier (Tier 1 agents only carry an enforceable budget here; Tier 2 / Tier 3 budgets, when enforced, come from the matching `tiers.<tier>.session_budget`).
- `archival.budget_warn_at` -- decimal warning threshold (default `0.8` -- 80% of budget). Read this value -- never hard-code it.
- `archival.token_approximation` -- chars-per-token ratio (default `4`). Apply the standard formula `tokens = chars / token_approximation` -- the same approximation used elsewhere in GAIA memory-budget reporting.
- `agents.<agent-id>.sidecar` -- resolved sidecar path. Use the resolved path (matches Step 1 of this skill); never guess from the agent id.

Per-agent procedure (run for every agent refreshed in Steps 2-9):

1. Stat the just-written `ground-truth.md` for the resolved sidecar and capture its size in characters.
2. Estimate token usage: `used = ground_truth_chars / archival.token_approximation`.
3. Resolve the budget: for Tier 1 agents use `tiers.tier_1.session_budget` (or `agents.<agent-id>.ground_truth_budget` when present). For Tier 2 use `tiers.tier_2.session_budget`. For Tier 3 / untiered (`session_budget: null`), report the actual usage with `(no budget enforced)` and skip threshold logic.
4. Compute percentage: `pct = round((used / budget) * 100)`.
5. Emit a per-agent budget line in the format `<agent>: <used>/<budget> tokens (<pct>%)`.
6. Threshold check (Tier 1 only -- Tier 2 reports the line but does not fire archival guidance unless its tier opts in): if `(used / budget) >= archival.budget_warn_at`, emit archival guidance immediately after the budget line. The guidance MUST:
   - Name the affected agent and current usage.
   - Reference the `budget_warn_at` threshold (e.g., `>= 80% of session_budget (budget_warn_at=0.8)`).
   - Point to archival next steps -- the `_memory/<agent>-sidecar/archive/` directory and the `/gaia-memory-hygiene` workflow for archival recommendations and confirmed archival actions.
   - Use a fixed phrasing template so the audit grep TC-GR37-23 matches both `budget_warn_at` and the archival guidance text in the same proximity.
7. Log every per-agent line to the diff report appended to `decision-log.md` in Step 9.

Reference template for the archival guidance line (sample text emitted to the user when threshold tripped):

```
WARN: <agent> ground-truth at <pct>% of session_budget (>= budget_warn_at=<threshold>). Archival guidance: review oldest entries via /gaia-memory-hygiene; archive candidates land in _memory/<agent>-sidecar/archive/ (gitignored). Re-run /gaia-refresh-ground-truth after archival to confirm the budget recovers.
```

Wording must remain stable across releases so the audit grep stays green; coordinate edits with `gaia-memory-hygiene/SKILL.md` to keep archival-pointer phrasing aligned (E52-S7).

### Step 9 -- Log to Decision Log

- Append the diff report to the target agent's `decision-log.md` in the resolved sidecar directory.
- Format: `## Refresh -- {date} ({mode}) -- Agent: {agent_name}\n{summary}`
- Never write to another agent's decision-log -- cross-agent write isolation.

### Step 10 -- Orchestrate --agent all (if applicable)

- If `--agent all` was specified: run refresh sequentially for each agent in order: val, theo, derek, nate.
- Each agent's refresh completes fully (Steps 2-9) before the next begins.
- On per-agent failure: log error with reason, continue with remaining agents.
- After all agents complete: present combined summary with per-agent status.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-refresh-ground-truth/scripts/finalize.sh
