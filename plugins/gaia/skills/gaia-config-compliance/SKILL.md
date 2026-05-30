---
name: gaia-config-compliance
description: Edit the compliance section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit compliance config" or /gaia-config-compliance.
argument-hint: "[--add-regime <regime>] [--remove-regime <regime>] [--domain <name>] [--ui-present true|false]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
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
- Exit 2 (missing / absent section): offer scaffold-or-skip-or-abort. Per E71-S9 AC4, an absent `compliance:` section validates with the semantic default `regimes: [], ui_present: false` — so scaffold-skip (decline the scaffold; keep the section absent) is now a first-class option that preserves the empty-default semantics without writing an empty stub block. Default scaffold (when the user opts in):
  ```yaml
  compliance:
    regimes: []
    domain: null
    ui_present: false
  ```

### Step 3 — Present CRUD Menu

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Render current regimes (in declaration order), domain, ui_present.
- Operation menu: add regime, remove regime, edit domain, toggle ui_present, exit.
- Validate every regime value against the canonical enum.

### Step 4 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 5 — Write Back

- On `y`:
  - **If the `compliance:` section already exists** (Step 2 extract returned exit 0): write the edited section to a temp file and invoke `config-yaml-editor.sh replace <path> compliance <temp-file>`.
  - **If the `compliance:` section is absent** and the user opted into the Step 2 scaffold path: write the scaffold to a temp file and invoke `config-yaml-editor.sh insert <path> compliance <temp-file>`. The `insert` verb appends a brand-new section before EOF and refuses (exit 1) if the section already exists — use it whenever the prior `extract` exited 2 (section not found). Do NOT use `replace` against an absent section — `replace` exits 2 (`section not found`), which is the AF-2026-05-30-4 F-10 footgun.

### Step 6 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- Regime declaration order is the layered-loader merge order — moving `gdpr` from position 0 to position 1 changes the merged rubric output. Surface this in the confirmation prompt so the user is aware before clicking through.
- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (40 properties in schema v2.0.0). This skill ONLY edits `compliance`.
