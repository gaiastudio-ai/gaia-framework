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

You are validating GAIA configuration. By default this skill validates a `project-config.yaml` file against `project-config.schema.json` (E68-S1) — the canonical structural schema covering the Review System v2 top-level sections (compliance, tools, test_execution, severity, gates, stacks, cross_service_tests, environments, ci_platform, platforms, device_targets, and others — see `schemas/project-config.schema.json` `.properties` for the full 40-property surface in schema v2.0.0) plus the existing required keys (`project_root`, `project_path`, `memory_path`, `checkpoint_path`, `installed_path`, `framework_version`, `date`).

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

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/validate-project-config.sh <path>`.
- The script converts YAML to JSON (via `yq` or `python3 + PyYAML`) and validates against `plugins/gaia/schemas/project-config.schema.json` using `ajv-cli` when available, with a jq-based fallback that enforces the `required` keys and the credential deny-list.
- On exit 0: print `PASS: <path>` and exit 0 (file is valid).
- On exit 1: print every violation line as emitted by the script — each line carries a JSONPath location (e.g., `$.project_root`) and a human-readable message. Exit 1 (file is invalid).
- On exit 2: surface the I/O / usage error verbatim and exit 2.

**`ci_cd.template_overrides:` SR-78 enforcement (E98-S4 / FR-518 / ADR-114 §(e)).** The schema's `ci_cd.template_overrides.disable.items` carries a `not.enum` clause for the five SR-78 security-critical job names (`commitlint`, `adr-048-guard`, `no-claude-attribution`, `secrets-scan`, `nfr-082-credential-audit`). Any literal-form match here is reported by `ajv-cli` as a schema violation at validate time (T-TOV-1 mitigation, enforced BEFORE regen). Defense-in-depth: `template-overrides.sh` at regen time also rejects hyphen+case-canonicalized forms (e.g., `commit-lint`, `Commit-Lint`) that bypass the literal-only schema enum.

**E99 multi-shape migration WARNING (E99-S6 / FR-528).** After schema validation passes, source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-migration-status.sh` and call `gaia_config_migration_status <project-config.yaml>`. When the status is `pre-migration`, `partial-missing-distribution`, or `partial-missing-kind`, emit the WARNING text from `gaia_config_migration_warning_text <config>` to stderr. The WARNING is informational (exit 0); the validator does NOT fail on pre-migration configs per NFR-080 zero-breakage. The companion `gaia_config_migration_stale_flag_write` writer drops a `_memory/.config-stale` marker per ADR-102 so `/gaia-help` surfaces the deferred migration on the next session. When status is `clean` or `unknown`, no warning is emitted (legacy all-deployable projects are vacuously clean per the NFR-080 default).

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
