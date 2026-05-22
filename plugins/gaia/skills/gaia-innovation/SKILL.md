---
name: gaia-innovation
description: Identify business-model innovation and strategic disruption opportunities through a five-phase pipeline — Market Context, Jobs-to-be-Done, Blue Ocean / ERRC, Business Model, and Strategic Roadmap. Use when "run innovation strategy" or /gaia-innovation. Delegates facilitation to Orion (innovation-strategist) and produces a creative artifact at .gaia/artifacts/creative-artifacts/innovation-strategy-{date}.md.
argument-hint: "[innovation domain or product]"
allowed-tools: [Read, Write, Glob, Agent]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh innovation-strategist decision-log

# gaia-innovation

Five-phase business-model innovation pipeline: **Market Context →
Jobs-to-be-Done → Blue Ocean / ERRC → Business Model → Strategic
Roadmap**. Delegates each phase's facilitation to Orion
(`innovation-strategist`) via the Agent tool with `context: fork`,
accumulates the phase outputs in the parent skill, and writes a single
artifact at `.gaia/artifacts/creative-artifacts/innovation-strategy-{date}.md` at
completion. Restored under ADR-065 (New Skills Wiring —
/gaia-design-thinking and /gaia-innovation) with full V1 feature
preservation: Jobs-to-be-Done with non-consumer identification, the
ERRC grid (Eliminate/Reduce/Raise/Create), the Business Model Canvas
(BMC, 9 blocks), the Value Proposition Canvas (VPC, jobs/pains/gains),
beachhead market identification, and tech-adoption-lifecycle mapping
(NFR-053).

## Critical Rules

- Run the five phases in strict order — never skip Market Context.
  Strategy without market grounding is theatre.
- Delegate phase facilitation to **Orion (`innovation-strategist`)**
  via the Agent tool with `context: fork`. Orion reads project
  artifacts but does not write — the parent skill writes the final
  artifact (ADR-045 fork-context isolation, extended by ADR-065 to
  creative subagents).
- Single-level spawning only (NFR-046): this skill invokes Orion;
  Orion MUST NOT spawn further subagents.
- Preserve the output contract exactly:
  `.gaia/artifacts/creative-artifacts/innovation-strategy-{date}.md` (date as
  `YYYY-MM-DD`). Downstream skills glob on this prefix.
- Always map innovations to business-model implications. Innovation
  without business-model thinking is theatre.
- Find the non-consumer — that is where disruption lives. Incremental
  thinking is the path to obsolescence.
- Failure is feedback — surface findings honestly, including CRITICAL
  verdicts that halt the pipeline.

## Subagent Dispatch Contract

This skill follows the framework-wide Subagent Dispatch Contract (ADR-063).
When Orion returns from a `context: fork` invocation, the parent skill MUST:

1. **Parse the subagent return** using the ADR-037 structured schema:
   `{ status, summary, artifacts, findings, next }`. The `status` field is
   one of `PASS`, `WARNING`, `CRITICAL`. Each entry in `findings` carries a
   `severity` field with the same vocabulary.
2. **Surface the verdict** to the user inline: display `status` and
   `summary`, then list `findings` with severity. No silent gates — the
   user sees what Orion concluded for every phase.
3. **Halt on CRITICAL** — if `status == "CRITICAL"` or any finding has
   `severity == "CRITICAL"`, the skill HALTS with an actionable error
   message naming the offending finding(s). The user must resolve before
   the pipeline can resume; partial outputs are preserved as scratch
   state for debugging but the unified artifact is NOT written.
4. **Display WARNING** — findings with `severity == "WARNING"` are
   displayed before proceeding to the next phase. The skill does not halt
   but logs the warning to the workflow checkpoint.
5. **Log INFO** — findings with `severity == "INFO"` are logged to the
   checkpoint but not shown unless the user requests verbose output.

This contract applies to every Phase 1–5 subagent return. CRITICAL
findings from creative facilitation are unlikely in practice, but the
contract is enforced uniformly per ADR-063.

## YOLO Behavior

When invoked under YOLO mode, this skill obeys the framework-wide YOLO
Mode Contract (ADR-067):

| Behavior | YOLO action |
|----------|-------------|
| Template-output prompt (`[c]/[y]/[e]`) | Auto-continue (skip prompt). Output already saved; user chose YOLO for speed. |
| Severity / filter selection | Auto-accept default. Defaults are documented and deterministic. |
| Optional confirmation ("Proceed to next phase?") | Auto-confirm. Optional prompts exist for safety; YOLO opts out of safety pauses. |
| Subagent verdict display | Auto-display, but a CRITICAL verdict still HALTS per ADR-063. |
| Open-question indicators (unchecked checkboxes, `TBD`, `TODO`) | HALT — require human input. Open questions cannot be auto-answered. |
| Memory save prompt | HALT — require human input (Phase 4 per ADR-061). Memory writes are never auto-approved. |
| Inline-ask on empty `$ARGUMENTS` | HALT — require human input (per ADR-066). No safe default for "what innovation domain?". |

The contract is identical to the per-behavior lookup table in
architecture.md §10.32.5 (ADR-067). Any future skill change that
diverges from this table requires an ADR amendment.

## Inputs

The skill begins by collecting four inputs from the user (or from
`$ARGUMENTS` when invoked via slash command):

1. **Innovation domain or product** — the market space, product, or
   strategic question to explore (e.g., "How do we disrupt traditional
   developer-onboarding tooling?").
2. **Audience / segment** — who are the customers? Existing users,
   adjacent segments, or the explicit non-consumer the team should
   target.
3. **Constraints** — time-to-market, capital, technical, regulatory,
   competitive, organizational boundaries.
4. **Success criteria** — how will the team know the innovation
   strategy succeeded? Revenue, market share, beachhead penetration,
   strategic optionality.

If `$ARGUMENTS` is empty, ask inline: "What innovation domain or
product should we explore?" (per ADR-066). Do not fail-fast on missing
inputs.

## Pipeline

| Phase | Owner | Subagent | Input | Output |
|-------|-------|----------|-------|--------|
| 1 — Market Context     | Gaia + Orion | `innovation-strategist` | Domain + audience + constraints     | Market landscape map + dominant business models + competitive dynamics |
| 2 — Jobs-to-be-Done    | Gaia + Orion | `innovation-strategist` | Phase 1 landscape + audience       | JTBD framework (functional/emotional/social) + non-consumer identification + outcome-driven mapping |
| 3 — Blue Ocean / ERRC  | Gaia + Orion | `innovation-strategist` | Phase 2 jobs + competitive factors | Strategy canvas + ERRC grid + value curve |
| 4 — Business Model     | Gaia + Orion | `innovation-strategist` | Phase 3 blue ocean + value curve   | Business Model Canvas (9 blocks) + Value Proposition Canvas + beachhead (TAM/SAM/SOM) |
| 5 — Strategic Roadmap  | Gaia + Orion | `innovation-strategist` | Phase 4 model + beachhead          | Tech-adoption-lifecycle mapping + beachhead sequencing + phased market entry |

## Phase 1 — Market Context Analysis

**Subagent:** `innovation-strategist` (Orion). Orion is invoked as a
`context: fork` subagent with the innovation domain, audience, and
constraints as input.

1. **Market landscape scanning** — map the current competitive
   landscape: incumbents, emerging entrants, value chains, regulatory
   forces. Identify trends shaping the space (technology shifts,
   demographic moves, regulatory pivots).
2. **Dominant business-model identification** — surface the dominant
   business models in the space (subscription, marketplace, freemium,
   enterprise, services). Identify which incumbents win on which
   model and why.
3. **Competitive dynamics mapping** — who is winning, who is losing,
   and what is changing? Capture asymmetries the strategy can
   exploit.
4. **Surface Orion's verdict** per the Subagent Dispatch Contract
   above. If CRITICAL, HALT before Phase 2. If WARNING, display and
   proceed.
5. **Persist** the market context to scratch state so Phase 2 can
   consume it.

## Phase 2 — Jobs-to-be-Done Analysis

**Subagent:** `innovation-strategist` (Orion). Orion receives Phase 1
market context as input.

1. **JTBD framework (V1 parity):** identify the **jobs** users hire
   products to do — across three dimensions (NFR-053):
   - **Functional jobs** — the practical task the user is trying to
     accomplish.
   - **Emotional jobs** — how the user wants to feel during and after.
   - **Social jobs** — how the user wants to be perceived by others.
   Capture the underserved, overserved, and unmet jobs explicitly.

2. **Non-consumer identification (V1 mandate):** find the
   **non-consumers** — who SHOULD be using a solution in this space
   but isn't? Disruption lives in non-consumption. The non-consumer
   segment MUST be named, sized (qualitatively at minimum), and
   characterized by the friction that excludes them today. The
   non-consumer focus is preserved verbatim from V1 (NFR-053) —
   skipping non-consumers is a parity regression.

3. **Load frameworks from CSV (V1 parity):** load the innovation
   frameworks catalog from
   `${CLAUDE_PLUGIN_ROOT}/knowledge/innovation-frameworks.csv`. The
   CSV columns are `framework_id, name, category, description,
   best_for`. Filter for `category == "discovery"` and present
   relevant techniques (e.g., JTBD, JTBD Switch Interview).

   **Missing-CSV handling:** if
   `${CLAUDE_PLUGIN_ROOT}/knowledge/innovation-frameworks.csv` is
   missing or unreadable, HALT with the actionable error: `required
   data file '${CLAUDE_PLUGIN_ROOT}/knowledge/innovation-frameworks.csv'
   not found — the innovation skill requires the innovation-frameworks
   catalog. Restore the CSV (canonical source:
   _gaia/creative/data/innovation-frameworks.csv) before retrying.`
   Do NOT fall back to a hardcoded framework list — silent
   degradation is forbidden.

4. **Outcome-driven mapping:** for each named job, capture the
   measurable outcome the user wants — speed, accuracy, predictability,
   independence, status. Outcomes drive the value curve in Phase 3.

5. **Surface Orion's verdict** per the Subagent Dispatch Contract.
   HALT on CRITICAL.

6. **Persist** the JTBD map, non-consumer profile, and outcomes to
   scratch state.

## Phase 3 — Blue Ocean Mapping

**Subagent:** `innovation-strategist` (Orion). Orion receives the
Phase 2 JTBD map and the competitive factors from Phase 1 as input.

1. **Strategy canvas:** plot the competing factors on the canvas (X
   axis: factors of competition; Y axis: offering level). Position
   each incumbent's value curve. Surface where the industry is
   converging — those are the dimensions ripe for elimination or
   reduction.

2. **ERRC grid (V1 parity):** apply the four-quadrant ERRC analysis
   (NFR-053). The grid MUST contain four explicit quadrants:
   - **Eliminate** — which factors that the industry takes for
     granted should be eliminated entirely?
   - **Reduce** — which factors should be reduced well below the
     industry standard?
   - **Raise** — which factors should be raised well above the
     industry standard?
   - **Create** — which factors should be created that the industry
     has never offered?

   Each quadrant MUST be populated with at least one entry grounded in
   the Phase 2 JTBD outcomes. An empty quadrant is a parity
   regression.

3. **New value curve & blue ocean identification:** plot the new
   value curve generated by the ERRC moves. Identify the
   uncontested market space — the blue ocean. Name it explicitly,
   describe how it differs from the red ocean, and explain why the
   competition is irrelevant to that space.

4. **Surface Orion's verdict** per the Subagent Dispatch Contract.
   HALT on CRITICAL.

5. **Persist** the strategy canvas, ERRC grid, and new value curve
   to scratch state.

## Phase 4 — Business Model Innovation

**Subagent:** `innovation-strategist` (Orion). Orion receives the
Phase 3 blue ocean and value curve as input.

1. **Business Model Canvas — BMC (V1 parity):** populate the
   Business Model Canvas with all **9 blocks** (NFR-053):
   - Key Partners
   - Key Activities
   - Key Resources
   - Value Propositions
   - Customer Relationships
   - Channels
   - Customer Segments
   - Cost Structure
   - Revenue Streams

   Each block MUST be filled — an empty block is a parity regression.
   Map every block back to the Phase 3 value curve so the model
   captures (rather than dilutes) the differentiation.

2. **Value Proposition Canvas — VPC (V1 parity):** map the value
   proposition in detail using the customer profile and value map
   sides:
   - **Customer profile:** customer **jobs** (from Phase 2),
     customer **pains** (frictions and risks), customer **gains**
     (desired outcomes and aspirations).
   - **Value map:** **pain relievers** (how the offering removes
     specific pains), **gain creators** (how the offering produces
     specific gains), **products / services** (the concrete
     deliverables).

   The VPC's jobs/pains/gains MUST tie 1:1 to the Phase 2 JTBD —
   any pain or gain not grounded in a Phase 2 job is rejected.

3. **Beachhead market identification (V1 parity):** identify the
   primary target segment — the **beachhead** — that the strategy
   wins first. Frame the beachhead with TAM / SAM / SOM:
   - **TAM** — Total Addressable Market: the entire revenue
     opportunity if every potential customer adopted.
   - **SAM** — Serviceable Addressable Market: the slice the
     business model and channels can reach.
   - **SOM** — Serviceable Obtainable Market: the realistic
     near-term capture given competition and execution capacity.

   The beachhead choice MUST be defensible from the Phase 2
   non-consumer analysis.

4. **Revenue model & cost structure:** explicitly state the revenue
   capture mechanism (subscription, transaction, marketplace fee,
   licensing, freemium-to-paid) and the cost structure profile
   (variable-heavy vs fixed-heavy, scale economics, network
   effects).

5. **Surface Orion's verdict** per the Subagent Dispatch Contract.
   HALT on CRITICAL.

6. **Persist** the BMC, VPC, beachhead with TAM/SAM/SOM, and the
   revenue/cost profile to scratch state.

## Phase 5 — Strategic Roadmap

**Subagent:** `innovation-strategist` (Orion). Orion receives the
Phase 4 business model and beachhead as input.

1. **Tech-adoption-lifecycle mapping (V1 parity, Rogers
   diffusion):** position the innovation on the Rogers diffusion
   curve and name the segment-by-segment plan (NFR-053):
   - **Innovators** — the small group willing to try the rawest
     version. What hooks them?
   - **Early adopters** — the visionaries who buy on potential.
     What proof do they need?
   - **Early majority** — the pragmatists who buy on references.
     What references and integrations close the chasm?
   - **Late majority** — the conservatives who buy on standard.
     What standardization unlocks them?
   - **Laggards** — the skeptics who buy when forced. What
     forcing function applies?

   The plan MUST cover the chasm crossing from early adopters to
   early majority — that is where most innovations die.

2. **Beachhead sequencing:** order the post-beachhead expansion.
   After the Phase 4 beachhead is captured, what is the next
   adjacent segment? The next after that? Sequence at least three
   segments and state the dependency between them — usually a
   capability, a reference, or a reputation that must be built in
   the prior segment.

3. **Phased market entry:** time-box the strategy. Phase 1 (months
   0–6): land the beachhead. Phase 2 (months 6–18): expand to
   sequenced segments. Phase 3 (18+ months): build the
   defensibility moat (network effects, ecosystem, switching
   costs, brand). Each phase MUST list explicit milestones and
   exit criteria.

4. **Defensibility & moat identification:** name the durable
   advantage the strategy is building — economies of scale,
   network effects, switching costs, brand, regulatory moat,
   data moat, ecosystem lock-in. A strategy without a moat is a
   strategy without a future.

5. **Surface Orion's verdict** per the Subagent Dispatch Contract.
   HALT on CRITICAL.

6. **Persist** the lifecycle map, beachhead sequence, phased
   roadmap, and moat identification to scratch state.

## Subagent invocation

Each phase invokes Orion (`innovation-strategist`) via the Agent tool
with `context: fork`. Required subagent file:
`plugins/gaia/agents/innovation-strategist.md`.

**Missing-subagent handling:** if the subagent file is not present,
fail fast with the exact message: `required subagent
'innovation-strategist' not found — install the GAIA creative agents
before running /gaia-innovation.` No fallback, no partial output.

**Single-level spawning (NFR-046):** Orion is a leaf subagent — Orion
MUST NOT spawn further subagents. The dispatch topology is two-level:
Gaia → Orion. Any attempt to nest is rejected.

## Output

Write the final artifact to
`.gaia/artifacts/creative-artifacts/innovation-strategy-{date}.md` where
`{date}` is the current date in `YYYY-MM-DD` form. This path is
verbatim from the legacy workflow's `output.primary` contract
(NFR-053).

### Same-day overwrite handling

If the output file already exists from a prior same-day run:

1. **Default (safe):** append a disambiguating suffix —
   `.gaia/artifacts/creative-artifacts/innovation-strategy-{date}-{N}.md` where
   `{N}` is the next available integer starting at 2. Log the
   disambiguation: `Same-day output exists — wrote to
   innovation-strategy-{date}-{N}.md to avoid silent data loss.`
2. **Overwrite:** if the user explicitly requests overwrite (e.g.,
   `--overwrite` flag or explicit confirmation), overwrite and emit
   `Overwriting existing innovation-strategy-{date}.md per user
   request.`

Silent overwrite is never permitted.

### Artifact structure

The artifact body includes:

- **Innovation Domain** — verbatim from Inputs.
- **Audience Brief** — audience, constraints, success criteria.
- **Phase 1 — Market Context** — landscape map, dominant business
  models, competitive dynamics, attributed to Orion.
- **Phase 2 — Jobs-to-be-Done** — functional/emotional/social jobs,
  non-consumer profile, outcomes.
- **Phase 3 — Blue Ocean / ERRC** — strategy canvas + ERRC grid (4
  populated quadrants) + new value curve + named blue ocean.
- **Phase 4 — Business Model** — Business Model Canvas (9 blocks) +
  Value Proposition Canvas (jobs/pains/gains ↔ pain relievers /
  gain creators / products) + beachhead with TAM/SAM/SOM + revenue
  / cost profile.
- **Phase 5 — Strategic Roadmap** — tech-adoption-lifecycle mapping
  (Rogers segments) + beachhead sequencing + phased market entry +
  moat identification.
- **Verdict log** — every phase's PASS/WARNING/CRITICAL verdict
  from Orion per the Subagent Dispatch Contract.
- **Attribution** — Orion (`innovation-strategist`) credited as
  facilitator for all phases.

## Failure semantics

- If Orion fails (crash, non-zero exit, timeout, malformed output,
  or CRITICAL verdict), the pipeline halts at the current phase and
  does NOT emit a partial output artifact. Captured phase outputs
  may be preserved as scratch state for debugging.
- If `${CLAUDE_PLUGIN_ROOT}/knowledge/innovation-frameworks.csv` is
  missing or unreadable, halt before Phase 2 with the actionable
  error above.
- If `plugins/gaia/agents/innovation-strategist.md` is missing,
  halt before Phase 1 with the actionable error above.

## Frontmatter linter compliance

This SKILL.md passes the frontmatter linter
(`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. The
required fields per the canonical schema are present: `name`
(matches the directory slug), `description` (trigger signature with
concrete action phrase + use phrase), `argument-hint`, `context`,
and `allowed-tools`. `Agent` is in `allowed-tools` because Orion is
invoked via the Agent tool per ADR-041.

## Parity notes vs. legacy workflow

The native pipeline preserves the legacy V1 five-step structure as
five native phases:

| Legacy step | Native phase | Notes |
|-------------|--------------|-------|
| Step 1 — Market Context           | Phase 1 | Same landscape + business-model + competitive-dynamics scope |
| Step 2 — Jobs-to-be-Done Analysis | Phase 2 | JTBD with functional/emotional/social dimensions and **non-consumer identification** preserved verbatim; CSV reference retained at plugin-local path per ADR-065 |
| Step 3 — Blue Ocean Mapping       | Phase 3 | Strategy canvas + **ERRC grid** (4 populated quadrants) retained verbatim; new value curve preserved |
| Step 4 — Business Model Innovation| Phase 4 | **BMC (9 blocks)** + **VPC (jobs/pains/gains)** + beachhead with TAM/SAM/SOM + revenue/cost profile retained |
| Step 5 — Strategic Roadmap        | Phase 5 | **Tech-adoption-lifecycle** Rogers diffusion mapping + beachhead sequencing + phased market entry retained; moat identification added as explicit close |

The data flow between phases and the output artifact structure are
identical to the legacy workflow. Only the orchestration mechanism
changes: native `context: fork` Agent-tool delegation under ADR-041
instead of legacy engine-driven step dispatch.

## References

- ADR-041 — Native Execution Model via Claude Code Skills + Subagents +
  Plugins + Hooks (replaces the legacy workflow engine)
- ADR-042 — Scripts-over-LLM for Deterministic Operations (no new
  scripts for this LLM-judgment skill; CSV path uses
  `${CLAUDE_PLUGIN_ROOT}/knowledge/...`)
- ADR-045 — Review Gate fork-context isolation (extended by ADR-065
  to creative subagents)
- ADR-063 — Subagent Dispatch Contract — Mandatory Verdict Surfacing
  (the source of the Subagent Dispatch Contract section above)
- ADR-065 — New Skills Wiring — /gaia-design-thinking and
  /gaia-innovation (the source for the 5-phase pipeline,
  plugin-local CSV path, and V1 feature preservation requirements)
- ADR-066 — Inline-Ask vs Fail-Fast Contract (this skill asks
  inline on empty `$ARGUMENTS`)
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior
  (the source of the YOLO Behavior table above)
- FR-361 — /gaia-innovation skill restoration
- NFR-046 — Single-level subagent spawning constraint
- NFR-053 — Functional parity with legacy workflow
- AF-2026-04-24-1 — V1-to-V2 37-Command Gap Remediation audit
- Reference implementations:
  - `plugins/gaia/skills/gaia-design-thinking/SKILL.md` (sibling
    five-phase creative skill restored under ADR-065)
  - `plugins/gaia/skills/gaia-brainstorming/SKILL.md`
    (single-subagent creative skill)
  - `plugins/gaia/skills/gaia-storytelling/SKILL.md`
    (single-subagent creative skill with CSV catalog)
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md`
    (multi-subagent creative orchestrator)
- Subagent: `plugins/gaia/agents/innovation-strategist.md` — Orion
- Data file: `${CLAUDE_PLUGIN_ROOT}/knowledge/innovation-frameworks.csv`
  (canonical source: `_gaia/creative/data/innovation-frameworks.csv`)
