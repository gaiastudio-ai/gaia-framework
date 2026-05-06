---
name: gaia-config-rubric
description: Edit the rubrics section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit rubrics config" or /gaia-config-rubric.
argument-hint: "[--set <key>=<value>] [--remove <key>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `rubrics` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3. The `rubrics` section configures the layered rubric loader (E68-S2) — typically the path overrides for project-level rubric files and any per-skill overrides per ADR-079.

This skill ONLY edits the `rubrics` section in `project-config.yaml`. It does NOT manage individual rubric files under `plugins/gaia/rubrics/` — that is the scope of `/gaia-validate-rubric` (E68-S2). To validate the merged rubric output, invoke `/gaia-config-validate --rubric` (legacy E68-S2 mode).

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `rubrics` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- This skill MUST NOT touch individual rubric files under `plugins/gaia/rubrics/`. That is `/gaia-validate-rubric` scope (E68-S2).
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `rubrics` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve the path as `${CLAUDE_PROJECT_ROOT:-$PWD}/config/project-config.yaml` (project-root-relative).
- HALT if missing.

### Step 2 — Extract the rubrics Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> rubrics`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  rubrics:
    project_root: rubrics/project
  ```

### Step 3 — Present Edit Menu

- Render the current rubrics block as a key/value table.
- Operation menu: set key, remove key, view, exit.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> rubrics <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation, AND `/gaia-config-validate --rubric` to confirm the merged rubric output remains valid.

## Notes

- For per-rubric-file editing, use `/gaia-validate-rubric` (E68-S2). This skill manages only the `rubrics:` configuration block in `project-config.yaml`.
- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `rubrics`.
