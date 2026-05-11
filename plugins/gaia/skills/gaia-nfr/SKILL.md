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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE"
```

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-nfr/scripts/setup.sh

## Mission

You are producing an NFR assessment report covering performance, scalability, reliability, and security requirements. Each dimension is rated with risk levels (high, medium, low) with justification. The output is written to `docs/test-artifacts/nfr-assessment.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/nfr-assessment` workflow (E28-S88, Cluster 12, ADR-041). The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics (ADR-041):** This skill runs under `context: main` with full tool access. It reads project state (architecture, PRD, story) and produces an output document.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- Assess all dimensions: performance, security, reliability, and scalability.
- Per-dimension justification is a **hard output requirement**: every risk rating MUST be accompanied by a justification that explicitly explains **why** the chosen risk level (high, medium, or low) was selected. Justification is a required output, not an optional nudge -- a rating without a "why high/medium/low" justification is incomplete and MUST be rewritten.
- Migration-assessment activation trigger (Step 6): activate the migration assessment step when **(a)** the PRD contains "Mode: Brownfield" OR **(b)** `docs/planning-artifacts/brownfield-assessment.md` exists. If neither indicator is present, skip Step 6 entirely.
- Output MUST be written to `docs/test-artifacts/nfr-assessment.md`.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Load NFRs

- Load knowledge fragment: `knowledge/risk-governance.md` for risk-based assessment methodology
- Read NFRs from PRD at `docs/planning-artifacts/prd.md` if available.
- Read NFRs from architecture document at `docs/planning-artifacts/architecture.md` if available.
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

**Activation trigger (explicit):** activate Step 6 when **(a)** the PRD contains "Mode: Brownfield" OR **(b)** `docs/planning-artifacts/brownfield-assessment.md` exists. Both conditions are independent triggers -- either one activates the migration assessment. If neither indicator is present, skip Step 6 entirely.

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
- Write output to `docs/test-artifacts/nfr-assessment.md`.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-nfr/scripts/finalize.sh
