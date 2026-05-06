---
name: gaia-test-e2e
description: Execute end-to-end tests via Playwright or Cypress adapters under the ADR-078 contract. Phase 3A toolkit + Phase 3B LLM judgment + verdict resolver. Use when "run e2e tests" or /gaia-test-e2e.
argument-hint: "[story-key] [--adapter <name>] [--target-url <url>]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
triggers:
  - run e2e tests
  - test e2e
  - end-to-end tests
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-e2e/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill (FR-DEJ-1, ADR-075). For `/gaia-test-e2e` it means: the configured e2e adapter (Playwright or Cypress, swappable via `test_execution.e2e.adapter` config or `--adapter` CLI flag) runs in Phase 3A and emits a structured `analysis-results.json` artifact. The LLM then performs an e2e-quality semantic judgment **on top of** that artifact in Phase 3B — applying the e2e rubric (test stability, coverage adequacy, failure root-cause classification, critical-path coverage) — but cannot override a deterministic adapter failure. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill is the **reference implementation** for the deployment-phase action skill pattern (ADR-080) and the first consumer of the ADR-078 e2e adapter contract. The remaining four deployment-phase action skills (`gaia-test-perf`, `gaia-test-dast`, `gaia-test-a11y`, `gaia-test-mobile-e2e`) follow the same template — only the adapter category and rubric differ.

**Fork context semantics (NFR-RSV2-5):** Phase 3B LLM judgment runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). The fork CANNOT modify files. Phase 3A is deterministic shell — no LLM involvement, no fork required. Phase 4 verdict resolution and Review Gate update happen in the parent context via `finalize.sh`.

**Adapter swappability (AC9):** The configured adapter is resolved by `select-adapter.sh` with first-match-wins precedence: `--adapter <name>` CLI flag → `test_execution.e2e.adapter` from `config/project-config.yaml` → default `playwright-e2e`.

**Graceful degradation (AC10):** When `tool-availability-probe.sh` returns `expected_and_missing` (the underlying tool is not installed), Phase 3A emits a `checks[].status: errored` row with a diagnostic `error_reason` naming the missing tool and installation hint. `verdict-resolver.sh` then maps this to BLOCKED — never to a false APPROVE.

## Critical Rules

- A story key argument MAY be provided. If absent, the deployment-phase invocation runs in story-less mode and skips the Review Gate update step.
- The `tool-availability-probe.sh` foundation script (E66-S2) MUST be present at `plugins/gaia/scripts/tool-availability-probe.sh`.
- The `verdict-resolver.sh` and `agent-overlay.sh` foundation scripts (E66-S1) MUST be present at `plugins/gaia/scripts/review-common/`.
- This skill is READ-ONLY in the fork (Phase 3B). Phase 4 finalize.sh runs in main context with Bash + the explicit narrow tool set required by `review-gate.sh`.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (per FR-RSV2-3): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- The adapter `run.sh` invocation MUST go through `tool-availability-probe.sh` first — the probe's three-state classification (`available`, `expected_and_missing`, `ran_and_errored`, `not_applicable`) is the authoritative gate.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in analysis-results.json
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce LLM findings that match by `{category, severity}` (NFR-DEJ-2). Textual message variation is allowed.

## Phases

### Phase 1 — Resolve adapter

Invoke `scripts/select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]`. The script emits the absolute adapter directory path on stdout. Abort the run with an actionable diagnostic if the resolved adapter directory is missing.

### Phase 2 — Probe + Phase 3A evidence collection

Invoke `scripts/phase3a-collect.sh --adapter-dir <path> --output-dir <dir> [--target-url <url>] [--config <path>] [--story-key <key>]`. The script:

1. Calls `tool-availability-probe.sh --adapter-dir <path> --file-list <synthetic>` to classify availability into one of the four canonical states.
2. If `available`, invokes the adapter's `run.sh` to execute the e2e suite, capturing stdout/stderr to `evidence/`.
3. Writes a top-level `analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` with `checks[0]` reflecting the adapter outcome.

Probe state to `checks[].status` mapping (deterministic, encoded in the script):

| Probe state | check.status | Verdict resolver maps to |
|---|---|---|
| `available` (run.sh exit 0) | `passed` | APPROVE eligible |
| `available` but run.sh exit ≠ 0 | `errored` | BLOCKED |
| `expected_and_missing` | `errored` (with diagnostic) | BLOCKED |
| `ran_and_errored` | `errored` (with diagnostic) | BLOCKED |
| `not_applicable` | `skipped` | non-blocking (no e2e suite to run) |

### Phase 3B — LLM judgment (forked context)

Persona resolved via `agent-overlay.sh --skill gaia-test-e2e` → `sable` (Test Architect). The fork loads `knowledge/e2e-rubric.md` and produces `llm-findings.json` covering:

- **Test stability** — flakiness signal, retry-loops, race conditions in selectors.
- **Coverage adequacy** — critical user-journey path coverage (login, checkout, primary CRUD).
- **Failure root-cause classification** — application bug vs test infrastructure vs target environment.
- **Selector resilience** — text-match fragility, hard-coded indices, deep CSS chains.

The fork is read-only; the parent context writes `llm-findings.json` to the output directory.

### Phase 4 — Verdict + Review Gate

Invoke `scripts/verdict.sh --analysis-results <path> --llm-findings <path> [--story-key <key>] [--gate <name>]`. The script:

1. Calls `review-common/verdict-resolver.sh --skill gaia-test-e2e` to compute the verdict (precedence per ADR-075: errored > tool-failed-blocking > LLM-Critical > APPROVE).
2. When `--story-key` and `--gate` are provided, invokes `review-gate.sh update` to update the matching Review Gate row to PASSED (APPROVE) or FAILED (REQUEST_CHANGES, BLOCKED). Deployment-phase invocations without an associated story skip this step.
3. Echoes the verdict on stdout for downstream chaining.

After verdict resolution, the lifecycle hook `scripts/finalize.sh` writes a checkpoint and emits a `workflow_complete` lifecycle event (parallel to gaia-deploy-checklist's finalize pattern). The hook takes no required arguments and is invoked at the end of the skill body.

## Severity Rubric

> See `knowledge/e2e-rubric.md` for the full per-tier rubric. Categories: stability, coverage, root-cause, selector-resilience. Severity tiers: Critical, High, Medium, Suggestion.

## Adapters

This skill ships with two e2e adapters under `plugins/gaia/scripts/adapters/`:

- **`playwright-e2e/`** — invokes `npx playwright test --reporter=json`. Default.
- **`cypress-e2e/`** — invokes `npx cypress run --reporter json`.

Both adapters honour the canonical ADR-078 contract (`adapter.json`, `run.sh`, `test/contract.bats`) PLUS the e2e-specific additive flag `--target-url <url>`. The flag is exported as `PLAYWRIGHT_BASE_URL` (Playwright) or passed via `--config baseUrl=<url>` (Cypress) — neither is required; omission preserves the project's default config.

## Output Contract

The skill emits two JSON files in the configured output directory:

- `analysis-results.json` — Phase 3A artifact, canonical schema (`plugins/gaia/schemas/analysis-results.schema.json`).
- `llm-findings.json` — Phase 3B artifact, schema-compatible with the verdict resolver's `--llm-findings` input.

The verdict (APPROVE | REQUEST_CHANGES | BLOCKED) is emitted on stdout by `finalize.sh`.

## Refs

- ADR-075 — Review skill evidence/judgment split.
- ADR-077 — Three-tier review pipeline.
- ADR-078 — Tool adapter framework (`adapter.json` schema, `run.sh` contract, four-state probe).
- ADR-080 — Deployment-phase action skill pattern.
- FR-RSV2-31, NFR-RSV2-7 — `/gaia-test-e2e` PRD requirements.
- E66-S1, E66-S2, E70-S1 — upstream foundations.
