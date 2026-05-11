---
name: gaia-edit-test-plan
description: Edit an existing test plan by adding new test cases while preserving all existing content. Use when "edit the test plan" or /gaia-edit-test-plan.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
# Discover-Inputs Protocol (ADR-062 / FR-346 / E45-S4)
# Strategy: SELECTIVE_LOAD — load only the named diff sections from PRD
# and architecture (the requirement and component sections that motivate
# the new test cases). Never full-load prd.md or architecture.md here.
discover_inputs: SELECTIVE_LOAD
discover_inputs_target: "docs/planning-artifacts/prd.md, docs/planning-artifacts/architecture.md"
orchestration_class: heavy-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-test-plan/scripts/setup.sh

## Mission

Edit an existing test plan (`docs/test-artifacts/test-plan.md`) by adding new test cases, updating coverage, and appending a version note — while preserving all existing content unchanged. The updated test plan is written back to `docs/test-artifacts/test-plan.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/edit-test-plan` workflow (E28-S87, Cluster 11). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A test plan MUST already exist at `docs/test-artifacts/test-plan.md` before starting. If the file is missing, halt with: "test-plan.md not found at docs/test-artifacts/test-plan.md — run /gaia-test-design first."
- Preserve all existing test plan content — test strategy, environments, entry/exit criteria, existing test cases.
- New test cases must follow the same format as existing ones.
- Test case IDs must auto-increment from the highest existing ID.
- Never remove or modify existing test cases — edits are additive only.
- This is a single-prompt operation — no subagent invocation needed.
- Output to `docs/test-artifacts/test-plan.md`.

## Steps

### Step 1 — Load Existing Test Plan

- Read `docs/test-artifacts/test-plan.md` in full.
- GATE: verify test-plan.md exists. If missing, halt and recommend /gaia-test-design.
- Identify existing test case count and highest test case ID (for auto-increment).
- Identify existing test areas/categories (e.g., unit, integration, E2E, performance, security).
- Display current test plan structure summary to the user: section count, test case count, coverage areas.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 1 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=load stage=test-plan-loaded`

### Step 2 — Capture Change Scope

> **Loading strategy: SELECTIVE_LOAD per ADR-062.** Load ONLY the named
> diff sections from upstream — the FR/NFR sections in `prd.md` and the
> component / decision sections in `architecture.md` that motivate the new
> test cases. Do NOT full-load either document. Use `sed -n
> '/^## FR-NNN/,/^## /p'` (or similar named-section extraction) once the
> user has identified the affected requirement IDs in the questions below.
> This is the diff-only / named sections only loading pattern.

#### Step 2a — Orchestrator-Context Detection (FR-353 / E46-S5)

> **Inheritance contract.** When this skill is invoked from an upstream
> orchestrator (typically `/gaia-add-feature`), three named context fields
> may be supplied as invocation parameters: `feature_description`,
> `prd_diff`, and `arch_diff`. These three names are the orchestrator-to-
> skill cascade contract per FR-353 — do NOT rename them per-skill, since
> peer skills (`/gaia-edit-prd`, `/gaia-edit-arch`) inherit the same set.

> **Backward-compat variable mapping.** The legacy Step 2 internal
> variables (`new_requirements`, `change_description`, `affected_test_areas`)
> are NOT renamed. The inheritance layer translates the orchestrator
> contract names into the legacy names so Steps 3–5 see exactly the
> variable names they see today:
>
> | Orchestrator field    | Legacy internal variable |
> |-----------------------|--------------------------|
> | `feature_description` | `new_requirements`       |
> | `prd_diff`            | `change_description`     |
> | `arch_diff`           | `affected_test_areas`    |

Run the **three-case branch** before asking any questions:

- **(a) ALL three present** → inherit all three fields verbatim. Skip
  both interactive prompts in Step 2b. Map each inherited field into its
  legacy internal variable per the table above.
- **(b) NONE present** → standalone path. Ask both interactive prompts in
  Step 2b verbatim — existing standalone behavior is preserved bit-for-bit
  (AC2). The inheritance layer is a silent no-op in this case; do NOT
  error, warn, or pause when no orchestrator context is detected.
- **(c) PARTIAL (one or two present)** → inherit whichever fields are
  present, then prompt for ONLY the missing fields using the existing
  Step 2b prompt text. Do NOT re-ask for inherited fields.

After the three-case branch, write a **single inheritance log line** to
the skill's working notes (not to stdout):

```
Step 2: inherited {comma-separated inherited fields, or "none"} from upstream; prompted for {comma-separated prompted fields, or "none"}.
```

This line is the auditable anchor for adversarial review of the cascade
(Subtask 1.3 of E46-S5; AC5). If the working-log write fails for any
reason (disk, permission), proceed without the log — the inheritance
itself is the load-bearing behavior; the log is an audit convenience.

#### Step 2b — Ask Missing Fields (standalone or partial path)

Ask the user the questions corresponding to fields NOT inherited in
Step 2a. In the standalone case both questions are asked; in the partial
case only the questions for missing fields are asked; in the full-
inheritance case this sub-step is skipped entirely.

1. (asked when `feature_description` / `new_requirements` not inherited)
   What new test cases are needed? Describe the feature or change
   requiring test coverage.
2. (asked when `prd_diff` / `change_description` not inherited)
   Which FR/NFR IDs need test coverage?
3. (asked when `arch_diff` / `affected_test_areas` not inherited)
   Which architecture components or decisions are affected?

#### Step 2c — Load Named Diff Sections

- Load ONLY the named diff sections of `docs/planning-artifacts/prd.md`
  corresponding to the supplied FR/NFR IDs (do NOT read the full PRD).
- Load ONLY the named diff sections of
  `docs/planning-artifacts/architecture.md` that correspond to the
  affected components (do NOT read the full architecture document).
- Record: `new_requirements`, `change_description`, `affected_test_areas`.

#### Step 2d — Post-Branch Non-Null Assertion (AC4)

Before Step 3 begins, verify each of the three legacy internal variables
(`new_requirements`, `change_description`, `affected_test_areas`) is
non-null and non-empty. If any is still null (for example, the upstream
passed an empty string masquerading as a value), fall back to the
matching Step 2b prompt for that specific field. Step 3 MUST NOT execute
with a missing scope variable.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 2 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=scope stage=change-scope-captured`

### Step 3 — Define New Test Cases

For each new requirement, define test cases with:
- Test case ID (auto-incremented from highest existing)
- Title and description
- Test type (unit, integration, E2E, performance, security, accessibility)
- Pre-conditions and test steps
- Expected results
- Priority (critical/high/medium/low)
- Validates: FR-*/NFR-* IDs this test case validates

Determine if new test areas/categories are needed or if cases fit existing categories.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 3 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=add stage=new-cases-defined`

### Step 4 — Update Test Plan

- Append new test cases to the appropriate test area sections.
- If new test area needed: create section header with description before adding test cases.
- Update test scope section to reflect expanded coverage.
- Update coverage summary if present (new requirements covered / total).
- Preserve all existing content exactly as-is — no reordering, no reformatting, no removal.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 4 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=update stage=plan-updated`

### Step 5 — Add Version Note and Save

Append version note to test plan:

```
## Version History
| Date | Change | New Test Cases | FR/NFR IDs Covered |
|------|--------|---------------|-------------------|
| {date} | {change summary} | {new test case IDs} | {FR/NFR IDs} |
```

If no Version History section exists, create one.

Write the updated test plan to `docs/test-artifacts/test-plan.md`.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 5 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=save stage=saved --paths docs/test-artifacts/test-plan.md`

### Step 6 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/test-artifacts/test-plan.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log). In particular, if the user aborts mid-edit and Step 5 never wrote, the loop MUST NOT run.
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/test-artifacts/test-plan.md`, `artifact_type = test-plan`, `model: claude-opus-4-7`, `effort: high` (ADR-074 contract C2 — Val opus pin). [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]. **Non-opus mismatch guard (AC3):** if a test fixture or downstream override forces a non-opus model, emit the canonical WARNING `Val dispatch on non-opus model — forcing opus per ADR-074 contract C2` and force `model: claude-opus-4-7` before invoking Val.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/test-artifacts/test-plan.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation runs against the Step 5 final write-back.

> Test Notes: VCP-VAL-04 (`docs/test-artifacts/test-plan.md §11.46.3`) covers this wire-in.

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 6 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=val stage=val-auto-review --paths docs/test-artifacts/test-plan.md`

### Step 7 — Next Steps

- Report test cases added: list new IDs, their types, and requirements covered.
- If high-risk stories need acceptance tests: "Recommend running /gaia-atdd for stories: {story_keys}"
- If traceability update needed: "Recommend running /gaia-trace to update traceability matrix"

> `!scripts/write-checkpoint.sh gaia-edit-test-plan 7 test_plan_path="docs/test-artifacts/test-plan.md" edit_mode=next-steps stage=next-steps-reported`

## Validation

<!--
  E42-S14 — V1→V2 21-item checklist port (FR-341, FR-359, VCP-CHK-29, VCP-CHK-30).
  Classification (21 items total):
    - Script-verifiable:  7 (SV-01..SV-07) — enforced by finalize.sh.
    - LLM-checkable:     14 (LLM-01..LLM-14) — evaluated by the host LLM
      against the test-plan.md artifact at finalize time.
  Exit code 0 when all 7 script-verifiable items PASS; non-zero otherwise.

  V1 source reconciliation:
    - _gaia/testing/workflows/edit-test-plan/checklist.md ships 11
      explicit bullets under five V1 H2 sections (Edit Quality, New
      Test Cases, Coverage, Version History, Output Verification).
    - The story 21-item count is authoritative per
      docs/v1-v2-command-gap-analysis.md §6 and the epic design note.
    - The remaining 10 items are reconciled from V1 instructions.xml
      step outputs (Step 1 plan load + ID harvest + test-area survey,
      Step 2 scope capture + PRD/architecture context load, Step 3
      test case authoring with required fields, Step 4 area-header
      creation, Step 5 Version History creation, Step 6 next-steps
      block).
    - Every V1 checklist bullet maps 1:1 to a V2 validation entry. No
      item is dropped, renamed, or merged.

  Because the V1 edit-test-plan checklist is dominated by
  preservation-semantics checks ("existing test cases preserved
  exactly", "existing test strategy unchanged", "test cases follow same
  format as existing"), LLM-checkable is the dominant classification
  here (14 / 21). Script-verifiable items cover the output-file shape,
  Version History presence, test-area headers, test-case-ID
  convention, and the Validates-field regex.

  V1 category coverage mapping (21 items):
    Edit Quality          — LLM-01, LLM-02, LLM-03                       (3)
    New Test Cases        — LLM-04, LLM-05, LLM-06, SV-05, SV-06, SV-07  (6)
    Coverage              — LLM-07, LLM-08                               (2)
    Version History       — SV-03, SV-04                                 (2)
    Output Verification   — SV-01, SV-02                                 (2)
    Reconciled (V1 instr) — LLM-09..LLM-14                               (6)
    Total                                                                 21

  Invoked by `finalize.sh` at post-complete (per architecture §10.31.1).
  Validation runs BEFORE the checkpoint and lifecycle-event writes
  (observability is never suppressed by checklist outcome — story AC5).

  See docs/implementation-artifacts/E42-S14-port-gaia-edit-test-plan-and-gaia-test-design-checklists-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to docs/test-artifacts/test-plan.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Version History section present (## Version History heading)
- [script-verifiable] SV-04 — Version History row with date, change summary, new test case IDs, FR/NFR anchors
- [script-verifiable] SV-05 — Test area section headers present (unit / integration / e2e / performance / security keyword)
- [script-verifiable] SV-06 — Test case ID convention followed (TC-NN / TP-NN anchors present)
- [script-verifiable] SV-07 — Validates field maps to FR/NFR IDs (FR-* or NFR-* anchor present)
- [LLM-checkable] LLM-01 — Existing test cases preserved exactly
- [LLM-checkable] LLM-02 — Existing test strategy and environments unchanged
- [LLM-checkable] LLM-03 — New test cases follow same format as existing
- [LLM-checkable] LLM-04 — Test case IDs auto-incremented from highest existing (no collisions)
- [LLM-checkable] LLM-05 — Each new test case has type, steps, expected results, priority
- [LLM-checkable] LLM-06 — Test cases assigned to correct test area/category (semantic fit)
- [LLM-checkable] LLM-07 — Test scope section updated to reflect expanded coverage
- [LLM-checkable] LLM-08 — Coverage summary updated (if present)
- [LLM-checkable] LLM-09 — Existing test plan loaded from docs/test-artifacts/test-plan.md (Step 1 output)
- [LLM-checkable] LLM-10 — Highest existing test case ID identified for auto-increment (Step 1)
- [LLM-checkable] LLM-11 — Existing test areas/categories identified before editing (Step 1)
- [LLM-checkable] LLM-12 — Change scope captured: feature description and FR/NFR IDs recorded (Step 2)
- [LLM-checkable] LLM-13 — PRD and architecture context consulted where available (Step 2)
- [LLM-checkable] LLM-14 — Next-steps block populated (traceability / ATDD recommendations) (Step 6)

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-test-plan/scripts/finalize.sh
