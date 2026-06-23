---
name: gaia-tech-research
description: Research a technology or tech stack with objective trade-off analysis. Use when the user wants to evaluate technologies, compare alternatives, and get adoption recommendations before architecture decisions.
argument-hint: "[technology or tech stack to research]"
allowed-tools: [Read, Write, Glob, Grep, Bash, WebSearch, WebFetch]
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-research/scripts/setup.sh

## Mission

You are conducting a technical research session. Guide the user through technology scoping, evaluation, and trade-off analysis, then emit a structured technical research report at `.gaia/artifacts/planning-artifacts/technical-research.md` for downstream consumers (e.g., `/gaia-product-brief`, `/gaia-create-arch`).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/technical-research` workflow. The step ordering, prompts, and output location follow the legacy `instructions.xml` mechanically — do not restructure, re-prompt, or reorder sections.

## Critical Rules

- Check web access availability before proceeding with research.
- If no web access, proceed with user-provided data and general knowledge only.
- Provide objective trade-off analysis, not technology advocacy.
- The output file path is `.gaia/artifacts/planning-artifacts/technical-research.md` — downstream consumers read this exact path, so do not relocate it.
- Mechanical port: the five legacy steps below must appear in this exact order.

## Steps

### Step 1 — Technology Scoping

Ask the user, in order, and wait for a response on each:

- **"What technologies or tech stack do you want to research?"**
- **"What is the use case or problem context?"**
- **"Are there constraints (team expertise, budget, timeline)?"**

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 1 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA"`

### Step 2 — Web Access Check

- Check if MCP web tools are available for live research.
- If web access is available, proceed with live web research in subsequent steps.
- If no web access, notify the user: *"Web access unavailable. Proceeding with user-provided data and general knowledge. Results may be less comprehensive."*

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 2 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA"`

### Step 3 — Technology Evaluation

- Assess each technology for: maturity, community size, learning curve, licensing.
- Evaluate ecosystem: libraries, tools, IDE support, documentation quality.
- Check production readiness: stability, performance characteristics, scalability.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 3 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA"`

### Step 4 — Trade-off Analysis

- Create pros/cons matrix for each technology option.
- Compare alternatives across key dimensions.
- Provide recommendation with clear rationale.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 4 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA"`

### Step 5 — Generate Output

Write a structured technical research report to `.gaia/artifacts/planning-artifacts/technical-research.md` containing, in order:

- **Technology Overview** — summary of each evaluated technology
- **Evaluation Matrix** — maturity, community, learning curve, licensing, ecosystem, production readiness
- **Trade-off Analysis** — pros/cons matrix and cross-dimensional comparison
- **Recommendation** — recommended technology with clear rationale
- **Migration / Adoption Considerations** — timeline, team ramp-up, risk factors

[Source: _gaia/lifecycle/workflows/1-analysis/technical-research/instructions.xml]
[Source: _gaia/lifecycle/workflows/1-analysis/technical-research/workflow.yaml]

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/technical-research.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 5 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA" --paths .gaia/artifacts/planning-artifacts/technical-research.md`

### Step 6 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/technical-research.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/technical-research.md`, `artifact_type = technical-research`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/technical-research.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Val auto-review. The `technical-research` artifact_type matches the on-disk filename `technical-research.md` (slug-filename symmetry). It may not have a canonical document-ruleset; Val skips structural validation for unknown types and still runs factual-claim validation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-tech-research 6 technology="$TECHNOLOGY" evaluation_criteria="$EVALUATION_CRITERIA" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/technical-research.md`

## Validation

<!--
  V1→V2 22-item checklist port.
  Classification (22 items total):
    - Script-verifiable: 13 (SV-01..SV-13) — enforced by finalize.sh.
    - LLM-checkable:      9 (LLM-01..LLM-09) — evaluated by the host LLM
      against the technical-research artifact below.
  Exit code 0 when all script-verifiable items PASS; non-zero otherwise.
  Dedup / expand rule applied to the V1 surface (2 validation-rules +
  11 checkboxes = 13 V1 items, expanded to 22 as follows):
    - "At least 2 alternatives compared" (V1 validation-rule) becomes
      SV-12 — backed by the alternatives_count helper
      in finalize.sh.
    - "Trade-off analysis included" (V1 validation-rule) splits into
      section-present (SV-09 ## Trade-off Analysis) and matrix-populated
      (SV-13 pros/cons matrix included) so an empty heading cannot
      spoof a PASS.
    - V1 Scope (Technologies / Use case / Constraints) maps 1:1 to
      SV-04, SV-05, SV-06.
    - V1 Evaluation (Maturity / Community / Licensing) is reclassified
      as LLM-checkable (LLM-02, LLM-03, LLM-04) because assessing
      accuracy requires semantic judgement, not keyword matching.
    - V1 Trade-offs (Pros/cons matrix / Alternatives compared /
      Recommendation rationale) split: matrix presence → SV-13,
      alternatives count → SV-12, rationale quality → LLM-06.
    - V1 Output Verification ("All required sections present") expands
      into one check per V2 Step 5 required section — Technology
      Overview (SV-07), Evaluation Matrix (SV-08), Trade-off Analysis
      (SV-09), Recommendation (SV-10), Migration/Adoption (SV-11) —
      so each section fails independently rather than as a single
      binary.
    - Web Access checkboxes from V1 fold into LLM-08 (semantic check
      on the limitation wording).
    - Observability items (non-empty artifact, frontmatter/title)
      surface as SV-02 and SV-03 so automated infrastructure can catch
      empty or malformed outputs before humans review them.
-->

- [script-verifiable] SV-01 — Output artifact exists at .gaia/artifacts/planning-artifacts/technical-research.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Technologies clearly identified
- [script-verifiable] SV-05 — Use case context provided
- [script-verifiable] SV-06 — Constraints documented
- [script-verifiable] SV-07 — Technology Overview section present
- [script-verifiable] SV-08 — Evaluation Matrix section present
- [script-verifiable] SV-09 — Trade-off Analysis section present
- [script-verifiable] SV-10 — Recommendation section present
- [script-verifiable] SV-11 — Migration / Adoption Considerations section present
- [script-verifiable] SV-12 — At least 2 alternatives compared
- [script-verifiable] SV-13 — Pros/cons matrix included
- [LLM-checkable] LLM-01 — Trade-off analysis explores meaningful dimensions, not advocacy
- [LLM-checkable] LLM-02 — Maturity assessment reflects real signals (release cadence, stability)
- [LLM-checkable] LLM-03 — Community and ecosystem evaluation grounded in evidence
- [LLM-checkable] LLM-04 — Licensing analysis accurate for the intended deployment model
- [LLM-checkable] LLM-05 — Alternatives compared across dimensions that matter for this use case
- [LLM-checkable] LLM-06 — Recommendation rationale follows from the trade-off analysis
- [LLM-checkable] LLM-07 — Migration / adoption considerations account for team ramp-up and timeline
- [LLM-checkable] LLM-08 — Web access availability and limitations noted if web access unavailable
- [LLM-checkable] LLM-09 — Risk factors acknowledged and tied to the recommendation

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-tech-research/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-create-arch` — feed the tech trade-off analysis into the architecture design step.
- **Alternative:** `/gaia-product-brief` — when consolidating all research into a brief precedes architecture.
- **Alternative:** `/gaia-advanced-elicitation` — when deeper requirements exploration is still needed.

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

This skill is ready to run under Mode B (persistent teammates). When the team
lead routes this skill through Mode B, the tech-research subagent (gaia:analyst) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:analyst" "gaia-tech-research"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
