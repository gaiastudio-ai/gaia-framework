---
name: gaia-create-epics
description: Break requirements into epics and user stories through collaborative discovery with the architect (Theo) and pm (Derek) subagents — Cluster 6 architecture skill. Use when the user wants to decompose a PRD and architecture into implementation-ready epics and stories with dependency topology, risk levels from the test plan, and priority ordering.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
# Discover-Inputs Protocol (ADR-062 / FR-346 / E45-S4)
# Strategy: INDEX_GUIDED — three large upstream artifacts (PRD,
# architecture, test plan) routinely total 50K+ tokens. Load each
# artifact's index (heading scan) first; fetch named sections on demand in
# later steps. Falls back to FULL_LOAD when an artifact lacks parseable
# headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: "docs/planning-artifacts/prd.md, docs/planning-artifacts/architecture.md, docs/test-artifacts/test-plan.md"
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE"
```

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-epics/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm all

## Mission

You are orchestrating the creation of an Epics and Stories document. The epic definition and story breakdown are delegated to the **architect** subagent (Theo) for technical decomposition and the **pm** subagent (Derek) for business prioritization and user story authoring. You load the PRD, architecture, test plan, and optional UX design, validate inputs, coordinate the multi-step flow, and write the output to `docs/planning-artifacts/epics-and-stories.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/create-epics-stories` workflow (brief Cluster 6, story P6-S3 / E28-S47). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST exist at `docs/planning-artifacts/prd.md` before starting. If missing, fail fast with "PRD not found at docs/planning-artifacts/prd.md — run /gaia-create-prd first."
- An architecture document MUST exist at `docs/planning-artifacts/architecture.md` before starting. If missing, fail fast with "Architecture not found at docs/planning-artifacts/architecture.md — run /gaia-create-arch first."
- The architecture document MUST contain a "## Review Findings Incorporated" section. If missing, fail fast with "Architecture review findings not found — run /gaia-create-arch first to complete adversarial review and architecture refinement."
- A test plan MUST exist at `docs/test-artifacts/test-plan.md` before starting. This is an **enforced** quality gate (ADR-042), not advisory. The gate is checked by `scripts/setup.sh` via `validate-gate.sh test_plan_exists`. If missing, HALT with "test-plan.md not found — run /gaia-test-design first." The file must be non-empty — a zero-byte file is treated as missing.
- Epic definition and technical decomposition are delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation — do NOT inline Theo's persona into this skill body. If the architect subagent (E28-S21) is not available, fail with "architect subagent not available — install E28-S21" error.
- Story authoring and business prioritization are delegated to the `pm` subagent (Derek) via native Claude Code subagent invocation — do NOT inline Derek's persona into this skill body. If the pm subagent (E28-S21) is not available, fail with "pm subagent not available — install E28-S21" error.
- If either the `architect` or `pm` subagent is not registered, surface a clear subagent-missing error rather than silently falling back to inline persona content.
- If `docs/planning-artifacts/epics-and-stories.md` already exists, warn the user: "An existing epics-and-stories document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Every story must have `depends_on` and `blocks` declarations — no circular dependencies.
- Stories must be ordered by dependency topology first, then business priority.

## Steps

### Step 1 — Load Upstream Artifacts

> **Loading strategy: INDEX_GUIDED per ADR-062.** Three large upstream
> artifacts (PRD, architecture, test plan) routinely total 50K+ tokens.
> Heading-scan each artifact first to build a section index — do NOT read
> the full bodies up front. Fetch named sections on demand in later steps
> (`sed -n` between heading anchors). If any artifact lacks parseable
> headings, fall back to FULL_LOAD for that file only.

- Heading-scan `docs/planning-artifacts/prd.md` to build a section index of functional requirements.
- GATE: verify prd.md exists. If missing, HALT — run /gaia-create-prd first.
- Heading-scan `docs/planning-artifacts/architecture.md` to build a section index of technical components.
- GATE: verify architecture.md contains a "## Review Findings Incorporated" section. If missing, HALT — run /gaia-create-arch first to complete adversarial review and architecture refinement.
- Heading-scan `docs/test-artifacts/test-plan.md` for the risk-assessment section index (high-risk areas: revenue-critical, security-sensitive, complex logic). This file was already validated by `scripts/setup.sh` via the enforced quality gate. Section bodies are loaded on demand.
- Heading-scan `docs/planning-artifacts/ux-design.md` if available for UI-flow / component-hierarchy / interaction-pattern / accessibility section anchors. Set `has_ux_design` flag.

> `!scripts/write-checkpoint.sh gaia-create-epics 1 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" architecture_version="$ARCHITECTURE_VERSION"`

### Step 2 — Detect Mode

- Check `docs/planning-artifacts/prd.md` header for "Mode: Brownfield".
- If brownfield mode detected: set mode to brownfield. Stories must cover gap requirements ONLY — do NOT create stories for existing implemented features.
- If no brownfield header: set mode to greenfield. Create stories for all features from the PRD.

> `!scripts/write-checkpoint.sh gaia-create-epics 2 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epics_mode="$EPICS_MODE"`

### Step 3 — Define Epics

Delegate to the **architect** subagent (Theo) via `agents/architect` to define epics.

- Group related features into logical epics.
- Each epic: name, description, goal, success criteria.
- Brownfield: epics should focus on gap closure — not existing functionality.

> `!scripts/write-checkpoint.sh gaia-create-epics 3 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT"`

### Step 4 — Break Into Stories

Delegate to the **pm** subagent (Derek) via `agents/pm` to author user stories.

- For each epic, create user stories.
- Each story needs: title, description, acceptance criteria, size estimate (S/M/L/XL).
- Use format: "As a [user], I want to [action] so that [benefit]".
- Brownfield: stories must trace to PRD gap requirement IDs. Do NOT create stories for existing implemented features.
- If `has_ux_design`: frontend stories MUST reference specific UX flows, components, and interaction patterns from ux-design.md. Include relevant screen names, navigation paths, and accessibility requirements in acceptance criteria.

> `!scripts/write-checkpoint.sh gaia-create-epics 4 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT" story_count="$STORY_COUNT"`

### Step 5 — Apply Test-Plan Risk Levels

- Read risk assessment from the test plan loaded in Step 1.
- For each story: if it touches a high-risk component, set risk_level: high. Otherwise medium or low.
- High-risk stories: add to Dev Notes: "Risk: HIGH — run /gaia-atdd before /gaia-dev-story".

> `!scripts/write-checkpoint.sh gaia-create-epics 5 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" high_risk_count="$HIGH_RISK_COUNT"`

### Step 6 — Declare Dependencies

Delegate to the **architect** subagent (Theo) via `agents/architect` to determine dependency topology.

- For each story, declare depends_on: [story-ids] and blocks: [story-ids].
- Ensure no circular dependencies.

> `!scripts/write-checkpoint.sh gaia-create-epics 6 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" deps_declared="$DEPS_DECLARED"`

### Step 7 — Priority Ordering

Delegate to the **pm** subagent (Derek) via `agents/pm` to set business priority.

- Sort stories by: dependency topology first, then business priority.
- Assign priority: P0 (must-have), P1 (should-have), P2 (nice-to-have).

> `!scripts/write-checkpoint.sh gaia-create-epics 7 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" priority_assigned="$PRIORITY_ASSIGNED"`

### Step 8 — Generate Output

Write the epics and stories document to `docs/planning-artifacts/epics-and-stories.md`. Each story formatted as:

```
### Story {epic-N}-{story-N}: {Title}
- Epic: {epic name}
- Priority: {P0/P1/P2}
- Size: {S/M/L/XL}
- Risk: {high/medium/low}
- Depends on: [{story-ids}]
- Blocks: [{story-ids}]
- Acceptance Criteria:
  - AC1: {criteria}
```

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/epics-and-stories.md`

> `!scripts/write-checkpoint.sh gaia-create-epics 8 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT" story_count="$STORY_COUNT" --paths docs/planning-artifacts/epics-and-stories.md`

### Step 9 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/planning-artifacts/epics-and-stories.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/planning-artifacts/epics-and-stories.md`, `artifact_type = epics-and-stories`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/planning-artifacts/epics-and-stories.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Concurrent invocations of this skill are safe per E44-S5 AC-EC5: each invocation has its own iteration counter (centralized in the canonical pattern), so loop state is per-invocation, not shared.

> `!scripts/write-checkpoint.sh gaia-create-epics 9 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" stage=val-auto-review --paths docs/planning-artifacts/epics-and-stories.md`

### Step 10 — Brownfield: Generate Onboarding Knowledge Base (optional)

Skip this step if mode is greenfield.

- Generate onboarding doc as a knowledge base index linking to ALL artifacts.
- Write to `docs/planning-artifacts/brownfield-onboarding.md`.

> `!scripts/write-checkpoint.sh gaia-create-epics 10 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epics_mode=brownfield brownfield_onboarding_written="$BROWNFIELD_ONBOARDING_WRITTEN"`

### Step 11 — Edge Case Analysis (optional)

- Ask: "Would you like to hunt for edge cases in the stories? Recommended to catch gaps before sprint planning. (yes / skip)"
- If yes: spawn edge case analysis subagent.
- If skip: edge case analysis can be run anytime later with /gaia-edge-cases.

> `!scripts/write-checkpoint.sh gaia-create-epics 11 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" edge_cases_run="$EDGE_CASES_RUN"`

### Step 12 — Adversarial Review (optional)

- Ask: "Would you like to run an adversarial review on the epics and stories? Recommended before sprint planning. (yes / skip)"
- If yes: spawn adversarial review subagent.
- If skip: adversarial review can be run anytime later with /gaia-adversarial.

> `!scripts/write-checkpoint.sh gaia-create-epics 12 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" adversarial_run="$ADVERSARIAL_RUN"`

## Validation

<!--
  E42-S10 — V1→V2 31-item checklist port (FR-341, FR-359, VCP-CHK-19, VCP-CHK-20).
  Classification (31 items total):
    - Script-verifiable: 21 (SV-01..SV-21) — enforced by finalize.sh.
    - LLM-checkable:     10 (LLM-01..LLM-10) — evaluated by the host LLM
      against the epics-and-stories.md artifact at finalize time.
  Exit code 0 when all 21 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at
  _gaia/lifecycle/workflows/3-solutioning/create-epics-stories/checklist.md
  ships 15 explicit bullets across seven V1 categories (Gates, Epics,
  Stories, Dependencies, Test Integration, Priority, Output
  Verification). The story 31-item count is authoritative per
  docs/v1-v2-command-gap-analysis.md; the remaining ~16 items are
  reconciled from V1 instructions.xml step outputs (Task 1.2):
    - PRD / architecture / test-plan consumed as upstream gates
    - Review Findings Incorporated section on the architecture
    - epic frontmatter (## Epic N: heading)
    - story frontmatter (### Story E{N}-S{N}: heading; 15-field
      contract items: Priority, Size, Depends on, Blocks, Risk,
      Acceptance Criteria, Traces to)
    - enum validation (P0/P1/P2, S/M/L/XL, high/medium/low)
    - algorithmic checks (no circular dependencies via Kahn's topo
      sort; no duplicate story keys)
    - semantic LLM items (LLM-01..LLM-10: epic grouping, user-story
      format, ordering, ATDD reminder adequacy, review-findings
      coverage, brownfield gap coverage, sizing plausibility, AC
      testability, epic goal clarity, priority-intent alignment).

  V1 category coverage mapping (31 items):
    Gates                — SV-18, SV-19, SV-20                                   (3)
    Epics                — SV-03, LLM-01, LLM-09                                 (3)
    Stories              — SV-04, SV-05, SV-06, SV-10, LLM-02, LLM-07, LLM-08    (7)
    Dependencies         — SV-07, SV-08, SV-14, SV-15                            (4)
    Test Integration     — SV-09, SV-16, SV-17                                   (3)
    Priority             — SV-11, LLM-03, LLM-10                                 (3)
    Output Verification  — SV-01, SV-02, SV-12, SV-13, SV-21,
                           LLM-05, LLM-06, LLM-04                                (8)
    Total                                                                        31

  The VCP-CHK-20 anchor is SV-14 — "No circular dependencies". This
  is the V1 phrase verbatim and MUST appear in violation output
  when a cycle is detected (AC2). The cycle path is surfaced via
  the failing story keys drained by Kahn's algorithm.

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).

  See docs/implementation-artifacts/E42-S10-port-gaia-create-epics-31-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to docs/planning-artifacts/epics-and-stories.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Epics section present (## Epic N: headings)
- [script-verifiable] SV-04 — Stories section present (### Story E{N}-S{N}: headings)
- [script-verifiable] SV-05 — Every story declares Priority
- [script-verifiable] SV-06 — Every story declares Size
- [script-verifiable] SV-07 — Every story declares Depends on
- [script-verifiable] SV-08 — Every story declares Blocks
- [script-verifiable] SV-09 — Every story declares Risk (risk_level)
- [script-verifiable] SV-10 — Every story declares Acceptance Criteria
- [script-verifiable] SV-11 — Priority values restricted to P0/P1/P2
- [script-verifiable] SV-12 — Size values restricted to S/M/L/XL
- [script-verifiable] SV-13 — Risk values restricted to high/medium/low
- [script-verifiable] SV-14 — No circular dependencies (topological sort drains every story)
- [script-verifiable] SV-15 — No duplicate story keys
- [script-verifiable] SV-16 — test-plan.md read and risk levels extracted (test-plan.md exists)
- [script-verifiable] SV-17 — Every story surfaces a Risk value (risk levels extracted from test-plan)
- [script-verifiable] SV-18 — PRD consumed (prd.md exists upstream)
- [script-verifiable] SV-19 — Architecture consumed (architecture.md exists upstream)
- [script-verifiable] SV-20 — Review Findings Incorporated section present in architecture
- [script-verifiable] SV-21 — Traceability referenced (Traces to / FR-### identifier present)
- [LLM-checkable] LLM-01 — Epics group related features logically
- [LLM-checkable] LLM-02 — Each story follows user story format ("As a ... I want ... so that ...")
- [LLM-checkable] LLM-03 — Stories ordered by dependency topology first, then business priority
- [LLM-checkable] LLM-04 — High-risk stories include ATDD reminder in Dev Notes with adequate guidance
- [LLM-checkable] LLM-05 — Review Findings Incorporated section content actually addresses findings
- [LLM-checkable] LLM-06 — Brownfield mode: stories cover gap requirements only (no existing-feature stories)
- [LLM-checkable] LLM-07 — Story sizes (S/M/L/XL) are reasonable for team velocity
- [LLM-checkable] LLM-08 — Acceptance criteria are testable and unambiguous
- [LLM-checkable] LLM-09 — Each epic has a clearly stated goal and success criteria
- [LLM-checkable] LLM-10 — Priority labels (P0/P1/P2) match business intent described in PRD

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-epics/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-atdd` — generate failing acceptance tests from the highest-risk story in the new backlog.
- **Alternative:** `/gaia-threat-model` — when security is a primary concern, model threats before ATDD.
