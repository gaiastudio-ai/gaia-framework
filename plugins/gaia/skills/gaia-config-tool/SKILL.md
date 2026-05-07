---
name: gaia-config-tool
description: Edit the tool_adapters section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit tool_adapters config" or /gaia-config-tool.
argument-hint: "[--category <sast|secrets|sca|...>] [--provider <name>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `tool_adapters` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3, each scoped to a single section of the eleven-section project-config surface (E68-S1). The `tool_adapters` section maps tool categories (sast, secrets, sca, etc.) to provider+config selections per FR-RSV2-10.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `tool_adapters` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- `provider` values MUST resolve to a built-in or registered adapter — verify against `${CLAUDE_PLUGIN_ROOT}/scripts/list-adapters.sh` output where possible.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `tool_adapters` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the tool_adapters Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> tool_adapters`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  tool_adapters:
    sast:
      provider: semgrep
    secrets:
      provider: gitleaks
    sca:
      provider: trivy
  ```

### Step 3 — Present Category Editor

- Render the current category-to-provider mapping as a table.
- Prompt for category and new provider/config.
- Cross-reference `list-adapters.sh` to surface available providers.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> tool_adapters <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `tool_adapters`.
