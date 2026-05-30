---
name: gaia-test-dast
description: Execute post-deploy dynamic application security tests via the OWASP ZAP DAST adapter under the ADR-078 contract. Phase 3A toolkit + Phase 3B LLM judgment + verdict resolver. Subprocess env is scrubbed to a per-adapter env-allowlist per T-RSV2-1 mitigation. Use when "run dast tests" or /gaia-test-dast.
argument-hint: "[story-key] [--adapter <name>] [--target-url <url>] [--profile baseline|full|api]"
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
adapters: [owasp-zap]
triggers:
  - run dast tests
  - test dast
  - dynamic security test
  - post-deploy dast
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-dast/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill (FR-DEJ-1, ADR-075). For `/gaia-test-dast` it means: the configured DAST adapter (OWASP ZAP by default, swappable via `test_execution.dast.adapter` config or `--adapter` CLI flag) runs in Phase 3A and emits a structured `analysis-results.json` artifact. The LLM then performs a DAST severity-triage semantic judgment in Phase 3B — applying the project risk profile to ZAP findings — but cannot override a deterministic adapter failure or High-severity finding. The verdict is computed by `verdict-resolver.sh`; the LLM never computes the verdict in natural language.

This skill is a deployment-phase action skill (ADR-080) and a peer of `/gaia-test-e2e` (E73-S1) and `/gaia-test-perf` (E73-S2) — same Phase 3A/3B/3C plumbing, DAST-specific rubric and env-allowlist credential isolation.

**Static vs dynamic distinction:** `/gaia-review-security` (E66 scope, static, pre-merge) reads code and finds OWASP-Top-10 patterns. `/gaia-test-dast` (this skill, dynamic, deployment-phase) runs OWASP ZAP against a live deployed endpoint. They are complementary, not alternatives.

**Fork context semantics (NFR-RSV2-5):** Phase 3B LLM judgment runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). Phase 3A is deterministic shell. Phase 4 verdict resolution and Review Gate update happen in the parent context via `verdict.sh` + `finalize.sh`.

**Adapter swappability:** Resolved by `select-adapter.sh` with first-match-wins precedence: `--adapter <name>` CLI flag → `test_execution.dast.adapter` from `.gaia/config/project-config.yaml` → default `owasp-zap`.

**Graceful degradation:** When `tool-availability-probe.sh` returns `expected_and_missing` (zap-cli not on PATH), Phase 3A emits a `checks[].status: errored` row with a diagnostic `error_reason` naming the missing tool and installation hint. `verdict-resolver.sh` maps this to BLOCKED — never to a false APPROVE.

## Critical Rules

- A story key argument MAY be provided. If absent, the deployment-phase invocation runs in story-less mode and skips the Review Gate update step.
- The `tool-availability-probe.sh` foundation script (E66-S2) MUST be present at `plugins/gaia/scripts/tool-availability-probe.sh`.
- The `verdict-resolver.sh` foundation script (E66-S1) MUST be present at `plugins/gaia/scripts/verdict-resolver.sh`.
- This skill is READ-ONLY in the fork (Phase 3B). Phase 4 `verdict.sh` runs in main context with Bash + the explicit narrow tool set required by `review-gate.sh`.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (per FR-RSV2-3): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Adapter `run.sh` invocation MUST go through `tool-availability-probe.sh` first — the probe's three-state classification is the authoritative gate.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- The adapter subprocess env is scrubbed to the per-adapter env-allowlist declared in `adapter.json` (T-RSV2-1). Adding entries to that allowlist requires a security review (see `## Secret Handling`).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in analysis-results.json
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce LLM findings that match by `{category, severity}` (NFR-DEJ-2). Textual message variation is allowed.

## Configuration Schema

Project-config block consumed by this skill (`.gaia/config/project-config.yaml`):

```yaml
test_execution:
  dast:
    adapter: owasp-zap          # owasp-zap   (default: owasp-zap)
  deployment:
    dast_test:
      profile: baseline           # baseline | full | api
      target_url: https://staging.example.com
      timeout_seconds: 600
```

## Secret Handling

The OWASP ZAP DAST adapter operates against live deployed environments — credential leakage through subprocess environment inheritance is the highest-priority threat for this skill (threat T-RSV2-1, "DAST tooling surface"). The adapter contract enforces a strict per-adapter env-allowlist that is the single source of truth for which environment variables are permitted to cross the parent → ZAP subprocess boundary.

### env-allowlist contract (T-RSV2-1 mitigation)

The OWASP ZAP adapter declares an `env-allowlist` field in `plugins/gaia/scripts/adapters/owasp-zap/adapter.json`. The allowlist is the exhaustive list of environment variables that `run.sh` will forward to the ZAP subprocess. Every other parent-process env var is scrubbed.

Permitted env vars (current allowlist):

| Variable        | Purpose                                                   |
|-----------------|-----------------------------------------------------------|
| `PATH`          | Locate the `zap-cli` binary (operationally required).     |
| `HOME`          | Resolve `$HOME` for ZAP's session storage.                |
| `TARGET_URL`    | Base URL under test. Public endpoint, not a secret.       |
| `ZAP_API_KEY`   | OWASP ZAP API key for daemon mode (secret).               |
| `ZAP_HOME`      | Override ZAP's session/working directory.                 |
| `ZAP_PROXY_HOST`| Outbound proxy host (e.g., for traffic capture).          |
| `ZAP_PROXY_PORT`| Outbound proxy port.                                      |
| `ZAP_PROFILE`   | Optional profile override consumed by custom ZAP scripts. |

### Scrubbing mechanism

`run.sh` invokes the ZAP subprocess via `env -i` (clear environment) followed by an explicit passthrough argv constructed from the allowlist read from `adapter.json`. The mechanism is:

```sh
env -i PATH="$PATH" HOME="$HOME" \
       ZAP_API_KEY="${ZAP_API_KEY:-}" \
       TARGET_URL="$TARGET_URL" \
       ZAP_HOME="${ZAP_HOME:-}" \
       zap-cli ...
```

(The actual `run.sh` builds the argv dynamically from `adapter.json` so the scrubbing list cannot drift away from the declared contract.) Any env var that is NOT in `env-allowlist` — including but not limited to `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `OPENAI_API_KEY`, generic `SECRET_KEY` — is absent from the subprocess environment.

### CI runner-level scrubbing

CI runners that invoke `/gaia-test-dast` MUST also enable per-job secret scrubbing on adapter logs. The adapter's stdout / stderr are captured into `evidence/owasp-zap.stdout` and `evidence/owasp-zap.stderr` and any subsequent log forwarding (e.g., to a CI artifact store) MUST run those streams through the runner's secret-redaction filter. Runner-level scrubbing complements (not replaces) the env-allowlist — env-allowlist prevents leakage at the subprocess boundary, runner scrubbing prevents leakage in archived logs.

### Security-review requirement for allowlist changes

Adding an entry to `adapter.json`'s `env-allowlist` requires a security review. The review MUST justify why the new variable is necessary, confirm the variable is needed by ZAP (not merely "convenient" for an unrelated tool), and document any rotation / least-privilege controls. This is recorded in the threat model (T-RSV2-1) and tracked through normal `/gaia-add-feature` cascade review for changes to `adapter.json`.

## Phases

### Phase 1 — Resolve adapter (config)

Invoke `scripts/select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]`. The script emits the absolute adapter directory path on stdout. Abort the run with an actionable diagnostic if the resolved adapter directory is missing.

### Phase 2 — Availability probe + Phase 3A toolkit (evidence collection)

Invoke `scripts/phase3a-collect.sh --adapter-dir <path> --output-dir <dir> [--target-url <url>] [--config <path>] [--story-key <key>]`. The script:

1. Calls `tool-availability-probe.sh --adapter-dir <path> --file-list <synthetic>` to classify availability.
2. If `available`, invokes the adapter's `run.sh` to execute the ZAP scan, capturing stdout/stderr to `evidence/`.
3. Writes a top-level `analysis-results.json` with `checks[0]` reflecting the adapter outcome.

Probe state to `checks[].status` mapping:

| Probe state             | check.status | Verdict resolver maps to |
|-------------------------|--------------|--------------------------|
| `available` (run.sh exit 0) | `passed`   | APPROVE eligible         |
| `available` but run.sh exit ≠ 0 | `errored` | BLOCKED              |
| `expected_and_missing`  | `errored` (with diagnostic) | BLOCKED      |
| `ran_and_errored`       | `errored` (with diagnostic) | BLOCKED      |
| `not_applicable`        | `skipped`    | non-blocking             |

### Phase 3B — LLM judgment (forked context)

Persona resolved via `agent-overlay.sh --skill gaia-test-dast` → `sable` (Test Architect). The fork loads `knowledge/dast-rubric.md` and produces `llm-findings.json` covering:

- **Severity triage** — interpretation of ZAP alerts against the project's risk profile.
- **False-positive screening** — explicit "no actionable findings" when ZAP reports only Informational alerts.
- **Coverage gaps** — flagged when the ZAP scan profile (baseline / full / api) does not cover all declared endpoints.
- **Compliance impact** — mapping High-severity findings to OWASP Top 10 categories and applicable compliance frameworks.

The fork is read-only; the parent context writes `llm-findings.json` to the output directory.

### Phase 4 — Verdict resolution + Review Gate update

Invoke `scripts/verdict.sh --analysis-results <path> --llm-findings <path> [--story-key <key>] [--gate "Security Review"]`. The script:

1. Calls `verdict-resolver.sh --skill gaia-test-dast` to compute the verdict (precedence per ADR-075: errored > tool-failed-blocking > LLM-Critical > APPROVE).
2. When `--story-key` and `--gate` are provided, invokes `review-gate.sh update` to update the matching Review Gate row to PASSED (APPROVE) or FAILED (REQUEST_CHANGES, BLOCKED). Deployment-phase invocations without an associated story skip this step.
3. Echoes the verdict on stdout for downstream chaining.

### Phase 5 — Report generation

After verdict resolution, the lifecycle hook `scripts/finalize.sh` writes a checkpoint, emits a `workflow_complete` lifecycle event, and (when an output directory was configured) renders a human-readable Markdown report alongside `analysis-results.json` summarizing findings by severity.

## Severity Rubric

> See `knowledge/dast-rubric.md` for the full per-tier rubric. Categories: dast.runtime-vuln, dast.config, dast.compliance, dast.coverage. Severity tiers: Critical, High, Medium, Suggestion.

## Adapters

This skill ships with one DAST adapter under `plugins/gaia/scripts/adapters/`:

- **`owasp-zap/`** — invokes `zap-cli quick-scan` against the target URL. Default. The subprocess env is scrubbed to the env-allowlist declared in `adapter.json` per T-RSV2-1.

The adapter honours the canonical ADR-078 contract (`adapter.json`, `run.sh`, `test/contract.bats`) PLUS the deployment-phase additive flags `--target-url <url>` and `--profile baseline|full|api`.

## Output Contract

The skill emits two JSON files in the configured output directory:

- `analysis-results.json` — Phase 3A artifact, canonical schema (`plugins/gaia/schemas/analysis-results.schema.json`).
- `llm-findings.json` — Phase 3B artifact, schema-compatible with the verdict resolver's `--llm-findings` input.

The verdict (APPROVE | REQUEST_CHANGES | BLOCKED) is emitted on stdout by `verdict.sh`.

## Refs

- ADR-075 — Review skill evidence/judgment split.
- ADR-077 — Three-tier review pipeline (seven-phase structure).
- ADR-078 — Tool adapter framework (`adapter.json` schema, `run.sh` contract, four-state probe).
- ADR-080 — Deployment-phase action skill pattern.
- FR-RSV2-31 — Deployment-phase DAST execution.
- FR-RSV2-33 — Per-adapter env-allowlist contract.
- NFR-RSV2-7 — Env-var-only credentials.
- T-RSV2-1 — DAST tooling surface threat (mitigated by env-allowlist).
- E66-S1, E66-S2, E70-S1 — upstream foundations.
- E73-S1, E73-S2 — peer deployment-phase action skills.
