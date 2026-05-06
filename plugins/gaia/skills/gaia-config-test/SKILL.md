---
name: gaia-config-test
description: Edit the test_execution section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit test_execution config" or /gaia-config-test.
argument-hint: "[--tier <1|2|3>] [--placement <local|ci-pre-merge|ci-post-merge|deployment|post-deploy>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `test_execution` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3, each scoped to a single section of the eleven-section project-config surface (E68-S1). The `test_execution` section maps the three test tiers (tier_1, tier_2, tier_3) to canonical pipeline placements per FR-RSV2-11.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `test_execution` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh` per ADR-042 / ADR-044. Do NOT round-trip the file through a generic YAML serializer.
- `placement` values MUST be one of the canonical set: `local`, `ci-pre-merge`, `ci-post-merge`, `deployment`, `post-deploy`. Reject any other value.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `test_execution` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section per the E68-S1 schema, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve the path as `${CLAUDE_PROJECT_ROOT:-$PWD}/config/project-config.yaml` (project-root-relative).
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

- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `test_execution`.
