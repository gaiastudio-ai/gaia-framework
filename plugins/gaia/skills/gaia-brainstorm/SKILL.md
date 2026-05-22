---
name: gaia-brainstorm
description: Brainstorm a new project idea with structured techniques — Cluster 4 analysis skill. Use when the user wants to explore a business idea, target users, pain points, and opportunity areas before writing a PRD.
argument-hint: "[project idea or topic]"
allowed-tools: [Read, Write, Glob, Grep, Bash]
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

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-brainstorm/scripts/setup.sh

## Mission

You are facilitating a structured brainstorming session for a new project idea. Guide the user through vision, target users, competitive landscape, and opportunity synthesis, then emit a structured brainstorm artifact at `.gaia/artifacts/creative-artifacts/brainstorm-*.md` for downstream consumers (e.g., `/gaia-create-prd`).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/brainstorm-project` workflow (brief §Cluster 4, story P4-S1). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure or re-prompt.

## Critical Rules

- Check `.gaia/artifacts/creative-artifacts/` for prior brainstorming output before starting.
- All findings must be grounded in user-provided information — no web access, no fabrication.
- The output file path is `.gaia/artifacts/creative-artifacts/brainstorm-{slug}.md` — downstream consumers glob on this pattern, so do not relocate it.

## Steps

### Step 1 — Discover Context

- Check `.gaia/artifacts/creative-artifacts/` for prior brainstorming output from the creative module.
- If found, load and incorporate insights into the session.
- If not found, note that no prior creative work exists and proceed.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 1 slug="$SLUG" technique="$TECHNIQUE"`

### Step 2 — Elicit Project Vision

Ask the user the following questions, one at a time, and wait for a response before moving to the next:

1. What is the business idea or problem you want to explore?
2. Who are the target users?
3. What pain points does this address?
4. What makes this different from existing solutions?

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 2 slug="$SLUG" technique="$TECHNIQUE"`

### Step 3 — Competitive Landscape

- Based on user-provided information, analyze the competitive landscape.
- No web access — use user-provided info and general knowledge only.
- Identify direct and indirect competitors.
- Map competitive positioning.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 3 slug="$SLUG" technique="$TECHNIQUE"`

### Step 4 — Opportunity Synthesis

- Synthesize findings into 3–5 opportunity areas.
- For each opportunity: describe it, estimate impact, note evidence.
- Rank opportunities by potential impact and feasibility.
- Collect all ideas explored during the session that did not make the top opportunity list into a **Parking Lot** — for each, note the idea, why it was deprioritized, and under what conditions it might become viable.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 4 slug="$SLUG" technique="$TECHNIQUE"`

### Step 5 — Generate Output

Write a structured brainstorm artifact to `.gaia/artifacts/creative-artifacts/brainstorm-{slug}.md` containing:

- Vision summary
- Target users
- Pain points
- Competitive landscape
- Opportunity areas (ranked)
- Parking Lot (deprioritized ideas with reasoning and revival conditions)
- Next steps (see the static `## Next Steps` section at the end of this skill — primary successor is `/gaia-product-brief`)

Where `{slug}` is a short kebab-case slug derived from the project vision (e.g., `brainstorm-ai-code-review.md`).

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/creative-artifacts/brainstorm-${SLUG}.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 5 slug="$SLUG" technique="$TECHNIQUE" --paths .gaia/artifacts/creative-artifacts/brainstorm-${SLUG}.md`

### Step 6 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/creative-artifacts/brainstorm-{slug}.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/creative-artifacts/brainstorm-{slug}.md`, `artifact_type = brainstorm`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/creative-artifacts/brainstorm-{slug}.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations` by invoking the producer (E44-S15):
        ```
        !${CLAUDE_PLUGIN_ROOT}/scripts/append-val-iteration.sh \
            --skill gaia-brainstorm --step 6 --iteration "$ITER" \
            --token-estimate "$TOKEN_ESTIMATE" \
            --revalidation-outcome findings_present \
            --findings-json "$FINDINGS_JSON" \
            --fix-summary "$FIX_SUMMARY"
        ```
        Where `$TOKEN_ESTIMATE` is the SDK-reported response usage token count for the iteration's Val invocation + fix payload (preferred), or the literal `null` when the runtime token-counting primitive is unavailable (AC-EC8 fallback). The producer writes a fresh ADR-059 schema-v1 checkpoint with the merged `val_loop_iterations` array — `scripts/measure-val-auto-fix-token-budget.sh` reads `token_estimate` directly from this stream for the NFR-VCP-2 verdict.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). The `brainstorm` artifact_type may not have a canonical document-ruleset; per E44-S1 AC-EC1 Val skips structural validation for unknown types and still runs factual-claim validation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-brainstorm 6 slug="$SLUG" technique="$TECHNIQUE" stage=val-auto-review --paths .gaia/artifacts/creative-artifacts/brainstorm-${SLUG}.md`

## Validation

<!--
  E42-S1 — V1→V2 24-item checklist port (FR-341, FR-359).
  Classification (24 items total):
    - Script-verifiable: 15 (SV-01..SV-15) — enforced by finalize.sh.
    - LLM-checkable:      9 (LLM-01..LLM-09) — evaluated by the host LLM
      against the brainstorm artifact below.
  Exit code 0 when all script-verifiable items PASS; non-zero otherwise.
  See .gaia/artifacts/implementation-artifacts/E42-S1-port-gaia-brainstorm-checklist.md.
-->

- [script-verifiable] SV-01 — Output artifact exists at .gaia/artifacts/creative-artifacts/brainstorm-*.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Output filename matches brainstorm-{slug}.md pattern
- [script-verifiable] SV-04 — Vision Summary section present
- [script-verifiable] SV-05 — Target Users section present
- [script-verifiable] SV-06 — Pain Points section present
- [script-verifiable] SV-07 — Differentiators section present
- [script-verifiable] SV-08 — Competitive Landscape section present
- [script-verifiable] SV-09 — Opportunity Areas section present
- [script-verifiable] SV-10 — At least 3 opportunity areas identified
- [script-verifiable] SV-11 — Parking Lot section present
- [script-verifiable] SV-12 — Next Steps section present
- [script-verifiable] SV-13 — Creative-artifacts/ checked for prior outputs
- [script-verifiable] SV-14 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-15 — Opportunities listed as a structured list
- [LLM-checkable] LLM-01 — Business idea clearly articulated
- [LLM-checkable] LLM-02 — Target users well-defined
- [LLM-checkable] LLM-03 — Pain points specific and grounded in user information
- [LLM-checkable] LLM-04 — Differentiators stated clearly vs competitors
- [LLM-checkable] LLM-05 — Direct and indirect competitors identified
- [LLM-checkable] LLM-06 — Competitive positioning mapped
- [LLM-checkable] LLM-07 — Each opportunity has supporting evidence
- [LLM-checkable] LLM-08 — Opportunities ranked by impact and feasibility
- [LLM-checkable] LLM-09 — Parking-lot entries include deprioritization reasoning and revival conditions

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-brainstorm/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-product-brief` — convert the brainstorm into a structured product brief.
- **Alternative:** `/gaia-market-research` — validate the competitive landscape before briefing.
- **Alternative:** `/gaia-domain-research` — when domain-specific research is needed first.
- **Alternative:** `/gaia-tech-research` — when technology evaluation must precede the brief.
