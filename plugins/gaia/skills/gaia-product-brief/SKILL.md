---
name: gaia-product-brief
description: Create a product brief through collaborative discovery — analysis skill. Use when the user wants to craft a product brief (vision, users, problem, solution, scope, risks, competitive landscape, success metrics) after an initial brainstorm or research phase.
argument-hint: "[product name or focus]"
allowed-tools: [Read, Write, Glob, Grep, Bash]
# Discover-Inputs Protocol
# Strategy: INDEX_GUIDED — load brainstorm/research artifact indexes (TOC,
# heading scan) first; fetch named sections on demand in later steps.
# Falls back to FULL_LOAD when an upstream artifact lacks parseable headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: .gaia/artifacts/creative-artifacts/
# Quality gates
# pre_start: enforced by scripts/setup.sh before Step 1 runs.
# post_complete: enforced by scripts/finalize.sh against the generated
#   product brief artifact (.gaia/artifacts/creative-artifacts/product-brief-*.md)
#   in addition to the existing 27-item checklist.
quality_gates:
  pre_start:
    - condition: "file_exists:.gaia/artifacts/creative-artifacts/brainstorm-*.md"
      error_message: "Run `/gaia-brainstorm` first to create a brainstorm artifact (or set GAIA_SKIP_BRAINSTORM=1 to seed from an existing brief / outside material)"
  post_complete:
    - condition: "section_present:Vision Statement"
      error_message: "Vision Statement section is required"
    - condition: "section_present:Target Users"
      error_message: "Target Users section is required"
    - condition: "section_present:Problem Statement"
      error_message: "Problem Statement section is required"
    - condition: "section_present:Proposed Solution"
      error_message: "Proposed Solution section is required"
    - condition: "section_present:Key Features"
      error_message: "Key Features section is required"
    - condition: "section_present:Scope and Boundaries"
      error_message: "Scope and Boundaries section is required"
    - condition: "section_present:Risks and Assumptions"
      error_message: "Risks and Assumptions section is required"
    - condition: "section_present:Competitive Landscape"
      error_message: "Competitive Landscape section is required"
    - condition: "section_present:Success Metrics"
      error_message: "Success Metrics section is required"
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-product-brief/scripts/setup.sh

## Mission

You are facilitating a collaborative discovery session to produce a product brief. Guide the user through vision, target users, problem statement, proposed solution, scope, risks, competitive landscape, and success metrics, then emit a structured product brief artifact at `.gaia/artifacts/creative-artifacts/product-brief-*.md` for downstream consumers (e.g., `/gaia-create-prd`).

**Agent:** `analyst` (Elena) — the analyst subagent facilitates discovery and drafts the brief sections. Persona definition lives at `${CLAUDE_PLUGIN_ROOT}/agents/analyst.md`; do not duplicate the persona content here.

**Template:** `${CLAUDE_PLUGIN_ROOT}/templates/product-brief-template.md` — structural source for the 9 required sections. The template's H2 headings are the post_complete gate targets and must not be renamed.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/create-product-brief` workflow. The step ordering, prompts, and output location follow the legacy `instructions.xml` mechanically — do not restructure, re-prompt, or reorder sections.

## Critical Rules

- All sections must be collaboratively developed with the user — do not invent vision, users, or metrics.
- Ground every claim in upstream artifacts (brainstorm, market research, domain research, technical research) when available; otherwise elicit from the user.
- The output file path is `.gaia/artifacts/creative-artifacts/product-brief-{slug}.md` — downstream consumers glob on this pattern, so do not relocate it.
- Mechanical port: the eight legacy steps below must appear in this exact order.

## Steps

### Step 1 — Discover Inputs

> **Loading strategy: INDEX_GUIDED.** This skill uses the
> INDEX_GUIDED input-loading strategy for the **brainstorm artifact** —
> the artifact's heading index is loaded first, and individual sections
> are fetched only when a later step needs them. Brainstorm transcripts
> commonly run 10K+ tokens, so full-loading them up front would burn the
> context budget the collaborative discovery session needs for the
> Vision / Target Users / Problem / Solution prompts.
>
> **Narrow scope.** INDEX_GUIDED applies
> specifically to the brainstorm artifact. Market research, domain
> research, and technical research outputs are typically smaller
> (often under 20 KB) and may still use FULL_LOAD without busting the
> token budget — choose FULL_LOAD for those files when the index/TOC
> overhead is not worth it.
>
> **Mechanics.** For an INDEX_GUIDED read, scan headings with
> `grep -nE '^#{1,3} '` (or read `index.md` if present), summarise the
> section list, and fetch named sections on demand later
> (`sed -n '/^## Section/,/^## /p'`). If an artifact has no parseable
> headings, fall back to FULL_LOAD for that file only and log the
> fallback in the checkpoint — the runtime heuristic MUST NOT halt or
> error on a small or unstructured file.

- Scan prior brainstorm output if available (heading scan over `.gaia/artifacts/creative-artifacts/brainstorm-*.md`).
- Scan market research if available (heading scan over `.gaia/artifacts/creative-artifacts/market-research*.md`).
- Scan domain research if available (heading scan over `.gaia/artifacts/creative-artifacts/domain-research*.md`).
- Scan technical research if available (heading scan over `.gaia/artifacts/creative-artifacts/tech-research*.md`).
- Scan any other creative outputs under `.gaia/artifacts/creative-artifacts/` for relevant indexes.
- Summarize what upstream context was found (section list, not full content) and flag any missing inputs to the user before proceeding.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 1 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 2 — Vision Statement

- Collaboratively craft the vision statement with the user.
- Incorporate insights from prior analysis if available.
- Elena (analyst) asks the user: **"What is the core vision for this product?"** — wait for a response before moving on.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 2 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 3 — Target Users

- Define user personas based on research.
- For each persona capture: name, role, goals, pain points, context.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 3 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 4 — Problem Statement

- Articulate the core problem being solved.
- Ground the statement in user research, market findings, and domain landscape where available.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 4 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 5 — Proposed Solution

- Define the high-level solution approach.
- Capture key features and differentiators.
- Reference technical research for technology selection rationale if available.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 5 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 6 — Scope, Risks and Competitive Landscape

- Define what is in-scope for this product and what is explicitly out of scope.
- Document known risks, dependencies, and assumptions the solution depends on.
- Summarize competitive landscape from upstream brainstorm and market research — key competitors, positioning, and differentiation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 6 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 7 — Success Metrics

- Define measurable KPIs and success criteria.
- Include both quantitative and qualitative metrics.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 7 product_name="$PRODUCT_NAME" target_user="$TARGET_USER"`

### Step 8 — Generate Output

Use the template at `${CLAUDE_PLUGIN_ROOT}/templates/product-brief-template.md` as the structural source for the 9 required sections. Do not invent alternate section headings — they are the exact post_complete gate targets enforced by `scripts/finalize.sh` against `.gaia/artifacts/creative-artifacts/product-brief-*.md`.

Write a structured product brief to `.gaia/artifacts/creative-artifacts/product-brief-{slug}.md` containing the exact sections below, in order:

- **Vision Statement** — core product vision
- **Target Users** — user personas (name, role, goals, pain points, context for each)
- **Problem Statement** — core problem being solved, grounded in research
- **Proposed Solution** — high-level solution approach
- **Key Features** — feature list with differentiators
- **Scope and Boundaries** — what is in-scope and what is explicitly out of scope
- **Risks and Assumptions** — known risks, dependencies, and assumptions
- **Competitive Landscape** — summary of competitive positioning from upstream research
- **Success Metrics** — measurable KPIs and success criteria
- **Next Steps** — per `${CLAUDE_PLUGIN_ROOT}/knowledge/lifecycle-sequence.yaml` (routing table ships inside the plugin under the `knowledge/` convention; the legacy v1 location `_gaia/_config/lifecycle-sequence.yaml` is retired and no longer used)

Where `{slug}` is a short kebab-case slug derived from the product vision (e.g., `product-brief-ai-code-review.md`).

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/creative-artifacts/product-brief-${SLUG}.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 8 product_name="$PRODUCT_NAME" target_user="$TARGET_USER" --paths .gaia/artifacts/creative-artifacts/product-brief-${SLUG}.md`

### Step 9 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/creative-artifacts/product-brief-{slug}.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/creative-artifacts/product-brief-{slug}.md`, `artifact_type = product-brief`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/creative-artifacts/product-brief-{slug}.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Val auto-review per the canonical pattern. The `product-brief` artifact_type uses Val's factual-claim validation against ground-truth plus the document-ruleset for product briefs.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-product-brief 9 product_name="$PRODUCT_NAME" target_user="$TARGET_USER" stage=val-auto-review --paths .gaia/artifacts/creative-artifacts/product-brief-${SLUG}.md`

## Validation

<!--
  V1→V2 27-item checklist port.
  Classification (27 items total):
    - Script-verifiable: 18 (SV-01..SV-18) — enforced by finalize.sh.
    - LLM-checkable:      9 (LLM-01..LLM-09) — evaluated by the host LLM
      against the product-brief artifact at finalize time.
  Exit code 0 when all 18 script-verifiable items PASS; non-zero otherwise.

  The 9 required product-brief sections form the spine of the script-verifiable
  subset (SV-04..SV-12). SV-01..SV-03 guard artifact existence, non-empty
  body, and top-level title/frontmatter. SV-13..SV-18 are deeper presence
  checks — Vision body non-empty, ≥1 persona, ≥1 key feature, scope
  carries both in-scope and out-of-scope wording, ≥1 competitor, and
  Success Metrics contains at least one measurable numeric signal
  (percent, currency, duration, NPS). These defend against the most
  common V2-regression: a required heading present but the body left
  empty.

  LLM-checkable items (LLM-01..LLM-09) cover semantic judgement that
  bash cannot reliably assess — coherence, plausibility, rationale,
  credibility, differentiation, measurability, and scope discipline.

  Invoked by `finalize.sh` at post-complete.
-->

- [script-verifiable] SV-01 — Output artifact exists at .gaia/artifacts/creative-artifacts/product-brief-*.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Vision Statement section present
- [script-verifiable] SV-05 — Target Users section present
- [script-verifiable] SV-06 — Problem Statement section present
- [script-verifiable] SV-07 — Proposed Solution section present
- [script-verifiable] SV-08 — Key Features section present
- [script-verifiable] SV-09 — Scope and Boundaries section present
- [script-verifiable] SV-10 — Risks and Assumptions section present
- [script-verifiable] SV-11 — Competitive Landscape section present
- [script-verifiable] SV-12 — Success Metrics section present
- [script-verifiable] SV-13 — Vision Statement body non-empty
- [script-verifiable] SV-14 — At least one persona listed in Target Users
- [script-verifiable] SV-15 — Key Features list non-empty
- [script-verifiable] SV-16 — Scope and Boundaries documents both in-scope and out-of-scope
- [script-verifiable] SV-17 — At least one competitor listed in Competitive Landscape
- [script-verifiable] SV-18 — Success Metrics contain measurable values
- [LLM-checkable] LLM-01 — Vision statement is coherent and aspirational
- [LLM-checkable] LLM-02 — Target user personas are plausible and grounded in research
- [LLM-checkable] LLM-03 — Problem statement is grounded in user/market research findings
- [LLM-checkable] LLM-04 — Proposed solution addresses the stated problem
- [LLM-checkable] LLM-05 — Key features are prioritised with rationale
- [LLM-checkable] LLM-06 — Risks are credible and assumptions are testable
- [LLM-checkable] LLM-07 — Competitive landscape differentiation is clear
- [LLM-checkable] LLM-08 — Success metrics are measurable and attributable to the product
- [LLM-checkable] LLM-09 — Scope boundaries are defensible against feature creep

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-product-brief/scripts/finalize.sh

## Next Steps

- Primary: `/gaia-create-prd` — expand the brief into a full Product Requirements Document.
- Alternative: `/gaia-market-research` — if competitive landscape needs deeper validation before the PRD.
- Alternative: `/gaia-domain-research` — if domain context is still thin.

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

This skill is Mode B-ready. Under the team-orchestration mode, the authoring work that the prose above describes as inline subagent dispatch is instead routed through the shared planning bridge library at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/planning-mode-b-bridge.sh`, which itself layers on the shared dispatch library `${CLAUDE_PLUGIN_ROOT}/scripts/lib/dispatch-teammate.sh`.

- **Spawn seam.** The analyst subagent (Elena) facilitates discovery and drafts the brief sections. The orchestration calls `planning_spawn_subagent gaia:analyst "gaia-product-brief"` to obtain a persistent teammate handle. The clean-room gate in the shared library refuses any reviewer persona before a teammate is created.
- **Relay seam.** Each authoring turn is relayed verbatim to the team lead via `planning_relay_turn <handle> <payload>`, so the produced artifact structure is identical to the Mode A subagent-dispatch path — only the dispatch seam differs, never the authored output.
- **Shutdown seam.** At skill exit the orchestration calls `planning_shutdown`, which delegates to `shutdown_all` so no teammate pane is left orphaned.
- **Honest fallback.** Live Mode B is not exercisable in every Claude Code context. When the substrate is absent the bridge degrades to the existing Mode A foreground dispatch and emits a single `MODE_B_FALLBACK` token to stderr; the Mode A behaviour documented above remains the source of truth.
