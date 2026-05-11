---
name: gaia-advanced-elicitation
description: Deep requirements elicitation using structured questioning techniques — Cluster 4 analysis skill. Use when the user wants to explore requirements gaps, validate assumptions, and discover unstated needs using methods like 5 Whys, Socratic Method, User Story Mapping, MoSCoW, Kano Model, Jobs-to-be-Done, Assumption Mapping, and Stakeholder Mapping.
argument-hint: "[product or feature area to explore]"
allowed-tools: [Read, Write, Glob, Grep, Bash]
orchestration_class: heavy-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-advanced-elicitation/scripts/setup.sh

## Mission

You are facilitating a deep requirements elicitation session. Guide the user through context gathering, method selection, structured elicitation execution, and requirements synthesis, then emit a structured elicitation report at `docs/planning-artifacts/elicitation-report-{date}.md` for downstream consumers (e.g., `/gaia-create-prd`).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/advanced-elicitation` workflow (brief §Cluster 4, story P4-S4). The step ordering, prompts, and output location follow the legacy `instructions.xml` mechanically — do not restructure, re-prompt, or reorder sections.

## Critical Rules

- Use structured questioning techniques from the methods table below.
- Document all requirements discovered with clear traceability.
- Distinguish between stated needs, implied needs, and assumed needs.
- The output file path is `docs/planning-artifacts/elicitation-report-{date}.md` — downstream consumers read this exact path pattern, so do not relocate it.
- Mechanical port: the five legacy steps below must appear in this exact order.

## Elicitation Methods

| Method | Description | Best For | Question Count |
|--------|-------------|----------|---------------|
| 5 Whys | Ask 'why' repeatedly to find root cause | Understanding motivations and root problems | 5 |
| Socratic Method | Guided questioning to challenge assumptions | Validating requirements and uncovering gaps | 8 |
| User Story Mapping | Map user journey end-to-end | Understanding workflows and user needs | 10 |
| MoSCoW Prioritization | Must/Should/Could/Won't classification | Prioritizing features and requirements | 6 |
| Kano Model | Categorize features by satisfaction impact | Feature prioritization and delight factors | 8 |
| Jobs-to-be-Done | What job is the user hiring this product for | Understanding true user motivations | 7 |
| Assumption Mapping | List and validate all assumptions | Risk identification and validation planning | 6 |
| Stakeholder Mapping | Identify all stakeholders and their needs | Ensuring comprehensive requirements coverage | 5 |

## Steps

### Step 1 — Context Gathering

- Load upstream research artifacts if available: `project-brainstorm.md`, `market-research.md`, `domain-research.md`, `technical-research.md`.
- Summarize what upstream context was found — present key themes, target users, market insights, and technical constraints already discovered.

Ask the user, in order, and wait for a response on each:

- **"Based on the research so far, what product or feature area do you want to explore deeper? (Or describe from scratch if no prior research exists)"**
- **"Who are the key stakeholders?"**
- **"Are there specific requirements gaps or assumptions from the research that you want to validate?"**

> `!scripts/write-checkpoint.sh gaia-advanced-elicitation 1 elicitation_topic="$ELICITATION_TOPIC" technique="$TECHNIQUE"`

### Step 2 — Method Selection

- Present the available elicitation methods from the table above with their descriptions and best-fit scenarios.

Ask the user:

- **"Which elicitation method(s) would you like to use? (or let me recommend based on your context)"**

- If user defers: recommend 2-3 methods based on the project context.

> `!scripts/write-checkpoint.sh gaia-advanced-elicitation 2 elicitation_topic="$ELICITATION_TOPIC" technique="$TECHNIQUE"`

### Step 3 — Elicitation Execution

For each selected method, execute the structured questioning flow:

- **5 Whys:** Ask "why" iteratively to uncover root motivations.
- **Socratic Method:** Challenge assumptions through guided questions.
- **User Story Mapping:** Walk through the user journey end-to-end.
- **MoSCoW:** Classify each requirement as Must/Should/Could/Won't.
- **Kano Model:** Categorize features by satisfaction impact.
- **Jobs-to-be-Done:** Identify the core job the user is hiring the product for.
- **Assumption Mapping:** List and validate all project assumptions.
- **Stakeholder Mapping:** Identify all stakeholders and their needs.

Document all requirements discovered during each method.

> `!scripts/write-checkpoint.sh gaia-advanced-elicitation 3 elicitation_topic="$ELICITATION_TOPIC" technique="$TECHNIQUE"`

### Step 4 — Requirements Synthesis

- Consolidate all discovered requirements across methods.
- Remove duplicates and resolve conflicts.
- Categorize as: functional, non-functional, constraint, assumption.
- Tag each requirement with source method and confidence level.
- Identify gaps where further elicitation is needed.

> `!scripts/write-checkpoint.sh gaia-advanced-elicitation 4 elicitation_topic="$ELICITATION_TOPIC" technique="$TECHNIQUE"`

### Step 5 — Generate Output

Write a structured elicitation report to `docs/planning-artifacts/elicitation-report-{date}.md` containing, in order:

- **Context Summary** — upstream research themes and stakeholder context
- **Methods Used** — which elicitation techniques were applied and why
- **Discovered Requirements** — categorized as functional, non-functional, constraint, assumption; each tagged with source method and confidence level
- **Assumptions Log** — all assumptions identified, with validation status
- **Gaps Identified** — areas where further elicitation is needed
- **Recommended Next Steps** — suggested follow-up actions

[Source: _gaia/lifecycle/workflows/1-analysis/advanced-elicitation/instructions.xml]
[Source: _gaia/lifecycle/workflows/1-analysis/advanced-elicitation/workflow.yaml]

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/elicitation-report-${DATE}.md`

> `!scripts/write-checkpoint.sh gaia-advanced-elicitation 5 elicitation_topic="$ELICITATION_TOPIC" technique="$TECHNIQUE" --paths docs/planning-artifacts/elicitation-report-${DATE}.md`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-advanced-elicitation/scripts/finalize.sh

## Next Steps

- Primary: `/gaia-create-prd` — create a Product Requirements Document from elicited requirements.
- Alternative: `/gaia-product-brief` — if a product brief is needed first.
