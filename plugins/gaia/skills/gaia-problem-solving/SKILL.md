---
name: gaia-problem-solving
description: Context-aware problem-solving skill with auto artifact gathering (30K context budget, six sub-budgets) and tiered resolution routing. Use when the user asks to "solve a problem", "run problem-solving", or wants to diagnose an issue and route it to the right fix path. Delegates analysis to Nova (problem-solver) under an explicit plan-approve-execute planning gate.
argument-hint: "[problem statement]"
allowed-tools: [Read, Write, Grep, Glob, Bash, Agent]
orchestration_class: conversational
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class conversational --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh problem-solver decision-log

# gaia-problem-solving

Context-aware problem-solving pipeline with an explicit **plan → approve →
execute** contract, auto artifact gathering against a 30K token
context budget, and tiered resolution routing (quick fix / bug /
enhancement / systemic). Produces a structured problem-solving report
at `.gaia/artifacts/creative-artifacts/problem-solving-{date}.md` and routes the
resolution into the right downstream flow (`/gaia-create-story`,
`/gaia-add-feature`, or escalation to architect / PM). Converted to
the native execution model with full functional parity against
the legacy source. The legacy-source path is intentionally
omitted from the body per the "zero legacy references"
parity check; see the References section for the parity source
pointer.

## Critical Rules

- **Always identify root cause before proposing solutions** — symptoms
  are not causes. Solutions proposed without a validated root cause
  are tech debt dressed as fixes.
- **Separate symptoms from causes** — refuse to treat symptoms.
  Escalate if the user insists on symptom-only treatment.
- **Challenge assumed constraints** — are they real (ADR-documented,
  regulatory, contractual) or inherited (nobody remembers why)?
- **NEVER interrogate the user for information that exists in project
  artifacts** — gather context automatically from PRD, architecture,
  sprint-status, test-plan, traceability matrix, decision logs, and
  codebase. Ask the user only for gaps the artifacts do not cover.
- **ALL code-change resolutions MUST route through
  `/gaia-create-story` or `/gaia-add-feature`** — no invisible work,
  no out-of-band commits. The Resolution Execution phase is the only
  path by which problem-solving produces code changes.
- **The Planning Gate is mandatory and blocking** — the skill MUST
  present a structured plan and WAIT for user approval before entering
  Resolution Classification and Resolution Execution. The skill MUST
  NOT proceed past the Planning Gate without explicit approval, and
  MUST NOT emit a problem-solving artifact if the user does not
  approve the plan.
- Delegate analysis to **Nova (`problem-solver`)** via the Agent tool
  when `plugins/gaia/agents/problem-solver.md` is registered. If the
  subagent is unavailable, fail fast — do not continue inline.
- Preserve the output contract exactly:
  `.gaia/artifacts/creative-artifacts/problem-solving-{date}.md` (date as
  `YYYY-MM-DD`). Downstream skills glob on this prefix — do not
  rename.

## Inputs

The skill begins by collecting two inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Problem statement** — describe the symptom or issue being
   experienced. Be specific — "login slow" is not actionable;
   "login P95 exceeded 3s after the 2026-04-15 deploy" is.
2. **Urgency level** — one of:
   - **critical** — production outage or data loss
   - **high** — blocks work
   - **medium** — needs attention this sprint
   - **low** — backlog candidate

If either input is missing, prompt the user before starting Context
Gathering.

## Planning Gate

This skill runs under an explicit **plan → approve → execute**
contract (matching the legacy `execution_mode: planning` semantics).

1. After Intake (Phase 1) and Context Gathering (Phase 2), the skill
   builds a structured plan describing:
   - the problem statement (verbatim) and urgency,
   - the Context Brief (what was found, by sub-budget, with keyword hit
     counts and token usage),
   - the analysis approach (which methodology — 5 Whys, Fishbone,
     TRIZ — and why),
   - the anticipated resolution classification (quick-fix, bug,
     critical, enhancement, systemic) and the downstream flow that
     will be triggered (`/gaia-create-story`, `/gaia-add-feature`, or
     escalation to architect / PM),
   - the files expected to be touched (if any) and the verification
     approach.
2. The skill presents the plan to the user and WAITS for approval.
3. If the user **approves** — proceed to Phase 3 (Problem Framing) and
   the rest of the pipeline.
4. If the user **declines / does not approve** — halt the skill
   cleanly at the planning gate. Do NOT emit a problem-solving
   artifact to `{creative_artifacts}/`. Preserve the Context Brief
   and plan as scratch state for the user to review, but do not
   write the final artifact (AC-EC1).
5. If the user **requests revisions** — accept the feedback, regenerate
   the plan, re-present, and wait again. Repeat until the user
   approves or declines.

## Context Budget (30K tokens)

The skill gathers context against a **30K token** total budget with
six sub-budgets, enforced per source:

| Source | Sub-budget | Extraction strategy |
|--------|-----------|----------------------|
| Stories | 8K tokens | SELECTIVE_LOAD on `{implementation_artifacts}/*.md` |
| Architecture | 5K tokens | SELECTIVE_LOAD on `{planning_artifacts}/architecture.md` |
| PRD | 5K tokens | SELECTIVE_LOAD on `{planning_artifacts}/prd.md` |
| Decision Logs | 3K tokens | Agent memory sidecars (PM, architect, SM) |
| Codebase | 5K tokens | Grep + recent git log on affected paths |
| Test Artifacts | 4K tokens | SELECTIVE_LOAD on `{test_artifacts}/test-plan.md` and `{test_artifacts}/traceability-matrix.md` |

**Total:** 30K tokens across six sub-budgets. These are the same
sub-budgets the legacy `workflow.yaml` declared — do not tighten or
loosen them in the conversion.

When a source's content exceeds its sub-budget, summarize extracted
sections; do not truncate silently mid-section. If the jointly gathered
context would exceed the 30K cap, drop the lowest-priority matches
first (priority order: stories > architecture > prd > codebase >
test_artifacts > decision_logs) and log the truncation in the Context
Brief's "Token Usage" section. No context-overflow crash is
permitted (AC-EC5 analogue).

## Input File Patterns

The skill reads these five SELECTIVE_LOAD input sources at
invocation time (matching the legacy `input_file_patterns` contract):

- **prd** → `{planning_artifacts}/prd.md` — PRD requirement sections
  matching keywords.
- **architecture** → `{planning_artifacts}/architecture.md` —
  architecture components, ADRs, API contracts, data models matching
  keywords.
- **sprint_status** → `{implementation_artifacts}/sprint-status.yaml` —
  current sprint state, story statuses, Review Gate rollups.
- **test_plan** → `{test_artifacts}/test-plan.md` — test coverage
  plan for the affected area.
- **traceability** → `{test_artifacts}/traceability-matrix.md` —
  requirements-to-tests mapping for the affected FR / NFR IDs.

Under the native model these are explicit read directives — the skill
invokes the foundation path-resolution script at skill-invocation time
to resolve the `{planning_artifacts}`, `{implementation_artifacts}`,
and `{test_artifacts}` path variables before each read. Any source
that cannot be resolved or does not exist is silently skipped (no
error) unless it is a required data file (see below).

## Data Files

The skill references one required data file:

- **solving-methods.csv** → `{data_path}/solving-methods.csv` — the
  systematic-methodology catalog (5 Whys, Fishbone, TRIZ, Theory of
  Constraints, First Principles, etc.) used to drive root-cause
  analysis.

The `{data_path}` template is resolved at skill-invocation time by the
foundation path-resolution script (matches the legacy `{data_path}`
resolution mechanism).

### Missing data-file handling (AC-EC3)

If `{data_path}/solving-methods.csv` is missing or unreadable, emit
an actionable error: `required data file
'{data_path}/solving-methods.csv' not found — the problem-solving
skill requires the methodology catalog. Restore the CSV or run the
foundation path-resolution check before retrying.` Halt before any
output artifact is written.

## Pipeline

The pipeline runs eleven phases across three phase groups. The
Planning Gate sits between Phase 2 (Context Gathering) and Phase 3
(Problem Framing) — nothing downstream of the gate executes without
approval.

### Phase Group 1 — Intake

**Phase 1 — Problem Intake.** Collect the problem statement and urgency
level. Extract domain keywords by parsing for:

1. **File names** — any foo.ts, bar.yaml, config.json patterns
   mentioned.
2. **Module names** — recognized GAIA module names (core, lifecycle,
   dev, creative, testing) or project-specific module references.
3. **Error signatures** — stack trace patterns, error codes, exception
   names, HTTP status codes.
4. **Domain terms** — expanded semantically using domain knowledge
   (e.g., "login fails" expands to: login, authentication, auth,
   session, JWT, token, sign-in, timeout, credentials). No external
   lookup table required.

**Phase 2 — Context Gathering.** Execute the two-tier scan:

**Tier 1 — Artifact Scan (always, against the six sub-budgets):**

- **Stories (8K tokens):** Glob `{implementation_artifacts}/` for
  story files matching keywords. Extract: story key, title, status,
  acceptance criteria, Review Gate table, findings. Prioritize stories
  with status `in-progress`, `review`, or `done` over `backlog`.
- **Architecture (5K tokens):** Grep `{planning_artifacts}/architecture.md`
  for sections matching keywords. Extract: affected components,
  relevant ADRs, API contracts, data models. Summarize if section
  exceeds budget.
- **PRD (5K tokens):** Grep `{planning_artifacts}/prd.md` for
  requirement sections matching keywords. Extract: relevant FR/NFR
  IDs, acceptance criteria, feature descriptions. Summarize if
  section exceeds budget.
- **Decision Logs (3K tokens):** Read agent memory sidecars for
  domain-relevant entries:
  `{memory_path}/pm-sidecar/decision-log.md`,
  `{memory_path}/architect-sidecar/decision-log.md`,
  `{memory_path}/sm-sidecar/decision-log.md`.
  Skip any sidecar that does not exist (no error). Extract only
  entries matching keywords.
- **Test Artifacts (4K tokens):** Check `{test_artifacts}/test-plan.md`
  for coverage of the affected area. Check
  `{test_artifacts}/traceability-matrix.md` to map requirements to
  tests. Identify coverage gaps and recent test review findings.

**Tier 2 — Codebase Scan (5K tokens, only if technical problem):**
Grep `{project-path}/` for affected routes, services, components,
functions matching keywords. Run `git log --oneline -20 --
{affected_paths}` to surface recent changes. Identify related test
files and whether they exist. Summarize findings — do not dump raw
code.

**Synthesize the Context Brief** with all gathered context plus a
keyword hit-count table and a token-usage breakdown per sub-budget.

#### Empty-context handling

When **all six sub-budget sources** (Stories, Architecture, PRD,
Decision Logs, Codebase, Test Artifacts) return empty or
not-found:

1. Set the synthesis flag `context_brief_empty: true` in the
   Context Brief metadata.
2. Emit an info-level log line: `Context Brief empty -- no artifact
   sources returned data`. This is the canonical gap-logging
   signature consumed by the observability pipeline.
3. Proceed gracefully — do NOT raise a missing-context error and
   do NOT crash on context-overflow (the zero-context edge case is
   covered by the same "no context-overflow crash" guarantee from
   the AC-EC5 analogue).
4. **Branch on execution mode:**
   - **Normal mode (default):** continue to Phase 3, where the
     fallback interrogation path collects the missing context from
     the user before the Planning Gate fires.
   - **YOLO mode:** skip the Phase 3 fallback
     interrogation prompts entirely. Auto-proceed with the empty
     Context Brief and emit the gap-log line `Context Brief empty
     -- proceeding with YOLO defaults`. The Planning Gate
     still fires but auto-approves per the YOLO mode contract — no
     user prompts are emitted for missing context. Downstream
     phases (3-10) operate on the problem statement alone.

If only some sub-budgets return empty (partial context), the
fallback interrogation is **not** triggered — the available
context is sufficient and Phase 3 uses it directly.

### Planning Gate

Present the plan and wait for approval (see above).

### Phase Group 2 — Context-Informed Analysis

**Phase 3 — Problem Framing.** If a Context Brief is available from
Phase 2, use its Architecture Context, Related Stories, and Relevant
Requirements sections to articulate the problem. Do NOT ask the user
for project context that is already present in the Context Brief.
Separate symptoms from root causes — cross-reference the reported
symptom against architecture design, story implementation notes, and
test results. Define what "solved" looks like — success criteria
grounded in existing acceptance criteria from related stories and
PRD requirements found in the Context Brief.

#### Fallback interrogation path

If `context_brief_empty: true` was set by Phase 2 (all six
sub-budget sources returned empty) and execution mode is **normal**
(YOLO mode is handled inline in Phase 2 — see "Empty-context
handling" above), fall back to a structured three-prompt
interrogation sequence (inline-ask over fail-fast). The
fallback runs BEFORE Nova subagent dispatch — Nova receives the
user-populated Context Brief, not an empty one.

Emit the following three prompts in order, one at a time, waiting
for the user's answer before the next:

1. **Problem context and background** —
   `Describe the problem context and background -- what system,
   feature, or area is affected?`
2. **Constraints / boundary conditions** —
   `What constraints or boundary conditions apply? (e.g., time
   pressure, dependencies, architectural constraints)`
3. **Observed behaviour and repro** —
   `Describe the observed behaviour and steps to reproduce`

User-supplied answers populate the same Context Brief fields that
artifact-sourced context would:

- Prompt 1 answer → **Architecture Context**
- Prompt 2 answer → **Constraint Context**
- Prompt 3 answer → **Symptom / Evidence Context**

**Data-contract preservation (AC3):** the fallback interrogation
MUST produce a Context Brief structurally identical to the
artifact-sourced version. Downstream phases (4-10) consume the
same data contract regardless of source. Unmapped fields
(Related Stories, Relevant Requirements, Decision Log Entries,
Codebase Scan, Test Coverage) are set to empty arrays / strings —
**never omitted**. If the user skips an interrogation prompt
(provides empty input), the corresponding section is left empty
and the skill proceeds without error — partial answers are valid.

The output artifact at
`.gaia/artifacts/creative-artifacts/problem-solving-{date}.md` produced from
fallback-interrogation context has the same sectional structure as
artifact-sourced runs — no degraded experience, no errors, no
missing sections.

**Phase 4 — Root Cause Analysis.** Load methods from
`{data_path}/solving-methods.csv` (missing-file handling above).
Apply an appropriate methodology: 5 Whys, Fishbone, TRIZ. Ground
each "why" in evidence from the Context Brief — Decision Log Entries,
Architecture Context, Test Coverage. Trace causal chains to their
source. Validate root cause — does fixing it fix the symptoms?

Identify **test gaps**: analyze what tests should have caught this
problem but did not. For each gap, capture: file_path, gap_description,
suggested_test_type (unit / integration / e2e), severity (critical /
high / medium / low). If no test gaps are identified, set the array
to empty — never omit the field.

**Phase 5 — Constraint Identification.** Use the Architecture Context
and Decision Log Entries from the Context Brief to separate REAL
constraints (ADR-documented, regulatory, contractual, valid) from
ASSUMED constraints (nobody remembers why). Challenge each assumed
constraint. Identify contradictions using the TRIZ contradiction
matrix where applicable.

**Phase 6 — Solution Generation.** Generate at least **5 candidate
solutions** using TRIZ inventive principles, Theory of Constraints,
or First Principles thinking. For each: note which architecture
components and stories would be affected. Cross-check against ADR
constraints and PRD requirements. Flag any solution that would
violate an existing decision.

**Phase 7 — Solution Evaluation.** Assess feasibility, impact, and
effort for each solution. Map solutions to a 2x2 (impact vs. effort).
Select the solution that best resolves the root cause without
violating architecture constraints. Document rejected solutions with
clear reasons — these are passed to the dev agent to prevent
re-exploration.

### Phase Group 3 — Resolution Routing

**Phase 8 — Resolution Classification.** Evaluate the root cause
against the classification decision matrix:

| Classification | Scope | Downstream flow |
|----------------|-------|----------------|
| **quick-fix** (< 1 story point) | 1–2 files, single component | `/gaia-create-story` |
| **bug** | multi-file / multi-component, needs AC and targeted testing | `/gaia-create-story` |
| **critical** | any scope, urgent (production outage / blocking) | `/gaia-create-story` with priority_flag: next-sprint |
| **enhancement** | missing capability or design limitation | `/gaia-add-feature` |
| **systemic** | root cause in architecture or requirements design | escalate to Theo (architect) or Derek (PM) — generate a Problem Brief, do NOT auto-invoke |

Present the recommended classification with reasoning. Let the user
confirm, override, or decline routing (which completes the workflow
with an action plan only).

**Phase 9 — Problem-Solving Artifact.** Render the structured
artifact (see below) and write it to
`.gaia/artifacts/creative-artifacts/problem-solving-{date}.md`.

**Phase 10 — Resolution Execution.** Based on classification, route:

- **quick-fix / bug / critical** — prepare context for
  `/gaia-create-story` invocation with pre-populated fields: title,
  epic (auto-detected from Related Stories in Context Brief),
  priority (P0 for critical, P1 for high urgency, P2 for medium /
  low), priority_flag (`next-sprint` if urgency is critical or
  high), origin: `problem-solving`,
  origin_ref: `{creative_artifacts}/problem-solving-{date}.md`,
  root_cause, affected_components, acceptance_criteria, and
  rejected_solutions. Propagate test_gaps into the created story's
  Dev Notes with structured fields. Invoke `/gaia-create-story` via
  the Agent tool. If the invocation fails, log a warning and fall
  back to the action plan output only.
- **enhancement** — route to `/gaia-add-feature` via the Agent tool,
  passing scope_analysis, affected_components, proposed_changes, and
  context_ref. If the invocation fails, log a warning and fall back
  to the action plan output only.
- **systemic** — do NOT invoke a subagent. Generate a **Problem
  Brief** for the architect (Theo) or PM (Derek) and write it to
  `{planning_artifacts}/problem-brief-{date}.md`. Suggest the user
  run `/gaia-agent-architect` or `/gaia-agent-pm` to continue.

**Phase 11 — Completion Summary.** Present a final summary table
(problem, root cause, classification, resolution reference,
test-gap count, artifact path) and suggest next steps.

### Nova subagent delegation

Root-cause analysis, constraint identification, solution generation,
and solution evaluation (Phases 4–7) are delegated to **Nova
(`problem-solver`)** via the Agent tool. Nova receives the Context
Brief and the selected methodology and returns the structured
analysis.

**Missing-subagent handling (AC-EC2):** If the problem-solver
subagent is not installed at invocation time, fail fast with the
exact message `required subagent 'problem-solver' not found — install
the GAIA creative agents before running /gaia-problem-solving.` Do
not attempt inline fallback — the analysis quality depends on Nova's
methodology library. No partial output written.

## Output

Write the problem-solving artifact to
`.gaia/artifacts/creative-artifacts/problem-solving-{date}.md` where `{date}` is
the current date in `YYYY-MM-DD` form. This path is verbatim from the
legacy workflow's `output.primary` contract (functional
parity).

### Same-day overwrite handling (AC-EC6 analogue)

If the output file already exists from a prior same-day run:

1. **Default (safe):** Append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/problem-solving-{date}-{N}.md` where
   `{N}` is the next available integer starting at 2.
2. **Overwrite:** Only on explicit user request.

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **YAML frontmatter** — template, date, urgency, classification,
  status, keywords, affected_components, root_cause, test_gaps,
  resolution_path.
- **Problem Statement** — user's original problem description.
- **Urgency** — level + justification.
- **Context Brief** — summarized context gathered in Phase 2.
- **Root Cause Analysis** — methodology, root cause, causal chain,
  test gaps table.
- **Constraints** — real vs. assumed with ADR references.
- **Solutions Considered** — 5+ solutions with impact, effort,
  feasibility, selected / rejected status.
- **Selected Solution** — detailed description + rationale.
- **Rejected Solutions** — each with clear reasoning (passed to dev
  agent).
- **Resolution Route** — classification, downstream flow,
  pre-populated story context.
- **Risk Assessment** — risks + mitigation.
- **Success Metrics** — how to measure that the problem is truly
  solved.
- **Attribution** — Nova (problem-solver) credited as analysis
  author.

## Failure semantics

- **Planning Gate declined (AC-EC1):** If the user does not approve
  the plan, halt the skill cleanly. Do NOT emit a problem-solving
  artifact. Preserve the Context Brief and plan as scratch state.
- **Nova fails (crash, non-zero exit, timeout, or malformed
  output):** Halt at the failing phase. Do NOT emit a partial
  problem-solving artifact. Any captured Phase 1–2 outputs may be
  preserved as scratch state for debugging.
- **Missing subagent (AC-EC2):** If
  `plugins/gaia/agents/problem-solver.md` is missing, halt before
  Phase 4 with the actionable error above.
- **Missing data file (AC-EC3):** If
  `{data_path}/solving-methods.csv` is missing, halt before Phase 4
  with the actionable error above.
- **Context overflow (AC-EC5 analogue):** Enforce the per-source
  sub-budgets. If jointly gathered context would exceed 30K, drop
  lowest-priority matches first and log the truncation in the
  Context Brief's Token Usage section. Never crash.

## Frontmatter linter compliance

This SKILL.md passes the frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required fields per the schema are present: `name` (matches the
directory slug) and `description` (trigger signature with concrete
action phrase). `allowed-tools` is validated against the canonical
tool set (Agent is required because Nova and downstream create-story
/ add-feature are invoked via the Agent tool; Bash and Grep are
required for the codebase-scan and git-log tier of context gathering).

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy eleven-step structure as
eleven native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Problem Intake | Phase 1 | Same two inputs; same keyword extraction |
| Step 2 — Context Gathering | Phase 2 | Same two-tier scan; same six sub-budgets; same Context Brief structure |
| `execution_mode: planning` | Planning Gate | Explicit plan-approve-execute contract; halts cleanly on decline (AC-EC1) |
| Step 3 — Problem Framing | Phase 3 | Same context-informed / fallback split |
| Step 4 — Root Cause Analysis | Phase 4 | Same methodology selection from `{data_path}/solving-methods.csv`; same test-gaps field |
| Step 5 — Constraint Identification | Phase 5 | Same real-vs-assumed-constraints decomposition |
| Step 6 — Solution Generation | Phase 6 | Same "at least 5 candidate solutions" rule; same ADR / PRD cross-check |
| Step 7 — Solution Evaluation | Phase 7 | Same 2x2 impact/effort mapping; same selected / rejected decomposition |
| Step 8 — Resolution Classification | Phase 8 | Same five classifications; same confirm / override / decline options |
| Step 9 — Problem-Solving Artifact | Phase 9 | Same output path `problem-solving-{date}.md`; same frontmatter schema |
| Step 10 — Resolution Execution | Phase 10 | Same downstream flows: `/gaia-create-story` for quick-fix / bug / critical, `/gaia-add-feature` for enhancement, Problem Brief escalation for systemic |
| Step 11 — Completion Summary | Phase 11 | Same final summary table |

The context-budget allocations, input-file-patterns contract, tiered
resolution routing, and subagent delegation pattern are preserved
verbatim from the legacy workflow — only the orchestration mechanism
changes (native `context: fork` subagent delegation
and an explicit plan-approve-execute gate instead of legacy
engine-driven step dispatch with the `execution_mode: planning`
switch).

## References

- Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- Skill-to-workflow conversion mapping
- Problem-solving context budget contract
- Conversion token-reduction target
- Functional parity with legacy workflow
- Reference implementations:
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` —
    multi-subagent orchestrator with legacy parity table
  - `plugins/gaia/skills/gaia-brainstorming/SKILL.md` —
    single-subagent creative skill
- Converted subagent:
  - `plugins/gaia/agents/problem-solver.md` — Nova
- Data file (not converted by this story; resolved by the foundation
  path-resolution script):
  - `{data_path}/solving-methods.csv`
- Legacy parity source (for reference only; not invoked from this
  skill; legacy path intentionally omitted from the body to satisfy
  the "zero legacy references" parity check).

## Mode B Readiness

> **Driving teammate turns (MANDATORY under team orchestration).** Declaring
> readiness above sets up the spawn / relay / shutdown bookkeeping seams — it does
> NOT by itself drive a teammate. When `SESSION_MODE == team`, the orchestrator
> MUST drive each teammate turn per the canonical **Mode B teammate round-trip
> contract** at `knowledge/mode-b-round-trip-contract.md`: emit a real
> `SendMessage(to: <handle>)` whose message ends with the reply-routing reminder,
> let the teammate reply via `SendMessage(to: team-lead)` (one-shot re-prompt on
> idle-without-reply; never fabricate the reply), then relay the received body to
> the transcript / artifact. The bridge functions named above are bookkeeping
> only; the round-trip itself is an orchestrator-driven, main-turn loop.
>
> **No discretionary Mode A fall-through.** The team-mode round-trip is mandatory
> when the session resolves to team orchestration — "it is a small / focused /
> quick step" is NOT a license to fall back to one-shot Mode A, and a slow reply
> is the cross-turn-boundary case (wait or re-prompt once), not a fallback
> trigger. The ONLY legitimate fall-through is a real `MODE_B_FALLBACK` token
> emitted by the bridge at spawn time (substrate genuinely unavailable).

This conversational skill is Mode B-ready. Under Mode B (opt-in: persistent
teammates), participant dispatch routes through the shared dispatch library
at `scripts/lib/dispatch-teammate.sh` via the conversational bridge at
`scripts/lib/conversational-mode-b-bridge.sh`. Each participant is spawned
with `conversational_spawn_participant`, which obtains a long-lived teammate
handle, enforces the reviewer clean-room invariant, and logs dispatch
provenance. Turn output is relayed verbatim to the session transcript, so the
artifact structure (transcript and synthesis) is byte-for-byte the same as
Mode A.

When the Mode B substrate is absent — the default in this build — the shared
library degrades to Mode A foreground dispatch and emits a single
machine-parseable `MODE_B_FALLBACK` token to stderr. Existing Mode A behavior
is preserved unchanged; Mode B is attempted only when the substrate is live.

**Shutdown discipline.** Every spawned participant MUST be cleaned up at skill
completion. Wire `trap conversational_shutdown EXIT` around the participant
loop; `conversational_shutdown` delegates to `shutdown_all` in the shared
library, which sweeps every active teammate and leaves no orphaned session.
