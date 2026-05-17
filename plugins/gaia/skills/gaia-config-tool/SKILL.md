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
- **Orphan-rejection (E71-S9 AC5 / config-skill author convention).** If the user supplies a `<category>` that is not in the canonical adapter-category set, reject with exit 1 and the canonical error message: `category '<category>' is not a known adapter category — see /gaia-list-tools for available categories`. The canonical set is the union of (a) categories emitted by `${CLAUDE_PLUGIN_ROOT}/scripts/list-adapters.sh` (currently `a11y-scanner | dast | dep-audit | deploy | e2e-runner | formatter | linter | mobile-static | perf-tool | sast | secret-scan`) and (b) the prose-only category `test_runner` — consumed by `/gaia-test-run` (line 47 of its SKILL.md and line 87 of run-tests.sh) to look up `tools.test_runner.provider` for unit-test runner selection (vitest, pytest, bats, go). `test_runner` has no `scripts/adapters/` entry by design — runner invocation is direct, not adapter-mediated — but the category must be acceptable to `/gaia-config-tool` so users can configure it. This convention is set by AF-2026-05-17-3; it preserves the orphan-rejection guard for unknown categories while admitting the test-runner vocabulary that `/gaia-test-run` already depends on. Mirrors the orphan-rejection pattern established by `/gaia-config-device-target` and propagated by E71-S9 AC5 across the config-skill family.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `tools` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the tools Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> tools`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold (per E71-S9 AC3 — empty heading + category-comment block sourced from `${CLAUDE_PLUGIN_ROOT}/scripts/list-adapters.sh`; users opt in to the categories they need):
  ```yaml
  tools:
    # Available adapter categories (from list-adapters.sh):
    #   a11y-scanner | dast | dep-audit | deploy | e2e-runner |
    #   formatter | linter | mobile-static | perf-tool | sast | secret-scan
    # Plus the prose-only category (no adapter; direct invocation):
    #   test_runner    -- consumed by /gaia-test-run (AF-2026-05-17-3)
    # Add a category as `<category>: { provider: <provider-name> }`. Run
    # /gaia-list-tools to see the available providers per category.
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

## Config-skill author convention: orphan-rejection pattern (E71-S9 AC5)

The orphan-rejection pattern is a shared convention across the `/gaia-config-*` skill family: when the user supplies an identifier that is not in the canonical closed set, the skill rejects with exit 1, names the offending identifier in the error message, and points the user at the repair command. Concrete sites:

- **`/gaia-config-platform`** — rejects empty / punctuated identifiers; warns on unknown-but-valid kebab-case (per ADR-081 §4.2 the platform surface is extensible).
- **`/gaia-config-device-target`** — rejects orphan platforms (a `<platform>` not present in `platforms[]`); error names the platform and points to `/gaia-config-platform add <platform>`.
- **`/gaia-config-severity`** — rejects internals outside `{Critical, High, Medium, Low, Info}` and verdicts outside `{BLOCKED, REQUEST_CHANGES, APPROVE}`.
- **`/gaia-config-gates`** — rejects unknown gate names (kebab-case check) and the same severity/verdict closed sets as `/gaia-config-severity`.
- **`/gaia-config-tool`** (this skill) — rejects unknown adapter categories per the Critical Rules section above; pointer goes to `/gaia-list-tools`.

When authoring a new `/gaia-config-*` skill, follow this convention: define the closed set, reject unknown values with exit 1, name the offender in the error, and point the user at the repair command.
