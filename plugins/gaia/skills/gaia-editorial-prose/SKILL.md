---
name: gaia-editorial-prose
description: Clinical copy-editing review — flags ambiguity, inconsistency, redundancy, jargon, passive voice, sentence complexity, and tone shifts in a document. Produces a markdown findings report with per-finding severity (critical / major / minor / style), specific line reference, and a suggested fix. Use when "review prose" or /gaia-editorial-prose.
argument-hint: "[target — document path]"
allowed-tools: [Read, Grep]
orchestration_class: reviewer
---

## Mission

You are performing a **clinical copy-editing review** on the document the user supplies. You evaluate the target across seven prose dimensions — ambiguity, inconsistency, redundancy, jargon, passive voice, sentence complexity, and tone shifts — and produce a markdown findings report. Every finding names a specific line (or section) in the source, classifies severity (critical / major / minor / style), and offers a concrete fix the author can accept or reject.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/editorial-review-prose.xml` task (42 lines). Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model (skills + subagents + plugins + hooks).

## Critical Rules

- **Review only — never rewrite the document.** The skill is strictly read-only on the target. Findings go in the report; the author decides which to apply.
- **Flag issues with specific line references and suggested fixes.** Every finding cites a line number (or section heading + offset) and includes a concrete fix suggestion — not vague "this could be clearer" observations.
- **Categorize every finding by severity:** `critical` (meaning-breaking), `major` (likely misread), `minor` (stylistic improvement), `style` (preference).
- **Prose-only scope.** Section reordering, TOC restructuring, hierarchy changes, and information-architecture issues are **out of scope** — route the author to `/gaia-editorial-structure`. If you notice structural issues during the prose pass, record them in a separate "Structural observations" note at the end of the report (see the Structural observations are awareness-only rule below) but do NOT expand them into findings.
- **Structural observations are awareness-only.** Any structural issues you surface in the "Structural observations" note are informational signals, not a substitute for a structural pass. They exist so the author knows a structural review may be warranted — they do not replace one. `/gaia-editorial-structure` is the canonical full structural-pass skill; recommend it whenever a structural observation appears, and let the author run that skill separately for the actual structural review.
- Do NOT modify the source document. The report artifact is the only output.

## Inputs

- `$ARGUMENTS`: optional target document path. If omitted, ask the user inline: "Which document should I review for prose quality?"

## Instructions

### Step 1 — Load Document

- If `$ARGUMENTS` is non-empty, use it as the target path. Otherwise ask the user inline for the document to review.
- Read the entire document with the Read tool.
- Note the document type (PRD, story, architecture, README, changelog, etc.) — type informs what reads as acceptable jargon vs. out-of-place jargon.

### Step 2 — Analyze Prose

Scan the document across these seven categories (the full set inherited from the legacy task):

- **Ambiguity** — vague terms, unclear referents ("this", "that", "it" with no antecedent), multiple interpretations of a single sentence.
- **Inconsistency** — the same term used with different meanings, or different terms used for the same concept, across the document.
- **Redundancy** — information repeated without new value, verbose phrases that can be shortened.
- **Jargon** — unexplained technical terms, acronyms introduced without definition, vocabulary that assumes domain knowledge the audience does not have.
- **Passive voice** — places where active voice would be clearer and attribute agency more cleanly.
- **Sentence complexity** — sentences over ~40 words, nested clauses three-deep or more, instructions buried inside compound-complex structures.
- **Tone shifts** — inconsistent voice or formality level (e.g., shifting between first-person and third-person, between casual and formal, between imperative and passive instruction).

### Step 3 — Generate Report

Produce a markdown findings report with this structure:

1. **Executive summary** — one paragraph naming the overall readability verdict and the top two or three thematic issues.
2. **Findings table** — columns: severity, location (line or section), issue, suggested fix. One row per finding.
3. **Overall readability score** — one of: `Clear` / `Mostly Clear` / `Needs Work` / `Major Issues`.

The report is the only output artifact. It is displayed to the user. If the user asks the skill to save the report to disk, write it with the Read tool's companion writer — but the default is display-only to mirror the legacy task's behavior.

## Output Behaviour

- **Default: display-only.** Running `/gaia-editorial-prose` produces a markdown findings report rendered inline in the conversation. The skill does **not** write the report to disk by default. Nothing under `docs/`, `gaia-framework/`, or `_memory/` is created or modified by a default invocation.
- **Save on explicit request.** If the user asks for a persisted artifact ("save this report to `docs/…`", "write the findings to a file"), the skill saves the report to the path the user specifies. Saving is opt-in, never automatic.
- **Rationale.** Editorial review output is **feedback, not an artifact replacement**. The author owns the source document and decides which findings to apply; persisting the review by default would imply the report is itself an artifact of record, which it is not. The display-only default keeps the review lightweight and aligns with the editorial review-feedback convention shared with `/gaia-editorial-structure`.

### Structural observations are awareness-only

The optional "Structural observations" note that may appear at the end of the report is an **awareness-only** signal. The observations are informational — they alert the author that a structural pass may be warranted — and are **not** a substitute for one. `/gaia-editorial-structure` is the **canonical full structural-pass skill**: when structural observations surface, recommend that the author invoke `/gaia-editorial-structure` separately to get an actual structural review.

## References

- Source: `_gaia/core/tasks/editorial-review-prose.xml` (legacy 42-line task body — ported per ADR-041 + ADR-042).
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists with this skill until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- NFR-053: Full v1.127.2-rc.1 Feature Parity.

## Related

- `/gaia-editorial-structure` — structural / information-architecture review. Use this sibling skill for hierarchy, ordering, and reorganization concerns; this skill (prose) deliberately stays out of that scope.
