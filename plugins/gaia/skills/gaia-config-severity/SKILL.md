---
name: gaia-config-severity
description: Edit the severity section of project-config.yaml — the FR-RSV2-22 5-into-3 severity map (Critical / High / Medium / Low / Info → BLOCKED / REQUEST_CHANGES / APPROVE). Section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit severity config" or /gaia-config-severity.
argument-hint: "<set|show|clear> [<internal> <verdict>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `severity` top-level section of `project-config.yaml` — the FR-RSV2-22 5-into-3 severity map that translates internal severity bands (`Critical | High | Medium | Low | Info`) to gate verdicts (`BLOCKED | REQUEST_CHANGES | APPROVE`). The downstream review system reads this map when composing gate verdicts.

The schema definition (`#/definitions/severityMap`) is a closed object: only the five internal names are accepted, and each maps to exactly one of the three verdicts.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `severity` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- Internal severity names are restricted to the closed set `{Critical, High, Medium, Low, Info}` — anything else is rejected with exit 1.
- Verdict values are restricted to the closed set `{BLOCKED, REQUEST_CHANGES, APPROVE}` — anything else is rejected with exit 1.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- Writes go through the deterministic helper `gaia-config-severity-edit.sh`, which delegates to `config-yaml-editor.sh replace` / `insert`.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing.

### Step 2 — Dispatch Subcommand

Invoke the deterministic helper:

```
${CLAUDE_PLUGIN_ROOT}/scripts/gaia-config-severity-edit.sh \
  --config <path> <set|show|clear> [<internal> <verdict>]
```

- `set <internal> <verdict>` — set / replace a single mapping in the section. Creates the section if absent.
- `show` — print the current map (one line per entry), or "no severity section" when absent.
- `clear` — remove the `severity` section entirely.

### Step 3 — Optional Validation Pass

Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- See `schemas/project-config.schema.json` `.properties` for the closed set of declared top-level sections this skill family operates on. This skill ONLY edits `severity`.
- For per-gate severity overrides (e.g., a single review gate with stricter mappings), use `/gaia-config-gates`. The two skills are intentionally separate per ADR-044 one-skill-per-section.
- Pairs with `/gaia-config-gates` (per-gate overrides). When a per-gate override is absent, the global `severity` map wins by fall-through.
