---
name: gaia-config-env
description: Edit the environments section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit environments config" or /gaia-config-env.
argument-hint: "[--add|--remove|--edit] [env-name]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `environments` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3, each scoped to a single section of the eleven-section project-config surface (E68-S1). Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

This skill targets ONLY the `environments` section. Other sections (`compliance`, `stacks`, `tool_adapters`, `test_execution`, `rubrics`, `compliance`, `platforms`, etc.) are invisible to the edit session.

## Critical Rules

- Only the `environments` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer — `yq -y`, `yaml.dump`, etc. strip comments and are forbidden.
- Credential values in `environments.*.credentials.*` MUST be env-var NAMES (e.g., `STAGING_DB_PASSWORD_VAR`), never literal credentials. Schema validation rejects literal-secret patterns (sk-, ghp_, AKIA, xox-, glpat-) per FR-RSV2-9.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `environments` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section per the E68-S1 schema, OR abort. NEVER write a malformed section silently.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve the path as `${CLAUDE_PROJECT_ROOT:-$PWD}/config/project-config.yaml` (project-root-relative).
- HALT if the file is missing — point the user at `/gaia-init`.

### Step 2 — Extract the environments Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> environments`.
- Exit 0: capture the section content for editing.
- Exit 2 (section missing / absent): inform the user and offer scaffold-or-abort. The default scaffold is the schema-conformant template:
  ```yaml
  environments:
    staging:
      url: https://staging.example.com
      credentials:
        db_password: STAGING_DB_PASSWORD_VAR
  ```
  On scaffold-and-continue, write the scaffold via `config-yaml-editor.sh insert` and re-extract.

### Step 3 — Present CRUD Menu

- Display the current `environments` section as a structured table (env name, url, credentials count).
- Present operation menu: `[a]` add env, `[r]` remove env, `[e]` edit env, `[v]` view, `[x]` exit without writing.

### Step 4 — Apply Operation

- Add: prompt for env name (must be unique), url, and credential entries (env-var-name only — reject literals).
- Remove: prompt for env name, confirm.
- Edit: prompt for env name, then field-by-field updates.
- All edits target only the in-memory section content — the file is not yet touched.

### Step 5 — Diff Preview + Confirmation Gate

- Generate a unified diff between the original section and the edited section using `diff -u` (same format as `git diff --no-index`) so the user sees exactly what will change.
- Present the diff and prompt: "Apply this edit? [y/n]". HALT without writing on `n` — the file MUST remain byte-identical to its pre-edit state on cancellation.

### Step 6 — Write Back via Comment-Preserving Editor

- On `y`: write the new section content to a temp file and invoke `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh replace <path> environments <temp-file>`.
- The script splices ONLY the section's lines and preserves every byte outside the section range.

### Step 7 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation. Do not run it automatically — the user may want to chain multiple edits.

## Notes

- The eleven top-level sections of `project-config.yaml` (E68-S1) are: `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `environments`.
- Mobile-specific editors (`/gaia-config-platform`, `/gaia-config-device-target`) are E74-S11 scope and intentionally NOT shipped by E71-S3.
