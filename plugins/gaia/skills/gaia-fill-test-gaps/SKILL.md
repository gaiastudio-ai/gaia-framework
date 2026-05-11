---
name: gaia-fill-test-gaps
description: Read gap report, triage by severity and story, propose remediation actions. Use when "fill test gaps" or /gaia-fill-test-gaps.
argument-hint: "[--severity critical|high|medium|all]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-fill-test-gaps/scripts/setup.sh

## Mission

You are performing gap remediation triage. You read the latest gap analysis report produced by `/gaia-test-gap-analysis`, filter gaps by severity, group them by story, propose remediation actions using the rule table from `scripts/lib/gap-triage-rules.js` (ADR-039 section 10.22.8.2), present a triage table for user approval, execute approved actions via bundled sub-workflow invocations, and emit a remediation report.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/fill-test-gaps` workflow (Cluster 11, story E28-S84, ADR-042). It follows the canonical skill pattern established by E28-S66 (code-review).

**Write context:** This skill does NOT use `context: fork` because it needs to write the remediation report and invoke sub-workflows that modify project files. It uses `allowed-tools: Read Grep Glob Bash Write Edit` for full read-write access.

**Sub-workflow dispatch:** Approved remediation actions are dispatched to bundled sub-workflows (`/gaia-add-stories`, `/gaia-triage-findings`, `/gaia-test-automate`) via subagent invocations with `mode=yolo`. The ADR-037 return adapter (`scripts/lib/adr037-return-adapter.js`) normalizes sub-workflow returns.

## Critical Rules

- A gap analysis report MUST exist at `docs/test-artifacts/test-gap-analysis-*.md`. If none found, fail fast with "No gap analysis report found -- run `/gaia-test-gap-analysis` first" (AC-EC3).
- If gap report frontmatter contains malformed YAML, fail with a descriptive parse error message (AC-EC2).
- Action proposal rules MUST be applied from `scripts/lib/gap-triage-rules.js` -- the single source of truth for the ADR-039 section 10.22.8.2 rule table.
- Logs-and-continues error handling: a single sub-workflow failure MUST NOT halt the parent skill (FR-314).
- Retry-only-failed semantics: consult the most recent prior remediation report (within 24 hours) and skip rows that previously succeeded (AC6/AC7 from legacy workflow).
- Gap rows referencing story keys that no longer have story files trigger a sprint-status.yaml fallback for status resolution; if that also yields no status, the row is marked `skip` with reason `story_not_found` (AC-EC4).
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule). Reads are read-only — sprint-status.yaml is consulted only as a secondary fallback source.
- YOLO mode follows the ADR-067 contract: default severity filter (critical+high) is auto-applied without prompting; explicit `--severity` arguments still take precedence.

## Constants

- **PERF_BUDGET_THRESHOLD** — default 20 actionable remediation rows. Above this threshold, Step 6 emits a perf-budget note before execution (FR-391). Override by editing this constant.

## Steps

### Step 1 -- Load Gap Report

- Glob `docs/test-artifacts/test-gap-analysis-*.md` to find all gap analysis reports.
- Sort glob results deterministically (lexicographic on filename).
- For each matched file, parse the YAML frontmatter and extract the `date` field.
- If a file has missing or malformed frontmatter, HALT with error: "Parse error in {filepath} -- malformed or missing frontmatter. Fix the file or regenerate with /gaia-test-gap-analysis" (AC-EC2).
- Select the file with the most recent `date` value.
- If zero files match the glob, HALT with: "No gap analysis report found -- run `/gaia-test-gap-analysis` first" (AC-EC3).
- Parse the selected report's markdown body to extract gap table rows (story_key, gap_type, severity, description).

### Step 2 -- Severity Filter

- Default severity filter: `critical+high`.
- **Argument precedence:** if the user invoked the skill with an explicit `--severity` argument (`critical`, `high`, `medium`, or `all`), use it directly and SKIP the prompt below.
- **Normal mode prompt (inline-ask, ADR-066):** when no `--severity` argument is provided and the runtime is NOT in YOLO mode, prompt the user:

  > Which severity filter should I apply? Default: critical+high. Options: critical | high | medium | all.

  Accept the user's response. Empty input or "default" selects critical+high. Validate against the four allowed options; reject anything else with a brief retry prompt.
- **YOLO mode auto-apply (ADR-067):** when no `--severity` argument is provided and the runtime IS in YOLO mode, auto-apply the default (critical+high) without prompting and emit a single-line audit log: "YOLO: severity filter auto-applied = critical+high (ADR-067)". This satisfies ADR-067 rule (2) — auto-accept default severity filters.
- Apply the resolved filter to the gap list.
- If 0 gaps remain after filtering: continue with an empty list -- the triage table renders with "No gaps match the selected severity filter".
- If filtered gap count exceeds 50: record INFO note "Report size {N} exceeds 50-gap perf budget -- expect >30s runtime".

### Step 3 -- Group by Story Key

- Build a triage map from the filtered gap list, keyed by `story_key`.
- Each row: `story_key`, `gap_count`, `gap_types` (deduplicated), `proposed_action` (empty), `status` (pending).
- Sort deterministically by `story_key` (lexicographic ascending).
- **Retry-only-failed preload (AC6/AC7):** Import `loadPrior` from `scripts/lib/prior-remediation-loader.js`. Call `loadPrior` with the selected gap report path and test artifacts directory. If a non-null prior is returned, mark previously-succeeded rows as `skip_prior_success`.

### Step 4 -- Action Proposal

- For each triage row, resolve the story's current status from the story file frontmatter (source of truth).
- **Sprint-status.yaml fallback (read-only):** if the story file is not found at `docs/implementation-artifacts/{story_key}-*.md`, before marking the row as `skip`, attempt a fallback lookup against `docs/sprint-status.yaml`:
  1. Emit the warning verbatim: `WARNING: Story file not found for {story_key} -- falling back to sprint-status.yaml for status resolution.`
  2. Read sprint-status.yaml (read-only — never write) and resolve the status field for `{story_key}`.
  3. If sprint-status.yaml yields a status, continue with the rule table below.
  4. If sprint-status.yaml has no entry for `{story_key}` either, mark the row as `skip` with reason `story_not_found` (AC-EC4).
- Import and invoke `proposeAction` from `scripts/lib/gap-triage-rules.js` for each gap — this remains the runtime source of truth for the rule table.
- **Inline rule table (ADR-039 §10.22.8.2)** — exactly the six-row decision matrix encoded in `gap-triage-rules.js`, inlined here for auditability per E49-S2:

  | gap_type           | story_status                  | action_type        | sub_workflow            | skip_reason                                |
  |--------------------|-------------------------------|--------------------|-------------------------|--------------------------------------------|
  | uncovered-ac       | backlog / ready-for-dev       | append_ac          | /gaia-add-stories       | —                                          |
  | missing-test       | done                          | new_story          | /gaia-triage-findings   | —                                          |
  | missing-edge-case  | backlog / ready-for-dev       | append_edge_case   | /gaia-add-stories       | —                                          |
  | unexecuted         | any non-skip status           | expand_automation  | /gaia-test-automate     | —                                          |
  | any gap_type       | in-progress / review / blocked | skip               | —                       | story is {status} — defer remediation       |
  | unknown gap_type   | any                           | skip               | —                       | unknown_gap_type                            |

  The inline table is documentation; runtime decisions are made by `proposeAction` so the table and code never drift. If you change one, change the other in the same PR.

### Step 5 -- Triage Table Output

- Render the triage map as a markdown table: `story_key | gap_count | gap_types | proposed_action | sub_workflow | status | skip_reason`.
- Add header with: report source file, date, severity filter, total gaps, filtered gaps.
- Save to `docs/test-artifacts/fill-test-gaps-triage-{date}.md`.

### Step 6 -- Execute Approved Actions

- **Perf-budget pre-check (FR-391):** before invoking sub-workflows, count actionable (non-skip, non-skip_prior_success) remediation rows. If the count exceeds `PERF_BUDGET_THRESHOLD` (default: 20 — see Constants), emit the perf-budget note verbatim:

  > Perf-budget note: {N} remediation rows exceed the 20-row threshold -- execution may take significant time.

  The threshold is the constant `PERF_BUDGET_THRESHOLD` declared in the Constants section above; substitute the resolved threshold value into the message. Continue execution after emitting — the note is informational only.
- Import `normalizeReturn` from `scripts/lib/adr037-return-adapter.js`.
- For each approved triage row:
  - If `skip` or `skip_prior_success`: record as skipped and continue.
  - Resolve bundled ref (strip "/gaia-" prefix). Validate against allowed refs: `add-stories`, `triage-findings`, `test-automate`.
  - Invoke sub-workflow via subagent with `mode=yolo`.
  - Normalize return via `normalizeReturn`. Branch on status: `ok` -> succeeded, `error`/`halted`/`needs_user` -> failed (logs-and-continues).
- Log execution summary: "{succeeded} succeeded, {failed} failed, {skipped} skipped".

### Step 7 -- Emit Remediation Report

- Import `writeReport` from `scripts/lib/gap-remediation-report-writer.js`.
- Call `writeReport` with tracking map, source gap report path, output directory, and execution date.
- Output: `docs/test-artifacts/gap-remediation-report-{date}.md` with frontmatter (source_gap_report, execution_date, total_actions, succeeded, failed, skipped) and per-action detail table per architecture section 10.22.8.3.
- If `writeReport` throws, HALT with error -- the report must always be written for retry-only-failed semantics.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-fill-test-gaps/scripts/finalize.sh
