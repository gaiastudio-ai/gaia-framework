---
name: gaia-config-compliance
description: Edit the compliance section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit compliance config" or /gaia-config-compliance.
argument-hint: "[--add-regime <regime>] [--remove-regime <regime>] [--domain <name>] [--ui-present true|false]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `compliance` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3. The `compliance` section selects opt-in regulatory regimes that compose layers onto the rubric stack per ADR-079 (FR-RSV2-5, FR-RSV2-7).

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `compliance` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- `regimes` values MUST be from the canonical enum: `gdpr`, `hipaa`, `pci-dss`, `sox`, `ccpa`, `soc2`, `iso-27001`, `wcag-2.1-aa`, `wcag-2.1-aaa`. Reject any other value.
- Regime declaration order is significant — it drives layered-loader merge order per ADR-079. The skill MUST NOT silently sort or reorder regimes.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `compliance` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the compliance Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> compliance`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  compliance:
    regimes: []
    domain: null
    ui_present: false
  ```

### Step 3 — Present CRUD Menu

- Render current regimes (in declaration order), domain, ui_present.
- Operation menu: add regime, remove regime, edit domain, toggle ui_present, exit.
- Validate every regime value against the canonical enum.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> compliance <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- Regime declaration order is the layered-loader merge order — moving `gdpr` from position 0 to position 1 changes the merged rubric output. Surface this in the confirmation prompt so the user is aware before clicking through.
- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `compliance`.
