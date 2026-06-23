---
name: gaia-nfr
description: Assess non-functional requirements covering performance, scalability, reliability, and security. Use when "assess NFRs" or /gaia-nfr.
argument-hint: "[story-key]"
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-nfr/scripts/setup.sh

## Mission

You are producing an NFR assessment report covering performance, scalability, reliability, and security requirements. Each dimension is rated with risk levels (high, medium, low) with justification. The output is written to `.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-{YYYY-MM-DD}.md` (periodically-reassessed plans carry a date suffix + group under a named subdir; legacy undated `nfr-assessment.md` remains read-only fallback).

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/nfr-assessment` workflow. The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics:** This skill runs under `context: main` with full tool access. It reads project state (architecture, PRD, story) and produces an output document.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- Assess all dimensions: performance, security, reliability, and scalability.
- Per-dimension justification is a **hard output requirement**: every risk rating MUST be accompanied by a justification that explicitly explains **why** the chosen risk level (high, medium, or low) was selected. Justification is a required output, not an optional nudge -- a rating without a "why high/medium/low" justification is incomplete and MUST be rewritten.
- Migration-assessment activation trigger (Step 6): activate the migration assessment step when **(a)** the PRD contains "Mode: Brownfield" OR **(b)** `.gaia/artifacts/planning-artifacts/brownfield-assessment.md` exists. If neither indicator is present, skip Step 6 entirely.
- Output MUST be written to `.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-{YYYY-MM-DD}.md` (periodically-reassessed plans carry a date suffix + group under a named subdir; legacy undated `nfr-assessment.md` remains read-only fallback).
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Load NFRs

- Load knowledge fragment: `knowledge/risk-governance.md` for risk-based assessment methodology
- Read NFRs from PRD if available — resolve via the sharded-fallback rule: try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded; NFRs typically live under `prd/05-non-functional-requirements.md`).
- Read NFRs from architecture document at `.gaia/artifacts/planning-artifacts/architecture.md` if available.
- If neither document exists, proceed with generic NFR assessment based on common patterns.
- Extract: response time targets, throughput requirements, availability SLAs, security requirements, data protection obligations.

### Step 2 -- Performance Assessment

- Assess response time targets: P50, P95, P99 latency expectations.
- Assess throughput requirements: requests per second, concurrent users.
- Assess resource limits: CPU, memory, storage, network bandwidth.
- Rate performance risk level (high/medium/low). The justification MUST explain **why** the chosen level was selected (why high, why medium, or why low) -- citing concrete signals such as latency targets, throughput ceilings, or measured bottlenecks. Justification is a required output, not optional.
- Identify performance-sensitive paths and bottleneck candidates.

### Step 3 -- Security Assessment

- Assess authentication mechanisms and strength.
- Assess authorization model and access control boundaries.
- Assess data protection: encryption at rest and in transit, PII handling.
- Rate security risk level (high/medium/low). The justification MUST explain **why** the chosen level was selected (why high, why medium, or why low) -- citing concrete signals such as auth weaknesses, exposure surface, or unmitigated OWASP Top 10 categories. Justification is a required output, not optional.
- Reference OWASP Top 10 categories where applicable.

### Step 4 -- Reliability Assessment

- Assess availability targets: uptime SLA (99.9%, 99.95%, 99.99%).
- Assess fault tolerance: graceful degradation, circuit breakers, fallback paths.
- Assess recovery: RTO (Recovery Time Objective), RPO (Recovery Point Objective).
- Rate reliability risk level (high/medium/low). The justification MUST explain **why** the chosen level was selected (why high, why medium, or why low) -- citing concrete signals such as SLA gaps, missing fallbacks, or RTO/RPO shortfalls. Justification is a required output, not optional.

### Step 5 -- Scalability Assessment

- Assess horizontal scaling capability: stateless services, load distribution.
- Assess vertical scaling limits: single-node capacity ceilings.
- Assess data tier scalability: database sharding, read replicas, caching layers.
- Rate scalability risk level (high/medium/low). The justification MUST explain **why** the chosen level was selected (why high, why medium, or why low) -- citing concrete signals such as statefulness barriers, vertical ceilings, or data-tier hot spots. Justification is a required output, not optional.

### Step 6 -- Migration Assessment (Brownfield)

This step is **optional** -- activate only when brownfield indicators are present.

**Activation trigger (explicit):** activate Step 6 when **(a)** the PRD contains "Mode: Brownfield" OR **(b)** `.gaia/artifacts/planning-artifacts/brownfield-assessment.md` exists. Both conditions are independent triggers -- either one activates the migration assessment. If neither indicator is present, skip Step 6 entirely.

When active, evaluate each of the following migration risk dimensions and rate each one (high/medium/low) with a justification that explains **why** the chosen level was selected. Justification is a required output for every sub-dimension, not optional.

- **Data migration performance** -- assess throughput, batch sizes, and migration window feasibility.
- **Backward compatibility** -- assess contract preservation across the cutover.
- **Dual-Write Latency** -- when active in brownfield mode, this sub-section is required. Assess the latency impact of writing to both the legacy and new systems during migration: target dual-write latency budget, acceptable thresholds, and rollback triggers when latency exceeds the budget.
- **Legacy API Parity** -- when active in brownfield mode, this sub-section is required. Assess API compatibility requirements between the legacy and new endpoints: endpoint mapping, behavioral parity, and the deprecation timeline for legacy endpoints.
- **Session continuity** -- assess user-session preservation across the cutover boundary.

Rate each migration risk dimension (high/medium/low). The justification for each rating MUST explain **why** the chosen level was selected (why high, why medium, or why low) -- citing concrete signals such as throughput gaps, contract drift, latency budgets, parity gaps, or session-state risk. Justification is a required output, not optional.

### Step 7 -- Generate Report

- Compile NFR assessment report with:
  - Executive summary with overall risk posture
  - Performance assessment with risk rating and justification (why high/medium/low)
  - Security assessment with risk rating and justification (why high/medium/low)
  - Reliability assessment with risk rating and justification (why high/medium/low)
  - Scalability assessment with risk rating and justification (why high/medium/low)
  - Migration assessment (if brownfield, otherwise omit) -- when present, the report MUST include both a **Dual-Write Latency** sub-section and a **Legacy API Parity** sub-section, each with its own risk rating and justification
  - Consolidated risk matrix: dimension, risk level, probability, impact
- Every dimension and migration sub-dimension in the report MUST carry a justification explaining **why** the rating was chosen. A rating without a "why high/medium/low" justification is incomplete output.
- Write output to `.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-{YYYY-MM-DD}.md` (periodically-reassessed plans carry a date suffix + group under a named subdir; legacy undated `nfr-assessment.md` remains read-only fallback).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-nfr/scripts/finalize.sh

## References

- Schema: `gaia-public/plugins/gaia/schemas/nfr-assessment.schema.json` (JSON Schema draft-2020-12) — the structural contract for the `nfr-assessment` artifact this skill produces. Validated by `/gaia-val-validate` (artifact_type `nfr-assessment`) via the shared `scripts/lib/validate-artifact-schema.sh` helper.
- Corpus instance: `.gaia/artifacts/test-artifacts/strategy/nfr-assessment.md` — the on-disk exemplar the schema is grounded in (eight canonical H2 sections + YAML frontmatter).
- Validator: `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md` — `artifact_type` enum now carries `nfr-assessment` (enum 16→17).
- Shared validator lib: `gaia-public/plugins/gaia/scripts/lib/validate-artifact-schema.sh` — backend-cascade JSON-schema validator (ajv → python3+jsonschema → graceful SKIP).
- Knowledge: `knowledge/risk-governance.md` — risk-based assessment methodology (Step 1).

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
lead routes this skill through Mode B, the NFR-assessment subagent (gaia:architect) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:architect" "gaia-nfr"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
