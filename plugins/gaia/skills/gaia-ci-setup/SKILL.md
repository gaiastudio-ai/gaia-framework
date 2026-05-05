---
name: gaia-config-ci
description: Scaffold a CI pipeline with quality checks. Use when "setup CI pipeline" or /gaia-config-ci (formerly /gaia-ci-setup).
argument-hint: "[--preset solo|small-team|standard|enterprise|custom]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
deprecated_aliases: [gaia-ci-setup]
deprecated_since: sprint-37
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-ci-setup/scripts/setup.sh

## Mission

You are scaffolding a CI/CD pipeline for the project. You detect the CI platform, select a promotion chain preset (or build a custom chain), define pipeline quality gates, configure secrets management, set deployment strategy, and generate the pipeline configuration file.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/ci-setup` workflow (Cluster 11, story E28-S86, ADR-042). It follows the canonical skill pattern established by E28-S66 (code-review).

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes pipeline configuration files and modifies `global.yaml`.

**Foundation script integration (ADR-042):** This skill relies on `validate-gate.sh` from `plugins/gaia/scripts/` as a dependency check in `setup.sh` (the foundation script must be present and executable before the skill body runs). The skill's `finalize.sh` does NOT post-check `ci_setup_exists` — removed by E28-S199, since this skill is the producer of `docs/test-artifacts/ci-setup.md` and a post-check on the producer's own output is tautological (success path) or misleading (failure path). Deterministic operations (config resolution, gate verification) belong in bash scripts, not LLM prompts.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Before scaffolding, check for existing CI config files (`.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml`). If found, warn the user and offer to merge or overwrite rather than silently replacing (AC-EC1).
- The `validate-gate.sh` foundation script (E28-S15) MUST be present and executable at `plugins/gaia/scripts/validate-gate.sh`. If missing or not executable, HALT with: "validate-gate.sh not found or not executable -- dependency E28-S15 must be installed first" (AC-EC3, AC-EC5).
- The `resolve-config.sh` foundation script (E28-S19) MUST be present and executable. If missing, HALT with dependency error.
- The promotion chain written to `global.yaml` MUST use the canonical field order: id, name, branch, ci_provider, merge_strategy, ci_checks (AC4, ADR-033).
- Pipeline configuration MUST include quality gate checks: lint, unit, test at minimum.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Detect CI Platform

- Scan for existing CI config files in the project: `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml`.
- If existing config found: warn the user and present options -- merge with existing, overwrite, or abort (AC-EC1).
- If no config found: note that no existing CI platform was detected.
- Ask which CI platform to use: GitHub Actions, GitLab CI, Jenkins, CircleCI, or other.

> `!scripts/write-checkpoint.sh gaia-ci-setup 1 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=platform-detected`

### Step 2 -- Preset Selection (Promotion Chain)

- Check if `ci_cd.promotion_chain` already exists in `global.yaml`.
- If it exists: warn user and offer [o]verwrite / [s]kip / [e]dit (redirect to `/gaia-ci-edit`).
- Present the 4 canonical presets: solo, small-team, standard, enterprise, plus custom.
- In YOLO mode: auto-select `standard` preset.
- For custom: prompt for each environment field (id, name, branch, ci_provider, merge_strategy, ci_checks).
- Write the selected chain to `global.yaml` preserving all existing fields.

> `!scripts/write-checkpoint.sh gaia-ci-setup 2 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" preset="$PRESET" stage=preset-selected`

### Step 3 -- Define Pipeline

- Configure build, lint, test, coverage, and deploy gates.
- Map gates to the selected CI platform's syntax.

> `!scripts/write-checkpoint.sh gaia-ci-setup 3 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=pipeline-defined`

### Step 4 -- Quality Gates

- Load knowledge fragment: `knowledge/contract-testing.md` for consumer-driven contract patterns in CI pipelines
- Define pass/fail thresholds: coverage percentage, test pass rate.
- Configure gate enforcement (blocking vs advisory).

> `!scripts/write-checkpoint.sh gaia-ci-setup 4 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=quality-gates-defined`

### Step 5 -- Secrets Management

- Identify required secrets from architecture and PRD.
- Document how to add secrets to the selected CI platform.
- Define environment-level separation for staging vs production secrets.

> `!scripts/write-checkpoint.sh gaia-ci-setup 5 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=secrets-configured`

### Step 6 -- Deployment Strategy

- Define staging deployment: auto-deploy on merge after gates pass.
- Define production deployment: manual approval gate.
- Define rollback procedure.

> `!scripts/write-checkpoint.sh gaia-ci-setup 6 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=deployment-strategy-defined`

### Step 7 -- Monitoring and Notifications

- Configure pipeline failure notifications.
- Add pipeline status badge for README.
- Recommend metrics dashboard for pipeline health.

> `!scripts/write-checkpoint.sh gaia-ci-setup 7 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=monitoring-configured`

### Step 8 -- Generate Pipeline Config

- Generate the CI config file (e.g., `.github/workflows/ci.yml`) for the selected platform.
- Validate the generated config syntax. The validation step is wrapped in the retry loop documented below under [Schema Validation Retry Loop](#schema-validation-retry-loop) -- see that subsection for entry, body, exit, and abort semantics. The loop wraps `validate-gate.sh` (do not duplicate its logic inline).

> `!scripts/write-checkpoint.sh gaia-ci-setup 8 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" schema_retry_count="$SCHEMA_RETRY_COUNT" stage=pipeline-config-generated --paths "$CI_CONFIG_PATH"`

### Schema Validation Retry Loop

> Implements **FR-355** (`/gaia-ci-setup` Schema Validation Retry Loop). Verified by **VCP-CI-01** (valid first-pass), **VCP-CI-02** (single retry), and **VCP-CI-03** (multi-retry) — see `docs/test-artifacts/test-plan.md §11.46.15`.

The Step 8 schema validation invocation is wrapped in a retry loop so the user can iteratively correct CI configuration violations within a single `/gaia-ci-setup` invocation instead of restarting the workflow.

**Entry conditions.** The loop is entered exactly once per `/gaia-ci-setup` invocation, immediately after the pipeline config file has been generated and is ready for schema validation. The first iteration runs the existing `validate-gate.sh` invocation unchanged.

**Loop body.**

1. Invoke `validate-gate.sh` against the current CI configuration.
2. On pass: the loop exits immediately on the first attempt with no violations output emitted, and the skill proceeds to Step 9 (Generate Output). This is the valid-first-pass path — no retry loop is invoked when the configuration is valid on the first attempt.
3. On failure: render the violations list using the format documented under [Violation Output Format](#violation-output-format) below, then prompt the user: `Correct the violations above and press [c] to re-validate, or [x] to abort.`
4. On `[c]`: re-read the CI configuration file from disk (so the user's edits are picked up) and re-invoke `validate-gate.sh`. Repeat from step 1.
5. On `[x]`: enter the abort path documented below.

**Exit conditions.** The loop exits in exactly two ways:

- **Pass exit.** `validate-gate.sh` returns success. The skill proceeds to Step 9. The pass exit is taken on the very first attempt for a valid configuration (no violations, no prompt) and on every subsequent attempt where the user has corrected all outstanding violations.
- **Abort exit (`[x]`).** The skill aborts cleanly with a summary of the remaining violations (`N violations remaining — run /gaia-ci-setup again after correction`) and exits non-zero. The abort exit is distinct from the pass exit and is the only forced exit path other than pass.

**No hard retry cap.** The loop has no hard cap on iterations. The user controls convergence — there is no arbitrary retry limit that forces an abort before the user has finished correcting the configuration. This guarantee is required by AC3 of E46-S7 and is verified by VCP-CI-03 (3 consecutive failures before pass — the loop must not abort prematurely).

**Prompt mode interactions.** In YOLO mode the retry loop still prompts `[c]`/`[x]`. Violations require human input and cannot be auto-answered — this matches the engine's `open-question` indicator handling.

**Atomic write semantics.** The skill does NOT write a partial `docs/test-artifacts/ci-setup.md` on the abort path. If `ci-setup.md` generation already occurred before validation in a future revision, that ordering must be documented here so users understand what the abort path leaves behind. Today the artifact is written by Step 9 (after validation passes), so the abort path leaves no `ci-setup.md` behind.

#### Violation Output Format

Each schema violation is rendered as a `{field, expected, actual}` triplet. The triplet is the canonical machine-parseable record so downstream tooling (lint-SKILL-md.js, future VCP regression tests, automation hooks) can consume it without re-parsing free-form prose.

```
Violations:
  - field:    promotion_chain[0].branch
    expected: a non-empty string identifying the git branch
    actual:   <missing>
  - field:    promotion_chain[1].ci_provider
    expected: one of: github_actions | gitlab_ci | jenkins | circleci
    actual:   travis
```

Multiple violations are emitted as an ordered list. Field names use dotted-path notation matching the canonical `global.yaml` schema. The `expected` value describes the schema constraint in human-readable form; the `actual` value is the literal value found in the configuration (or `<missing>` when the field is absent). The triplet contract MUST remain stable so lint and regression tooling can verify the format mechanically.

### Step 9 -- Generate Output

- Generate the CI/CD pipeline configuration document at `docs/test-artifacts/ci-setup.md`.
- Include: pipeline stages, quality gates, secrets management, deployment strategy, monitoring setup.

> `!scripts/write-checkpoint.sh gaia-ci-setup 9 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=output-generated --paths docs/test-artifacts/ci-setup.md`

## Validation

<!--
  E42-S15 — V1→V2 8-item checklist port (FR-341, FR-359, VCP-CHK-35, VCP-CHK-36).
  Classification (8 items total — V1 verbatim, no extras):
    - Script-verifiable: 6 (SV-01..SV-06) — enforced by finalize.sh.
    - LLM-checkable:     2 (LLM-01..LLM-02) — evaluated by the host LLM
      against the ci-setup.md artifact at finalize time.
  Exit code 0 when all 6 script-verifiable items PASS; non-zero otherwise.

  V1 source: 8 items (clean). V1 → V2 mapping (1:1, no drop, no merge):
    V1 "CI platform confirmed by user (not just auto-detected)" → LLM-01 (semantic)
    V1 "Pipeline stages defined (build, lint, test, coverage)"  → SV-01 (4-stage regex)
    V1 "Quality gate thresholds set"                            → SV-02 (threshold regex)
    V1 "Secrets management documented (required secrets,
        environment separation)"                                → SV-03 (heading)
    V1 "Deployment strategy defined (staging, production,
        rollback)"                                              → SV-04 (heading + 3 keywords)
    V1 "Monitoring and notifications configured (failure
        alerts, status badge)"                                  → SV-05 (heading + alert/badge)
    V1 "Pipeline config generated"                              → SV-06 (heading or path regex)
    V1 "Gates are enforced (blocking, not advisory)"            → LLM-02 (semantic)

  Invoked by `finalize.sh` at post-complete (per architecture §10.31.1).
  Validation runs BEFORE the checkpoint and lifecycle-event writes
  (observability is never suppressed by checklist outcome — story AC6).

  See docs/implementation-artifacts/E42-S15-port-gaia-test-framework-atdd-ci-setup-checklists-to-v2.md.
-->

- [script-verifiable] SV-01 — Pipeline stages defined (build, lint, test, coverage)
- [script-verifiable] SV-02 — Quality gate thresholds set
- [script-verifiable] SV-03 — Secrets management documented (required secrets, environment separation)
- [script-verifiable] SV-04 — Deployment strategy defined (staging, production, rollback)
- [script-verifiable] SV-05 — Monitoring and notifications configured (failure alerts, status badge)
- [script-verifiable] SV-06 — Pipeline config generated
- [LLM-checkable] LLM-01 — CI platform confirmed by user (not just auto-detected)
- [LLM-checkable] LLM-02 — Gates are enforced (blocking, not advisory)

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-ci-setup/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-readiness-check` — validate implementation readiness now that CI is scaffolded.
