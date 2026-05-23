---
name: gaia-config-show
description: Display project-config.yaml read-only — top-level section TOC (default), a single named section, or the full byte-verbatim file (--full). Use when "show config" or /gaia-config-show.
argument-hint: "[<section-name> | --full]"
allowed-tools: [Read, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are displaying `project-config.yaml` in read-only mode. The skill is one of the `/gaia-config-*` editors shipped by E71-S3 — the only one without write semantics. Three invocation shapes:

- **No argument (default)** — render the top-level section TOC: a list of the declared sections from `schemas/project-config.schema.json` `.properties` (40 entries in schema v2.0.0). Helps users orient before drilling in.
- **`<section-name>`** — single positional argument naming a top-level section to display. Output is the section's lines verbatim (no parse-and-reserialize round-trip).
- **`--full`** — explicit flag for the byte-verbatim full-file render. Output is the file's bytes verbatim — no comment stripping, no formatting normalization. This is the legacy E71-S3 contract preserved behind an explicit flag (per E71-S9 AC2 / Val F-3).

## Critical Rules

- This skill is READ-ONLY. NEVER write to project-config.yaml or any other file.
- Output is byte-verbatim — no YAML parse/reserialize round-trip, no comment stripping, no indentation normalization. Comments and formatting MUST be preserved exactly as they appear on disk.
- If a section argument is provided and the section does not exist, surface the error from `config-yaml-editor.sh extract` and exit non-zero. Do NOT scaffold or write anything.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing — point the user at `/gaia-init`.

### Step 2 — Render the File, Section, or TOC

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

Dispatch based on the argument shape:

- **`--full`** — cat the entire file to the terminal byte-verbatim. This is the legacy E71-S3 contract preserved behind an explicit flag. No parse-and-reserialize round-trip, no comment stripping, no indentation normalization.
- **Positional `<section-name>`** — invoke `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> <section-name>` and pipe the output to the terminal. Exit 2 (section not found) surfaces verbatim.
- **Positional dotted-path `<section>.<subsection>`** (E98-S4 / ADR-114 §Consequences) — when the positional argument contains a `.` (e.g., `ci_cd.template_overrides`), dispatch via `yq eval '.<section>.<subsection>' <path>` to render the nested subsection. The TOC continues to enumerate only top-level `.properties` keys; dotted-path drill-down is opt-in via the dotted form. Exit non-zero if the nested path resolves to `null`.
- **No argument (default)** — render the top-level section TOC by enumerating `.properties` keys from `schemas/project-config.schema.json`. One section name per line, sorted alphabetically. Helps users orient before drilling in with `--full` or a positional section name.

If the terminal supports syntax highlighting and a YAML highlighter is available (e.g., `bat --language=yaml`, `pygmentize -l yaml`), render YAML output with highlighting; otherwise plain. NEVER write to the file.

## Notes

- This skill is intentionally minimal — it is the inverse of the seven editor skills. Use it before/after edits to confirm the file state.
- `/gaia-config-show environments`, `/gaia-config-show stacks`, etc. are equivalent to `config-yaml-editor.sh extract <path> <section>`.
- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (40 properties in schema v2.0.0).
