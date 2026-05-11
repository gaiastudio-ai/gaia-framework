---
name: gaia-config-validate
description: Validate project-config.yaml against project-config.schema.json (E68-S1) and report schema violations with JSONPath locations. Pass --rubric to instead validate the merged rubric output for the active project (E68-S2 layered loader). Use when "validate config" or /gaia-config-validate.
argument-hint: "[<config-file>] [--rubric] [--skill <name>]"
allowed-tools: [Read, Bash]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are validating GAIA configuration. By default this skill validates a `project-config.yaml` file against `project-config.schema.json` (E68-S1) — the canonical structural schema covering the eleven top-level sections introduced by the Review System v2 surface (compliance, tools, test_execution, severity, gates, stacks, cross_service_tests, environments, ci_platform, platforms, device_targets) plus the existing required keys (`project_root`, `project_path`, `memory_path`, `checkpoint_path`, `installed_path`, `framework_version`, `date`).

When invoked with `--rubric`, the skill instead validates the merged rubric output for the active project (legacy E68-S2 behavior — base + regimes-in-declaration-order + optional domain + optional project per ADR-079). The rubric mode preserves the layered-loader contract surfaced before E71-S3 so existing callers do not break.

This skill is the native Claude Code entry point for the `/gaia-config-validate` slash command (E71-S3 AC5). Most of the work is scripted: the deterministic schema-validation logic lives in `validate-project-config.sh` (project-config mode) and `validate-rubric.sh` (rubric mode). Your job is to dispatch to the correct script, surface the verdict, and exit with the correct code.

## Critical Rules

- This skill is READ-ONLY. Do NOT modify project-config.yaml or any rubric file.
- The PASS/FAIL verdict is deterministic — derive it from script exit codes, not from natural-language reasoning.
- Default mode validates `project-config.yaml` against `project-config.schema.json` per E71-S3 AC5; `--rubric` opts into the legacy rubric-validation behavior per E68-S2.
- Exit 0 if the file is valid; exit 1 if invalid (one or more schema violations); exit 2 on usage / I/O error.
- Schema violations are reported with a JSONPath-style location (e.g., `$.project_root`) so users can navigate to the offending field.

## Steps

### Step 1 — Detect Mode

- If `--rubric` flag is present, route to rubric-validation mode (Step 4).
- Otherwise route to project-config schema-validation mode (Step 2).

### Step 2 — Resolve project-config.yaml Path

- If a positional argument is provided, use it as the path to the file under test.
- Otherwise resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (or fall back to `config/project-config.yaml` relative to the project root).
- HALT if the file does not exist; tell the user where it was searched and suggest `/gaia-init` to scaffold one.

### Step 3 — Run Project-Config Schema Validation

- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/validate-project-config.sh <path>`.
- The script converts YAML to JSON (via `yq` or `python3 + PyYAML`) and validates against `plugins/gaia/schemas/project-config.schema.json` using `ajv-cli` when available, with a jq-based fallback that enforces the `required` keys and the credential deny-list.
- On exit 0: print `PASS: <path>` and exit 0 (file is valid).
- On exit 1: print every violation line as emitted by the script — each line carries a JSONPath location (e.g., `$.project_root`) and a human-readable message. Exit 1 (file is invalid).
- On exit 2: surface the I/O / usage error verbatim and exit 2.

### Step 4 — Rubric-Validation Mode (legacy E68-S2)

- If `--skill <name>` is provided, validate only that skill's merged rubric.
- Otherwise validate all six base skills (`code`, `qa`, `test`, `security`, `perf`, `a11y`).
- For each skill:
  - Run `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-loader.sh --skill <name>` and pipe the output through `validate-rubric.sh /dev/stdin`.
  - A merged-output schema failure surfaces as `FAIL: merged rubric for <skill> failed schema validation` with the violations.
- Aggregate per-skill verdicts and emit a final summary `<P> passed, <F> failed, <B> blocked, <W> warnings`. Exit non-zero if any FAIL or BLOCKED occurred.

## Notes

- E71-S3 changed the default mode from rubric validation (E68-S2) to project-config schema validation. Existing callers that depended on rubric validation must add the `--rubric` flag.
- The project-config schema lives at `plugins/gaia/schemas/project-config.schema.json` — see E68-S1 for the surface contract.
- Credential deny-list patterns (sk-, ghp_, AKIA, xox-, glpat-) are rejected per FR-RSV2-9; literal credentials in `environments.*.credentials.*` MUST be replaced with env-var name references.
