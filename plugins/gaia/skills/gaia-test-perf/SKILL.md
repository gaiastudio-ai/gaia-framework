---
name: gaia-test-perf
description: Execute post-deploy performance tests via k6 and Lighthouse adapters under the tool adapter contract. Phase 3A toolkit + Phase 3B LLM judgment + verdict resolver, plus SLO and baseline-regression checks. Use when "run perf tests" or /gaia-test-perf.
argument-hint: "[story-key] [--adapter <name>] [--target-url <url>] [--scenario <name>]"
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
adapters: [k6, lighthouse]
triggers:
  - run perf tests
  - test perf
  - performance test
  - post-deploy perf
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-perf/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill. For `/gaia-test-perf` it means: the configured perf adapter (k6 or Lighthouse, swappable via `test_execution.perf.adapter` config or `--adapter` CLI flag) runs in Phase 3A and emits a structured `analysis-results.json` artifact alongside the raw tool summary. The skill's `slo-check.sh` then evaluates each scenario's measured metrics against the declared SLOs (p95 latency, error rate, RPS for k6; performance score, LCP, CLS for Lighthouse), and `baseline-check.sh` compares the current p95 against the last-known baseline at `.gaia/perf-baselines/{scenario}.json`. The LLM then performs a perf-quality semantic judgment in Phase 3B — applying the perf rubric — but cannot override a deterministic SLO breach or adapter failure. The verdict is computed by `verdict-resolver.sh`; the LLM never computes the verdict in natural language.

This skill is a deployment-phase action skill and a peer of `/gaia-test-e2e` — same Phase 3A/3B/3C plumbing, perf-specific rubric and SLO/baseline overlays.

**Static vs dynamic distinction:** `/gaia-review-perf` (static, pre-merge) reads code and finds N+1 / complexity issues. `/gaia-test-perf` (this skill, dynamic, deployment-phase) runs k6 / Lighthouse against a live deployed endpoint. They are complementary, not alternatives.

**Fork context semantics:** Phase 3B LLM judgment runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). Phase 3A is deterministic shell. Phase 4 verdict resolution and Review Gate update happen in the parent context via `verdict.sh` + `finalize.sh`.

**Adapter swappability:** Resolved by `select-adapter.sh` with first-match-wins precedence: `--adapter <name>` CLI flag → `test_execution.perf.adapter` from `.gaia/config/project-config.yaml` → default `k6`.

**Graceful degradation:** When `tool-availability-probe.sh` returns `expected_and_missing`, Phase 3A emits a `checks[].status: errored` row with a diagnostic `error_reason` naming the missing tool and installation hint. `verdict-resolver.sh` maps this to BLOCKED — never to a false APPROVE.

## Critical Rules

- A story key argument MAY be provided. If absent, the deployment-phase invocation runs in story-less mode and skips the Review Gate update step.
- The `tool-availability-probe.sh` foundation script MUST be present at `plugins/gaia/scripts/tool-availability-probe.sh`.
- The `verdict-resolver.sh` foundation script MUST be present at `plugins/gaia/scripts/verdict-resolver.sh`.
- This skill is READ-ONLY in the fork (Phase 3B). Phase 4 verdict.sh runs in main context with Bash + the explicit narrow tool set required by `review-gate.sh`.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary: APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Adapter `run.sh` invocation MUST go through `tool-availability-probe.sh` first — the probe's three-state classification is the authoritative gate.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- Baseline files at `.gaia/perf-baselines/{scenario}.json` are gitignored (environment-specific data). Renaming a scenario resets its baseline.

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in analysis-results.json
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce LLM findings that match by `{category, severity}`. Textual message variation is allowed.

## Configuration Schema

Project-config block consumed by this skill (`.gaia/config/project-config.yaml`):

```yaml
test_execution:
  perf:
    adapter: k6                  # k6 | lighthouse  (default: k6)
  deployment:
    perf_test:
      regression_threshold_pct: 20    # default 20%
      scenarios:
        - name: login
          adapter: k6
          target_url: https://staging.example.com/login
          script: .gaia/perf-scripts/login.js
          slos:
            p95_latency_ms: 500
            error_rate_max: 0.01
            min_rps: 100
          regression_threshold_pct: 25     # optional per-scenario override
        - name: home
          adapter: lighthouse
          target_url: https://staging.example.com/
          categories: performance
          slos:
            performance_score_min: 0.9
            lcp_ms_max: 2500
            cls_max: 0.1
```

## Phases

### Phase 1 — Resolve adapter

Invoke `scripts/select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]`. The script emits the absolute adapter directory path on stdout. Abort the run with an actionable diagnostic if the resolved adapter directory is missing.

### Phase 2 — Probe + Phase 3A evidence collection

Invoke `scripts/phase3a-collect.sh --adapter-dir <path> --output-dir <dir> [--target-url <url>] [--config <path>] [--story-key <key>]`. The script:

1. Calls `tool-availability-probe.sh --adapter-dir <path> --file-list <synthetic>` to classify availability.
2. If `available`, invokes the adapter's `run.sh` to execute the perf test, capturing stdout/stderr to `evidence/`.
3. Writes a top-level `analysis-results.json` with `checks[0]` reflecting the adapter outcome.

Probe state to `checks[].status` mapping:

| Probe state | check.status | Verdict resolver maps to |
|---|---|---|
| `available` (run.sh exit 0) | `passed` | APPROVE eligible |
| `available` but run.sh exit ≠ 0 | `errored` | BLOCKED |
| `expected_and_missing` | `errored` (with diagnostic) | BLOCKED |
| `ran_and_errored` | `errored` (with diagnostic) | BLOCKED |
| `not_applicable` | `skipped` | non-blocking |

### Phase 2b — SLO + baseline overlay

For each scenario in `test_execution.deployment.perf_test.scenarios[]`:

1. Invoke `scripts/slo-check.sh --config <perf-test-block.json> --results <normalized-result.json>` to evaluate per-scenario SLOs and emit a composite verdict.
2. Invoke `scripts/baseline-check.sh --scenario <name> --results <normalized-result.json> --baseline-dir .gaia/perf-baselines [--threshold <pct>]` to flag p95 regressions.
3. Append SLO breaches and regression annotations as Phase 3A findings (severity: Critical for SLO breach, High for regression > threshold).

### Phase 3B — LLM judgment (forked context)

Persona resolved via `agent-overlay.sh --skill gaia-test-perf` → `sable` (Test Architect). The fork loads `knowledge/perf-rubric.md` and produces `llm-findings.json` covering:

- **SLO conformance** — clear restatement of breaches surfaced in Phase 3A; explicit "no SLO breach" finding when none.
- **Regression severity** — interpretation of baseline regression annotations.
- **Throughput consistency** — coefficient of variation across virtual-user ramps.
- **Browser perf opportunities** — Lighthouse audits (TBT, render-blocking resources, image opt) classified as Suggestion or High depending on impact.

The fork is read-only; the parent context writes `llm-findings.json` to the output directory.

### Phase 4 — Verdict + Review Gate

Invoke `scripts/verdict.sh --analysis-results <path> --llm-findings <path> [--story-key <key>] [--gate "Performance Review"]`. The script:

1. Calls `verdict-resolver.sh --skill gaia-test-perf` to compute the verdict (precedence: errored > tool-failed-blocking > LLM-Critical > APPROVE).
2. When `--story-key` and `--gate` are provided, invokes `review-gate.sh update` to update the matching Review Gate row to PASSED (APPROVE) or FAILED (REQUEST_CHANGES, BLOCKED). Deployment-phase invocations without an associated story skip this step.
3. Echoes the verdict on stdout for downstream chaining.

After verdict resolution, the lifecycle hook `scripts/finalize.sh` writes a checkpoint and emits a `workflow_complete` lifecycle event.

## Severity Rubric

> See `knowledge/perf-rubric.md` for the full per-tier rubric. Categories: slo, regression, throughput, browser-opportunity. Severity tiers: Critical, High, Medium, Suggestion.

## Adapters

This skill ships with two perf adapters under `plugins/gaia/scripts/adapters/`:

- **`k6/`** — invokes `k6 run --quiet --summary-export=-`. Default. Additive flag `--script <path>` resolves to `$K6_SCRIPT` or `.gaia/perf-scripts/default.js`.
- **`lighthouse/`** — invokes `lighthouse <url> --output=json --quiet --chrome-flags="--headless --no-sandbox"`. Additive flag `--categories <csv>` (default: `performance`).

Both adapters honour the canonical tool adapter contract (`adapter.json`, `run.sh`, `test/contract.bats`) PLUS the perf-specific additive flag `--target-url <url>`.

## Output Contract

The skill emits two JSON files in the configured output directory:

- `analysis-results.json` — Phase 3A artifact, canonical schema (`plugins/gaia/schemas/analysis-results.schema.json`).
- `llm-findings.json` — Phase 3B artifact, schema-compatible with the verdict resolver's `--llm-findings` input.

The verdict (APPROVE | REQUEST_CHANGES | BLOCKED) is emitted on stdout by `verdict.sh`.

## Refs

- Review skill evidence/judgment split.
- Three-tier review pipeline.
- Tool adapter framework (`adapter.json` schema, `run.sh` contract, four-state probe).
- Deployment-phase action skill pattern.
- `/gaia-test-perf` requirements.
- `/gaia-test-e2e` reference implementation.
