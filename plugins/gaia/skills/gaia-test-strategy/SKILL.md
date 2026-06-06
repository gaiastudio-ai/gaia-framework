---
name: gaia-test-strategy
description: Unified test-strategy skill — owns both test-plan design (formerly /gaia-test-design) and test-framework scaffolding (formerly /gaia-test-framework). Use when "design test strategy", "scaffold tests", "setup test framework", "test plan", or /gaia-test-strategy. Mode-selected via --plan, --scaffold, or interactive no-arg prompt.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
phase: setup
deprecated_aliases: [gaia-test-design, gaia-test-framework]
deprecated_since: sprint-37
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh test-architect all

## Mission

You are the unified entry point for test strategy and test framework setup. Per source-report §9.4, the previous two skills `/gaia-test-design` (test-plan design by Sable) and `/gaia-test-framework` (procedural scaffolding) are collapsed into a single skill with mode selection. This skill owns:

- `--plan` mode: delegate to **Sable** (test-architect subagent) to author or update a `test-strategy.md` document under `.gaia/artifacts/planning-artifacts/` (canonical home; legacy `test-artifacts/strategy/` is honored read-only for pre-migration projects) covering test types, risk-based prioritization, and per-service test sections. `--plan` produces `test-strategy.md`; the companion `test-plan.md` (the per-FR test-case catalogue) is produced by `/gaia-trace` and the `--plan` test-design lineage — both now share the `planning-artifacts/` home, so the two docs sit side-by-side rather than split across trees.

  **Two-artifact expectation + frontmatter schema.** `--plan` produces TWO consumers-dependent artifacts: (1) `test-strategy.md` (prose strategy — consumed by `/gaia-create-epics` via `test_plan_exists` gate's strategy-fallback), and (2) `test-plan.md` (per-FR test-case catalogue — consumed by `/gaia-trace`). The finalize alias-copy `test-strategy.md` → `test-plan.md` is a BOOTSTRAP; operators are expected to enrich `test-plan.md` with the actual per-FR rows BEFORE invoking `/gaia-trace` for a real traceability run. Running `/gaia-trace` against the unenriched alias yields a low-coverage matrix. The required `test-strategy.md` frontmatter is `artifact_type: test-strategy`, `schema_version: "2.0.0"`, `generated_by: /gaia-test-strategy`, `date: YYYY-MM-DD`, `risk_levels: [high, medium, low]`.
- `--scaffold` mode: procedurally generate test directories, framework configuration files (`vitest.config`, `jest.config`, `pytest.ini`, etc.), tagging conventions, and sample tests for the detected or specified stack. Multi-service support via `--service <path>`, `--service all`, `--service root`, or `--cross-service`.
- No-arg interactive mode: present a four-option menu and route to the corresponding `--plan` or `--scaffold` logic.

Deprecation: the skill exposes `deprecated_aliases: [gaia-test-design, gaia-test-framework]`. Invocations of the old names route here per the deprecation alias mechanism. `/gaia-test-design` routes to `--plan` mode; `/gaia-test-framework` routes to `--scaffold` mode. Each routed invocation emits a one-line deprecation warning naming the new canonical command.

## Critical Rules

- The two old skill directories (`gaia-test-design/`, `gaia-test-framework/`) remain on disk — only their `name:` and frontmatter are retired. Do NOT delete them.
- `--plan` and `--scaffold` are mutually exclusive. Invoking both flags together exits with code 1 and a clear message.
- `project-config.yaml` MUST exist before this skill runs in any mode. If absent, exit with code 1 and direct the user to run `/gaia-init` or `/gaia-brownfield` first. The skill never creates a default config.
- `--plan` mode delegates to the **test-architect** subagent (Sable) — do NOT inline Sable's persona into this skill body. If the subagent is not available, halt with: "test-architect subagent not available -- ensure agents are installed."
- `--scaffold` mode is procedural (directory/config generation) and does not require a subagent.
- Do NOT implement or run any tests during scaffolding — only set up the infrastructure. Test implementation happens in Phase 4 workflows (`/gaia-dev-story`, `/gaia-review-qa`, `/gaia-atdd`).
- Output the document artifacts — `test-strategy.md` and `test-plan.md` — to `.gaia/artifacts/planning-artifacts/` (the canonical home stated above; legacy `test-artifacts/strategy/` is read-only for pre-migration projects). Scaffold artifacts from `--scaffold` mode (framework config files like `vitest.config`/`pytest.ini`, test directories, sample tests) are written under the relevant service path or the project's `tests/` tree, NOT into the artifacts buckets.
- Subsequent invocations on a project that already has `test-strategy.md` and scaffolded test directories MUST read the existing strategy and offer incremental updates — do NOT overwrite existing test configuration.
- Single-stack projects skip the interactive `--service` picker and scaffold the single declared stack directly.
- After scaffolding, update the `test_execution` section of `project-config.yaml` and offer a CI regeneration prompt per source-report §9.6.

## Argument Parsing

The skill accepts the following arguments:

- `--plan` — author or update `test-strategy.md`. Delegates to Sable.
- `--scaffold` — generate framework scaffolding (config files, directories, fixtures).
- `--service <path>` — restrict scaffolding to a single declared service. Use `--service all` for bulk scaffolding across all `stacks[]`. Use `--service root` for cross-service E2E tests at `tests/e2e/`.
- `--add <test-type>` — incremental mode: add a new test type (e.g., `perf`, `contract`, `accessibility`) to an existing service.
- `--cross-service` — generate cross-service E2E tests at `tests/e2e/`. Equivalent to `--service root`.

### Argument Validation Guards

1. **Mutual exclusion of `--plan` and `--scaffold`:** if both flags are present, exit code 1 with the message: `error: --plan and --scaffold are mutually exclusive — choose one mode, or invoke /gaia-test-strategy with no arguments for interactive selection.`
2. **Missing `project-config.yaml`:** if the file does not exist on disk, exit code 1 with the message: `error: project-config.yaml not found — run /gaia-init or /gaia-brownfield first to create the project config. This skill does not create a default config.`
3. **Invalid `--service` path:** if `--service <path>` is specified but the path is not present in `project-config.yaml` `stacks[]`, exit code 1 listing the declared services and `all` / `root` reserved values.

## Steps

### Step 0 — Mode Selection

Parse arguments and route:

- If `--plan --scaffold` both present → exit 1 (mutual-exclusion guard).
- If `project-config.yaml` is missing → exit 1 (missing-config guard).
- If `--plan` only → goto Step 1 (Plan Mode).
- If `--scaffold` only (with optional `--service`, `--add`, `--cross-service`) → goto Step 5 (Scaffold Mode).
- If no arguments → goto Step 0a (Interactive Mode).

### Step 0a — Interactive Mode (No Arguments)

Present the user with a four-option menu:

```
What would you like to do?

  1. Create or update the test strategy document
  2. Scaffold test framework for a service
  3. Add a new test type to an existing service
  4. Show current test setup
```

Route the selected choice:

- Option 1 → invoke `--plan` mode (Step 1).
- Option 2 → invoke `--scaffold` mode (Step 5). If multiple services declared in `stacks[]`, present the service picker; if single-stack, scaffold directly.
- Option 3 → prompt for the service (skip picker for single-stack projects), prompt for the test type, then run `--scaffold --service <path> --add <test-type>`.
- Option 4 → read `test_execution` from `project-config.yaml`, list scaffolded services and test types, list existing files under `.gaia/artifacts/planning-artifacts/` (test-strategy.md / test-plan.md canonical home) plus the legacy `.gaia/artifacts/test-artifacts/strategy/` and `tests/`, and exit cleanly without writes.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 0a stage=interactive-route`

### Step 1 — Plan Mode: Load Project Context

(Plan mode begins here.)

Read upstream context (gracefully degrade on missing files):

- `.gaia/artifacts/planning-artifacts/architecture.md` — extract system components, interactions, high-risk areas. If missing: log WARNING, use generic risk ratings.
- PRD — extract requirements (functional and non-functional). Resolve via the sharded-fallback rule: try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). If NEITHER exists: log WARNING, reduced scope.
- `.gaia/artifacts/planning-artifacts/project-context.md` — extract project-level context.

Detect subsequent-invocation: if `.gaia/artifacts/planning-artifacts/test-strategy.md` (canonical) OR the legacy `.gaia/artifacts/test-artifacts/strategy/test-strategy.md` already exists, read it and prepare the incremental-update flow — ask the user what to add (new test type, new perf scenarios, new contract suite) and only generate the incremental pieces.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 1 mode=plan stage=context-loaded`

### Step 2 — Plan Mode: Risk Assessment (Delegate to Sable)

Delegate to the **test-architect** subagent (Sable) for risk assessment.

- Load knowledge: `knowledge/risk-governance.md` for probability-impact matrix methodology.
- Identify high-risk areas: revenue-critical paths, security-sensitive components, complex business logic, data integrity boundaries.
- Rate each area using probability × impact scoring.
- Produce a risk assessment matrix with columns: Area, Risk Level (H/M/L), Probability, Impact, Coverage Strategy.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 2 mode=plan stage=risk-assessment`

### Step 3 — Plan Mode: Test Strategy & Plan (Delegate to Sable)

Delegate to Sable for test strategy and plan authoring.

- Load knowledge: `knowledge/test-pyramid.md`, `knowledge/api-testing-patterns.md`.
- Define test levels per component: unit, integration, E2E, contract.
- Apply test pyramid — most tests at the lowest effective level.
- Define coverage targets, naming conventions, fixture/mock requirements.
- Define quality gates for the CI pipeline.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 3 mode=plan stage=test-strategy`

### Step 4 — Plan Mode: Generate Output

- Write the compiled test strategy to the canonical home `.gaia/artifacts/planning-artifacts/test-strategy.md` (docs-ABOUT-testing live in `planning-artifacts/`, not `test-artifacts/`). For back-compat: if a legacy `.gaia/artifacts/test-artifacts/strategy/test-strategy.md` already exists (pre-migration project), write to that existing location to preserve placement and surface a one-line advisory recommending `migrate-planning-vs-test.sh`; otherwise NEW writes go to `planning-artifacts/`.
- For subsequent invocations: append the incremental update section, do not overwrite earlier sections.
- Offer a follow-up scaffolding prompt: "Set up scaffolding now? [y/n]". On y, route to Step 5.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 4 mode=plan stage=output-generated --paths .gaia/artifacts/planning-artifacts/test-strategy.md`

### Step 5 — Scaffold Mode: Detect Stack(s)

(Scaffold mode begins here.)

Read `project-config.yaml` `stacks[]`. The interpretation:

- If `stacks[]` is missing or contains exactly one entry → **single-stack project**. Skip the `--service` interactive picker and scaffold the single declared stack directly.
- If `stacks[]` contains two or more entries → **multi-service project**. Resolve the target service from `--service <path>`; if not specified, present an interactive picker listing all declared services plus `all` and `root` (cross-service) options.
- If `--service all` is specified → iterate through every declared service sequentially.
- If `--service root` or `--cross-service` is specified → scaffold cross-service E2E at `tests/e2e/`.

Detect per-service language and build tool: check `package.json`, `requirements.txt` / `pyproject.toml`, `build.gradle` / `pom.xml`, `pubspec.yaml`, `go.mod`. Identify any existing test config (`vitest.config.ts`, `jest.config.js`, `pytest.ini`, etc.).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 5 mode=scaffold stage=stack-detected`

### Step 6 — Scaffold Mode: Select Framework

Per detected stack, recommend and apply:

- TypeScript/JavaScript: Vitest (preferred) or Jest for unit/integration; Playwright or Cypress for E2E.
- Python: pytest for unit/integration; Playwright for E2E.
- Java: JUnit 5 for unit/integration; Selenium or Playwright for E2E.
- Flutter/Dart: `flutter_test` for unit; `integration_test` for integration.
- Go: built-in `testing` package; `testify` for assertions.

Prefer extending existing project conventions over replacing them. Load the relevant knowledge fragments JIT.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 6 mode=scaffold stage=framework-selected`

### Step 7 — Scaffold Mode: Generate Scaffolding

- Generate config files for the selected framework.
- Create folder structure (`tests/unit/`, `tests/integration/`, `tests/e2e/` — relative to the service or root for cross-service).
- Add test runner scripts to the project build tool (npm scripts, Makefile, etc.).
- Define fixture/factory architecture (pure functions first, framework fixtures as wrappers).
- For `--add <test-type>`: only generate the incremental pieces (e.g., adding a `perf/` subtree without re-emitting the existing `unit/` config).
- Do NOT write sample tests beyond the smallest-possible "smoke" assertion needed to confirm the runner is wired.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 7 mode=scaffold stage=scaffolded`

### Step 8 — Scaffold Mode: Update project-config.yaml

After successful scaffolding:

- Update the `test_execution` section of `project-config.yaml` with entries for the scaffolded test types and services.
- Offer a CI regeneration prompt per source-report §9.6: "Regenerate CI config now? [y/n]". On y, route to `/gaia-config-ci`.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-strategy 8 mode=scaffold stage=config-updated --paths .gaia/config/project-config.yaml`

## Validation

- [script-verifiable] SV-01 — `test-strategy.md` written when `--plan` mode runs.
- [script-verifiable] SV-02 — Risk assessment section present in `test-strategy.md`.
- [script-verifiable] SV-03 — Test pyramid / test levels keyword present in `test-strategy.md`.
- [script-verifiable] SV-04 — Coverage targets / quality gates documented.
- [script-verifiable] SV-05 — Scaffold mode generated config file(s) for the detected stack.
- [script-verifiable] SV-06 — Scaffold mode created test directory structure.
- [LLM-checkable] LLM-01 — Project stack detected correctly.
- [LLM-checkable] LLM-02 — Framework recommendation matches stack.
- [LLM-checkable] LLM-03 — No actual test implementations created beyond smoke wiring.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-strategy/scripts/finalize.sh

## Next Steps

- **After `--plan`:** offer `/gaia-test-strategy --scaffold` to wire the framework matching the strategy.
- **After `--scaffold`:** offer `/gaia-config-ci` to regenerate CI per the new `test_execution` entries.
- **After both:** proceed to story-level test work via `/gaia-dev-story`, `/gaia-review-qa`, `/gaia-atdd`.
