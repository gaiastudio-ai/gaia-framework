---
name: gaia-pitch-deck
description: Create an investor or partner pitch deck using the standard Problem → Solution → Market → Business Model → Traction → Team → Ask structure with speaker notes and data-visualization specs. Use when the user asks to "create a pitch deck", build an investor deck, or draft a partnership pitch. Delegates slide authoring to Vermeer (presentation-designer).
argument-hint: "[funding stage or pitch purpose]"
allowed-tools: [Read, Write, Glob, Agent]
orchestration_class: light-procedural
---

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh presentation-designer decision-log

# gaia-pitch-deck

Investor / partner pitch pipeline: **Pitch Context → Load Business
Artifacts → Standard Pitch Structure → Slide-by-Slide Content → Data
Visualization → Storytelling Polish → Generate Output**. Produces a
pitch-deck specification at
`.gaia/artifacts/creative-artifacts/pitch-deck-{date}.md` covering every
standard pitch section with speaker notes and chart specs. Converted
under ADR-041 (native execution model) with full functional parity
against the legacy source (NFR-053). The legacy-source path is
intentionally omitted from the body per the E28-S104 "zero legacy
references" parity check; see the References section for the parity
source pointer.

## Critical Rules

- Follow the **standard pitch-deck structure**: Cover → **Problem** →
  **Solution** → **Market** → **Business Model** → **Traction** →
  **Team** → **Ask**. Appendix slides may follow the Ask but never
  replace a core section.
- Every data point must be **specific and credible** — cite the source
  or flag the number as a hypothesis. "Massive market" without a TAM
  / SAM / SOM decomposition is not acceptable.
- The **Ask** must be clear and justified — specific funding amount
  (or specific partnership terms), specific use of funds, specific
  milestones the funds unlock.
- Run the seven phases in order — never skip Pitch Context (the
  audience anchor) and never skip Storytelling Polish (the
  hook-to-CTA flow).
- Delegate slide-by-slide authoring to **Vermeer
  (`presentation-designer`)** via the Agent tool when
  `plugins/gaia/agents/presentation-designer.md` is registered.
  If the subagent is unavailable, facilitate inline — do not halt.
- Preserve the output contract exactly:
  `.gaia/artifacts/creative-artifacts/pitch-deck-{date}.md` (date as
  `YYYY-MM-DD`). Downstream skills glob on this prefix — do not
  rename.
- This skill and `gaia-slide-deck` share the same Vermeer subagent
  but have separate bodies. This skill drives investor / partner
  pitches with the standard seven-section structure;
  `gaia-slide-deck` drives generic / talk / workshop decks with a
  narrative-arc structure. Do not merge the two.

## Inputs

The skill begins by collecting three inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Audience** — investors (seed / series A / series B / growth),
   strategic partners, internal stakeholders, customers for a
   partnership pitch.
2. **Funding stage or purpose** — seed round, series A, partnership
   agreement, internal buy-in, grant application.
3. **Key ask** — specific funding amount (with currency) or
   specific partnership terms plus the specific use of funds or
   partnership deliverables.

If any input is missing, prompt the user before entering Load
Business Artifacts.

## Pipeline

The pipeline runs seven phases in strict order. Each phase has a
clear entry and exit condition and captures output that feeds the
next phase.

| Phase | Responsibility | Input | Output |
|-------|----------------|-------|--------|
| 1. Pitch Context | Gaia | User inputs | Audience + stage + ask brief |
| 2. Load Business Artifacts | Gaia | Existing product / market docs | Data points, metrics, competitive insights |
| 3. Standard Pitch Structure | Gaia | Context + artifacts | Slide map (Cover, Problem, Solution, Market, Business Model, Traction, Team, Ask) |
| 4. Slide-by-Slide Content | Vermeer (`presentation-designer`) | Slide map + artifacts | Headlines, messages, data, speaker notes |
| 5. Data Visualization | Vermeer (`presentation-designer`) | Market / business-model / traction data | Chart specs + competitive matrix |
| 6. Storytelling Polish | Vermeer (`presentation-designer`) | Full deck | Polished narrative flow + hook / CTA |
| 7. Generate Output | Gaia | All prior outputs | Pitch-deck specification artifact |

## Phase 1 — Pitch Context

Anchor the pitch in audience, stage, and a specific ask.

1. **Define audience** — investors (seed / series A / series B /
   growth), strategic partners, internal stakeholders.
2. **Identify funding stage or purpose** — seed, series A,
   partnership, internal buy-in, grant. The stage dictates depth
   (seed decks lead with problem and team; series A decks lead with
   traction and unit economics).
3. **Define the key ask** — funding amount (with currency),
   partnership terms, resource allocation. The ask must be specific
   enough that the audience can say "yes" or "no" — vague asks get
   vague answers.

## Phase 2 — Load Business Artifacts

Load whatever business context exists so the deck draws on concrete
evidence rather than generic claims.

1. Read `{planning_artifacts}/product-brief.md` if available for the
   product positioning and problem framing.
2. Read `{planning_artifacts}/market-research-*.md` if available for
   TAM / SAM / SOM and competitive landscape.
3. Read `{planning_artifacts}/innovation-strategy-*.md` if available
   for business-model innovation and differentiation.
4. **Extract key data points** — market size numbers, customer
   quotes, traction metrics, competitive insights, unit economics.
   Every number MUST carry its source — uncited numbers are
   hypotheses and must be flagged as such.

## Phase 3 — Standard Pitch Structure

Build the canonical slide map. Every pitch deck covers these sections
in this order:

- **Cover** — company name, tagline (one memorable sentence), logo,
  date.
- **Problem** — the specific pain point, anchored in market data and
  customer quotes. The audience must feel the problem in the first 60
  seconds.
- **Solution** — how the company solves it, unique approach, category
  positioning. One idea per slide.
- **Market** — TAM / SAM / SOM with credible sources. Show the path
  from the total market to the obtainable share.
- **Business Model** — revenue model, pricing, unit economics,
  distribution strategy. This is where the "how do you make money"
  question lives — answer it explicitly.
- **Traction** — metrics, growth, milestones. For pre-traction
  pitches, show the concrete roadmap and the de-risking experiments
  run to date.
- **Team** — key members, relevant experience, advisors, investors.
  Highlight domain fit and past wins.
- **Ask** — specific funding amount or partnership terms plus the
  specific use of funds and the specific milestones they unlock.

Appendix slides (optional, always after the Ask): detailed
financials, technical architecture, full competitive matrix, legal
structure, regulatory strategy.

## Phase 4 — Slide-by-Slide Content

Delegate slide authoring to **Vermeer (`presentation-designer`)**
via the Agent tool. This is a `context: fork` subagent invocation —
Vermeer receives the pitch context, business artifacts, and slide map
and returns a structured slide list.

1. **Invoke Vermeer** as a `context: fork` subagent. Required
   subagent file: `plugins/gaia/agents/presentation-designer.md`.

   **Missing-subagent handling (AC-EC2 analogue):** If the
   presentation-designer subagent is not installed, fail fast with the
   exact message `required subagent 'presentation-designer' not found
   — install the GAIA creative agents before running
   /gaia-pitch-deck.` No fallback, no partial output.
2. **For each required slide** (Cover, Problem, Solution, Market,
   Business Model, Traction, Team, Ask), capture:
   - **Headline** — short, active, pitch-worthy.
   - **Key message** — the single idea the slide communicates.
   - **Supporting data** — specific numbers, quotes, or evidence with
     sources.
   - **Visual specification** — chart type, image, or diagram.
   - **Speaker notes** — what the presenter says that the slide
     deliberately does not show.
3. **Add appendix slides** for detailed financials, tech architecture,
   and competitive matrix. Appendix slides are always optional at
   presentation time but available for investor Q&A.

## Phase 5 — Data Visualization

Every pitch deck lives or dies on the quality of its charts. Design
them explicitly — no generic stock graphs.

1. **Market size** — TAM / SAM / SOM funnel chart with sources.
2. **Growth trajectory** — historical growth + projected growth with
   the assumptions underlying the projection called out.
3. **Revenue projections** — unit economics (CAC, LTV, payback
   period) plus the revenue build-up by customer segment.
4. **Competitive positioning** — 2x2 matrix on the two axes that
   matter most for the category (e.g., price vs. quality,
   integration depth vs. ease of setup). Place competitors
   accurately; do not fabricate a favorable corner.
5. For each chart, specify: chart type, color palette, labeling,
   source citation, and the single insight the chart should deliver.

## Phase 6 — Storytelling Polish

Pitch decks are stories, not reports. Apply narrative craft to the
full deck.

1. **Narrative flow** — the audience's journey runs from problem
   (urgency) through solution (relief) to opportunity (excitement).
   Check slide-by-slide that this flow holds.
2. **Emotional beats** — urgency (Problem), relief (Solution),
   excitement (Market), confidence (Business Model), proof
   (Traction), trust (Team), clarity (Ask).
3. **Opening hook** — the Cover and Problem slides must grab
   attention in under 60 seconds combined. Rewrite until they do.
4. **Closing call to action** — the Ask slide must leave the
   audience with a specific next step and a specific deadline.

## Phase 7 — Generate Output

Assemble the final pitch-deck specification.

1. Combine pitch context, slide-by-slide content, data-visualization
   specs, visual-design system, and appendix slides into a single
   artifact.
2. Write the artifact to
   `.gaia/artifacts/creative-artifacts/pitch-deck-{date}.md`.

## Output

Write the pitch-deck specification to
`.gaia/artifacts/creative-artifacts/pitch-deck-{date}.md` where `{date}` is the
current date in `YYYY-MM-DD` form. This path is verbatim from the
legacy workflow's `output.primary` contract (NFR-053 — functional
parity).

### Same-day overwrite handling (AC-EC6 analogue)

If the output file already exists from a prior same-day run:

1. **Default (safe):** Append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/pitch-deck-{date}-{N}.md` where `{N}` is
   the next available integer starting at 2.
2. **Overwrite:** Only on explicit user request.

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **Audience Context** — audience, stage, ask.
- **Business Context Summary** — key data points from loaded
  artifacts with sources.
- **Slide-by-Slide Specification** — eight core slides (Cover,
  Problem, Solution, Market, Business Model, Traction, Team, Ask)
  each with headline, key message, supporting data, visual, speaker
  notes.
- **Data Visualization Specs** — chart list with chart type, palette,
  labeling, source citation.
- **Appendix Slides** — optional detail slides for investor Q&A.
- **Attribution** — Vermeer (presentation-designer) credited as
  slide and visual-design author.

## Failure semantics

- If Vermeer fails (crash, non-zero exit, timeout, or malformed
  output), the skill halts at Phase 4, 5, or 6 and does NOT emit a
  partial output artifact. Any captured Phase 1–3 outputs may be
  preserved as scratch state for debugging, but
  `pitch-deck-{date}.md` is only written after Phase 7 completes
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

The native pipeline preserves the legacy seven-step structure as
seven native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Pitch Context | Phase 1 | Same three inputs (audience, stage, ask) |
| Step 2 — Load Business Artifacts | Phase 2 | Same product-brief / market / innovation sources; same extracted-data-points contract |
| Step 3 — Standard Pitch Structure | Phase 3 | Same eight-section canonical order (Cover, Problem, Solution, Market, Business Model, Traction, Team, Ask) |
| Step 4 — Slide-by-Slide Content | Phase 4 | Same subagent role (Vermeer / presentation-designer); delegation via Agent tool per ADR-041 |
| Step 5 — Data Visualization | Phase 5 | Same chart list (market, growth, revenue, competitive) |
| Step 6 — Storytelling Polish | Phase 6 | Same narrative-flow + emotional-beats + hook / CTA decomposition |
| Step 7 — Generate Output | Phase 7 | Same output path `pitch-deck-{date}.md` |

The pitch structure, the speaker-notes requirement, and the
every-data-point-must-be-credible rule are preserved verbatim from
the legacy workflow — only the orchestration mechanism changes
(native `context: fork` subagent delegation under ADR-041 instead of
legacy engine-driven step dispatch).

## References

- ADR-041 — Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- FR-323 — Skill-to-workflow conversion mapping
- NFR-048 — Conversion token-reduction target
- NFR-053 — Functional parity with legacy workflow
- Reference implementations:
  - `plugins/gaia/skills/gaia-slide-deck/SKILL.md` (E28-S104 —
    sibling skill, same subagent, generic-deck structure)
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` (E28-S102 —
    multi-subagent orchestrator with legacy parity table)
- Converted subagent (E28-S22):
  - `plugins/gaia/agents/presentation-designer.md` — Vermeer
- Legacy parity source (for reference only; not invoked from this
  skill; legacy path intentionally omitted from the body to satisfy
  the "zero legacy references" parity check — see E28-S104 test
  scenario 10).
