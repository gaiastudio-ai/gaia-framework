---
name: gaia-config-rubric
description: "DEPRECATED — This skill has been retired. Use /gaia-config-severity (5-into-3 severity map) and /gaia-config-gates (per-gate severity overrides) instead. Preserved as a thin one-sprint deprecation redirect."
argument-hint: "[--set <key>=<value>] [--remove <key>]"
allowed-tools: [Read, Grep, Bash, Skill]
deprecated_aliases: [gaia-config-rubric]
deprecated_since: sprint-44
replaced_by: [gaia-config-severity, gaia-config-gates]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Deprecation Notice

> **This skill is retired.** Schema v2.0.0 of `project-config.yaml` has no `rubrics` top-level property — the section this skill targeted never existed in the v2 schema. The original drafter's intent was to configure the layered rubric loader, but that configuration surface was decomposed into TWO canonical sections:
>
> - **`severity`** — global 5-into-3 severity map. Edit via `/gaia-config-severity`.
> - **`gates`** — per-gate severity overrides. Edit via `/gaia-config-gates`.
>
> No `rubrics` section exists in `schemas/project-config.schema.json`, so this skill cannot perform a valid write. It is preserved for one sprint as a thin redirect per the deprecation-with-redirect pattern. After that, it will be removed.

## Mission

This skill is a thin deprecation redirect. It exists only to surface the retirement notice and point callers at the canonical replacements:

- For the global severity-to-verdict map → `/gaia-config-severity`
- For per-gate severity overrides → `/gaia-config-gates`
- For per-rubric-file validation (an orthogonal concern) → `/gaia-validate-rubric`

The retirement rationale is "schema v2.0.0 has no `rubrics` top-level property" — not a validator-overlap argument. Validators are not editors; there is no overlap to dedup.

## Steps

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration. The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

### Step 1 — Display Deprecation Banner

Display the deprecation notice so the user sees the redirect in the transcript:

> `/gaia-config-rubric` is retired. Schema v2.0.0 has no `rubrics` top-level property. Use `/gaia-config-severity` (global 5-into-3 severity map) and `/gaia-config-gates` (per-gate overrides) instead.

### Step 2 — Suggest the Canonical Replacement

Ask the user which surface they intended to edit:

- The global severity-to-verdict map → run `/gaia-config-severity`.
- Per-gate severity overrides → run `/gaia-config-gates`.
- Per-rubric-file validation (file under `plugins/gaia/rubrics/`) → run `/gaia-validate-rubric`.

Do NOT attempt to modify a `rubrics` block in `project-config.yaml` — the section does not exist in the schema, and `config-yaml-editor.sh insert` will reject it per the schema-aware fail-safe.

## Notes

- The retirement is one sprint long per the deprecation-with-redirect pattern. After that window, the skill is removed.
- Consult `schemas/project-config.schema.json` `.properties` for the closed set of declared top-level sections the `/gaia-config-*` family operates on.
