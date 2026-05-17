---
name: gaia-test-device-matrix
description: Expand a configured device-target matrix (os_versions × form_factors × screen_sizes) and dispatch each entry to the configured device-farm adapter. Returns per-device verdicts plus a composite verdict. Use when "run device matrix" or /gaia-test-device-matrix.
argument-hint: "[--platform <ios|android|all>] [--filter <regex>] [--config <path>]"
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
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-device-matrix/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill (FR-DEJ-1, ADR-077). For `/gaia-test-device-matrix` the upstream `dispatch-device-farm.sh` emits a structured `analysis-results.json` artifact (validating against `plugins/gaia/schemas/analysis-results.schema.json`). The LLM never computes the verdict — `plugins/gaia/scripts/review-common/verdict-resolver.sh` consumes the analysis output, and adapter availability is gated by `plugins/gaia/scripts/tool-availability-probe.sh` (four-state classification; missing CLI maps to BLOCKED).

`/gaia-test-device-matrix` is the deployment-phase action skill that expands a configured device matrix and dispatches each entry to the configured device-farm adapter. The skill:

1. Reads `device_targets` from `config/project-config.yaml` — `os_versions`, `form_factors`, `screen_sizes`.
2. Computes the cartesian product of these axes via `scripts/expand-matrix.sh`.
3. Filters the matrix by `--platform` (when provided) and `--filter` (regex).
4. Dispatches each expanded entry through the device-farm adapter (sequential by default; parallel if the adapter advertises `parallel_dispatch: true`).
5. Aggregates per-device verdicts via the shared `composite-verdict.sh` helper (FAILED > ERROR > TIMEOUT > PASSED priority).

This skill is a sibling of `/gaia-test-mobile-e2e` — that skill dispatches a single suite to whatever device set the farm is configured to use; this skill explicitly enumerates and dispatches each device matrix entry.

## Critical Rules

- A device-farm adapter MUST be configured in `project-config.yaml` at `device_farm.adapter` — one of `firebase-test-lab | browserstack | sauce-labs`. Missing adapter yields `verdict: ERROR`. **No `/gaia-config-*` skill currently edits `device_farm.adapter`** (AF-2026-05-17-10); users must edit the YAML directly. `/gaia-config-device-target` is unrelated — it scopes to the `device_targets` section, not adapter selection.
- A defense-in-depth `platforms[]`-mobile gate fires at the top of `scripts/dispatch.sh` (AF-2026-05-17-10): if neither `ios` nor `android` appears in `platforms[]`, the skill exits SKIPPED with reason `no_mobile_platform` (mirrors AF-2026-05-17-9 family-invariant gating for the mobile family).
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
