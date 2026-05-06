---
name: gaia-test-device-matrix
description: Expand a configured device-target matrix (os_versions × form_factors × screen_sizes) and dispatch each entry to the configured device-farm adapter. Returns per-device verdicts plus a composite verdict. Use when "run device matrix" or /gaia-test-device-matrix.
argument-hint: "[--platform <ios|android|all>] [--filter <regex>] [--config <path>]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
runtime-profile: network
adapters: [firebase-test-lab, browserstack, sauce-labs]
triggers:
  - run device matrix
  - test device matrix
  - device matrix
  - /gaia-test-device-matrix
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-device-matrix/scripts/setup.sh

## Mission

`/gaia-test-device-matrix` is the deployment-phase action skill that expands a configured device matrix and dispatches each entry to the configured device-farm adapter. The skill:

1. Reads `device_targets` from `config/project-config.yaml` — `os_versions`, `form_factors`, `screen_sizes`.
2. Computes the cartesian product of these axes via `scripts/expand-matrix.sh`.
3. Filters the matrix by `--platform` (when provided) and `--filter` (regex).
4. Dispatches each expanded entry through the device-farm adapter (sequential by default; parallel if the adapter advertises `parallel_dispatch: true`).
5. Aggregates per-device verdicts via the shared `composite-verdict.sh` helper (FAILED > ERROR > TIMEOUT > PASSED priority).

This skill is a sibling of `/gaia-test-mobile-e2e` — that skill dispatches a single suite to whatever device set the farm is configured to use; this skill explicitly enumerates and dispatches each device matrix entry.

## Critical Rules

- A device-farm adapter MUST be configured. Missing adapter yields `verdict: ERROR`.
- `runtime-profile: network` declaration MUST be honoured. Bridge-disabled short-circuits with `verdict: SKIPPED`.
- Matrix expansion uses cartesian product semantics: `|os_versions| × |form_factors| × |screen_sizes|`. Empty axes are treated as `["default"]` (1-element).
- The skill never writes sprint-status.yaml.

## Phases

### Phase 1 — Expand matrix

`scripts/expand-matrix.sh --config <path>` reads `device_targets` and emits a JSON array of expanded device entries. Each entry contains `os_version`, `form_factor`, `screen_size`. The entry count equals the cartesian product of the three axes.

### Phase 2 — Dispatch

`scripts/dispatch.sh` iterates over the expanded matrix and calls the upstream `dispatch-device-farm.sh` for each entry. Composite verdict aggregation follows.

### Phase 3 — Composite verdict

Shared with `/gaia-test-mobile-e2e` via `plugins/gaia/scripts/composite-verdict.sh`:

- Any `FAILED` → composite `FAILED`.
- Any `ERROR` (no `FAILED`) → composite `ERROR`.
- Any `TIMEOUT` (no `FAILED`/`ERROR`) → composite `TIMEOUT`.
- All `PASSED` → composite `PASSED`.

## Output Contract

```json
{
  "skill": "gaia-test-device-matrix",
  "adapter": "firebase-test-lab",
  "verdict": "PASSED",
  "passed_count": 4,
  "failed_count": 0,
  "error_count": 0,
  "timeout_count": 0,
  "per_device_results": [...]
}
```

## Refs

- ADR-080 — Deployment-phase action skill pattern.
- ADR-081 — Mobile-as-Platform Extension.
- E74-S9 — Device-farm dispatch (upstream).
- E74-S10 — `/gaia-test-mobile-e2e` (peer).
- FR-RSV2-42, FR-RSV2-43, NFR-RSV2-8 — PRD requirements.
