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
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-perf-testing/scripts/setup.sh

## Mission

You are creating a performance test plan covering performance budgets, load test scenarios (k6), frontend performance (Core Web Vitals via Lighthouse CI), backend profiling, and CI pipeline integration. The output is written to `.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-{date}.md` (grouped under a named subdir for the periodically-reassessed class; legacy ungrouped `test-artifacts/performance-test-plan-{date}.md` remains read-only fallback).

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/performance-testing` workflow. The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics:** This skill runs under `context: main` with full tool access. It reads project state (architecture, test plan, story) and produces an output document.

## Critical Rules

- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- Performance budgets must be defined with measurable thresholds.
- Load test scenarios must include realistic traffic patterns.
- Output MUST be written to `.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-{date}.md` (grouped under a named subdir for the periodically-reassessed class; legacy ungrouped `test-artifacts/performance-test-plan-{date}.md` remains read-only fallback) where `{date}` is today's date in YYYY-MM-DD format.
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
- Write output to `.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-{date}.md` (grouped under a named subdir for the periodically-reassessed class; legacy ungrouped `test-artifacts/performance-test-plan-{date}.md` remains read-only fallback).

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-${DATE}.md`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-perf-testing/scripts/finalize.sh

## References

- Schema: `gaia-public/plugins/gaia/schemas/performance-test-plan.schema.json` (JSON Schema draft-2020-12) — the structural contract for the `performance-test-plan` artifact this skill produces. Validated by `/gaia-val-validate` (artifact_type `performance-test-plan`) via the shared `scripts/lib/validate-artifact-schema.sh` helper.
- Corpus instance: `.gaia/artifacts/test-artifacts/strategy/performance-test-plan-2026-03-13.md` — the on-disk exemplar the schema is grounded in (seven canonical H2 sections + YAML frontmatter).
- Validator: `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md` — `artifact_type` enum now carries `performance-test-plan`.
- Shared validator lib: `gaia-public/plugins/gaia/scripts/lib/validate-artifact-schema.sh` — backend-cascade JSON-schema validator (ajv → python3+jsonschema → graceful SKIP).
- Knowledge: `knowledge/k6-patterns.md` (Step 2 load-test design), `knowledge/lighthouse-ci.md` (Step 3 frontend performance).

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
lead routes this skill through Mode B, the performance-testing subagent (gaia:devops) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:devops" "gaia-perf-testing"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
