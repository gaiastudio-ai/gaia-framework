---
name: gaia-config-test
description: Edit the test_execution section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting. Use when "edit test_execution config" or /gaia-config-test.
argument-hint: "[--tier <1|2|3>] [--placement <local|ci-pre-merge|ci-post-merge|deployment|post-deploy>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `test_execution` top-level section of `project-config.yaml`. The skill is one of the `/gaia-config-*` editors, each scoped to a single declared section of `schemas/project-config.schema.json`. The `test_execution` section maps the three test tiers (tier_1, tier_2, tier_3) to canonical pipeline placements.

Editing is comment-preserving: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `test_execution` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh`. Do NOT round-trip the file through a generic YAML serializer.
- `placement` values MUST be one of the canonical set: `local`, `ci-pre-merge`, `ci-post-merge`, `deployment`, `post-deploy`. Reject any other value.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `test_execution` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section per the schema, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the test_execution Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> test_execution`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  test_execution:
    tier_1:
      placement: local
    tier_2:
      placement: ci-pre-merge
    tier_3:
      placement: ci-post-merge
  ```

### Step 3 — Present Tier Editor

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration. The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Render the current tier-to-placement mapping as a table.
- Prompt for tier and new placement, validating against the canonical placement set.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> test_execution <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (40 properties in schema v2.0.0). This skill ONLY edits `test_execution`.
