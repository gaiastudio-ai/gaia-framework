---
name: gaia-storytelling
description: Craft a compelling narrative using story frameworks and emotional design. Use when the user asks to "craft a story", write a narrative, or build emotional copy around a product/idea. Delegates narrative construction to Elara (storyteller), picks a framework from the story-types catalog, and produces a ranked, polished narrative artifact.
argument-hint: "[story topic or core message]"
allowed-tools: [Read, Write, Glob, Agent]
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

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh storyteller decision-log

# gaia-storytelling

Narrative craft pipeline: **Audience and Purpose → Framework Selection →
Story Construction → Emotional Beats → Polish and Present**. Produces a
polished story artifact at `.gaia/artifacts/creative-artifacts/story-{date}.md`.
Converted under the native execution model with full functional
parity against the legacy source. The legacy-source path is
intentionally omitted from the body per the "zero legacy
references" parity check; see the References section for the parity
source pointer.

## Critical Rules

- Every story must have a transformation arc — the protagonist must
  change state (belief, situation, capability) between the opening and
  the resolution. A static story is never acceptable.
- Find the authentic story — never fabricate emotional beats, never
  invent metrics, never use research or quotes that cannot be
  attributed.
- Test the 3-second hook rule before finalizing — the opening must grab
  attention instantly. If a reader needs more than three seconds to
  understand why they should keep reading, rewrite the hook.
- Run the five phases in order — never skip Audience and Purpose (the
  one-core-message anchor) and never skip Polish and Present (the
  3-second hook + read-aloud test).
- Delegate narrative construction to **Elara (`storyteller`)** via the
  Agent tool when `plugins/gaia/agents/storyteller.md` is registered.
  If the subagent is unavailable, facilitate inline — do not halt.
- Preserve the output contract exactly:
  `.gaia/artifacts/creative-artifacts/story-{date}.md` (date as `YYYY-MM-DD`).
  Downstream skills glob on this prefix — do not rename.

## Inputs

The skill begins by collecting four inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Target audience** — who is this story for? What do they already
   know, believe, or fear?
2. **Desired feeling** — what should the audience feel after hearing
   the story? (hope, urgency, belonging, curiosity, resolve)
3. **Desired action** — what action should they take after? (book a
   demo, change a practice, share the idea, fund the project)
4. **Core message** — if the audience remembers only ONE thing, what
   is it? Narrow it to a single sentence before proceeding.

If any input is missing, prompt the user before entering Framework
Selection.

## Pipeline

The pipeline runs five phases in strict order. Each phase has a clear
entry and exit condition and captures output that feeds the next phase.

| Phase | Responsibility | Input | Output |
|-------|----------------|-------|--------|
| 1. Audience and Purpose | Gaia | User inputs | Core-message anchor, audience brief |
| 2. Framework Selection | Gaia + Elara | Core-message + audience | Selected framework (Hero's Journey / Problem-Solution / BAB / etc.) |
| 3. Story Construction | Elara (`storyteller`) | Framework + core message | Narrative arc (hook, rising tension, climax, resolution) |
| 4. Emotional Beats | Elara (`storyteller`) | Narrative arc | Emotional journey map (surprise, tension, relief, resolution) |
| 5. Polish and Present | Gaia | Emotional arc | Final story artifact |

## Phase 1 — Audience and Purpose

Anchor the story in a single core message before any drafting begins.

1. **Define the target audience** — who are they, what do they care
   about, what do they already believe, what would surprise them?
2. **Define the desired feeling** — what emotional state should the
   audience occupy at the resolution?
3. **Define the desired action** — what should they do next?
4. **Capture the one core message** — write it in a single sentence.
   This sentence is the north star for every phase that follows.
5. **Record** the audience brief and core message so Elara can receive
   them as context in Phase 2.

Do not proceed without a one-sentence core message. Multiple messages
mean the story is unfocused — narrow first.

## Phase 2 — Framework Selection

Pick the narrative framework that best fits the core message and
audience.

1. **Load the story-types catalog** from `{data_path}/story-types.csv`.
   This CSV lists each framework's name, best-fit scenarios, structural
   beats, and example use cases. The `{data_path}` template is resolved
   at skill-invocation time by the foundation path-resolution script
   (matches the legacy `{data_path}` resolution mechanism).
2. **Present framework options** to the user based on the audience +
   purpose fit. Typical candidates include:
   - **Hero's Journey** — protagonist-led transformation, rich for
     founder stories and product origin narratives.
   - **Problem–Solution** — compact, evidence-first structure for
     B2B / investor / technical audiences.
   - **Before–After–Bridge** — concise persuasive arc for landing pages
     and marketing copy.
   - **Story of Self / Us / Now** — mission-driven narratives for
     movements and community organizing.
   - **The Pixar Formula** — "Once upon a time… every day… until one
     day… because of that… because of that… until finally…" — great
     for emotional product stories.
3. **Explain the fit** — for the selected framework, explain in one
   sentence why it matches the audience + purpose.

### Missing data-file handling

If `{data_path}/story-types.csv` is missing or unreadable, emit an
actionable error: `required data file '{data_path}/story-types.csv'
not found — the storytelling skill requires the framework catalog.
Restore the CSV or run the foundation path-resolution check before
retrying.` Do not fall back to an incomplete framework list — halt
before any output artifact is written.

## Phase 3 — Story Construction

Delegate narrative drafting to **Elara (`storyteller`)** via the Agent
tool. This is a `context: fork` subagent invocation — Elara receives the
audience brief, core message, and selected framework, and returns a
structured narrative arc.

1. **Invoke Elara** as a `context: fork` subagent with the Phase 1 +
   Phase 2 outputs. Required subagent file:
   `plugins/gaia/agents/storyteller.md`.

   **Missing-subagent handling:** If the storyteller
   subagent is not installed, fail fast with the exact message
   `required subagent 'storyteller' not found — install the GAIA
   creative agents before running /gaia-storytelling.` No fallback,
   no partial output.
2. **Build the narrative arc** with four beats:
   - **Hook** — the opening image, question, or claim that grabs
     attention in under three seconds.
   - **Rising tension** — stakes, obstacles, and choices that build
     pressure on the protagonist.
   - **Climax** — the moment of transformation. The protagonist's
     change of state happens here.
   - **Resolution** — the new equilibrium; connects back to the core
     message and the desired action.
3. **Apply the selected framework's structure** — map the four beats
   into the framework's canonical sections (e.g., Hero's Journey's
   Ordinary World → Call → Ordeal → Return).
4. **Ensure transformation is visible** — the protagonist must end in
   a different state than they began. A flat arc is a failure.
5. **Add concrete, sensory details** — abstract claims ("easier", "more
   engaging") are replaced with specific, attributable moments.
6. **Persist** the narrative arc so Phase 4 can map emotional beats
   against it.

## Phase 4 — Emotional Beats

Map the emotional journey the audience travels from hook to resolution.

1. **Map the emotional trajectory** — for each beat in the narrative
   arc, name the emotion the audience should feel: curiosity,
   apprehension, recognition, relief, hope, resolve.
2. **Ensure every beat serves the core message** — if a beat does not
   move the audience toward the desired feeling or action, cut it.
3. **Balance tension and relief** — audiences need both pressure and
   release. A uniformly tense story fatigues; a uniformly relieved
   story flatlines.
4. **Verify the climax delivers the transformation** — this is the
   emotional peak. The audience must feel the protagonist change.
5. **Update the narrative arc** with the emotional annotations. Elara
   may be invoked again here (same `context: fork` pattern) to polish
   specific beats.

## Phase 5 — Polish and Present

Finalize the artifact and test it against the 3-second hook rule.

1. **Test the 3-second hook** — read only the first two sentences
   aloud. Is the core question or stakes immediately clear? If not,
   rewrite the opening.
2. **Refine language** — remove every word that does not serve the
   story. Short sentences in the hook, longer sentences in the rising
   tension, punchy sentences at the climax.
3. **Read aloud** — does it flow? Does it feel authentic to the
   protagonist's voice? Fix any passage that sounds stilted.
4. **Record the story in Elara's sidecar memory** (if the Memory
   Update section of Elara's persona is defined) so future invocations
   can reference the narrative pattern.
5. **Render the final artifact** and write it to
   `.gaia/artifacts/creative-artifacts/story-{date}.md`.

## Output

Write the final story artifact to
`.gaia/artifacts/creative-artifacts/story-{date}.md` where `{date}` is the
current date in `YYYY-MM-DD` form. This path is verbatim from the
legacy workflow's `output.primary` contract (functional parity).

### Same-day overwrite handling

If the output file already exists from a prior same-day run:

1. **Default (safe):** Append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/story-{date}-{N}.md` where `{N}` is the
   next available integer starting at 2. Log the disambiguation:
   `Same-day output exists — wrote to story-{date}-{N}.md to avoid
   silent data loss.`
2. **Overwrite:** If the user explicitly requests overwrite (e.g.,
   `--overwrite` flag or explicit confirmation), overwrite the existing
   file and emit `Overwriting existing story-{date}.md per user
   request.`

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **Audience Brief** — target audience, desired feeling, desired
  action, core message.
- **Selected Framework** — name + one-sentence fit rationale.
- **Narrative Arc** — hook, rising tension, climax, resolution with
  framework-specific section headers.
- **Emotional Journey Map** — emotion annotations per beat.
- **Attribution** — Elara (storyteller) credited as narrative author.

## Failure semantics

- If Elara fails (crash, non-zero exit, timeout, or malformed
  output), the skill halts at Phase 3 and does NOT emit a partial
  output artifact. Any captured Phase 1/Phase 2 outputs may be
  preserved as scratch state for debugging, but `story-{date}.md` is
  only written after Phase 5 completes successfully.
- If the `{data_path}/story-types.csv` data file is missing or
  unreadable, halt before Phase 2 with the actionable error above.
- If `plugins/gaia/agents/storyteller.md` is missing, halt before
  Phase 3 with the actionable error above.

## Frontmatter linter compliance

This SKILL.md passes the frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required schema fields are present: `name` (matches the
directory slug) and `description` (trigger signature with concrete
action phrase). `allowed-tools` is validated against the canonical tool
set (Agent is required because Elara is invoked via the Agent tool).
If a future edit removes the `description` field or any other
required field, the frontmatter linter reports the missing field and
the CI gate fails — no silent skill registration is permitted.

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy five-step structure as five
native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Audience and Purpose | Phase 1 | Same four questions: audience, feeling, action, core message |
| Step 2 — Story Framework Selection | Phase 2 | `{data_path}/story-types.csv` reference preserved; same framework options |
| Step 3 — Story Construction | Phase 3 | Same subagent role (Elara / storyteller); delegation via Agent tool |
| Step 4 — Emotional Beats | Phase 4 | Same emotional-mapping contract |
| Step 5 — Polish and Present | Phase 5 | Same 3-second hook rule and `story-{date}.md` output path |

The data flow between phases and the output artifact structure are
identical to the legacy workflow — only the orchestration mechanism
changes (native `context: fork` subagent delegation instead of
legacy engine-driven step dispatch).

## References

- Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- Skill-to-workflow conversion mapping
- Conversion token-reduction target
- Functional parity with legacy workflow
- Reference implementations:
  - `plugins/gaia/skills/gaia-brainstorming/SKILL.md` —
    single-subagent creative skill
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` —
    multi-subagent orchestrator with legacy parity table
- Converted subagent:
  - `plugins/gaia/agents/storyteller.md` — Elara
- Data file (not converted by this story; resolved by the foundation
  path-resolution script):
  - `{data_path}/story-types.csv`
- Legacy parity source (for reference only; not invoked from this
  skill; legacy path intentionally omitted from the body to satisfy
  the "zero legacy references" parity check).

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
lead routes this skill through Mode B, the storytelling subagent (gaia:storyteller) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:storyteller" "gaia-storytelling"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
