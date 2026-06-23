---
name: gaia-brainstorming
description: Facilitated brainstorming session using diverse creative techniques. Use when the user wants to run a structured ideation session (mind mapping, SCAMPER, six thinking hats, etc.) with ranked output.
argument-hint: "[brainstorming topic]"
allowed-tools: [Read, Write, Glob]
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

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

# gaia-brainstorming

Facilitated creative ideation session: **Session Setup → Technique Selection →
Technique Execution → Idea Organization**. Produces a ranked, categorized
artifact at `.gaia/artifacts/creative-artifacts/brainstorming-{date}.md`. Converted
with full parity against `_gaia/core/workflows/brainstorming/`.

## Critical Rules

- Run the four phases in order — never skip Session Setup or Idea Organization.
- Delegate facilitation to **Rex (`brainstorming-coach`)** via the Agent tool
  when `plugins/gaia/agents/brainstorming-coach.md` is available. If the
  subagent is unavailable or not registered, facilitate inline — do not halt.
- Preserve the output path exactly: `.gaia/artifacts/creative-artifacts/brainstorming-{date}.md`
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
   `.gaia/artifacts/creative-artifacts/brainstorming-{date}.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/creative-artifacts/brainstorming-${DATE}.md`

5. Report the output path and suggest `/gaia-market-research`,
   `/gaia-domain-research`, or `/gaia-tech-research` as follow-ups.

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

This conversational skill is Mode B-ready. Under Mode B (opt-in: persistent
teammates), participant dispatch routes through the shared dispatch library
at `scripts/lib/dispatch-teammate.sh` via the conversational bridge at
`scripts/lib/conversational-mode-b-bridge.sh`. Each participant is spawned
with `conversational_spawn_participant`, which obtains a long-lived teammate
handle, enforces the reviewer clean-room invariant, and logs dispatch
provenance. Turn output is relayed verbatim to the session transcript, so the
artifact structure (transcript and synthesis) is byte-for-byte the same as
Mode A.

When the Mode B substrate is absent — the default in this build — the shared
library degrades to Mode A foreground dispatch and emits a single
machine-parseable `MODE_B_FALLBACK` token to stderr. Existing Mode A behavior
is preserved unchanged; Mode B is attempted only when the substrate is live.

**Shutdown discipline.** Every spawned participant MUST be cleaned up at skill
completion. Wire `trap conversational_shutdown EXIT` around the participant
loop; `conversational_shutdown` delegates to `shutdown_all` in the shared
library, which sweeps every active teammate and leaves no orphaned session.
