---
name: gaia-config-validate
description: Validate the merged rubric for the active project — runs the layered rubric loader (base + regimes + domain + project per RFC 7396), validates the merged output against rubric.schema.json, and flags declaration-order contradictions. Use when "validate config" or /gaia-config-validate.
argument-hint: "[--skill <name>]  (default: validates all six base review skills)"
allowed-tools: [Read, Bash]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are validating the merged rubric output for the active project. This skill exercises the full four-layer pipeline (base + regimes-in-declaration-order + optional domain + optional project per ADR-079) for one or more review skills, validates the merged result against `rubric.schema.json`, and surfaces declaration-order contradictions (a regime that empties an array a previous regime populated, then the next regime re-populates differently).

Most of the work is scripted (`rubric-loader.sh` + `rubric-merger.sh` + `validate-rubric.sh`). Your job is to drive the loader for the requested skill(s), inspect the merged output, run the contradiction detector, and produce a clear PASS or FAIL report.

## Critical Rules

- This skill is READ-ONLY. Do NOT modify project-config.yaml or any rubric file.
- The PASS/FAIL verdict is deterministic — derive it from script exit codes, not from natural-language reasoning.
- Contradiction detection is a WARNING (informational), not a hard FAIL. A contradiction does NOT block the merged rubric from being valid.
- A schema-validation failure on any individual layer halts the loader with `BLOCKED` (NFR-RSV2-4). Surface that verbatim — do NOT auto-correct.
- Six default skills: `code`, `qa`, `test`, `security`, `perf`, `a11y`. Use `--skill <name>` to scope to one.

## Steps

### Step 1 — Determine Skills to Validate

- If `--skill <name>` is provided, validate only that skill.
- Otherwise validate all six base skills (`code`, `qa`, `test`, `security`, `perf`, `a11y`).

### Step 2 — Run the Loader for Each Skill

For each skill in scope:

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-loader.sh --skill <name>` (no other flags — the loader auto-discovers regimes, domain, and project layer from project-config.yaml).
- Capture stdout (the merged JSON) and stderr (any BLOCKED messages).
- If exit is non-zero, the verdict for that skill is `FAIL` with the BLOCKED message verbatim. Do NOT proceed to contradiction detection for that skill.

### Step 3 — Validate the Merged Output

- For each skill that loaded successfully, pipe the merged JSON through `validate-rubric.sh /dev/stdin` (or write to a tempfile and validate). The merged output MUST itself satisfy `rubric.schema.json`.
- A merged-output schema failure indicates two layers combined into a structure that no individual layer would have produced — surface as `FAIL: merged rubric for <skill> failed schema validation` with the violations.

### Step 4 — Declaration-Order Contradiction Detection

- For projects with two or more regimes, re-run the loader incrementally: load `base + regime1`, then `base + regime1 + regime2`, then `base + regime1 + regime2 + regime3`, etc.
- After each step, compare the array-typed keys against the previous step. If a regime emptied an array a previous step had populated, AND a subsequent regime re-populated that array differently (different element count or different element ordering when sorted), record a `WARNING: declaration-order contradiction in <skill>: array <key> was emptied by <regime_n> then re-populated by <regime_n+1>`.
- WARNINGs do NOT change the PASS/FAIL verdict. They are informational signals that the regime declaration order may produce a non-obvious merged result.

### Step 5 — Report

- For each skill, print one of:
  - `PASS: <skill> — <N> rules in merged rubric`
  - `FAIL: <skill> — <reason>`
  - `BLOCKED: <skill> — <message from loader>`
- After per-skill verdicts, print any WARNING lines from contradiction detection.
- Print a final summary: `<P> passed, <F> failed, <B> blocked, <W> warnings`. Exit non-zero if any FAIL or BLOCKED occurred.

## Notes

- The loader honours `GAIA_RUBRICS_ROOT` (override the framework's `rubrics/` root for testing). Do not set this in production validation.
- For projects with no `compliance.regimes:` and no `rubrics/project/`, the merged output equals the base rubric (AC9 / identity merge). PASS verdicts for those projects confirm only that the base rubric is well-formed.
- This skill exercises NFR-RSV2-10 (deterministic merger) implicitly — a second run on identical inputs produces a byte-identical merged output. If you observe drift between runs, treat it as a critical bug and file a finding.
