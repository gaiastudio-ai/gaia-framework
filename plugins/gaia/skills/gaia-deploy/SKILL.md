---
name: gaia-deploy
description: Pattern A deployment orchestrator — composite pre-deploy gate (ADR-082) → adapter-mediated deploy (ADR-078) → health-check → post-deploy smoke (E73-S1..S4) → final verdict. Sequential, transparent, no auto-retry, no auto-rollback. Use when "deploy this version" or /gaia-deploy.
argument-hint: "--env <env> --version <ver> [--skip-smoke] [--story-key <key>]"
context: main
allowed-tools: [Read, Grep, Glob, Bash, Skill]
type: action
verdict: true
phase: deployment
triggers:
  - deploy this version
  - run gaia-deploy
  - deployment pipeline
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-deploy/scripts/setup.sh

## Mission

`/gaia-deploy` orchestrates a five-phase deployment pipeline: **pre-deploy gate → deploy → health-check → post-deploy smoke → final verdict**. The skill is the reference implementation of **ADR-080 Pattern A** — claude-driven, sequential, transparent, adapter-mediated, environment-isolated, with **no auto-retry and no auto-rollback**.

Pre-deploy gating is delegated to `composite-verdict-aggregator.sh` (ADR-082, E66-S3). Deploy execution is delegated to a configured adapter that conforms to the ADR-078 contract (`adapter.json`, `run.sh`, `test/contract.bats`). The reference deploy adapter is `script-deploy` — generic enough to wrap any user-supplied deploy script, while keeping the adapter contract clean.

Pattern A invariants:

- **Sequential execution** — phases run in strict order, no parallelism (AC7).
- **Transparency** — every phase emits a structured status message in conversation (AC8).
- **Environment isolation** — exactly one `--env` per invocation, no fan-out (AC9). `--env` is mandatory with no default.
- **Failure-halts** — a non-zero exit at any phase halts subsequent phases immediately. The skill MAY suggest `/gaia-rollback-plan` in conversation but MUST NOT invoke it (AC11).
- **Credentials via env-var names only** — never inline values, never file paths, never interactive prompts. Missing env-var → BLOCKED with the expected name in the diagnostic (AC10, NFR-RSV2-7).

## Critical Rules

- The `composite-verdict-aggregator.sh` foundation (E66-S3) MUST be present at `plugins/gaia/scripts/review-common/composite-verdict-aggregator.sh`. If absent, the pre-deploy gate emits BLOCKED with an installation hint.
- The configured deploy adapter MUST resolve to an executable `run.sh` under `plugins/gaia/scripts/adapters/<adapter>/`. Missing adapter → BLOCKED with installation guidance (AC13).
- The skill operates in `context: main` (not fork) because it writes evidence files and orchestrates Skill-tool calls to the smoke action skills. The fork pattern used by review skills does not apply here.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- This skill is the only orchestrator allowed to invoke E73-S1..S4 action skills (`gaia-test-e2e`, `gaia-test-perf`, `gaia-test-dast`, `gaia-test-a11y`) as **deployment-phase smoke**. Each action skill runs its own Phase 3A/3B pipeline independently against the target environment URL.

## CLI Flags

| Flag | Required | Description |
|---|---|---|
| `--env <env>` | yes | Target environment (e.g., `staging`, `production`). No default. |
| `--version <ver>` | yes | Version tag / artifact identifier passed to the deploy adapter. |
| `--skip-smoke` | no | Skip the post-deploy smoke phase. Final verdict is `PASSED` (deploy-only) with a `WARNING` recorded in the report (AC14). |
| `--story-key <key>` | no | Story key for the pre-deploy composite-verdict gate. Story-less deployment-phase invocation is supported but skips Review Gate context. |

## Phases

### Phase 1 — Pre-deploy gate

Invoke `scripts/pre-deploy-gate.sh --story-key <key>`. The script reads the composite verdict via `composite-verdict-aggregator.sh` (or the test-seam fixture file `GAIA_DEPLOY_COMPOSITE_FILE`).

- `composite == "APPROVE"` → proceed to Phase 2.
- Anything else → emit `BLOCKED` with the failing review names and exit 1.

The skill MUST NOT proceed to deploy when the composite is not APPROVE. There is no override flag.

### Phase 2 — Deploy adapter dispatch

Invoke `scripts/deploy-dispatch.sh --env <env> --version <ver> --output-dir evidence/deploy/`. The script:

1. Resolves the adapter from `deployment.adapter` config (test seam: `GAIA_DEPLOY_ADAPTER_CMD`).
2. Runs the three-state availability probe (`tool-availability-probe.sh`) — `unavailable` → BLOCKED with installation instructions.
3. Invokes the adapter's `run.sh` once (no retry per AC11). Captures stdout/stderr to `evidence/deploy/`.
4. Non-zero adapter exit → BLOCKED with diagnostic; mentions `/gaia-rollback-plan` in conversation but does not invoke it.

### Phase 3 — Health-check

Invoke `scripts/health-check.sh --mode <poll|skip> --url <url> --timeout <secs> --output-dir evidence/deploy/`. Behavior is driven by `health_check.mode` in project-config.yaml (default `poll` — backward-compatible per FR-425, E78-S3):

- `mode: poll` (default) — polls the target URL with exponential backoff (2s initial, capped at 10s) until HTTP 2xx or timeout. Writes `evidence/deploy/health-check.json` with `status`, `attempts`, `duration_seconds`. Timeout → BLOCKED with remediation guidance (AC4).
- `mode: skip` — bypasses the poll loop entirely. Writes `evidence/deploy/health-check.json` with `{status: "skipped", mode: "skip", reason: "configured skip"}` so the audit trail records that the skip was intentional. Use this for projects without a reachable health-check endpoint (e.g., marketplace-published plugins).

Any other value rejected at config-load time with an actionable error listing the valid options. Schema enforcement (FR-425, AC5) lives in `project-config.schema.json` under `definitions.healthCheck`.

### Phase 4 — Post-deploy smoke

Invoke `scripts/smoke-orchestrate.sh --suites-file <path> --target-url <url> --output-dir evidence/smoke/`. Suites declared in `deployment.smoke_suites[]` are invoked in **declared order** against the deployed environment URL (AC5, AC7). Each suite returns a verdict (APPROVE | REQUEST_CHANGES | BLOCKED) recorded in `evidence/smoke/<suite>.json`.

`--skip-smoke` short-circuits this phase, emits a `WARNING`, and writes `_skip-smoke.json` to evidence (AC14).

**Empty `smoke_suites` / manual-checklist mode (E78-S5, FR-427):** When the resolved deployment configuration provides no smoke suites — either `deployment.smoke_suites: []` or `distribution.channels[].smoke_test.mode: manual-checklist` — the smoke phase MUST NOT yield BLOCKED. `smoke-orchestrate.sh` detects two equivalent paths:

- An empty `--suites-file` (zero non-blank, non-comment lines), or
- An explicit `--mode manual-checklist` flag.

In either case the script writes `evidence/smoke/manual-checklist.json` with verdict `APPROVE` plus metadata (`mode`, `checklist_source`, `tester_acknowledgement`, `created_at` ISO-8601) and exits 0. Pass `--checklist-source <path>` to record the manual checklist document path; defaults to `"none"`. Use this path for plugins published to a marketplace where automated smoke suites are not applicable but a human signs off on a manual checklist.

The default smoke runner invokes the matching action skill via the Skill tool. Test seam: `GAIA_DEPLOY_SMOKE_RUNNER` overrides the runner with a script that takes `<suite> <target-url> <output-dir>` and prints the verdict.

### Phase 5 — Final verdict

Invoke `scripts/verdict-aggregate.sh --evidence-dir evidence/ --env <env> --version <ver> [--skip-smoke]`. Aggregation rules (AC6):

- Any suite verdict ∈ `{BLOCKED, REQUEST_CHANGES}` → final `FAILED`.
- All suite verdicts `APPROVE` → final `PASSED`.
- `--skip-smoke` set → final `PASSED` with `skip_smoke: true` in the report.

Writes `evidence/deployment-report.json` with `environment`, `version`, `timestamp`, `final_verdict`, `skip_smoke`, `suites[]`. Echoes the verdict on stdout.

After verdict aggregation, the lifecycle hook `scripts/finalize.sh` writes a checkpoint and emits a `workflow_complete` lifecycle event.

## Credential Handling (AC10)

Before invoking the deploy adapter or smoke runners, run `scripts/check-credentials.sh --env-var <NAME> [--env-var <NAME> ...]` for every credential env-var declared under `environments.<env>.auth.credentials_env`. Missing → BLOCKED with the expected env-var name. Credentials are passed by **name** to downstream scripts; the deploy adapter and smoke runners read the env-var from their own environment.

## Output Contract

Evidence directory layout (relative to invocation cwd):

```
evidence/
├── deploy/
│   ├── deploy.stdout
│   ├── deploy.stderr
│   └── health-check.json
├── smoke/
│   ├── <suite-name>.json
│   └── _skip-smoke.json     (only when --skip-smoke)
└── deployment-report.json
```

The final verdict (`PASSED` | `FAILED`) is emitted on stdout by `verdict-aggregate.sh`.

## Refs

- ADR-077 — Three-tier review pipeline (deployment-phase action skills).
- ADR-078 — Tool adapter framework (`adapter.json`, `run.sh`, `test/contract.bats`, four-state probe).
- ADR-080 — Deployment-Phase Pattern A (claude-driven, sequential, transparent, no-retry, no-rollback).
- ADR-082 — Composite Review Verdict GATING (composite-verdict-aggregator.sh).
- FR-RSV2-31, FR-RSV2-33, NFR-RSV2-7 — `/gaia-deploy` PRD requirements.
- E66-S3, E73-S1, E73-S2, E73-S3, E73-S4 — upstream foundations.
