---
name: gaia-perf-testing
description: Create performance test plan with load testing scenarios, CI gates, and Core Web Vitals targets. Use when "performance testing" or /gaia-perf-testing.
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-perf-testing/scripts/setup.sh

## Mission

You are creating a performance test plan covering performance budgets, load test scenarios (k6), frontend performance (Core Web Vitals via Lighthouse CI), backend profiling, and CI pipeline integration. The output is written to `docs/test-artifacts/performance-test-plan-{date}.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/performance-testing` workflow (E28-S88, Cluster 12, ADR-041). The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics (ADR-041):** This skill runs under `context: main` with full tool access. It reads project state (architecture, test plan, story) and produces an output document.

## Critical Rules

- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- Performance budgets must be defined with measurable thresholds.
- Load test scenarios must include realistic traffic patterns.
- Output MUST be written to `docs/test-artifacts/performance-test-plan-{date}.md` where `{date}` is today's date in YYYY-MM-DD format.
- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Performance Budget

- Define response time targets: P50, P95, P99 latency thresholds.
- Define throughput targets: requests per second (RPS) under normal and peak load.
- Define error rate thresholds (target less than 0.1% under normal load).
- Establish baseline metrics — two branches conditioned on environment availability:
  - When a production or staging environment IS available: MUST capture baseline metrics (P50/P95/P99 latency, throughput, error rate) from the available production or staging environment and record them in the performance test plan.
  - When no production or staging environment is available: MUST document the absence explicitly as a gap in the performance test plan — for example, `Baseline metrics: GAP — no production or staging environment available; targets are forward-looking only.` Do NOT silently omit the baseline section.
- If architecture.md is available, extract API endpoints and traffic patterns.

### Step 2 -- Load Test Design

- Load knowledge fragment: `knowledge/k6-patterns.md`
- Create test scenarios using k6 or equivalent load testing tool.
- Define virtual user profiles representing real traffic patterns.
- Design ramp-up strategies: gradual load, spike test, soak test.
- Define test data requirements and seed data generation.
- Include threshold configuration for CI pass/fail gates.

### Step 3 -- Frontend Performance

- Load knowledge fragment: `knowledge/lighthouse-ci.md`
- Define Core Web Vitals targets: LCP under 2.5s, INP under 200ms, CLS under 0.1.
- Set bundle size budgets per route (JS, CSS, images).
- Apply concrete critical-rendering-path techniques: **lazy loading** (defer below-the-fold images and components), **code-splitting** (route-level and component-level dynamic imports), and **image optimisation** (modern formats such as WebP/AVIF, responsive `srcset` sizing, compression). Add font subsetting, preconnect hints, and render-blocking script removal where applicable.
- Configure Lighthouse CI assertions for performance score thresholds (target > 90).

### Step 4 -- Backend Profiling

- Identify slow query patterns: N+1 problems, missing indexes, full table scans.
- Analyze memory allocation patterns and potential memory leaks.
- Check connection pool sizing and exhaustion scenarios.
- Profile CPU-intensive operations and identify optimization targets.
- Include database query performance benchmarks.

### Step 5 -- CI Integration

- Add Lighthouse score thresholds to CI pipeline (performance > 90).
- Define load test pass/fail criteria for CI gates.
- Set bundle size limits with automated enforcement.
- Configure performance regression alerts.
- Include k6 GitHub Actions integration configuration.

### Step 6 -- Generate Output

- Generate performance test plan with:
  - Performance budget with P50/P95/P99 targets
  - Load test scenarios (gradual, spike, soak, stress)
  - Core Web Vitals targets and Lighthouse CI configuration
  - Backend profiling checklist
  - CI gate configuration and pass/fail criteria
  - Bundle size budgets and enforcement
- Write output to `docs/test-artifacts/performance-test-plan-{date}.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/test-artifacts/performance-test-plan-${DATE}.md`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-perf-testing/scripts/finalize.sh
