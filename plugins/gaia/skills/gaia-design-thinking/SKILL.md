---
name: gaia-design-thinking
description: Guide a human-centered design session through the five-phase Stanford d.school pipeline — Empathize, Define, Ideate, Prototype, Test. Use when "run design thinking" or /gaia-design-thinking. Delegates facilitation to Lyra (design-thinking-coach) and produces a creative artifact at .gaia/artifacts/creative-artifacts/design-thinking-{date}.md.
argument-hint: "[design challenge]"
allowed-tools: [Read, Write, Glob, Agent]
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

# gaia-design-thinking

Five-phase human-centered design pipeline: **Empathize → Define → Ideate →
Prototype → Test**. Delegates each phase's facilitation to Lyra
(`design-thinking-coach`) via the Agent tool with `context: fork`, accumulates
the phase outputs in the parent skill, and writes a single artifact at
`.gaia/artifacts/creative-artifacts/design-thinking-{date}.md` at completion. Restored
with full V1 feature preservation: empathy mapping prompts, the V1 PoV
template, the design-methods CSV catalog, and the >=10 ideas mandate in
Phase 3.

## Critical Rules

- Run the five phases in strict order — never skip Empathize. Empathy is
  the foundation; everything else is built on it.
- Delegate phase facilitation to **Lyra (`design-thinking-coach`)** via the
  Agent tool with `context: fork`. Lyra reads project artifacts but does not
  write — the parent skill writes the final artifact (fork-context
  isolation).
- Single-level spawning only: this skill invokes Lyra; Lyra MUST
  NOT spawn further subagents.
- Preserve the output contract exactly:
  `.gaia/artifacts/creative-artifacts/design-thinking-{date}.md` (date as `YYYY-MM-DD`).
  Downstream skills glob on this prefix.
- Validate assumptions through real human input — never fabricate user
  insights, personas, or empathy data.
- Failure is feedback — surface findings honestly, including CRITICAL
  verdicts that halt the pipeline.

## Subagent Dispatch Contract

This skill follows the framework-wide Subagent Dispatch Contract.
When Lyra returns from a `context: fork` invocation, the parent skill MUST:

1. **Parse the subagent return** using the structured schema:
   `{ status, summary, artifacts, findings, next }`. The `status` field is
   one of `PASS`, `WARNING`, `CRITICAL`. Each entry in `findings` carries a
   `severity` field with the same vocabulary.
2. **Surface the verdict** to the user inline: display `status` and
   `summary`, then list `findings` with severity. No silent gates — the
   user sees what Lyra concluded for every phase.
3. **Halt on CRITICAL** — if `status == "CRITICAL"` or any finding has
   `severity == "CRITICAL"`, the skill HALTS with an actionable error
   message naming the offending finding(s). The user must resolve before
   the pipeline can resume; partial outputs are preserved as scratch state
   for debugging but the unified artifact is NOT written.
4. **Display WARNING** — findings with `severity == "WARNING"` are
   displayed before proceeding to the next phase. The skill does not halt
   but logs the warning to the workflow checkpoint.
5. **Log INFO** — findings with `severity == "INFO"` are logged to the
   checkpoint but not shown unless the user requests verbose output.

This contract applies to every Phase 1–5 subagent return. CRITICAL findings
from creative facilitation are unlikely in practice, but the contract is
enforced uniformly.

## YOLO Behavior

When invoked under YOLO mode, this skill obeys the framework-wide YOLO Mode
Contract:

| Behavior | YOLO action |
|----------|-------------|
| Template-output prompt (`[c]/[y]/[e]`) | Auto-continue (skip prompt). Output already saved; user chose YOLO for speed. |
| Severity / filter selection | Auto-accept default. Defaults are documented and deterministic. |
| Optional confirmation ("Proceed to next phase?") | Auto-confirm. Optional prompts exist for safety; YOLO opts out of safety pauses. |
| Subagent verdict display | Auto-display, but a CRITICAL verdict still HALTS. |
| Open-question indicators (unchecked checkboxes, `TBD`, `TODO`) | HALT — require human input. Open questions cannot be auto-answered. |
| Memory save prompt | HALT — require human input (Phase 4). Memory writes are never auto-approved. |
| Inline-ask on empty `$ARGUMENTS` | HALT — require human input. No safe default for "what design challenge?". |

The contract is identical to the canonical per-behavior lookup table.
Any future skill change that diverges from this table requires an
architecture amendment.

## Inputs

The skill begins by collecting four inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Design challenge** — the human-centered problem to explore
   (e.g., "How might we make GAIA easier for first-time users?").
2. **Audience** — who are the humans this design is for? Roles, contexts,
   relationships, prior tools they use.
3. **Constraints** — time, budget, technical, regulatory, team-size,
   organizational boundaries.
4. **Success criteria** — how will you know the design thinking session
   succeeded? What does a good outcome look like?

If `$ARGUMENTS` is empty, ask inline: "What design challenge should we
explore?". Do not fail-fast on missing inputs.

## Pipeline

| Phase | Owner | Subagent | Input | Output |
|-------|-------|----------|-------|--------|
| 1 — Empathize | Gaia + Lyra | `design-thinking-coach` | Challenge + audience | Empathy map + insights |
| 2 — Define    | Gaia + Lyra | `design-thinking-coach` | Phase 1 insights | PoV statement + How-Might-We questions |
| 3 — Ideate    | Gaia + Lyra | `design-thinking-coach` | Phase 2 HMWs + design-methods.csv | >=10 ideas, top 2-3 selected |
| 4 — Prototype | Gaia + Lyra | `design-thinking-coach` | Phase 3 selected ideas | Prototype scope + materials |
| 5 — Test      | Gaia + Lyra | `design-thinking-coach` | Phase 4 prototype | Test plan + feedback plan + iteration loop |

## Phase 1 — Empathize

**Subagent:** `design-thinking-coach` (Lyra). Lyra is invoked as a
`context: fork` subagent with the design challenge, audience, and
constraints as input.

1. **Empathy mapping** — capture what the user thinks/feels, sees, hears,
   says/does, plus pains, gains, and jobs-to-be-done. The map MUST cover
   each of these dimensions for at least one persona.
2. **Technique selection** — Lyra recommends 1–2 empathy data-gathering
   techniques from the design-methods catalog (interview, journey map,
   shadowing, diary study). The user picks one.
3. **Insight capture & synthesis** — extract the top 3–5 user needs or
   opportunity areas from the empathy data. Each insight is grounded in a
   specific empathy-map entry; abstract claims without grounding are
   rejected.
4. **Surface Lyra's verdict** per the Subagent Dispatch Contract above. If
   CRITICAL, HALT before Phase 2. If WARNING, display and proceed.
5. **Persist** the empathy map and insights to scratch state so Phase 2
   can consume them.

## Phase 2 — Define

**Subagent:** `design-thinking-coach` (Lyra). Lyra receives Phase 1
empathy map and insights as input.

1. **Point-of-View statement (V1 template):** convert the strongest
   insight into a PoV using the canonical V1 template:

   > User [type] needs [need] because [insight].

   Example: *"User: a first-time GAIA developer needs a one-screen
   onboarding tour because they currently abandon the framework before
   reaching their first successful skill invocation."*

   The template MUST be preserved exactly — `User [type] needs [need]
   because [insight]` is the V1 contract. Reframing the PoV
   without this structure is a parity regression.

2. **How-Might-We reframing:** convert the PoV into HMW (How-Might-We)
   opportunity questions. Generate **at least 3 HMW questions** — each
   must be open-ended, actionable, and oriented to the user need.
   Examples: "How might we shorten the time-to-first-skill?", "How might
   we surface progress without overwhelming a beginner?".

3. **Problem-statement convergence:** select the 1–2 HMW questions with
   the strongest fit against the audience and constraints. Document why
   the others were deferred.

4. **Surface Lyra's verdict** per the Subagent Dispatch Contract. HALT on
   CRITICAL.

5. **Persist** the PoV and selected HMW questions to scratch state.

## Phase 3 — Ideate

**Subagent:** `design-thinking-coach` (Lyra). Lyra receives the selected
HMW questions and the design-methods catalog as input.

1. **Technique selection from CSV (V1 parity):** load the design-methods
   catalog from `${CLAUDE_PLUGIN_ROOT}/knowledge/design-methods.csv`. The
   CSV columns are `method_id, name, category, phase, description,
   duration, participants`. Filter for `phase == "ideate"` and present
   2–3 candidate techniques (e.g., Crazy 8s, SCAMPER, Worst Possible
   Idea, Analogous Inspiration). The user picks one or two.

   **Missing-CSV handling:** if
   `${CLAUDE_PLUGIN_ROOT}/knowledge/design-methods.csv` is missing or
   unreadable, HALT with the actionable error: `required data file
   '${CLAUDE_PLUGIN_ROOT}/knowledge/design-methods.csv' not found — the
   design-thinking skill requires the design-methods catalog. Restore
   the CSV (canonical source: _gaia/creative/data/design-methods.csv)
   before retrying.` Do NOT fall back to a hardcoded technique list —
   silent degradation is forbidden.

2. **Idea generation (>=10 ideas mandate, V1 parity):** run the selected
   technique(s) until at least **10 ideas** are captured before any
   convergence. Quantity over quality at this stage; capture every idea
   without filtering. The minimum 10 ideas mandate is preserved verbatim
   from V1 — converging earlier is a parity regression.

3. **Convergence to top 2-3:** rank the ideas by impact × feasibility,
   then converge to the top 2–3 candidates. Document the selection
   criteria (audience fit, constraint compatibility, novelty, effort).

4. **Surface Lyra's verdict** per the Subagent Dispatch Contract. HALT on
   CRITICAL.

5. **Persist** the long list, the top 2–3, and the selection rationale
   to scratch state.

## Phase 4 — Prototype

**Subagent:** `design-thinking-coach` (Lyra). Lyra receives the top 2–3
ideas as input.

1. **Minimal scope definition:** for each candidate idea, define the
   smallest learnable artifact — what is the minimum that lets us
   validate the assumption with a real user?
2. **Materials list:** enumerate the materials, tools, and time required
   to build the prototype.
3. **Fidelity guidance:** select the appropriate fidelity level for the
   stage of the assumption being tested:
   - **Paper / sketch** — concept-level validation, fastest iteration
   - **Wireframe / clickable mock** — flow-level validation
   - **Functional prototype** — interaction-level validation
4. **Surface Lyra's verdict** per the Subagent Dispatch Contract. HALT on
   CRITICAL.
5. **Persist** the prototype scope, materials, and fidelity choice to
   scratch state.

## Phase 5 — Test

**Subagent:** `design-thinking-coach` (Lyra). Lyra receives the prototype
scope as input.

1. **Test plan + success criteria:** define what success looks like for
   the user test (specific behaviors, statements, or task completions).
   Define what failure looks like — what would cause a return to an
   earlier phase?
2. **Feedback plan + stakeholder mapping:** identify whose feedback the
   team needs (target users, internal stakeholders, domain experts) and
   how it will be captured (interview, observation, instrumentation).
3. **Iteration loop:** define which earlier phase to return to under each
   failure mode — a wrong PoV returns to Phase 2, a wrong solution
   returns to Phase 3, a flawed prototype returns to Phase 4.
4. **Surface Lyra's verdict** per the Subagent Dispatch Contract. HALT on
   CRITICAL.
5. **Persist** the test plan, feedback plan, and iteration loop to
   scratch state.

## Subagent invocation

Each phase invokes Lyra (`design-thinking-coach`) via the Agent tool with
`context: fork`. Required subagent file:
`plugins/gaia/agents/design-thinking-coach.md`.

**Missing-subagent handling:** if the subagent file is not present, fail
fast with the exact message: `required subagent
'design-thinking-coach' not found — install the GAIA creative agents
before running /gaia-design-thinking.` No fallback, no partial output.

**Single-level spawning:** Lyra is a leaf subagent — Lyra MUST
NOT spawn further subagents. The dispatch topology is two-level:
Gaia → Lyra. Any attempt to nest is rejected.

## Output

Write the final artifact to
`.gaia/artifacts/creative-artifacts/design-thinking-{date}.md` where `{date}` is the
current date in `YYYY-MM-DD` form. This path is verbatim from the legacy
workflow's `output.primary` contract.

### Same-day overwrite handling

If the output file already exists from a prior same-day run:

1. **Default (safe):** append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/design-thinking-{date}-{N}.md` where `{N}` is
   the next available integer starting at 2. Log the disambiguation:
   `Same-day output exists — wrote to design-thinking-{date}-{N}.md to
   avoid silent data loss.`
2. **Overwrite:** if the user explicitly requests overwrite (e.g.,
   `--overwrite` flag or explicit confirmation), overwrite and emit
   `Overwriting existing design-thinking-{date}.md per user request.`

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **Design Challenge** — verbatim from Inputs.
- **Audience Brief** — audience, constraints, success criteria.
- **Phase 1 — Empathize** — empathy map + insights, attributed to Lyra.
- **Phase 2 — Define** — PoV statement (V1 template) + ≥3 HMW questions
  + selected problem statement.
- **Phase 3 — Ideate** — selected technique(s) + ≥10 ideas long list +
  top 2–3 with selection rationale.
- **Phase 4 — Prototype** — scope, materials, fidelity choice.
- **Phase 5 — Test** — test plan, feedback plan, iteration loop.
- **Verdict log** — every phase's PASS/WARNING/CRITICAL verdict from
  Lyra per the Subagent Dispatch Contract.
- **Attribution** — Lyra (`design-thinking-coach`) credited as facilitator
  for all phases.

## Failure semantics

- If Lyra fails (crash, non-zero exit, timeout, malformed output, or
  CRITICAL verdict), the pipeline halts at the current phase and does
  NOT emit a partial output artifact. Captured phase outputs may be
  preserved as scratch state for debugging.
- If `${CLAUDE_PLUGIN_ROOT}/knowledge/design-methods.csv` is missing or
  unreadable, halt before Phase 3 with the actionable error above.
- If `plugins/gaia/agents/design-thinking-coach.md` is missing, halt
  before Phase 1 with the actionable error above.

## Frontmatter linter compliance

This SKILL.md passes the frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required fields per the canonical schema are present: `name` (matches the
directory slug), `description` (trigger signature with concrete action
phrase + use phrase), `argument-hint`, `context`, and `allowed-tools`.
`Agent` is in `allowed-tools` because Lyra is invoked via the Agent tool.

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy V1 five-step structure as five
native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Empathize | Phase 1 | Same empathy-map dimensions; technique selection retained |
| Step 2 — Define   | Phase 2 | V1 PoV template `User [type] needs [need] because [insight]` preserved verbatim; >=3 HMW questions retained |
| Step 3 — Ideate   | Phase 3 | design-methods CSV catalog retained at plugin-local path; >=10 ideas mandate retained |
| Step 4 — Prototype | Phase 4 | Same minimal-scope + materials + fidelity model |
| Step 5 — Test     | Phase 5 | Same test-plan + feedback-plan + iteration-loop contract |

The data flow between phases and the output artifact structure are
identical to the legacy workflow. Only the orchestration mechanism
changes: native `context: fork` Agent-tool delegation
instead of legacy engine-driven step dispatch.

## References

- Reference implementations:
  - `plugins/gaia/skills/gaia-brainstorming/SKILL.md` (single-subagent
    creative skill)
  - `plugins/gaia/skills/gaia-storytelling/SKILL.md` (single-subagent
    creative skill with CSV catalog)
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` (multi-subagent
    creative orchestrator)
- Subagent: `plugins/gaia/agents/design-thinking-coach.md` — Lyra
- Data file: `${CLAUDE_PLUGIN_ROOT}/knowledge/design-methods.csv`
  (canonical source: `_gaia/creative/data/design-methods.csv`)

## Mode B Readiness

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
