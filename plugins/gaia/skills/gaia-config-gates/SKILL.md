---
name: gaia-config-gates
description: Edit the gates section of project-config.yaml — per-gate severity overrides keyed by gate name (FR-RSV2-12). Section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit gates config" or /gaia-config-gates.
argument-hint: "<set|show|clear> <gate> [<internal> <verdict>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `gates` top-level section of `project-config.yaml` — the FR-RSV2-12 per-gate severity overrides. Each gate (e.g., `code-review`, `qa-tests`, `security-review`) may override the global `severity` map with its own 5-into-3 mapping. When a per-gate override is absent for a given internal severity, the global `severity` map wins by fall-through.

The schema definition is `{ <gate-name>: { severity: severityMap } }`. Internal severity names are the closed set `{Critical, High, Medium, Low, Info}` and verdicts are the closed set `{BLOCKED, REQUEST_CHANGES, APPROVE}`.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte.

## Critical Rules

- Only the `gates` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- Internal severity names are restricted to `{Critical, High, Medium, Low, Info}`.
- Verdict values are restricted to `{BLOCKED, REQUEST_CHANGES, APPROVE}`.
- Gate names follow the kebab-case shape `^[a-z][a-z0-9-]*$` to mirror the review-gate naming convention. Unknown gate names warn (rubric-pointer hint) but proceed — the gate registry is open per the review system's extensibility model.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.

## Fall-Through Semantics (FR-RSV2-12)

When a review gate composes its verdict, the resolver looks up the severity-to-verdict mapping as follows:

1. **Per-gate override present** — the `gates.<gate>.severity.<internal>` entry wins. The gate uses the override verdict.
2. **Per-gate override absent** — fall through to the global `severity.<internal>` map.
3. **Neither present** — system default (typically `APPROVE` for `Info` and `Low`; `REQUEST_CHANGES` for `Medium`; `BLOCKED` for `High` and `Critical`).

The skill documents these semantics so users understand why a per-gate override only applies when explicitly set.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing.

### Step 2 — Dispatch Subcommand

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

Invoke the deterministic helper:

```
${CLAUDE_PLUGIN_ROOT}/scripts/gaia-config-gates-edit.sh \
  --config <path> <set|show|clear> <gate> [<internal> <verdict>]
```

- `set <gate> <internal> <verdict>` — set / replace a single per-gate mapping. Creates the gate block if absent; creates the `gates` section if absent.
- `show <gate>` — print the current map for `<gate>`, or "no overrides" when absent.
- `clear <gate>` — remove that gate's override block; if no gates remain, remove the `gates` section.

### Step 3 — Optional Validation Pass

Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- See `schemas/project-config.schema.json` `.properties` for the closed set of declared top-level sections this skill family operates on. This skill ONLY edits `gates`.
- Pairs with `/gaia-config-severity` (global map). The global map wins by fall-through when a per-gate override is absent.
- Per Val F-7 (E71-S7): severity and gates are TWO separate skills, NOT one combined skill — this matches the established one-skill-per-section ADR-044 pattern.
