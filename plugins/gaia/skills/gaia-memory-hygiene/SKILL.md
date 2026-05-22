---
name: gaia-memory-hygiene
description: Detect stale, contradicted, and orphaned decisions in agent memory sidecars. Use when "memory hygiene" or "clean sidecars" or /gaia-memory-hygiene. Runs dynamic sidecar discovery, tier-aware multi-file scanning, cross-reference validation against current planning and architecture artifacts, stale detection, classification, token-budget reporting, archival recommendations, ground-truth refresh triggers, and user-confirmed archival actions.
argument-hint: "[--dry-run]"
context: main
allowed-tools: [Read, Write, Edit, Bash, Grep]
model: inherit
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-memory-hygiene/scripts/setup.sh

## Mission

You are running a cross-sidecar hygiene pass across the project's agent memory. This skill discovers every `.gaia/memory/*-sidecar/` directory, classifies each sidecar by tier, scans each decision-log / ground-truth / conversation-context file under strict JIT discipline, cross-references decisions against current planning and architecture artifacts, classifies each entry into one of five statuses (ACTIVE, STALE, CONTRADICTED, ORPHANED, UNVERIFIABLE-FORMAT), reports token-budget pressure per agent, recommends archival for budget / staleness / age, triggers ground-truth refresh for lagging Tier 1 agents, and — only with explicit per-entry user confirmation — applies Keep / Archive / Delete actions to sidecar files.

This skill is the native Claude Code conversion of the legacy `memory-hygiene` workflow (E28-S107, Cluster 14). The 12-step prose structure, JIT discipline, cross-reference cap, token approximation, and 7-section enhanced report layout are preserved from the legacy `instructions.xml` — parity confirmed per NFR-053.

**Main context semantics (ADR-041):** This skill runs under `context: main`. It reads `.gaia/memory/` (canonical, post-ADR-111; falls back to legacy `_memory/` only on pre-migration projects), reads `.gaia/artifacts/planning-artifacts/`, `.gaia/artifacts/implementation-artifacts/`, `.gaia/artifacts/test-artifacts/`, and writes a hygiene report plus (on user confirmation) targeted sidecar edits.

**Scripts-over-LLM (ADR-042 / FR-325):** Deterministic foundation operations (config resolution, checkpoint writes, lifecycle events) are delegated to `plugins/gaia/scripts/` via inline `!${CLAUDE_PLUGIN_ROOT}/...` calls. Agent sidecar reads use the hybrid memory-loading pattern (ADR-046).

**Hybrid memory loading (ADR-046):** Where per-agent sidecar content needs to be read, the skill invokes `!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent_name> <tier>` where `<tier>` is one of `decision-log`, `ground-truth`, or `all` (see E28-S13 AC1 for the canonical loader signature). Sidecar directory names are resolved from `.gaia/memory/config.yaml` `agents.{id}.sidecar` — never hard-coded.

## Critical Rules

- **User-initiated cross-sidecar reads are explicitly allowed** per the agent-specification protocol. This skill is the canonical cross-sidecar reader.
- **Never modify a sidecar file without explicit user confirmation for each entry.** Archival is recommendation-only; deletion requires per-entry confirmation.
- **Preserve the sidecar file header and marker comment** in all modifications. The `<!-- Decisions will be appended below this line -->` marker and the file title / description block are invariant.
- **Process sidecars one at a time.** Release previous sidecar content from active context before loading the next (JIT). This is the per-sidecar token budget discipline that keeps the skill within the NFR-048 activation budget.
- **Archival is never auto-executed.** All recommendations require user confirmation per entry before any file changes are made.
- **Cross-reference validation scope is limited to the declared matrix** in `.gaia/memory/config.yaml` under `cross_references:`. Do NOT traverse arbitrary cross-agent reads — the matrix is the authoritative boundary.
- **Token approximation is 4 chars per token** (file size in bytes / 4). This value is read from `.gaia/memory/config.yaml` `archival.token_approximation` — the skill does not hard-code the ratio.
- **Sprint-status.yaml is NEVER written by this skill** (Sprint-Status Write Safety rule). The skill only reads sprint-status.yaml for current sprint ID.
- **Graceful degradation (AC-EC10 — no _memory/ directory):** If `_memory/` does not exist at all, exit gracefully with the message "no sidecars discovered — `_memory/` directory not present" and do NOT create any files.
- **Token budget guard (AC-EC6, NFR-048):** Per-sidecar JIT release prevents accumulation. If a single decision-log exceeds the per-agent budget, flag the agent as over-budget in the Token Budget Table but complete the scan.
- **Fail-fast on missing foundation scripts (AC-EC2 equivalent):** `setup.sh` aborts with an actionable error identifying the missing / non-executable script path when `resolve-config.sh` is missing.

## Inputs

This skill accepts the following inputs (from `$ARGUMENTS` when invoked via slash command, or from interactive prompt otherwise):

1. **Mode** — `--dry-run` (optional). When set, the skill runs the full scan and report but skips Step 11 (User Action on Flagged Items) and Step 12 (Optional Checkpoint Pruning). Default: interactive mode.
2. **Execution mode** — `normal` (pause for per-entry review in Step 11) or `yolo` (only the safe default — still require per-entry confirmation; YOLO never auto-archives or auto-deletes sidecar content).

## Pipeline Overview

The skill runs twelve steps in strict order, mirroring the legacy `instructions.xml`:

1. **Dynamic Sidecar Discovery** — tier classification, legacy-filename detection, archive/ exclusion
2. **Tier-Aware Multi-File Scanning** — per-tier file enumeration with JIT release between sidecars
3. **Reference Artifact Loading** — architecture.md, prd.md, infrastructure-design.md, test-plan.md, sprint-status.yaml, epics-and-stories.md
4. **Cross-Reference Validation** — applies the `cross_references:` matrix from `.gaia/memory/config.yaml`
5. **Stale Detection** — reuses the `stale-detection` section of the shared memory-management skill
6. **Classify Entries** — assigns one of five statuses to every entry
7. **Token Budget Reporting** — reuses the `budget-monitoring` section of the shared memory-management skill
8. **Archival Recommendations** — budget pressure / staleness / age
9. **Ground Truth Refresh Trigger** — Tier 1 agents only (Val, Theo, Derek, Nate via config)
10. **Present Enhanced Report** — 7-section artifact written to `.gaia/artifacts/implementation-artifacts/memory-hygiene-report-{date}.md`
11. **User Action on Flagged Items** — Keep / Archive / Delete per entry
12. **Optional Checkpoint Pruning** — opt-in, user prompt

## Step 1 — Dynamic Sidecar Discovery

1. Read `.gaia/memory/config.yaml` to load:
   - Tier assignments (`tiers.tier_1.agents`, `tiers.tier_2.agents`, `tiers.tier_3.agents`)
   - Token budgets (`tiers.tier_1.session_budget`, `tiers.tier_2.session_budget`; Tier 3 has `session_budget: null` — no enforcement)
   - Cross-reference matrix (`cross_references:`)
   - Token approximation (`archival.token_approximation`, default 4 chars/token)
   - Budget warn threshold (`archival.budget_warn_at`, default 0.8)
2. For each agent, resolve the sidecar directory name from the `agents.{agent-id}.sidecar` field. If an agent has no explicit `agents.{id}.sidecar` entry, fall back to `{agent-id}-sidecar/`.
3. Enumerate all on-disk `.gaia/memory/*-sidecar/` directories.
4. Union the config-declared sidecars with the on-disk sidecars into a master list. For each sidecar, classify by tier:
   - Agent in `tiers.tier_1.agents` → **Tier 1** (3 files: `ground-truth.md`, `decision-log.md`, `conversation-context.md`)
   - Agent in `tiers.tier_2.agents` → **Tier 2** (2 files: `decision-log.md`, `conversation-context.md`)
   - Agent in `tiers.tier_3.agents` → **Tier 3** (1 file: `decision-log.md`)
   - Agent has on-disk sidecar but no tier in config → **Untiered** (scan `decision-log.md` only; no budget enforced)
5. Exclude `archive/` subdirectories from active scanning — these contain archived entries and are gitignored.
6. Build categorized sidecar lists:
   - Tier 1 sidecars with expected files
   - Tier 2 sidecars with expected files
   - Tier 3 sidecars with expected files
   - Untiered sidecars (decision-log.md only)
   - **Empty sidecars** — directories with no content files (AC-EC2: log "empty sidecar" and continue)
   - **Sidecars with legacy filenames** — `architecture-decisions.md` (architect), `infrastructure-decisions.md` (devops), `threat-model-decisions.md` (security), `velocity-data.md` (sm) — flag for migration to `decision-log.md` (AC-EC3)
7. **AC-EC10 — no _memory/ directory:** if the `_memory/` directory does not exist, report "no sidecars discovered — `_memory/` directory not present" and complete the skill. Do NOT create files.
8. **Zero-content short-circuit:** if every discovered sidecar is empty, report "All sidecars are empty — nothing to review" and complete the skill.
9. Report to user: `{N} sidecars discovered ({T1} Tier 1, {T2} Tier 2, {T3} Tier 3, {U} untiered), {E} empty. {L} legacy filenames detected. Proceeding with review.`

## Step 2 — Tier-Aware Multi-File Scanning (JIT)

For each sidecar in the master list, process one at a time (**JIT — release previous sidecar content from active context before loading the next**):

1. Determine the expected file list based on the sidecar's tier (from Step 1).
2. Read the sidecar content via the hybrid memory loader:
   - Tier 1: `!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent_name> all` (loads decision-log + ground-truth)
   - Tier 2: `!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent_name> decision-log`
   - Tier 3 / Untiered: `!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh <agent_name> decision-log`
   - When `conversation-context.md` is needed for Tier 1 / Tier 2, read it directly via `Read` (memory-loader.sh covers decision-log and ground-truth only per E28-S13 AC1).
3. For each expected file:
   - Check if the file exists.
   - If missing: log warning "Expected `{filename}` for {tier} agent `{agent}` — file not found" — not an error, record as `missing` in the content inventory.
   - If present: check for content beyond the template header (text after the marker comment `<!-- Decisions will be appended below this line -->`).
   - Record file size in bytes for token-budget calculation (Step 7).
4. **Legacy-filename detection (AC-EC3):** if a sidecar contains `architecture-decisions.md`, `infrastructure-decisions.md`, `threat-model-decisions.md`, or `velocity-data.md`, scan it as decision-log content and flag the entry for migration in the report.
5. Build the per-sidecar content inventory: `{file, size, tier, content_status}` where `content_status` is one of `has-content | empty | missing | legacy-name`.
6. Release the current sidecar's content from active context before loading the next — JIT discipline is mandatory for the NFR-048 token budget.

## Step 3 — Reference Artifact Loading

Attempt to read each reference artifact (record which exist and which are missing):

- `.gaia/artifacts/planning-artifacts/architecture.md` — for architectural decision validation
- `.gaia/artifacts/planning-artifacts/prd.md` — for product decision validation (per ADR-069 / FR-396..402, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` if the flat path is absent)
- `.gaia/artifacts/planning-artifacts/infrastructure-design.md` — for infrastructure validation
- `.gaia/artifacts/test-artifacts/test-plan.md` — for test strategy validation (per ADR-072 / AF-2026-05-08-5, fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` if the flat path is absent)
- `.gaia/artifacts/implementation-artifacts/sprint-status.yaml` — for sprint references and current sprint ID
- `.gaia/artifacts/planning-artifacts/epics-and-stories.md` — for story / epic key validation

For each artifact that exists: retain key sections for comparison in Steps 4, 5, 6, and 8.

Extract the current sprint ID from `sprint-status.yaml` if it exists. If not found, note `sprint data unavailable — will use 42-day calendar fallback for age calculations` (AC-EC4). The Ground Truth Refresh section (Step 9) is skipped when `sprint-status.yaml` is absent.

**If no reference artifacts exist:** warn the user "No reference artifacts found. Hygiene will be limited to structural checks and budget reporting."

## Step 4 — Cross-Reference Validation

For each sidecar with content (**JIT — release previous before loading next**):

Parse decision-log entries using the standardized format (E9-S3):

- Header: `### [YYYY-MM-DD] Decision Title`
- Fields: `Agent:`, `Sprint:`, `Status:` (`active | superseded | archived`), `Related:` (paths, keys, agent references)
- If an entry does not follow the standardized format (no `Status:` field, no `### ` header): flag as **UNVERIFIABLE-FORMAT**.

For entries with the `Status:` field:

- `Status: superseded` or `Status: archived` → flag the entry itself as already-archived (candidate for archive/ move)
- `Status: active` → validate the `Related:` field references.

For entries with `Related:` pointing to other agents' decisions:

- Use the **cross-reference matrix** from `.gaia/memory/config.yaml` (`cross_references:`) to determine valid cross-agent reads.
- For each cross-agent reference: look up the referenced entry's `Status:` in the source agent's decision-log (loaded via `memory-loader.sh <source_agent> decision-log`).
- If the referenced entry has `Status: superseded` or `Status: archived` → flag as **STALE** with evidence pointing to the superseded entry.
- If the referenced entry is not found → flag as **ORPHANED**.
- If the source agent's file is not parseable → flag the reference as **UNVERIFIABLE-FORMAT**.
- **AC-EC7 — circular Related-field references:** if agent A → agent B → agent A, the cross-reference scan terminates after one full pass. Do NOT traverse beyond one hop from the origin — the cross-reference cap guarantees no infinite loop.

For all entries: scan the `Related:` field for artifact paths and story / epic keys.

- Cross-reference paths against the filesystem — if not found, flag as potential **STALE** or **ORPHANED**.
- Cross-reference story / epic keys against `epics-and-stories.md` — if not found, flag as **ORPHANED**.
- For ORPHANED candidates: search for semantically similar names and suggest likely renames.

**AC-EC5 — cross-reference matrix missing:** if `cross_references:` is absent from `.gaia/memory/config.yaml`, the skill degrades to structural checks + budget reporting only. Log a warning "cross-reference matrix missing from `.gaia/memory/config.yaml` — skipping cross-agent validation" and do NOT crash.

**Cross-Agent Read Authorisation Matrix (FR-383):** the `cross_references:` block in `.gaia/memory/config.yaml` is the authoritative boundary for every cross-agent read this skill performs. The matrix authorises nine canonical reader contexts (each entry is a reader → source/file/mode triple):

- `architect` — reads `pm/decision-log` and `validator/ground-truth`
- `pm` — reads `architect/decision-log` and `sm/ground-truth`
- `sm` — reads `architect/decision-log`, `pm/decision-log`, and `validator/ground-truth`
- `orchestrator` — reads `validator`, `architect`, `pm`, and `sm` `conversation-context` (summary mode)
- `security` — reads `architect/decision-log` and `validator/ground-truth`
- `devops` — reads `architect/decision-log`
- `test-architect` — reads `architect/decision-log` and `validator/ground-truth`
- `validator` — reads `architect`, `pm`, and `sm` `decision-log` (full mode, capped at 50% of session budget)
- `dev-agents` — reads `validator/ground-truth` and `architect/decision-log`

The matrix is the cross-agent authorisation source of truth — the SKILL.md does NOT duplicate the triples; it points readers to `.gaia/memory/config.yaml#cross_references` as the single canonical record. Any reader / source / file combination NOT enumerated above is unauthorised by definition.

**Cross-agent authorisation gate (block-and-log):** before invoking `memory-loader.sh <source_agent> <file>` for ANY cross-reference, the skill MUST verify that the (reader, source_agent, file) triple is present in `.gaia/memory/config.yaml#cross_references`. If the triple is NOT present:

1. Skip the read — do NOT load the source agent's file.
2. Log the denial as `cross-ref denied: {reader} → {source}/{file} (not in matrix)` to the report's Detailed Findings (or to a "Cross-Ref Denials" sub-section if present).
3. Continue scanning the remaining entries — denial is non-fatal.

This block-and-log gate operationalises the existing "limited to the declared matrix" rule in the Critical Rules section. It does NOT replace AC-EC5: when `cross_references:` is absent entirely, the AC-EC5 graceful-degrade path still fires (warn and skip cross-agent validation; complete structural + budget reporting).

**AC-EC8 — Unicode / non-ASCII agent sidecar names:** path resolution preserves the original encoding (no re-encoding applied). The scan completes without raising encoding errors.

## Step 5 — Stale Detection via Shared Skill

JIT-load the `stale-detection` section from `_gaia/lifecycle/skills/memory-management.md`. Load only the content between `<!-- SECTION: stale-detection -->` and `<!-- END SECTION -->` markers.

Apply the canonical stale detection logic from the memory-management skill:

1. **Stale entries** — a decision references an artifact path that no longer exists on the filesystem.
2. **Contradicted entries** — two active decisions in the same sidecar that conflict.
3. **Orphaned entries** — a decision references a story or epic removed from `epics-and-stories.md`.

Merge stale detection results with cross-reference validation results from Step 4 — deduplicate entries flagged by both checks.

## Step 6 — Classify Entries

Assign each sidecar entry one of five statuses:

- **ACTIVE** — the entry is consistent with current reference artifacts; no action needed.
- **STALE** — the referenced artifact has changed or the cross-referenced decision is superseded / archived.
- **CONTRADICTED** — the current artifact explicitly states the opposite of what this entry records.
- **ORPHANED** — the component, service, story, or epic referenced no longer exists in any current artifact.
- **UNVERIFIABLE-FORMAT** — the entry does not follow the standardized format (no `Status:` field, no `### ` header) — cannot validate programmatically.

Record evidence for each classification: which artifact section confirms or contradicts, what changed, or what is missing.

## Step 7 — Token Budget Reporting via Shared Skill

JIT-load the `budget-monitoring` section from `_gaia/lifecycle/skills/memory-management.md`. Load only the content between `<!-- SECTION: budget-monitoring -->` and `<!-- END SECTION -->` markers.

Apply the budget-monitoring procedure using the file sizes from the Step 2 inventory and tier budgets from `.gaia/memory/config.yaml`:

- Calculate token usage per agent: sum sidecar file sizes and convert via the skill formula (default 4 chars/token from `archival.token_approximation`).
- Classify each agent by threshold status (**OK** / **warning** at ≥ 0.8 / **critical** at ≥ 0.9 / **over-budget** at ≥ 1.0).
- For Tier 1 agents: also report ground-truth budget usage separately.
- For Tier 3 / Untiered: report actual tokens with "no budget enforced".

Build the **Token Budget Table** per the skill's output format.

## Step 8 — Archival Recommendations

Generate archival recommendations based on three criteria:

1. **Budget pressure** — for agents at or above 90% of budget: identify oldest entries as archival candidates (oldest first). Mark as `actionable — budget pressure`.
2. **Staleness** — entries with `Status: superseded` or `Status: archived` that have not been moved to the `archive/` subdirectory. Mark as `actionable — stale status`.
3. **Age** — entries older than 3 sprints (determined from the current sprint ID minus 3; fallback to 42 calendar days if no sprint data — AC-EC4). Only flag if the entry has no `Related:` field pointing to an active story. Mark as `advisory — age`.

Classify each recommendation:

- **Actionable** — budget pressure and staleness recommendations should be acted on.
- **Advisory** — age-based recommendations are informational; the user decides.

**Per-item estimated token recovery (FR-383):** every archival recommendation row MUST carry an explicit per-item token recovery estimate — averages or aggregate-only counts are NOT sufficient. Compute the estimate as `Estimated recovery: ~{N} tokens` where:

- `{N}` = `bytes / token_approximation` rounded to the nearest integer
- `bytes` is the on-disk byte size of the candidate entry (from the Step 2 content inventory)
- `token_approximation` is the value loaded from `.gaia/memory/config.yaml` `archival.token_approximation` (default 4 chars/token)

Reuse the same `archival.token_approximation` ratio that drives the Step 7 Token Budget Table — do NOT hard-code a different ratio in archival recommendations. The two outputs share a single source of truth.

Example: a stale entry of 640 bytes flagged for archival reports `Estimated recovery: ~160 tokens` (640 / 4). When three candidates of 400, 800, and 1200 bytes are flagged, the rows report `~100`, `~200`, and `~300` tokens respectively. The estimate appears in the report's §4 Archival Recommendations table (Step 10) under the `Estimated Recovery` column.

Archival is never auto-executed — all recommendations require user confirmation per entry before any file changes are made.

## Step 9 — Ground Truth Refresh Trigger

For each **Tier 1 agent** (as listed in `tiers.tier_1.agents` within `.gaia/memory/config.yaml` — e.g., Val, Theo, Derek, Nate) that has a `ground-truth.md` file:

1. Read the most recent entry's `Sprint:` field from `ground-truth.md`.
2. Compare against the current sprint ID from `sprint-status.yaml`.
3. If the gap is **more than 1 sprint behind**: recommend `/gaia-refresh-ground-truth --agent {agent-id}` for that agent.

If `sprint-status.yaml` does not exist or has no sprint ID: skip the ground-truth refresh check entirely (cannot determine staleness without sprint data).

Tier 2, Tier 3, and Untiered agents have no `ground-truth.md` — exclude them from this check.

## Step 10 — Present Enhanced Report (7 Sections)

Write the enhanced findings report to `.gaia/artifacts/implementation-artifacts/memory-hygiene-report-{date}.md` with the following **seven sections** (layout preserved from the legacy workflow for NFR-053 parity):

### 1. Summary

- Total sidecars scanned (broken down by tier: Tier 1, Tier 2, Tier 3, Untiered)
- Total entries scanned
- Counts by status: ACTIVE, STALE, CONTRADICTED, ORPHANED, UNVERIFIABLE-FORMAT
- Budget usage summary: agents OK, warning, critical, over-budget

### 2. Token Budget Table

| Agent | Tier | Files Scanned | Token Usage | Session Budget | GT Budget | % Used | Status |

One row per agent, sorted by tier then agent name.

### 3. Detailed Findings

| Sidecar | Entry | Status | Evidence | Reference Artifact |

Grouped by sidecar, sorted by severity: CONTRADICTED > STALE > ORPHANED > UNVERIFIABLE-FORMAT > ACTIVE.

### 4. Archival Recommendations

| # | Agent | Entry | Reason | Type | Estimated Recovery | Action |

Budget pressure first, then staleness, then age. The `Estimated Recovery` column carries the per-item token recovery estimate (`~{N} tokens`) computed in Step 8 from `bytes / archival.token_approximation` — same source-of-truth ratio used by the Step 7 Token Budget Table.

### 5. Ground Truth Refresh Recommendations

| Agent | Last Sprint | Current Sprint | Gap | Recommendation |

Tier 1 agents only.

### 6. Untiered Agent Report

| Agent | Sidecar Dir | Files Found | Recommendation |

For each untiered agent: recommend adding to `.gaia/memory/config.yaml` as Tier 3.

### 7. Skipped Sidecars

List of sidecars with no content or explicitly skipped (empty directories, missing required files, legacy filenames pending migration).

The report header is written via the shared `template-header.sh` foundation script pattern (ADR-042), carrying `version`, `date`, and `author` fields for traceability.

## Step 11 — User Action on Flagged Items

For each entry with a status other than ACTIVE, ask the user to choose one action:

- **Keep** — add a `[Reviewed: {date}]` annotation to the entry. Confirms the user saw and accepted it.
- **Archive** — move the entry to the `archive/` subdirectory of the sidecar (create the directory if it does not yet exist). Prefix the archived entry with `[Archived: {date} — Reason: {status}]`.
- **Delete** — remove the entry from the sidecar file entirely.

When modifying sidecar files:

- **ALWAYS** preserve the file header (title, description, marker comment).
- **ALWAYS** keep the `<!-- Decisions will be appended below this line -->` marker intact.
- Active entries remain between the marker comment and the end of file.
- Archived entries go to the `archive/` subdirectory, never inline.

After all user actions are processed: report a summary of changes made to each sidecar file.

**Dry-run mode:** if the skill was invoked with `--dry-run`, skip this step entirely. The report in Step 10 is the final artifact; no sidecar modifications happen.

## Step 12 — Optional Checkpoint Pruning

Ask the user: "Would you like to prune old completed checkpoints? (yes / skip)"

- If yes: read `.gaia/memory/checkpoints/completed/` and list all `.yaml` files with dates.
- Ask: "How many sprints of checkpoints to retain? (default: 2)"
- Delete checkpoint files older than the retention window.
- Report: `Pruned {N} completed checkpoint(s). Retained {M} within the {retention}-sprint window.`

**Dry-run mode:** skip this step when `--dry-run` is set.

## Output — Primary Artifact

Write the hygiene report to `.gaia/artifacts/implementation-artifacts/memory-hygiene-report-{date}.md` (path preserved verbatim from the legacy `output.primary` contract for NFR-053 parity).

The `{date}` placeholder is substituted with the current date in `YYYY-MM-DD` form at write time, preserving the legacy substitution pattern.

## Post-Complete Gates

No post-complete gate is enforced. The skill's output is advisory: the user decides per-entry what to keep, archive, or delete. The legacy workflow has no `post_complete:` gate block, and parity requires none here either.

## Failure Semantics / Edge Cases

- **AC-EC1 — malformed SKILL.md frontmatter:** the E28-S7 / E28-S74 frontmatter linter catches missing `name` or `description` fields at CI time. The story cannot merge without passing the linter.
- **AC-EC2 — empty sidecar directory:** Step 1 categorizes empty sidecars separately. The skill logs "empty sidecar for {agent}" and continues scanning the remaining sidecars. No crash.
- **AC-EC3 — legacy sidecar filename present:** Step 2 detects `architecture-decisions.md`, `infrastructure-decisions.md`, `threat-model-decisions.md`, `velocity-data.md`. Content is scanned as decision-log and the entry is flagged for migration in the report.
- **AC-EC4 — sprint-status.yaml missing:** Step 3 falls back to a 42-day calendar. Step 8 produces no age-based recommendations; Step 9 (Ground Truth Refresh) is skipped with a note.
- **AC-EC5 — cross-reference matrix missing:** Step 4 degrades to structural checks + budget reporting. The skill logs a warning and does NOT crash.
- **AC-EC6 — decision-log exceeds token budget:** JIT release between sidecars prevents accumulation. The Token Budget Table flags the agent as over-budget. The per-sidecar scan still completes.
- **AC-EC7 — circular Related-field references between agents:** cross-reference scan terminates after one full pass (the cross-reference cap enforces this). No infinite loop.
- **AC-EC8 — Unicode / special characters in agent sidecar names:** path resolution preserves the original encoding. Scan completes without re-encoding errors.
- **AC-EC9 — parity harness diff between legacy and converted skill:** the Cluster 14 parity harness at `gaia-public/tests/cluster-14-parity/memory-hygiene-parity.bats` acts as the automated regression gate for NFR-053. Any behavioral drift surfaces as a failing test.
- **AC-EC10 — project with no _memory/ directory at all:** Step 1 exits gracefully with "no sidecars discovered — `_memory/` directory not present". No files are created.

## Frontmatter Linter Compliance

This SKILL.md passes the E28-S7 / E28-S74 / E28-S96 frontmatter linter (`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. Required fields are present: `name` matches the directory slug `gaia-memory-hygiene`; `description` is a trigger-signature with a concrete action phrase; `allowed-tools` is validated against the canonical tool set (Read, Write, Edit, Bash, Grep); `model: inherit` is set per the E28-S74 schema.

If a future edit removes `description` or any other required field, the frontmatter linter reports the missing field and the CI gate fails — no silent skill registration is permitted.

## Parity Notes vs. Legacy Workflow

The native skill preserves the legacy 12-step structure as 12 native steps (verbatim numbering). Data flow between steps is identical — each step's output feeds the next via the documented input contracts. The skill does not re-implement the workflow engine; it uses native Claude Code primitives (Skills + inline scripts + foundation-script wiring) per ADR-041. The Cluster 14 parity harness confirms NFR-053 parity — per-status counts, archival recommendations, ground-truth refresh triggers, and untiered-agent report output must match between the legacy workflow and this skill when run against the `v-parity-baseline` fixture.

The legacy workflow is NOT deleted as part of E28-S107. Per ADR-048, engine/workflow deletion is the program-closing Cluster 18/19 action. Both the legacy workflow and this skill coexist until parity is proven across all Cluster 14 conversions.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-memory-hygiene/scripts/finalize.sh

## References

- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks (replaces the legacy workflow engine).
- ADR-042 — Scripts-over-LLM for Deterministic Operations (foundation script set invoked inline via `!scripts/*.sh`).
- ADR-046 — Hybrid Memory Loading (memory-loader.sh inline `!` bash pattern for per-agent sidecar reads).
- FR-323 — Native Skill Format Compliance (frontmatter schema per E28-S74).
- FR-325 — Foundation scripts wired inline.
- FR-331 — Cross-agent memory loading via the hybrid pattern.
- NFR-048 — Conversion token-reduction target / activation-budget ceiling.
- NFR-053 — Functional parity with the legacy workflow (parity harness is the authority).
- E28-S13 — `memory-loader.sh` foundation script and canonical `<agent_name> <tier>` signature.
- E28-S17 — bats-core unit tests for foundation scripts (linter consumer).
- E28-S19 — Subagent frontmatter schema and `_base-dev.md` template.
- E28-S21 — Convert 12 lifecycle agents to subagents (canonical memory-loader consumption pattern).
- E28-S74 — Canonical SKILL.md frontmatter schema.
- Reference implementation for Cluster 14 pattern:
  - `plugins/gaia/skills/gaia-brownfield/SKILL.md` — sibling Cluster 14 skill; setup.sh / finalize.sh / foundation-script wiring pattern mirrored here.
  - `plugins/gaia/skills/gaia-fix-story/SKILL.md` — canonical inline `!${CLAUDE_PLUGIN_ROOT}/...` invocation shape.
- Shared memory-management skill (JIT-loaded): `_gaia/lifecycle/skills/memory-management.md` sections `stale-detection` (Step 5) and `budget-monitoring` (Step 7).
- Legacy parity source (for reference only; not invoked from this skill): `_gaia/lifecycle/workflows/anytime/memory-hygiene/` (workflow.yaml + 12-step instructions.xml).
