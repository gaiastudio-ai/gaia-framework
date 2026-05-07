---
name: gaia-tech-debt-review
description: Aggregate, classify, score, and prioritize technical debt across the active sprint. Produces a rolling tech-debt-dashboard.md with stable TD-{N} IDs, aging buckets, STALE TARGET / UNASSIGNED detection, and trend comparison vs the prior dashboard. Use when "review tech debt" or /gaia-tech-debt-review.
allowed-tools: [Read, Write, Edit, Bash, Grep]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/setup.sh

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh sm decision-log

## Mission

You are running the **tech-debt review** for the active sprint. You scan every story markdown file's YAML frontmatter and `## Findings` section (never the full body — token budget mandate), collect tech-debt candidates, validate their triage targets, merge duplicates, assign stable `TD-{N}` identifiers, classify into DESIGN / CODE / TEST / INFRASTRUCTURE, score by Impact + Risk − Effort, compute aging against the current sprint, and emit a rolling `tech-debt-dashboard.md` with trend comparison vs the previous dashboard.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/tech-debt-review` workflow (brief P14-S4, story E28-S108, Cluster 14). The 7-step instruction body from the legacy 147-line `instructions.xml` is preserved in prose — parity confirmed per NFR-053.

**Native execution (ADR-041):** Runs under Claude Code's native execution model — no workflow.xml engine, no pre-resolved config chain. Steps are prose; deterministic operations are scripts.

**Scripts-over-LLM (ADR-042 / FR-325):** Deterministic operations — frontmatter-only scanning, Findings section extraction, duplicate detection input, stable TD-{N} ID assignment — are delegated to `skills/gaia-tech-debt-review/scripts/` helpers. Foundation operations (config resolution, checkpoint writes, lifecycle events) are delegated to `plugins/gaia/scripts/` via inline `!${CLAUDE_PLUGIN_ROOT}/...` calls.

**Hybrid memory loading (ADR-046):** Nate's scrum-master sidecar (`sm-sidecar/decision-log.md`) provides sprint-velocity context used when scoring Effort against historical capacity. The sidecar is loaded inline in the `## Setup` block via the canonical `memory-loader.sh <agent_name> <tier>` signature (see E28-S13 AC1). This is the only reason this skill loads agent memory — and it is loaded once, up-front, not per-step.

## Critical Rules

- **Frontmatter + Findings only.** Read ONLY the YAML frontmatter (between the first two `---` delimiters) and the `## Findings` section of each story file. Never load full story bodies. This is the critical token-budget-protection mandate from the legacy workflow and it MUST be preserved. The `scan-findings.sh` helper enforces it.
- **Stable `TD-{N}` IDs.** Every debt item receives an ID in Step 2, and that ID stays with the item across ALL subsequent steps — sort, filter, regenerate. IDs persist across runs: on each re-run, read the previous `tech-debt-dashboard.md`, collect existing TD-{N} tokens, and assign new IDs only to genuinely new items. The `td-id-assign.sh` helper enforces this.
- **No renumbering.** Never renumber existing TD-{N} IDs. If TD-3 is resolved and removed, TD-4 stays TD-4. The dashboard is a ledger, not a ranked list.
- **Target validation.** For every finding marked `[TRIAGED → {target_key}]`, look up the target story's status. Flag:
  - target done → **STALE TARGET** (debt likely added after implementation — needs re-triage).
  - target file missing or target not a valid story key → **UNASSIGNED**.
  - target in backlog / validating / ready-for-dev → **QUEUED**.
  - target in-progress → **IN PROGRESS**.
  - target in review → **IN REVIEW**.
- **RESOLVED filtering.** For every STALE TARGET, check the filesystem — if the specific file/pattern the finding references no longer exists, mark RESOLVED and exclude from classification and scoring.
- **Duplicate merge before ID assignment.** Two findings that describe the same root cause (same file/pattern, same issue type) are merged into a single item with source list `E{a}-S{b}, E{c}-S{d}` and tag `(merged from N findings)`. Merge BEFORE `td-id-assign.sh` — IDs reflect the deduplicated set.
- **Dashboard trend preservation.** The dashboard overwrites the previous `tech-debt-dashboard.md`, but the **trend section** compares current totals against the previous totals. Read the previous dashboard first; compute deltas; write the merged result.
- **Dashboard is read-only output.** No user confirmation prompt. The legacy workflow.yaml declared `template_output_prompt: "auto"`; this skill matches that semantic — write the dashboard and exit cleanly.
- **Sprint-status.yaml is NEVER written by this skill** (Sprint-Status Write Safety rule). It is only read for the current `sprint_id`.
- **Val memory save is non-blocking.** Step 7 appends a decision-log entry to `_memory/validator-sidecar/decision-log.md`. If the write fails, log a warning and continue — memory save is best-effort.

## Inputs

- None. The skill discovers its inputs at runtime:
  - `docs/implementation-artifacts/sprint-status.yaml` — current `sprint_id`.
  - Story files — recursive walk under `docs/implementation-artifacts/epic-*/stories/**/*.md` (canonical nested layout per E79) PLUS the legacy flat layer `docs/implementation-artifacts/*.md` (read-only fallback until E79-S6 backfill completes). Frontmatter + Findings sections only.
  - `docs/implementation-artifacts/tech-debt-dashboard.md` — previous dashboard (if present).

## Steps

### Step 1 — Scan Debt Sources

- If `docs/implementation-artifacts/tech-debt-dashboard.md` exists, read it — capture previous TD-{N} IDs, previous totals, and previous items list for trend comparison.
- Read `docs/implementation-artifacts/sprint-status.yaml` — identify the current `sprint_id` and the list of backlog stories.
- Invoke the scanner:
  ```
  !${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh --artifacts-dir docs/implementation-artifacts
  ```
  The scanner reads only frontmatter + `## Findings` sections (token-budget mandate) and emits pipe-delimited candidate rows:
  `{story_key}|{status}|{sprint_id}|{type}|{severity}|{finding}|{action}`.
  The scanner includes:
  - every `Type = tech-debt` row,
  - every `Type = bug` row with `Severity = medium | low` that is NOT marked `[TRIAGED]` or `[DISMISSED]` in the finding text.
- For each candidate marked `[TRIAGED → {target_key}]`, validate the target:
  1. Glob `docs/implementation-artifacts/{target_key}-*.md`.
  2. If the target file exists, parse its frontmatter `status` field.
  3. Map to a Resolution Status: QUEUED / IN PROGRESS / IN REVIEW / STALE TARGET.
  4. If the target file is missing or the target is not a valid `E{n}-S{m}` key → UNASSIGNED.
- For each STALE TARGET, verify filesystem state:
  1. Identify the specific file, config, or pattern the finding references.
  2. If the filesystem no longer has it, mark RESOLVED and EXCLUDE from classification/scoring. Report: `{N} STALE TARGET items verified: {R} resolved (excluded), {P} still active`.
- Split into two pools — (a) untriaged findings still in story files, (b) already-triaged backlog stories. Include both in the analysis (untriaged items receive Resolution Status = UNASSIGNED).
- If no debt items remain at all, inform the user "No technical debt detected" and exit cleanly.

### Step 2 — Classify Debt

- **Duplicate merge (before ID assignment).** Compare all items pairwise:
  - same file / config / pattern referenced → candidate duplicate.
  - same type of issue ("dual directories" from different source stories) → candidate duplicate.
  - one finding is a subset of another → candidate duplicate.
  Merge each duplicate group into a single item: keep the most descriptive title, combine all source stories (e.g., `E8-S2, E8-S4`), keep the same target, tag as `(merged from {count} findings)`. Report: `Merged {N} duplicate findings into {M} items`.
- **Assign stable `TD-{N}` IDs** to the MERGED set by invoking:
  ```
  !${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/td-id-assign.sh --dashboard docs/implementation-artifacts/tech-debt-dashboard.md --count <N>
  ```
  The helper reads the previous dashboard's TD-{N} tokens and emits the next `N` sequential IDs after the highest existing. For items already present in the previous dashboard (matched by file + pattern + source story), preserve their existing TD-{N}. Only genuinely new items receive fresh IDs. **Never renumber.**
- **Categorize** each item into exactly one category:
  - **DESIGN** — architectural shortcuts, missing abstractions, tight coupling, design-pattern violations.
  - **CODE** — code smells, duplication, excessive complexity, naming inconsistencies, SOLID violations.
  - **TEST** — missing tests, flaky tests, low-coverage areas, manual-only testing.
  - **INFRASTRUCTURE** — CI/CD gaps, missing monitoring, manual deployment steps, environment drift.
- **Tag each item with its source**: `finding` (from dev-story), `triage` (backlog story from triage-findings), `manual` (user-reported).
- **Surface target-validation issues.** If any items have Resolution Status = STALE TARGET or UNASSIGNED, present a warning block BEFORE the classification table:
  ```
  ⚠ Target Validation Issues:
  - TD-{N}: Target {key} is DONE — finding was likely added after implementation. Needs re-triage.
  - TD-{N}: Target "{text}" — no valid story assigned. Needs triage.
  Recommend: run /gaia-triage-findings to reassign these items.
  ```
- **Present the classification table** with all columns:
  `| ID | Item | Category | Source | Target Story | Resolution Status |`
  Resolution values: QUEUED / IN PROGRESS / IN REVIEW / STALE TARGET / UNASSIGNED.
- Present a category summary table with counts per category.

### Step 3 — Score and Prioritize

- For each debt item, assess three dimensions on a 1–5 scale:
  - **Impact** — how much this affects dev velocity, reliability, or UX (1=minimal, 5=severe).
  - **Effort** — work to resolve (1=trivial, 2=few hours, 3=one story, 4=multi-story, 5=epic-sized). Cross-reference Nate's sidecar velocity context loaded in Setup.
  - **Risk of Inaction** — what happens if ignored for 3 more sprints (1=nothing, 3=slows team, 5=production incident).
- Debt Score = (Impact + Risk of Inaction) − Effort.
- Priority mapping: Score ≥ 7 → FIX NOW. Score 4–6 → PLAN NEXT. Score 1–3 → TRACK.
- Sort by Debt Score descending and add a `Rank` column. **Preserve the TD-{N} ID** — rank is a sorted position, not a new identifier.
- Present the full scored table:
  `| Rank | ID | Item | Category | Source | Target | Resolution | Impact | Effort | Risk | Score | Priority |`

### Step 4 — Calculate Aging

- For each item, compute age in sprints:
  - **Triaged backlog stories** — compare story creation sprint to current `sprint_id`.
  - **Untriaged findings** — compare source story `sprint_id` to current `sprint_id`.
  - **Sprint_id missing** — fall back to file modification date.
- Apply SLA thresholds:
  - FIX NOW items older than 1 sprint → flag **OVERDUE**.
  - PLAN NEXT items older than 3 sprints → auto-escalate to FIX NOW.
  - TRACK items older than 5 sprints → flag for relevance review (may be obsolete).
- Build an aging histogram: item counts per age bucket (current, 1–2, 3–4, 5+ sprints).

### Step 5 — Generate Dashboard

- Load the local template: `skills/gaia-tech-debt-review/templates/dashboard.md`.
- Fill every section:
  - **Summary metrics** — total, FIX NOW / PLAN NEXT / TRACK, overdue, STALE TARGET, UNASSIGNED, debt ratio.
  - **Category table** — count and oldest-item age per category.
  - **Aging histogram** — ASCII bar chart.
  - **Top 10 table** — all columns: rank, TD-{N}, item, category, source, target, resolution, impact, effort, risk, score, age, priority, action.
  - **Overdue alerts** — all OVERDUE and auto-escalated items with source and age.
  - **Target validation issues** — STALE TARGET and UNASSIGNED items with re-triage recommendation.
  - **Trend section** — current vs previous totals, delta, resolved since last, new since last. If no previous dashboard, emit `First review — no prior data`.
- Write the filled template to `docs/implementation-artifacts/tech-debt-dashboard.md`. This output is auto-continue — no user-confirmation prompt (matches legacy `template_output_prompt: "auto"`).

### Step 6 — Recommend Actions

Based on dashboard findings, present specific next-step commands:

- If any STALE TARGET or UNASSIGNED items exist: `Run /gaia-triage-findings to reassign {count} items with invalid targets`.
- If any FIX NOW + OVERDUE items exist: `Run /gaia-correct-course to inject these into the current sprint`.
- If debt ratio > 30%: `Consider dedicating 20% of next sprint capacity to debt reduction`.
- If TEST debt dominates: `Run /gaia-test-automate to address test coverage gaps`.
- If DESIGN debt dominates: `Consider /gaia-add-feature for architectural refactoring`.
- If INFRASTRUCTURE debt dominates: `Run /gaia-ci-setup to close CI/CD gaps`.
- If items were auto-escalated: `Review escalated items — aging has upgraded their priority`.

For each FIX NOW + OVERDUE item, append to `docs/planning-artifacts/action-items.yaml` (canonical location per architecture §10.28.6 / ADR-052; reconciled in E36-S4) (if not already tracked) with fields:
`type: "implementation"`, `priority: "high"`, `status: "open"`, `source_workflow: "tech-debt-review"`, `source_sprint: {sprint_id}`, `title: "{debt item description}"`, `related_stories: [{target story if exists}]`. Check existing action items by title similarity to avoid duplicates.

### Step 7 — Save to Val Memory

Auto-save review decisions to Val's sidecar (no user prompt):

1. Append to `_memory/validator-sidecar/decision-log.md`:
   ```
   ### [YYYY-MM-DD] Tech Debt Review: {total_count} items

   - **Agent:** validator
   - **Workflow:** tech-debt-review
   - **Sprint:** {sprint_id}
   - **Status:** recorded

   Dashboard: {total_count} items. FIX NOW: {fix_now_count}. PLAN NEXT: {plan_next_count}. TRACK: {track_count}.
   Overdue: {overdue_count}. Auto-escalated: {escalated_count}.
   Stale targets: {stale_count}. Unassigned: {unassigned_count}.
   Debt ratio: {ratio}%. Trend: {delta vs previous} ({up/down/stable}).
   Top category: {dominant_category} ({count} items).
   Top 3 FIX NOW items: {brief list with scores}.
   Recommendations: {list of recommended /gaia-* commands}.
   ```

2. Replace the body of `_memory/validator-sidecar/conversation-context.md` (preserve header above the first `---`) with:
   ```
   Last session: Tech debt review for {sprint_id}.
   Date: {YYYY-MM-DD}. Items: {total_count}. FIX NOW: {fix_now_count}. Overdue: {overdue_count}.
   Stale targets: {stale_count}. Unassigned: {unassigned_count}.
   Debt ratio: {ratio}%. Trend: {up/down/stable}.
   ```

If `_memory/validator-sidecar/` or the target files do not exist, create them with the standard sidecar headers. If the write fails, log a warning and continue — memory save is non-blocking.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/finalize.sh

## References

- **E28-S108 / P14-S4** — this conversion story (Cluster 14).
- **ADR-041** — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- **ADR-042** — Scripts-over-LLM for deterministic operations.
- **ADR-046** — Hybrid Memory Loading (drives the `memory-loader.sh sm decision-log` call in Setup).
- **ADR-048** — Engine Deletion as Program-Closing Action (the legacy `_gaia/lifecycle/workflows/4-implementation/tech-debt-review/` remains in place until Cluster 18/19 cleanup).
- **NFR-048** — Framework context budget (40K tokens per activation) — the token-budget mandate that forces frontmatter-only reads.
- **NFR-053** — Functional parity across native conversions.
- **E28-S13** — `memory-loader.sh` foundation script and canonical `<agent_name> <tier>` signature.
- **Legacy source:** `_gaia/lifecycle/workflows/4-implementation/tech-debt-review/instructions.xml` (147-line 7-step body ported above).
- **Legacy template:** `_gaia/lifecycle/templates/tech-debt-dashboard-template.md` (shipped locally as `skills/gaia-tech-debt-review/templates/dashboard.md`).
