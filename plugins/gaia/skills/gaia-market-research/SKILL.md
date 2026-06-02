---
name: gaia-market-research
description: Conduct market research on competition and customers — Cluster 4 analysis skill. Use when the user wants to analyze competitors, define customer segments, and size a market (TAM/SAM/SOM) before or during product discovery.
argument-hint: "[market or industry focus]"
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

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-market-research/scripts/setup.sh

## Mission

You are facilitating a market research session. Guide the user through scope definition, competitive analysis, customer research, and market sizing (TAM/SAM/SOM), then emit a structured market research report at `.gaia/artifacts/planning-artifacts/market-research.md` for downstream consumers (e.g., `/gaia-domain-research`, `/gaia-product-brief`).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/market-research` workflow (brief §Cluster 4, story P4-S3). The step ordering, prompts, and output location follow the legacy `instructions.xml` mechanically — do not restructure, re-prompt, or reorder sections.

## Critical Rules

- Check web access availability before proceeding with research.
- If no web access, proceed with user-provided data and general knowledge only.
- State all market sizing assumptions clearly.
- The output file path is `.gaia/artifacts/planning-artifacts/market-research.md` — downstream consumers read this exact path, so do not relocate it.
- Mechanical port: the six legacy steps below must appear in this exact order.

## Steps

### Step 1 — Scope Definition

Ask the user, in order, and wait for a response on each:

- **"What market or industry do you want to research?"**
- **"Are there specific competitors you want analyzed?"**
- **"What geographic scope? (global, regional, local)"**

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 1 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET"`

### Step 2 — Web Access Check

- Check if MCP web tools are available for live research.
- If web access is available, proceed with live web research in subsequent steps.
- If no web access, notify the user: *"Web access unavailable. Proceeding with user-provided data and general knowledge. Results may be less comprehensive."*

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 2 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET"`

### Step 3 — Competitive Analysis

- Identify and analyze competitors (direct and indirect).
- For each competitor capture: strengths, weaknesses, market position, pricing model.
- Create a competitive positioning matrix.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 3 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET"`

### Step 4 — Customer Research

- Define target customer segments.
- Analyze user behavior patterns and needs.
- Identify underserved needs and market gaps.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 4 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET"`

### Step 5 — Market Sizing

- Estimate Total Addressable Market (TAM).
- Estimate Serviceable Addressable Market (SAM).
- Estimate Serviceable Obtainable Market (SOM).
- State all assumptions clearly.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 5 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET"`

### Step 6 — Generate Output

Write a structured market research report to `.gaia/artifacts/planning-artifacts/market-research.md` containing, in order:

- **Executive Summary**
- **Competitive Analysis** — direct and indirect competitors with strengths, weaknesses, market position, pricing model, and a competitive positioning matrix
- **Customer Segments** — target segments, behavior patterns, needs, and market gaps
- **Market Sizing** — TAM, SAM, SOM with all assumptions stated
- **Key Findings**
- **Strategic Recommendations**

[Source: _gaia/lifecycle/workflows/1-analysis/market-research/instructions.xml]
[Source: _gaia/lifecycle/workflows/1-analysis/market-research/workflow.yaml]

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/market-research.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 6 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET" --paths .gaia/artifacts/planning-artifacts/market-research.md`

### Step 7 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/market-research.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/market-research.md`, `artifact_type = market-research`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/market-research.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). The `market-research` artifact_type may not have a canonical document-ruleset; per E44-S1 AC-EC1 Val skips structural validation for unknown types and still runs factual-claim validation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-market-research 7 research_topic="$RESEARCH_TOPIC" competitor_set="$COMPETITOR_SET" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/market-research.md`

## Validation

<!--
  E42-S2 — V1→V2 28-item checklist port (FR-341, FR-359).
  Classification (28 items total):
    - Script-verifiable: 18 (SV-01..SV-18) — enforced by finalize.sh.
    - LLM-checkable:     10 (LLM-01..LLM-10) — evaluated by the host LLM
      against the market-research artifact below.
  Exit code 0 when all script-verifiable items PASS; non-zero otherwise.
  Dedup rule applied to V1 surface (2 rules + 15 checkboxes = 17 lines):
    - "At least 3 competitors analyzed" rule == Competition checkbox (1 item).
    - "TAM/SAM/SOM estimates provided with assumptions" rule collapses
      into the three Market Sizing dimension checkboxes (6 items after
      estimate+assumptions split).
  After dedup V1 yields 15 distinct items; expansion to 28 splits
  TAM/SAM/SOM into estimate+assumptions (+3 net), treats each of the 4
  required output sections as a separate item (+3 net vs. "all required
  sections present"), and adds an Executive Summary / Key Findings /
  Strategic Recommendations section check to mirror the V2 Step 6 output
  contract. See .gaia/artifacts/implementation-artifacts/E42-S2-port-gaia-market-research-28-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output artifact exists at .gaia/artifacts/planning-artifacts/market-research.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Market/industry clearly defined
- [script-verifiable] SV-05 — Geographic scope stated
- [script-verifiable] SV-06 — Executive Summary section present
- [script-verifiable] SV-07 — Competitive Analysis section present
- [script-verifiable] SV-08 — Customer Segments section present
- [script-verifiable] SV-09 — Market Sizing section present
- [script-verifiable] SV-10 — Key Findings section present
- [script-verifiable] SV-11 — Strategic Recommendations section present
- [script-verifiable] SV-12 — At least 3 competitors analyzed
- [script-verifiable] SV-13 — Competitive positioning matrix included
- [script-verifiable] SV-14 — TAM estimate provided with assumptions
- [script-verifiable] SV-15 — SAM estimate provided with assumptions
- [script-verifiable] SV-16 — SOM estimate provided with assumptions
- [script-verifiable] SV-17 — Web access guard / availability noted
- [script-verifiable] SV-18 — Limitation noted in output if web access unavailable
- [LLM-checkable] LLM-01 — Target customer segments defined with evidence
- [LLM-checkable] LLM-02 — User behavior patterns identified
- [LLM-checkable] LLM-03 — Underserved customer needs highlighted
- [LLM-checkable] LLM-04 — Strengths clearly articulated for each competitor
- [LLM-checkable] LLM-05 — Weaknesses clearly articulated for each competitor
- [LLM-checkable] LLM-06 — Competitive positioning mapped clearly
- [LLM-checkable] LLM-07 — TAM assumptions clearly justified
- [LLM-checkable] LLM-08 — SAM assumptions clearly justified
- [LLM-checkable] LLM-09 — SOM assumptions clearly justified
- [LLM-checkable] LLM-10 — Strategic recommendations actionable and grounded

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-market-research/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-product-brief` — consolidate market findings into a structured product brief.
- **Alternative:** `/gaia-domain-research` — when domain or industry depth is still needed.
- **Alternative:** `/gaia-tech-research` — when technology evaluation must run before the brief.
