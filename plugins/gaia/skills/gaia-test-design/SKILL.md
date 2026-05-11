---
name: deprecated-gaia-test-design
description: DEPRECATED — This skill has been retired. Use /gaia-test-strategy --plan (canonical, see gaia-test-strategy/SKILL.md). This file remains only to expose the deprecated alias for one sprint per E69-S3 / FR-RSV2-24.
context: fork
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
deprecated_aliases: [gaia-test-design]
deprecated_since: sprint-37
replaced_by: gaia-test-strategy
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-design/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh test-architect all

## Mission

You are orchestrating the creation of a risk-based Test Plan. The test planning is delegated to the **test-architect** subagent (Sable), who conducts risk assessment, designs test strategy, and produces the final artifact. You load upstream artifacts (architecture, PRD, project context), validate inputs, coordinate the multi-step flow, and write the output to `docs/test-artifacts/test-plan.md` using the bundled `test-plan-template.md` template structure.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/test-design` workflow (E28-S82, Cluster 11). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` -- do not restructure, re-prompt, or reorder.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Start with risk assessment -- not all areas need equal coverage.
- Define quality gates for the CI pipeline.
- The test plan template MUST exist at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-design/test-plan-template.md` and be non-empty. If the template file is empty (0 bytes) or missing, halt with: "Test plan template not found or empty -- cannot produce test plan without template."
- If architecture.md is missing at `docs/planning-artifacts/architecture.md`: proceed with reduced risk context, log a WARNING ("Architecture document not found -- producing test plan with generic risk ratings"), and use generic risk ratings instead of architecture-informed ones.
- If prd.md is missing at `docs/planning-artifacts/prd.md`: proceed with reduced context, log a WARNING ("PRD not found -- test plan scope may be incomplete").
- Test planning is delegated to the test-architect subagent (Sable) via native Claude Code subagent invocation -- do NOT inline Sable's persona into this skill body. If the test-architect subagent is not available or not registered, halt with: "test-architect subagent not available -- ensure E28-S21 agents are installed."
- Template resolution: load `test-plan-template.md` from this skill directory. If `custom/templates/test-plan-template.md` exists and is non-empty, use the custom template instead -- the custom template takes full precedence over the bundled default (ADR-020 / FR-101).
- Output ALL artifacts to `docs/test-artifacts/`.
- Val auto-review runs unconditionally via the direct-call contract from E44-S1 -- the deprecated frontmatter flag is superseded by the Step 8 auto-fix loop wired in by E44-S6 (see Step 8 below; ADR-058 / architecture.md §10.31.2).

## Steps

### Step 1 -- Load Project Context

- Read `docs/planning-artifacts/architecture.md` if available -- extract system components, their interactions, and high-risk areas.
- Read `docs/planning-artifacts/prd.md` if available -- extract requirements (functional and non-functional).
- Read `docs/planning-artifacts/project-context.md` if available -- extract project-level context.
- If architecture.md is missing: log WARNING and proceed with generic risk context. Do not halt.
- If prd.md is missing: log WARNING and proceed with reduced scope context. Do not halt.
- Understand system components and their interactions from whatever context is available.

> `!scripts/write-checkpoint.sh gaia-test-design 1 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=context-loaded`

### Step 2 -- Risk Assessment

Delegate to the **test-architect** subagent (Sable) via `agents/test-architect` for risk assessment.

- Load knowledge fragment: `knowledge/risk-governance.md` for probability-impact matrix methodology
- Identify high-risk areas: revenue-critical paths, security-sensitive components, complex business logic, data integrity boundaries.
- Rate each area using probability x impact scoring.
- Produce a risk assessment matrix with columns: Area, Risk Level (H/M/L), Probability, Impact, Coverage Strategy.
- When architecture.md is missing, use generic risk ratings based on common patterns (auth = High, CRUD = Medium, static content = Low).

> `!scripts/write-checkpoint.sh gaia-test-design 2 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" risk_level="$RISK_LEVEL" stage=risk-assessment`

### Step 3 -- Legacy Integration Boundaries (Brownfield)

This step is **optional** -- activate only when brownfield indicators are present.

- If PRD contains "Mode: Brownfield" or project has `docs/planning-artifacts/brownfield-assessment.md`: activate this step.
- Identify integration boundaries: where new code calls legacy code and vice versa.
- Load knowledge fragment: `knowledge/contract-testing.md` for consumer-driven contract patterns
- For each boundary: define contract test (input/output schema validation between old and new).
- For each legacy API wrapper or adapter: define adapter test (legacy behavior preserved).
- If data migration exists: define migration validation tests (row counts, data integrity, rollback verification).
- If dual-write strategy: define consistency tests (both stores reflect same state).
- Add legacy boundary risks to the risk assessment from Step 2.
- If no brownfield indicators are found: skip this step entirely.

> `!scripts/write-checkpoint.sh gaia-test-design 3 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=legacy-boundaries`

### Step 4 -- Test Strategy

Delegate to the **test-architect** subagent (Sable) via `agents/test-architect` for test strategy design.

- Load knowledge fragment: `knowledge/test-pyramid.md` for test level methodology
- Load knowledge fragment: `knowledge/api-testing-patterns.md` for API and contract test patterns
- Define test levels per component: unit, integration, E2E, contract.
- Apply test pyramid -- most tests at the lowest effective level.
- Map each component to its appropriate test level based on risk assessment.
- Define the test pyramid distribution targets (e.g., 70% unit, 20% integration, 10% E2E).

> `!scripts/write-checkpoint.sh gaia-test-design 4 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=test-strategy`

### Step 5 -- Test Plan

Delegate to the **test-architect** subagent (Sable) via `agents/test-architect` for test plan authoring.

- Create test plan with coverage targets per component.
- Define test naming conventions and organization.
- Specify test data requirements, fixtures, and mocks.
- Define test environment requirements and setup.

> `!scripts/write-checkpoint.sh gaia-test-design 5 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=test-plan-drafted`

### Step 6 -- Quality Gates

Delegate to the **test-architect** subagent (Sable) via `agents/test-architect` for quality gate definition.

- Define automated gates: coverage percentage thresholds, pass rate requirements, performance budgets.
- Specify CI pipeline integration points for each gate.
- Define gate failure behavior (block merge, warn, advisory).

> `!scripts/write-checkpoint.sh gaia-test-design 6 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=quality-gates`

### Step 7 -- Generate Output

- Load the test plan template from `${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-design/test-plan-template.md`.
- GATE: verify the template file exists and is non-empty (file size > 0 bytes). If the template is empty or missing, halt with: "Test plan template not found or empty at test-plan-template.md -- cannot produce test plan without template."
- Check for custom template override: if `custom/templates/test-plan-template.md` exists and is non-empty, use the custom template instead.
- Compile the test plan by populating the template with: risk assessment (Step 2), legacy integration boundaries (Step 3, if applicable), test strategy (Step 4), test plan details (Step 5), quality gates (Step 6).
- Write the compiled test plan to `docs/test-artifacts/test-plan.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/test-artifacts/test-plan.md`

> `!scripts/write-checkpoint.sh gaia-test-design 7 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=output-generated --paths docs/test-artifacts/test-plan.md`

### Step 8 -- Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/test-artifacts/test-plan.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/test-artifacts/test-plan.md`, `artifact_type = test-plan`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/test-artifacts/test-plan.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation runs against the Step 7 artifact write.

> Test Notes: VCP-VAL-04 (`docs/test-artifacts/test-plan.md §11.46.3`) covers this wire-in.

> `!scripts/write-checkpoint.sh gaia-test-design 8 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=val-auto-review --paths docs/test-artifacts/test-plan.md`

### Step 9 -- Optional: Scaffold Test Framework

- Check if the project already has a test framework configured (look for jest.config, vitest.config, playwright.config, pytest.ini, build.gradle test blocks, etc.).
- If no test framework is detected: suggest running `/gaia-test-framework` to scaffold the test framework with appropriate tooling, folder structure, fixture patterns, and a sample test.
- If a test framework already exists: skip this step -- the framework is already configured.
- This step is informational only -- the actual scaffolding is handled by the separate `/gaia-test-framework` skill.

> `!scripts/write-checkpoint.sh gaia-test-design 9 story_key="$STORY_KEY" test_plan_path="docs/test-artifacts/test-plan.md" stage=scaffold-suggestion`

## Validation

<!--
  E42-S14 — V1→V2 8-item checklist port (FR-341, FR-359, VCP-CHK-27, VCP-CHK-28).
  Classification (8 items total):
    - Script-verifiable: 6 (SV-01..SV-06) — enforced by finalize.sh.
    - LLM-checkable:     2 (LLM-01..LLM-02) — evaluated by the host LLM
      against the test-plan.md artifact at finalize time.
  Exit code 0 when all 6 script-verifiable items PASS; non-zero otherwise.

  V1 source: _gaia/testing/workflows/test-design/checklist.md (8 items,
  clean). V1 → V2 mapping (1:1, no drop, no merge):
    V1 "Project context loaded and understood"                 → LLM (context semantics)
    V1 "Risk assessment completed with probability x impact"   → SV-03 (heading + keywords)
    V1 "Test levels defined per component"                     → SV-04 (levels/pyramid)
    V1 "Test pyramid applied appropriately"                    → SV-04 (pyramid keyword — folded with test-levels)
    V1 "Legacy integration boundaries identified (brownfield)" → LLM-01
    V1 "Data migration validation tests defined (if applicable)" → LLM-02
    V1 "Coverage targets defined"                              → SV-05
    V1 "Quality gates specified for CI"                        → SV-06
  Additional structural items (SV-01, SV-02) enforce the V1 output
  contract (test-plan.md written to docs/test-artifacts/test-plan.md,
  non-empty). The V1 "Project context loaded" item collapses to host-LLM
  review because context loading is a Step-1 side effect not provably
  inspected against the artifact body.

  Invoked by `finalize.sh` at post-complete (per architecture §10.31.1).
  Validation runs BEFORE the checkpoint and lifecycle-event writes
  (observability is never suppressed by checklist outcome — story AC5).

  See docs/implementation-artifacts/E42-S14-port-gaia-edit-test-plan-and-gaia-test-design-checklists-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to docs/test-artifacts/test-plan.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Risk assessment section present (risk heading + probability/impact keywords)
- [script-verifiable] SV-04 — Test strategy section present (test pyramid / test levels keyword)
- [script-verifiable] SV-05 — Coverage targets defined (coverage / target keyword present)
- [script-verifiable] SV-06 — Quality gates specified for CI (quality gate / CI gate keyword present)
- [LLM-checkable] LLM-01 — Legacy integration boundaries identified and tested (if brownfield)
- [LLM-checkable] LLM-02 — Data migration validation tests defined (if applicable)

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-design/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-create-epics` — convert the test plan risks into an epic and story breakdown.
