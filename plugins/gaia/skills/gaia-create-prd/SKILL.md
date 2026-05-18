---
name: gaia-create-prd
description: Create a Product Requirements Document through collaborative discovery with the pm subagent (Derek) — Cluster 5 planning skill. Use when the user wants to produce a validated PRD from an existing product brief, covering goals, functional/non-functional requirements, user journeys, data requirements, integrations, and success criteria.
argument-hint: "[product-brief-path]"
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
# Discover-Inputs Protocol (ADR-062 / FR-346 / E45-S4)
# Strategy: INDEX_GUIDED — load product brief + research artifact indexes
# (TOC, heading scan) first; fetch named sections on demand in later steps.
# Falls back to FULL_LOAD when an upstream artifact lacks parseable headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: "docs/creative-artifacts/product-brief.md, docs/creative-artifacts/market-research.md, docs/creative-artifacts/domain-research.md, docs/creative-artifacts/tech-research.md"
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-prd/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh pm all

## Mission

You are orchestrating the creation of a Product Requirements Document (PRD). The PRD authoring is delegated to the **pm** subagent (Derek), who conducts user interviews, elicits requirements, and produces the final artifact. You load the product brief, validate inputs, coordinate the multi-step flow, and write the output to `docs/planning-artifacts/prd.md` using the canonical `prd-template.md` template structure.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/2-planning/create-prd` workflow (brief Cluster 5, story P5-S1 / E28-S40). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A product brief MUST exist before starting. The `[product-brief-path]` argument is required — fail fast with "product-brief-path required" error if missing.
- If the product brief file does not exist at the supplied path, fail pre-flight with "product brief not found at <path>" — do not create a partial PRD.
- Every requirement must have a unique ID: `FR-###` (functional), `NFR-###` (non-functional).
- Requirements must be discoverable from user interviews, not guessed.
- Each requirement must have testable acceptance criteria.
- PRD authoring prompts are delegated to the `pm` subagent (Derek) via native Claude Code subagent invocation — do NOT inline Derek's persona into this skill body. If the pm subagent (E28-S21) is not available, fail with "pm subagent not available — install E28-S21" error.
- If `docs/planning-artifacts/prd.md` already exists, warn the user: "An existing PRD was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Template resolution: load `prd-template.md` from this skill directory. If `custom/templates/prd-template.md` exists and is non-empty, use the custom template instead — the custom template takes full precedence over the framework default (ADR-020 / FR-101).

## Steps

### Step 1 — Load Product Brief

> **Loading strategy: INDEX_GUIDED per ADR-062.** The product brief plus the
> three research artifacts can total 30K+ tokens combined. Load each
> artifact's index first (heading scan via `grep -nE '^#{1,3} '`) — do NOT
> read full bodies up front. Fetch named sections on demand in later steps
> (e.g., extract `## Vision Statement` only when Step 4 requires it). If an
> artifact has no parseable headings, fall back to FULL_LOAD for that file
> only.

- Validate that `[product-brief-path]` argument was provided. If missing, fail fast: "product-brief-path required — provide the path to the product brief file."
- Heading-scan the product brief at the supplied path (build a section index).
- Heading-scan available research artifacts (`docs/creative-artifacts/market-research*.md`, `domain-research*.md`, `tech-research*.md`) — index-only, not full bodies.
- Extract section anchors (not contents) for: vision, target users, problem statement, proposed solution, scope and boundaries, risks and assumptions, competitive landscape, success metrics. Section bodies are loaded on demand by later steps.
- If `docs/planning-artifacts/prd.md` already exists: warn "An existing PRD was found at docs/planning-artifacts/prd.md. Continuing will overwrite it. Confirm with user before proceeding."

> `!scripts/write-checkpoint.sh gaia-create-prd 1 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 2 — User Interviews

Delegate to the **pm** subagent (Derek) via `agents/pm` to conduct user interviews.

The pm subagent asks the user:

1. Who are the primary user types?
2. What are their top 3 needs?
3. What frustrates them most about current solutions?

Structure responses into user need statements.

> `!scripts/write-checkpoint.sh gaia-create-prd 2 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 3 — Functional Requirements

Delegate to the **pm** subagent (Derek) to elicit and structure functional requirements:

- List features organized by priority: Must-Have, Should-Have, Nice-to-Have.
- Each feature needs: description, user story format, acceptance criteria.
- Assign unique IDs: FR-001, FR-002, ... — IDs are sequential and never reused.
- Cross-reference with product brief: verify each FR is traceable to the brief's proposed solution or key features. Flag any FR that introduces scope not present in the brief — confirm with user before including.

> `!scripts/write-checkpoint.sh gaia-create-prd 3 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 4 — Non-Functional Requirements

Delegate to the **pm** subagent (Derek) to define non-functional requirements:

- Define: performance targets, security requirements, accessibility standards.
- Define: scalability needs, reliability targets, compliance requirements.
- Assign unique IDs: NFR-001, NFR-002, ... — IDs are sequential and never reused.
- Each NFR MUST include a measurable target with a specific threshold (e.g., "response time < 200ms at p95", "99.9% uptime", "WCAG 2.1 AA compliance"). Reject vague qualifiers like "fast", "secure", "scalable" without numeric criteria.

> `!scripts/write-checkpoint.sh gaia-create-prd 4 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 5 — User Journeys

- Map key user flows with happy path and error paths.
- Include: entry point, steps, decision points, exit conditions.

> `!scripts/write-checkpoint.sh gaia-create-prd 5 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 6 — Data Requirements

- Identify data stored, processed, and exchanged.
- Define data retention, privacy, and security policies.

> `!scripts/write-checkpoint.sh gaia-create-prd 6 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 7 — Integration Requirements

- List external systems, APIs, and third-party services.
- Define integration patterns and data exchange formats.
- For each critical dependency: define failure mode, fallback behavior, and SLA expectations.

> `!scripts/write-checkpoint.sh gaia-create-prd 7 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 8 — Out of Scope

- List features, integrations, and use cases explicitly excluded from this release.
- For each exclusion: state what is excluded and why (deferred, not needed, separate product).
- Cross-reference with product brief: items listed as out-of-scope in the brief's "Scope and Boundaries" section must appear here. Flag any brief out-of-scope item missing from this list.

> `!scripts/write-checkpoint.sh gaia-create-prd 8 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 9 — Constraints and Assumptions

- Document technical, budget, timeline, and team constraints.
- List all assumptions that requirements depend on.
- Cross-reference with product brief: carry forward every risk and assumption from the brief's "Risks and Assumptions" section. Each must appear in this section or be explicitly noted as resolved with justification.

> `!scripts/write-checkpoint.sh gaia-create-prd 9 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 10 — Success Criteria

- Define measurable acceptance criteria for each feature.
- Define overall product success metrics.
- Cross-reference with product brief: every metric from the brief's "Success Metrics" section must have a corresponding measurable criterion in the PRD. Flag any brief metric not covered.

> `!scripts/write-checkpoint.sh gaia-create-prd 10 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 11 — Generate Output

Load the `prd-template.md` template from this skill directory (or from `custom/templates/prd-template.md` if a custom override exists and is non-empty).

Write the PRD to `docs/planning-artifacts/prd.md` with all sections populated:

- Overview
- Goals and Non-Goals
- User Stories
- Functional Requirements (prioritized with FR-### IDs)
- Non-Functional Requirements (with NFR-### IDs and measurable targets)
- Out of Scope
- UX Requirements
- Technical Constraints
- Dependencies (with failure modes, fallback behaviors, SLA expectations)
- Milestones
- Requirements Summary table (all FR and NFR IDs with description, priority, status)
- Open Questions

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/prd.md`

> `!scripts/write-checkpoint.sh gaia-create-prd 11 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG" --paths docs/planning-artifacts/prd.md`

### Step 12 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/planning-artifacts/prd.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/planning-artifacts/prd.md`, `artifact_type = prd`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/planning-artifacts/prd.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation MUST run against the Step 11 primary write (artifact-as-drafted), not the post-adversarial revision produced by the next steps — see story E44-S4 AC3 rationale.

> `!scripts/write-checkpoint.sh gaia-create-prd 12 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG" stage=val-auto-review --paths docs/planning-artifacts/prd.md`

### Step 13 — Adversarial Review

- Read `${CLAUDE_PLUGIN_ROOT}/knowledge/adversarial-triggers.yaml` to evaluate trigger rules. (This policy table ships inside the plugin under ADR-041's `knowledge/` convention; the legacy v1 location `_gaia/_config/adversarial-triggers.yaml` is retired and no longer used.) Determine the current `change_type`: if invoked with a change_type context (e.g., from add-feature triage), use that value. If no context is available (standalone PRD creation), default to "feature".
- Look up the trigger rule for `change_type` + artifact "prd". If adversarial is false for this combination: skip the adversarial review. Add a "## Review Findings Incorporated" section with "Adversarial review not triggered — change type: {change_type}".
- If adversarial is true: spawn a subagent to run the adversarial review task against `docs/planning-artifacts/prd.md`.
- When subagent returns: verify `adversarial-review-prd-*.md` exists in `docs/planning-artifacts/`.

> `!scripts/write-checkpoint.sh gaia-create-prd 13 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG"`

### Step 14 — Incorporate Adversarial Findings

- Read `docs/planning-artifacts/adversarial-review-prd-*.md` — extract critical and high severity findings.
- For each critical/high finding: add as a new requirement or refine an existing requirement in the PRD.
- Add a "## Review Findings Incorporated" section to the PRD listing each finding, its severity, and how it was addressed (new requirement added / existing requirement refined / acknowledged as risk).
- Write the updated PRD to `docs/planning-artifacts/prd.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/prd.md`

> `!scripts/write-checkpoint.sh gaia-create-prd 14 project_name="$PROJECT_NAME" prd_version="$PRD_VERSION" feature_slug="$FEATURE_SLUG" --paths docs/planning-artifacts/prd.md`

## Validation

<!--
  E42-S6 — V1→V2 36-item checklist port (FR-341, FR-359, VCP-CHK-11, VCP-CHK-12).
  Classification (36 items total):
    - Script-verifiable: 24 (SV-01..SV-24) — enforced by finalize.sh.
    - LLM-checkable:     12 (LLM-01..LLM-12) — evaluated by the host LLM
      against the PRD artifact at finalize time.
  Exit code 0 when all 24 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at _gaia/lifecycle/workflows/2-planning/create-prd/
  checklist.md carried 21 bulleted items. The story product-brief count (36)
  is authoritative (see story Dev Notes #1): the 21 V1 bullets are expanded
  here to 36 by (a) splitting compound items (e.g., "All sections present" →
  per-section SV-04..SV-15), (b) adding envelope items SV-01..SV-03,
  (c) adding Requirements Summary Table structural + data-row checks
  (SV-16..SV-17 — AC-EC5 guard), (d) adding FR-### / NFR-### identifier
  regex checks (SV-18..SV-19), (e) adding the VCP-CHK-12 anchor check for
  dependency failure modes + fallback behaviour (SV-20), (f) adding section-
  body sanity checks (SV-21..SV-24) to catch empty sections, and (g) pulling
  12 LLM-checkable items (LLM-01..LLM-12) out of the V1 semantic bullets
  (user-focus traceability, MoSCoW, consistency, measurability, failure-mode
  credibility, scope discipline).

  The VCP-CHK-12 anchor is SV-20 — "Critical dependencies have failure modes
  and fallback behavior defined". This is the V1 phrase verbatim and MUST
  appear in violation output when the Dependencies section lacks failure-
  mode / fallback text.

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation runs
  BEFORE session-memory auto-save (AC-EC6 / ADR-061).

  See docs/implementation-artifacts/E42-S6-port-gaia-create-prd-36-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output artifact exists at docs/planning-artifacts/prd.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Overview section present
- [script-verifiable] SV-05 — Goals and Non-Goals section present
- [script-verifiable] SV-06 — User Stories section present
- [script-verifiable] SV-07 — Functional Requirements section present
- [script-verifiable] SV-08 — Non-Functional Requirements section present
- [script-verifiable] SV-09 — User Journeys section present
- [script-verifiable] SV-10 — Data Requirements section present
- [script-verifiable] SV-11 — Integration Requirements section present
- [script-verifiable] SV-12 — Out of Scope section present
- [script-verifiable] SV-13 — Constraints section present
- [script-verifiable] SV-14 — Success Criteria section present
- [script-verifiable] SV-15 — Dependencies section present
- [script-verifiable] SV-16 — Requirements Summary Table present with markdown table structure
- [script-verifiable] SV-17 — Requirements Summary Table has at least one data row
- [script-verifiable] SV-18 — At least one FR-### functional-requirement identifier present
- [script-verifiable] SV-19 — At least one NFR-### non-functional-requirement identifier present
- [script-verifiable] SV-20 — Critical dependencies have failure modes and fallback behavior defined
- [script-verifiable] SV-21 — Out of Scope section body non-empty
- [script-verifiable] SV-22 — Constraints section body non-empty
- [script-verifiable] SV-23 — Success Criteria section body non-empty
- [script-verifiable] SV-24 — User Journeys section body non-empty
- [LLM-checkable] LLM-01 — Requirements trace to user needs (user-focus traceability)
- [LLM-checkable] LLM-02 — User stories use the standard "As a... I want... so that..." format
- [LLM-checkable] LLM-03 — Each functional requirement has testable acceptance criteria
- [LLM-checkable] LLM-04 — Acceptance criteria are measurable and unambiguous
- [LLM-checkable] LLM-05 — MoSCoW (or equivalent) prioritisation applied to features
- [LLM-checkable] LLM-06 — No contradictions between requirements
- [LLM-checkable] LLM-07 — Terminology used consistently throughout the PRD
- [LLM-checkable] LLM-08 — User journeys are meaningful and cover happy + error paths
- [LLM-checkable] LLM-09 — Non-functional requirements have measurable targets (thresholds, not vague qualifiers)
- [LLM-checkable] LLM-10 — Constraints are coherent and compatible with the proposed solution
- [LLM-checkable] LLM-11 — Dependency failure modes are articulated with realistic SLAs
- [LLM-checkable] LLM-12 — Scope boundaries are defensible against feature creep

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-prd/scripts/finalize.sh

## Next Steps

- Primary: `/gaia-create-ux` — Create UX design specifications for the validated PRD.
