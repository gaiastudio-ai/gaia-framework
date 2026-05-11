---
name: gaia-slide-deck
description: Create a presentation slide deck with a narrative arc — hook, build, payoff — plus visual-design specs and speaker notes. Use when the user asks to "create a slide deck", draft a talk, or design a presentation. Delegates slide-by-slide authoring to Vermeer (presentation-designer).
argument-hint: "[presentation topic]"
allowed-tools: [Read, Write, Glob, Agent]
orchestration_class: light-procedural
---

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh presentation-designer decision-log

# gaia-slide-deck

Presentation design pipeline: **Audience and Purpose → Content
Inventory → Narrative Arc → Slide Outline → Visual Design → Generate
Output**. Produces a slide-deck specification at
`docs/creative-artifacts/slide-deck-{date}.md` with slide-by-slide
content, speaker notes, and a visual-design system. Converted under
ADR-041 (native execution model) with full functional parity against
the legacy source (NFR-053). The legacy-source path is intentionally
omitted from the body per the E28-S104 "zero legacy references"
parity check; see the References section for the parity source
pointer.

## Critical Rules

- Every slide must have exactly **one key message** (one slide = one
  idea). If a slide carries two ideas, split it.
- Visual hierarchy drives attention — master it. Define an explicit
  visual-design system (color palette, typography, layout patterns)
  before generating the slide list.
- The narrative arc must flow: **hook, build, payoff**. Every slide
  must map to one of the three phases.
- Run the six phases in order — never skip Audience and Purpose (the
  takeaway anchor) and never skip Visual Design (the consistency
  contract).
- Delegate slide-by-slide authoring to **Vermeer
  (`presentation-designer`)** via the Agent tool when
  `plugins/gaia/agents/presentation-designer.md` is registered.
  If the subagent is unavailable, facilitate inline — do not halt.
- Preserve the output contract exactly:
  `docs/creative-artifacts/slide-deck-{date}.md` (date as
  `YYYY-MM-DD`). Downstream skills glob on this prefix — do not
  rename.
- This skill and `gaia-pitch-deck` share the same Vermeer subagent
  but have separate bodies. This skill drives generic / talk /
  workshop decks; `gaia-pitch-deck` drives investor / partner
  pitches. Do not merge the two.

## Inputs

The skill begins by collecting four inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Presentation topic** — what is the talk about?
2. **Target audience** — who are they, and what do they already know?
3. **Desired takeaway** — what should the audience do, think, or feel
   after the presentation?
4. **Presentation context** — live talk, async review, workshop,
   conference keynote, sales enablement, internal team meeting?

If any input is missing, prompt the user before entering Content
Inventory.

## Pipeline

The pipeline runs six phases in strict order. Each phase has a clear
entry and exit condition and captures output that feeds the next phase.

| Phase | Responsibility | Input | Output |
|-------|----------------|-------|--------|
| 1. Audience and Purpose | Gaia | User inputs | Audience brief + takeaway |
| 2. Content Inventory | Gaia | Topic + audience | Inventory table (have / need / gaps) |
| 3. Narrative Arc | Gaia + Vermeer | Takeaway + inventory | Arc (hook, build, payoff) + throughline |
| 4. Slide Outline | Vermeer (`presentation-designer`) | Arc + inventory | Slide list (title, key message, visual, notes) |
| 5. Visual Design | Vermeer (`presentation-designer`) | Slide list | Design system (palette, type, layouts) |
| 6. Generate Output | Gaia | All prior outputs | Slide-deck spec artifact |

## Phase 1 — Audience and Purpose

Anchor the deck in the audience and a single takeaway before drafting.

1. **Define the target audience** — who are they, what do they already
   know, what do they expect, what would surprise them?
2. **Define the takeaway** — at the end of the presentation, what
   should the audience do, think, or feel? Write the takeaway as a
   single sentence.
3. **Determine presentation context** — live talk, async review,
   workshop, keynote, sales enablement, internal team. This affects
   pacing (1 slide per minute for talks, 2–3 minutes per slide for
   workshops).

## Phase 2 — Content Inventory

Inventory what you already have before planning what you need.

1. **Identify existing material** — docs, data, images, research,
   interviews, customer quotes.
2. **Extract key data points** — numbers, quotes, and evidence that
   can anchor slides.
3. **Identify gaps** — what content still needs to be created or
   sourced? Flag gaps explicitly so the slide outline can account for
   them.

## Phase 3 — Narrative Arc

Define the story shape that carries the audience from hook to payoff.

1. **Define the story structure** — the arc flows **hook (attention),
   build (evidence), payoff (action)**. Every slide must map to one
   of the three phases.
2. **Create the throughline** — one sentence that connects every
   slide to the takeaway. If a slide does not serve the throughline,
   cut it.
3. **Plan emotional beats** — surprise (hook), tension (build),
   resolution (payoff). The payoff must deliver the takeaway.

## Phase 4 — Slide Outline

Delegate slide-by-slide authoring to **Vermeer
(`presentation-designer`)** via the Agent tool. This is a
`context: fork` subagent invocation — Vermeer receives the Phase 1–3
outputs and returns a structured slide list.

1. **Invoke Vermeer** as a `context: fork` subagent with the audience
   brief, takeaway, narrative arc, and content inventory. Required
   subagent file: `plugins/gaia/agents/presentation-designer.md`.

   **Missing-subagent handling (AC-EC2 analogue):** If the
   presentation-designer subagent is not installed, fail fast with the
   exact message `required subagent 'presentation-designer' not found
   — install the GAIA creative agents before running
   /gaia-slide-deck.` No fallback, no partial output.
2. **Build the slide list** — one slide = one idea. For each slide
   capture:
   - **Title** — short, active, memorable.
   - **Key message** — the single idea the slide communicates.
   - **Supporting visual** — chart, image, diagram, or typography
     treatment that reinforces the message.
   - **Transition logic** — how this slide connects to the next
     (cause-and-effect, contrast, progression, evidence-for-claim).
   - **Slide role** — inform, persuade, transition, or evidence.
   - **Speaker notes** — what the presenter says that the slide
     deliberately does not show.
3. **Target 1 slide per minute** of talk time for live presentations.
   For workshops, allocate 2–3 minutes per slide and add explicit
   interaction prompts.

## Phase 5 — Visual Design

Vermeer defines the visual-design system that keeps the deck
consistent.

1. **Color palette** — 2–3 primary colors plus 1 accent. Name each
   color's role (background, primary text, secondary text, emphasis).
2. **Typography** — heading font, body font, sizes. Specify the
   hierarchy (H1 / H2 / body / caption / code).
3. **Layout patterns** — define reusable layouts for: title slide,
   content slide, comparison slide, data slide, quote slide,
   transition slide.
4. **Consistency rules** — margins, alignment, spacing, image
   treatment. These rules are enforced slide-by-slide in Phase 6.

## Phase 6 — Generate Output

Assemble the final slide-deck specification.

1. Combine the audience brief, narrative arc, slide list, and visual
   design system into a single artifact.
2. For each slide, render: title, key message, supporting visual
   spec, speaker notes, slide role, and layout reference.
3. Write the artifact to
   `docs/creative-artifacts/slide-deck-{date}.md`.

## Output

Write the slide-deck specification to
`docs/creative-artifacts/slide-deck-{date}.md` where `{date}` is the
current date in `YYYY-MM-DD` form. This path is verbatim from the
legacy workflow's `output.primary` contract (NFR-053 — functional
parity).

### Same-day overwrite handling (AC-EC6 analogue)

If the output file already exists from a prior same-day run:

1. **Default (safe):** Append a disambiguating suffix —
   `docs/creative-artifacts/slide-deck-{date}-{N}.md` where `{N}` is
   the next available integer starting at 2. Log the disambiguation.
2. **Overwrite:** Only on explicit user request.

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **Audience Brief** — target audience, takeaway, context, pacing.
- **Content Inventory** — have / need / gaps table.
- **Narrative Arc** — hook → build → payoff with throughline.
- **Slide-by-Slide Specification** — slide list with title, key
  message, visual, speaker notes, role, transition logic.
- **Visual Design System** — palette, typography, layouts,
  consistency rules.
- **Attribution** — Vermeer (presentation-designer) credited as
  slide and visual-design author.

## Failure semantics

- If Vermeer fails (crash, non-zero exit, timeout, or malformed
  output), the skill halts at Phase 4 or Phase 5 and does NOT emit a
  partial output artifact. Any captured Phase 1–3 outputs may be
  preserved as scratch state for debugging, but
  `slide-deck-{date}.md` is only written after Phase 6 completes
  successfully.
- If `plugins/gaia/agents/presentation-designer.md` is missing, halt
  before Phase 4 with the actionable error above.

## Frontmatter linter compliance

This SKILL.md passes the E28-S7 frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required fields per E28-S19 schema are present: `name` (matches the
directory slug) and `description` (trigger signature with concrete
action phrase). `allowed-tools` is validated against the canonical
tool set (Agent is required because Vermeer is invoked via the Agent
tool).

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy six-step structure as six
native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Audience and Purpose | Phase 1 | Same three inputs (audience, takeaway, context) |
| Step 2 — Content Inventory | Phase 2 | Same have / need / gaps decomposition |
| Step 3 — Narrative Arc | Phase 3 | Same hook-build-payoff structure + throughline |
| Step 4 — Slide Outline | Phase 4 | Same subagent role (Vermeer / presentation-designer); delegation via Agent tool per ADR-041 |
| Step 5 — Visual Design | Phase 5 | Same palette, typography, layout decomposition |
| Step 6 — Generate Output | Phase 6 | Same output path `slide-deck-{date}.md` |

The slide-by-slide content contract, the speaker-notes requirement,
and the one-slide-one-idea rule are preserved verbatim from the
legacy workflow — only the orchestration mechanism changes (native
`context: fork` subagent delegation under ADR-041 instead of legacy
engine-driven step dispatch).

## References

- ADR-041 — Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- FR-323 — Skill-to-workflow conversion mapping
- NFR-048 — Conversion token-reduction target
- NFR-053 — Functional parity with legacy workflow
- Reference implementations:
  - `plugins/gaia/skills/gaia-pitch-deck/SKILL.md` (E28-S104 —
    sibling skill, same subagent, pitch-specific structure)
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` (E28-S102 —
    multi-subagent orchestrator with legacy parity table)
- Converted subagent (E28-S22):
  - `plugins/gaia/agents/presentation-designer.md` — Vermeer
- Legacy parity source (for reference only; not invoked from this
  skill; legacy path intentionally omitted from the body to satisfy
  the "zero legacy references" parity check — see E28-S104 test
  scenario 10).
