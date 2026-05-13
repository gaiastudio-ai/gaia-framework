---
name: gaia-create-arch
description: Design system architecture through collaborative discovery with the architect subagent (Theo) — Cluster 6 architecture skill. Use when the user wants to produce a validated architecture document from an existing PRD, covering technology selection, system components, data architecture, API design, infrastructure, security architecture, and architecture decision records.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
# Discover-Inputs Protocol (ADR-062 / FR-346 / E45-S4)
# Strategy: INDEX_GUIDED — the PRD is typically 20K+ tokens. Load the PRD
# index (heading scan or §N.x table of contents) first; fetch named
# sections on demand in later steps. Falls back to FULL_LOAD when the PRD
# lacks parseable headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: docs/planning-artifacts/prd.md
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE"
```

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all

## Mission

You are orchestrating the creation of a System Architecture document. The architecture authoring is delegated to the **architect** subagent (Theo), who conducts technology selection, designs system components, and produces the final artifact. You load the PRD, validate inputs, coordinate the multi-step flow, and write the output to `docs/planning-artifacts/architecture.md` using the carried `architecture-template.md` template structure.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/create-architecture` workflow (brief Cluster 6, story P6-S1 / E28-S45). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST exist at `docs/planning-artifacts/prd.md` before starting. If missing, fail fast with "PRD not found at docs/planning-artifacts/prd.md — run /gaia-create-prd first."
- The PRD MUST contain a "## Review Findings Incorporated" section. If missing, fail fast with "PRD review findings not found — run /gaia-create-prd to complete adversarial review and PRD refinement."
- Every significant technical decision must be recorded as an ADR inline in the Decision Log table of the architecture document.
- Architecture authoring is delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation — do NOT inline Theo's persona into this skill body. If the architect subagent (E28-S21) is not available, fail with "architect subagent not available — install E28-S21" error.
- If `docs/planning-artifacts/architecture.md` already exists, warn the user: "An existing architecture document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Template resolution: load `architecture-template.md` from this skill directory. If `custom/templates/architecture-template.md` exists and is non-empty, use the custom template instead — the custom template takes full precedence over the framework default (ADR-020 / FR-101).
- ADRs live inline in the architecture document's Decision Log table — there is no separate ADR directory. Preserve the legacy workflow's ADR placement convention.
- Every technical decision must connect to business value.

## Steps

### Step 1 — Load Upstream Artifacts

> **Loading strategy: INDEX_GUIDED per ADR-062.** The PRD is routinely
> 20K+ tokens — full-loading it here burns the context budget before
> architecture authoring even begins. Heading-scan `prd.md` first (e.g.,
> `grep -nE '^#{1,3} ' docs/planning-artifacts/prd.md`) to build a section
> index. Fetch §N.x bodies on demand in later steps (`sed -n` between
> heading anchors). If the PRD has no parseable headings, fall back to
> FULL_LOAD and log the fallback in the checkpoint.

- Heading-scan `docs/planning-artifacts/prd.md` to build a section index of requirements (functional and non-functional). Do NOT read the full body up front.
- GATE: verify prd.md contains a "## Review Findings Incorporated" section. If missing, HALT — run /gaia-create-prd first to complete adversarial review and PRD refinement.
- Heading-scan `docs/planning-artifacts/ux-design.md` if available — record section anchors for UI requirements.
- Check for brownfield artifacts: `docs/planning-artifacts/brownfield-assessment.md` and `docs/planning-artifacts/project-documentation.md`. If either exists, heading-scan them — these contain existing codebase analysis that must inform architecture decisions even if the PRD is not in brownfield mode.
- Check for `docs/planning-artifacts/threat-model.md`. If it exists, heading-scan it — identified threats and mitigations must inform the security architecture in Step 7. Section bodies are loaded on demand by later steps.

> `!scripts/write-checkpoint.sh gaia-create-arch 1 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION"`

### Step 2 — Detect Mode

- Check `docs/planning-artifacts/prd.md` header for "Mode: Brownfield".
- If brownfield mode detected: set mode to brownfield. Use brownfield architecture template.
- If no brownfield header: set mode to greenfield. Load `architecture-template.md` from this skill directory. If `custom/templates/architecture-template.md` exists and is non-empty, use the custom template instead.

> `!scripts/write-checkpoint.sh gaia-create-arch 2 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" arch_mode="$ARCH_MODE"`

### Step 3 — Technology Selection

Delegate to the **architect** subagent (Theo) via `agents/architect` to select the technology stack.

- Greenfield: select tech stack with rationale for each choice. Consider: team expertise, scalability needs, ecosystem maturity.
- Brownfield: discover existing tech stack from project-documentation.md and code scan. Mark ADR status as "Existing" for discovered decisions.
- If brownfield artifacts were loaded in Step 1: reference the existing tech stack, constraints, and integration points when evaluating technology choices.
- Record decision as ADR in the architecture document's Decision Log table.
- Present recommended technology stack to the user for confirmation.

> `!scripts/write-checkpoint.sh gaia-create-arch 3 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=technology-selection`

### Step 3.5 — Tech-Stack Confirmation Pause

> **Parity restoration — E46-S6 / FR-354 / AF-2026-04-24-1.** This sub-step
> restores the V1 tech-stack confirmation gate that was dropped during the
> Claude Code native migration (E28). It MUST fire after Step 3 returns and
> BEFORE Step 4 begins. Step 4..N are NOT renumbered — Step 3.5 is a
> deliberate non-integer slot so that downstream cross-references in
> `epics-and-stories.md`, `test-plan.md §11.46.14`, and
> `traceability-matrix.md` continue to resolve.

> **Variable contract.** This sub-step writes a runtime variable named
> `confirmed_tech_stack`. **Steps 4 and later MUST read the tech stack from
> `confirmed_tech_stack` — never from the original Theo response object
> (e.g., `theo_response.tech_stack`, `recommendation.primary`).** This
> single contract is what makes the `[m]odify` branch actually take effect
> downstream. If a future refactor short-circuits the variable, that is a
> regression — flag it as a Finding.

Render the recommendation Theo returned in Step 3 to the user as a fenced
block in this exact shape:

```text
Recommended Tech Stack
======================

Primary: <stack label, e.g., "TypeScript / Next.js / Postgres">

Key libraries / frameworks:
  - <library>: <one-line rationale>
  - <library>: <one-line rationale>
  - ...

Deferred / rejected alternatives:
  - <alternative>: <why deferred or rejected>
  - ...

[a]ccept / [m]odify / [r]eject
```

Wait for the user's response before proceeding. Branch handlers:

- **`[a]ccept`** — Set `confirmed_tech_stack` to Theo's recommendation
  unchanged. Append the audit entry "Tech stack accepted as recommended"
  to the in-session ADR-sidecar buffer (flushed in the finalize step;
  see "Append Architecture Decisions to Sidecar" below). Proceed to Step 4.
- **`[m]odify`** — Prompt the user for a free-form modification patch
  (replacements, additions, removals). Apply the patch to Theo's
  recommendation, write the result to `confirmed_tech_stack`, and append
  the audit entry "Tech stack modified by user: {diff}" to the
  in-session ADR-sidecar buffer. Proceed to Step 4.
- **`[r]eject`** — HALT Step 4. Offer two sub-options:
  1. **Re-invoke Theo with rejection notes** — gather a short rejection
     rationale from the user, re-invoke the gaia:architect subagent with that
     rationale appended, and re-render the pause when Theo returns. The
     pause repeats until the user picks `[a]ccept` or `[m]odify`, or
     escalates to abort.
  2. **Abort workflow** — exit with status `aborted at tech-stack confirmation`.
     Write NO `docs/planning-artifacts/architecture.md` file. Write NO
     sidecar entry. The session ends cleanly with the abort status surfaced
     to the caller.

> **YOLO / non-interactive mode (deliberate concession).** When the skill
> runs in YOLO or any other non-interactive mode where no human input can
> be solicited, the pause MUST still fire and emit an audit entry. The
> degraded behavior is: set `confirmed_tech_stack` to Theo's recommendation
> unchanged, append the audit entry "YOLO auto-accepted tech stack (no user
> pause)" to the in-session ADR-sidecar buffer, and proceed to Step 4. This
> is a documented product decision (AF-2026-04-24-1) — a hard pause in
> YOLO would break the non-interactive batch use case. Do NOT read the
> YOLO short-circuit as a regression.

> Step 3.5 is a confirmation gate, not a standalone step — it does not
> emit its own checkpoint. The `confirmed_tech_stack` value plus the
> in-session ADR-sidecar audit buffer flow through to Step 4 (which
> emits its own checkpoint) and Step 13 (which flushes the buffer to
> the sidecar). Keeping the canonical Phase-3-solutioning step count
> at 13 preserves cross-skill checkpoint-counting invariants.

### Step 4 — System Architecture

> **Tech stack input contract.** Step 4 (and every subsequent step that
> consumes the tech stack) MUST read from the `confirmed_tech_stack`
> runtime variable set by Step 3.5 — never from Theo's raw Step 3
> response. This is the load-bearing wire that makes the `[m]odify` and
> `[r]eject → re-invoke` branches of Step 3.5 actually flow downstream.

Delegate to the **architect** subagent (Theo) via `agents/architect` to design the system architecture.

- Greenfield: define component diagram and service boundaries. Describe communication patterns. Record architectural style as ADR.
- Brownfield: document as-is architecture with Mermaid diagrams:
  - System context diagram (C4 Level 1)
  - Container diagram (C4 Level 2)
  - 3-5 sequence diagrams for key system flows
  - Data flow diagram
  - Target architecture for gaps identified in the PRD
  - As-is vs target delta table

> `!scripts/write-checkpoint.sh gaia-create-arch 4 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=system-architecture`

### Step 5 — Data Architecture

Delegate to the **architect** subagent (Theo) via `agents/architect` to design data architecture.

- Design database schema and data model.
- Define data flow between components.
- Specify data storage, caching, and replication strategies.

> `!scripts/write-checkpoint.sh gaia-create-arch 5 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=data-architecture`

### Step 6 — API Design

Delegate to the **architect** subagent (Theo) via `agents/architect` to design APIs.

- Define API endpoint overview.
- Specify authentication and authorization strategy.
- Document API versioning approach.

> `!scripts/write-checkpoint.sh gaia-create-arch 6 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=api-design`

### Step 7 — Infrastructure and Cross-Cutting Concerns

Delegate to the **architect** subagent (Theo) via `agents/architect` to define infrastructure.

- Define deployment topology and environments (dev, staging, prod).
- Specify hosting, containerization, and orchestration choices.
- Define monitoring and logging strategy.
- Define security architecture: if threat-model.md was loaded, cross-reference identified threats and map each critical/high threat to an architectural mitigation. If no threat model exists, prompt user for key security requirements.
- Brownfield: document security architecture, cross-cutting concerns with current state and gaps. Define migration strategy. Cross-reference api-documentation.md, event-catalog.md, dependency-map.md in the Integration Architecture section.

> `!scripts/write-checkpoint.sh gaia-create-arch 7 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=infra-and-cross-cutting`

### Step 8 — Architecture Decision Records

Delegate to the **architect** subagent (Theo) via `agents/architect` to compile ADRs.

- Review all decisions made in Steps 3-7.
- Ensure each significant decision is recorded as ADR with: Title, Date, Status, Context, Decision, Alternatives Considered, Consequences, Addresses (FR/NFR IDs).
- Brownfield: mark existing decisions as status "Existing", new gap-related decisions as "Proposed".
- Generate a "Decision to Requirement Mapping" table mapping each ADR to the FR/NFR IDs it addresses. Flag any FR/NFR from the PRD with no corresponding ADR as a coverage gap.

> `!scripts/write-checkpoint.sh gaia-create-arch 8 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" adr_count="$ADR_COUNT"`

### Step 9 — Generate Output

- Write the architecture document to `docs/planning-artifacts/architecture.md` using the `architecture-template.md` section structure.
- Greenfield: include technology stack, system architecture, data architecture, API design, infrastructure plan, ADR references, and Decision-to-Requirement Mapping table.
- Brownfield: include C4 diagrams, sequence diagrams, data flow diagram, as-is/target delta table, migration strategy, and cross-references.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/architecture.md`

> `!scripts/write-checkpoint.sh gaia-create-arch 9 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" --paths docs/planning-artifacts/architecture.md`

### Step 10 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/planning-artifacts/architecture.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/planning-artifacts/architecture.md`, `artifact_type = architecture`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/planning-artifacts/architecture.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation runs against the Step 9 primary write (artifact-as-drafted). Per story E44-S5 AC-EC9 and the Adversarial-loop Val scope decision in story Dev Notes, Step 13's post-adversarial re-write does NOT trigger a second Val invocation.

> `!scripts/write-checkpoint.sh gaia-create-arch 10 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" stage=val-auto-review --paths docs/planning-artifacts/architecture.md`

### Step 11 — Optional: API Design Review

- Ask user: "Would you like to review the API design against REST standards? Recommended if your architecture includes APIs. (yes / skip)"
- If yes: invoke the API design review task.
- If skip: API review can be run anytime later with /gaia-review-api.

> `!scripts/write-checkpoint.sh gaia-create-arch 11 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" api_review_run="$API_REVIEW_RUN"`

### Step 12 — Adversarial Review

- Read adversarial-triggers.yaml to evaluate trigger rules.
- If adversarial review is triggered: spawn a subagent for adversarial review of the architecture document.
- If not triggered: add "## Review Findings Incorporated" section noting the review was not triggered.

> `!scripts/write-checkpoint.sh gaia-create-arch 12 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" adversarial_triggered="$ADVERSARIAL_TRIGGERED"`

### Step 13 — Incorporate Adversarial Findings

- Read adversarial review findings.
- For each critical/high finding: update the architecture — add missing components, revise decisions, strengthen security/scalability, update ADRs.
- Add a "## Review Findings Incorporated" section to the architecture document listing each finding, its severity, and how it was addressed.
- Write the final architecture document.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/architecture.md`

> `!scripts/write-checkpoint.sh gaia-create-arch 13 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" --paths docs/planning-artifacts/architecture.md _memory/architect-sidecar/architecture-decisions.md`

#### Append Architecture Decisions to Sidecar (E46-S6 / FR-354)

> **Run order — strict.** This action runs ONLY AFTER the architecture
> document write succeeds in Step 13. If the architecture write failed,
> skip the sidecar write entirely — the inline Decision Log in
> `architecture.md` is the primary artifact, and a sidecar without a
> matching architecture document is worse than no sidecar.

> **Sidecar path — fixed.** Write to
> `_memory/architect-sidecar/architecture-decisions.md`. This path is
> not configurable via `global.yaml`; it is fixed by ADR-016 and
> §10.10 of `architecture.md`. Do NOT relocate it under `custom/` or
> under `_gaia/`.

**Steps:**

1. Build the in-session decisions list from (a) every row appended to
   the architecture.md `§ Decision Log` table during Steps 3–13, and
   (b) every audit entry buffered by Step 3.5 (accept / modify /
   reject / YOLO auto-accept).
2. If `_memory/architect-sidecar/architecture-decisions.md` does NOT
   exist, create it with the canonical header:

   ```markdown
   # Architect — Architecture Decisions

   > Sidecar log of architecture decisions per ADR-016 format. Mirrors the inline Decision Log in architecture.md.

   ---
   ```

3. Build a session header for this run in the form
   `### Session {YYYY-MM-DD} — {feature_or_scope_label}`, using the
   project name + Step 1 scope label. This header groups all entries
   from a single `/gaia-create-arch` invocation.
4. **Append-only safety (AC5).** Read the existing sidecar before
   writing. If a session header with the same date AND
   `feature_or_scope_label` already exists, append ONLY the new ADR
   entries under that header (dedup key = ADR ID — never write the
   same ADR ID twice within one session header). If no matching
   header exists, append a NEW session header block at the end of the
   file. **Never overwrite, mutate, or reorder an existing entry.**
5. Emit one ADR-016-formatted entry per decision under the session
   header. Each entry MUST match the inline Decision Log row exactly
   on the five fields **ADR ID, Decision, Rationale, Status, Source**
   — no sixth column, no field rename. The session-header grouping is
   the only sidecar-only addition.
6. Append a trailing `---` separator after the session group so
   subsequent sessions land in their own block.

> **Non-blocking write error policy (Subtask 3.5).** If the sidecar
> write fails (permission denied, disk full, path missing and
> creation fails), log the WARNING `ADR sidecar write failed:
> {reason}. Inline Decision Log in architecture.md is authoritative.`
> to the workflow output and CONTINUE. Do NOT re-raise as a HALT —
> `architecture.md` is already written and is the primary source.

> **Append-only contract — absolute.** Re-runs MAY ONLY append new
> entries; existing entries are byte-identical across sessions. This
> makes the sidecar usable as a git-friendly audit trail — reviewers
> can `git diff` it across sessions and see exactly which decisions
> were added by each `/gaia-create-arch` invocation.

> The sidecar write is a sub-action of Step 13 (terminal write of
> the architecture document) — it does not emit its own checkpoint.
> The Step 13 checkpoint is the canonical observability anchor for
> the finalize phase; the sidecar path appears in that checkpoint's
> `--paths` set when the write succeeds. Keeping the canonical
> Phase-3-solutioning step count at 13 preserves cross-skill
> checkpoint-counting invariants enforced by
> `tests/vcp-cpt-09-phase3-solutioning.bats`.

#### Hydrate project-config.yaml (E85-S5 / FR-457)

> **Run order — strict.** Runs ONLY AFTER the architecture document
> write in Step 13 has succeeded and the sidecar append above has
> completed. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh`,
> then build two `mktemp` YAML fragment files from `confirmed_tech_stack`
> (Step 3.5 canonical variable) — one with `stacks:` payload, one with
> `platforms:` payload — and call `config_hydrate_section stacks <file>`
> followed by `config_hydrate_section platforms <file>` (per ADR-098,
> the helper's second arg is a file path, not a literal string). `rm -f`
> both fragment files after the calls return.

> **Idempotency contract (ADR-098).** When `config_phase` is already
> `partial` or `full` in `config/project-config.yaml`, both calls are
> safe no-ops — the helper short-circuits the write and the file is
> byte-unchanged. When `config_phase` is `minimal`, the helper writes
> the section and advances `config_phase` to `partial` monotonically.
> The helper NEVER writes `config_phase: full` — that transition is
> reserved for `validate-project-config.sh` (E85-S4 / ADR-096).

> **Non-blocking error policy.** Capture `$?` from each call. The helper
> already logs `config-hydration: WARN/CRITICAL ...` to stderr for any
> failure (rc=0 ok, rc=1 generic, rc=2 allowlist, rc=3 lock timeout); a
> non-zero rc does NOT HALT the workflow — `architecture.md` has already
> been written and is the primary artifact. Same policy as the sidecar
> write above. The hydration trigger is purely a SKILL.md finalize-step
> addition; no architect subagent or template changes (AC5 / FR-457).

## Validation

<!--
  E42-S8 — V1→V2 33-item checklist port (FR-341, FR-359, VCP-CHK-15, VCP-CHK-16).
  Classification (33 items total):
    - Script-verifiable: 25 (SV-01..SV-25) — enforced by finalize.sh.
    - LLM-checkable:      8 (LLM-01..LLM-08) — evaluated by the host LLM
      against the architecture artifact at finalize time.
  Exit code 0 when all 25 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at _gaia/lifecycle/workflows/3-solutioning/create-architecture/
  checklist.md carried 17 bulleted items. The story 33-item count is
  authoritative: the 17 V1 bullets are expanded here to 33 by
  (a) adding envelope items SV-01..SV-03 (artifact presence, non-empty,
  frontmatter), (b) splitting "All required sections present" into
  per-section presence checks (SV-04..SV-11 — System Overview,
  Architecture Decisions, System Components, Data Architecture,
  Integration Points, Infrastructure, Security Architecture,
  Cross-Cutting Concerns), (c) preserving the V1 body-sanity anchors
  verbatim as SV-12..SV-19 (Stack selected with rationale, Component
  diagram described, Service boundaries defined, Data model defined,
  Data flow documented, Endpoints overviewed, Auth strategy defined,
  Deployment topology described), (d) adding Decision Log structural
  checks (SV-20..SV-22 — table present, ADRs present (V1 "Decisions
  recorded"), ADR fields populated), (e) preserving SV-23 (cross-
  cutting documented) and gate/output items SV-24..SV-25 (Review
  Findings Incorporated section; FR-### traceability), and (f) pulling
  8 LLM-checkable items (LLM-01..LLM-08) from the V1 semantic bullets
  (tech-stack trade-offs, communication pattern coherence, ADR
  rationale quality, Decision-to-Requirement coverage, security vs
  threat model, env progression, cross-cutting adequacy, adversarial
  incorporation traceability).

  The VCP-CHK-16 anchor is SV-21 — "Decisions recorded". This is the
  V1 phrase verbatim and MUST appear in violation output when the
  Decision Log table is heading-only (AC-EC5).

  Per-item LLM-checkable timeout contract: 30s wall-clock per item
  (AC-EC7). Malformed verdict (no explicit PASS/FAIL) is treated as
  FAIL — never skip (AC-EC4).

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).

  See docs/implementation-artifacts/E42-S8-port-gaia-create-arch-33-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file exists at docs/planning-artifacts/architecture.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — System Overview section present
- [script-verifiable] SV-05 — Architecture Decisions section present (Decision Log)
- [script-verifiable] SV-06 — System Components section present
- [script-verifiable] SV-07 — Data Architecture section present
- [script-verifiable] SV-08 — Integration Points section present
- [script-verifiable] SV-09 — Infrastructure section present
- [script-verifiable] SV-10 — Security Architecture section present
- [script-verifiable] SV-11 — Cross-Cutting Concerns section present
- [script-verifiable] SV-12 — Stack selected with rationale
- [script-verifiable] SV-13 — Component diagram described
- [script-verifiable] SV-14 — Service boundaries defined
- [script-verifiable] SV-15 — Data model defined
- [script-verifiable] SV-16 — Data flow documented
- [script-verifiable] SV-17 — Endpoints overviewed
- [script-verifiable] SV-18 — Auth strategy defined
- [script-verifiable] SV-19 — Deployment topology described
- [script-verifiable] SV-20 — Decision Log table present with markdown table structure
- [script-verifiable] SV-21 — Decisions recorded (Decision Log table has at least one ADR row)
- [script-verifiable] SV-22 — Each ADR has context, decision, consequences (ADR row fields populated)
- [script-verifiable] SV-23 — Cross-cutting concerns documented
- [script-verifiable] SV-24 — Review Findings Incorporated section present
- [script-verifiable] SV-25 — At least one FR-### identifier referenced (traceability)
- [LLM-checkable] LLM-01 — Trade-offs documented (tech-stack choices justified against alternatives)
- [LLM-checkable] LLM-02 — Communication patterns specified (sync vs async, at-least-once vs exactly-once)
- [LLM-checkable] LLM-03 — Each ADR has context, decision, consequences with sound rationale
- [LLM-checkable] LLM-04 — Decision-to-Requirement Mapping — every ADR maps to at least one FR/NFR; no orphaned FR/NFR
- [LLM-checkable] LLM-05 — Security architecture addresses identified threats (threat-model cross-reference where present)
- [LLM-checkable] LLM-06 — Environments defined (dev, staging, prod) with progression rules explicit
- [LLM-checkable] LLM-07 — Monitoring, logging, and error-handling strategies adequate for the system scale
- [LLM-checkable] LLM-08 — Adversarial review findings properly incorporated with traceable before/after mapping

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-arch/scripts/finalize.sh
