---
name: gaia-tool-info
description: Render full `adapter.json` metadata for one named tool adapter plus its current three-state availability probe result. Resolves the adapter name with custom-over-built-in precedence (project-local `custom/adapters/` wins over `plugins/gaia/scripts/adapters/`). Unknown adapter names exit non-zero with an actionable list of available adapters. Use when "tool info", "adapter info", or /gaia-tool-info.
argument-hint: "<adapter-name>"
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are surfacing the full metadata block for one tool adapter. The script `tool-info.sh` is the single source of truth — it resolves the adapter directory, validates the JSON, renders every top-level key/value pair from `adapter.json`, and runs the availability probe.

## Critical Rules

- An adapter name MUST be provided. If missing, fail with `usage: /gaia-tool-info <adapter-name>`.
- This skill is READ-ONLY. Do NOT modify the adapter or any related file.
- Do NOT re-implement metadata rendering or probe logic in conversation — the script is the authoritative source.
- On unknown adapter names, render the script's "Available adapters" list verbatim. Do NOT trim or summarise.

## Steps

### Step 1 — Resolve the Argument

- If no adapter name was provided, fail with `usage: /gaia-tool-info <adapter-name>`.

### Step 2 — Run the Helper

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/tool-info.sh <name>`.
- Exit code 0 — adapter resolved. Render stdout verbatim.
- Exit code 2 — unknown adapter. Render stdout verbatim (it includes the available list) and stop without proposing fixes.
- Exit code 1 — caller error (missing argument, malformed adapter.json, jq missing). Render stderr and stop.

### Step 3 — Follow-up Routing

- If the user asks "is X available", point them at the rendered availability slot.
- If the user wants the full inventory, route to `/gaia-list-tools`.
- If the user wants to add a new adapter, route to the adapter authoring docs at `plugins/gaia/scripts/adapters/BOUNDARIES.md` and `_schema/`.

## Notes

- Custom-over-built-in precedence: when both `custom/adapters/{name}/` and `scripts/adapters/{name}/` exist, the script resolves to the custom one. The output's `source:` line names which root won.
- Availability slot semantics: the slot uses the canonical four-state probe vocabulary — `available` / `expected_and_missing` (rendered as `unavailable` in the table) / `ran_and_errored` (rendered as `degraded`) / `not_applicable` / `unknown`. When `GAIA_TOOL_INFO_SKIP_PROBE=1` the slot reads `unknown (probe skipped)` — used by tests.
- The script uses `jq` to enumerate every top-level key in `adapter.json` so optional fields (`scope`, `plugin`, etc.) appear without per-field hardcoding.
