---
name: gaia-config-sprint-review
description: Edit the sprint_review section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting. Configures Track B per-stack execution-review commands consumed by /gaia-sprint-review. Schema rejects `playwright_headed: false` at validation time. Use when "edit sprint_review config" or /gaia-config-sprint-review.
argument-hint: "[get|set|show|clear] [--key <dotted-path>] [--value <v>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `sprint_review` top-level section of `project-config.yaml`. The skill is one of the `/gaia-config-*` editors, each scoped to a single declared section of `schemas/project-config.schema.json`. The `sprint_review` section maps per-stack execution-review commands consumed by the Track B runner that `/gaia-sprint-review` invokes.

Editing is comment-preserving: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `sprint_review` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh`. Do NOT round-trip the file through a generic YAML serializer.
- `playwright_headed` MUST be `true` (foreground-mode enforcement). The schema constrains this with `const: true`; this skill MUST NOT offer to set it to `false`. Any user-attempt to set `playwright_headed: false` is rejected with the canonical error `sprint_review.playwright_headed must be true (foreground-mode enforcement)`.
- `human_confirm` MUST be one of: `required`, `optional`. Reject any other value.
- `timeout_per_stack` MUST be an integer in [30, 3600]. Reject any other value.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `sprint_review` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section per the schema, OR abort.

## Subcommands

This skill supports four subcommands:

- `get [--key <dotted-path>]` — read a single key (or the whole section). Examples: `get`, `get --key backend_commands.backend-python`, `get --key playwright_headed`.
- `set --key <dotted-path> --value <v>` — write a single key atomically. Examples: `set --key backend_commands.backend-python --value "pytest -v"`, `set --key human_confirm --value required`.
- `show` — pretty-print the whole `sprint_review` section. If the section is absent, emit the canonical default block with a header-comment marker (see Step 2).
- `clear --key <dotted-path>` — remove a key; the schema default applies on next read.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the sprint_review Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> sprint_review`.
- Exit 2 (missing / absent section): for `show`, emit the canonical default block with a header-comment marker:
  ```yaml
  # sprint_review: (defaults — section not yet configured for this project)
  sprint_review:
    playwright_headed: true       # NFR-069 — MUST stay true
    timeout_per_stack: 300        # seconds (30..3600)
    human_confirm: required       # required | optional
    screen_recording_fallback: true
  ```
  For `set`/`clear`, offer to scaffold the default section on first write, OR abort.

### Step 3 — Validate the proposed edit

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- For `set`:
  - Resolve `--key` against the schema (`playwright_headed`, `timeout_per_stack`, `human_confirm`, `screen_recording_fallback`, `backend_commands.<stack-id>`, `frontend_commands.<stack-id>` (canonical map — preferred over the legacy `frontend_command` scalar when a project has more than one web/front-end stack), `frontend_command` (deprecated scalar; backward-compat alias for single-web-stack projects), `mobile_commands.<stack-id>`, `desktop_commands.<stack-id>`, `plugin_commands.<stack-id>`).
  - **Hard-rejection on `playwright_headed: false`**. Print the canonical error and HALT.
  - Reject out-of-range `timeout_per_stack` (< 30 or > 3600).
  - Reject `human_confirm` values outside `{required, optional}`.
  - For `*_commands.<stack-id>` keys with unknown stack identifiers: WARN but accept (forward-compat). Surface the warning before the diff preview so the user can confirm intent.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> sprint_review <temp-file>`.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation. In particular, `/gaia-config-validate` re-confirms `playwright_headed: true` and emits per-stack-identifier WARNINGs for unknown identifiers.

## Notes

- See `schemas/project-config.schema.json` `.properties.sprint_review` for the full schema. This skill ONLY edits `sprint_review`.
- Consumed by `/gaia-sprint-review` Track B runner — the per-stack command map is the canonical lookup at execution-review time.
- Schema enforcement of `playwright_headed: true` is intentional: the foreground invariant is the entire reason Track B exists; defeating it via config silently is exactly the attack it guards against.
