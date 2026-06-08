---
name: gaia-domain-research
description: Conduct domain and industry research. Use when the user wants to map a domain landscape (key players, regulations, trends, terminology) and assess domain-specific risks before product definition or technical research.
argument-hint: "[domain or industry focus]"
allowed-tools: [Read, Write, Glob, Grep, Bash, WebSearch, WebFetch]
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

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-domain-research/scripts/setup.sh

## Mission

You are facilitating a domain research session. Guide the user through domain scoping, domain landscape mapping, and domain-specific risk assessment, then emit a structured domain research report at `.gaia/artifacts/planning-artifacts/domain-research.md` for downstream consumers (e.g., `/gaia-tech-research`, `/gaia-product-brief`).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/1-analysis/domain-research` workflow. The step ordering, prompts, and output location follow the legacy `instructions.xml` mechanically — do not restructure, re-prompt, or reorder sections.

## Critical Rules

- Check web access availability before research.
- Clearly distinguish between verified facts and general knowledge.
- The output file path is `.gaia/artifacts/planning-artifacts/domain-research.md` — downstream consumers read this exact path, so do not relocate it.
- Mechanical port: the five legacy steps below must appear in this exact order.

## Steps

### Step 1 — Domain Scoping

Ask the user, in order, and wait for a response on each:

- **"What domain or industry do you want to research?"**
- **"Are there specific aspects you want to focus on?"**

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 1 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE"`

### Step 2 — Web Access Check

- Check if MCP web tools are available.
- If no web access, notify the user and proceed with general knowledge only.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 2 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE"`

### Step 3 — Domain Landscape

- Identify key players and organizations in the domain.
- Document relevant regulations and compliance requirements.
- Map industry trends and emerging patterns.
- Define domain-specific terminology and concepts.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 3 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE"`

### Step 4 — Domain-Specific Risks

- Identify regulatory and compliance risks.
- Assess technical risks specific to the domain.
- Evaluate market and competitive risks.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 4 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE"`

### Step 5 — Generate Output

Write a structured domain research report to `.gaia/artifacts/planning-artifacts/domain-research.md` containing, in order:

- **Domain Overview**
- **Key Players** — organizations and roles
- **Regulatory Landscape** — regulations and compliance requirements
- **Trends** — industry trends and emerging patterns
- **Terminology Glossary** — domain-specific terms and concepts
- **Risk Assessment** — regulatory/compliance, technical, and market/competitive risks
- **Recommendations**

[Source: _gaia/lifecycle/workflows/1-analysis/domain-research/instructions.xml]
[Source: _gaia/lifecycle/workflows/1-analysis/domain-research/workflow.yaml]

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/domain-research.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 5 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE" --paths .gaia/artifacts/planning-artifacts/domain-research.md`

### Step 6 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/domain-research.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/domain-research.md`, `artifact_type = domain-research`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/domain-research.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Val auto-review per the canonical pattern. The `domain-research` artifact_type may not have a canonical document-ruleset; Val skips structural validation for unknown types and still runs factual-claim validation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-domain-research 6 domain="$DOMAIN" research_scope="$RESEARCH_SCOPE" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/domain-research.md`

## Validation

<!--
  V1→V2 22-item checklist port.
  Classification (22 items total):
    - Script-verifiable: 13 (SV-01..SV-13) — enforced by finalize.sh.
    - LLM-checkable:      9 (LLM-01..LLM-09) — evaluated by the host LLM
      against the domain-research artifact below.
  Exit code 0 when all script-verifiable items PASS; non-zero otherwise.
  Dedup / expand rule applied to the V1 surface (2 rules + 11 checkboxes):
    - "Domain clearly defined" and "Risk assessment included" validation
      rules collapse into the Scope (SV-04) and Risk Assessment section
      (SV-11) items respectively — counted once.
    - "All required sections present" in V1 Output Verification expands
      into one check per V2 Step 5 required section (Domain Overview,
      Key Players, Regulatory Landscape, Trends, Terminology Glossary,
      Risk Assessment, Recommendations — SV-06..SV-12) so each section
      fails independently rather than as a single binary.
    - "Terminology glossary included" splits into section-present
      (SV-10) and content-populated (SV-13, ≥3 terms) so an empty
      heading cannot spoof a PASS.
    - The three Risk Assessment sub-items (regulatory/technical/market)
      are LLM-checkable (semantic judgement on coverage quality) while
      the umbrella ## Risk Assessment heading is script-verifiable.
    - Web Access checkboxes from V1 fold into LLM-08 (semantic check on
      the limitation wording).
-->

- [script-verifiable] SV-01 — Output artifact exists at .gaia/artifacts/planning-artifacts/domain-research.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Domain/industry clearly defined
- [script-verifiable] SV-05 — Focus areas identified
- [script-verifiable] SV-06 — Domain Overview section present
- [script-verifiable] SV-07 — Key Players section present
- [script-verifiable] SV-08 — Regulatory Landscape section present
- [script-verifiable] SV-09 — Trends section present
- [script-verifiable] SV-10 — Terminology Glossary section present
- [script-verifiable] SV-11 — Risk Assessment section present
- [script-verifiable] SV-12 — Recommendations section present
- [script-verifiable] SV-13 — Terminology Glossary populated with at least 3 terms
- [LLM-checkable] LLM-01 — Key players identified with roles and context
- [LLM-checkable] LLM-02 — Regulatory landscape captures applicable regulations with scope
- [LLM-checkable] LLM-03 — Industry trends mapped with evidence or direction of travel
- [LLM-checkable] LLM-04 — Terminology glossary entries are accurate and domain-specific
- [LLM-checkable] LLM-05 — Regulatory and compliance risks identified with impact/likelihood
- [LLM-checkable] LLM-06 — Technical risks specific to the domain identified
- [LLM-checkable] LLM-07 — Market and competitive risks evaluated
- [LLM-checkable] LLM-08 — Web access availability and limitations noted if web access unavailable
- [LLM-checkable] LLM-09 — Recommendations actionable and grounded in the risk assessment

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-domain-research/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-product-brief` — consolidate domain findings into a structured product brief.
- **Alternative:** `/gaia-tech-research` — when technology trade-offs still need evaluation before the brief.
