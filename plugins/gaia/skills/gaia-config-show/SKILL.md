---
name: gaia-config-show
description: Display project-config.yaml read-only — the entire file, or a single named section. Use when "show config" or /gaia-config-show.
argument-hint: "[<section-name>]"
allowed-tools: [Read, Bash]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are displaying `project-config.yaml` in read-only mode. The skill is one of eight `/gaia-config-*` editors shipped by E71-S3 — the only one without write semantics. Output is always the file's bytes verbatim (or a single section's lines verbatim) — no parse-and-reserialize round-trip, no comment stripping, no formatting normalization.

Optionally accepts a single positional argument naming the top-level section to display (e.g., `/gaia-config-show environments` displays only the `environments` section). With no argument, the entire file is rendered.

## Critical Rules

- This skill is READ-ONLY. NEVER write to project-config.yaml or any other file.
- Output is byte-verbatim — no YAML parse/reserialize round-trip, no comment stripping, no indentation normalization. Comments and formatting MUST be preserved exactly as they appear on disk.
- If a section argument is provided and the section does not exist, surface the error from `config-yaml-editor.sh extract` and exit non-zero. Do NOT scaffold or write anything.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing — point the user at `/gaia-init`.

### Step 2 — Render the File or Section

- If a positional section name is provided: invoke `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> <section-name>` and pipe the output to the terminal. Exit 2 (section not found) surfaces verbatim.
- Otherwise: cat the entire file to the terminal verbatim.
- If the terminal supports syntax highlighting and a YAML highlighter is available (e.g., `bat --language=yaml`, `pygmentize -l yaml`), render with highlighting; otherwise plain.
- NEVER write to the file.

## Notes

- This skill is intentionally minimal — it is the inverse of the seven editor skills. Use it before/after edits to confirm the file state.
- `/gaia-config-show environments`, `/gaia-config-show stacks`, etc. are equivalent to `config-yaml-editor.sh extract <path> <section>`.
- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`.
