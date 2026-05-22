---
name: gaia-ground-truth-management
description: Ground truth operations for the validator — entry structure, incremental/full/dual refresh strategies, conflict resolution, archival, token budget management, and brownfield extraction. Native Claude Code port of the legacy ground-truth-management lifecycle skill.
version: '1.0'
applicable_agents: [validator]
sections: [entry-structure, incremental-refresh, full-refresh, dual-refresh, conflict-resolution, archival, token-budget, brownfield-extraction]
allowed-tools: [Read, Write, Edit, Grep]
orchestration_class: light-procedural
---

<!-- Converted under ADR-041 (Native Execution Model). Source: _gaia/lifecycle/skills/ground-truth-management.md. -->

## Mission

Back Val's ground-truth rewrite path with deterministic operations over the per-agent `ground-truth.md` sidecar file. This skill is the body-of-knowledge reference used by every Val workflow that touches ground truth — `val-validate-artifact`, `val-validate-plan`, `val-refresh-ground-truth`, and brownfield seeding.

Sections below are loaded JIT by callers under the ADR-041 native execution model: the Claude Code skill runtime scans for `<!-- SECTION: {id} -->` and `<!-- END SECTION -->` markers in this file and loads only the requested section body. Each section marker is part of the public contract — renaming or removing one is a breaking change against every caller that references it by ID.

## Critical Rules

- **Filesystem is always the source of truth.** When ground truth disagrees with the filesystem scan, update the entry automatically — do not flip the direction of truth.
- **Never silently drop entries.** Malformed or unresolvable entries must be flagged (WARNING) and attempted for reconstruction before anything is removed; removal of a live entry always requires user confirmation.
- **Empty-seed invariant is hard-enforced (dual-refresh §3).** The committed `{project-path}/_memory/{agent}-sidecar/ground-truth.md` must always have `entry_count: 0` and `estimated_tokens: 0` after Step 8b. Halt if not.
- **Token budgets are per-tier and config-driven.** Never hardcode the 200K Tier-1 ceiling or the 60%/80% thresholds in code — read from `_memory/config.yaml`.
- **Do not conflate runtime sidecar and committed seed.** Dual-refresh writes both; only `last_refresh` is updated on the committed seed.

<!-- SECTION: entry-structure -->
## Entry Structure

A ground-truth entry is a compact 3–4 line markdown block representing one verified fact.

### Format

```
**[{category}]** {factual statement}
Source: `{source_path}` | Verified: {YYYY-MM-DD} | Count: {N}
```

### Required Fields

| Field | Description |
|-------|-------------|
| **Fact category** | One of the 4 categories below |
| **Factual statement** | A single, verifiable assertion |
| **Source** | File path or glob that proves the fact |
| **Last-verified** | Date of last successful verification (ISO 8601) |
| **Verification count** | Number of times this fact has been confirmed |

### Fact Categories

- `file-inventory` — file existence, location, count (e.g., "25 agent files in `_gaia/*/agents/`")
- `structural-pattern` — architecture patterns, conventions, section structure (e.g., "workflow.yaml requires `name` field")
- `variable-inventory` — config variables, resolved values, defaults (e.g., "`project_path` defaults to `.`")
- `cross-reference` — links between artifacts, traceability entries (e.g., "ADR-012 referenced by E8-S1, E8-S9")

### Example Entry

```
**[file-inventory]** 8 shared dev skills in `_gaia/dev/skills/`
Source: `_gaia/dev/skills/*.md` | Verified: 2026-03-18 | Count: 3
```
<!-- END SECTION -->

<!-- SECTION: incremental-refresh -->
## Incremental Refresh

Updates ground truth by scanning only files changed since the last refresh.

### Change Detection

1. Run `git diff --name-only {last_refresh_commit}..HEAD` to get changed files
2. If no git history: fall back to file modification timestamps vs. `last-verified` dates
3. Filter to project-relevant paths: `{project-path}/`, `docs/*-artifacts/`. Exclude: `_gaia/`, `.claude/`, `bin/`, `_memory/`, `node_modules/`, `.git/`

### Comparison Logic

For each changed file, extract verifiable facts and compare against existing entries:

1. **Match** — fact exists and value unchanged → update `last-verified` date, increment count
2. **Update** — fact exists but value changed → apply conflict-resolution rules
3. **New** — fact discovered with no existing entry → stage as candidate entry
4. **Stale** — existing entry's source file was modified but fact no longer present → flag for review

### Output Categories

| Category | Action |
|----------|--------|
| **Confirmed** | Entries re-verified, dates and counts updated |
| **Updated** | Entries modified via conflict resolution with changelog |
| **New** | Candidate entries pending addition |
| **Stale** | Entries whose source changed but fact not found — flag for user review |
<!-- END SECTION -->

<!-- SECTION: full-refresh -->
## Full Refresh

Complete scan of the framework and project to rebuild or reconcile the entire ground-truth inventory.

### Scan Targets

| Target | Path Pattern | Facts Extracted |
|--------|-------------|-----------------|
| Project source files | `{project-path}/**/*` | File inventory, directory structure, languages, entry points |
| Project config files | `{project-path}/*.{json,yaml,yml,toml,xml,env.example}` | Config keys, settings, dependencies |
| Package manifests | `{project-path}/**/package.json`, `pubspec.yaml`, `pom.xml`, etc. | Dependencies, versions, scripts |
| Planning artifacts | `.gaia/artifacts/planning-artifacts/*.md` | Artifact count, names, dates |
| Implementation artifacts | `.gaia/artifacts/implementation-artifacts/epic-*/stories/**/*.md` (canonical, E79) + `.gaia/artifacts/implementation-artifacts/*.md` (legacy flat fallback) | Artifact count, story keys, types |
| Test artifacts | `.gaia/artifacts/test-artifacts/*.md` | Artifact count, coverage areas |

### Exclusions

Always skip these directories — they are framework internals, not project code:
`_gaia/`, `.claude/`, `bin/`, `_memory/`, `node_modules/`, `.git/`, `build/`, `dist/`

### Output Format

The scan produces a complete fact inventory structured by category. Each fact follows the entry-structure format. The inventory is then reconciled against existing `ground-truth.md`:

1. For each scanned fact: search existing entries for a matching category + statement
2. Apply incremental-refresh comparison logic (match / update / new / stale)
3. Entries in `ground-truth.md` with no corresponding scanned fact → mark as stale candidates
<!-- END SECTION -->

<!-- SECTION: dual-refresh -->
## Dual Refresh (Runtime Sidecar + Committed Seed)

When the framework and the project source are in separate directories (`project_path` differs from `.`), each Tier 1 agent has **two** `ground-truth.md` files that must stay in sync:

| Location | Path (resolved) | Role | Content |
|----------|-----------------|------|---------|
| Runtime sidecar | `{project-root}/_memory/{agent}-sidecar/ground-truth.md` | Working copy used by the agent at runtime | Full runtime entries — `entry_count` and `estimated_tokens` reflect reality |
| Committed seed | `{project-path}/_memory/{agent}-sidecar/ground-truth.md` | Shipping template committed to the framework repo and published to npm | **Empty template** — `entry_count: 0`, `estimated_tokens: 0` (per E28-S31 invariant) |

### Why both must refresh together

Historically, only the runtime sidecar was refreshed; the committed seed was updated manually (see E28-S3 finding #4). This invited drift between the two files: the runtime copy gained entries while the committed template stayed frozen at an older timestamp, and operators had no reliable signal that the seed was stale. `val-refresh-ground-truth` now writes both by default so the two locations cannot drift independently.

### Refresh rules

1. **Runtime sidecar (Step 8)** — written normally with full entry inventory, updated `last_refresh`, live `entry_count` and `estimated_tokens`.
2. **Committed seed (Step 8b)** — only the `last_refresh` frontmatter field is updated; all other frontmatter (`agent`, `tier`, `token_budget`) and the body (including the `Invariants` section) are preserved verbatim.
3. **Empty-seed invariant is hard-enforced.** After writing the committed seed, the workflow re-parses the frontmatter and HALTS if `entry_count` or `estimated_tokens` is anything other than `0`. See memory-management skill section `empty-seed-invariant` for the full rule.
4. **Fail-loud on missing files.** If either location is missing when the workflow runs, the workflow halts with a clear error. There is no silent create-on-demand for the committed seed — that file is part of the framework's shipping template and must be added intentionally.
5. **Single-location projects.** When `project_path: "."` (runtime and committed paths resolve to the same file), Step 8b is a no-op — Step 8 already wrote the only copy.

### Agent mapping

All four Tier 1 agents follow the same dual-refresh rule with their respective sidecar directories:

- `val` → `validator-sidecar/`
- `theo` → `architect-sidecar/`
- `derek` → `pm-sidecar/`
- `nate` → `sm-sidecar/`

When `--agent all` is used, dual-refresh runs once per agent inside the per-agent refresh loop, and the combined summary reports both runtime and committed-seed results for each agent.
<!-- END SECTION -->

<!-- SECTION: conflict-resolution -->
## Conflict Resolution

Deterministic rules for resolving discrepancies between ground truth entries and filesystem state.

### Conflict Types

| Type | Condition | Resolution | User Confirmation |
|------|-----------|------------|-------------------|
| **Factual conflict** | Ground truth value differs from filesystem scan | Filesystem wins automatically | No |
| **Missing source** | Entry's source path no longer exists | Mark entry as `REMOVED` | Yes — before permanent deletion |
| **New fact** | Scan discovers a fact with no existing entry | Add new entry | No |

### Resolution Rules

1. **Filesystem is always source of truth** — when a factual conflict is detected (e.g., ground truth says "67 workflows" but scan finds 69), update the entry automatically
2. **Changelog note** — every update appends a note: `Updated: {old_value} → {new_value} (detected {date}, previous value set {prev_date})`
3. **Missing source** — if an entry's source file is deleted or moved, mark as `REMOVED` with the detection date. Require user confirmation before permanent removal from ground truth
4. **New facts** — add directly with verification count of 1 and current date

### Corrupted Entry Handling

When incremental or full refresh encounters an entry with malformed structure (missing required fields, broken markdown):

1. Flag the entry as `WARNING: malformed entry — {description of issue}`
2. Attempt reconstruction from the filesystem scan — re-extract facts from the source path
3. If reconstruction succeeds: replace the corrupted entry with the reconstructed version + changelog note
4. If reconstruction fails (source no longer exists): retain the corrupted entry with WARNING flag for manual review
5. **Never silently drop corrupted entries** — always flag and attempt recovery

### User Confirmation Matrix

| Action | Auto | Confirm |
|--------|------|---------|
| Update factual value | Yes | — |
| Add new entry | Yes | — |
| Reconstruct corrupted entry | Yes | — |
| Remove entry (source deleted) | — | Yes |
| Archive entry (budget pressure) | Yes | — |
<!-- END SECTION -->

<!-- SECTION: token-budget -->
## Token Budget Management

Monitors ground-truth.md size against Val's Tier 1 200K token budget (per ADR-014).

### Token Estimation

Approximate formula: `characters / 4 ≈ tokens`. For ground-truth.md:

```
file_chars = wc -m ground-truth.md
estimated_tokens = file_chars / 4
budget_pct = (estimated_tokens / 200000) * 100
```

### Budget Thresholds

| Level | Range | Action |
|-------|-------|--------|
| **GREEN** | < 60% (< 120K tokens) | No action needed |
| **YELLOW** | 60–80% (120K–160K tokens) | Suggest archival — list candidates |
| **RED** | > 80% (> 160K tokens) | Require archival before next save |

### Status Reporting

Every refresh workflow must report budget status:

```
Token Budget: {level} — {estimated_tokens}/200,000 ({pct}%)
Entries: {total_count} ({new} new, {updated} updated, {stale} stale)
{if YELLOW: "Archival recommended — {N} candidate entries"}
{if RED: "Archival required — must free {N} tokens before next write"}
```
<!-- END SECTION -->

<!-- SECTION: archival -->
## Archival

Moves low-value entries from `ground-truth.md` to `ground-truth-archive.md` when token budget pressure requires it.

### Trigger

Archival is triggered when token budget reaches RED threshold (> 80% of 200K tokens). YELLOW threshold suggests but does not require archival.

### Priority — Which Entries to Archive

1. Entries **not referenced in the last 3 validation runs** (oldest first)
2. Among equally unreferenced entries: oldest `last-verified` date first
3. Never archive entries with verification count > 10 unless they are also unreferenced

### Archive Process

1. Select candidate entries by priority until freeing enough tokens to reach GREEN threshold
2. For each archived entry: move the full entry to `ground-truth-archive.md` (same sidecar directory as `ground-truth.md`)
3. Leave a **one-line summary** in `ground-truth.md`: `[archived] {category}: {statement} → see ground-truth-archive.md`
4. Update token budget status after archival

### Archive File Format

`ground-truth-archive.md` mirrors the entry structure. Each archived entry retains all fields plus:

```
Archived: {date} | Reason: {budget_pressure|manual} | Last referenced: run-{N}
```

Val can still cross-reference archived entries when needed — load `ground-truth-archive.md` JIT.
<!-- END SECTION -->

<!-- SECTION: brownfield-extraction -->
## Brownfield Extraction

Seeds initial ground truth from existing project artifacts during `/gaia-brownfield` onboarding.

### Source Documents

| Document | Path | Facts to Extract |
|----------|------|-----------------|
| Brownfield assessment | `.gaia/artifacts/planning-artifacts/brownfield-assessment.md` | Tech stack, dependencies, file counts, project structure |
| Project documentation | `.gaia/artifacts/planning-artifacts/project-documentation.md` | Architecture patterns, conventions, config values |

### Parsing Rules

1. **Brownfield assessment** — extract from structured tables and inventories:
   - File counts per directory → `file-inventory` entries
   - Dependency list with versions → `variable-inventory` entries
   - Architecture patterns detected → `structural-pattern` entries

2. **Project documentation** — extract from narrative sections:
   - Config values and defaults → `variable-inventory` entries
   - Cross-references between components → `cross-reference` entries
   - Conventions documented → `structural-pattern` entries

3. **Filesystem scan** — complement document extraction with direct scanning:
   - Run full-refresh scan targets against `{project-path}`
   - Compare scanned facts against document-extracted facts
   - Resolve conflicts using conflict-resolution rules (filesystem wins)

### Initial Seeding Workflow

1. Parse brownfield-assessment.md → extract candidate entries
2. Parse project-documentation.md → extract candidate entries
3. Deduplicate: merge entries with matching category + statement
4. Run full-refresh scan to verify all candidates against filesystem
5. Write verified entries to `ground-truth.md` with verification count = 1
6. Report: `Seeded {N} ground-truth entries from brownfield artifacts + filesystem scan`
<!-- END SECTION -->
