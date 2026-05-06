---
name: gaia-validate-rubric
description: Validate a single rubric file (JSON or YAML — one layer of the four-layer rubric pipeline) against the rubric.schema.json JSON Schema. YAML is parsed to JSON before schema validation; both formats produce identical PASS/FAIL semantics. Reports PASS or FAIL with actionable schema violations. Use when "validate rubric" or /gaia-validate-rubric.
argument-hint: "<path-to-rubric.json|.yaml|.yml>"
allowed-tools: [Read, Bash]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are validating a single rubric file (a layer in the four-layer rubric pipeline introduced by ADR-079) against `rubric.schema.json`. The check is mostly scripted — `validate-rubric.sh` is the single source of truth (per ADR-042, NFR-RSV2-4). Your job is to invoke the script, surface the verdict, and report any violations actionably.

Layers covered by this skill: `rubrics/base/<skill>.json`, `rubrics/regimes/<regime>.json`, `rubrics/domain/<name>.json`, `rubrics/project/<skill>.json`. Any single one of these can be validated standalone.

## Critical Rules

- A path argument MUST be provided. If missing, fail with `usage: /gaia-validate-rubric <rubric.json>`.
- The file MUST exist at the supplied path. Do NOT search or guess locations.
- This skill is READ-ONLY. Do NOT modify the rubric file.
- The verdict comes from `validate-rubric.sh` — do NOT re-implement schema validation in conversation.
- Surface all violations the script reports, line-by-line, on FAIL. Do NOT collapse or summarise — schema violations are actionable only when literal.

## Steps

### Step 1 — Resolve Argument

- If no path argument was provided, fail with `usage: /gaia-validate-rubric <rubric.json>`.
- If the file does not exist, fail with `rubric file not found: <path>`.

### Step 2 — Run the Validator

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/validate-rubric.sh <path>`.
- Exit code 0 — schema PASS. Print `PASS: <path>` and stop.
- Non-zero exit — schema FAIL. Re-render the violation lines from the script's stderr output verbatim, then print `FAIL: <path> — <N> violation(s)` as the final line.

### Step 3 — Report

- On PASS: a single-line `PASS: <path>` is the canonical output. No further action.
- On FAIL: the violation list (one rule per line) followed by the FAIL summary. Stop without proposing fixes — fixes belong in `/gaia-fix-story` or the story owner's edit cycle.

## Notes

- The `validate-rubric.sh` script prefers `ajv-cli` when available; falls back to a structural `jq`-based validator otherwise. Both produce the same PASS/FAIL semantics.
- YAML input (`.yaml` / `.yml`) is converted to JSON before validation via `yq` (preferred) or `python3` + PyYAML (fallback). If neither is available, the script exits with a clear "YAML rubric input requires either 'yq' or 'python3 + PyYAML' on PATH" message.
- Override the schema path via the `GAIA_RUBRIC_SCHEMA` environment variable (used by tests).
- This skill validates ONE layer. To validate the merged output of a project's full layer stack, use `/gaia-config-validate`.
