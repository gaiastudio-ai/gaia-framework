---
name: gaia-config-ci
description: Scaffold or regenerate a CI pipeline with quality checks. Use when "setup CI pipeline" or /gaia-config-ci (formerly /gaia-ci-setup); pass --regenerate to refresh generated workflows with the backup-before-overwrite UX and *.user-steps.yml include pattern (E71-S4).
argument-hint: "[--preset solo|small-team|standard|enterprise|custom] [--regenerate]"
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
deprecated_aliases: [gaia-ci-setup]
deprecated_since: sprint-37
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-ci-setup/scripts/setup.sh

## Mission

You are scaffolding a CI/CD pipeline for the project. You detect the CI platform, select a promotion chain preset (or build a custom chain), define pipeline quality gates, configure secrets management, set deployment strategy, and generate the pipeline configuration file.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/ci-setup` workflow (Cluster 11, story E28-S86, ADR-042). It follows the canonical skill pattern established by E28-S66 (code-review).

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes pipeline configuration files and modifies `global.yaml`.

**Foundation script integration (ADR-042):** This skill relies on `validate-gate.sh` from `plugins/gaia/scripts/` as a dependency check in `setup.sh` (the foundation script must be present and executable before the skill body runs). The skill's `finalize.sh` does NOT post-check `ci_setup_exists` — removed by E28-S199, since this skill is the producer of `.gaia/artifacts/test-artifacts/ci-setup.md` and a post-check on the producer's own output is tautological (success path) or misleading (failure path). Deterministic operations (config resolution, gate verification) belong in bash scripts, not LLM prompts.

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

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 1 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=platform-detected`

### Step 2 -- Preset Selection (Promotion Chain)

- Check if `ci_cd.promotion_chain` already exists in `global.yaml`.
- If it exists: warn user and offer [o]verwrite / [s]kip / [e]dit (redirect to `/gaia-ci-edit`).
- Present the 4 canonical presets: solo, small-team, standard, enterprise, plus custom.
- In YOLO mode: auto-select `standard` preset.
- For custom: prompt for each environment field (id, name, branch, ci_provider, merge_strategy, ci_checks).
- Write the selected chain to `global.yaml` preserving all existing fields.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 2 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" preset="$PRESET" stage=preset-selected`

### Step 3 -- Define Pipeline

- Configure build, lint, test, coverage, and deploy gates.
- Map gates to the selected CI platform's syntax.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 3 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=pipeline-defined`

### Step 4 -- Quality Gates

- Load knowledge fragment: `knowledge/contract-testing.md` for consumer-driven contract patterns in CI pipelines
- Define pass/fail thresholds: coverage percentage, test pass rate.
- Configure gate enforcement (blocking vs advisory).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 4 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=quality-gates-defined`

### Step 5 -- Secrets Management

- Identify required secrets from architecture and PRD.
- Document how to add secrets to the selected CI platform.
- Define environment-level separation for staging vs production secrets.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 5 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=secrets-configured`

### Step 6 -- Deployment Strategy

- Define staging deployment: auto-deploy on merge after gates pass.
- Define production deployment: manual approval gate.
- Define rollback procedure.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 6 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=deployment-strategy-defined`

### Step 7 -- Monitoring and Notifications

- Configure pipeline failure notifications.
- Add pipeline status badge for README.
- Recommend metrics dashboard for pipeline health.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 7 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=monitoring-configured`

### Step 8 -- Generate Pipeline Config

- Generate the CI config file (e.g., `.github/workflows/ci.yml`) for the selected platform.
- Validate the generated config syntax. The validation step is wrapped in the retry loop documented below under [Schema Validation Retry Loop](#schema-validation-retry-loop) -- see that subsection for entry, body, exit, and abort semantics. The loop wraps `validate-gate.sh` (do not duplicate its logic inline).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 8 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" schema_retry_count="$SCHEMA_RETRY_COUNT" stage=pipeline-config-generated --paths "$CI_CONFIG_PATH"`

### Schema Validation Retry Loop

> Implements **FR-355** (`/gaia-ci-setup` Schema Validation Retry Loop). Verified by **VCP-CI-01** (valid first-pass), **VCP-CI-02** (single retry), and **VCP-CI-03** (multi-retry) — see `.gaia/artifacts/test-artifacts/test-plan.md §11.46.15`.

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

**Atomic write semantics.** The skill does NOT write a partial `.gaia/artifacts/test-artifacts/ci-setup.md` on the abort path. If `ci-setup.md` generation already occurred before validation in a future revision, that ordering must be documented here so users understand what the abort path leaves behind. Today the artifact is written by Step 9 (after validation passes), so the abort path leaves no `ci-setup.md` behind.

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

- Generate the CI/CD pipeline configuration document at `.gaia/artifacts/test-artifacts/ci-setup.md`.
- Include: pipeline stages, quality gates, secrets management, deployment strategy, monitoring setup.
- When the generated workflow is written to disk (e.g. `.github/workflows/gaia-pre-merge.yml`), prepend the four-line header emitted by `${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-regen-header.sh emit <hash>` where `<hash>` is the sha256 of the CI-relevant config sections (computed via the same helper's `hash` subcommand). The header records: attribution, DO NOT EDIT warning referencing `--regenerate`, source-hash, and the ISO-8601 generated-at timestamp.
- Immediately after the workflow file is written, invoke `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-user-steps.sh scaffold <ci-file>` to drop a sibling `*.user-steps.yml` scaffold next to it (no-op when the user-steps file already exists). This is the AC8 first-run scaffold path.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-ci-setup 9 ci_provider="$CI_PROVIDER" ci_config_path="$CI_CONFIG_PATH" stage=output-generated --paths .gaia/artifacts/test-artifacts/ci-setup.md`

## Four-Phase Stitching Order (ADR-114 §(c), FR-517, E98-S2)

When `/gaia-config-ci --regenerate` rewrites a `gaia-*.yml` workflow, the engine at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-workflow-stitcher.sh` composes the output in this **fixed, non-negotiable** four-phase order:

1. **GAIA template scaffold** — the managed workflow body as generated from `project-config.yaml`.
2. **`steps_before_gaia`** — entries from `gaia-{base}.user-steps.yml` are spliced **before** the managed steps block.
3. **`gaia-generated jobs ∪ user-jobs`** — entries from `gaia-{base}.user-jobs.yml` are YAML-unioned into the managed `jobs:` map (last-writer-wins on key collision; collision detection is E98-S3's job).
4. **`steps_after_gaia`** — entries from `gaia-{base}.user-steps.yml` are spliced **after** the managed steps block.

### Overlay shapes

```yaml
# gaia-ci.user-jobs.yml — merged into managed jobs: map
jobs:
  coverage-upload:
    runs-on: ubuntu-latest
    steps:
      - run: echo coverage
  notify-slack:
    runs-on: ubuntu-latest
    steps:
      - run: echo slack
```

```yaml
# gaia-ci.user-steps.yml — block-level splicing
steps_before_gaia:
  - name: user-pre
    run: echo before
steps_after_gaia:
  - name: user-post
    run: echo after
```

### Invariants

- **Block-level edges only.** Per-step `insert_after` / `insert_before` markers are **NOT** honored (deliberate scope cut per ADR-114 §Rationale — those are template forks, not overlays).
- **GAIA-generated steps and jobs are never reordered or modified.** The stitcher composes around them; it does not rewrite them.
- **Comments preserved.** Comments in both the template-derived sections and the overlay-derived sections survive the stitch (per ADR-044 / ADR-114 §(c)).
- **Deterministic.** Same inputs → byte-identical output (TC-CCL-8). Sort key: alphabetical by overlay filename, then declaration order within each overlay file.

`gaia_ci_stitch <managed-yml> [<output-path>]` is the single function in the stitcher; downstream consumers (Sub-flow C of `--regenerate` mode) source it and call directly.

## Auto-Rename Migration (FR-519, ADR-114 §(f), SR-84, E98-S5)

### Orchestration contract (caller responsibility)

The `gaia_auto_rename_migration` helper at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/auto-rename-migration.sh` is **decision-driven** — it consumes a per-file decision from the env-var `GAIA_MIGRATE_DECISION_{basename_with_underscores}` (e.g., `GAIA_MIGRATE_DECISION_ci_yml=y`). The production caller (the LLM running `/gaia-config-ci --regenerate`) is responsible for the interactive orchestration:

1. **Pre-flight enumerate.** Source the helper and call `gaia_auto_rename_migration` with no decisions set — it will list candidates and (default-to-skip) write `_memory/.config-stale` for each. Read the list of candidates from `.github/workflows/*.yml` filtered through `gaia_ci_classify == unprefixed`.
2. **Per-file `AskUserQuestion`.** For EACH candidate, dispatch `AskUserQuestion` with the canonical three options:
   - **`y` — gaia-rename + overlays** — managed by GAIA per FR-516; you keep custom logic via overlay stubs.
   - **`n` — user-rename** — file is yours; GAIA will never modify it again.
   - **`s` — skip-all** — defer the decision; `_memory/.config-stale` is written and `/gaia-help` will surface the deferred migration.
3. **Set decision env-var + re-invoke.** Export `GAIA_MIGRATE_DECISION_{basename_with_underscores}=<choice>` for each resolved decision, then re-invoke `gaia_auto_rename_migration` to execute the renames + backups.
4. **Y-branch regen step.** AFTER the helper renames a file to `gaia-{base}.yml`, the orchestrator MUST re-enter Sub-flow C for that file: generate the canonical body (Sub-flow C step 1), stitch overlays (step 2), apply `template_overrides` (step 4), prepend header (step 5). The helper itself does NOT regenerate the body — it only renames + scaffolds the empty overlay stubs.

### Three branches (helper-level behavior)

- **(y)** Rename to `gaia-{base}.yml` + scaffold empty overlay stubs (`gaia-{base}.user-jobs.yml`, `gaia-{base}.user-steps.yml`). **Body regen is the orchestrator's responsibility** (see step 4 of the orchestration contract above) — the helper does NOT call back into the canonical template generator.
- **(n)** Rename to `user-{base}.yml` (byte-identical content; the file is now user-owned per FR-516).
- **(s)** Skip-all — leave the file untouched and write `_memory/.config-stale` per FR-528 / ADR-102. The deferred migration is surfaced by `/gaia-help`.

### Backup contract

Backup-first BEFORE any rename: `.gaia-backup/ci-regen-{ISO-8601-timestamp}/` at PROJECT_ROOT (NOT under `.gaia/`), mode 0755, files mode 0644, sha256-verified byte-identical copy of every file the migration is about to mutate.

### SR-84 non-interactive guard (T-ARM-1 mitigation)

In non-interactive contexts (`GAIA_NONINTERACTIVE=1`), the migration requires **BOTH** `--force` CLI arg AND `GAIA_MIGRATE_ALLOW_FORCE=1` env-var. Either alone HALTs with:

```
auto-rename-migration.sh: HALT: non-interactive auto-rename migration requires --force AND GAIA_MIGRATE_ALLOW_FORCE=1 per SR-84
```

### Idempotency

Already-prefixed files (`gaia-*.yml` or `user-*.yml`) are classified by `gaia_ci_classify` as `generated` / `user-authored` / `overlay` and never re-fire the prompt. Subsequent regen runs produce byte-identical output (extends TC-CCL-8 determinism).

## `template_overrides:` Declarative Overrides (FR-518, ADR-114 §(e), E98-S4)

`ci_cd.template_overrides:` is a three-field declarative surface in `project-config.yaml` that lets project owners modify generated workflows without authoring overlay files. The interpreter lives at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/template-overrides.sh` and runs on the stitched workflow stream during `/gaia-config-ci --regenerate`.

### The three fields

```yaml
ci_cd:
  template_overrides:
    disable: [shellcheck]            # remove named jobs from generated jobs: map
    timeout_overrides:               # override per-job timeout-minutes
      bats-tests: 15
    adapter_versions:                # pin adapter version in job invocations
      markdownlint: "0.41.0"
```

### SR-78 disable-allowlist (T-TOV-1 mitigation)

The closed enum of security-critical job names that **CANNOT** be disabled is hard-coded:

- `commitlint`
- `adr-048-guard`
- `no-claude-attribution`
- `secrets-scan`
- `nfr-082-credential-audit`

Any `disable:` entry matching one of these names (after hyphen+case canonicalization — `commit-lint` / `Commit-Lint` / `commitlint` all collide with the canonical token) is **REJECTED** with a non-zero exit and an actionable error citing SR-78 / T-TOV-1.

### Per-field validation

- **Unknown `disable:` name** → WARNING (graceful — catalog may drift between framework releases).
- **`timeout_overrides:` minutes outside [1, 360]** → HARD ERROR.
- **Unknown `adapter_versions:` adapter name** → HARD ERROR (pinning to a non-existent adapter is always a typo).
- **Unparseable semver in `adapter_versions:`** → HARD ERROR (expects `N.N.N` with optional prerelease/build).

### Sequencing

The interpreter runs against the **already-stitched** workflow stream (E98-S2's `ci-workflow-stitcher.sh` output), not the raw template. Override application is the final pass before the workflow is written to disk.

## Regen Contract — `gaia-` Prefix Is the Ownership Boundary (ADR-114, E98-S1)

`/gaia-config-ci --regenerate` is permitted to overwrite **only** files classified as `generated` by the canonical helper `${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-prefix-detection.sh`. Source the helper and call `gaia_ci_classify <path>` to obtain one of:

| Classification | Match rule (first match wins) | Regen behavior |
|---|---|---|
| `overlay` | `gaia-*.user-jobs.yml` OR `gaia-*.user-steps.yml` | NEVER overwrite. Stitch via `ci-regen-user-steps.sh` (see Sub-flow C step 2). |
| `generated` | basename starts with `gaia-` (and did not match overlay) | Eligible for regen. Header + body fully overwritten. |
| `user-authored` | basename starts with `user-` | NEVER touch. Refuse with actionable error citing ADR-114. |
| `unprefixed` | none of the above | NEVER touch. Route through the E98-S5 auto-rename migration prompt per FR-519. |

The four-value enum is exhaustive and ordered — overlay precedence is load-bearing so that `gaia-ci.user-jobs.yml` is classified `overlay` (not `generated`), preventing regen from stomping overlay files. The `unprefixed` state is the migration-trigger surface per FR-519 and is intentionally distinct from `user-authored` (fail-safe-conservative fallback).

Refuse-to-touch error for `user-authored` / `overlay` / `unprefixed`:

```
/gaia-config-ci: refusing to overwrite <path> (classification: <kind>).
  Regen owns gaia-*.yml only — per ADR-114's CI customization layered model.
  - user-authored files: yours; regen will never modify them.
  - overlay files (gaia-*.user-jobs.yml / gaia-*.user-steps.yml): stitched, never overwritten.
  - unprefixed files: run /gaia-config-ci to migrate via the E98-S5 auto-rename flow (FR-519).
```

`ci-prefix-detection.sh` is the single source of truth for this classification. Sub-flow A's `ci-regen-detect-edit.sh` MUST consult `gaia_ci_classify` before scanning for manual edits — no file outside the `generated` class is a candidate for the regen loop.

## `--regenerate` Mode (E71-S4)

When the user invokes `/gaia-config-ci --regenerate`, this mode replaces Steps 1-9 entirely. It is the deterministic refresh path for previously-generated workflow files. The five sub-flows below map 1:1 to AC1-AC10 (TS-01..TS-12). The mode does not write a step-level checkpoint — it is a re-entry into the generator, not a new phase, and the existing Step 9 checkpoint covers the regenerated artifact.

**Sub-flow A — Manual-edit detection (AC2, TS-02).**
For each generated workflow file (`.github/workflows/gaia-*.yml`), run `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-detect-edit.sh <file>`. The exit code drives the next sub-flow:

- `0` (clean) — no manual edits. Proceed silently to sub-flow C (regenerate in place). NO prompt is shown — this is the AC5 (TS-05) silent regen path; no manual edit means no user prompt.
- `1` (edited) — proceed to sub-flow B (backup-or-merge prompt).
- `2` (no header) — treat as edited; proceed to sub-flow B.

**Sub-flow B — Backup-or-merge prompt (AC3, TS-03).**
Present the four-option prompt with `b` as the default option:

```
The generated CI workflow has manual edits. Choose how to proceed:
  (d) show diff      — preview the difference, then re-prompt.
  (b) backup         — copy current file to .gaia-backup/{ci-file}-{ts}/, then regenerate. (default)
  (m) merge manually — cancel; you reconcile by hand.
  (f) force overwrite — proceed without backup.
[d/b/m/f] (default: b):
```

Resolve the answer:

- `d` — render `diff -u <file> <regenerated-content>` and re-issue the prompt.
- `b` — invoke `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-backup.sh <file>` to create the backup directory, then proceed to sub-flow C. The backup directory uses the convention `.gaia-backup/{ci-file}-{ISO-8601-timestamp}/` at project root (AC4, TS-04).
- `m` — abort the regen for this file. Write the `_memory/.config-stale` flag via `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-stale-flag.sh write` so subsequent commands surface the stale-config warning.
- `f` — proceed to sub-flow C without creating a backup.

**Sub-flow C — Regenerate the workflow (AC1, AC5, AC6, AC7).**
Compute the canonical content for the workflow:

1. Generate the body content from the current `project-config.yaml` (the same deterministic generator used by Step 9).
2. **Overlay stitching (E98-S2 / FR-517).** Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-workflow-stitcher.sh` and call `gaia_ci_stitch <managed-yml>` against the generated workflow. The stitcher composes the four-phase order: GAIA scaffold → `steps_before_gaia` → GAIA jobs ∪ `user-jobs.yml` → `steps_after_gaia` (AC6, TS-06). The legacy `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-user-steps.sh extract-before`/`extract-after` primitives remain available for callers that need the raw blocks; the canonical entry-point for full stitching is `gaia_ci_stitch`.
3. **Write protection (AC7, TS-07).** BEFORE writing any file, pass the prospective target through `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-user-steps.sh assert-protected <path>` — the helper exits non-zero for any `*.user-steps.yml` path so the regenerate flow CANNOT touch a user-steps file regardless of which option (d/b/m/f) the user chose.
4. **Apply `template_overrides:` (E98-S4 / FR-518 / ADR-114 §(e)).** Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/template-overrides.sh` and call `gaia_apply_template_overrides <stitched-yml> <project-config.yaml>` against the stitched workflow stream. The interpreter performs the three FR-518 passes (`disable`, `timeout_overrides`, `adapter_versions`) and enforces the SR-78 closed-enum disable allowlist (T-TOV-1 mitigation). On non-zero exit, ABORT the regen for this file — no partial write, no header prepended, the user must fix project-config.yaml and re-run.
5. Compute the body sha256 via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-regen-header.sh hash` (over the CI-relevant config sections), prepend the four-line header via `... emit <hash>`, and write the result back to the workflow file. The header lines are:
   - `# Generated by /gaia-config-ci from project-config.yaml`
   - `# DO NOT EDIT this file by hand — run \`/gaia-config-ci --regenerate\` to refresh.`
   - `# Source hash: sha256:<hex>`
   - `# Generated at: <ISO-8601-UTC>`
6. After every workflow has been refreshed successfully, clear the stale flag via `${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-stale-flag.sh clear`.

**Sub-flow D — Stale-flag lifecycle (AC9, TS-09..TS-11).**
The flag file `_memory/.config-stale` is the single signal that the project's CI workflows are out-of-date relative to `project-config.yaml`:

- `write` — set on `m` (merge-manually) in sub-flow B and on `n` (defer) in the post-edit prompt (sub-flow E).
- `check` — emitted at the top of `/gaia-*` runs that consume the config; exits 0 with a stderr warning when present, exits 1 silently when absent.
- `clear` — invoked at the end of sub-flow C after a successful regen for every workflow.

**Sub-flow E — Post-edit prompt (AC10, TS-12).**
Other config-mutating editors (`/gaia-config-env`, `/gaia-config-stack`, `/gaia-config-rubric`, etc.) detect when their edits touch the CI-relevant sections (`ci_cd`, `environments`, `stacks`) and invoke the shared prompt helper:

```
!${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-post-edit-prompt.sh print
```

The user answers `y` (regenerate now), `n` (defer), or `d` (show diff). The editor then resolves the side-effect via:

```
!${CLAUDE_PLUGIN_ROOT}/scripts/ci-regen-post-edit-prompt.sh handle <answer>
```

Answer `y` returns to the caller for an immediate `/gaia-config-ci --regenerate`. Answer `n` writes the stale flag (sub-flow D). Answer `d` returns a diff-hint pointing at `/gaia-config-show ci_cd` for a preview.

**No prompt when no manual edit (AC5, TS-05).** If sub-flow A returns clean for every file in the regen set, no prompt is presented — files are regenerated in place silently.

**`*.user-steps.yml` is never modified (AC7, TS-07).** Across every option of sub-flow B, sub-flow C, and the scaffold path in Step 9, the `assert-protected` guard ensures no `*.user-steps.yml` is overwritten, deleted, moved, or backed up.

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

  See .gaia/artifacts/implementation-artifacts/E42-S15-port-gaia-test-framework-atdd-ci-setup-checklists-to-v2.md.
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
