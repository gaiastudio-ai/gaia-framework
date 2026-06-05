---
name: deprecated-gaia-test-framework
description: DEPRECATED — This skill has been retired. Use /gaia-test-strategy --scaffold (canonical, see gaia-test-strategy/SKILL.md). This file remains only to expose the deprecated alias for one sprint.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
deprecated_aliases: [gaia-test-framework]
deprecated_since: sprint-37
replaced_by: gaia-test-strategy
orchestration_class: light-procedural
---

## Deprecation Notice

This skill is a DEPRECATED alias. On invocation, emit this canonical one-line
warning VERBATIM as the FIRST line of output, then redirect to the canonical
skill:

> `[deprecated] /gaia-test-framework is retired — use /gaia-test-strategy --scaffold (alias preserved one sprint).`

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-framework/scripts/setup.sh

## Mission

Initialize a test framework for the current project by detecting the project stack, selecting the appropriate test framework, scaffolding configuration files and folder structure, and designing fixture/factory patterns. The output is a test framework setup document written to `.gaia/artifacts/test-artifacts/test-framework-setup.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/test-framework` workflow. The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Detect the project stack before recommending any framework — never assume.
- Scaffold complete setup: config files, folder structure, and test runner scripts (npm scripts or equivalent).
- Do NOT implement or run any tests — test implementation happens in Phase 4 workflows (/gaia-dev-story, /gaia-qa-tests, /gaia-atdd).
- Do NOT write sample tests or run any test suite — only set up the infrastructure so tests can be added later.
- Output ALL artifacts to `.gaia/artifacts/test-artifacts/`.
- This is a single-prompt operation — no subagent invocation needed.

## Steps

### Step 1 — Detect Stack

- Identify project language, framework, and existing test setup.
- Check for package.json (Node/TypeScript), requirements.txt / pyproject.toml (Python), build.gradle / pom.xml (Java), pubspec.yaml (Flutter/Dart), go.mod (Go).
- Identify any existing test configuration (vitest.config.ts, jest.config.js, pytest.ini, etc.).
- Report detected stack to the user: language, framework, existing test infrastructure.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-framework 1 detected_stack="$DETECTED_STACK" framework_config_path="$FRAMEWORK_CONFIG_PATH" stage=stack-detected`

### Step 2 — Select Framework

- Load stack-specific knowledge fragments based on detected stack:
  - Load knowledge fragment: `knowledge/jest-vitest-patterns.md` for JS/TS projects
  - Load knowledge fragment: `knowledge/pytest-patterns.md` for Python projects
  - Load knowledge fragment: `knowledge/junit5-patterns.md` for Java projects
- Load knowledge fragment: `knowledge/test-isolation.md` for test doubles and dependency injection patterns
- Recommend test framework based on detected stack:
  - TypeScript/JavaScript: Vitest (preferred) or Jest for unit/integration, Playwright or Cypress for E2E
  - Python: pytest for unit/integration, Playwright for E2E
  - Java: JUnit 5 for unit/integration, Selenium or Playwright for E2E
  - Flutter/Dart: flutter_test for unit, integration_test for integration
  - Go: built-in testing package, testify for assertions
- Consider existing project conventions — if a framework is already partially set up, prefer extending it over replacing it.
- Present recommendation with rationale.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-framework 2 detected_stack="$DETECTED_STACK" framework_config_path="$FRAMEWORK_CONFIG_PATH" stage=framework-selected`

### Step 3 — Scaffold

- Generate config files for the selected framework (e.g., vitest.config.ts, jest.config.js, pytest.ini).
- Create folder structure for tests (e.g., `tests/unit/`, `tests/integration/`, `tests/e2e/`).
- Add test runner scripts to the project build tool (e.g., npm scripts in package.json, Makefile targets).
- Do NOT write sample tests or run any test suite — only set up the infrastructure.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-framework 3 detected_stack="$DETECTED_STACK" framework_config_path="$FRAMEWORK_CONFIG_PATH" stage=scaffolded`

### Step 4 — Fixture Architecture

- Load knowledge fragment: `knowledge/fixture-architecture.md` for fixture patterns and pure function wrappers
- Load knowledge fragment: `knowledge/data-factories.md` for builder pattern and factory function patterns
- Design fixture/factory patterns appropriate for the stack.
- Pure functions first — framework fixtures as wrappers around pure factory functions.
- Define a consistent pattern for test data creation (factory functions, builder pattern, or fixture files).
- Document the fixture architecture in the output.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-framework 4 detected_stack="$DETECTED_STACK" framework_config_path="$FRAMEWORK_CONFIG_PATH" stage=fixtures-designed`

### Step 5 — Generate Output

Write the test framework setup document to `.gaia/artifacts/test-artifacts/test-framework-setup.md` with:
- Detected stack summary
- Selected framework and rationale
- Configuration files created
- Folder structure
- Test runner commands
- Fixture/factory architecture
- Instructions for adding tests

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-test-framework 5 detected_stack="$DETECTED_STACK" framework_config_path="$FRAMEWORK_CONFIG_PATH" stage=output-generated --paths .gaia/artifacts/test-artifacts/test-framework-setup.md`

## Validation

<!--
  V1→V2 7-item checklist port.
  Classification (7 items total — V1 verbatim, no extras):
    - Script-verifiable: 4 (SV-01..SV-04) — enforced by finalize.sh.
    - LLM-checkable:     3 (LLM-01..LLM-03) — evaluated by the host LLM
      against the test-framework-setup.md artifact at finalize time.
  Exit code 0 when all 4 script-verifiable items PASS; non-zero otherwise.

  V1 source: 7 items (clean). V1 → V2 mapping (1:1, no drop, no merge):
    V1 "Project stack detected correctly"                 → LLM-01 (semantic)
    V1 "Framework recommendation matches stack"           → LLM-02 (semantic)
    V1 "Config files generated"                           → SV-01 (heading + config-file regex)
    V1 "Folder structure scaffolded"                      → SV-02 (heading + tests/ regex)
    V1 "Test runner script configured and executable"     → SV-03 (heading + runner regex)
    V1 "Fixture architecture designed"                    → SV-04 (heading)
    V1 "No actual test implementations created — tests
        are written in Phase 4"                           → LLM-03 (semantic, negative)

  Invoked by `finalize.sh` at post-complete (per architecture §10.31.1).
  Validation runs BEFORE the checkpoint and lifecycle-event writes
  (observability is never suppressed by checklist outcome).
-->

- [script-verifiable] SV-01 — Config files generated
- [script-verifiable] SV-02 — Folder structure scaffolded
- [script-verifiable] SV-03 — Test runner script configured and executable
- [script-verifiable] SV-04 — Fixture architecture designed
- [LLM-checkable] LLM-01 — Project stack detected correctly
- [LLM-checkable] LLM-02 — Framework recommendation matches stack
- [LLM-checkable] LLM-03 — No actual test implementations created — tests are written in Phase 4

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-framework/scripts/finalize.sh
