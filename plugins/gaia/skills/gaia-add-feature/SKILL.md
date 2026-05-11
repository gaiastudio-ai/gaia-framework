---
name: gaia-add-feature
description: Triage and route a fix, enhancement, or feature through only the affected artifacts. Classifies as patch/enhancement/feature and cascades accordingly -- updating PRD, architecture, epics, test plan, threat model, and traceability as needed (FR-323, FR-362). Surfaces Val verdicts (PASS/WARNING/CRITICAL) per ADR-063 and emits an assessment-doc audit trail.
context: fork
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: heavy-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm decision-log

## Mission

You are the orchestrator for adding a new feature, enhancement, or patch to
the project. You classify the change scope and cascade updates through
exactly the set of affected artifacts. This skill delegates to sub-workflows
via subagents -- it does not perform direct edits to downstream artifacts.

This skill is the native Claude Code conversion of the legacy add-feature
workflow (E28-S57, FR-323) and is hardened by E48-S1 (FR-362) so that
validation gates are no longer swallowed inside subagents. The
classification vocabulary (patch / enhancement / feature), cascade matrix,
and delegation model are preserved verbatim from the legacy workflow.

## Critical Rules

- This is an orchestrator -- delegate to sub-workflows via subagents, do
  not perform edits directly.
- Context flows forward: PRD diff feeds architecture edit, which feeds test
  plan edit, which feeds story creation.
- Intelligently skip steps when not needed -- do not force all
  sub-workflows on every change.
- The classification vocabulary is EXACTLY: `patch`, `enhancement`,
  `feature`. Do NOT rename, alias, or refactor these terms -- downstream
  triage tooling and historical change requests depend on those exact
  strings.
- The cascade matrix (which artifacts are updated per classification) MUST
  match the definitions below exactly.
- Validation gates are MANDATORY surfacing points -- never silently consume
  Val verdicts inside a subagent. Always parse the ADR-037 return schema
  and apply the ADR-063 verdict-surfacing contract before continuing the
  cascade.
- A CRITICAL verdict from Val HALTS the skill before cascade execution.
  This applies in all execution modes (normal and YOLO) per ADR-067.
- **AskUserQuestion call MUST precede Val dispatch under Auto Mode**
  (E83-S1). Step 2 entry MUST emit an `AskUserQuestion` tool call before
  the Agent-tool dispatch to Val. AskUserQuestion is substrate-enforced
  under Auto Mode (per the empirical evidence captured in user memory rule
  `feedback_askuserquestion_under_automode.md`, 2026-05-09); this is the
  primitive that catches the "auto-mode self-judgment" bypass class. Do
  NOT substitute stdout sentinels, Stop hooks, or pause-and-wait scripts
  -- they are bypassed under Auto Mode (the gaia-meeting precedent).
- **Sentinel checkpoint MUST exist before Step 3** (E83-S1). Step 2 MUST
  write `_memory/checkpoints/add-feature-{feature_id}-val-dispatched.json`
  via the dedicated `scripts/write-val-sentinel.sh` writer (which delegates
  to atomic tempfile + `mv` and constructs JSON via `jq -n`, never via
  heredoc). `finalize.sh` validates the sentinel before allowing cascade
  completion -- a missing or malformed sentinel HALTs the workflow with
  stderr `Val gate sentinel missing.*re-invoke from a parent orchestrator
  thread`. This is the primitive that catches the "skipped Step 2 entirely"
  bypass class.
- **There is NO patch-mode exception to the Val gate** (E83-S2,
  precedent: AI-2026-05-09-12). Patch classification still requires a
  dispatched Val subagent and the same ADR-063 verdict-surfacing contract
  as enhancement and feature classifications. Self-license patterns of
  the form "auto-judge under patch classification", "inline-judge because
  the diff is small", or "skip Val for trivial typo fix" are forbidden.
  The classification is decided in Step 1; the Val gate runs
  unconditionally in Step 2 before any cascade or direct edit.
- **No inline Val — Val MUST be dispatched as a `context: fork` subagent
  via the Agent tool** (E83-S2, precedent: AI-2026-05-09-12). The LLM
  MUST NOT pass off its own inline review as a Val outcome, MUST NOT
  compose a synthetic ADR-037 return JSON in the parent thread, and
  MUST NOT set `status: PASS` without a real Agent-tool dispatch. If
  the Agent tool is not available in the current context (e.g., running
  under a fork that did not allowlist `Agent`), HALT immediately with
  the parent-thread re-invoke message in Step 2 -- do NOT self-judge
  the Val gate from the parent thread.

## Subagent Dispatch Contract

This skill follows the framework-wide Subagent Dispatch Contract (ADR-063).
Every Val invocation is dispatched via `context: fork` per ADR-045 with a
read-only tool allowlist `[Read, Grep, Glob, Bash]`, pinned to
`model: claude-opus-4-7` and `effort: high` per ADR-074 contract C2 (Val
opus pin — validation rigor is the contract). After Val returns:

1. **Parse the subagent return** using the ADR-037 structured schema:
   `{ status, summary, artifacts, findings, next }`. The `status` field is
   one of `PASS`, `WARNING`, `CRITICAL`. Each entry in `findings` carries a
   `severity` of `CRITICAL`, `WARNING`, or `INFO`.
2. **Surface the verdict** to the user inline: display `status` and
   `summary`, then list every finding with its severity, scope, and
   recommended action.
3. **Halt on CRITICAL** -- if `status == "CRITICAL"` or any finding has
   `severity == "CRITICAL"`, the skill HALTS before cascade execution with
   an actionable error message. The user must resolve the finding before
   the skill can resume (or abort). No assessment-doc is emitted on a
   CRITICAL halt.
4. **Display WARNING** -- findings with `severity == "WARNING"` are
   displayed inline before proceeding. The skill does NOT halt; warnings
   are recorded in the assessment-doc Val Findings Summary section.
5. **Log INFO** -- findings with `severity == "INFO"` are written to the
   workflow checkpoint and the assessment-doc Val Findings Summary but are
   not surfaced inline unless the user requests verbose output.

This contract is enforced uniformly per ADR-063. CRITICAL findings cannot
be auto-dismissed in any execution mode.

## YOLO Behavior

This skill conforms to the framework-wide YOLO Mode Contract (ADR-067).

| Behavior | YOLO Action |
|----------|-------------|
| Template-output prompts (`[c]/[y]/[e]`) | Auto-continue (skip prompt). |
| Severity / filter selection | Auto-accept defaults. |
| Optional confirmation ("Proceed with cascade?") | Auto-confirm. |
| Subagent verdict display (Val review gate) | Auto-display, but a CRITICAL verdict still HALTS per ADR-063. |
| Val gate dispatch under absent Agent tool | HALT -- never auto-judge, never inline-Val. Surface `Re-invoke /gaia-add-feature from a parent orchestrator thread` error (E83-S2, precedent: AI-2026-05-09-12). |
| Open-question indicators (urgency, driver, CR linkage) | HALT -- never auto-skip; require human input. |
| Memory save prompt at end | HALT -- require human input (Phase 4 per ADR-061). |

In YOLO mode the Val verdict is auto-displayed but a CRITICAL verdict still
halts the skill -- this is the canonical YOLO/CRITICAL interaction
established by ADR-067.

## Classification Vocabulary

Changes are classified into exactly one of three categories:

| Classification | Scope | Description |
|----------------|-------|-------------|
| **patch** | Minimal | A one-line typo fix, copy change, or trivial correction. Touches only the directly affected doc. Does NOT cascade to PRD, architecture, epics, test plan, threat model, or traceability. |
| **enhancement** | Moderate | A story-level change such as a new acceptance criterion on an existing story. Cascades to epics + test plan + traceability. Leaves PRD, architecture, and threat model untouched unless impact is explicitly flagged. |
| **feature** | Full | A net-new user-visible capability. Full cascade across PRD, architecture, epics, test plan, threat model, and traceability. |

## Cascade Matrix

The cascade matrix defines which artifacts are updated for each
classification:

| Artifact | patch | enhancement | feature |
|----------|-------|-------------|---------|
| PRD (`docs/planning-artifacts/prd.md`) | -- | -- | YES |
| Architecture (`docs/planning-artifacts/architecture.md`) | -- | -- | YES |
| Epics & Stories (`docs/planning-artifacts/epics-and-stories.md`) | -- | YES | YES |
| Test Plan (`docs/test-artifacts/test-plan.md`) | -- | YES | YES |
| Threat Model (`docs/planning-artifacts/threat-model.md`) | -- | -- | YES |
| Traceability (`docs/test-artifacts/traceability-matrix.md`) | -- | YES | YES |

"--" means the artifact is NOT touched for that classification. "YES"
means the artifact IS updated via the appropriate sub-workflow.

## Steps

### Step 1 -- Capture Feature Scope

- Ask: Describe the new feature, enhancement, or fix you want to add.
- Ask: What is the **urgency**? Vocabulary: critical / high / medium / low.
  - critical -- blocking production or active customer impact.
  - high -- important and time-bound, fits next sprint.
  - medium -- normal backlog priority.
  - low -- nice-to-have, no time pressure.
- Ask: What is the **driver**? Vocabulary: user-request / bug-report /
  tech-debt / opportunity.
  - user-request -- explicit ask from a user, customer, or stakeholder.
  - bug-report -- defect, regression, or incorrect behaviour.
  - tech-debt -- internal quality, maintainability, or refactor.
  - opportunity -- new market, capability, or strategic improvement.
- Ask: Is this linked to a change request? If so, provide the CR ID.
- If CR exists: read `docs/planning-artifacts/change-request-{cr_id}.md`
  for context (impact analysis, approval status).
- Generate `feature_id` in the format `AF-{date}-{N}` where `{date}` is the
  current date (`AF-{YYYY-MM-DD}-{N}`, e.g. `AF-2026-04-26-1`) and `{N}`
  is a monotonically increasing integer for that date. To resolve `{N}`,
  scan `docs/planning-artifacts/epics-and-stories.md` and any prior
  `docs/planning-artifacts/assessment-AF-{date}-*.md` artifacts; use the
  highest existing index for today plus one, or `1` if none exist.
- Classify the change as **patch**, **enhancement**, or **feature** based
  on scope analysis.
- Present the scope summary to the user for confirmation before proceeding:
  - Feature ID: {feature_id}
  - Change: {description}
  - Classification: {patch / enhancement / feature}
  - Urgency: {critical / high / medium / low}
  - Driver: {user-request / bug-report / tech-debt / opportunity}
  - CR: {cr_id or "none"}
  - Expected cascade: {list of artifacts that will be updated per the
    cascade matrix}

### Step 2 -- Val Review Gate (mandatory verdict surfacing)

This step is the canonical Val review gate. It restores the validation
gate that previously ran silently inside the cascade subagents (the
regression class closed by ADR-063) and is hardened under E83-S1 with two
fail-closed primitives at the Step 2 boundary: (1) an `AskUserQuestion`
substrate-enforced halt at gate entry, (2) a sentinel checkpoint JSON
written on Val PASS that `finalize.sh` validates before cascade completion.

> **Parent thread invocation required (E83-S2, precedent:
> AI-2026-05-09-12, enforcement: ADR-063 amendment / AF-2026-05-09-5).**
>
> Val MUST be dispatched as a `context: fork` subagent via the Agent tool.
> There is NO patch-mode exception -- patch, enhancement, and feature
> classifications all run the Val gate unconditionally.
>
> If the Agent tool is not exposed in the current invocation context
> (e.g., the skill itself was spawned under `context: fork` without
> `Agent` in the allowlist, or a downstream fork stripped the Agent tool
> from the inherited toolset), the skill MUST HALT immediately with the
> error: `Val gate cannot dispatch (Agent tool not exposed). Re-invoke /gaia-add-feature from a parent orchestrator thread.`
>
> The HALT message above is the canonical error string -- the parent
> orchestrator must re-invoke /gaia-add-feature from a parent orchestrator thread to recover; never inline-judge the Val gate.
>
> Do NOT self-judge the Val gate inline, do NOT compose a synthetic
> ADR-037 return in the parent thread, do NOT pass off inline review as
> a Val outcome. The 2026-05-09 audit (AF-2026-05-09-3 / AF-2026-05-09-4)
> found that LLM under Auto Mode self-licensed exactly this bypass --
> the ADR-063 amendment closes it as a hard contract: Val verdicts
> originate ONLY from a real Agent-tool dispatch.

#### Step 2a -- AskUserQuestion precondition (substrate halt)

Before the Agent-tool dispatch to Val, the LLM MUST emit an
`AskUserQuestion` tool call presenting the cascade plan and the intake
data captured in Step 1. The substrate halts the turn pending user input
under Auto Mode -- this is the empirically-verified primitive
(`feedback_askuserquestion_under_automode.md`, 2026-05-09) that closes
the "auto-mode self-judgment" bypass class. The user's explicit
acknowledgement is what unblocks the Val dispatch below. Substitute
primitives — output-stream signaling, hook-based interception, or
polling loops in user-space — are bypassed under Auto Mode and must
not replace the substrate-enforced halt (the gaia-meeting precedent
fixed in E76-S9).

The AskUserQuestion call is the SOLE interactive boundary primitive at
Step 2 entry (TC-VFC-7). It is required under both interactive and Auto
Mode invocations.

#### Step 2b -- Val dispatch + sentinel write

- Spawn a Val subagent via the Agent tool with `context: fork`,
  `model: claude-opus-4-7`, `effort: high`, and the read-only tool
  allowlist `[Read, Grep, Glob, Bash]` per ADR-045 and ADR-074 contract C2
  (Val opus pin). Pass the intake data captured in Step 1 (feature_id,
  description, classification, urgency, driver, CR linkage, expected
  cascade).
- **Non-opus mismatch guard (ADR-074 contract C2, AC3).** If a test
  fixture or downstream override forces a non-opus model into the dispatch
  context, this skill MUST emit the canonical WARNING `Val dispatch on
  non-opus model — forcing opus per ADR-074 contract C2` and force
  `model: claude-opus-4-7` before invoking Val. Silent degradation is
  forbidden.
- [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]
- Val validates the intake against the codebase and ground truth and
  returns the ADR-037 structured schema:
  `{ status, summary, artifacts, findings, next }`.
- Apply the Subagent Dispatch Contract above:
  1. Display `status` and `summary` inline.
  2. List every finding with its severity, scope, and recommended action.
  3. **Halt on CRITICAL** -- if `status == "CRITICAL"` or any finding has
     `severity == "CRITICAL"`, HALT the skill before cascade execution
     with an actionable error message that includes the finding text and
     suggested resolution. Do NOT proceed to Step 3. Do NOT emit an
     assessment-doc -- the cascade did not run.
  4. Display WARNING findings inline; record them for the assessment-doc.
  5. Log INFO findings to the checkpoint and assessment-doc.
- In YOLO mode the verdict is auto-displayed (no `[c]/[y]/[e]` pause) but
  a CRITICAL verdict still HALTS per ADR-067. The Step 2a AskUserQuestion
  call is NOT bypassed in YOLO mode -- it is the substrate-enforced halt
  that protects against silent gate skips.
- After Val returns a non-CRITICAL verdict (PASS or WARNING), MUST write
  the sentinel via `scripts/write-val-sentinel.sh`:

  ```
  printf '%s' "$VAL_RETURN_JSON" \
    | "${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/write-val-sentinel.sh" \
        --feature-id "$FEATURE_ID"
  ```

  The writer constructs the sentinel JSON via `jq -n` (NOT via heredoc /
  `cat <<EOF`), validates the required keys (status enum, summary,
  findings array, agent=val), and writes atomically (sibling tempfile +
  `mv`). The sentinel path is
  `_memory/checkpoints/add-feature-${FEATURE_ID}-val-dispatched.json`.

  `finalize.sh` validates the sentinel before allowing cascade completion;
  a missing or malformed sentinel HALTs the skill with stderr matching
  `Val gate sentinel missing.*re-invoke from a parent orchestrator thread`
  (FR-362, ADR-063 amendment, TC-VFC-2 / TC-VFC-3).

- Only when no CRITICAL findings remain AND the sentinel write succeeded
  does the skill proceed to the cascade steps below.

### Step 3 -- Execute Cascade (patch)

- If classification is `patch`:
  - Apply the fix directly to the affected document.
  - No cascade -- no downstream artifacts are touched.
  - Skip to Step 9 (Emit Assessment-Doc) then Step 10 (Summary).

### Step 4 -- Edit PRD (feature only)

- If classification is `feature`:
  - Delegate to the edit-prd sub-workflow via subagent: add new functional
    and non-functional requirements.
  - Capture the PRD diff -- identify NEW requirement IDs (FR-*, NFR-*)
    added.
  - Capture the cascade classification from edit-prd (architecture
    impact: NONE / MINOR / SIGNIFICANT).
  - Store: `prd_diff`, `cascade_to_arch`.
- If classification is `enhancement` or `patch`: skip this step.

### Step 5 -- Edit Architecture (feature only, if needed)

- If classification is `feature` AND `cascade_to_arch != NONE`:
  - Delegate to the edit-architecture sub-workflow via subagent.
  - Capture the architecture diff -- new ADRs, changed sections.
  - Store: `arch_diff`.
- If `cascade_to_arch == NONE`: inform the user "No architecture changes
  needed" and skip.
- If classification is `enhancement` or `patch`: skip this step.

### Step 6 -- Edit Test Plan (enhancement and feature)

- If classification is `enhancement` or `feature`:
  - Check if `docs/test-artifacts/test-plan.md` exists. If not, recommend
    running `/gaia-test-design`.
  - If the test plan exists: delegate to the edit-test-plan sub-workflow
    via subagent.
  - **Orchestrator trigger inheritance (FR-353 / E46-S5).** When
    delegating to `/gaia-edit-test-plan`, pass the three inheritance
    contract fields as named invocation parameters:
    - `feature_description` -- the feature scope captured in Step 1
    - `prd_diff` -- the PRD diff captured in Step 4 (empty for
      `enhancement` classification, since Step 4 is skipped -- pass only
      when populated)
    - `arch_diff` -- the architecture diff captured in Step 5 (empty for
      `enhancement` classification, since Step 5 is skipped -- pass only
      when populated)
    Pass only the subset that is populated for the current classification.
    `/gaia-edit-test-plan` Step 2 handles the partial-inheritance case by
    prompting for missing fields. Do NOT pass empty strings for skipped
    fields -- omit them so the downstream three-case branch routes to
    PARTIAL rather than FULL with empty values.
  - Capture test plan additions (new test case IDs).
  - Store: `test_diff`.
- If classification is `patch`: skip this step.

### Step 7 -- Edit Threat Model (feature only)

- If classification is `feature`:
  - Check if `docs/planning-artifacts/threat-model.md` exists.
  - If it exists: update the threat model to account for new attack
    surfaces introduced by the feature.
  - Store: `threat_model_diff`.
- If classification is `enhancement` or `patch`: skip this step.

### Step 8 -- Add Feature Stories (enhancement and feature)

- If classification is `enhancement` or `feature`:
  - Delegate to the add-stories sub-workflow via subagent, passing
    `feature_description`, `prd_diff`, `arch_diff`, and `cr_id`.
  - Capture new story keys and epic assignments.
  - Store: `new_stories`.
  - Per user rule `feedback_priority_flag_never_auto_set.md`, stories
    created by this skill MUST have `priority_flag: null` regardless of
    urgency. Triage and `/gaia-sprint-plan` decide priority sequencing.

    > **Memory rule (verbatim — survives context compaction):**
    >
    > Stories produced by /gaia-add-feature MUST have priority_flag: null
    > by default. Do NOT auto-set priority_flag:
    > 'next-sprint' during triage or cascade, even when:
    > - The driver is high-urgency.
    > - All stories are P1.
    > - The brief classifies the work as technical-debt / regression
    >   remediation.
- If classification is `patch`: skip this step.

### Step 8b -- Update Traceability (enhancement and feature)

- If classification is `enhancement` or `feature`:
  - Delegate to the traceability sub-workflow via subagent to regenerate
    the traceability matrix.
  - Verify new FR / NFR IDs, test cases, and stories are linked.
- If classification is `patch`: skip this step.

### Step 8c -- Re-shard touched documents (E53-S244, ADR-070)

Cascade execution may have written to one or more monolith documents:
`docs/planning-artifacts/prd.md`, `docs/planning-artifacts/architecture.md`,
and/or `docs/planning-artifacts/epics-and-stories.md` (and, transitively
via Step 8 sub-workflow, story files and traceability). Once the cascade
finishes, MUST re-shard each touched monolith so the per-section shards
stay aligned with the monolith. This step honours the monolith-vs-shard
sync contract in ADR-070 (extended in E53-S243) — it is not optional
unless the user passes `--monolith-only` for an explicit atomic same-PR
edit (e.g., when the cascade and the re-shard will land in the same
commit and the user prefers to invoke `/gaia-shard-doc` manually at
PR-merge time).

- If `$ARGUMENTS` contains `--monolith-only`: skip this step entirely.
  Record `reshard: skipped (--monolith-only)` in the assessment-doc
  Cascade Plan section. The user takes responsibility for re-running
  `/gaia-shard-doc` (or merging shards back to the monolith) before
  commit.
- Otherwise, build the touched-monolith set from the prior cascade steps:
  - if Step 4 (Edit PRD) ran -> include `docs/planning-artifacts/prd.md`
  - if Step 5 (Edit Architecture) ran -> include
    `docs/planning-artifacts/architecture.md`
  - if Step 8 (Add Feature Stories) ran -> include
    `docs/planning-artifacts/epics-and-stories.md`
  - for `patch` classification: include only the directly-edited monolith
    (no cascade ran)
- For each monolith in the touched set, invoke `/gaia-shard-doc <path>`.
  `/gaia-shard-doc` is unchanged in this story — only the cascade
  invocation pattern changes (AC4 of E53-S244).
- After all re-shards return, run
  `${CLAUDE_PLUGIN_ROOT}/scripts/check-monolith-shard-sync.sh` against
  the project root. The check is advisory (always exits 0). If it emits
  any `WARNING` lines, surface those WARNINGs to the user and record
  them in the assessment-doc Val Findings Summary section so the audit
  trail captures the residual drift — they indicate one or more
  re-shards did not converge and the user must investigate before
  commit.
- Record the per-monolith `reshard: invoked (gaia-shard-doc)` decisions
  in the assessment-doc Cascade Plan section so the audit trail captures
  the invocations.

This step runs in YOLO mode automatically — re-sharding is deterministic
per ADR-042 and needs no user prompt. It is purely additive: skills that
did not previously include this step continue to function for backwards
compatibility (AC8 of E53-S244).

### Step 9 -- Emit Assessment-Doc Artifact

This step runs only after the cascade completes successfully and Val
returned no CRITICAL findings in Step 2. If Step 2 halted on CRITICAL,
no assessment-doc is emitted -- the user must resolve the CRITICAL
finding first and re-invoke the skill.

- Write the assessment-doc to
  `docs/planning-artifacts/assessment-{feature_id}.md` with the following
  sections:

  - **Header** -- feature_id, date, author, classification, urgency,
    driver, CR linkage.
  - **Classification** -- the chosen classification (patch / enhancement /
    feature) with a one-line scope rationale.
  - **Affected Artifacts** -- the list of artifacts touched per the
    cascade matrix for the chosen classification, with the actual diff
    summaries captured during the cascade. Skipped artifacts are listed
    with "(skipped: classification = {patch|enhancement})" so the audit
    trail is explicit.
  - **Cascade Plan** -- a numbered list of the sub-workflows dispatched in
    order, with the resulting diff IDs (new FR / NFR IDs, ADR numbers,
    test case IDs, story keys) captured at each step. For patch
    classification this section reads "(no cascade -- direct edit
    applied)".
  - **Val Findings Summary** -- the verdict from Step 2 (PASS / WARNING)
    plus the full list of WARNING and INFO findings with their severity,
    scope, and recommended action. CRITICAL findings never appear here
    because they would have halted the skill before this step.

- The assessment-doc serves as the audit trail: who proposed what change,
  what Val said about it, what artifacts ended up touched, and which
  follow-up stories were created. It is written ONLY after the cascade
  completes successfully.
- Before the Finalize block runs, MUST export `FEATURE_ID` so the
  `finalize.sh` E83-S1 sentinel guard can locate the Val-dispatch
  sentinel: `export FEATURE_ID="${feature_id}"`. The guard treats an
  unexported `FEATURE_ID` as a legacy fixture path (skipped) -- production
  cascades MUST always export it.

### Step 10 -- Summary

- Present the final summary:

  **Change Addition Complete: {description}**

  | Artifact | Status | Details |
  |----------|--------|---------|
  | Feature ID | {feature_id} | {AF-YYYY-MM-DD-N} |
  | Classification | {patch / enhancement / feature} | {scope rationale} |
  | Urgency | {critical / high / medium / low} | -- |
  | Driver | {user-request / bug-report / tech-debt / opportunity} | -- |
  | Val Verdict | {PASS / WARNING} | {N WARNING findings} |
  | PRD | {Updated / Skipped} | {new FR/NFR IDs or "N/A"} |
  | Architecture | {Updated / Skipped} | {new ADRs or "N/A"} |
  | Test Plan | {Updated / Skipped / Not found} | {new test case IDs or reason} |
  | Threat Model | {Updated / Skipped} | {changes or "N/A"} |
  | Stories | {Created / Skipped} | {new story keys or "N/A"} |
  | Traceability | {Regenerated / Skipped} | {linkage status} |
  | Assessment Doc | {emitted / skipped} | docs/planning-artifacts/assessment-{feature_id}.md |

  **Next steps:**
  - For each new story: run `/gaia-create-story {story_key}` to elaborate.
  - To start development: run `/gaia-sprint-plan` or `/gaia-correct-course`.
  - To audit this change later: read
    `docs/planning-artifacts/assessment-{feature_id}.md`.

## References

- ADR-037 -- Structured subagent return schema
  (`status` / `summary` / `artifacts` / `findings` / `next`).
- ADR-041 -- Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks.
- ADR-042 -- Scripts-over-LLM for Deterministic Operations. The Val gate
  and assessment-doc emit are LLM-judgment steps and intentionally do NOT
  introduce new scripts.
- ADR-045 -- Review Gate via sequential `context: fork` subagents.
  Val invocations follow this isolation pattern with a read-only tool
  allowlist.
- ADR-063 -- Subagent Dispatch Contract -- Mandatory Verdict Surfacing.
- ADR-067 -- YOLO Mode Contract -- Consistent Non-Interactive Behavior.
- FR-323 -- Add-feature orchestrator with classification vocabulary and
  cascade matrix.
- FR-362 -- Restore the validation gate inside `/gaia-add-feature`.
- ADR-070 -- Auto-sharding policy; monolith-vs-shard sync contract.
- E53-S243 -- Static `monolith-shard-sync` check + ADR-070 amendment.
- E53-S244 -- Cascade-skill auto-invoke for `/gaia-shard-doc`
  (Step 8c above + `--monolith-only` opt-out).
- AF-2026-05-09-5 / ADR-063 amendment -- "Val verdicts originate ONLY
  from a real Agent-tool dispatch" hard contract; closes the inline-Val
  + auto-judge-in-patch-mode bypass class.
- AI-2026-05-09-12 -- Action item flagging the
  `/gaia-add-feature` Val-gate fail-open under `context: fork` (precedent
  for the E83-S2 prose-hardening clauses above).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/finalize.sh
