---
name: gaia-deploy
description: Pattern A deployment orchestrator — composite pre-deploy gate → adapter-mediated deploy → health-check → post-deploy smoke → final verdict. Sequential, transparent, no auto-retry, no auto-rollback. Use when "deploy this version" or /gaia-deploy.
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-deploy/scripts/setup.sh

## Mission

`/gaia-deploy` orchestrates a five-phase deployment pipeline: **pre-deploy gate → deploy → health-check → post-deploy smoke → final verdict**. The skill is the reference implementation of **Pattern A** — claude-driven, sequential, transparent, adapter-mediated, environment-isolated, with **no auto-retry and no auto-rollback**.

Pre-deploy gating is delegated to `composite-verdict-aggregator.sh`. Deploy execution is delegated to a configured adapter that conforms to the tool adapter contract (`adapter.json`, `run.sh`, `test/contract.bats`). The reference deploy adapter is `script-deploy` — generic enough to wrap any user-supplied deploy script, while keeping the adapter contract clean.

Pattern A invariants:

- **Sequential execution** — phases run in strict order, no parallelism (AC7).
- **Transparency** — every phase emits a structured status message in conversation (AC8).
- **Environment isolation** — exactly one `--env` per invocation, no fan-out (AC9). `--env` is mandatory with no default.
- **Failure-halts** — a non-zero exit at any phase halts subsequent phases immediately. The skill MAY suggest `/gaia-rollback-plan` in conversation but MUST NOT invoke it (AC11).
- **Credentials via env-var names only** — never inline values, never file paths, never interactive prompts. Missing env-var → BLOCKED with the expected name in the diagnostic (AC10).

## Critical Rules

- The `composite-verdict-aggregator.sh` foundation MUST be present at `plugins/gaia/scripts/review-common/composite-verdict-aggregator.sh`. If absent, the pre-deploy gate emits BLOCKED with an installation hint.
- The configured deploy adapter MUST resolve to an executable `run.sh` under `plugins/gaia/scripts/adapters/<adapter>/`. Missing adapter → BLOCKED with installation guidance (AC13).
- The skill operates in `context: main` (not fork) because it writes evidence files and orchestrates Skill-tool calls to the smoke action skills. The fork pattern used by review skills does not apply here.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- This skill is the only orchestrator allowed to invoke the action skills (`gaia-test-e2e`, `gaia-test-perf`, `gaia-test-dast`, `gaia-test-a11y`) as **deployment-phase smoke**. Each action skill runs its own Phase 3A/3B pipeline independently against the target environment URL.
- **`environments[].kind` gate.** BEFORE any deploy phase runs, source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-env-kind.sh` and call `gaia_resolve_env_kind <project-config.yaml> <env-id>`. If the resolved kind is NOT `deployable`, HALT non-zero with the canonical stderr text: `environment '<env-id>' is kind: <kind> — use /gaia-publish instead`. No deploy step runs; no partial mutation of any artifact. The resolver applies the silent default (`deployable`) when `kind:` is absent, so legacy configs proceed unchanged.

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

Invoke `scripts/health-check.sh --mode <poll|skip> --url <url> --timeout <secs> --output-dir evidence/deploy/`. Behavior is driven by `health_check.mode` in project-config.yaml (default `poll` — backward-compatible):

- `mode: poll` (default) — polls the target URL with exponential backoff (2s initial, capped at 10s) until HTTP 2xx or timeout. Writes `evidence/deploy/health-check.json` with `status`, `attempts`, `duration_seconds`. Timeout → BLOCKED with remediation guidance (AC4).
- `mode: skip` — bypasses the poll loop entirely. Writes `evidence/deploy/health-check.json` with `{status: "skipped", mode: "skip", reason: "configured skip"}` so the audit trail records that the skip was intentional. Use this for projects without a reachable health-check endpoint (e.g., marketplace-published plugins).

Any other value rejected at config-load time with an actionable error listing the valid options. Schema enforcement (AC5) lives in `project-config.schema.json` under `definitions.healthCheck`.

### Phase 4 — Post-deploy smoke

Invoke `scripts/smoke-orchestrate.sh --suites-file <path> --target-url <url> --output-dir evidence/smoke/`. Suites declared in `deployment.smoke_suites[]` are invoked in **declared order** against the deployed environment URL (AC5, AC7). Each suite returns a verdict (APPROVE | REQUEST_CHANGES | BLOCKED) recorded in `evidence/smoke/<suite>.json`.

`--skip-smoke` short-circuits this phase, emits a `WARNING`, and writes `_skip-smoke.json` to evidence (AC14).

**Empty `smoke_suites` / manual-checklist mode:** When the resolved deployment configuration provides no smoke suites — either `deployment.smoke_suites: []` or `distribution.channels[].smoke_test.mode: manual-checklist` — the smoke phase MUST NOT yield BLOCKED. `smoke-orchestrate.sh` detects two equivalent paths:

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

> **Gitignore note:** The promotion trigger writes evidence to `.gaia/evidence/deploy/<env>/`. Projects initialised with `/gaia-init` automatically ignore `.gaia/evidence/` via the seeded `.gitignore`. Existing projects should add `.gaia/evidence/` to their `.gitignore` to avoid accidentally committing ephemeral deploy evidence.

## Affected-set data contract

The deploy workflow consumes an **affected-set** that names which stacks
(components) changed in a given CI run. This section documents the schema,
resolution channels, and fallback chain that governs how the affected-set
reaches the deploy pipeline.

### CI artifact (primary channel)

The selective-test pipeline's `plan` job writes a JSON file and uploads it
as a GitHub Actions artifact named **`affected-set`**. The file is named
`affected-set.json` and conforms to this schema:

```json
{
  "stacks": ["<stack-name>", ...]
}
```

Rules:

- `stacks` is a JSON array of strings. Each string is a stack name declared
  in `project-config.yaml` under `stacks[].name`.
- The wildcard sentinel `["*"]` means "all stacks" (full deploy).
- An empty array `[]` means "no stacks affected" (docs-only change; no
  deploy needed).

Example — selective:
```json
{"stacks":["api","web"]}
```

Example — full deploy (escalation):
```json
{"stacks":["*"]}
```

Example — docs-only (no deploy):
```json
{"stacks":[]}
```

### Commit trailer (secondary channel)

When the CI artifact is unavailable (manual deploy, workflow re-run, or
cross-workflow trigger), the resolver falls back to parsing a commit trailer
from the HEAD commit message. Two trailer names are accepted:

```
Affected-Set: ["api","worker"]
Affected-Components: ["web"]
```

The trailer value must be a JSON array of stack-name strings. The resolver
reads the first matching trailer (`Affected-Set` preferred, then
`Affected-Components`). Invalid or absent trailers cause the resolver to
fall through to the safety net.

### Full-deploy safety net (fallback)

When neither the CI artifact nor a commit trailer is available, the resolver
emits the **full-deploy sentinel** — every component deploys. This guarantees
that the deploy pipeline **never silently deploys nothing**.

When `--config` points to a valid `project-config.yaml`, the resolver
enumerates all `stacks[].name` entries from the config. Without a config, it
emits the wildcard sentinel `["*"]`.

### Resolver output

`plugins/gaia/scripts/resolve-affected-set.sh` implements the three-tier
fallback chain. Its output is a JSON object on stdout:

```json
{"stacks":["api","web"],"channel":"ci-artifact"}
```

The `channel` field names which resolution tier succeeded:
`ci-artifact`, `commit-trailer`, or `full-deploy`. Consumers can log
this value for observability without parsing the resolution logic themselves.

### Wiring seam

The promotion-trigger workflow (deploy pipeline) downloads the `affected-set`
artifact and passes its path to `resolve-affected-set.sh --artifact <path>`.
If the download step fails (artifact expired, manual trigger), the resolver
transparently falls through to the commit-trailer and full-deploy tiers.

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
lead routes this skill through Mode B, the deployment subagent (gaia:devops) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:devops" "gaia-deploy"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
