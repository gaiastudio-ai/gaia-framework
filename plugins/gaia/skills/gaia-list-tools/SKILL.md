---
name: gaia-list-tools
description: Enumerate every tool adapter discoverable under built-in (`plugins/gaia/scripts/adapters/`) and project-local (`custom/adapters/`) roots, grouped by category, with name, version, provider binary, runtime profile, three-state availability, and a `[custom]` / `[shadowed]` precedence badge. Read-only — no side effects. Use when "list tools", "what adapters are available", or /gaia-list-tools.
argument-hint: "(no arguments)"
allowed-tools: [Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are reporting the current adapter inventory for the active project. The script `list-adapters.sh` is the single source of truth (per ADR-042, ADR-078). Your job is to invoke it, surface its output, and answer follow-up questions about specific adapters by routing the user to `/gaia-tool-info`.

## Critical Rules

- This skill is READ-ONLY. Do NOT modify any adapter file.
- Do NOT re-implement adapter discovery, probe execution, or category grouping in conversation — the script is deterministic and authoritative.
- Render the script's output verbatim. Do NOT collapse, re-sort, or paraphrase rows.

## Steps

### Step 1 — Run the Enumeration Script

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/list-adapters.sh`.
- Capture stdout (the table) and stderr (warnings about malformed `adapter.json` files).

### Step 2 — Render the Output

- Print the script's stdout verbatim.
- If stderr emitted any warnings (e.g. `skipping malformed adapter.json under built-in: <name>`), surface them under a `## Warnings` heading after the table — do NOT discard.
- If the script printed `No adapters found.`, render it verbatim and add a one-line nudge directing the user to `/gaia-create-story` if they want to add one.

### Step 3 — Follow-up Routing

- For "tell me more about X", direct the user to `/gaia-tool-info X`.
- For "validate my rubric", direct to `/gaia-validate-rubric <path>`.
- For "list specific category", direct the user to grep the output (the script's grouped output is greppable by category line).

## Notes

- The script honours `BUILTIN_ADAPTERS_DIR` and `CUSTOM_ADAPTERS_DIR` overrides for testing. Do NOT set these in production.
- Availability slot states map to: `available` (probe passed), `unavailable` (provider binary missing), `degraded` (probe ran but returned errored). When `GAIA_LIST_TOOLS_SKIP_PROBE=1` the slot reads `unknown` — used by tests to avoid PATH dependencies.
- Custom-over-built-in precedence (FR-RSV2-10): a `custom/adapters/{name}/` overrides the built-in `scripts/adapters/{name}/`. The built-in row is marked `[shadowed]` so the precedence is auditable from a single table view.
