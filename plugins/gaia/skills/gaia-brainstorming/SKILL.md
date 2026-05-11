---
name: gaia-brainstorming
description: Facilitated brainstorming session using diverse creative techniques. Use when the user wants to run a structured ideation session (mind mapping, SCAMPER, six thinking hats, etc.) with ranked output.
argument-hint: "[brainstorming topic]"
context: fork
allowed-tools: [Read, Write, Glob]
orchestration_class: conversational
---

# gaia-brainstorming

Facilitated creative ideation session: **Session Setup → Technique Selection →
Technique Execution → Idea Organization**. Produces a ranked, categorized
artifact at `docs/creative-artifacts/brainstorming-{date}.md`. Converted under
ADR-041 with full parity against `_gaia/core/workflows/brainstorming/`
(NFR-053).

## Critical Rules

- Run the four phases in order — never skip Session Setup or Idea Organization.
- Delegate facilitation to **Rex (`brainstorming-coach`)** via the Agent tool
  when `plugins/gaia/agents/brainstorming-coach.md` is available. If the
  subagent is unavailable or not registered, facilitate inline — do not halt.
- Preserve the output path exactly: `docs/creative-artifacts/brainstorming-{date}.md`
  (date as `YYYY-MM-DD`). Downstream skills glob on this prefix.
- Use `brainstorming-template.md` for the output structure.
- During execution: quantity over quality — capture every idea without filtering.

## Session Setup

Ask these five questions in order:

1. **Topic** — what the user wants to brainstorm about.
2. **Scope** — broad exploration or a focused problem.
3. **Constraints** — time, budget, technical, team size.
4. **Output format** — list, ranked, categorized, action plan.
5. **Session tone** — wild ideas welcome vs. practical solutions only.

## Technique Selection

Recommend 2–3 techniques from the table below with a one-line rationale each,
let the user choose, then explain how the selected technique works.

| Technique | Best For | Description |
|-----------|----------|-------------|
| Mind Mapping | Exploring a broad topic | Start with a central concept, branch out |
| SCAMPER | Improving existing ideas | Substitute, Combine, Adapt, Modify, Put to other use, Eliminate, Reverse |
| Reverse Brainstorming | Finding hidden problems | "How could we make this fail?" then invert |
| Six Thinking Hats | Balanced perspective | Examine from 6 angles: facts, emotions, caution, benefits, creativity, process |
| Brainwriting | Rapid idea generation | Generate ideas silently, build on others |
| Worst Possible Idea | Breaking creative blocks | Start with terrible ideas, find the good in them |
| SWOT | Strategic analysis | Strengths, Weaknesses, Opportunities, Threats |
| How Might We | Reframing problems | Convert problems into opportunity statements |

## Technique Execution

Run the selected technique round by round:

1. Generate **5–10 ideas per round** using the technique's methodology.
2. Present the ideas to the user and build on their reactions.
3. Capture every idea — no filtering.
4. Run multiple selected techniques sequentially.
5. Target **15–30 total ideas** before moving to organization.

## Idea Organization

1. Group ideas into **3–5 thematic categories**.
2. Rank each by **Impact** (High/Med/Low) and **Feasibility** (High/Med/Low) and
   a combined score.
3. Identify the **top 3–5 ideas** overall. For each: one-sentence summary, why
   it's valuable, first concrete next step.
4. Render the artifact from `brainstorming-template.md` and write it to
   `docs/creative-artifacts/brainstorming-{date}.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/creative-artifacts/brainstorming-${DATE}.md`

5. Report the output path and suggest `/gaia-market-research`,
   `/gaia-domain-research`, or `/gaia-tech-research` as follow-ups.
