---
name: gaia-config-tool
description: Edit the tools section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit tools config" or /gaia-config-tool.
argument-hint: "[--category <sast|secret-scan|dep-audit|...>] [--provider <name>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `tools` top-level section of `project-config.yaml`. The skill is one of the `/gaia-config-*` editors shipped by E71-S3, each scoped to a single declared section of `schemas/project-config.schema.json`. The `tools` section maps tool categories (sast, secret-scan, dep-audit, etc.) to provider+config selections per FR-RSV2-10.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `tools` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- `provider` values MUST resolve to a built-in or registered adapter — verify against `${CLAUDE_PLUGIN_ROOT}/scripts/list-adapters.sh` output where possible.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `tools` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the tools Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> tools`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold (category names match the `list-adapters.sh` inventory):
  ```yaml
  tools:
    sast:
      provider: semgrep
    secret-scan:
      provider: gitleaks
    dep-audit:
      provider: trivy
  ```

### Step 3 — Present Category Editor

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Render the current category-to-provider mapping as a table.
- Prompt for category and new provider/config.
- Cross-reference `list-adapters.sh` to surface available providers.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> tools <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- See `schemas/project-config.schema.json` `.properties` for the closed set of declared top-level sections. This skill ONLY edits `tools`.
