---
name: gaia-config-stack
description: Edit the stacks section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit stacks config" or /gaia-config-stack.
argument-hint: "[--add|--remove|--edit|--reorder] [stack-name]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `stacks` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3. The `stacks` section is an ordered list of stack-path rules for multi-service repos per FR-RSV2-6 — review skills resolve the active stack by walking entries in declaration order and matching against the changed-file list.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `stacks` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- Each stack entry MUST have `name`, `language`, and `paths`. Reject entries missing any required field.
- Stack `name` values MUST be unique within the list.
- Stack declaration order is significant — it drives the first-match resolution rule. Reorder operations MUST surface this in the confirmation prompt.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `stacks` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the stacks Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> stacks`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  stacks:
    - name: app
      language: typescript
      paths: ["src/**"]
  ```

### Step 3 — Present CRUD Menu

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Render the current stacks list as a numbered table (position, name, language, paths).
- Operation menu: `[a]` add, `[r]` remove, `[e]` edit, `[o]` reorder, `[v]` view, `[x]` exit.

### Step 4 — Apply Operation

- Add: prompt for name, language, paths (glob list).
- Remove: prompt for name, confirm.
- Edit: prompt for name, then field-by-field updates.
- Reorder: prompt for new order; warn that position 0 changes the first-match resolution.

### Step 5 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 6 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> stacks <temp-file>`.

### Step 7 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- Stack declaration order is the resolution order. Surface this in any reorder confirmation so the user is aware before applying.
- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (40 properties in schema v2.0.0). This skill ONLY edits `stacks`.
