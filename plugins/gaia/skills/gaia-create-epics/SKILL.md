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
discover_inputs_target: ".gaia/artifacts/planning-artifacts/prd.md (or .gaia/artifacts/planning-artifacts/prd/prd.md), .gaia/artifacts/planning-artifacts/architecture.md, .gaia/artifacts/test-artifacts/test-plan.md (or .gaia/artifacts/test-artifacts/strategy/test-plan.md)"
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-epics/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm all

## Mission

You are orchestrating the creation of an Epics and Stories document. The epic definition and story breakdown are delegated to the **architect** subagent (Theo) for technical decomposition and the **pm** subagent (Derek) for business prioritization and user story authoring. You load the PRD, architecture, test plan, and optional UX design, validate inputs, coordinate the multi-step flow, and write the output to the canonical post-ADR-111 path `.gaia/artifacts/planning-artifacts/epics-and-stories.md`.

**Path resolution (AF-2026-05-21-13).** All path references in this SKILL.md use the canonical post-ADR-111 locations under `.gaia/artifacts/planning-artifacts/` and `.gaia/artifacts/test-artifacts/`. Pre-ADR-111 projects continue to work via canonical-first two-tier resolution at the script layer (`scripts/finalize.sh` already implements the E96-S7 partial-4c smart-fallback: try `.gaia/artifacts/...` first, fall back to `docs/...` only when absent). When writing artifacts via the Write tool, target the canonical paths named in this SKILL.md; the pre-ADR-111 fallback is read-side only. AF-21-13 also establishes the canonical destination for `brownfield-onboarding.md` (line 188) at `.gaia/artifacts/planning-artifacts/brownfield-onboarding.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/create-epics-stories` workflow (brief Cluster 6, story P6-S3 / E28-S47). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST exist before starting. Resolve via the sharded-fallback rule (ADR-069 / FR-396..402): first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). If NEITHER exists, fail fast with "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- An architecture document MUST exist at `.gaia/artifacts/planning-artifacts/architecture.md` before starting. If missing, fail fast with "Architecture not found at .gaia/artifacts/planning-artifacts/architecture.md — run /gaia-create-arch first."
- The architecture document MUST contain a "## Review Findings Incorporated" section, with **one carve-out** documented at AF-2026-05-31-1 / Test12 F-14: when the architecture YAML frontmatter declares `mode: brownfield`, the section is **advisory** (its absence emits a NOTICE but does not HALT). The brownfield Phase 9a architecture pipeline generates its arch.md from gap consolidation, NOT from an adversarial+incorporate loop, so requiring the section would break the brownfield→epics handoff (Test12 F-14: operators had to manually append a placeholder section to unblock create-epics). For greenfield (`mode: greenfield` / unset), the section remains a hard gate — its absence still fails with "Architecture review findings not found — run /gaia-create-arch first to complete adversarial review and architecture refinement."
- A test plan MUST exist before starting. The gate `validate-gate.sh test_plan_exists` (ADR-072 / AF-2026-05-08-5) accepts three placements: flat `.gaia/artifacts/test-artifacts/test-plan.md`, strategy/ `.gaia/artifacts/test-artifacts/strategy/test-plan.md`, or sharded `.gaia/artifacts/test-artifacts/test-plan/index.md`. This is an **enforced** quality gate (ADR-042), not advisory. The gate is checked by `scripts/setup.sh` via `validate-gate.sh test_plan_exists`. If missing from ALL three placements, HALT with "test-plan.md not found at .gaia/artifacts/test-artifacts/test-plan.md, .gaia/artifacts/test-artifacts/strategy/test-plan.md, or .gaia/artifacts/test-artifacts/test-plan/index.md — run /gaia-test-design first." The file must be non-empty — a zero-byte file is treated as missing.
- Epic definition and technical decomposition are delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation — do NOT inline Theo's persona into this skill body. If the architect subagent (E28-S21) is not available, fail with "architect subagent not available — install E28-S21" error.
- Story authoring and business prioritization are delegated to the `pm` subagent (Derek) via native Claude Code subagent invocation — do NOT inline Derek's persona into this skill body. If the pm subagent (E28-S21) is not available, fail with "pm subagent not available — install E28-S21" error.
- If either the `architect` or `pm` subagent is not registered, surface a clear subagent-missing error rather than silently falling back to inline persona content.
- If `.gaia/artifacts/planning-artifacts/epics-and-stories.md` already exists, warn the user: "An existing epics-and-stories document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Every story must have `depends_on` and `blocks` declarations — no circular dependencies.
- Stories must be ordered by dependency topology first, then business priority.
- **Per-epic directory naming (AF-2026-05-22-8 Bug-18)** — When Derek bulk-authors per-story `.md` files (Step 4), each story MUST land at `${implementation_artifacts}/{resolve_epic_slug output}/stories/{story_key}-{slug}.md`. The `{resolve_epic_slug output}` is computed by `scripts/lib/resolve-epic-slug.sh --epic-key E{N} --epics-file ...` and is e.g. `epic-E1-core-brain-vault`. Do NOT write to `epic-{N}/stories/...` (numeric-only, no slug) — `transition-story-status.sh` uses the resolver-output directory for `story-index.yaml`, so any other naming produces SPLIT STATE across two directories per epic. This is the recurring Bug-18 from the YARA test report — when create-epics bulk-writes stories without invoking the resolver, the result is `epic-1/stories/E1-S1-*.md` (story body) in one dir and `epic-E1-core-brain-vault/stories/story-index.yaml` (state) in another.

## Steps

### Step 1 — Load Upstream Artifacts

> **Loading strategy: INDEX_GUIDED per ADR-062.** Three large upstream
> artifacts (PRD, architecture, test plan) routinely total 50K+ tokens.
> Heading-scan each artifact first to build a section index — do NOT read
> the full bodies up front. Fetch named sections on demand in later steps
> (`sed -n` between heading anchors). If any artifact lacks parseable
> headings, fall back to FULL_LOAD for that file only.

- Resolve the PRD path via the sharded-fallback rule (Critical Rules above). Heading-scan the resolved PRD to build a section index of functional requirements; for the sharded layout, also heading-scan `prd/04-functional-requirements/`.
- GATE: verify the resolved PRD (flat `.gaia/artifacts/planning-artifacts/prd.md` OR sharded `.gaia/artifacts/planning-artifacts/prd/prd.md`) exists. If neither, HALT — run /gaia-create-prd first.
- Heading-scan `.gaia/artifacts/planning-artifacts/architecture.md` to build a section index of technical components.
- GATE: verify architecture.md contains a "## Review Findings Incorporated" section. If missing, HALT — run /gaia-create-arch first to complete adversarial review and architecture refinement.
- Heading-scan the test plan for the risk-assessment section index (high-risk areas: revenue-critical, security-sensitive, complex logic) — resolve the test-plan path via the strategy-fallback rule (Critical Rules above): try `.gaia/artifacts/test-artifacts/test-plan.md`, fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md`. This file was already validated by `scripts/setup.sh` via the enforced quality gate. Section bodies are loaded on demand.
- Heading-scan `.gaia/artifacts/planning-artifacts/ux-design.md` if available for UI-flow / component-hierarchy / interaction-pattern / accessibility section anchors. Set `has_ux_design` flag.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 1 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" architecture_version="$ARCHITECTURE_VERSION"`

### Step 2 — Detect Mode

- Check `.gaia/artifacts/planning-artifacts/prd.md` header for "Mode: Brownfield".
- If brownfield mode detected: set mode to brownfield. Stories must cover gap requirements ONLY — do NOT create stories for existing implemented features.
- If no brownfield header: set mode to greenfield. Create stories for all features from the PRD.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 2 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epics_mode="$EPICS_MODE"`

### Step 3 — Define Epics

Delegate to the **architect** subagent (Theo) via `agents/architect` to define epics.

- Group related features into logical epics.
- Each epic: name, description, goal, success criteria.
- Brownfield: epics should focus on gap closure — not existing functionality.

**Epic heading format (required for downstream resolver compatibility).** When Theo and Derek author `epics-and-stories.md` in Step 4, every epic MUST use ONE of the two accepted H2 heading forms (both are honored by `scripts/lib/resolve-epic-slug.sh` post-AF-22-6):

- Form (a) — canonical em-dash form: `## E{N} — {Epic Title}` (e.g., `## E1 — Core Brain Vault`)
- Form (b) — natural-language form: `## Epic {N}: {Epic Title}` (e.g., `## Epic 1: Core Brain Vault`)

Either form resolves the per-epic slug correctly for `transition-story-status.sh`, `gaia-dev-story`, and `gaia-sprint-plan`. Do NOT mix forms within a single file. Headings using neither form (e.g., `## 1. Core Brain Vault`) will cause `transition-story-status.sh` to fail with "epic key E{N} not found".

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 3 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT"`

### Step 4 — Break Into Stories

Delegate to the **pm** subagent (Derek) via `agents/pm` to author user stories.

- For each epic, create user stories.
- Each story needs: title, description, acceptance criteria, size estimate (S/M/L/XL).
- Use format: "As a [user], I want to [action] so that [benefit]".
- Brownfield: stories must trace to PRD gap requirement IDs. Do NOT create stories for existing implemented features.
- If `has_ux_design`: frontend stories MUST reference specific UX flows, components, and interaction patterns from ux-design.md. Include relevant screen names, navigation paths, and accessibility requirements in acceptance criteria.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 4 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT" story_count="$STORY_COUNT"`

### Step 5 — Apply Test-Plan Risk Levels

- Read risk assessment from the test plan loaded in Step 1.
- For each story: if it touches a high-risk component, set the story's `Risk:` bullet to `high`. Otherwise `medium` or `low`. **AF-2026-05-30-4 / Test11 F-12+F-13**: the OUTPUT TEMPLATE in this SKILL uses the Title-case label `Risk:` (which `create-story/generate-frontmatter.sh` extracts via `extract_bullet "Risk"`). Earlier revisions of this prose said `risk_level:` (snake_case), which broke story materialization — the generator couldn't find the field and exited with `missing field 'risk'`. Use `Risk:` here to match the template. The generator now also accepts the snake_case form as a fallback (belt-and-braces).
- High-risk stories: add to Dev Notes: "Risk: HIGH — run /gaia-atdd before /gaia-dev-story".

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 5 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" high_risk_count="$HIGH_RISK_COUNT"`

### Step 6 — Declare Dependencies

Delegate to the **architect** subagent (Theo) via `agents/architect` to determine dependency topology.

- For each story, declare `Depends on: [story-ids]` and `Blocks: [story-ids]` bullets. **AF-2026-05-30-4 / Test11 F-12+F-13**: same labeling note as Step 5 — the OUTPUT TEMPLATE uses Title-case `Depends on:` / `Blocks:`, which is what `create-story/generate-frontmatter.sh` extracts. Earlier revisions of this prose said `depends_on:` / `blocks:` (snake_case); that drift made the SV-07 finalize-check fail and broke generate-frontmatter's depends-on extraction. The generator now accepts both forms as a fallback.
- Ensure no circular dependencies.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 6 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" deps_declared="$DEPS_DECLARED"`

### Step 7 — Priority Ordering

Delegate to the **pm** subagent (Derek) via `agents/pm` to set business priority.

- Sort stories by: dependency topology first, then business priority.
- Assign priority: P0 (must-have), P1 (should-have), P2 (nice-to-have).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 7 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" story_count="$STORY_COUNT" priority_assigned="$PRIORITY_ASSIGNED"`

### Step 8 — Generate Output

Write the epics and stories document to `.gaia/artifacts/planning-artifacts/epics-and-stories.md`. Each story formatted as:

```
### Story E{N}-S{N}: {Title}
- Epic: {epic KEY, e.g. E1 — NOT the epic name}
- Priority: {P0/P1/P2}
- Size: {S/M/L/XL}
- Risk: {high/medium/low}
- Depends on: [E{N}-S{N}, E{N}-S{N}, ...]   # story keys in the same E{N}-S{N} form, NOT plain numbers
- Blocks: [{story-ids}]
- Acceptance Criteria:
  - AC1: {criteria}
```

Concrete example (this is what the finalize.sh gate regex `^### Story E[0-9]+-S[0-9]+` will match):

```
### Story E1-S1: Vault folder creation and git initialization
- Epic: E1
- Priority: P0
- Size: M
- Risk: high
- Depends on: []
- Blocks: [E1-S2]
- Acceptance Criteria:
  - AC1: Given a fresh project dir, when `gaia-init` runs, then `.gaia/` is created and committed.
```

> **Heading-format contract (H-1, Test07).** The story heading is literally
> `### Story E{N}-S{N}: {Title}` — note the literal letter `S` between the epic
> and story numbers (e.g. `### Story E1-S1:`, NOT `### Story E1-1:`). The
> finalize.sh SV-04..SV-10 gate regex `^### Story E[0-9]+-S[0-9]+` enforces
> this verbatim — a heading without the `S` reports as "no story headings found"
> and collapses every per-story check to FAIL. Same `E{N}-S{N}` form applies to
> story keys inside `Depends on:` and `Blocks:` lists.

> **Field-format contract (F-017/F-018, Test04).** Author bullets as plain
> `- Label: value` (the consumer `generate-frontmatter.sh` also tolerates the
> bold `- **Label:** value` form). The `Epic:` value MUST be the epic KEY
> (`E1`), not the epic name — `transition-story-status.sh` resolves it via
> `resolve-epic-slug.sh --epic-key`. The `Risk:` value drives `/gaia-atdd`
> batch discovery, which reads this exact `### Story` + `- Risk:` block shape.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/epics-and-stories.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 8 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epic_count="$EPIC_COUNT" story_count="$STORY_COUNT" --paths .gaia/artifacts/planning-artifacts/epics-and-stories.md`

### Step 9 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/epics-and-stories.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/epics-and-stories.md`, `artifact_type = epics-and-stories`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/epics-and-stories.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Concurrent invocations of this skill are safe per E44-S5 AC-EC5: each invocation has its own iteration counter (centralized in the canonical pattern), so loop state is per-invocation, not shared.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 9 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/epics-and-stories.md`

### Step 10 — Brownfield: Generate Onboarding Knowledge Base (optional)

Skip this step if mode is greenfield.

- Generate onboarding doc as a knowledge base index linking to ALL artifacts.
- Write to `.gaia/artifacts/planning-artifacts/brownfield-onboarding.md`.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 10 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" epics_mode=brownfield brownfield_onboarding_written="$BROWNFIELD_ONBOARDING_WRITTEN"`

### Step 11 — Edge Case Analysis (optional)

- Ask: "Would you like to hunt for edge cases in the stories? Recommended to catch gaps before sprint planning. (yes / skip)"
- If yes: spawn edge case analysis subagent.
- If skip: edge case analysis can be run anytime later with /gaia-edge-cases.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 11 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" edge_cases_run="$EDGE_CASES_RUN"`

### Step 12 — Adversarial Review (optional)

- Ask: "Would you like to run an adversarial review on the epics and stories? Recommended before sprint planning. (yes / skip)"
- If yes: spawn adversarial review subagent.
- If skip: adversarial review can be run anytime later with /gaia-adversarial.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-epics 12 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" adversarial_run="$ADVERSARIAL_RUN"`

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

  See .gaia/artifacts/implementation-artifacts/E42-S10-port-gaia-create-epics-31-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to .gaia/artifacts/planning-artifacts/epics-and-stories.md
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
