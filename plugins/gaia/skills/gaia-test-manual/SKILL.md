---
name: gaia-test-manual
description: Agent-driven manual verification — exercises a target as a real user would and produces a run record with observed-vs-expected evidence. Disambiguated from /gaia-test-run (automated machine suite).
argument-hint: "<target>"
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/setup.sh

## Mission

Dispatch the manual-tester agent (Reese) to exercise a target — a skill, script, workflow step, or user-facing feature — as a human operator would. The agent runs commands, observes output, compares expected vs. actual behavior, and produces a structured run-record with per-step evidence. The parent skill persists the evidence artifacts (run-record.md and exit-code.log) and enforces the proof-of-execution gate.

## Disambiguation

This skill (`/gaia-test-manual`) and `/gaia-test-run` serve different purposes:

- **`/gaia-test-manual`** — Agent-as-user manual verification. Reese exercises the target the way a human tester would: running commands interactively, observing output, checking visual or behavioral expectations that automated suites cannot cover. Produces a run-record (steps table with observed-vs-expected) and an exit-code log. Best for exploratory testing, smoke testing, UX verification, and validating behaviors that resist automation.

- **`/gaia-test-run`** — Automated machine test suite execution. Runs the project's existing automated tests (unit, integration, e2e) via the configured test runner (jest, pytest, bats, etc.) and reports structured pass/fail results. Best for regression testing, CI gates, and coverage measurement.

Use `/gaia-test-manual` when you need a human-style walkthrough with evidence. Use `/gaia-test-run` when you need to execute the automated test suite.

## Critical Rules

- A target argument MUST be provided. If missing, fail fast with "usage: /gaia-test-manual <target>".
- The manual-tester agent runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify source files. Evidence persistence is parent-mediated.
- Proof-of-execution gate: if the agent verdict is `PASSED` but either `run-record.md` or `exit-code.log` is missing or empty, the verdict MUST be downgraded to `UNVERIFIED`. This gate is enforced by `write-evidence.sh --verify`.
- Evidence files land under the canonical evidence directory resolved by `resolve-artifact-path.sh manual_test --slug <target-slug>`.
- Sprint-status.yaml is NEVER written by this skill.

## Supported Surfaces

The manual-test skill supports four verification surfaces, each keyed to a project-config signal:

| Surface   | Config Signal                          | When Absent         |
|-----------|----------------------------------------|---------------------|
| browser   | `platforms` contains `web`             | SKIPPED (dormant)   |
| api       | `platforms` contains `server`          | SKIPPED (dormant)   |
| mobile    | `platforms` contains `ios` or `android`| SKIPPED (dormant)   |
| desktop   | `sprint_review.desktop_commands` has entries | SKIPPED (dormant) |

A surface that is not configured is always SKIPPED (exit code 2) — never UNVERIFIED, never FAILED. SKIPPED means dormant: the surface is simply not relevant to this project. UNVERIFIED means the surface was exercised but evidence was insufficient.

The default surface when none is specified is `api`, for backward compatibility with backend-only projects.

## Relationship to Existing Testing Skills

`/gaia-test-manual` is complementary to, not a replacement for, the existing automated and specialized testing skills:

- **`/gaia-test-e2e`** — Automated end-to-end test execution via Playwright or Cypress. Manual testing covers behaviors that resist browser automation (visual polish, subjective UX, edge-case flows that the e2e suite does not yet cover).

- **`/gaia-test-mobile-e2e`** — Automated mobile end-to-end tests via Detox or Appium. Manual testing on the mobile surface provides human-walkthrough coverage for gestures, haptics, and platform-specific behaviors that mobile e2e frameworks handle poorly.

- **`/gaia-test-a11y`** — Automated accessibility testing via axe-core, pa11y, or Lighthouse. Manual testing surfaces accessibility issues that require human judgment (focus order intuitiveness, screen-reader narrative coherence, color-contrast edge cases in complex gradients).

- **`/gaia-review-mobile`** — Code review with a mobile-specific lens. Manual testing verifies runtime behavior; the mobile review inspects code-level patterns (memory leaks, deep-link handling, offline resilience).

- **`/gaia-test-device-matrix`** — Automated cross-device test matrix execution. Manual testing complements the matrix by covering devices or OS versions that the matrix does not include, or by exercising behaviors that differ across physical hardware in ways emulators miss.

- **`/gaia-config-device-target`** — Configuration editor for the device-target matrix. Not a testing skill itself, but its output (the `device_targets` section) feeds both `/gaia-test-device-matrix` and the manual-test mobile surface's scope decisions.

## Steps

### Step 1 — Resolve target and evidence path

Resolve the target argument to a concrete testable entity (script path, skill name, feature description). Derive a slug from the target for the evidence directory path. Use `resolve-artifact-path.sh manual_test --slug <slug>` to determine the canonical evidence location.

### Step 1b — Resolve surface profile

Determine which surface to exercise. If the caller provides a `MANUAL_TEST_SURFACE` environment variable, use it; otherwise default to `api`. Run `surface-adapter.sh --surface <surface>` to check whether the surface is configured in the project. If the adapter returns SKIPPED (exit 2), skip directly to Step 5 with a SKIPPED verdict — do not dispatch the agent. If the adapter returns an error (exit 1), fail fast.

### Step 2 — Dispatch the manual-tester agent

Dispatch the `manual-tester` agent (Reese) via the Agent tool with `context: fork`. Pass the target description and any relevant context (acceptance criteria, usage examples, expected behaviors). The agent runs commands, observes output, and returns a structured run-record payload.

### Step 3 — Persist evidence artifacts

Receive the agent's run-record payload. Invoke `write-evidence.sh <evidence-dir> <verdict>` with the run-record content piped via stdin. The script writes `run-record.md` and `exit-code.log` to the evidence directory.

### Step 4 — Enforce proof-of-execution gate

Invoke `write-evidence.sh <evidence-dir> <verdict> --verify` to validate that both evidence files exist and are non-empty. If the verdict is `PASSED` but evidence is missing or empty, the script downgrades to `UNVERIFIED` and exits non-zero.

### Step 5 — Surface verdict and findings

Report the final verdict to the user. Surface any `WARNING` or `CRITICAL` findings from the run-record. Suppress `INFO` findings from the user-visible transcript (they remain in the evidence files).

### Step 5b — Record verdict on review-gate ledger

The finalize script records the manual-test verdict on the review-gate extended ledger (the same tier used by test-automate-plan and story-validation). It also appends a row to the persistent verdicts TSV (`.gaia/state/manual-test-verdicts.tsv`) for flakiness tracking. Set `MANUAL_TEST_VERDICT`, `MANUAL_TEST_STORY_KEY`, and optionally `MANUAL_TEST_RUN_ID` before finalize runs. Stories with `manual_verification: true` in frontmatter will see an advisory WARNING on `review -> done` transition if the latest manual-test verdict is FAILED.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/finalize.sh
