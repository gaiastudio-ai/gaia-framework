---
name: gaia-add-feature
description: Triage and route a fix, enhancement, or feature through only the affected artifacts. Classifies as patch/enhancement/feature and cascades accordingly -- updating PRD, architecture, epics, test plan, threat model, and traceability as needed (FR-323, FR-362). Surfaces Val verdicts (PASS/WARNING/CRITICAL) per ADR-063 and emits an assessment-doc audit trail.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE"
```

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
- **No inline Val — Val MUST be dispatched via the main-turn Agent tool**
  (per ADR-093 / ADR-104; migrated from the prior `context: fork` model by
  E87-S5). After dispatch, the skill MUST source
  `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke
  `assert_agent_envelope {sentinel_path}` against the envelope sentinel
  the Val persona writes (E87-S2 contract); on non-zero exit HALT with the
  canonical error string. The LLM MUST NOT pass off its own inline review
  as a Val outcome, MUST NOT compose a synthetic ADR-037 return JSON in
  the parent thread, and MUST NOT set `status: PASS` without a real
  Agent-tool dispatch + envelope-assert success. If the Agent tool is not
  available in the current context (e.g., running under a fork that did
  not allowlist `Agent`), HALT immediately with the parent-thread
  re-invoke message in Step 2 -- do NOT self-judge the Val gate from the
  parent thread. The E83 four-layer fail-closed enforcement
  (E83 dispatch checkpoint + AskUserQuestion precondition + prose
  hardening + bats anti-pattern check) remains intact; E87 adds the
  envelope-assert as a NEW layer on top of E83, not as a replacement.
- **Dispatch prompt hygiene (AI-2026-05-13-11).** The Val dispatch
  prompt MUST contain ONLY the raw Step 1 intake fields. The
  orchestrator MUST NOT (a) instruct Val on the sentinel JSON shape,
  field names, or hash basis — the validator persona's Sentinel-Write
  Contract at `plugins/gaia/agents/validator.md` is the single source
  of truth; (b) pre-load a prior run's findings, verdict, or
  recommendations into a re-dispatch prompt — the substrate's
  content-integrity guard flags this as forgery and the cascade MUST
  HALT; (c) invent an `artifact_path` value — pass `feature_id` as the
  literal `artifact_path` so caller and persona hash the same string.
  See Step 2b "Dispatch prompt hygiene" block for the full rationale
  and the 2026-05-13 incident precedent.

## Subagent Dispatch Contract

This skill follows the framework-wide Subagent Dispatch Contract (ADR-063).
Every Val invocation is dispatched via the **main-turn Agent tool** (per
ADR-093 / ADR-104; migrated from the prior `context: fork` per ADR-045
model by E87-S5) with a read-only tool allowlist
`[Read, Grep, Glob, Bash, Write]` (Val needs `Write` to emit the envelope
sentinel from inside its own execution context per the E87-S2 Sentinel-Write
Contract). Dispatch is pinned to `model: claude-opus-4-7` and `effort: high`
per ADR-074 contract C2 (Val opus pin — validation rigor is the contract).

**Envelope-assert step (E87-S5 / ADR-104).** After the Agent call returns
and BEFORE consuming the Val verdict, the skill MUST source
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke
`assert_agent_envelope {sentinel_path}` where
`{sentinel_path} = _memory/checkpoints/val-envelope-{sha256(artifact_path) first 16 hex}.json`.
On non-zero exit, HALT with the canonical error string
`HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at {path}` —
DO NOT fall through to a self-judged verdict. Closes the regression class
documented in `feedback_add_feature_val_gate_fails_open.md`
(AI-2026-05-09-12).

**E83 + E87 sentinel coexistence (AC4).** Two layered sentinels coexist
post-migration — they answer different questions:
- E83 dispatch checkpoint
  (`_memory/checkpoints/add-feature-{feature_id}-val-dispatched.json`) —
  validated by `finalize.sh`, proves dispatch HAPPENED.
- E87 envelope sentinel
  (`_memory/checkpoints/val-envelope-{artifact-hash}.json`) — validated by
  `assert_agent_envelope`, proves the dispatcher was AUTHENTIC (Val persona).
Both MUST pass for the cascade to proceed. The two sentinel paths are
distinct slugs (`add-feature-...val-dispatched.json` vs `val-envelope-...json`)
and do NOT collide.

After Val returns:

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

### Step 1c -- Re-validate prereqs under captured classification (E89-S1, FR-AFE-1)

The initial `setup.sh` invocation ran under the default `enhancement` classification. Now that Step 1 has captured the actual classification, re-invoke `setup.sh` so the test-plan / traceability gates fire AGAINST that classification:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/setup.sh \
  --classification "$CLASSIFICATION" \
  --feature-id "$FEATURE_ID"
```

**Behaviour by classification (per E89-S1 AC3..AC5):**

- `patch`: the test-plan / traceability gates are SKIPPED. The re-invocation is harmless.
- `enhancement` / `feature`: the test-plan and traceability presence gates fire. If either artifact is missing, `setup.sh` HALTs with one of:
  - `HALT: test-plan.md is missing — run /gaia-test-design first, then re-invoke /gaia-add-feature {feature_id}`
  - `HALT: traceability-matrix.md is missing — run /gaia-trace first, then re-invoke /gaia-add-feature {feature_id}`

These HALTs are TERMINAL — the cascade does NOT proceed to Step 2. The user must bootstrap the missing artifact via the named skill, then re-invoke `/gaia-add-feature` with the feature_id. The path forms `validate-gate.sh` resolves (flat / strategy / sharded per ADR-070, ADR-072) are owned by `validate-gate.sh`; this skill does not duplicate that lookup.

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
> Val MUST be dispatched via the **main-turn Agent tool** (per ADR-093 /
> ADR-104; migrated from the prior `context: fork` per ADR-045 model by
> E87-S5). There is NO patch-mode exception -- patch, enhancement, and
> feature classifications all run the Val gate unconditionally.
>
> If the Agent tool is not exposed in the current invocation context
> (e.g., the skill itself was spawned under a stripped-down fork without
> `Agent` in the allowlist, or a downstream context stripped the Agent
> tool from the inherited toolset), the skill MUST HALT immediately with
> the error: `Val gate cannot dispatch (Agent tool not exposed). Re-invoke /gaia-add-feature from a parent orchestrator thread.`
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

**Dispatch prompt hygiene (AI-2026-05-13-11, 2026-05-13 incident).** The
Val dispatch prompt MUST contain ONLY the raw intake fields captured in
Step 1 (`feature_id`, `description`, `classification`, `urgency`,
`driver`, `cr_id`, `expected cascade`). The orchestrator MUST NOT:

- **Override Val's persona Sentinel-Write Contract.** Do NOT instruct
  Val on the sentinel JSON shape, field names, hash basis, or write
  path. The validator persona at `plugins/gaia/agents/validator.md`
  §Sentinel-Write Contract is the single source of truth for the
  sentinel; if the caller supplies a custom shape (e.g. a JSON template
  pasted into the dispatch prompt), Val will obey the caller and write
  a malformed sentinel that fails `assert_agent_envelope` at the
  `persona_sig`-presence check. The 2026-05-13 incident reproduced this
  exactly — first dispatch wrote a sentinel without `persona_sig`
  because the prompt told Val to use a custom `{agent, artifact, status,
  summary, timestamp}` shape.

- **Pre-load prior-run findings on re-dispatch.** If a first dispatch
  fails (malformed sentinel, wrong artifact_path, errored before write,
  etc.) and a retry is required, the retry prompt MUST be composed from
  the raw intake as if the prior run never happened. Do NOT include the
  first run's findings list, verdict, severity tags, or recommendations.
  The Claude Code substrate has an active content-integrity guard that
  flags re-dispatches whose prompt pre-synthesizes the envelope and asks
  the sub-agent to rubber-stamp it; the canonical flag text is
  `SECURITY WARNING: ...content-integrity violation and bypass of the
  Val dispatch gate the user's memory explicitly warns about`. On a
  substrate flag the orchestrator MUST HALT the cascade — never consume
  a flagged sentinel as authoritative. Anchored to user memory rule
  `feedback_val_redispatch_no_preload.md`.

- **Pass `feature_id` as `artifact_path`.** Per the hash-basis
  reconciliation above, the dispatch prompt MUST tell Val the
  `artifact_path` for sentinel computation is the literal `feature_id`
  string (`AF-YYYY-MM-DD-N`). This is the SAME convention validator.md
  §Sentinel-Write Contract documents for in-memory intake validation —
  the orchestrator does not invent a new value, it forwards `feature_id`
  unchanged as the `artifact_path` the persona hashes.

These three rules are operator-error vectors verified against an actual
incident on 2026-05-13 (AF-2026-05-13-1 cascade attempt). Each is
fail-closed: the substrate or `assert_agent_envelope` will HALT a
non-compliant dispatch — but the friction of recovery is high, so
adhere to the hygiene rules at dispatch time.

- Spawn a Val subagent via the **main-turn Agent tool** (per ADR-093 /
  ADR-104; migrated from the prior `context: fork` model by E87-S5),
  `model: claude-opus-4-7`, `effort: high`, and the read-only tool
  allowlist `[Read, Grep, Glob, Bash, Write]` (Val needs `Write` post-E87-S2
  to emit the envelope sentinel from inside its own execution context) per
  ADR-074 contract C2 (Val opus pin). Pass the intake data captured in
  Step 1 (feature_id, description, classification, urgency, driver, CR
  linkage, expected cascade). Per the Dispatch prompt hygiene block
  above, pass `feature_id` as the literal `artifact_path` for sentinel
  computation and DO NOT include a sentinel JSON template or any
  pre-synthesized findings in the prompt.
- **Envelope-assert step (E87-S5 / ADR-104).** After the Agent call
  returns and BEFORE consuming the Val verdict, source
  `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invoke
  `assert_agent_envelope {sentinel_path}` where
  `{sentinel_path} = _memory/checkpoints/val-envelope-{sha256(artifact_path) first 16 hex}.json`.
  For `/gaia-add-feature` the validation target is an in-memory intake
  object, not an on-disk artifact — the orchestrator MUST pass the
  `feature_id` (e.g. `AF-2026-05-13-1`) as the literal `artifact_path`
  string to Val so both sides compute the same sha256. The validator
  persona's Sentinel-Write Contract (§Sentinel-Write Contract in
  `plugins/gaia/agents/validator.md`) computes the sentinel path as
  `sha256(artifact_path)`; passing `feature_id` as `artifact_path` keeps
  caller and persona in agreement. This is the SINGLE source of truth
  for the hash basis — the prior text "sha256(feature_id)" was a
  drift defect (AI-2026-05-13-11) and is corrected here.
  On non-zero exit, HALT with the canonical error string `HALT: Val agent
  envelope assertion failed — sentinel absent, malformed, or forged at
  {path}` — DO NOT fall through to a self-judged verdict. The cascade
  MUST NOT proceed without a validated assessment. This closes the
  fail-open regression class documented in
  `feedback_add_feature_val_gate_fails_open.md` (AI-2026-05-09-12) at the
  authenticity layer; the existing E83 dispatch-checkpoint precondition
  (validated by `finalize.sh`) continues to guard the dispatch-happened
  layer. See the Subagent Dispatch Contract section above for the
  E83 + E87 coexistence rationale and distinct sentinel paths.
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
  - **Prereq (E89-S1, FR-AFE-1):** the test-plan presence gate fires in
    `setup.sh` via `validate-gate.sh test_plan_exists` when
    `--classification=enhancement|feature` is passed. Arriving at Step 6
    implies the test plan exists at the path `validate-gate.sh test_plan_exists`
    resolves (flat `docs/test-artifacts/test-plan.md` OR strategy/ form OR
    sharded form, per ADR-070, ADR-072). If the gate failed, this skill
    has already HALTed with the canonical message `HALT: test-plan.md is
    missing — run /gaia-test-design first, then re-invoke /gaia-add-feature
    {feature_id}` — see Step 1c re-invocation below.
  - Delegate to the edit-test-plan sub-workflow via subagent.
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

### Step 8a -- Intake-time dispatch-verb enforcement (E88-S2, FR-DPD-2)

For every story produced by Step 8 (classification `enhancement` or `feature`), invoke the deterministic intake check BEFORE 8b updates traceability:

```bash
for story_path in "${new_story_paths[@]}"; do
  !scripts/lib/intake-dispatch-verb-check.sh --story-file "$story_path"
done
```

The helper sources `scripts/lib/dispatch-verb-match.sh` (E88-S1) and HALTs with the canonical message `HALT: dispatch-verb AC #<n> ("<excerpt>") lacks a companion integration-test AC. Add an integration-test AC, OR annotate this AC with <!-- gaia:contract-only: <reason> --> if the dispatch is contract-only.` when a story has a dispatch-verb AC without integration coverage and without a contract-only override.

This step MUST run AFTER stories are written by Step 8 (the helper needs the file on disk) and BEFORE Step 8b (traceability would otherwise record stories that fail the drift-prevention contract). The LLM never inlines the taxonomy or re-implements the matcher — ADR-107 SSOT contract.

If classification is `patch`: skip this step.

### Step 8b -- Update Traceability (enhancement and feature)

- If classification is `enhancement` or `feature`:
  - **Prereq (E89-S1, FR-AFE-1):** the traceability-matrix presence gate
    fires in `setup.sh` via `validate-gate.sh traceability_exists` when
    `--classification=enhancement|feature` is passed. Arriving at Step 8b
    implies the matrix exists at the path `validate-gate.sh traceability_exists`
    resolves (flat / strategy / sharded per ADR-070, ADR-072). If the gate
    failed, this skill has already HALTed with the canonical message
    `HALT: traceability-matrix.md is missing — run /gaia-trace first, then
    re-invoke /gaia-add-feature {feature_id}` — see Step 1c re-invocation.
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
- AI-2026-05-13-11 -- Action item tightening the Val-dispatch contract
  after the 2026-05-13 AF-2026-05-13-1 incident: reconciles the hash
  basis between SKILL.md and validator.md, adds Dispatch prompt hygiene
  prose covering caller-side sentinel-shape override and prior-findings
  pre-loading on re-dispatch.

## Changelog

- **2026-05-14 — E89-S1 — Steps 6/8b HALT-or-bootstrap on missing canonical test artifacts (FR-AFE-1, AI-2026-05-13-1 friction-point 1).** `setup.sh` gained two new optional CLI flags (`--classification <patch|enhancement|feature>`, `--feature-id <AF-{date}-{N}>`) parsed BEFORE resolve-config so the classification is available when gates fire. Under classification `enhancement` / `feature`, `setup.sh` invokes `validate-gate.sh test_plan_exists` and `validate-gate.sh traceability_exists` (extending the existing `prd_exists` / `epics_and_stories_exists` consumer pattern at L62/L65). On either gate failure, `setup.sh` `die`'s with canonical stderr `HALT: test-plan.md is missing — run /gaia-test-design first, then re-invoke /gaia-add-feature {feature_id}` (or the `/gaia-trace` mirror). Patch classifications skip both gates. SKILL.md Steps 6 + 8b prose rewritten to document the prereq contract; Step 1c re-invocation added so the classification captured in Step 1 flows back to `setup.sh`. Closes the friction-point 1 drift surfaced by the AF-2026-05-13-1 smoke test (Step 6 silently skipped its Test Plan edit because the artifact did not yet exist on disk).
- **2026-05-14 — E88-S2 — Intake-time dispatch-verb enforcement (FR-DPD-2, ADR-107, AI-2026-05-13-4).** Added Step 8a between Step 8 (Add Feature Stories) and Step 8b (Update Traceability). The step invokes `scripts/lib/intake-dispatch-verb-check.sh --story-file <path>` for every story produced by Step 8. The helper sources `scripts/lib/dispatch-verb-match.sh` (E88-S1) and HALTs with the canonical message when a dispatch-verb AC lacks a companion integration-test AC and has no `<!-- gaia:contract-only: <reason> -->` override. Closes the drift class documented in AI-2026-05-13-4 (dispatch-verb ACs landing without integration coverage). Story-template.md and validate-frontmatter.sh gain a new 16th required `delivered:` boolean field (default `true`) — the bookkeeping primitive E88-S6 will consume for retroactive E76-S10 back-fill.
- **2026-05-13 — E87-S7 — Sentinel-Write Writer Shift (ADR-105 amends ADR-104).** Following the AI-2026-05-13-13 incident, the Val sentinel write has been relocated from the Val sub-agent context to the orchestrator's main turn. Val now RETURNS the sentinel content as a `sentinel_envelope` field inside the ADR-037 envelope; the orchestrator parses the field and writes the sentinel via the new helper `plugins/gaia/scripts/lib/write-val-envelope.sh`. This closes the Claude Code substrate content-integrity false-fire that blocked the cascade end-to-end after E87-S5 / E87-S6 landed. Forgery resistance preserved via `persona_sig` binding to validator.md's on-disk sha256 (NFR-064 unchanged). The Step 2b dispatch contract now reads: (1) spawn Val via Agent tool; (2) parse `sentinel_envelope` from Val's return; (3) write sentinel via `write-val-envelope.sh --envelope "$sentinel_envelope"` (captures the path on stdout); (4) source `assert-agent-envelope.sh`; (5) `assert_agent_envelope` against the captured path; (6) HALT on non-zero; (7) consume verdict. The E83 four-layer fail-closed enforcement (E83 dispatch checkpoint, AskUserQuestion precondition, dispatch prompt hygiene, bats anti-pattern check) is preserved intact. Coverage: TC-WVE-1..10 in `plugins/gaia/tests/write-val-envelope.bats` (helper-level); existing TC-VBR-11..11g in `plugins/gaia/tests/val-bridge-migration.bats` continues to pass (assertion logic unchanged); validator.md §Sentinel-Write Contract rewritten to specify the return-channel.
- **2026-05-13 — AI-2026-05-13-11 — Dispatch prompt hygiene + hash-basis reconcile.** Fixed three operator-error vectors surfaced by the 2026-05-13 AF-2026-05-13-1 cascade attempt (substrate content-integrity HALT). (a) Reconciled the envelope sentinel hash basis: Step 2b body had drifted to `sha256(feature_id)` while the Subagent Dispatch Contract section (L114) and validator persona §Sentinel-Write Contract both say `sha256(artifact_path)`. Step 2b now matches; the convention is documented as "pass `feature_id` as the literal `artifact_path`" so caller and persona hash the same string. Validator persona amended with the same convention. (b) Added an explicit "Dispatch prompt hygiene" block to Step 2b enumerating three forbidden patterns: caller-side sentinel JSON shape override (causes Val to write a malformed sentinel that fails `assert_agent_envelope`), prior-findings pre-loading on re-dispatch (substrate content-integrity guard flags as forgery), and `artifact_path` invention (breaks hash agreement). Anchored to memory rule `feedback_val_redispatch_no_preload.md` (also 2026-05-13). (c) Mirrored the hygiene rule into Critical Rules so it survives Step 2b skim. No script changes — `write-val-sentinel.sh` and `finalize.sh` are unchanged; the bug surface is entirely in the SKILL.md prose contract with Val.
- **2026-05-13 — E87-S5 — Val Bridge Migration, FINAL self-referential migration (ADR-104).** Migrated `/gaia-add-feature` Step 2 Val gate from `context: fork` (per ADR-045) to **main-turn Agent-tool dispatch** (per ADR-093 / ADR-104). Added the post-dispatch envelope-assert step (`source assert-agent-envelope.sh` + `assert_agent_envelope` + HALT on non-zero) at Step 2b. The E83 four-layer fail-closed enforcement (sentinel checkpoint, AskUserQuestion precondition, prose hardening, bats anti-pattern check) is preserved intact — E87 adds the envelope-assert as a NEW layer ON TOP of E83, not as a replacement. Two layered sentinels coexist at distinct paths: E83 dispatch checkpoint `_memory/checkpoints/add-feature-{feature_id}-val-dispatched.json` (validated by `finalize.sh`, proves dispatch HAPPENED) and E87 envelope sentinel `_memory/checkpoints/val-envelope-{artifact-hash}.json` (validated by `assert_agent_envelope`, proves dispatcher was AUTHENTIC Val persona). Closes `feedback_add_feature_val_gate_fails_open.md` (AI-2026-05-09-12) at the authenticity layer. Coverage by TC-VBR-11..11g in `plugins/gaia/tests/val-bridge-migration.bats`; E83 TC-VFC-* suite continues to pass.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/finalize.sh
