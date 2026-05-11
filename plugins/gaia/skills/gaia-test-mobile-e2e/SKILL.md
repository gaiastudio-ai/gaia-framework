---
name: gaia-test-mobile-e2e
description: Execute mobile end-to-end tests via the configured device-farm adapter (Firebase Test Lab, BrowserStack, Sauce Labs). Resolves the adapter from project-config.yaml, dispatches the suite, and returns per-device verdicts plus a composite verdict. Use when "run mobile e2e" or /gaia-test-mobile-e2e.
argument-hint: "[--suite <path>] [--device <id>] [--config <path>]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
runtime-profile: network
adapters: [firebase-test-lab, browserstack, sauce-labs]
triggers:
  - run mobile e2e
  - test mobile e2e
  - mobile end-to-end
  - /gaia-test-mobile-e2e
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-mobile-e2e/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill (FR-DEJ-1, ADR-077). For `/gaia-test-mobile-e2e` the configured device-farm adapter runs in Phase 3A and the upstream `dispatch-device-farm.sh` emits a structured `analysis-results.json` artifact (validating against `plugins/gaia/schemas/analysis-results.schema.json`). The LLM never computes the verdict — `plugins/gaia/scripts/review-common/verdict-resolver.sh` consumes the analysis output (plus any LLM findings from the optional Phase 3B fork) and emits APPROVE | REQUEST_CHANGES | BLOCKED. Adapter availability is gated by `plugins/gaia/scripts/tool-availability-probe.sh`, whose four-state classification maps `expected_and_missing` and `ran_and_errored` to BLOCKED — never to a false APPROVE.

`/gaia-test-mobile-e2e` is the deployment-phase action skill that runs a mobile end-to-end test suite against a real-device cloud (Firebase Test Lab, BrowserStack, or Sauce Labs). The skill:

1. Resolves the configured device-farm adapter from `device_farm.adapter` in `config/project-config.yaml`.
2. Validates the bridge toggle (`test_execution_bridge.bridge_enabled`) — short-circuits with `verdict: SKIPPED` if the bridge is disabled.
3. Dispatches the suite via `plugins/gaia/scripts/dispatch-device-farm.sh` (E74-S9), which honours `runtime-profile: network` and validates the adapter's `auth_env_var`.
4. Normalizes the adapter output into the canonical per-device schema (`device_id`, `os_version`, `form_factor`, `verdict`, `duration_ms`, `artifacts`).
5. Computes a composite verdict (PASSED | FAILED | ERROR | TIMEOUT | SKIPPED) using priority FAILED > ERROR > TIMEOUT > PASSED.

This skill is a sibling of `/gaia-test-device-matrix` — that skill expands a configured device matrix and dispatches each entry; this skill dispatches a single test suite to whatever device set the farm is configured to use.

## Critical Rules

- A device-farm adapter MUST be configured in `project-config.yaml`. Missing adapter yields `verdict: ERROR` with guidance pointing at `/gaia-config-device-target`.
- `runtime-profile: network` declaration MUST be honoured — the adapter is allowed to make external API calls, and the bridge toggle gates the dispatch.
- `auth_env_var` validation is delegated to `dispatch-device-farm.sh` (E74-S9). This skill does not handle credentials directly.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Phases

### Phase 1 — Resolve adapter

`scripts/dispatch.sh` reads `device_farm.adapter` from the resolved project config. If unset or empty, the skill emits `{"verdict":"ERROR", ...}` and exits non-zero.

### Phase 2 — Bridge toggle

If `test_execution_bridge.bridge_enabled` is `false`, the skill short-circuits with `{"verdict":"SKIPPED", "reason":"bridge_disabled"}` and exits 0. Diagnostic message guides the user to `/gaia-bridge-enable`.

### Phase 3 — Dispatch

The skill shells out to `plugins/gaia/scripts/dispatch-device-farm.sh --adapter <name> --suite <path> --device-matrix <path>`. The dispatcher honours `GAIA_OFFLINE` and `auth_env_var` and emits canonical adapter output.

### Phase 4 — Normalize per-device output

The dispatcher's `per_device_results[]` (with adapter-specific fields) is mapped into the canonical schema:

| Field | Type | Notes |
|---|---|---|
| `device_id` | string | adapter-specific identifier |
| `os_version` | string | e.g. "14", "13.5" |
| `form_factor` | string | one of `phone`, `tablet`, `watch` |
| `verdict` | enum | `PASSED` \| `FAILED` \| `ERROR` \| `TIMEOUT` |
| `duration_ms` | number | total elapsed time in milliseconds |
| `artifacts` | array | optional URLs (screenshots, logs) |

### Phase 5 — Composite verdict

The composite verdict is computed by `plugins/gaia/scripts/composite-verdict.sh` with priority:

1. Any device `FAILED` → composite `FAILED`.
2. No `FAILED` and any `ERROR` → composite `ERROR`.
3. No `FAILED`, no `ERROR`, and any `TIMEOUT` → composite `TIMEOUT`.
4. All `PASSED` → composite `PASSED`.

The composite verdict is the skill's top-level `verdict` field. Summary counts (`passed_count`, `failed_count`, `error_count`, `timeout_count`) are emitted alongside.

## Output Contract

Single JSON object on stdout:

```json
{
  "skill": "gaia-test-mobile-e2e",
  "adapter": "firebase-test-lab",
  "verdict": "PASSED",
  "passed_count": 2,
  "failed_count": 0,
  "error_count": 0,
  "timeout_count": 0,
  "per_device_results": [...]
}
```

## Refs

- ADR-080 — Deployment-phase action skill pattern.
- ADR-081 — Mobile-as-Platform Extension.
- E74-S9 — Mobile dynamic + device-farm adapter dispatch (upstream).
- E73-S5 — Action-skill dispatch infrastructure (upstream).
- FR-RSV2-42, FR-RSV2-43, NFR-RSV2-8 — `/gaia-test-mobile-e2e` PRD requirements.
