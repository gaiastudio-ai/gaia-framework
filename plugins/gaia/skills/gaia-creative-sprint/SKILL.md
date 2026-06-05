---
name: gaia-creative-sprint
description: Multi-agent creative sprint pipeline — empathize → solve → innovate. Use when "creative sprint" or /gaia-creative-sprint. Delegates three sequential phases to design-thinking-coach (Lyra), problem-solver (Nova), and innovation-strategist (Orion), then synthesizes a unified creative brief.
argument-hint: "[creative challenge]"
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
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

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh design-thinking-coach decision-log
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh problem-solver decision-log
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh innovation-strategist decision-log

# gaia-creative-sprint

Multi-agent creative pipeline that runs a three-phase sprint: **empathize →
solve → innovate → synthesize**. Each phase delegates to a converted
subagent (Lyra, Nova, Orion) via sequential `context: fork` invocations, then
Gaia merges the three phase outputs into a unified creative brief.
Converted from the legacy `creative-sprint` workflow under the native
execution model and sequential fork-subagent pattern with full
functional parity against the legacy workflow. The legacy-source
path is intentionally omitted from the body per the parity check; see
the References section for the parity source pointer.

**Architectural parallel with `gaia-party` and
`gaia-run-all-reviews`:** all three skills are sequential
fork-subagent orchestrators. `gaia-run-all-reviews` is the fixed-sequence
reviewer chain; `gaia-party` is the dynamic-participant roundtable;
`gaia-creative-sprint` is the fixed three-phase creative pipeline. The
orchestration topology is the same (sequential, never parallel, never
reordered); only the participant set and per-step output contract differ.

## Critical Rules

- **Sequential only (AC-EC3):** Each phase builds on the previous
  phase's output. Phase 2 (Solve) refuses to start before Phase 1
  (Empathize) output is captured. Phase 3 (Innovate) refuses to start before
  Phase 2 output is captured. Never parallelize phases; never reorder. Refuse
  any `--parallel` flag or equivalent parallel-invocation request with the
  error `Parallel orchestration refused — gaia-creative-sprint is
  sequential-only.`
- **Fork-within-fork:** This skill runs under `context: fork`, and
  each phase's subagent invocation within the pipeline is **also** its own
  sequential `context: fork` subagent call — matching the same topology.
- **Halt-on-failure semantics (AC-EC1):** If a phase's subagent fails
  (crash, non-zero exit, timeout, or returns a malformed output), the
  pipeline halts. The skill MUST NOT emit a partial unified creative brief.
  Partial phase outputs may be preserved as recoverable scratch state for
  debugging, but the unified brief is only written after all three phases
  succeed.
- **Required-subagent precheck (AC-EC2):** Before Phase 1 begins, verify all
  three required subagents are installed by checking
  `plugins/gaia/agents/design-thinking-coach.md`,
  `plugins/gaia/agents/problem-solver.md`, and
  `plugins/gaia/agents/innovation-strategist.md`. If any required subagent
  is missing, fail fast with the exact message
  `required subagent '{name}' not found — install the GAIA creative agents
  before running /gaia-creative-sprint` and do not attempt later phases.
- **State-free:** This skill does not transition sprint status, update story
  frontmatter, or touch the state machine. It writes ONLY to
  `.gaia/artifacts/creative-artifacts/creative-sprint-{date}.md` (and optional
  scratch-state files for partial phase outputs).
- **Output contract preserved:** The unified brief path template
  `.gaia/artifacts/creative-artifacts/creative-sprint-{date}.md` is preserved verbatim
  from the legacy `workflow.yaml:output.primary`. Do not rename.

## Inputs

The skill begins by collecting four inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Creative challenge** — a clear problem statement describing the
   opportunity, product idea, or strategic question to explore.
2. **Constraints** — budget, timeline, technology stack, brand guidelines,
   regulatory boundaries.
3. **Success criteria** — what does a good outcome look like? How will you
   know the sprint succeeded?
4. **Audience & stakeholders** — target users, decision-makers, and any
   domain experts whose perspective matters.

If any input is missing, prompt the user before starting Phase 1.

## Pipeline

The pipeline runs four steps in strict order: **Empathize → Solve → Innovate
→ Synthesize**. Each phase has a single responsible subagent, a required
input set (derived from the prior phase's output), and a structured output
contract that the next phase consumes.

| Step | Owner | Subagent | Input | Output |
|------|-------|----------|-------|--------|
| Phase 1 — Empathize | Lyra | `design-thinking-coach` | Creative challenge + audience | Empathy map + problem definition |
| Phase 2 — Solve | Nova | `problem-solver` | Phase 1 empathy output | Ranked solution proposals |
| Phase 3 — Innovate | Orion | `innovation-strategist` | Phase 2 solutions | Innovation roadmap |
| Synthesize | Gaia (moderator) | — | Phase 1 + Phase 2 + Phase 3 outputs | Unified creative brief |

## Phase 1 — Empathize

**Subagent:** `design-thinking-coach` (Lyra).

1. Invoke the `design-thinking-coach` subagent as a `context: fork`
   subagent, passing the creative challenge, audience, and constraints as
   input.
2. Focus the subagent on the empathize and define phases of design thinking:
   user research, personas, journey maps, key pain points and opportunities.
3. Capture the subagent's structured output:
   - **Empathy map** — thinks/feels, sees, hears, says/does, pains, gains.
   - **Problem definition** — a sharpened problem statement reframed from
     the user's point of view.
   - **Key insights** — 3–5 user needs or opportunities worth pursuing.
4. Validate the output (AC-EC6): the empathy map MUST include at least one
   persona section and the problem definition MUST be non-empty. If the
   subagent returns a non-conformant / malformed output (schema violation,
   missing personas section, missing problem definition), halt the pipeline
   BEFORE Phase 2 with an actionable error
   `Phase 1 output is malformed or non-conformant — schema violation:
   {missing_field}. Pipeline halted.`
5. Write the phase output to scratch state so downstream phases can read it.

## Phase 2 — Solve

**Subagent:** `problem-solver` (Nova).

1. **Sequential gate (AC-EC3):** Refuse to start if Phase 1 output has not
   been captured in scratch state. Emit the log entry
   `Phase 2 requires Phase 1 output — Empathize phase must complete first.`
   and halt.
2. Invoke the `problem-solver` subagent as a `context: fork` subagent,
   passing Phase 1's empathy map + problem definition as input (the solve
   subagent consumes the Phase 1 output directly).
3. Apply systematic problem-solving methodologies (root cause analysis,
   TRIZ, Theory of Constraints, 5 Whys) to the defined problem.
4. Capture the subagent's structured output:
   - **Ranked solution proposals** — 3–5 candidate solutions with a
     trade-off analysis (feasibility, impact, effort).
   - **Feasibility assessment** — per-solution risk and dependency notes.
5. Write the phase output to scratch state.

## Phase 3 — Innovate

**Subagent:** `innovation-strategist` (Orion).

1. **Sequential gate:** Refuse to start if Phase 2 output has not been
   captured in scratch state (same sequential-contract enforcement as
   Phase 2).
2. Invoke the `innovation-strategist` subagent as a `context: fork`
   subagent, passing Phase 2's ranked solution proposals as input (the
   innovate subagent consumes the solve output directly).
3. Identify disruption opportunities, Jobs-to-be-Done angles, Blue Ocean
   mapping, and business-model innovations building on the ranked solutions.
4. Capture the subagent's structured output:
   - **Innovation roadmap** — prioritized initiatives with strategic fit
     notes.
   - **Competitive differentiation** — where the proposed innovations stand
     versus existing alternatives.
5. Write the phase output to scratch state.

## Synthesize

Gaia (this skill) synthesizes the three phase outputs into a single unified
creative brief. No subagent is invoked here — synthesis is deterministic
merging with attribution.

1. Load the three phase outputs from scratch state.
2. Map each proposed solution (Phase 2) back to the user needs identified
   in the empathy map (Phase 1). Every solution MUST be traceable to at
   least one empathy-phase insight.
3. Layer the innovation roadmap (Phase 3) on top of the solutions — which
   solutions are incremental, which are disruptive, which unlock new
   business models.
4. Define next steps and implementation priorities — what should the team
   do first?
5. Build the unified creative brief with these sections:
   - **Creative Challenge** — verbatim from Inputs.
   - **User Insights** — empathy map summary + personas (attributed:
     Lyra / design-thinking-coach).
   - **Solutions** — ranked proposals + feasibility (attributed:
     Nova / problem-solver).
   - **Innovations** — roadmap + strategic fit (attributed:
     Orion / innovation-strategist).
   - **Solution → Insight Map** — explicit mapping table.
   - **Implementation Priorities** — next-step list.

## Output

Write the unified creative brief to
`.gaia/artifacts/creative-artifacts/creative-sprint-{date}.md` where `{date}` is the
current date in `YYYY-MM-DD` form. This path is verbatim from the legacy
workflow's `output.primary` contract (functional parity).

### Same-day overwrite handling (AC-EC5)

If the output file already exists from a prior run on the same date:

1. **Default (safe):** Append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/creative-sprint-{date}-{N}.md` where `{N}` is
   the next available integer starting at 2. Log the disambiguation:
   `Same-day output exists — wrote to creative-sprint-{date}-{N}.md to
   avoid silent data loss.`
2. **Overwrite:** If the user explicitly requests overwrite (e.g.,
   `--overwrite` flag or confirms at prompt), overwrite the existing file
   and emit the log entry
   `Overwriting existing creative-sprint-{date}.md per user request.`

Silent overwrite is never permitted.

## Interrupt & recovery (AC-EC7)

If the user cancels the session between Phase 2 and Phase 3 (or at any
other inter-phase boundary):

- The skill MUST NOT emit a unified creative brief — synthesis requires all
  three phase outputs.
- Any captured partial phase outputs are preserved as recoverable scratch
  state so the user can resume or inspect the partial run.
- On resume, detect the scratch state and offer: (a) continue from the next
  phase using the captured prior outputs, (b) restart from Phase 1, or
  (c) discard scratch state.

## Failure semantics (AC-EC1)

If any phase subagent fails (crash, non-zero exit, timeout, or malformed
output):

- The pipeline halts at that phase. Do NOT attempt subsequent phases.
- The unified creative brief is NOT written — partial synthesis is never
  emitted (no silent data loss).
- Any already-captured phase outputs are preserved in scratch state and
  flagged as partial so downstream tools can distinguish them from a
  complete run.
- Emit an actionable error referencing the failed phase, the subagent name,
  and the captured failure message.

## Frontmatter linter compliance (AC4, AC-EC4)

This SKILL.md passes the frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required fields per the schema are present: `name` (matches directory
slug) and `description` (trigger-signature with concrete action phrase).
`allowed-tools` is validated against the canonical tool set (Agent is
required because the three phase subagents are invoked via the Agent tool).
If a future edit removes the `description` field or any other required
field, the frontmatter linter reports the missing field and the CI gate
fails — no silent skill registration is permitted.

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy six-step structure as four native
phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Sprint Briefing | `## Inputs` | Identical inputs (challenge, constraints, success criteria, audience) |
| Step 2 — Empathize | Phase 1 — Empathize | Same subagent role (Lyra); delegation via the `Agent` tool |
| Step 3 — Solve | Phase 2 — Solve | Same subagent role (Nova); sequential gate now explicit |
| Step 4 — Innovate | Phase 3 — Innovate | Same subagent role (Orion); sequential gate now explicit |
| Step 5 — Synthesize | `## Synthesize` | Deterministic merge by Gaia — no subagent call |
| Step 6 — Generate Output | `## Output` | Same output path template `creative-sprint-{date}.md` |

The data flow between phases is identical to the legacy workflow
(Phase 1 output → Phase 2 input; Phase 2 output → Phase 3 input), but
expressed as explicit sequential gates rather than implicit framework-engine
chaining. See the References section for the legacy parity source paths.

## References

- Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- Review Gate via Sequential `context: fork` Subagents (same
  sequential-fork-subagent pattern used here for the three-phase pipeline)
- Skill-to-workflow conversion mapping
- Conversion token-reduction target
- Functional parity with legacy workflow
- Reference implementations:
  - `plugins/gaia/skills/gaia-run-all-reviews/SKILL.md` (fixed-sequence
    variant of the same pattern)
  - `plugins/gaia/skills/gaia-party/SKILL.md` (dynamic-participant
    variant of the same pattern)
- Converted subagents:
  - `plugins/gaia/agents/design-thinking-coach.md` — Lyra
  - `plugins/gaia/agents/problem-solver.md` — Nova
  - `plugins/gaia/agents/innovation-strategist.md` — Orion
- Legacy parity source (for reference only; not invoked from this skill;
  legacy path intentionally omitted from the body to satisfy the
  "zero legacy references" parity check).
