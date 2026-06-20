---
name: gaia-create-arch
description: Design system architecture through collaborative discovery with the architect subagent (Theo). Use when the user wants to produce a validated architecture document from an existing PRD, covering technology selection, system components, data architecture, API design, infrastructure, security architecture, and architecture decision records.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
# Discover-Inputs Protocol
# Strategy: INDEX_GUIDED — the PRD is typically 20K+ tokens. Load the PRD
# index (heading scan or §N.x table of contents) first; fetch named
# sections on demand in later steps. Falls back to FULL_LOAD when the PRD
# lacks parseable headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: .gaia/artifacts/planning-artifacts/prd.md
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

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-arch/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all

## Brain Context

!${CLAUDE_PLUGIN_ROOT}/scripts/brain/brain-reliance-loader.sh gaia-create-arch:discover-inputs

## Mission

You are orchestrating the creation of a System Architecture document. The architecture authoring is delegated to the **architect** subagent (Theo), who conducts technology selection, designs system components, and produces the final artifact. You load the PRD, validate inputs, coordinate the multi-step flow, and write the output to the canonical path `.gaia/artifacts/planning-artifacts/architecture.md` using the carried `architecture-template.md` template structure.

**Path resolution.** All architecture path references in this SKILL.md use the canonical location `.gaia/artifacts/planning-artifacts/architecture.md`. Legacy projects continue to work via a positive-evidence-legacy fallback at the script layer (`scripts/finalize.sh` three-tier idiom: `ARCHITECTURE_ARTIFACT` env-var override → legacy `docs/planning-artifacts/architecture.md` only when that file exists AND `.gaia/artifacts/planning-artifacts/` does NOT → canonical default). When writing the architecture document via the Write tool, target the canonical path; the legacy fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/create-architecture` workflow. The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST exist before starting. Resolve via the sharded-fallback rule: first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). If NEITHER exists, fail fast with "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- The PRD MUST contain a "## Review Findings Incorporated" section. If missing, fail fast with "PRD review findings not found — run /gaia-create-prd to complete adversarial review and PRD refinement."
- Every significant technical decision must be recorded as an ADR inline in the Decision Log table of the architecture document.
- Architecture authoring is delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation — do NOT inline Theo's persona into this skill body. If the architect subagent is not available, fail with "architect subagent not available" error.
- If `.gaia/artifacts/planning-artifacts/architecture.md` already exists, warn the user: "An existing architecture document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Template resolution: load `architecture-template.md` from this skill directory. If `custom/templates/architecture-template.md` exists and is non-empty, use the custom template instead — the custom template takes full precedence over the framework default.
- ADRs live inline in the architecture document's Decision Log table — there is no separate ADR directory. Preserve the legacy workflow's ADR placement convention.
- Every technical decision must connect to business value.
- **Checkpoints + Step 10–13 handoff in subagent dispatch.** The per-step `write-checkpoint.sh` calls below are ADVISORY in subagent/YOLO dispatch: when Theo runs the steps inline inside a dispatched subagent, per-step checkpoints and lifecycle-event emission may not fire from the subagent context, so resumption support is best-effort, not guaranteed. This is expected, not a defect — do not treat a missing mid-run checkpoint as a failure. The orchestrator/subagent split is: the SUBAGENT authors Steps 1–9 (the architecture document) and returns; the ORCHESTRATOR (main turn) owns Steps 10–13 (Val review, API design review, adversarial review, finalize) via main-turn Agent dispatch. The subagent's clean handoff point is "exit after Step 9 with the drafted architecture.md"; it does NOT run the Step 10–13 review gates itself.

## Steps

### Step 1 — Load Upstream Artifacts

> **Loading strategy: INDEX_GUIDED.** The PRD is routinely
> 20K+ tokens — full-loading it here burns the context budget before
> architecture authoring even begins. Heading-scan `prd.md` first (e.g.,
> `grep -nE '^#{1,3} ' .gaia/artifacts/planning-artifacts/prd.md`) to build a section
> index. Fetch §N.x bodies on demand in later steps (`sed -n` between
> heading anchors). If the PRD has no parseable headings, fall back to
> FULL_LOAD and log the fallback in the checkpoint.

- Resolve the PRD path via the sharded-fallback rule (Critical Rules above). Heading-scan the resolved PRD to build a section index of requirements (functional and non-functional); for the sharded layout, also heading-scan shard subsections under `prd/04-functional-requirements/` and `prd/05-non-functional-requirements.md`. Do NOT read the full bodies up front.
- GATE: verify prd.md contains a "## Review Findings Incorporated" section. If missing, HALT — run /gaia-create-prd first to complete adversarial review and PRD refinement.
- Heading-scan `.gaia/artifacts/planning-artifacts/ux-design.md` if available — record section anchors for UI requirements.
- Check for brownfield artifacts: `.gaia/artifacts/planning-artifacts/brownfield-assessment.md` and `.gaia/artifacts/planning-artifacts/project-documentation.md`. If either exists, heading-scan them — these contain existing codebase analysis that must inform architecture decisions even if the PRD is not in brownfield mode.
- Check for `.gaia/artifacts/planning-artifacts/threat-model.md`. If it exists, heading-scan it — identified threats and mitigations must inform the security architecture in Step 7. Section bodies are loaded on demand by later steps.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 1 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION"`

### Step 2 — Detect Mode

- Check `.gaia/artifacts/planning-artifacts/prd.md` header for "Mode: Brownfield".
- If brownfield mode detected: set mode to brownfield. Use brownfield architecture template.
- If no brownfield header: set mode to greenfield. Load `architecture-template.md` from this skill directory. If `custom/templates/architecture-template.md` exists and is non-empty, use the custom template instead.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 2 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" arch_mode="$ARCH_MODE"`

### Step 3 — Technology Selection

Delegate to the **architect** subagent (Theo) via `agents/architect` to select the technology stack.

- Greenfield: select tech stack with rationale for each choice. Consider: team expertise, scalability needs, ecosystem maturity.
- Brownfield: discover existing tech stack from project-documentation.md and code scan. Mark ADR status as "Existing" for discovered decisions.
- If brownfield artifacts were loaded in Step 1: reference the existing tech stack, constraints, and integration points when evaluating technology choices.
- Record decision as ADR in the architecture document's Decision Log table.
- Present recommended technology stack to the user for confirmation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 3 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=technology-selection`

### Step 3.5 — Tech-Stack Confirmation Pause

> **Parity restoration.** This sub-step
> restores the V1 tech-stack confirmation gate that was dropped during the
> Claude Code native migration. It MUST fire after Step 3 returns and
> BEFORE Step 4 begins. Step 4..N are NOT renumbered — Step 3.5 is a
> deliberate non-integer slot so that downstream cross-references in
> `epics-and-stories.md`, `test-plan.md`, and
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
     Write NO `.gaia/artifacts/planning-artifacts/architecture.md` file. Write NO
     sidecar entry. The session ends cleanly with the abort status surfaced
     to the caller.

> **YOLO / non-interactive mode (deliberate concession).** When the skill
> runs in YOLO or any other non-interactive mode where no human input can
> be solicited, the pause MUST still fire and emit an audit entry. The
> degraded behavior is: set `confirmed_tech_stack` to Theo's recommendation
> unchanged, append the audit entry "YOLO auto-accepted tech stack (no user
> pause)" to the in-session ADR-sidecar buffer, and proceed to Step 4. This
> is a documented product decision — a hard pause in
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

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 4 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=system-architecture`

### Step 5 — Data Architecture

Delegate to the **architect** subagent (Theo) via `agents/architect` to design data architecture.

- Design database schema and data model.
- Define data flow between components.
- Specify data storage, caching, and replication strategies.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 5 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=data-architecture`

### Step 6 — API Design

Delegate to the **architect** subagent (Theo) via `agents/architect` to design APIs.

- Define API endpoint overview.
- Specify authentication and authorization strategy.
- Document API versioning approach.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 6 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=api-design`

### Step 7 — Infrastructure and Cross-Cutting Concerns

Delegate to the **architect** subagent (Theo) via `agents/architect` to define infrastructure.

- Define deployment topology and environments (dev, staging, prod).
- Specify hosting, containerization, and orchestration choices.
- Define monitoring and logging strategy.
- Define security architecture: if threat-model.md was loaded, cross-reference identified threats and map each critical/high threat to an architectural mitigation. If no threat model exists, prompt user for key security requirements.
- Brownfield: document security architecture, cross-cutting concerns with current state and gaps. Define migration strategy. Cross-reference api-documentation.md, event-catalog.md, dependency-map.md in the Integration Architecture section.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 7 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" section_slug=infra-and-cross-cutting`

### Step 8 — Architecture Decision Records

Delegate to the **architect** subagent (Theo) via `agents/architect` to compile ADRs.

- Review all decisions made in Steps 3-7.
- Ensure each significant decision is recorded as ADR with: Title, Date, Status, Context, Decision, Alternatives Considered, Consequences, Addresses (FR/NFR IDs).
- Brownfield: mark existing decisions as status "Existing", new gap-related decisions as "Proposed".
- Generate a "Decision to Requirement Mapping" table mapping each ADR to the FR/NFR IDs it addresses. Flag any FR/NFR from the PRD with no corresponding ADR as a coverage gap.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 8 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" adr_count="$ADR_COUNT"`

### Step 9 — Generate Output

- Write the architecture document to `.gaia/artifacts/planning-artifacts/architecture.md` using the `architecture-template.md` section structure.
- Greenfield: include technology stack, system architecture, data architecture, API design, infrastructure plan, ADR references, and Decision-to-Requirement Mapping table.
- Brownfield: include C4 diagrams, sequence diagrams, data flow diagram, as-is/target delta table, migration strategy, and cross-references.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/architecture.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 9 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" --paths .gaia/artifacts/planning-artifacts/architecture.md`

### Step 10 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard: if not exists `.gaia/artifacts/planning-artifacts/architecture.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard: if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/architecture.md`, `artifact_type = architecture`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/architecture.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Validation runs against the Step 9 primary write (artifact-as-drafted). Step 13's post-adversarial re-write does NOT trigger a second Val invocation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 10 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/architecture.md`

### Step 11 — Optional: API Design Review

- Ask user: "Would you like to review the API design against REST standards? Recommended if your architecture includes APIs. (yes / skip)"
- If yes: invoke the API design review task.
- If skip: API review can be run anytime later with /gaia-review-api.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 11 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" api_review_run="$API_REVIEW_RUN"`

### Step 12 — Adversarial Review

- Read `${CLAUDE_PLUGIN_ROOT}/knowledge/adversarial-triggers.yaml` to evaluate trigger rules for `change_type` + artifact "architecture". Determine the current `change_type`: if invoked with a change_type context, use that value; otherwise default to "feature".
- If adversarial review is triggered: dispatch the **`adversarial-reviewer`** subagent (Sage) via the Agent tool to critique `.gaia/artifacts/planning-artifacts/architecture.md`. **Before dispatching, run `mkdir -p .gaia/artifacts/planning-artifacts/adversarial/`** so the nested directory exists on first run. The dispatch prompt MUST specify (a) the artifact path to review and (b) the report output path `.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-architecture-{YYYY-MM-DD}.md` (use today's UTC date). Sage's persona at `plugins/gaia/agents/adversarial-reviewer.md` defines the review structure, severity vocabulary, and architecture-specific review lenses.
- When the subagent returns: verify `adversarial-review-architecture-*.md` exists in `.gaia/artifacts/planning-artifacts/adversarial/`. Display the returned review envelope (status + summary + findings) to the user.
- If not triggered: add "## Review Findings Incorporated" section noting the review was not triggered.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 12 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" adversarial_triggered="$ADVERSARIAL_TRIGGERED"`

### Step 13 — Incorporate Adversarial Findings

- Read adversarial review findings.
- For each critical/high finding: update the architecture — add missing components, revise decisions, strengthen security/scalability, update ADRs.
- Add a "## Review Findings Incorporated" section to the architecture document listing each finding, its severity, and how it was addressed.
- Write the final architecture document.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/architecture.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-arch 13 project_name="$PROJECT_NAME" arch_version="$ARCH_VERSION" --paths .gaia/artifacts/planning-artifacts/architecture.md .gaia/memory/architect-sidecar/architecture-decisions.md`

#### Append Architecture Decisions to Sidecar

> **Run order — strict.** This action runs ONLY AFTER the architecture
> document write succeeds in Step 13. If the architecture write failed,
> skip the sidecar write entirely — the inline Decision Log in
> `architecture.md` is the primary artifact, and a sidecar without a
> matching architecture document is worse than no sidecar.

> **Sidecar path — fixed.** Write to
> `.gaia/memory/architect-sidecar/architecture-decisions.md`. This path is
> not configurable via `global.yaml`. Do NOT relocate it under `custom/` or
> under `_gaia/`.

**Steps:**

1. Build the in-session decisions list from (a) every row appended to
   the architecture.md `§ Decision Log` table during Steps 3–13, and
   (b) every audit entry buffered by Step 3.5 (accept / modify /
   reject / YOLO auto-accept).
2. If `.gaia/memory/architect-sidecar/architecture-decisions.md` does NOT
   exist, create it with the canonical header:

   ```markdown
   # Architect — Architecture Decisions

   > Sidecar log of architecture decisions. Mirrors the inline Decision Log in architecture.md.

   ---
   ```

3. Build a session header for this run in the form
   `### Session {YYYY-MM-DD} — {feature_or_scope_label}`, using the
   project name + Step 1 scope label. This header groups all entries
   from a single `/gaia-create-arch` invocation.
4. **Append-only safety.** Read the existing sidecar before
   writing. If a session header with the same date AND
   `feature_or_scope_label` already exists, append ONLY the new ADR
   entries under that header (dedup key = ADR ID — never write the
   same ADR ID twice within one session header). If no matching
   header exists, append a NEW session header block at the end of the
   file. **Never overwrite, mutate, or reorder an existing entry.**
5. Emit one canonically-formatted entry per decision under the session
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

#### Hydrate project-config.yaml

> **Run order — strict.** Runs ONLY AFTER the architecture document
> write in Step 13 has succeeded and the sidecar append above has
> completed. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh`,
> then build two `mktemp` YAML fragment files from `confirmed_tech_stack`
> (Step 3.5 canonical variable) — one with `stacks:` payload, one with
> `platforms:` payload — and call `config_hydrate_section stacks <file>`
> followed by `config_hydrate_section platforms <file>` (the helper's
> second arg is a file path, not a literal string). `rm -f`
> both fragment files after the calls return.

> **Idempotency contract.** When `config_phase` is already
> `partial` or `full` in `.gaia/config/project-config.yaml`, both calls are
> safe no-ops — the helper short-circuits the write and the file is
> byte-unchanged. When `config_phase` is `minimal`, the helper writes
> the section and advances `config_phase` to `partial` monotonically.
> The helper NEVER writes `config_phase: full` — that transition is
> reserved for `validate-project-config.sh`.

> **Non-blocking error policy.** Capture `$?` from each call. The helper
> already logs `config-hydration: WARN/CRITICAL ...` to stderr for any
> failure (rc=0 ok, rc=1 generic, rc=2 allowlist, rc=3 lock timeout); a
> non-zero rc does NOT HALT the workflow — `architecture.md` has already
> been written and is the primary artifact. Same policy as the sidecar
> write above. The hydration trigger is purely a SKILL.md finalize-step
> addition; no architect subagent or template changes.

## Validation

<!--
  V1→V2 33-item checklist port.
  Classification (33 items total):
    - Script-verifiable: 25 (SV-01..SV-25) — enforced by finalize.sh.
    - LLM-checkable:      8 (LLM-01..LLM-08) — evaluated by the host LLM
      against the architecture artifact at finalize time.
  Exit code 0 when all 25 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at _gaia/lifecycle/workflows/3-solutioning/create-architecture/
  checklist.md carried 17 bulleted items. The 33-item count is
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

  The SV-21 anchor is "Decisions recorded". This is the
  V1 phrase verbatim and MUST appear in violation output when the
  Decision Log table is heading-only.

  Per-item LLM-checkable timeout contract: 30s wall-clock per item.
  Malformed verdict (no explicit PASS/FAIL) is treated as
  FAIL — never skip.

  Invoked by `finalize.sh` at post-complete. Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome).
-->

- [script-verifiable] SV-01 — Output file exists at .gaia/artifacts/planning-artifacts/architecture.md
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

## Mode B Readiness

This skill is Mode B-ready. Under the team-orchestration mode, the authoring work that the prose above describes as inline subagent dispatch is instead routed through the shared planning bridge library at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/planning-mode-b-bridge.sh`, which itself layers on the shared dispatch library `${CLAUDE_PLUGIN_ROOT}/scripts/lib/dispatch-teammate.sh`.

- **Spawn seam.** The architect subagent (Theo) authors the architecture sections. The orchestration calls `planning_spawn_subagent gaia:architect "gaia-create-arch"` to obtain a persistent teammate handle. The clean-room gate in the shared library refuses any reviewer persona before a teammate is created.
- **Relay seam.** Each authoring turn is relayed verbatim to the team lead via `planning_relay_turn <handle> <payload>`, so the produced artifact structure is identical to the Mode A subagent-dispatch path — only the dispatch seam differs, never the authored output.
- **Shutdown seam.** At skill exit the orchestration calls `planning_shutdown`, which delegates to `shutdown_all` so no teammate pane is left orphaned.
- **Honest fallback.** Live Mode B is not exercisable in every Claude Code context. When the substrate is absent the bridge degrades to the existing Mode A foreground dispatch and emits a single `MODE_B_FALLBACK` token to stderr; the Mode A behaviour documented above remains the source of truth.
